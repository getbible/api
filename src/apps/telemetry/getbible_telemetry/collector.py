"""Continuous batched ingestion of temporary nginx/runtime log spools.

The append-only producers never open SQLite. The collector commits source
offsets in the same transaction as events; restart/replay is idempotent.
Rotated files are removed only after their complete contents are committed.
"""

from __future__ import annotations

import fcntl
import gzip
import hashlib
import json
import os
import select
import signal
import shlex
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any

from .metrics import MetricsSampler
from .health import HealthInspector
from .store import TelemetryStore


def read_settings(path: str) -> dict[str, float]:
    """Parse the manager's effective environment without evaluating shell."""
    accepted = {
        "TELEMETRY_MAX_GIB", "TELEMETRY_RETENTION_DAYS", "TELEMETRY_SPOOL_MAX_GIB",
        "TELEMETRY_SPOOL_ROTATE_MIB", "TELEMETRY_BATCH_SIZE", "TELEMETRY_FLUSH_SECONDS",
        "TELEMETRY_METRICS_SECONDS", "ALERT_COOLDOWN_SECONDS", "ALERT_HOLD_SECONDS",
        "ALERT_CPU_PERCENT", "ALERT_MEMORY_PERCENT", "ALERT_DISK_PERCENT", "ALERT_MEMORY_PRESSURE_PERCENT",
        "ALERT_SYNC_GRACE_SECONDS",
    }
    result = {}
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        key, separator, value = raw.removeprefix("export ").partition("=")
        key = key.strip().removeprefix("GETBIBLE_")
        if not separator or key not in accepted:
            continue
        parsed = shlex.split(value, comments=True)
        if len(parsed) != 1:
            raise ValueError("invalid effective setting: " + key)
        number = float(parsed[0])
        if not 0 < number < 10**12:
            raise ValueError("setting must be positive and finite: " + key)
        if key.endswith("PERCENT") and number > 100:
            raise ValueError("percentage must be <=100: " + key)
        if key == "TELEMETRY_BATCH_SIZE" and (number != int(number) or number > 100000):
            raise ValueError("batch size must be an integer between 1 and 100000")
        if key == "TELEMETRY_MAX_GIB" and number < 1 / 1024:
            raise ValueError("history budget must be at least 1 MiB")
        if key in {"TELEMETRY_SPOOL_MAX_GIB", "TELEMETRY_SPOOL_ROTATE_MIB"} and number < 1 / 1024:
            raise ValueError("spool size is below the supported minimum")
        result[key] = number
    return result


class Collector:
    def __init__(self, store: TelemetryStore, log_root: str, *, batch_size: int = 1000,
                 max_line_bytes: int = 16 * 1024 * 1024, rotate_bytes: int = 16 * 1024 * 1024,
                 spool_max_bytes: int = 1024 ** 3, nginx_pid: str = "/run/nginx.pid",
                 notify: str = "/usr/local/lib/getbible/getbible-notify") -> None:
        self.store = store
        self.root = Path(log_root)
        self.batch_size = max(1, min(int(batch_size), 100_000))
        self.max_line_bytes = max(1024, int(max_line_bytes))
        self.rotate_bytes = max(1024, int(rotate_bytes))
        self.spool_max_bytes = max(1024, int(spool_max_bytes))
        self.nginx_pid = Path(nginx_pid)
        self.notify = notify
        self.running = True
        self._alert_processes: list[subprocess.Popen] = []
        self._last_cleanup: dict[str, tuple[int, float]] = {}
        self._lock = None
        self._storage_alert_at = 0.0
        self.alert_settings = {
            "ALERT_COOLDOWN_SECONDS": 900, "ALERT_HOLD_SECONDS": 60,
            "ALERT_CPU_PERCENT": 95, "ALERT_MEMORY_PERCENT": 90,
            "ALERT_DISK_PERCENT": 90, "ALERT_MEMORY_PRESSURE_PERCENT": 10,
            "ALERT_SYNC_GRACE_SECONDS": 3600,
        }

    def lock(self) -> None:
        path = self.store.path.with_suffix(".collector.lock")
        self._lock = path.open("a", encoding="ascii")
        try:
            fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            self._lock.close()
            self._lock = None
            raise RuntimeError("another telemetry collector owns this database") from exc

    def close(self) -> None:
        if self._lock is not None:
            self._lock.close()
            self._lock = None

    def files(self) -> list[tuple[Path, str, str, bool]]:
        result = []
        if not self.root.is_dir():
            return result
        for domain in sorted(self.root.iterdir()):
            if not domain.is_dir() or domain.is_symlink():
                continue
            for path in [domain / "access.log", domain / "error.log", *sorted((domain / "app").glob("*.log"))]:
                if path.is_file() and not path.is_symlink():
                    result.append((path, domain.name, "edge" if path.name == "access.log" else
                                   "diagnostic" if path.name == "error.log" else "runtime", False))
            for path in sorted((domain / "archive").glob("*.log-*")):
                if not path.is_file() or path.is_symlink():
                    continue
                source = "edge" if path.name.startswith("access.log-") else "diagnostic" if path.name.startswith("error.log-") else "runtime"
                result.append((path, domain.name, source, True))
        # Read closed spools first, so backlog does not starve behind hot files.
        result.sort(key=lambda row: (not row[3], row[0].stat().st_mtime if row[0].exists() else 0))
        return result

    def ingest_file(self, path: Path, endpoint: str, source: str, *, rotated: bool = False) -> int:
        try:
            stat = path.stat()
            identity = f"{stat.st_dev}:{stat.st_ino}"
            opener = gzip.open if path.suffix == ".gz" else open
            with opener(path, "rb") as handle:
                row = self.store.db.execute("SELECT * FROM sources WHERE identity=?", (identity,)).fetchone()
                offset = row["offset"] if row else 0
                generation = row["generation"] if row else 0
                fingerprint_bytes = row["fingerprint_bytes"] if row else 0
                fingerprint = row["fingerprint"] if row else ""
                if fingerprint_bytes:
                    prefix = handle.read(fingerprint_bytes)
                    unchanged = hashlib.sha256(prefix).hexdigest() == fingerprint
                else:
                    unchanged = True
                truncated = (path.suffix != ".gz" and stat.st_size < offset) or not unchanged
                if truncated:
                    offset, fingerprint_bytes, fingerprint = 0, 0, ""
                    generation += 1
                handle.seek(offset)
                records = []
                size = 0
                blocked = False
                while len(records) < self.batch_size and size < 8 * 1024 * 1024:
                    start = handle.tell()
                    line = handle.readline(self.max_line_bytes + 1)
                    if not line:
                        break
                    if len(line) > self.max_line_bytes:
                        blocked = True
                        break
                    if not line.endswith(b"\n"):
                        # Producers may still be finishing this record. Preserve
                        # the cursor and revisit, even across a collector restart.
                        break
                    offset = handle.tell()
                    size += len(line)
                    if not fingerprint_bytes:
                        fingerprint_bytes = min(len(line), 256)
                        fingerprint = hashlib.sha256(line[:fingerprint_bytes]).hexdigest()
                    if not line.strip():
                        continue
                    try:
                        entry = json.loads(line)
                        if not isinstance(entry, dict):
                            raise ValueError("record is not a JSON object")
                    except (ValueError, UnicodeError):
                        entry = {"event": "unstructured_log", "level": "ERROR" if source == "diagnostic" else "WARNING",
                                 "message": line.decode("utf-8", "replace").rstrip("\n"),
                                 "source": source, "malformed": source != "diagnostic"}
                    logical_name = path.name.split(".log-", 1)[0] + ".log" if rotated else path.name
                    key_data = endpoint.encode() + b"\0" + logical_name.encode() + b"\0" + str(start).encode() + b"\0" + line
                    record_key = hashlib.sha256(key_data).hexdigest()
                    record_source = "diagnostic" if entry.get("event") == "unstructured_log" else source
                    records.append((entry, record_source, record_key))
                with self.store.db:
                    if truncated:
                        self.store.note_gap("source_replaced_or_truncated", str(path) + ": previous committed offset "
                                            + str(row["offset"]) + "; unread data may have been lost before collection.")
                    for entry, record_source, record_key in records:
                        self.store.append(entry, endpoint=endpoint, source=record_source, record_key=record_key)
                    self.store.db.execute(
                        "INSERT INTO sources(identity,path,offset,fingerprint,fingerprint_bytes,generation,updated,closed) "
                        "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(identity) DO UPDATE SET path=excluded.path,offset=excluded.offset,"
                        "fingerprint=excluded.fingerprint,fingerprint_bytes=excluded.fingerprint_bytes,generation=excluded.generation,"
                        "updated=excluded.updated,closed=excluded.closed",
                        (identity, str(path), offset, fingerprint, fingerprint_bytes, generation, time.time(), int(rotated)))
                    if blocked:
                        self.store.set_metadata("blocked_source:" + identity,
                                                {"path": str(path), "offset": offset, "reason": "line exceeds configured maximum; spool retained"})
                    else:
                        self.store.db.execute("DELETE FROM metadata WHERE key=?", ("blocked_source:" + identity,))
                return len(records)
        except (FileNotFoundError, PermissionError, gzip.BadGzipFile, EOFError) as exc:
            with self.store.db:
                self.store.set_metadata("source_error:" + str(path), {"time": time.time(), "error": str(exc)})
            return 0

    def _nginx_reopen(self) -> bool:
        try:
            pid = int(self.nginx_pid.read_text(encoding="ascii").strip())
            if pid <= 1:
                return False
            os.kill(pid, signal.SIGUSR1)
            return True
        except (OSError, ValueError):
            return False

    def rotate(self) -> int:
        rotated = 0
        nginx = False
        for path, endpoint, source, archived in self.files():
            if archived:
                continue
            try:
                stat = path.stat()
                if stat.st_size < self.rotate_bytes:
                    continue
                # nginx needs its master to reopen before an old spool can be
                # removed. Do not rotate if signaling is unavailable.
                if source in {"edge", "diagnostic"} and not self.nginx_pid.is_file():
                    continue
                archive = path.parent.parent / "archive" if source == "runtime" else path.parent / "archive"
                archive.mkdir(mode=0o750, parents=True, exist_ok=True)
                target = archive / (path.name + "-" + time.strftime("%Y%m%d-%H%M%S", time.gmtime())
                                    + f"-{time.time_ns()}.spool")
                os.rename(path, target)
                # nginx and WatchedFileHandler both need a writable replacement.
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.st_mode & 0o777)
                try:
                    os.fchown(fd, stat.st_uid, stat.st_gid)
                finally:
                    os.close(fd)
                rotated += 1
                nginx = nginx or source in {"edge", "diagnostic"}
            except OSError as exc:
                with self.store.db:
                    self.store.set_metadata("rotation_error:" + str(path), {"time": time.time(), "error": str(exc)})
        if nginx and not self._nginx_reopen():
            with self.store.db:
                self.store.set_metadata("nginx_reopen_failed", {"time": time.time(), "spools_retained": True})
        return rotated

    @staticmethod
    def _open_in_process(path: Path) -> bool:
        """Conservative Linux check: never unlink a producer's open spool.

        Collector runs with enough process visibility to check nginx/runtime
        descriptors. Permission failures retain the file instead of guessing.
        """
        target = str(path)
        for directory in Path("/proc").glob("[0-9]*/fd"):
            try:
                for descriptor in directory.iterdir():
                    try:
                        if os.readlink(descriptor).removesuffix(" (deleted)") == target:
                            return True
                    except FileNotFoundError:
                        continue
                    except PermissionError:
                        return True
            except FileNotFoundError:
                continue
            except PermissionError:
                return True
        return False

    def cleanup(self) -> int:
        removed = 0
        for path, _, _, rotated in self.files():
            # Legacy compressed archives are imported but retained for explicit
            # operator review. Only our own transport spools are auto-removed.
            if not rotated or not path.name.endswith(".spool"):
                continue
            try:
                stat = path.stat()
                identity = f"{stat.st_dev}:{stat.st_ino}"
                row = self.store.db.execute("SELECT offset FROM sources WHERE identity=?", (identity,)).fetchone()
                if row is None or row[0] != stat.st_size:
                    self._last_cleanup.pop(identity, None)
                    continue
                previous = self._last_cleanup.get(identity)
                self._last_cleanup[identity] = stat.st_size, time.monotonic()
                if previous is None or previous[0] != stat.st_size or time.monotonic() - previous[1] < 5:
                    continue
                if self._open_in_process(path):
                    continue
                # Recheck after descriptor scan. Cursor is already durable.
                if path.stat().st_size != stat.st_size:
                    continue
                path.unlink()
                self._last_cleanup.pop(identity, None)
                with self.store.db:
                    self.store.db.execute("DELETE FROM sources WHERE identity=?", (identity,))
                removed += 1
            except FileNotFoundError:
                continue
        return removed

    def state(self) -> dict[str, Any]:
        total, unread = 0, 0
        for path, _, _, _ in self.files():
            try:
                stat = path.stat()
                total += stat.st_size
                row = self.store.db.execute("SELECT offset FROM sources WHERE identity=?", (f"{stat.st_dev}:{stat.st_ino}",)).fetchone()
                if path.suffix != ".gz":
                    unread += max(0, stat.st_size - (row[0] if row else 0))
            except FileNotFoundError:
                pass
        return {"spool_bytes": total, "unread_bytes": unread, "spool_max_bytes": self.spool_max_bytes,
                "spool_over_budget": total > self.spool_max_bytes, "heartbeat": time.time(),
                "durability": "batched FULL SQLite commits after buffered producer writes",
                "budget_enforcement": "oldest committed history is pruned; unread spools are retained and alerted"}

    def journal(self, executable: str = "/usr/bin/journalctl") -> int:
        """Read bounded getBible service events using a durable journal cursor."""
        if not os.access(executable, os.X_OK):
            return 0
        saved = self.store.db.execute("SELECT value FROM metadata WHERE key='journal_cursor'").fetchone()
        previous = json.loads(saved[0]) if saved else {}
        args = [executable, "--no-pager", "--output=json", "--all", "--unit=getbible-*"]
        if previous.get("cursor"):
            args += ["--after-cursor", previous["cursor"]]
        elif previous.get("stamp"):
            args += ["--since", "@" + str(int(previous["stamp"]))]
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        entries = []
        pending = bytearray()
        deadline = time.monotonic() + 2
        try:
            assert proc.stdout is not None
            while len(entries) < self.batch_size and time.monotonic() < deadline:
                ready, _, _ = select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    break
                pending.extend(data)
                if len(pending) > self.max_line_bytes:
                    with self.store.db:
                        self.store.set_metadata("journal_error", {"time": time.time(), "reason": "oversized journal record; cursor unchanged"})
                    return 0
                while b"\n" in pending and len(entries) < self.batch_size:
                    line, _, rest = pending.partition(b"\n")
                    pending = bytearray(rest)
                    try:
                        entry = json.loads(line)
                        if isinstance(entry, dict) and "__CURSOR" in entry:
                            entries.append(entry)
                    except (ValueError, UnicodeError):
                        continue
            status = proc.poll()
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            if proc.stdout:
                proc.stdout.close()
        with self.store.db:
            for entry in entries:
                stamp = int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1_000_000
                message = entry.get("MESSAGE", "")
                if isinstance(message, list):
                    message = bytes(message).decode("utf-8", "replace")
                priority = int(entry.get("PRIORITY", 6))
                record = {"time": stamp, "event": "service_journal", "level": "ERROR" if priority <= 3 else "WARNING" if priority == 4 else "INFO",
                          "message": message, "unit": entry.get("_SYSTEMD_UNIT", ""),
                          "pid": entry.get("_PID"), "boot_id": entry.get("_BOOT_ID"), "journal": entry}
                self.store.append(record, endpoint="system", source="journal", record_key="journal:" + entry["__CURSOR"])
                self.store.set_metadata("journal_cursor", {"cursor": entry["__CURSOR"], "stamp": stamp})
            if entries:
                self.store.db.execute("DELETE FROM metadata WHERE key='journal_error'")
            elif status not in (0, None):
                if previous.get("cursor"):
                    self.store.note_gap("journal_cursor_unavailable", "Journal cursor could not be read; retained journal history will resume at the last event timestamp.",
                                        first_stamp=previous.get("stamp"))
                    self.store.set_metadata("journal_cursor", {"stamp": previous.get("stamp")})
                self.store.set_metadata("journal_error", {"time": time.time(), "exit_status": status})
        return len(entries)

    def _notify(self, level: str, title: str, body: str) -> None:
        self._alert_processes = [proc for proc in self._alert_processes if proc.poll() is None]
        if not os.access(self.notify, os.X_OK) or len(self._alert_processes) >= 4:
            return
        try:
            self._alert_processes.append(subprocess.Popen([self.notify, level, title, body],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, close_fds=True))
        except OSError:
            pass

    def health(self, sample: dict[str, Any], state: dict[str, Any], *, now: float | None = None) -> None:
        now = time.time() if now is None else now
        row = self.store.db.execute("SELECT value FROM metadata WHERE key='health_alerts'").fetchone()
        alerts = json.loads(row[0]) if row else {}
        memory = sample.get("memory", {}).get("used_fraction")
        cpu = sample.get("cpu", {}).get("used_fraction")
        pressure = sample.get("pressure", {}).get("memory") or {}
        memory_pressure = (pressure.get("full") or {}).get("avg10", 0)
        conditions = {
            "memory": (memory is not None and memory >= self.alert_settings["ALERT_MEMORY_PERCENT"] / 100, "Memory exceeds the configured percentage of its available limit."),
            "cpu": (cpu is not None and cpu >= self.alert_settings["ALERT_CPU_PERCENT"] / 100, "CPU has sustained demand above the configured percentage of its available limit."),
            "memory_pressure": (memory_pressure >= self.alert_settings["ALERT_MEMORY_PRESSURE_PERCENT"], "Memory pressure is stalling work; inspect resident caches and concurrency."),
            "disk": (any(d.get("used_fraction", 0) >= self.alert_settings["ALERT_DISK_PERCENT"] / 100 for d in sample.get("disks", [])), "Data filesystem exceeds the configured usage threshold."),
            "telemetry_spool": (bool(state.get("spool_over_budget")), "Unread/active telemetry spools exceed their configured budget; they have not been deleted."),
        }
        services = sample.get("services", {})
        if services.get("available"):
            for key in alerts:
                if key.startswith(("service:", "sync:")):
                    conditions[key] = (False, "Previously reported service condition cleared.")
            for key, condition in services.get("conditions", {}).items():
                conditions[key] = (condition["unhealthy"], condition["message"])
        for key, (unhealthy, message) in conditions.items():
            previous = alerts.setdefault(key, {"since": None, "last_sent": 0, "active": False})
            if unhealthy:
                previous["since"] = previous["since"] or now
                if now - previous["since"] >= self.alert_settings["ALERT_HOLD_SECONDS"] and now - previous["last_sent"] >= self.alert_settings["ALERT_COOLDOWN_SECONDS"]:
                    self._notify("warn", "getBible capacity: " + key, message)
                    previous["last_sent"], previous["active"] = now, True
            else:
                if previous["active"]:
                    self._notify("info", "getBible recovered: " + key, "The previously reported condition has cleared.")
                previous["since"], previous["active"] = None, False
        with self.store.db:
            self.store.set_metadata("health_alerts", alerts)

    def run(self, *, flush_seconds: float = 1, metrics_seconds: float = 5,
            max_bytes: int = 10 * 1024 ** 3, retention_days: float = 180,
            once: bool = False, cgroup_root: str = "/sys/fs/cgroup", settings: str = "", journal: bool = True,
            systemctl: str = "/usr/bin/systemctl") -> None:
        self.lock()
        sampler = MetricsSampler(cgroup_root=cgroup_root, disks=[str(self.root), str(self.store.path.parent)])
        inspector = HealthInspector(systemctl)
        next_metric = next_prune = next_cleanup = next_settings = 0.0
        try:
            while self.running:
                began = time.monotonic()
                work = 0
                try:
                    if settings and began >= next_settings:
                        try:
                            current = read_settings(settings)
                            max_bytes = int(current.get("TELEMETRY_MAX_GIB", max_bytes / 1024**3) * 1024**3)
                            retention_days = current.get("TELEMETRY_RETENTION_DAYS", retention_days)
                            flush_seconds = current.get("TELEMETRY_FLUSH_SECONDS", flush_seconds)
                            metrics_seconds = current.get("TELEMETRY_METRICS_SECONDS", metrics_seconds)
                            self.batch_size = int(current.get("TELEMETRY_BATCH_SIZE", self.batch_size))
                            self.rotate_bytes = int(current.get("TELEMETRY_SPOOL_ROTATE_MIB", self.rotate_bytes / 1024**2) * 1024**2)
                            self.spool_max_bytes = int(current.get("TELEMETRY_SPOOL_MAX_GIB", self.spool_max_bytes / 1024**3) * 1024**3)
                            self.alert_settings.update({key: value for key, value in current.items() if key.startswith("ALERT_")})
                            with self.store.db:
                                self.store.set_metadata("effective_settings", current)
                                self.store.db.execute("DELETE FROM metadata WHERE key='settings_error'")
                        except (OSError, ValueError) as exc:
                            with self.store.db:
                                self.store.set_metadata("settings_error", {"time": time.time(), "error": str(exc)})
                        next_settings = began + 30
                    for path, endpoint, source, rotated in self.files():
                        work += self.ingest_file(path, endpoint, source, rotated=rotated)
                    now = time.monotonic()
                    if now >= next_metric:
                        if journal:
                            self.journal()
                        sample, state = sampler.sample(), self.state()
                        sample["services"] = inspector.current(grace_seconds=self.alert_settings["ALERT_SYNC_GRACE_SECONDS"])
                        with self.store.db:
                            self.store.append_metric({**sample, "telemetry": state})
                            self.store.set_metadata("collector", state)
                        self.health(sample, state)
                        next_metric = now + max(1, metrics_seconds)
                    if now >= next_prune:
                        result = self.store.prune(max_bytes=max_bytes, retention_days=retention_days)
                        with self.store.db:
                            self.store.set_metadata("last_prune", result)
                        next_prune = now + 60
                    if now >= next_cleanup:
                        self.rotate()
                        for path, endpoint, source, rotated in self.files():
                            if rotated:
                                self.ingest_file(path, endpoint, source, rotated=True)
                        self.cleanup()
                        next_cleanup = now + 10
                except (sqlite3.Error, OSError) as exc:
                    self.store.db.rollback()
                    # With a full/unavailable database, durable cursors do not
                    # advance. Leave spools intact and alert without using SQL.
                    if time.monotonic() - self._storage_alert_at >= self.alert_settings["ALERT_COOLDOWN_SECONDS"]:
                        self._notify("error", "getBible telemetry storage failure", str(exc))
                        self._storage_alert_at = time.monotonic()
                    print(json.dumps({"level": "ERROR", "event": "telemetry_storage_failure", "error": str(exc)}), flush=True)
                    if once:
                        raise
                if once:
                    break
                # Backlog drains continuously in bounded transactions. Yield
                # between batches instead of waiting a full second per batch.
                delay = .01 if work >= self.batch_size else max(.01, flush_seconds - (time.monotonic() - began))
                time.sleep(min(delay, 1.0))
        finally:
            self.close()
