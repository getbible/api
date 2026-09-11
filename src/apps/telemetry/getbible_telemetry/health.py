"""Read-only service health checks tied to actual systemd timer execution."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import time
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .store import timestamp


class HealthInspector:
    def __init__(self, executable: str = "/usr/bin/systemctl") -> None:
        self.executable = executable
        self.last_sample: dict[str, Any] = {"available": False, "conditions": {}}
        self.next_check = 0.0
        self._worker: threading.Thread | None = None

    def current(self, *, grace_seconds: float = 3600) -> dict[str, Any]:
        """Inspect off the ingest loop; a stalled service bus cannot block logs."""
        if time.time() >= self.next_check and (self._worker is None or not self._worker.is_alive()):
            self._worker = threading.Thread(target=self.sample, kwargs={"grace_seconds": grace_seconds}, daemon=True)
            self._worker.start()
        return self.last_sample

    def _run(self, *args: str) -> str | None:
        try:
            result = subprocess.run([self.executable, *args], capture_output=True, text=True,
                                    timeout=3, env={**os.environ, "LC_ALL": "C", "TZ": "UTC", "SYSTEMD_COLORS": "0"})
            return result.stdout if result.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None

    def sample(self, *, grace_seconds: float = 3600, now: float | None = None) -> dict[str, Any]:
        now = time.time() if now is None else now
        if now < self.next_check:
            return self.last_sample
        self.next_check = now + 60
        failed = self._run("list-units", "--all", "--type=service", "--state=failed", "--plain", "--no-legend", "--no-pager", "getbible-*", "nginx.service")
        if failed is None:
            self.last_sample = {"available": False, "conditions": {}, "reason": "systemd state unavailable"}
            return self.last_sample
        conditions = {}
        for line in failed.splitlines():
            unit = line.split()[0] if line.split() else ""
            if unit == "nginx.service" or re.fullmatch(r"getbible-[A-Za-z0-9_.@-]+\.service", unit):
                conditions["service:" + unit] = {"unhealthy": True, "message": "Managed service failed: " + unit}
        timers = self._run("list-timers", "--all", "--plain", "--no-legend", "--no-pager", "getbible-sync-*.timer") or ""
        syncs = []
        for line in timers.splitlines():
            matches = [part for part in line.split() if re.fullmatch(r"getbible-sync-[A-Za-z0-9_.@-]+\.timer", part)]
            if not matches:
                continue
            timer = matches[0]
            last = self._run("show", timer, "--property=LastTriggerUSec", "--value")
            if not last or last.strip() in {"", "n/a"}:
                continue
            try:
                due = datetime.strptime(last.strip(), "%a %Y-%m-%d %H:%M:%S %Z").replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                continue
            service = timer.removesuffix(".timer") + ".service"
            environment = self._run("show", service, "--property=Environment", "--value")
            if environment is None:
                continue
            try:
                values = dict(part.split("=", 1) for part in shlex.split(environment) if "=" in part)
            except ValueError:
                continue
            home, label = values.get("GB_SYNC_HOME", ""), values.get("GB_SYNC_VERSION", "")
            if not home.startswith("/") or not re.fullmatch(r"v[1-9][0-9]*|root", label):
                continue
            checked = 0.0
            try:
                for state in (Path(home) / "state" / (label + ".conf")).read_text(encoding="utf-8").splitlines():
                    if state.startswith("LAST_CHECK="):
                        checked = timestamp(state.partition("=")[2].strip().strip("'\""), fallback=0)
            except OSError:
                pass
            stale = now > due + grace_seconds and checked + 1 < due
            item = {"unit": service, "domain": values.get("GB_SYNC_DOMAIN", ""), "version": label,
                    "last_check": checked or None, "last_timer_trigger": due, "stale": stale}
            syncs.append(item)
            conditions["sync:" + service] = {"unhealthy": stale,
                                             "message": "Scheduled sync has no successful LAST_CHECK after its timer trigger: " + service}
        self.last_sample = {"available": True, "conditions": conditions, "syncs": syncs, "sampled_at": now}
        return self.last_sample
