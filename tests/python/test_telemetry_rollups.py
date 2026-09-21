"""Reporting equivalence and recovery against disposable canonical traffic history."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_telemetry import TelemetryStore
from getbible_telemetry.rollups import ReportingPreparing, effective_bucket_seconds
from getbible_telemetry.store import SCHEMA_VERSION, prepare_history


HOUR = 3600
DAY = 24 * HOUR
START = 2 * DAY
END = START + 3 * DAY
DIMENSIONS = (
    "endpoint", "version", "status", "auth", "ip", "path", "translation",
    "book", "search", "reference", "cache", "method", "token", "user_agent",
    "operation", "referrer", "endpoint_kind", "mcp_method", "mcp_tool",
    "mcp_client_name", "mcp_client_version", "mcp_outcome", "upstream_service",
    "upstream_api_version", "upstream_operation",
)


class TelemetryRollupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / "traffic.sqlite3"
        self.store = TelemetryStore(self.path)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    @staticmethod
    def record(request_id, stamp, **changes):
        """Canonical records avoid coupling report checks to log normalization."""
        value = {
            "endpoint": "api.example.test", "request_id": request_id, "stamp": stamp,
            "method": "GET", "path": "/v3/kjv/43/3.json", "query": "", "version": "v3",
            "status": 200, "duration_ms": 5.0, "bytes": 100, "remote_addr": "192.0.2.1",
            "token_id": "", "auth": "anonymous", "cache": "HIT", "translation": "kjv",
            "book": '["43"]', "reference": "", "search": "", "operation": "static",
            "user_agent": "Example reader/1", "endpoint_kind": "static",
            "referrer": "https://reader.example.test/", "book_names": '{"43":"John"}',
            "edge_json": '{}', "runtime_json": None,
        }
        value.update(changes)
        return value

    @staticmethod
    def insert(db, record):
        columns = list(record)
        db.execute("INSERT INTO requests(" + ",".join(columns) + ") VALUES("
                   + ",".join("?" for _ in columns) + ")", tuple(record.values()))

    def populate(self, db=None):
        db = self.store.db if db is None else db
        latencies = (0.5, 1.0, 5.0, 5.1, 25.0, 251.0, 1000.0, 70001.0)
        with db:
            for hour in (0, 1, 3, 24, 25, 30, 48, 50):
                # Unequal sample counts expose averaging per-hour averages.
                for index in range(5 + hour % 4):
                    kind = ("static", "search", "query", "mcp")[index % 4]
                    mcp = kind == "mcp"
                    operation = {"static": "static", "search": "search",
                                 "query": "scripture", "mcp": "call_api_operation"}[kind]
                    fields = {
                        "endpoint": kind + ".example.test", "endpoint_kind": kind,
                        "version": "" if mcp else ("v2" if index % 2 else "v3"),
                        "operation": operation, "method": ("GET", "POST", "HEAD", "OPTIONS")[index % 4],
                        "status": (200, 304, 404, 429, 500, 200, 201, 503)[(index + hour) % 8],
                        "duration_ms": latencies[(index + hour) % len(latencies)],
                        "bytes": 100 + hour + index,
                        "remote_addr": "192.0.2." + str(index % 3 + 1),
                        "token_id": "reader-" + str(index % 2) if index % 3 else "",
                        "auth": ("anonymous", "valid", "rejected")[index % 3],
                        "cache": ("HIT", "MISS", "", "-")[index % 4],
                        "translation": "" if mcp else ("asv" if index % 2 else "kjv"),
                        "book": "" if mcp else '["1","43"]' if index % 2 else '["43"]',
                        "book_names": '{}' if mcp else '{"1":"Genesis","43":"John"}',
                        "reference": "John 3:16" if kind == "query" else "",
                        "search": "love" if kind == "search" else "",
                        "user_agent": "Example reader/" + str(index % 2),
                        "referrer": "" if index % 3 else "https://reader.example.test/",
                    }
                    if mcp:
                        fields["runtime_json"] = json.dumps({
                            "mcp_method": "tools/call", "mcp_tool": "call_api_operation",
                            "mcp_client_name": "Example client", "mcp_client_version": "2.0",
                            "mcp_outcome": "tool_error" if hour % 2 else "success",
                            "upstream_service": "query", "upstream_api_version": "v3",
                            "upstream_operation": "getScripture",
                        })
                    self.insert(db, self.record(f"request-{hour}-{index}",
                                                START + hour * HOUR + 90.5 + index * 41, **fields))
                self.insert(db, self.record(f"orphan-{hour}", START + hour * HOUR + 850,
                                            edge_json=None, runtime_json='{"event":"request"}'))

    def refresh(self):
        for _ in range(100):
            progress = self.store.refresh_rollups(max_buckets=100, time_budget=10)
            if progress["ready"]:
                self.assertTrue(progress["backfill_complete"])
                self.assertEqual(progress["pending_hours"], 0)
                return progress
        self.fail("Reporting preparation did not converge on a finite fixture")

    def repeat_record(self, count, stamp, prefix):
        template = self.record(prefix, stamp)
        values = [count]
        expressions = []
        for column, value in template.items():
            expressions.append("? || number" if column == "request_id" else "?")
            values.append(value)
        with self.store.db:
            self.store.db.execute(
                "WITH RECURSIVE synthetic(number) AS (SELECT 1 UNION ALL "
                "SELECT number+1 FROM synthetic WHERE number<?) INSERT INTO requests("
                + ",".join(template) + ") SELECT " + ",".join(expressions) + " FROM synthetic", values)

    def assert_equivalent(self, actual, expected):
        """Counts stay exact; SQL sum ordering may change floating-point roundoff."""
        if isinstance(expected, dict):
            self.assertEqual(set(actual), set(expected))
            for name, value in expected.items():
                with self.subTest(field=name):
                    self.assert_equivalent(actual[name], value)
        elif isinstance(expected, list):
            self.assertEqual(len(actual), len(expected))
            for number, (left, right) in enumerate(zip(actual, expected)):
                with self.subTest(row=number):
                    self.assert_equivalent(left, right)
        elif isinstance(expected, float):
            self.assertTrue(math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9),
                            (actual, expected))
        else:
            self.assertEqual(actual, expected)

    def check_summary(self, start=START, end=END, **options):
        expected = self.store._summary_raw(start, end, **options)
        actual = self.store.summary(start, end, **options)
        # Storage sizes are operational state, not request-report semantics.
        expected.pop("retention")
        actual.pop("retention")
        self.assert_equivalent(actual, expected)
        return actual

    def test_summary_and_rankings_preserve_all_canonical_dimensions(self):
        self.populate()
        self.refresh()
        report = self.check_summary()
        self.assertEqual(report["unique_ips"], 3)
        self.assertEqual(report["unique_tokens"], 2)
        self.assertEqual(report["runtime_without_edge"], 8)
        self.assertEqual(sum(bucket["count"] for bucket in report["latency_ms"]["histogram"]),
                         report["calls"])
        for dimension in DIMENSIONS:
            with self.subTest(dimension=dimension):
                self.assert_equivalent(
                    self.store.breakdown(dimension, START, END, top=2),
                    self.store._breakdown_raw(dimension, START, END, top=2))

    def test_partial_hours_and_half_open_boundaries_match_raw(self):
        self.populate()
        self.refresh()
        ranges = (
            (START + 90.5, START + 50 * HOUR + 213.5),
            (START + 90.5001, START + 50 * HOUR + 213.5),
            (START + HOUR, START + 2 * DAY),
            (START + HOUR - .01, START + 2 * DAY + .01),
            (END, END + DAY),
            (START, START),
        )
        for start, end in ranges:
            with self.subTest(start=start, end=end):
                self.check_summary(start, end)
                bucket = effective_bucket_seconds(start, end, 700)
                self.assert_equivalent(self.store.series(start, end, 700),
                                       self.store._series_raw(start, end, bucket))

    def test_filter_intersections_and_usage_rules_match_raw(self):
        self.populate()
        self.refresh()
        selections = (
            {"endpoint": "search.example.test"}, {"version": "v3"},
            {"filters": {"endpoint_kind": "mcp"}}, {"filters": {"status": "200"}},
            {"filters": {"auth": "valid", "cache": "MISS"}},
            {"filters": {"method": "GET", "translation": "kjv"}},
            {"filters": {"endpoint": "query.example.test", "operation": "scripture"}},
            {"filters": {"successful": "true"}}, {"filters": {"successful": "false"}},
            {"filters": {"origin_only": "true"}}, {"filters": {"origin_only": "false"}},
            {"filters": {"usage": "translation"}}, {"filters": {"usage": "book"}},
            {"filters": {"usage": "search"}}, {"filters": {"usage": "reference"}},
            {"endpoint": "query.example.test", "filters": {"endpoint_kind": "search"}},
            {"filters": {"translation": "missing"}},
            {"filters": {"ip": "192.0.2.1", "token": "reader-0"}},
            {"filters": {"book": "43"}}, {"filters": {"q": "example CLIENT"}},
            {"filters": {"mcp_outcome": "tool_error"}},
            {"filters": {"path_contains": "kjv", "user_agent_contains": "reader"}},
        )
        for options in selections:
            with self.subTest(options=options):
                self.check_summary(START + 91, END - 19, **options)
                bucket = effective_bucket_seconds(START + 91, END - 19, 700)
                self.assert_equivalent(self.store.series(START + 91, END - 19, 700, **options),
                                       self.store._series_raw(START + 91, END - 19, bucket, **options))

    def test_series_keeps_short_range_resolution_and_combines_long_range_hours(self):
        self.populate()
        self.refresh()
        for start, end, requested in ((START, START + HOUR, 60), (START, START + DAY - 1, 61),
                                      (START, START + DAY, 61), (START + 91, END - 19, 3701)):
            with self.subTest(start=start, end=end, requested=requested):
                bucket = effective_bucket_seconds(start, end, requested)
                if end - start < DAY:
                    self.assertEqual(bucket, max(requested, math.ceil((end - start) / 2000)))
                else:
                    self.assertEqual(bucket % HOUR, 0)
                    self.assertGreaterEqual(bucket, requested)
                actual = self.store.series(start, end, requested)
                self.assert_equivalent(actual, self.store._series_raw(start, end, bucket))
                self.assertTrue(all(row["bucket_seconds"] == bucket for row in actual))

    def test_summary_requests_only_selected_dimensions_and_validates_them(self):
        self.populate()
        self.refresh()
        for selected in ([], ["endpoint"], ["status", "translation", "mcp_tool"]):
            with self.subTest(dimensions=selected):
                result = self.check_summary(dimensions=selected)
                self.assertEqual(set(result["breakdowns"]), set(selected))
        with self.assertRaises(ValueError):
            self.store.summary(START, END, dimensions=["endpoint", "unrecognized_dimension"])

    def test_insert_update_delete_and_timestamp_move_replace_prior_aggregates(self):
        self.populate()
        self.refresh()
        with self.store.db:
            self.insert(self.store.db, self.record("new", START + 2 * HOUR, duration_ms=60001))
            self.store.db.execute("UPDATE requests SET stamp=?,status=503,bytes=900,remote_addr=? "
                                  "WHERE request_id=?", (START + 49 * HOUR, "192.0.2.250", "request-1-0"))
            self.store.db.execute("DELETE FROM requests WHERE request_id=?", ("request-24-0",))
        self.refresh()
        self.check_summary()
        self.check_summary(START, START + DAY)
        self.check_summary(START + DAY, END)
        self.assertEqual(self.store.summary(START, END, dimensions=[])["unique_ips"], 4)
        # Rebuilding an unchanged store must not add its figures a second time.
        self.refresh()
        self.check_summary()

    def test_failed_ingestion_transaction_preserves_the_previous_report(self):
        self.populate()
        self.refresh()
        before = self.check_summary()
        with self.assertRaisesRegex(RuntimeError, "aborted ingestion"):
            with self.store.db:
                self.insert(self.store.db, self.record("uncommitted", START + 2 * HOUR))
                self.store.db.execute("DELETE FROM requests WHERE request_id=?", ("request-24-0",))
                raise RuntimeError("aborted ingestion")
        self.refresh()
        self.assert_equivalent(self.check_summary(), before)

    def test_late_edge_runtime_merge_moves_hours_and_is_idempotent(self):
        runtime = {"time": START + 100, "request_id": "late", "event": "request",
                   "method": "GET", "path": "/v3/kjv/John3:16", "status": 200,
                   "duration_ms": 7, "endpoint_kind": "query", "operation": "scripture",
                   "version": "v3", "translation": "kjv", "reference": "John 3:16"}
        edge = {"time": START + 2 * DAY + 200, "request_id": "late", "method": "GET",
                "uri": "/v3/kjv/John3:16", "status": 304, "request_time": .25,
                "bytes": 70, "remote_addr": "192.0.2.1", "cache": "HIT"}
        with self.store.db:
            self.store.append(runtime, endpoint="query.example.test", source="runtime", record_key="runtime")
        self.refresh()
        initial = self.check_summary()
        self.assertEqual((initial["calls"], initial["runtime_without_edge"]), (0, 1))
        for _ in range(2):
            with self.store.db:
                self.store.append(edge, endpoint="query.example.test", source="edge", record_key="edge")
                self.store.append(runtime, endpoint="query.example.test", source="runtime", record_key="runtime")
            self.refresh()
            report = self.check_summary()
            self.assertEqual((report["calls"], report["runtime_without_edge"], report["duration_ms"]),
                             (1, 0, 250))
            self.assertEqual(self.store.summary(START, START + DAY, dimensions=[])["calls"], 0)

    def test_retention_removes_aggregate_totals_and_distinct_values(self):
        self.populate()
        with self.store.db:
            self.insert(self.store.db, self.record("expired-identity", START + 30,
                                                  remote_addr="192.0.2.250", token_id="expired"))
        self.refresh()
        self.assertEqual(self.store.summary(START, END, dimensions=[])["unique_ips"], 4)
        pruned = self.store.prune(max_bytes=512 * 1024**2, retention_days=1, now=END)
        self.assertGreater(pruned["deleted"]["requests"], 0)
        self.refresh()
        report = self.check_summary()
        self.assertEqual((report["unique_ips"], report["unique_tokens"]), (3, 2))
        self.assertEqual(self.store.summary(START, START + DAY, dimensions=[])["calls"], 0)
        self.assertEqual(self.store.db.execute(
            "SELECT count(*) FROM reporting_scopes WHERE id NOT IN "
            "(SELECT scope_id FROM reporting_totals)").fetchone()[0], 0)

    def test_large_pending_report_exposes_progress_and_keeps_details_available(self):
        template = self.record("pending", START)
        columns, expressions, values = list(template), [], []
        for column, value in template.items():
            if column == "request_id":
                expressions.append("'pending-' || number")
            elif column == "stamp":
                expressions.append("? + (number % 48) * 3600 + 15")
                values.append(START)
            else:
                expressions.append("?")
                values.append(value)
        with self.store.db:
            self.store.db.execute(
                "WITH RECURSIVE synthetic(number) AS (SELECT 1 UNION ALL "
                "SELECT number+1 FROM synthetic WHERE number<60000) "
                "INSERT INTO requests(" + ",".join(columns) + ") SELECT "
                + ",".join(expressions) + " FROM synthetic", values)
        with TelemetryStore(self.path, readonly=True) as reader:
            with self.assertRaises(ReportingPreparing) as raised:
                reader.summary(START, END, dimensions=[])
            self.assertFalse(raised.exception.progress["ready"])
            self.assertGreater(raised.exception.progress["pending_hours"], 0)
            self.assertEqual(len(reader.requests(START, END, limit=5)["items"]), 5)
        before = raised.exception.progress["pending_hours"]
        progress = self.store.refresh_rollups(max_buckets=1, time_budget=10)
        self.assertEqual(progress["processed"], 1)
        self.assertLess(progress["pending_hours"], before)
        self.assertFalse(progress["ready"])

    def test_dense_partial_and_live_hours_remain_readable_after_preparation(self):
        self.repeat_record(60000, START + 100, "boundary-")
        with self.store.db:
            self.insert(self.store.db, self.record("closed-interior", START + DAY + 100))
        self.refresh()
        historical = self.check_summary(START + 10, START + 2 * DAY + 10, dimensions=[])
        self.assertEqual(historical["calls"], 60001)
        current = START + 4 * DAY
        self.repeat_record(60000, current + 100, "live-")
        with patch("getbible_telemetry.rollups.time.time", return_value=current + 200):
            # The live hour cannot be projected until it closes; retries alone
            # cannot make a preparation response actionable for this boundary.
            self.refresh()
            live = self.check_summary(START + DAY, current + 150, dimensions=[])
            self.assertEqual(live["calls"], 60001)
            bucket = effective_bucket_seconds(START + DAY, current + 150, 60)
            self.assert_equivalent(self.store.series(START + DAY, current + 150, 60),
                                   self.store._series_raw(START + DAY, current + 150, bucket))

    def test_migrated_history_backfill_resumes_and_preserves_collection_cursors(self):
        legacy_path = self.root / "legacy.sqlite3"
        with sqlite3.connect(legacy_path) as legacy:
            legacy.executescript((ROOT / "src/apps/telemetry/getbible_telemetry/schemas/2.sql").read_text())
            legacy.execute("PRAGMA user_version=2")
            self.populate(legacy)
            legacy.execute("INSERT INTO sources(identity,path,offset,updated) VALUES(?,?,?,?)",
                           ("source-1", "/logs/access.log", 4096, START))
            legacy.execute("INSERT INTO metadata(key,value) VALUES(?,?)", ("journal_cursor", '"cursor-1"'))
            original_rows = legacy.execute("SELECT count(*) FROM requests").fetchone()[0]
        preparation = prepare_history(legacy_path, self.root / "backups")
        self.assertEqual(preparation["previous_schema_version"], 2)
        self.assertEqual(preparation["schema_version"], SCHEMA_VERSION)
        self.assertFalse(preparation["history_reset"])
        with sqlite3.connect(preparation["backup"]) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(backup.execute("SELECT count(*) FROM requests").fetchone()[0], original_rows)
        self.store.close()
        self.path = legacy_path
        self.store = TelemetryStore(self.path)
        with TelemetryStore(self.path, readonly=True) as reader:
            # Small histories may remain available through bounded raw reads.
            # A larger incomplete report must explicitly expose preparation.
            try:
                pending = reader.summary(START, END, dimensions=[])
            except ReportingPreparing as error:
                self.assertFalse(error.progress["ready"])
            else:
                self.assertEqual(pending["calls"], original_rows - 8)
                self.assertEqual(pending["runtime_without_edge"], 8)
        first = self.store.refresh_rollups(max_buckets=1, time_budget=10)
        self.assertLessEqual(first["processed"], 1)
        self.assertFalse(first["ready"])
        self.store.close()
        self.store = TelemetryStore(self.path)
        # Ingestion continues while preexisting hours are prepared.
        with self.store.db:
            self.insert(self.store.db, self.record("during-backfill", START + 30, status=500))
        self.refresh()
        self.assertEqual(self.store.db.execute("SELECT offset FROM sources WHERE identity='source-1'").fetchone()[0], 4096)
        self.assertEqual(json.loads(self.store.db.execute("SELECT value FROM metadata WHERE key='journal_cursor'").fetchone()[0]),
                         "cursor-1")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM requests").fetchone()[0], original_rows + 1)
        self.check_summary()

    def test_migrated_unclosed_hours_are_prepared_when_the_clock_advances(self):
        legacy_path = self.root / "unclosed.sqlite3"
        with sqlite3.connect(legacy_path) as legacy:
            legacy.executescript((ROOT / "src/apps/telemetry/getbible_telemetry/schemas/2.sql").read_text())
            legacy.execute("PRAGMA user_version=2")
            for hour in range(3):
                self.insert(legacy, self.record("unclosed-" + str(hour), START + hour * HOUR + 50))
        prepare_history(legacy_path, self.root / "backups")
        self.store.close()
        self.store = TelemetryStore(legacy_path)
        with patch("getbible_telemetry.rollups.time.time", return_value=START + 100):
            self.store.refresh_rollups(max_buckets=10, time_budget=10)
        for clock in (START + HOUR + 100, START + 3 * HOUR + 100):
            with self.subTest(clock=clock), patch("getbible_telemetry.rollups.time.time", return_value=clock):
                progress = self.store.refresh_rollups(max_buckets=10, time_budget=10)
                self.assertGreater(progress["processed"], 0)
                self.check_summary(START, END, dimensions=[])


if __name__ == "__main__":
    unittest.main()
