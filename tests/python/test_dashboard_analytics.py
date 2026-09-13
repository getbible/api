"""Dashboard reports consume the same persisted records as the collector."""

from dataclasses import replace
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/dashboard"))
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_dashboard.analytics import Analytics, query_range
from getbible_dashboard.auth import AuthStore
from getbible_dashboard.config import Config
from getbible_dashboard.server import Dashboard
from getbible_telemetry import TelemetryStore
from tests.python.test_dashboard_auth import FakeTelegram


class AnalyticsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "traffic.sqlite3"
        with TelemetryStore(self.path) as store:
            store.append({"time": 1700000001, "request_id": "one", "method": "GET",
                          "uri": "/v2/?reference=John%203%3A16", "status": 200,
                          "request_time": 0.015, "bytes": 100, "remote_addr": "192.0.2.1",
                          "auth": "anonymous"}, endpoint="query.example.test", source="edge", record_key="e1")
            store.append({"time": 1700000001, "request_id": "one", "event": "request",
                          "method": "GET", "path": "/v2/", "status": 200, "version": "v2",
                          "translation": "kjv", "reference": "John 3:16", "duration_ms": 15,
                          "operation": "scripture", "endpoint_kind": "query"},
                         endpoint="query.example.test", source="runtime", record_key="r1")
            store.append_metric({"cpu": {"usage_percent": 10}, "memory": {"current_bytes": 1024}}, stamp=1700000002)
            store.db.commit()
        self.analytics = Analytics(self.path)
        self.query = {"start": "1700000000", "end": "1700000100"}

    def test_overview_merges_runtime_edge_without_double_counting(self):
        result = self.analytics.report("overview", self.query)
        self.assertEqual(result["calls"], 1)
        self.assertTrue(result["origin_only"])
        self.assertEqual(result["latest_metrics"]["memory"]["current_bytes"], 1024)
        self.assertEqual(result["breakdowns"]["translation"][0]["value"], "kjv")

    def test_request_details_preserve_semantics_and_filter(self):
        result = self.analytics.report("requests", {**self.query, "translation": "kjv"})
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["runtime"]["reference"], "John 3:16")
        self.assertEqual(self.analytics.report("requests", {**self.query, "translation": "missing"})["items"], [])

    def test_time_series_and_retention_storage_share_database(self):
        result = self.analytics.report("history", {**self.query, "bucket_seconds": "1"})
        self.assertEqual(result["series"][0]["calls"], 1)
        self.assertEqual(len(result["metrics"]), 1)
        self.assertGreater(self.analytics.report("storage", self.query)["bytes"], 0)

    def test_large_history_uses_bounded_buckets_and_rejects_invalid_ranges(self):
        result = self.analytics.report("history", {"start": "1600000000", "end": "1700000000", "bucket_seconds": "1"})
        self.assertGreaterEqual(result["bucket_seconds"], 50000)
        for query in ({"start": "nan", "end": "1700000000"},
                      {"start": "1700000001", "end": "1700000000"},
                      {"start": "2024-01-01T00:00:00", "end": "2024-01-02T00:00:00Z"}):
            with self.assertRaises(ValueError):
                query_range(query)

    def test_audience_ranks_distinct_fields_and_keeps_filters(self):
        with TelemetryStore(self.path) as store:
            store.append({"time": 1700000001, "request_id": "audience", "method": "GET", "uri": "/robots.txt",
                          "status": 404, "referer": "https://reader.example/page", "user_agent": "Robot Test"},
                         endpoint="query.example.test", source="edge", record_key="audience")
            store.db.commit()
        result = self.analytics.report("audience", {**self.query, "q": "robot", "top": "1000"})
        self.assertEqual(result["referrers"][0]["value"], "https://reader.example/page")
        agent = result["user_agents"][0]
        self.assertEqual(agent["value"], "Robot Test")
        self.assertEqual(len(self.analytics.report("requests", {**self.query, **agent["filters"]})["items"]), agent["calls"])
        with self.assertRaises(ValueError):
            self.analytics.report("audience", {**self.query, "top": "1001"})


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)

    def test_generated_config_paths_and_bounds_are_honored(self):
        file = self.path / "dashboard.conf"
        file.write_text("DASHBOARD_ENABLED=true\nDASHBOARD_DOMAIN=admin.example.test\n"
                        "TELEMETRY_DB=/data/traffic.sqlite3\nBROKER_SOCKET=/run/admin.sock\n"
                        "DASHBOARD_TOKEN_SECONDS=45\nDASHBOARD_IDLE_SECONDS=90\nDASHBOARD_SESSION_DAYS=14\n")
        config = Config.load(file)
        self.assertEqual(config.telemetry_db, "/data/traffic.sqlite3")
        self.assertEqual(config.broker_socket, "/run/admin.sock")
        self.assertEqual((config.token_seconds, config.idle_seconds, config.session_seconds), (45, 90, 14 * 86400))
        file.write_text("DASHBOARD_DOMAIN=https://bad.example/path\n")
        with self.assertRaises(ValueError):
            Config.load(file)
        file.write_text("DASHBOARD_TOKEN_SECONDS=61\n")
        with self.assertRaises(ValueError):
            Config.load(file)

    def test_reload_preserves_sessions_and_updates_future_lifetimes(self):
        config = Config(domain="old.example.test", enabled=True, state_dir=str(self.path))
        auth = AuthStore(self.path)
        auth.set_password("A sufficiently long password")
        telegram = FakeTelegram()
        challenge = auth.start_challenge("192.0.2.1", "A sufficiently long password", telegram)
        login = auth.finish_challenge("192.0.2.1", challenge["challenge_id"], telegram.codes[-1][0])
        app = Dashboard(config, auth=auth, telegram=telegram)
        self.addCleanup(app.close)
        app.reconfigure(replace(config, domain="new.example.test", token_seconds=45, idle_seconds=90))
        self.assertEqual(app.config.domain, "new.example.test")
        self.assertEqual(app.auth.token_seconds, 45)
        self.assertEqual(app.lifecycle.idle_seconds, 90)
        self.assertEqual(app.auth.session(login["token"], "192.0.2.1")["id"], login["session_id"])
        with self.assertRaises(ValueError):
            app.reconfigure(replace(config, state_dir="/elsewhere"))


if __name__ == "__main__":
    unittest.main()
