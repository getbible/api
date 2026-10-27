"""Shared service incidents for systemd OnFailure and telemetry health checks.

Keep the small incident journal independent of the reporting database: a failed
collector or database must still produce one immediate, actionable notification.
Updates are locked and atomic; Telegram delivery never holds the state lock.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from typing import Any


UNIT = re.compile(r"(?:getbible-[A-Za-z0-9_.@-]+|nginx)\.service")
PROPERTIES = ("Id", "LoadState", "ActiveState", "SubState", "Type", "Result",
              "ExecMainCode", "ExecMainStatus", "ExecMainExitTimestampMonotonic",
              "ActiveEnterTimestampMonotonic", "InvocationID")


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def parse_units(text: str) -> dict[str, dict[str, str]]:
    result = {}
    for block in text.strip().split("\n\n"):
        values = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        if UNIT.fullmatch(values.get("Id", "")):
            result[values["Id"]] = values
    return result


def failure_message(unit: str, values: dict[str, Any]) -> str:
    result = values.get("Result") or "unknown"
    status = values.get("ExecMainStatus", "unknown")
    return (f"{unit}: result={result}, exit status={status}, "
            f"state={values.get('ActiveState', 'unknown')}/{values.get('SubState', 'unknown')}. "
            f"Inspect journalctl -u {unit} --since '1 hour ago'.")


def successful(values: dict[str, Any]) -> float:
    """Return the kernel monotonic timestamp of proven successful execution."""
    if values.get("LoadState") != "loaded" or values.get("Result") != "success":
        return 0
    state = values.get("ActiveState")
    if state == "active" and values.get("SubState") == "running":
        stamp = values.get("ActiveEnterTimestampMonotonic", "0")
    elif (state in {"inactive", "active"} and values.get("SubState") in {"dead", "exited"}
          and values.get("ExecMainCode") == "1" and values.get("ExecMainStatus") == "0"):
        stamp = values.get("ExecMainExitTimestampMonotonic", "0")
    else:
        return 0  # Retrying, reset-failed, stopped-before-start and missing units.
    try:
        return max(0, int(stamp)) / 1_000_000
    except (ValueError, TypeError):
        return 0


class ServiceIncidents:
    def __init__(self, directory: str | Path) -> None:
        self.directory = Path(directory)

    def snapshot(self) -> dict[str, dict[str, Any]]:
        result = {}
        for path in self.directory.glob("*.json"):
            if UNIT.fullmatch(path.stem):
                state = json.loads(path.read_text())
                if not isinstance(state, dict):
                    raise ValueError("Invalid service incident: " + path.name)
                result[path.stem] = state
        return result

    def observe(self, unit: str, values: dict[str, Any] | None, *, now: float,
                monotonic: float, boot: str, failed: bool = False, hold: float = 60,
                reminder: float = 86400, cooldown: float = 900,
                legacy: dict[str, Any] | None = None) -> tuple[dict[str, Any], str | None]:
        if not UNIT.fullmatch(unit):
            raise ValueError("Not a managed service unit")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = self.directory / (unit + ".json")
        with (self.directory / (unit + ".lock")).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                state = json.loads(path.read_text())
            except FileNotFoundError:
                # Older telemetry incidents lack execution identity. Require a
                # new successful run rather than accepting a historical exit
                # retained by reset-failed or a dependency/start-limit failure.
                active_legacy = bool((legacy or {}).get("active"))
                state = {**(legacy or {}), "boot_id": boot,
                         "failure_monotonic": monotonic if active_legacy else 0}
                if active_legacy:
                    state["failed_at"] = now
            if not isinstance(state, dict):
                raise ValueError("Invalid service incident: " + path.name)
            original = json.dumps(state, sort_keys=True)
            state.setdefault("active", False)
            event = None
            values = values or {}
            if failed or values.get("ActiveState") == "failed":
                first = not state["active"]
                state.update(active=True, clear_since=None, observed_at=now)
                if values or not state.get("message"):
                    state["message"] = failure_message(unit, values)
                try:
                    failure_stamp = int(values.get("ExecMainExitTimestampMonotonic", "0")) / 1_000_000
                except (ValueError, TypeError):
                    failure_stamp = 0
                if first or state.get("boot_id") != boot or failure_stamp > state.get("failure_monotonic", 0):
                    state.update(boot_id=boot, failure_monotonic=failure_stamp or monotonic,
                                 failed_at=now)
                    if values.get("failure_invocation") or values.get("InvocationID"):
                        state["failure_invocation"] = values.get("failure_invocation") or values["InvocationID"]
                if first:
                    state.update(since=now, episodes=state.get("episodes", 0) + 1)
                    event = "onset"
                elif now - state.get("last_sent", 0) >= max(reminder, cooldown):
                    event = "reminder"
            elif state["active"]:
                stamp = successful(values)
                new_invocation = (state.get("failure_invocation") and values.get("InvocationID")
                                  and state["failure_invocation"] != values["InvocationID"]
                                  and monotonic >= state.get("failure_monotonic", 0))
                newer = stamp > 0 and (state.get("boot_id") != boot or new_invocation
                                      or stamp > state.get("failure_monotonic", 0))
                if unit == "getbible-storage.service":
                    usage = values.get("storage_usage") or {}
                    if not isinstance(usage, dict):
                        usage = {}
                    completed = usage.get("completed_at", usage.get("generated_at", 0))
                    generated = usage.get("generated_at", 0)
                    maximum = usage.get("max_age_seconds", 120)
                    numeric = all(isinstance(value, (int, float)) and not isinstance(value, bool)
                                  and math.isfinite(value) for value in (completed, generated, maximum))
                    newer = (newer and numeric and maximum > 0
                             and completed > state.get("failed_at", 0)
                             and 0 <= now - generated <= maximum)
                if newer:
                    if state.get("clear_since") is None:
                        state["clear_since"] = now
                    # A completed oneshot is direct proof of successful work.
                    # Timer idle intervals can be shorter than the normal hold;
                    # requiring a long inactive window would prevent recovery.
                    completed_run = values.get("Type") == "oneshot" and values.get("SubState") in {"dead", "exited"}
                    if completed_run or now - state["clear_since"] >= hold:
                        state.update(active=False, since=None, clear_since=None, recovered_at=now)
                        event = "recovered"
                else:
                    state["clear_since"] = None
            if event:
                state.update(last_sent=now, last_event=event)
            if json.dumps(state, sort_keys=True) == original and path.exists():
                return state, event
            descriptor, temporary = tempfile.mkstemp(prefix=".incident-", dir=self.directory)
            try:
                with os.fdopen(descriptor, "w") as stream:
                    json.dump(state, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            finally:
                Path(temporary).unlink(missing_ok=True)
        return state, event


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("unit")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--systemctl", default="/usr/bin/systemctl")
    parser.add_argument("--notify", default="/usr/local/lib/getbible/getbible-notify")
    args = parser.parse_args()
    if not UNIT.fullmatch(args.unit):
        parser.error("not a managed service unit")
    values: dict[str, Any] = {}
    try:
        result = subprocess.run([args.systemctl, "show", args.unit, "--no-pager",
                                 "--property=" + ",".join(PROPERTIES)],
                                capture_output=True, text=True, timeout=3)
        values = parse_units(result.stdout).get(args.unit, {})
    except (OSError, subprocess.TimeoutExpired):
        pass
    # systemd supplies these for OnFailure even if a fast retry already changed
    # the queried unit state. Older systemd versions fall back to show above.
    for name, target in (("MONITOR_SERVICE_RESULT", "Result"), ("MONITOR_EXEC_MAIN_STATUS", "ExecMainStatus")):
        if os.environ.get(name):
            values[target] = os.environ[name]
    if os.environ.get("MONITOR_INVOCATION_ID"):
        values["failure_invocation"] = os.environ["MONITOR_INVOCATION_ID"]
    if values.get("Result") == "success":
        values["Result"] = "unavailable (unit has already left its failed state)"
    settings = {}
    for key, default in (("ALERT_REMINDER_SECONDS", 86400), ("ALERT_COOLDOWN_SECONDS", 900)):
        value = os.environ.get("GETBIBLE_" + key, str(default))
        settings[key] = int(value) if re.fullmatch(r"[1-9][0-9]{0,5}", value) else default
    state, event = ServiceIncidents(args.directory).observe(
        args.unit, values, failed=True, now=time.time(), monotonic=time.monotonic(), boot=boot_id(),
        reminder=settings["ALERT_REMINDER_SECONDS"], cooldown=settings["ALERT_COOLDOWN_SECONDS"])
    if event:
        subprocess.run([args.notify, "fail", "Service failed: " + args.unit,
                        state["message"] + (" Persistent incident reminder." if event == "reminder" else "")],
                       check=False, timeout=18)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
