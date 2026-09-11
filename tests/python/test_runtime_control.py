"""Cache control uses the public Librarian API and tracks publication changes."""
from __future__ import annotations
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


control = load("worker_control_test", "src/apps/common/getbible_api_common/control.py")
client = load("worker_control_client_test", "src/bin/getbible-runtime-control")
adapt = load("adaptive_test", "src/bin/getbible-adapt")


class Bible:
    def __init__(self):
        self.operations = []

    def transition_source(self, revision):
        self.operations.append(("source", revision))

    def cache_info(self):
        return {"memory_measurement": "estimated_python_objects_not_rss", "chapters": {"entries": 1}}

    def warm_query(self, translation):
        self.operations.append(("query", translation))
        return {"target": "query"}

    def warm_translation(self, translation, **kwargs):
        self.operations.append(("search", translation))
        return {"target": "search"}

    def drop_translation(self, translation, disk=False):
        self.operations.append(("drop", translation, disk))

    def reload_translation(self, translation, target):
        self.operations.append(("reload", translation, target))


class RuntimeControlTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gb-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "first").mkdir()
        (self.root / "v2").symlink_to("first")
        self.bible = Bible()
        self.worker = control.WorkerControl(self.bible, SimpleNamespace(repository=str(self.root), version="v2"), "query")
        self.addCleanup(self.worker.close)

    def test_source_refresh_is_lazy_and_detects_atomic_publication(self):
        self.assertTrue(self.worker.refresh_source())
        self.assertFalse(self.worker.refresh_source())
        (self.root / "second").mkdir()
        (self.root / "next").symlink_to("second")
        os.replace(self.root / "next", self.root / "v2")
        self.assertTrue(self.worker.refresh_source(force=True))
        revisions = [item[1] for item in self.bible.operations]
        self.assertEqual(len(set(revisions)), 2)

    def test_query_warm_does_not_build_search_index(self):
        self.worker.execute({"action": "warm", "translation": "kjv"})
        self.worker.execute({"action": "drop", "translation": "kjv"})
        self.worker.execute({"action": "reload", "translation": "kjv"})
        self.assertEqual([item for item in self.bible.operations if item[0] != "source"], [("query", "kjv"), ("drop", "kjv", False), ("reload", "kjv", "query")])
        with self.assertRaises(ValueError):
            self.worker.execute({"action": "warm", "translation": "../../etc"})

    def test_real_private_socket_and_measured_memory(self):
        with patch.dict(os.environ, {"GETBIBLE_CONTROL_DIR": str(self.root / "control")}):
            try:
                self.worker.start()
            except PermissionError:
                self.skipTest("This sandbox prohibits AF_UNIX socket creation; run on disposable Linux acceptance host.")
        self.assertEqual(self.worker.socket_path.stat().st_mode & 0o777, 0o600)
        info = client.worker_request(self.worker.socket_path, {"action": "info"}, 3)
        self.assertEqual(info["pid"], os.getpid())
        self.assertEqual(info["scope"], "worker")
        self.assertIn("RSS includes shared pages", info["memory_note"])
        self.assertGreater(info["rss_bytes"], 0)

    def test_http_ttl_renews_after_unchanged_successful_source_check(self):
        revision = self.root / ".freshness-v2"
        revision.write_text("test")
        os.utime(revision, (1000, 1000))
        self.worker.refresh_source(force=True)
        with patch.object(control.time, "time", return_value=1050):
            self.assertEqual(self.worker.cache_seconds(100), 50)
        with patch.object(control.time, "time", return_value=1200):
            self.assertEqual(self.worker.cache_seconds(100), 0)
        os.utime(revision, (1200, 1200))
        self.worker.next_source_check = 0
        self.worker.refresh_source()
        with patch.object(control.time, "time", return_value=1250):
            self.assertEqual(self.worker.cache_seconds(100), 50)

    def test_controller_needs_sustained_demand_and_respects_bounds(self):
        settings = {"ADAPTIVE_SUSTAINED_SAMPLES": "3"}
        target = {"workers": 2, "weight": 4}
        sample = {"utilization": 99, "queue_percent": 90, "memory_percent": 50,
                  "automatic_workers": True, "workers": 2, "workers_min": 1, "workers_max": 3}
        previous = {}
        for _ in range(2):
            candidate, previous = adapt.decide(settings, previous, sample, target)
            self.assertEqual(candidate, target)
        candidate, previous = adapt.decide(settings, previous, sample, target)
        self.assertEqual(candidate["workers"], 3)
        sample["workers"] = 3
        candidate, previous = adapt.decide(settings, previous, sample, candidate)
        self.assertEqual(candidate["workers"], 3)
        sample["automatic_workers"] = False
        candidate, _ = adapt.decide(settings, previous, sample, target)
        self.assertEqual(candidate, target)

    def test_response_crossing_publication_is_never_cached(self):
        try:
            from flask import Flask, Response
        except ImportError:
            self.skipTest("Flask runtime dependencies required")
        app = Flask(__name__)
        control.install_control(app, self.bible, self.worker.settings, "query")
        @app.get("/query")
        def route():
            (self.root / "next").symlink_to("first")
            os.replace(self.root / "next", self.root / "v2")
            response = Response("scripture")
            response.headers["Cache-Control"] = "public, max-age=2592000"
            return response
        response = app.test_client().get("/query")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(response.headers["CDN-Cache-Control"], "no-store")

    def test_watcher_repairs_cache_epoch_when_its_state_is_missing(self):
        args = SimpleNamespace(manager="getbible", registry=str(self.root))
        item = {"domain": "query.example.test", "kind": "query", "label": "v2"}
        environment = {"GETBIBLE_REPOSITORY": str(self.root), "GETBIBLE_VERSION": "v2"}
        with patch.object(adapt.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            revision = adapt.source_change(args, item, environment, None)
        self.assertEqual(len(revision), 64)
        self.assertEqual(run.call_args.args[0][-1], "refresh-source")
        with patch.object(adapt.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="nginx rejected")):
            diagnostic = {}
            self.assertIsNone(adapt.source_change(args, item, environment, None, diagnostic))
            self.assertEqual(diagnostic["error"], "nginx rejected")

    def test_idle_workers_keep_resident_caches_unless_shrinking_is_opted_in(self):
        target = {"workers": 4, "weight": 4}
        sample = {"utilization": 0, "queue_percent": 0, "memory_percent": 10,
                  "automatic_workers": True, "workers": 4, "workers_min": 1, "workers_max": 8}
        unchanged, _ = adapt.decide({}, {"low": 10}, sample, target)
        self.assertEqual(unchanged, target)
        smaller, _ = adapt.decide({"ADAPTIVE_ALLOW_IDLE_SHRINK": "true"}, {"low": 10}, sample, target)
        self.assertEqual(smaller["workers"], 3)


if __name__ == "__main__":
    unittest.main()
