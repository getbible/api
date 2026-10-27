"""Failures persist through retries; only real successful work can recover them."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_telemetry.collector import Collector
from getbible_telemetry.health import HealthInspector
from getbible_telemetry.service_alerts import ServiceIncidents, main, parse_units, successful
from getbible_telemetry.store import TelemetryStore


UNIT = "getbible-example.service"


def observation(*, state="failed", result="timeout", code="2", status="15", exit_at=100,
                started_at=0, substate=None):
    return {"Id": UNIT, "LoadState": "loaded", "ActiveState": state,
            "SubState": substate or {"failed": "failed", "inactive": "dead", "activating": "start",
                                     "active": "running"}[state],
            "Type": "oneshot", "Result": result, "ExecMainCode": code, "ExecMainStatus": status,
            "ExecMainExitTimestampMonotonic": str(int(exit_at * 1_000_000)),
            "ActiveEnterTimestampMonotonic": str(int(started_at * 1_000_000))}


class ServiceAlertsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.incidents = ServiceIncidents(self.root / "service-alerts")

    def observe(self, values=None, now=100, unit=UNIT, **kwargs):
        return self.incidents.observe(unit, values, now=now, monotonic=now, boot="boot-one", **kwargs)

    def test_immediate_failure_and_reminders_survive_new_process_state(self):
        state, event = self.observe(observation())
        self.assertEqual(event, "onset")
        self.assertIn("result=timeout", state["message"])
        self.incidents = ServiceIncidents(self.root / "service-alerts")
        for now in (205, 310, 415, 1000, 8000):
            self.assertIsNone(self.observe(observation(exit_at=now), now=now)[1])
        self.assertEqual(self.observe(observation(exit_at=86501), now=86501)[1], "reminder")
        self.assertIsNone(self.observe(observation(exit_at=86606), now=86606)[1])

    def test_activating_success_default_is_not_recovery(self):
        self.observe(observation())
        for now in (130, 195, 1000):
            state, event = self.observe(observation(state="activating", result="success", code="0", status="0", exit_at=0), now=now)
            self.assertTrue(state["active"])
            self.assertIsNone(event)

    def test_reset_failed_is_not_successful_execution(self):
        self.observe(observation())
        for now in (130, 195):
            state, event = self.observe(observation(state="inactive", result="success", code="0", status="0"), now=now)
            self.assertTrue(state["active"])
            self.assertIsNone(event)

    def test_completed_oneshot_recovers_once_without_waiting_past_next_timer(self):
        self.observe(observation())
        success = observation(state="inactive", result="success", code="1", status="0", exit_at=160)
        state, event = self.observe(success, now=170)
        self.assertEqual(event, "recovered")
        self.assertFalse(state["active"])
        self.assertIsNone(self.observe(success, now=300)[1])

    def test_missing_sample_breaks_recovery_hold(self):
        self.observe(observation())
        success = observation(state="active", result="success", started_at=150)
        self.observe(success, now=160)
        self.observe(None, now=200)
        self.assertIsNone(self.observe(success, now=230)[1])
        self.assertEqual(self.observe(success, now=291)[1], "recovered")

    def test_new_boot_running_service_can_recover(self):
        self.observe(observation(exit_at=10000), now=10000)
        success = observation(state="active", result="success", started_at=10)
        self.incidents.observe(UNIT, success, now=11000, monotonic=20, boot="boot-two")
        self.assertEqual(self.incidents.observe(UNIT, success, now=11061, monotonic=81, boot="boot-two")[1], "recovered")

    def test_storage_partial_success_does_not_clear_incident(self):
        unit = "getbible-storage.service"
        self.observe(observation(), unit=unit)
        success = observation(state="inactive", result="success", code="1", status="0", exit_at=160)
        success["storage_usage"] = {"generated_at": 50, "completed_at": 90, "max_age_seconds": 900}
        for now in (170, 231):
            self.assertTrue(self.observe(success, unit=unit, now=now)[0]["active"])
        success["storage_usage"] = {"generated_at": 110, "completed_at": 220, "max_age_seconds": 900}
        self.assertEqual(self.observe(success, unit=unit, now=240)[1], "recovered")

    def test_old_or_missing_storage_snapshot_is_not_recovery(self):
        unit = "getbible-storage.service"
        self.observe(observation(), unit=unit)
        success = observation(state="inactive", result="success", code="1", status="0", exit_at=160)
        for now in (170, 231):
            self.assertIsNone(self.observe(success, unit=unit, now=now)[1])
        success["storage_usage"] = {"generated_at": 110, "completed_at": 160, "max_age_seconds": 120}
        for now in (300, 361):
            self.assertIsNone(self.observe(success, unit=unit, now=now)[1])

    def test_inspector_explicitly_checks_tracked_retry_and_completed_units(self):
        self.observe(observation())
        inspector = HealthInspector(incident_directory=self.incidents.directory)
        current = observation(state="activating", result="success", code="0", status="0", exit_at=0)
        def command(*args):
            if args[0] == "show":
                self.assertIn(UNIT, args)
                return "\n".join(f"{key}={value}" for key, value in current.items())
            return ""
        with patch.object(inspector, "_run", side_effect=command):
            sample = inspector.sample(now=200)
        values = sample["conditions"]["service:" + UNIT]["unit_state"]
        self.assertEqual(successful(values), 0)
        self.assertEqual(parse_units("Id=nginx.service\nResult=success\n\nId=not-managed.service\nResult=success"),
                         {"nginx.service": {"Id": "nginx.service", "Result": "success"}})

    def test_collector_deduplicates_onfailure_and_preserves_missing_unit(self):
        self.observe(observation())  # OnFailure already sent the immediate alert.
        with TelemetryStore(self.root / "traffic.sqlite3") as store:
            collector = Collector(store, str(self.root))
            with patch.object(collector, "_notify") as notify:
                for now in (110, 180, 250):
                    collector.health({"services": {"available": True, "conditions": {}, "sampled_at": now,
                                                   "boot_id": "boot-one", "monotonic": now}}, {}, now=now)
                self.assertEqual(notify.call_count, 0)
                alerts = json.loads(store.db.execute("SELECT value FROM metadata WHERE key='health_alerts'").fetchone()[0])
                self.assertTrue(alerts["service:" + UNIT]["active"])

    def test_existing_sqlite_service_incident_is_imported_without_second_alert(self):
        with TelemetryStore(self.root / "traffic.sqlite3") as store:
            store.set_metadata("health_alerts", {"service:" + UNIT: {"active": True, "last_sent": 100, "since": 40}})
            collector = Collector(store, str(self.root))
            with patch.object(collector, "_notify") as notify:
                collector.health({"services": {"available": True, "sampled_at": 200,
                    "conditions": {"service:" + UNIT: {"unhealthy": True, "unit_state": observation()}}}}, {}, now=200)
                self.assertEqual(notify.call_count, 0)
            self.assertTrue(self.incidents.snapshot()[UNIT]["active"])

    def test_alert_template_uses_literal_unit_and_shared_incident_journal(self):
        template = ROOT / "src/systemd/getbible-alert@.service.tmpl"
        result = subprocess.run([sys.executable, str(ROOT / "src/bin/getbible-render"), str(template),
            "PYTHON=/usr/bin/python3", "MANAGEMENT_RELEASE=/opt/getbible/management/current",
            "VAR=/var/lib/getbible", "SYSTEMCTL=/usr/bin/systemctl"], capture_output=True, text=True, check=True)
        self.assertIn("service_alerts.py %i --directory /var/lib/getbible/telemetry/service-alerts", result.stdout)
        self.assertNotIn('"Service failed: %I"', result.stdout)


    def test_onfailure_entry_point_reports_reason_once_without_database(self):
        details = "\n".join(f"{key}={value}" for key, value in observation().items())
        result = subprocess.CompletedProcess([], 0, stdout=details)
        with patch("sys.argv", ["service_alerts.py", UNIT, "--directory", str(self.incidents.directory)]), \
                patch("getbible_telemetry.service_alerts.subprocess.run", return_value=result) as run:
            main()
            self.assertEqual(run.call_count, 2)
            command = run.call_args.args[0]
            self.assertEqual(command[1:3], ["fail", "Service failed: " + UNIT])
            self.assertIn("result=timeout", command[3])
            main()
            self.assertEqual(run.call_count, 3)

    def test_stale_services_sample_cannot_clear_incident(self):
        self.observe(observation())
        with TelemetryStore(self.root / "traffic.sqlite3") as store:
            collector = Collector(store, str(self.root))
            sample = {"services": {"available": True, "sampled_at": 150, "boot_id": "boot-one",
                "conditions": {"service:" + UNIT: {"unhealthy": False,
                    "unit_state": observation(state="inactive", result="success", code="1", status="0", exit_at=140)}}}}
            with patch.object(collector, "_notify") as notify:
                collector.health(sample, {}, now=300)
                self.assertEqual(notify.call_count, 0)
            self.assertTrue(self.incidents.snapshot()[UNIT]["active"])

    def test_cached_previous_invocation_cannot_clear_a_later_failure(self):
        self.observe({**observation(), "InvocationID": "failed-run"})
        old = {**observation(state="inactive", result="success", code="1", status="0", exit_at=50),
               "InvocationID": "previous-success"}
        state, event = self.incidents.observe(UNIT, old, now=120, monotonic=90, boot="boot-one")
        self.assertTrue(state["active"])
        self.assertIsNone(event)

    def test_failure_during_later_health_queries_cannot_be_cleared_by_earlier_success(self):
        self.observe({**observation(exit_at=30), "InvocationID": "first-failure"}, now=30)
        inspector = HealthInspector(incident_directory=self.incidents.directory)
        old = {**observation(state="inactive", result="success", code="1", status="0", exit_at=50),
               "InvocationID": "previous-success"}
        clock = 90

        def command(*args):
            nonlocal clock
            if args[0] == "show":
                return "\n".join(f"{key}={value}" for key, value in old.items())
            if args[0] == "list-timers":
                # OnFailure sees a new failed invocation after the inspector
                # has already read the previous successful execution.
                self.observe({**observation(), "InvocationID": "new-failure"}, now=100)
                clock = 110
            return ""

        with patch.object(inspector, "_run", side_effect=command), \
                patch("getbible_telemetry.health.time.monotonic", side_effect=lambda: clock), \
                patch("getbible_telemetry.health.boot_id", return_value="boot-one"):
            sample = inspector.sample(now=90)
        values = sample["conditions"]["service:" + UNIT]["unit_state"]
        state, event = self.incidents.observe(UNIT, values, now=120, monotonic=sample["monotonic"],
                                              boot=sample["boot_id"])
        self.assertTrue(state["active"])
        self.assertEqual(state["failure_invocation"], "new-failure")
        self.assertIsNone(event)

    def test_legacy_incident_requires_execution_after_import(self):
        old = observation(state="inactive", result="success", code="1", status="0", exit_at=50)
        state, event = self.observe(old, now=100, legacy={"active": True, "last_sent": 40})
        self.assertTrue(state["active"])
        self.assertIsNone(event)
        current = observation(state="inactive", result="success", code="1", status="0", exit_at=110)
        self.assertEqual(self.observe(current, now=120)[1], "recovered")

    def test_fast_restart_after_monitored_failure_is_recognized(self):
        self.observe({**observation(state="active", result="timeout", started_at=99, exit_at=0),
                      "InvocationID": "restarted", "failure_invocation": "failed-run"}, failed=True)
        current = {**observation(state="active", result="success", started_at=99), "InvocationID": "restarted"}
        self.assertIsNone(self.observe(current, now=110)[1])
        self.assertEqual(self.observe(current, now=171)[1], "recovered")


if __name__ == "__main__":
    unittest.main()
