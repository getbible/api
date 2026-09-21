"""Report reuse is bounded, invalidated by writes and shared across viewers."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/dashboard"))
from getbible_dashboard.report_cache import ReportCache


class ReportCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "traffic.sqlite3"
        self.path.write_bytes(b"database")

    def test_concurrent_viewers_share_work_and_receive_independent_responses(self):
        cache = ReportCache(self.path)
        start = threading.Barrier(4)
        calls = []

        def compute():
            calls.append(1)
            return {"calls": 7, "breakdowns": {"endpoint": []}}

        def report():
            start.wait(timeout=5)
            return cache.get("report", compute)

        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(report) for _ in range(4)]
            reports = [future.result(timeout=5) for future in futures]
        self.assertEqual(len(calls), 1)
        reports[0]["breakdowns"]["endpoint"].append("handler state")
        for report in reports[1:]:
            self.assertEqual(report["breakdowns"]["endpoint"], [])
        self.assertEqual(cache.get("report", compute)["breakdowns"]["endpoint"], [])

    def test_database_wal_and_replacement_invalidate_cached_data(self):
        cache = ReportCache(self.path)
        values = iter(range(1, 10))
        compute = lambda: {"calls": next(values)}
        self.assertEqual(cache.get("report", compute)["calls"], 1)
        wal = Path(str(self.path) + "-wal")
        wal.write_bytes(b"new committed history")
        self.assertEqual(cache.get("report", compute)["calls"], 2)
        wal.write_bytes(b"another committed history transaction")
        self.assertEqual(cache.get("report", compute)["calls"], 3)
        replacement = self.path.with_suffix(".new")
        replacement.write_bytes(b"database")
        replacement.replace(self.path)
        self.assertEqual(cache.get("report", compute)["calls"], 4)
        wal.unlink()
        self.assertEqual(cache.get("report", compute)["calls"], 5)

    def test_failures_are_retried_and_clear_releases_saved_reports(self):
        cache = ReportCache(self.path)

        def failed():
            raise RuntimeError("still preparing")

        with self.assertRaisesRegex(RuntimeError, "still preparing"):
            cache.get("report", failed)
        self.assertEqual(cache.get("report", lambda: {"calls": 1})["calls"], 1)
        cache.clear()
        self.assertEqual(cache.get("report", lambda: {"calls": 2})["calls"], 2)

    def test_entry_byte_and_expiry_limits_do_not_retain_unbounded_results(self):
        for cache in (ReportCache(self.path, max_entries=1),
                      ReportCache(self.path, max_bytes=50),
                      ReportCache(self.path, ttl=0)):
            with self.subTest(cache=cache):
                cache.get("first", lambda: {"text": "one report payload"})
                cache.get("second", lambda: {"text": "another report payload"})
                result = cache.get("first", lambda: {"text": "recomputed"})
                self.assertEqual(result["text"], "recomputed")


if __name__ == "__main__":
    unittest.main()
