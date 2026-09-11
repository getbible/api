"""Admission never removes live data and simultaneous syncs share a budget."""
from __future__ import annotations
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
