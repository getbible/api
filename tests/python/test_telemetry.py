"""Telemetry persistence, privacy, retention and request-join acceptance tests."""

from __future__ import annotations

import json
import contextlib
import io
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_telemetry import TelemetryStore
from getbible_telemetry.collector import Collector
from getbible_telemetry.collector import read_settings
from getbible_telemetry.health import HealthInspector
from getbible_telemetry.metrics import MetricsSampler
from getbible_telemetry.producer import emit_event
from getbible_telemetry.cli import main
from getbible_telemetry.settings import numeric_setting


def edge(request_id="r1", **changes):
    value = {"time": 100, "request_id": request_id, "endpoint": "bible.test", "method": "GET",
             "uri": "/v2/kjv/43/3.json", "status": 200, "request_time": .01, "bytes": 100,
             "remote_addr": "2001:db8::1", "token": "", "auth_state": "anonymous", "cache": "HIT"}
    value.update(changes)
    return value


class TelemetryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = TelemetryStore(self.root / "traffic.sqlite3")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def append(self, entry, source="edge", endpoint="bible.test"):
        with self.store.db:
            self.store.append(entry, endpoint=endpoint, source=source, record_key="record-" + str(entry.get("request_id", "-")))

    def test_edge_runtime_join_both_orders_and_retry(self):
        for source_order in (("runtime", "edge"), ("edge", "runtime")):
            rid = "-".join(source_order)
            runtime = edge(rid, event="request", translation="kjv", reference="John 3:16",
                           duration_ms=7, criteria={"words": "love"}, status=201, operation="scripture", endpoint_kind="query")
            for source in source_order:
                self.append(runtime if source == "runtime" else edge(rid), source=source)
            self.append(edge(rid))
        report = self.store.summary(0, 200)
        self.assertEqual(report["calls"], 2)
        self.assertEqual(report["duration_ms"], 10)
        self.assertEqual(report["breakdowns"]["reference"][0]["value"], "John 3:16")
        for row in self.store.requests(0, 200)["items"]:
            self.assertIsNotNone(row["edge"])
            self.assertEqual(row["runtime"]["criteria"], {"words": "love"})
            self.assertEqual(row["status"], 200)

    def test_orphans_are_visible_without_counting_as_origin(self):
        self.append(edge("runtime", event="request"), source="runtime")
        self.assertEqual(self.store.summary(0, 200)["calls"], 0)
        self.assertEqual(self.store.summary(0, 200)["runtime_without_edge"], 1)
        self.assertEqual(len(self.store.requests(0, 200)["items"]), 1)

    def test_same_id_on_different_domains_does_not_merge(self):
        self.append(edge(), endpoint="a.test")
        self.append(edge(), endpoint="b.test")
        self.assertEqual(self.store.summary(0, 200)["calls"], 2)
        self.assertEqual(len(self.store.endpoints()), 2)

    def test_static_translation_rankings_include_full_books_and_chapters(self):
        paths = ["/v2/kjv.json", "/v2/kjv/43.json", "/v2/kjv/43/3.json",
                 "/v3/asv.json", "/kjv.json", "/kjv/1/1.json"]
        for index, path in enumerate(paths):
            self.append(edge(str(index), uri=path))
        ranking = self.store.summary(0, 200)["breakdowns"]["translation"]
        self.assertEqual({row["value"]: row["calls"] for row in ranking}, {"kjv": 5, "asv": 1})
        rows = self.store.requests(0, 200, filters={"translation": "kjv"})["items"]
        self.assertEqual({row["path"] for row in rows}, set(paths) - {"/v3/asv.json"})
        self.assertEqual(self.store.summary(0, 200, filters={"book": "43"})["calls"], 2)
        self.assertEqual(self.store.summary(0, 200, filters={"version": "v3"})["calls"], 1)

    def test_static_discovery_metadata_and_runtime_paths_are_not_translations(self):
        paths = ["/versions.json", "/v2/translations.json", "/v2/openapi.json",
                 "/v2/index.json", "/v2/metadata.json",
                 "/v2/search/1.json", "/v2/query/1/1.json",
                 "/v2/search", "/healthz", "/v2/kjv/43/3.json/extra",
                 "/v2/kjv.json/43.json", "/v2/kjv/zero.json"]
        for index, path in enumerate(paths):
            self.append(edge(str(index), uri=path))
        rows = self.store.requests(0, 200)["items"]
        self.assertEqual({row["path"] for row in rows}, set(paths))
        self.assertTrue(all(not row["translation"] and not row["book"] for row in rows))
        self.assertEqual(self.store.summary(0, 200)["calls"], len(paths))

    def test_secrets_redacted_rich_fields_retained(self):
        self.append(edge(uri="/v2/kjv.json?token=secret-1&q=love", auth_state="rejected",
                         user_agent="Bearer secret-2", authorization="secret-3", password="secret-4",
                         cookie="secret-5", search="love", criteria={"secret": "secret-6", "exact": True}))
        encoded = json.dumps(self.store.requests(0, 200))
        for index in range(1, 7):
            self.assertNotIn("secret-" + str(index), encoded)
        self.assertIn("love", encoded)
        self.assertIn("rejected", encoded)
        self.assertIn("2001:db8::1", encoded)

    def test_sql_injection_filters_rejected_or_bound(self):
        self.append(edge())
        with self.assertRaises(ValueError):
            self.store.breakdown("endpoint); DROP TABLE requests; --", 0, 200)
        self.assertEqual(self.store.summary(0, 200, filters={"ip": "' OR 1=1 --"})["calls"], 0)
        self.assertEqual(self.store.summary(0, 200)["calls"], 1)

    def test_pagination_no_overlap_and_half_open_ranges(self):
        for index in range(10):
            self.append(edge(str(index), time=index))
        first = self.store.requests(2, 8, limit=3)
        second = self.store.requests(2, 8, limit=3, cursor=first["next_cursor"])
        self.assertEqual([r["stamp"] for r in first["items"] + second["items"]], [7, 6, 5, 4, 3, 2])
        self.assertEqual(sum(row["calls"] for row in self.store.series(2, 8, 2)), 6)

    def test_readonly_connection_cannot_mutate(self):
        self.append(edge())
        with TelemetryStore(self.store.path, readonly=True) as reader:
            with self.assertRaises(sqlite3.OperationalError):
                reader.db.execute("DELETE FROM requests")
            self.assertEqual(reader.summary(0, 200)["calls"], 1)

    def test_oldest_retention_preserves_newest_and_records_gap(self):
        self.append(edge("old", time=1))
        self.append(edge("new", time=200000))
        result = self.store.prune(max_bytes=1024**2, retention_days=1, now=200001)
        self.assertEqual(result["deleted"]["requests"], 1)
        self.assertEqual(self.store.requests(0, 300000)["items"][0]["request_id"], "new")
        self.assertEqual(self.store.storage()["retention_events"][0]["request_rows"], 1)

    def test_size_pruning_reuses_pages_and_preserves_recent_row(self):
        with self.store.db:
            for index in range(250):
                self.store.append(edge(str(index), time=index + 1, user_agent="x" * 8192), endpoint="bible.test", source="edge", record_key=str(index))
        result = self.store.prune(max_bytes=1024**2, retention_days=180, now=1000)
        self.assertGreater(result["deleted"]["requests"], 0)
        self.assertLessEqual(self.store.storage()["active_bytes"], 1024**2)
        self.assertLessEqual(self.store.storage()["bytes"], 1024**2)
        self.assertEqual(self.store.requests(0, 1000)["items"][0]["request_id"], "249")
        self.assertTrue(self.store.storage()["retention_events"])

    def test_zero_retention_disables_age_but_keeps_oldest_first_size_pruning(self):
        self.append(edge("old", time=1))
        result = self.store.prune(max_bytes=1024**2, retention_days=0, now=10**10)
        self.assertEqual(result["deleted"]["requests"], 0)
        with self.store.db:
            for index in range(250):
                self.store.append(edge(str(index), time=index + 2, user_agent="x" * 8192),
                                  endpoint="bible.test", source="edge", record_key=str(index))
        result = self.store.prune(max_bytes=1024**2, retention_days=0, now=10**10)
        self.assertGreater(result["deleted"]["requests"], 0)
        rows = self.store.requests(0, 1000)["items"]
        self.assertEqual(rows[0]["request_id"], "249")
        self.assertNotIn("old", [row["request_id"] for row in rows])
        self.assertEqual(self.store.storage()["retention_events"][0]["reason"], "size")

    def test_startup_and_reload_share_strict_numeric_contract(self):
        path = self.root / "telemetry.env"
        options = {"RETENTION_DAYS": "--retention-days", "MAX_GIB": "--max-gib",
                   "BATCH_SIZE": "--batch-size", "FLUSH_SECONDS": "--flush-seconds"}
        for key, option in options.items():
            for value in ("nan", "inf", "Infinity", "1.5", "1.0", "-1", "100000000000"):
                with self.subTest(key=key, value=value):
                    path.write_text(f"GETBIBLE_TELEMETRY_{key}={value}\n")
                    with self.assertRaises(ValueError):
                        read_settings(str(path))
                    with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                        main(["collect", "--once", option, value])
                    self.assertEqual(raised.exception.code, 2)
        path.write_text("GETBIBLE_TELEMETRY_RETENTION_DAYS=000000\nGETBIBLE_TELEMETRY_BATCH_SIZE=100000\n")
        self.assertEqual(read_settings(str(path)), {"TELEMETRY_RETENTION_DAYS": 0, "TELEMETRY_BATCH_SIZE": 100000})
        with self.assertRaises(ValueError):
            Collector(self.store, str(self.root), batch_size=100001)
        with self.assertRaises(ValueError):
            numeric_setting("ALERT_CPU_PERCENT", 96)
        with patch("getbible_telemetry.cli.TelemetryStore") as storage, patch("getbible_telemetry.cli.Collector") as collector:
            main(["collect", "--once", "--retention-days", "0", "--batch-size", "100000", "--no-journal"])
            self.assertEqual(collector.call_args.kwargs["batch_size"], 100000)
            self.assertEqual(collector.return_value.run.call_args.kwargs["retention_days"], 0)
            storage.assert_called_once()

    def test_alert_environment_without_settings_file_is_honored(self):
        with patch.dict(os.environ, {"GETBIBLE_ALERT_HOLD_SECONDS": "7", "GETBIBLE_ALERT_CPU_PERCENT": "81"}):
            collector = Collector(self.store, str(self.root))
        self.assertEqual(collector.alert_settings["ALERT_HOLD_SECONDS"], 7)
        self.assertEqual(collector.alert_settings["ALERT_CPU_PERCENT"], 81)

    def test_flush_deadline_preserves_one_second_metrics_and_shutdown_ticks(self):
        collector = Collector(self.store, str(self.root))
        clock, ingested, metrics, sleeps = [0.0], [], [], []
        def sleep(delay):
            sleeps.append(delay)
            clock[0] += delay
            if clock[0] >= 7:
                collector.running = False
        def ingest(*_args, **_kwargs):
            ingested.append(clock[0])
            return 0
        def sample():
            metrics.append(clock[0])
            return {}
        with patch("getbible_telemetry.collector.time.monotonic", side_effect=lambda: clock[0]), \
                patch("getbible_telemetry.collector.time.sleep", side_effect=sleep), \
                patch("getbible_telemetry.collector.MetricsSampler") as sampler, \
                patch("getbible_telemetry.collector.HealthInspector") as inspector, \
                patch.object(collector, "files", return_value=[(self.root / "access.log", "bible.test", "edge", False)]), \
                patch.object(collector, "ingest_file", side_effect=ingest), \
                patch.object(collector, "rotate"), patch.object(collector, "cleanup"), \
                patch.object(collector, "state", return_value={}), patch.object(collector, "health"), \
                patch.object(self.store, "prune", return_value={}):
            sampler.return_value.sample.side_effect = sample
            inspector.return_value.current.return_value = {}
            collector.run(flush_seconds=3, metrics_seconds=1, retention_days=0, journal=False)
        self.assertEqual(ingested, [0, 3, 6])
        self.assertEqual(metrics, list(range(7)))
        self.assertTrue(all(0 < delay <= 1 for delay in sleeps))

    def test_reload_zero_retention_reaches_pruner_without_resetting_other_settings(self):
        path = self.root / "telemetry.env"
        path.write_text("GETBIBLE_TELEMETRY_RETENTION_DAYS=0\nGETBIBLE_TELEMETRY_FLUSH_SECONDS=3\n")
        collector = Collector(self.store, str(self.root))
        with patch.object(self.store, "prune", return_value={}) as prune, \
                patch("getbible_telemetry.collector.HealthInspector") as inspector:
            inspector.return_value.current.return_value = {}
            collector.run(once=True, journal=False, settings=str(path))
        self.assertEqual(prune.call_args.kwargs["retention_days"], 0)
        self.assertNotIn("settings_error", self.store.storage()["metadata"])

    def test_partial_line_cursor_commit_and_restart(self):
        path = self.root / "logs/bible.test/access.log"
        path.parent.mkdir(parents=True)
        raw = json.dumps(edge()).encode()
        path.write_bytes(raw[:40])
        collector = Collector(self.store, str(self.root / "logs"))
        self.assertEqual(collector.ingest_file(path, "bible.test", "edge"), 0)
        with path.open("ab") as handle:
            handle.write(raw[40:] + b"\n")
        self.assertEqual(collector.ingest_file(path, "bible.test", "edge"), 1)
        self.store.close()
        self.store = TelemetryStore(self.root / "traffic.sqlite3")
        collector = Collector(self.store, str(self.root / "logs"))
        self.assertEqual(collector.ingest_file(path, "bible.test", "edge"), 0)
        self.assertEqual(self.store.summary(0, 200)["calls"], 1)

    def test_transaction_failure_does_not_advance_cursor(self):
        path = self.root / "access.log"
        path.write_text(json.dumps(edge()) + "\n")
        collector = Collector(self.store, str(self.root))
        with patch.object(self.store, "append", side_effect=sqlite3.OperationalError("disk full")):
            with self.assertRaises(sqlite3.OperationalError):
                collector.ingest_file(path, "bible.test", "edge")
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM sources").fetchone()[0], 0)
        self.assertEqual(collector.ingest_file(path, "bible.test", "edge"), 1)

    def test_truncation_is_reported_and_new_records_ingested(self):
        path = self.root / "access.log"
        path.write_text(json.dumps(edge("old")) + "\n")
        collector = Collector(self.store, str(self.root))
        collector.ingest_file(path, "bible.test", "edge")
        path.write_text(json.dumps(edge("new")) + "\n")
        collector.ingest_file(path, "bible.test", "edge")
        self.assertEqual(self.store.summary(0, 200)["calls"], 2)
        self.assertEqual(self.store.storage()["retention_events"][0]["reason"], "source_replaced_or_truncated")

    def test_oversized_spool_is_preserved_and_exposed(self):
        path = self.root / "access.log"
        path.write_bytes(b"x" * 2048 + b"\n")
        collector = Collector(self.store, str(self.root), max_line_bytes=1024)
        collector.ingest_file(path, "bible.test", "edge")
        self.assertTrue(path.exists())
        self.assertEqual(self.store.db.execute("SELECT offset FROM sources").fetchone()[0], 0)
        self.assertTrue(any(key.startswith("blocked_source:") for key in self.store.storage()["metadata"]))

    def test_closed_spool_deleted_only_after_commit_and_no_open_writer(self):
        path = self.root / "logs/bible.test/archive/access.log-1.spool"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(edge()) + "\n")
        collector = Collector(self.store, str(self.root / "logs"))
        self.assertEqual(collector.cleanup(), 0)
        collector.ingest_file(path, "bible.test", "edge", rotated=True)
        collector.cleanup()
        with patch("getbible_telemetry.collector.time.monotonic", return_value=10**12), patch.object(collector, "_open_in_process", return_value=True):
            self.assertEqual(collector.cleanup(), 0)
        with patch("getbible_telemetry.collector.time.monotonic", return_value=2*10**12), patch.object(collector, "_open_in_process", return_value=False):
            self.assertEqual(collector.cleanup(), 1)
        self.assertFalse(path.exists())
        self.assertEqual(self.store.summary(0, 200)["calls"], 1)

    def test_malformed_logs_are_preserved_as_diagnostics(self):
        path = self.root / "access.log"
        path.write_text("bad request token=topsecret\n")
        collector = Collector(self.store, str(self.root))
        collector.ingest_file(path, "bible.test", "edge")
        rows = self.store.events(0, 10**12)["items"]
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["payload"]["malformed"])
        self.assertNotIn("topsecret", json.dumps(rows))

    def test_alerts_require_sustained_pressure_and_emit_one_recovery(self):
        collector = Collector(self.store, str(self.root))
        sample = {"memory": {"used_fraction": .95}}
        with patch.object(collector, "_notify") as notify:
            collector.health(sample, {}, now=1000)
            collector.health(sample, {}, now=1030)
            self.assertEqual(notify.call_count, 0)
            collector.health(sample, {}, now=1061)
            self.assertEqual(notify.call_count, 1)
            collector.health(sample, {}, now=1070)
            self.assertEqual(notify.call_count, 1)
            collector.health({}, {}, now=1080)
            collector.health({}, {}, now=1090)
            self.assertEqual(notify.call_count, 2)

    def test_missing_sensors_remain_unavailable(self):
        sampler = MetricsSampler(cgroup_root=str(self.root), proc_root=str(self.root), thermal_root=str(self.root))
        data = sampler.sample()
        self.assertFalse(data["temperature_available"])
        self.assertIsNone(data["temperatures"])
        self.assertIsNone(data["memory"]["current_bytes"])
        self.assertIsNone(data["cpu"]["used_fraction"])

    def test_producer_surfaces_missing_audit_directory(self):
        with self.assertRaises(FileNotFoundError):
            emit_event("security", {"password": "secret"}, path=str(self.root / "missing/app.log"))

    def test_settings_are_data_not_shell_and_validate_before_return(self):
        path = self.root / "telemetry.env"
        path.write_text("GETBIBLE_TELEMETRY_MAX_GIB=4\nGETBIBLE_ALERT_CPU_PERCENT='87'\n")
        self.assertEqual(read_settings(str(path))["ALERT_CPU_PERCENT"], 87)
        path.write_text("GETBIBLE_TELEMETRY_MAX_GIB=$(touch /tmp/should-not-exist)\n")
        with self.assertRaises(ValueError):
            read_settings(str(path))

    def test_resolved_books_count_each_book_in_a_multi_book_query(self):
        self.append(edge(books=[43, 45]))
        data = self.store.breakdown("book", 0, 200)
        self.assertEqual({r["value"] for r in data}, {"43", "45"})
        self.assertEqual(self.store.summary(0, 200, filters={"book": 43, "path": "/v2/kjv/43/3.json"})["calls"], 1)

    def test_monthly_sync_uses_successful_check_not_publication_age(self):
        due = 1780272000  # 2026-06-01 UTC
        state = self.root / "sync/state"
        state.mkdir(parents=True)
        path = state / "v2.conf"
        path.write_text("LAST_SYNC=2020-01-01T00:00:00Z\nLAST_CHECK=2026-06-01T00:00:01Z\n")
        inspector = HealthInspector()
        def command(*args):
            if args[0] == "list-units":
                return ""
            if args[0] == "list-timers":
                return "next last getbible-sync-bible_test-v2.timer getbible-sync-bible_test-v2.service\n"
            if "--property=LastTriggerUSec" in args:
                return "Mon 2026-06-01 00:00:00 UTC\n"
            return f'GB_SYNC_HOME={self.root}/sync GB_SYNC_VERSION=v2 GB_SYNC_DOMAIN=bible.test'
        with patch.object(inspector, "_run", side_effect=command):
            data = inspector.sample(now=due+7200)
            self.assertFalse(data["syncs"][0]["stale"])
            path.write_text("LAST_CHECK=2026-05-01T00:00:00Z\n")
            data = inspector.sample(now=due+7300)
            self.assertTrue(data["syncs"][0]["stale"])


if __name__ == "__main__":
    unittest.main()
