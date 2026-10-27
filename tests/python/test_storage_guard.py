"""Admission never removes live data and simultaneous syncs share a budget."""
from __future__ import annotations
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader("storage_guard", str(ROOT / "src/bin/getbible-storage-guard"))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)


class StorageGuardTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "usage.json").write_text(json.dumps({"generated_at": time.time(), "used_bytes": 100}))

    def args(self, **values):
        defaults = dict(state=str(self.root), action="reserve", id="one", max_gib=1,
                        max_age=120, bytes=600 * 1024**2, checkout=None, revision="HEAD")
        return SimpleNamespace(**(defaults | values))

    def test_competing_reservation_preserves_oldest_and_live_data(self):
        live = self.root / "live.json"
        live.write_text("Scripture")
        guard.admission(self.args())
        with self.assertRaisesRegex(ValueError, "serving and rollback releases were retained"):
            guard.admission(self.args(id="two"))
        self.assertEqual(live.read_text(), "Scripture")
        guard.admission(self.args(action="release"))
        self.assertEqual(guard.admission(self.args(id="two"))["reserved_bytes"], 600 * 1024**2)

    def test_existing_shared_lock_never_requires_chmod_by_another_domain(self):
        guard.admission(self.args())
        # fchmod would fail for a different sync UID sharing the readers group.
        with patch.object(guard.os, "fchmod", side_effect=PermissionError("not owner")):
            guard.admission(self.args(action="release"))
            guard.admission(self.args(id="other-domain"))

    def test_periodic_sampler_honors_saved_and_authoritative_budget(self):
        configured = self.root / "getbible.conf"
        environment = self.root / "environment.conf"
        configured.write_text("STORAGE_MAX_GIB=100\n")
        environment.write_text("STORAGE_MAX_GIB=250\n")
        with patch.dict(os.environ, {"GETBIBLE_STORAGE_MAX_GIB": ""}):
            self.assertEqual(guard.storage_budget(configured, environment), 250)
        with patch.dict(os.environ, {"GETBIBLE_STORAGE_MAX_GIB": "0"}):
            self.assertEqual(guard.storage_budget(configured, environment), 0)
        with patch.dict(os.environ, {"GETBIBLE_STORAGE_MAX_GIB": "500"}):
            self.assertEqual(guard.storage_budget(configured, environment), 500)

    def test_stale_accounting_refuses_publication(self):
        (self.root / "usage.json").write_text(json.dumps({"generated_at": time.time() - 121, "used_bytes": 0}))
        with self.assertRaisesRegex(ValueError, "stale"):
            guard.admission(self.args())

    def test_snapshot_counts_hardlinked_releases_once(self):
        source = self.root / "source"
        source.write_bytes(b"x" * 5000)
        os.link(source, self.root / "retained")
        (self.root / "usage.json").unlink()
        result = guard.snapshot([str(self.root)])
        self.assertEqual(result["used_bytes"], source.stat().st_blocks * 512)
        self.assertEqual(result["roots"][0]["files"], 1)
        self.assertFalse(result["hard_quota"])

    def corpus(self, count=5):
        corpus = self.root / "corpus"
        corpus.mkdir()
        for number in range(count):
            (corpus / str(number)).write_bytes(b"x" * 4097)
        return corpus

    def first_slice(self, corpus, horizon=900):
        # One entry is committed; the next entry reaches the slice deadline.
        with patch.object(guard.time, "monotonic", side_effect=[0, 0, 0, 0, 1]):
            return guard.sample([str(corpus)], self.root, max_seconds=horizon, slice_seconds=.5)

    def test_partial_scan_retains_usage_and_resumes_without_double_counting(self):
        corpus = self.corpus()
        previous = (self.root / "usage.json").read_bytes()
        partial = self.first_slice(corpus)
        self.assertEqual(partial["status"], "in_progress")
        self.assertEqual(partial["files"], 1)
        self.assertEqual((self.root / "usage.json").read_bytes(), previous)
        report = guard.sample([str(corpus)], self.root)
        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["roots"][0]["files"], 5)
        self.assertEqual(report["used_bytes"], sum(path.stat().st_blocks * 512 for path in corpus.iterdir()))
        self.assertEqual(report["started_at"], partial["started_at"])
        self.assertEqual(report["generated_at"], report["started_at"])
        self.assertGreaterEqual(report["completed_at"], report["started_at"])
        self.assertEqual(report["max_age_seconds"], 1840)
        self.assertFalse((self.root / ".scan/scan.sqlite3").exists())

    def test_interrupted_transaction_replays_only_uncommitted_work(self):
        corpus = self.corpus(300)
        iterator = guard.directory_entries

        def interrupt(descriptor, cursor):
            for number, entry in enumerate(iterator(descriptor, cursor)):
                if number == 270:
                    raise KeyboardInterrupt
                yield entry

        with patch.object(guard, "directory_entries", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                guard.sample([str(corpus)], self.root)
        with sqlite3.connect(self.root / ".scan/scan.sqlite3") as connection:
            self.assertEqual(connection.execute("SELECT SUM(files) FROM roots").fetchone()[0], 256)
        report = guard.sample([str(corpus)], self.root)
        self.assertEqual(report["roots"][0]["files"], 300)

    def test_directory_buffer_cookie_resumes_a_wide_directory(self):
        corpus = self.corpus(3000)
        iterator = guard.directory_entries
        visited = 0

        def observe(descriptor, cursor):
            nonlocal visited
            for entry in iterator(descriptor, cursor):
                visited += 1
                yield entry

        with patch.object(guard, "directory_entries", side_effect=observe), patch.object(
                guard.time, "monotonic", side_effect=lambda: 1 if visited >= 1500 else 0):
            partial = guard.sample([str(corpus)], self.root, slice_seconds=.5)
        self.assertEqual(partial["status"], "in_progress")
        with sqlite3.connect(self.root / ".scan/scan.sqlite3") as connection:
            self.assertGreater(connection.execute("SELECT cursor FROM directories WHERE done=0").fetchone()[0], 0)
        visited = 0
        with patch.object(guard, "directory_entries", side_effect=observe):
            report = guard.sample([str(corpus)], self.root)
        self.assertEqual(report["roots"][0]["files"], 3000)
        self.assertLess(visited, 3000)

    def test_directory_mutation_replays_names_and_discovers_new_files(self):
        corpus = self.corpus()
        self.first_slice(corpus)
        (corpus / "added").write_bytes(b"new")
        report = guard.sample([str(corpus)], self.root)
        self.assertEqual(report["roots"][0]["files"], 6)

    def test_same_name_replacement_is_counted_during_directory_replay(self):
        corpus = self.corpus()
        self.first_slice(corpus)
        with sqlite3.connect(self.root / ".scan/scan.sqlite3") as connection:
            name = os.fsdecode(connection.execute("SELECT name FROM entries LIMIT 1").fetchone()[0])
        replaced = corpus / name
        old_allocated = replaced.stat().st_blocks * 512
        # Retain the old inode elsewhere to rule out filesystem inode reuse.
        os.link(replaced, self.root / "retained-old-inode")
        replaced.unlink()
        replaced.write_bytes(b"replacement" * 2000)
        report = guard.sample([str(corpus)], self.root)
        current_allocated = sum(path.stat().st_blocks * 512 for path in corpus.iterdir())
        self.assertEqual(report["roots"][0]["files"], 6)
        self.assertEqual(report["used_bytes"], current_allocated + old_allocated)

    def test_replaced_directory_is_not_promoted_as_a_complete_scan(self):
        corpus = self.corpus()
        previous = (self.root / "usage.json").read_bytes()
        self.first_slice(corpus)
        corpus.rename(self.root / "previous")
        corpus.mkdir()
        (corpus / "replacement").write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "directory was replaced"):
            guard.sample([str(corpus)], self.root)
        self.assertEqual((self.root / "usage.json").read_bytes(), previous)
        self.assertEqual(json.loads((self.root / "progress.json").read_text())["status"], "failed")
        self.assertEqual(guard.sample([str(corpus)], self.root)["roots"][0]["files"], 1)

    def test_scan_horizon_fails_without_promoting_partial_accounting(self):
        corpus = self.corpus()
        previous = (self.root / "usage.json").read_bytes()
        self.first_slice(corpus, 120)
        with sqlite3.connect(self.root / ".scan/scan.sqlite3") as connection:
            connection.execute("UPDATE metadata SET value=? WHERE key='started_at'", (str(time.time() - 121),))
        with self.assertRaisesRegex(TimeoutError, "120-second horizon"):
            guard.sample([str(corpus)], self.root, max_seconds=120)
        self.assertEqual((self.root / "usage.json").read_bytes(), previous)
        self.assertFalse((self.root / ".scan/scan.sqlite3").exists())

    def test_permission_failure_retains_previous_complete_snapshot(self):
        corpus = self.corpus()
        previous = (self.root / "usage.json").read_bytes()
        original_open = guard.os.open

        def refuse(path, *args, **kwargs):
            if str(path) == str(corpus):
                raise PermissionError("denied directory")
            return original_open(path, *args, **kwargs)

        with patch.object(guard.os, "open", side_effect=refuse):
            with self.assertRaisesRegex(PermissionError, "denied directory"):
                guard.sample([str(corpus)], self.root)
        self.assertEqual((self.root / "usage.json").read_bytes(), previous)

    def test_overlapping_roots_hardlinks_symlinks_and_nonascii_names(self):
        corpus = self.corpus(1)
        nested = corpus / "écriture"
        nested.mkdir()
        (nested / "verset").write_bytes(b"text")
        os.link(corpus / "0", nested / "copie")
        (corpus / "loop").symlink_to(corpus, target_is_directory=True)
        report = guard.snapshot([str(nested), str(corpus), str(corpus)])
        self.assertEqual(len(report["roots"]), 1)
        self.assertEqual(report["roots"][0]["files"], 2)

    def test_admission_uses_scan_start_and_completed_snapshot_window(self):
        now = time.time()
        usage = {"generated_at": now - 200, "started_at": now - 200, "completed_at": now,
                 "max_age_seconds": 1840, "used_bytes": 0, "status": "complete"}
        (self.root / "usage.json").write_text(json.dumps(usage))
        guard.admission(self.args(max_age=None))
        with self.assertRaisesRegex(ValueError, "stale"):
            guard.admission(self.args(max_age=120, id="explicit"))
        usage["started_at"] = usage["generated_at"] = now - 1841
        (self.root / "usage.json").write_text(json.dumps(usage))
        with self.assertRaisesRegex(ValueError, "stale"):
            guard.admission(self.args(max_age=None))

    def test_sequential_publications_keep_budget_charges_until_observed(self):
        guard.admission(self.args())
        guard.admission(self.args(action="commit"))
        guard.admission(self.args(action="release"))
        with self.assertRaisesRegex(ValueError, "committed storage reservation"):
            guard.admission(self.args())
        with self.assertRaisesRegex(ValueError, "exceeds STORAGE_MAX_GIB"):
            guard.admission(self.args(id="two"))
        reservations = json.loads((self.root / "reservations.json").read_text())
        stamp = reservations["one"]["committed_at"]
        # Completion alone is insufficient: the sample must START after commit.
        (self.root / "usage.json").write_text(json.dumps({"generated_at": stamp - 1,
            "started_at": stamp - 1, "completed_at": time.time(), "used_bytes": 0}))
        with self.assertRaisesRegex(ValueError, "exceeds STORAGE_MAX_GIB"):
            guard.admission(self.args(id="two"))
        (self.root / "usage.json").write_text(json.dumps({"generated_at": time.time(), "used_bytes": 0}))
        guard.admission(self.args(id="two"))
        self.assertNotIn("one", json.loads((self.root / "reservations.json").read_text()))


if __name__ == "__main__":
    unittest.main()
