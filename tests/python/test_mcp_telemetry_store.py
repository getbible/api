"""MCP origin counts, protocol facts and collector/dashboard integration."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))
sys.path.insert(0, str(ROOT / "src/apps/dashboard"))

from getbible_dashboard.analytics import Analytics
from getbible_telemetry import TelemetryStore
from getbible_telemetry.catalog import LocalCatalog
from getbible_telemetry.collector import Collector
from getbible_telemetry.health import HealthInspector
from getbible_telemetry.store import SCHEMA_VERSION


class MCPTelemetryStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.registry = self.root / "endpoints"
        directory = self.registry / "mcp.example.test"
        directory.mkdir(parents=True)
        (directory / "endpoint.conf").write_text("TYPE=mcp\nKIND=mcp\nENABLED=true\n")
        self.catalog = LocalCatalog(self.registry, self.root / "data")
        self.database = self.root / "traffic.sqlite3"
        self.store = TelemetryStore(self.database, catalog=self.catalog)
        self.addCleanup(self.store.close)

    def edge(self, request_id="request", **fields):
        return {"time": 100, "request_id": request_id, "uri": "/", "method": "POST",
                "status": 200, "request_time": .05, "bytes": 200, "remote_addr": "192.0.2.1",
                "user_agent": "Example MCP client/2.0", "auth_state": "anonymous", **fields}

    def runtime(self, request_id="request", **fields):
        return {"time": 100, "request_id": request_id, "event": "request", "logger": "getbible.mcp",
                "path": "/", "method": "POST", "status": 200, "duration_ms": 30,
                "endpoint_kind": "mcp", "operation": "call_api_operation", "mcp_method": "tools/call",
                "mcp_tool": "call_api_operation", "mcp_outcome": "success",
                "upstream_service": "query", "upstream_api_version": "v3",
                "upstream_operation": "getScripture", **fields}

    def append(self, entry, source="edge", domain="mcp.example.test"):
        with self.store.db:
            self.store.append(entry, endpoint=domain, source=source,
                              record_key=source + ":" + entry["request_id"])

    def test_runtime_and_edge_join_both_orders_with_protocol_errors_and_one_origin_count(self):
        for runtime_first in (True, False):
            rid = "order-" + str(runtime_first)
            runtime = self.runtime(rid, mcp_outcome="tool_error" if runtime_first else "success")
            edge = self.edge(rid)
            pairs = (("runtime", runtime), ("edge", edge)) if runtime_first else (("edge", edge), ("runtime", runtime))
            for source, record in pairs:
                self.append(record, source)
            self.append(runtime, "runtime")
        report = self.store.summary(0, 200, filters={"endpoint_kind": "mcp"})
        self.assertEqual((report["calls"], report["mcp_requests"], report["mcp_tool_calls"]), (2, 2, 2))
        self.assertEqual((report["errors"], report["mcp_errors"], report["http_errors"]), (1, 1, 0))
        self.assertEqual(report["duration_ms"], 50)
        self.assertEqual(report["runtime_without_edge"], 0)
        self.assertEqual(report["breakdowns"]["mcp_tool"][0]["errors"], 1)
        for row in self.store.requests(0, 200)["items"]:
            self.assertEqual((row["version"], row["upstream_api_version"], row["status"]), ("", "v3", 200))
            self.assertIsNotNone(row["runtime"])
            self.assertIsNotNone(row["edge"])
        self.assertEqual(sum(row["errors"] for row in self.store.series(0, 200)), 1)
        self.assertEqual(len(self.store.requests(0, 200, filters={"successful": "true"})["items"]), 1)

    def test_edge_only_rejections_and_robots_belong_to_root_mcp_without_versions(self):
        for number, (path, status) in enumerate((("/", 401), ("/robots.txt", 404), ("/v3/kjv.json", 404), ("/healthz", 200))):
            self.append(self.edge(str(number), uri=path, status=status, user_agent="ExampleRobot/1.0"))
        report = self.store.summary(0, 200, filters={"endpoint_kind": "mcp"})
        self.assertEqual((report["calls"], report["mcp_errors"]), (4, 3))
        self.assertEqual(report["breakdowns"]["user_agent"][0]["value"], "ExampleRobot/1.0")
        self.assertEqual(report["breakdowns"]["translation"], [])
        self.assertEqual(report["breakdowns"]["reference"], [])
        for row in self.store.requests(0, 200)["items"]:
            self.assertEqual((row["endpoint_kind"], row["version"], row["operation"]), ("mcp", "", "http"))
        self.assertEqual(self.store.endpoints()[0]["endpoint_kind"], "mcp")
        self.assertFalse((self.registry / "mcp.example.test/versions").exists())

    def test_protocol_client_and_upstream_rankings_keep_exact_drilldown_filters(self):
        self.append(self.edge("initialize"))
        self.append(self.runtime("initialize", operation="initialize", mcp_method="initialize", mcp_tool="",
                                 mcp_client_name="Example Desktop", mcp_client_version="7.2"), "runtime")
        self.append(self.edge("tool"))
        self.append(self.runtime("tool"), "runtime")
        for dimension in ("mcp_method", "mcp_tool", "mcp_client_name", "mcp_client_version",
                          "mcp_outcome", "upstream_service", "upstream_api_version", "upstream_operation"):
            rows = self.store.breakdown(dimension, 0, 200)
            self.assertTrue(rows)
            for row in rows:
                detail = self.store.requests(0, 200, filters=row["filters"])["items"]
                self.assertEqual(len(detail), row["calls"])
                self.assertTrue(all(item[dimension] == row["value"] for item in detail))
        self.assertEqual(len(self.store.requests(0, 200, filters={"q": "EXAMPLE DESKTOP"})["items"]), 1)
        self.assertEqual(self.store.requests(0, 200, filters={"mcp_tool": "' OR 1=1 --"})["items"], [])

    def test_upstream_search_records_cannot_be_counted_as_mcp_interactions(self):
        self.append(self.edge())
        self.append(self.runtime(upstream_service="search", upstream_operation="search"), "runtime")
        self.append(self.edge(uri="/v3/kjv/love"), domain="search.example.test")
        self.append(self.runtime(path="/v3/kjv/love", logger="getbible.search", endpoint_kind="search",
                                 operation="search", version="v3", translation="kjv", search="love"),
                    "runtime", domain="search.example.test")
        self.assertEqual(self.store.summary(0, 200, filters={"endpoint_kind": "mcp"})["calls"], 1)
        search = self.store.summary(0, 200, filters={"endpoint_kind": "search"})
        self.assertEqual(search["calls"], 1)
        self.assertEqual(search["breakdowns"]["search"][0]["value"], "love")
        self.assertEqual(search["breakdowns"]["mcp_method"], [])
        self.assertEqual(self.store.summary(0, 200)["breakdowns"]["upstream_service"][0]["calls"], 1)

    def test_collector_reads_spools_once_and_retains_safe_metadata_in_current_schema(self):
        log_root = self.root / "log"
        domain = log_root / "mcp.example.test"
        (domain / "app").mkdir(parents=True)
        (domain / "access.log").write_text(json.dumps(self.edge()) + "\n")
        (domain / "app/mcp-generation.log").write_text(json.dumps(self.runtime(
            mcp_client_name="Example client", authorization="secret-value",
            mcp_client_version="Bearer private-token")) + "\n")
        collector = Collector(self.store, str(log_root))
        self.assertEqual({source for _, _, source, _ in collector.files()}, {"edge", "runtime"})
        for path, endpoint, source, rotated in collector.files():
            self.assertEqual(collector.ingest_file(path, endpoint, source, rotated=rotated), 1)
            self.assertEqual(collector.ingest_file(path, endpoint, source, rotated=rotated), 0)
        self.assertEqual(self.store.summary(0, 200)["calls"], 1)
        self.assertEqual(self.store.db.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
        encoded = json.dumps(self.store.requests(0, 200))
        self.assertNotIn("secret-value", encoded)
        self.assertNotIn("private-token", encoded)
        self.assertIn("Example client", encoded)

    def test_mcp_report_keeps_service_scope_and_selected_filters(self):
        self.append(self.edge())
        self.append(self.runtime(mcp_outcome="protocol_error"), "runtime")
        self.append(self.edge("another", uri="/v3/kjv.json"), domain="api.example.test")
        analytics = Analytics(self.database)
        report = analytics.report("mcp", {"start": "0", "end": "200"})
        self.assertEqual((report["calls"], report["mcp_errors"], report["series"][0]["calls"]), (1, 1, 1))
        self.assertEqual(report["filters"]["endpoint_kind"], "mcp")
        self.assertEqual(analytics.report("mcp", {"start": "0", "end": "200", "mcp_tool": "missing"})["calls"], 0)
        with self.assertRaises(ValueError):
            analytics.report("mcp", {"start": "0", "end": "200", "endpoint_kind": "search"})

    def test_runtime_without_edge_is_visible_without_inflating_origin_counts(self):
        self.append(self.runtime(), "runtime")
        report = self.store.summary(0, 200, filters={"endpoint_kind": "mcp"})
        self.assertEqual((report["calls"], report["runtime_without_edge"]), (0, 1))
        self.assertEqual(self.store.requests(0, 200)["items"][0]["mcp_tool"], "call_api_operation")

    def test_unknown_outcome_is_neither_relabelled_success_nor_counted_as_error(self):
        self.append(self.edge())
        self.append(self.runtime(mcp_outcome="unknown"), "runtime")
        report = self.store.summary(0, 200, filters={"endpoint_kind": "mcp"})
        self.assertEqual(report["mcp_errors"], 0)
        self.assertEqual(report["breakdowns"]["mcp_outcome"][0]["value"], "unknown")
        self.assertFalse(self.store.requests(0, 200)["items"][0]["mcp_error"])

    def test_mcp_unit_failure_uses_existing_managed_service_health_reporting(self):
        inspector = HealthInspector()
        unit = "getbible-mcp-mcp_example_test-generation.service"
        with patch.object(inspector, "_run", side_effect=lambda *args: f"{unit} loaded failed failed MCP\n" if args[0] == "list-units" else ""):
            self.assertTrue(inspector.sample(now=100)["conditions"]["service:" + unit]["unhealthy"])


if __name__ == "__main__":
    unittest.main()
