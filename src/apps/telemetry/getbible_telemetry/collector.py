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
import sys
import uuid
import time
from pathlib import Path
from typing import Any

from .metrics import MetricsSampler
from .health import HealthInspector
from .store import TelemetryStore
from .settings import SETTING_NAMES, numeric_setting
from .capacity import CapacityTracker, incident_update


def read_settings(path: str) -> dict[str, int]:
    """Parse the manager's effective environment without evaluating shell."""
    result = {}
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        key, separator, value = raw.removeprefix("export ").partition("=")
        key = key.strip().removeprefix("GETBIBLE_")
        if not separator or key not in SETTING_NAMES:
            continue
        parsed = shlex.split(value, comments=True)
        if len(parsed) != 1:
            raise ValueError("invalid effective setting: " + key)
        result[key] = numeric_setting(key, parsed[0])
    return result


class Collector:
    def __init__(self, store: TelemetryStore, log_root: str, *, batch_size: int = 1000,
                 max_line_bytes: int = 16 * 1024 * 1024, rotate_bytes: int = 16 * 1024 * 1024,
                 spool_max_bytes: int = 1024 ** 3, nginx_pid: str = "/run/nginx.pid",
                 notify: str = "/usr/local/lib/getbible/getbible-notify") -> None:
        self.store = store
        self.root = Path(log_root)
        self.batch_size = numeric_setting("TELEMETRY_BATCH_SIZE", batch_size)
        self.max_line_bytes = max(1024, int(max_line_bytes))
        self.rotate_bytes = max(1024, int(rotate_bytes))
        self.spool_max_bytes = max(1024, int(spool_max_bytes))
        self.nginx_pid = Path(nginx_pid)
        self.notify = notify
        self.running = True
        self._alert_processes: list[subprocess.Popen] = []
        self._last_cleanup: dict[str, tuple[int, int, float]] = {}
        self._cleanup_cursor = 0
        self._ingest_cursors = [0, 0]
        self._batch_pending = False
        self._pass_pending = False
        self._committed_bytes = 0
        self._committed_records = 0
        self._instance = uuid.uuid4().hex
        self._capacity = CapacityTracker(store)
        self._history_max_bytes = 10 * 1024**3
        self._lock = None
        self._storage_alert_at = 0.0
        self.alert_settings = {
            "ALERT_COOLDOWN_SECONDS": 900, "ALERT_REMINDER_SECONDS": 86400, "ALERT_HOLD_SECONDS": 60,
            "ALERT_CPU_PERCENT": 95, "ALERT_MEMORY_PERCENT": 90,
            "ALERT_DISK_PERCENT": 90, "ALERT_MEMORY_PRESSURE_PERCENT": 10,
            "ALERT_SYNC_GRACE_SECONDS": 3600,
        }
        self.alert_settings = {key: numeric_setting(key, os.environ.get("GETBIBLE_" + key, value))
                               for key, value in self.alert_settings.items()}

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
            self._batch_pending = False
            signature = [stat.st_size, stat.st_mtime_ns, endpoint, source]
            complete = self.store.db.execute("SELECT value FROM metadata WHERE key=?", ("source_eof:" + identity,)).fetchone()
            if complete and json.loads(complete[0]) == signature:
                return 0
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
                committed_start = offset
                blocked = False
                eof = False
                partial = False
                while len(records) < self.batch_size and size < 8 * 1024 * 1024:
                    start = handle.tell()
                    line = handle.readline(self.max_line_bytes + 1)
                    if not line:
                        eof = True
                        break
                    if len(line) > self.max_line_bytes:
                        blocked = True
                        break
                    if not line.endswith(b"\n"):
                        # Producers may still be finishing this record. Preserve
                        # the cursor and revisit, even across a collector restart.
                        partial = True
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
                self._batch_pending = not (eof or blocked or partial)
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
                    after = os.fstat(handle.fileno())
                    if eof and (after.st_size, after.st_mtime_ns) == (stat.st_size, stat.st_mtime_ns):
                        self.store.set_metadata("source_eof:" + identity, signature)
                    else:
                        self.store.db.execute("DELETE FROM metadata WHERE key=?", ("source_eof:" + identity,))
                    self.store.db.execute("DELETE FROM metadata WHERE key=?", ("source_error:" + str(path),))
                    if blocked:
                        self.store.set_metadata("blocked_source:" + identity,
                                                {"path": str(path), "offset": offset, "reason": "line exceeds configured maximum; spool retained"})
                    else:
                        self.store.db.execute("DELETE FROM metadata WHERE key=?", ("blocked_source:" + identity,))
                if path.suffix != ".gz":
                    self._committed_bytes += max(0, offset - committed_start)
                self._committed_records += len(records)
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
                with self.store.db:
                    self.store.db.execute("DELETE FROM metadata WHERE key=?", ("rotation_error:" + str(path),))
            except OSError as exc:
                with self.store.db:
                    self.store.set_metadata("rotation_error:" + str(path), {"time": time.time(), "error": str(exc)})
        if nginx:
            with self.store.db:
                if self._nginx_reopen():
                    self.store.db.execute("DELETE FROM metadata WHERE key='nginx_reopen_failed'")
                else:
                    self.store.set_metadata("nginx_reopen_failed", {"time": time.time(), "spools_retained": True})
        return rotated

    def ingest_pass(self, *, time_budget: float = .25) -> int:
        """Alternate live and closed sources, yielding between bounded commits.

        Remember each group's position so a slow backlog cannot starve a hot
        endpoint, and a hot endpoint cannot starve archived history. The budget
        applies between atomic batches; no transaction is abandoned mid-commit.
        """
        files = self.files()
        groups = ([row for row in files if not row[3]], [row for row in files if row[3]])
        done = [0, 0]
        work = 0
        self._pass_pending = False
        deadline = time.monotonic() + time_budget
        while any(done[i] < len(group) for i, group in enumerate(groups)):
            for i, group in enumerate(groups):
                if done[i] >= len(group):
                    continue
                index = self._ingest_cursors[i] % len(group)
                path, endpoint, source, rotated = group[index]
                self._batch_pending = False
                work += self.ingest_file(path, endpoint, source, rotated=rotated)
                self._pass_pending = self._pass_pending or self._batch_pending
                self._ingest_cursors[i] = (index + 1) % len(group)
                done[i] += 1
                if not self.running or time.monotonic() >= deadline:
                    self._pass_pending |= any(done[j] < len(rows) for j, rows in enumerate(groups))
                    return work
        return work

    def cleanup(self) -> int:
        candidates = []
        spools = [entry[0] for entry in self.files() if entry[3] and entry[0].name.endswith(".spool")]
        if spools:
            start = self._cleanup_cursor % len(spools)
            spools = spools[start:] + spools[:start]
        checked = 0
        live = set()
        for path in spools:
            try:
                stat = path.stat()
                identity = f"{stat.st_dev}:{stat.st_ino}"
                live.add(identity)
                row = self.store.db.execute("SELECT offset FROM sources WHERE identity=?", (identity,)).fetchone()
                if row is None or row[0] != stat.st_size:
                    self._last_cleanup.pop(identity, None)
                    continue
                previous = self._last_cleanup.get(identity)
                if previous is None or previous[:2] != (stat.st_size, stat.st_mtime_ns):
                    self._last_cleanup[identity] = stat.st_size, stat.st_mtime_ns, time.monotonic()
                    continue
                if time.monotonic() - previous[2] < 5:
                    continue
                candidates.append({"path": str(path), "identity": identity, "size": stat.st_size,
                                   "mtime_ns": stat.st_mtime_ns})
                checked += 1
                if checked == 32:
                    break
            except FileNotFoundError:
                continue
        self._cleanup_cursor += max(1, checked)
        # No /proc visibility assumptions or added Docker capabilities: a read
        # lease proves that the committed archive has no writable descriptor.
        if not candidates:
            return 0
        try:
            process = subprocess.run([sys.executable, str(Path(__file__).with_name("spools.py"))],
                                     input=json.dumps(candidates), capture_output=True, text=True, timeout=5)
            if process.returncode:
                raise RuntimeError("spool reclamation helper failed")
            results = json.loads(process.stdout)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
            with self.store.db:
                self.store.set_metadata("spool_cleanup", {"time": time.time(), "removed": 0,
                                                          "retained": len(candidates), "error": str(exc)})
            return 0
        removed = 0
        with self.store.db:
            for result in results:
                if not result.get("removed"):
                    continue
                identity = result["identity"]
                self.store.db.execute("DELETE FROM sources WHERE identity=?", (identity,))
                self.store.db.execute("DELETE FROM metadata WHERE key IN (?,?)",
                                      ("source_eof:" + identity, "blocked_source:" + identity))
                self._last_cleanup.pop(identity, None)
                removed += 1
            self.store.set_metadata("spool_cleanup", {"time": time.time(), "removed": removed,
                "retained": len(candidates) - removed,
                "reasons": sorted({item["reason"] for item in results if item.get("reason")})})
        return removed

    def state(self) -> dict[str, Any]:
        total = unread = active = rotated_bytes = consumed = archives = pending_archives = compressed_pending = 0
        unread_files = active_files = 0
        sources = {row["identity"]: row for row in self.store.db.execute("SELECT identity,offset FROM sources")}
        completed = {row[0].removeprefix("source_eof:"): json.loads(row[1]) for row in
                     self.store.db.execute("SELECT key,value FROM metadata WHERE key LIKE 'source_eof:%'")}
        for path, endpoint, source, rotated in self.files():
            try:
                stat = path.stat()
                identity = f"{stat.st_dev}:{stat.st_ino}"
                total += stat.st_size
                offset = sources[identity]["offset"] if identity in sources else 0
                complete = completed.get(identity) == [stat.st_size, stat.st_mtime_ns, endpoint, source]
                if not rotated:
                    active += stat.st_size
                    active_files += 1
                elif path.name.endswith(".spool"):
                    rotated_bytes += stat.st_size
                    if offset == stat.st_size:
                        consumed += stat.st_size
                else:
                    archives += stat.st_size
                    if not complete:
                        pending_archives += stat.st_size
                if path.suffix == ".gz":
                    if not complete:
                        compressed_pending += stat.st_size
                        unread_files += 1
                else:
                    remaining = max(0, stat.st_size - offset)
                    unread += remaining
                    unread_files += bool(remaining)
            except FileNotFoundError:
                pass
        budgeted = active + rotated_bytes + pending_archives
        page = self.store.db.execute("PRAGMA page_size").fetchone()[0]
        history_active = (self.store.db.execute("PRAGMA page_count").fetchone()[0]
                          - self.store.db.execute("PRAGMA freelist_count").fetchone()[0]) * page
        problems = {row[0]: json.loads(row[1]) for row in self.store.db.execute(
            "SELECT key,value FROM metadata WHERE key LIKE 'blocked_source:%' OR key LIKE 'source_error:%' "
            "OR key IN ('nginx_reopen_failed','spool_cleanup')")}
        return {"spool_bytes": total, "unread_bytes": unread, "spool_max_bytes": self.spool_max_bytes,
                "budgeted_spool_bytes": budgeted, "active_bytes": active, "active_files": active_files,
                "rotated_spool_bytes": rotated_bytes, "consumed_rotated_bytes": consumed,
                "retained_archive_bytes": archives, "pending_archive_bytes": pending_archives,
                "compressed_pending_bytes": compressed_pending, "unread_files": unread_files,
                "spool_over_budget": budgeted > self.spool_max_bytes, "heartbeat": time.time(),
                "rotate_bytes": self.rotate_bytes, "collector_instance": self._instance,
                "committed_bytes": self._committed_bytes, "committed_records": self._committed_records,
                "history_active_bytes": history_active, "history_max_bytes": self._history_max_bytes,
                "problems": problems,
                "durability": "batched FULL SQLite commits after buffered producer writes",
                "budget_enforcement": "transport and pending imports count; completed legacy archives are retained separately; unread spools are never deleted"}

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
        pressure = (sample.get("pressure", {}).get("memory") or {}).get("full") or {}
        disk = max((d.get("used_fraction") or 0 for d in sample.get("disks", [])), default=0)
        usage = state.get("budgeted_spool_bytes", state.get("spool_bytes", 0))
        allowance = state.get("spool_max_bytes", self.spool_max_bytes)
        details = (f"Transport/pending spools {usage / 1024**3:.2f} GiB / {allowance / 1024**3:.2f} GiB; "
                   f"unread {state.get('unread_bytes', 0) / 1024**2:.1f} MiB, "
                   f"committed closed spools {state.get('consumed_rotated_bytes', 0) / 1024**2:.1f} MiB. "
                   "Unread/active files are preserved. Use getbible capacity for collection health and sizing advice.")
        conditions = {
            "memory": (memory, self.alert_settings["ALERT_MEMORY_PERCENT"] / 100, "Memory exceeds its configured threshold."),
            "cpu": (cpu, self.alert_settings["ALERT_CPU_PERCENT"] / 100, "CPU demand exceeds its configured threshold."),
            "memory_pressure": (pressure.get("avg10"), self.alert_settings["ALERT_MEMORY_PRESSURE_PERCENT"], "Memory pressure is stalling work; inspect caches and concurrency."),
            "disk": (disk if sample.get("disks") else None, self.alert_settings["ALERT_DISK_PERCENT"] / 100, "The data filesystem exceeds its usage threshold."),
            "telemetry_spool": (usage, allowance, details),
        }
        services = sample.get("services", {})
        if services.get("available"):
            for key in alerts:
                if key.startswith(("service:", "sync:")):
                    conditions[key] = (0, 1, "Previously reported service condition cleared.")
            for key, condition in services.get("conditions", {}).items():
                conditions[key] = (int(condition["unhealthy"]), 1, condition["message"])
        for key, (value, threshold, message) in conditions.items():
            if value is None:
                continue  # Missing sensors are not evidence of recovery.
            previous = alerts.setdefault(key, {})
            event = incident_update(previous, value, threshold, now=now,
                                    hold=self.alert_settings["ALERT_HOLD_SECONDS"],
                                    cooldown=self.alert_settings["ALERT_COOLDOWN_SECONDS"],
                                    reminder=self.alert_settings["ALERT_REMINDER_SECONDS"])
            if event:
                if event == "recovered":
                    self._notify("info", "getBible recovered: " + key, "The previously reported condition has cleared.")
                else:
                    self._notify("warn", "getBible capacity: " + key,
                                 message + (" Persistent incident reminder." if event == "reminder" else ""))
        with self.store.db:
            self.store.set_metadata("health_alerts", alerts)

    def run(self, *, flush_seconds: int = 1, metrics_seconds: int = 5,
            max_bytes: int = 10 * 1024 ** 3, retention_days: int = 180,
            once: bool = False, cgroup_root: str = "/sys/fs/cgroup", settings: str = "", journal: bool = True,
            systemctl: str = "/usr/bin/systemctl") -> None:
        flush_seconds = numeric_setting("TELEMETRY_FLUSH_SECONDS", flush_seconds)
        metrics_seconds = numeric_setting("TELEMETRY_METRICS_SECONDS", metrics_seconds)
        retention_days = numeric_setting("TELEMETRY_RETENTION_DAYS", retention_days)
        self.lock()
        self._history_max_bytes = max_bytes
        sampler = MetricsSampler(cgroup_root=cgroup_root, disks=[str(self.root), str(self.store.path.parent)])
        inspector = HealthInspector(systemctl)
        next_metric = next_prune = next_cleanup = next_settings = 0.0
        next_ingest = next_rollup = 0.0
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
                            next_ingest = min(next_ingest, began + flush_seconds)
                            metrics_seconds = current.get("TELEMETRY_METRICS_SECONDS", metrics_seconds)
                            self._history_max_bytes = max_bytes
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
                    if began >= next_ingest:
                        work = self.ingest_pass()
                        # A full batch indicates backlog. Drain it promptly in
                        # bounded transactions; otherwise honor the configured
                        # ingestion interval independently of housekeeping.
                        next_ingest = time.monotonic() + (.01 if self._pass_pending else flush_seconds)
                    now = time.monotonic()
                    if now >= next_metric:
                        if journal:
                            self.journal()
                        sample, state = sampler.sample(), self.state()
                        sample["services"] = inspector.current(grace_seconds=self.alert_settings["ALERT_SYNC_GRACE_SECONDS"])
                        with self.store.db:
                            self.store.append_metric({**sample, "telemetry": state})
                            self.store.set_metadata("collector", state)
                            self._capacity.observe(sample, state)
                        self.health(sample, state)
                        next_metric = now + max(1, metrics_seconds)
                    if now >= next_prune:
                        result = self.store.prune(max_bytes=max_bytes, retention_days=retention_days)
                        with self.store.db:
                            self.store.set_metadata("last_prune", result)
                        next_prune = now + 60
                    if now >= next_cleanup:
                        self.rotate()
                        self.cleanup()
                        next_cleanup = now + 10
                    # Historical reporting work is resumable and follows each
                    # bounded ingestion pass. It never delays source commits or
                    # makes ordinary request handlers maintain the database.
                    if now >= next_rollup:
                        self.store.refresh_rollups(max_buckets=1 if self._pass_pending else 4, time_budget=.1)
                        next_rollup = time.monotonic() + (2 if self._pass_pending else .25)
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
                # Wake for metrics/settings/shutdown at least once per second
                # without accidentally ingesting every time this loop wakes.
                deadline = min(next_ingest, next_metric, next_prune, next_cleanup,
                               next_settings if settings else float("inf"))
                time.sleep(min(1.0, max(.01, deadline - time.monotonic())))
        finally:
            self.close()
