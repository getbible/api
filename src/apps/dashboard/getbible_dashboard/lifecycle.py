"""Viewer leases own the reporting pool; authentication remains inexpensive."""

from concurrent.futures import ThreadPoolExecutor
import errno
import logging
import sqlite3
import threading
import time


class ReportingUnavailable(Exception):
    pass


def storage_error(exc):
    """Explain local storage failures without exposing arbitrary exception text."""
    try:
        from getbible_telemetry.store import TelemetrySchemaError
    except ImportError:
        return "The reporting dependency is unavailable; apply the current dashboard installation"
    if isinstance(exc, TelemetrySchemaError):
        return str(exc)
    code = getattr(exc, "sqlite_errorcode", 0) & 255
    if (isinstance(exc, PermissionError) or code in {sqlite3.SQLITE_PERM, sqlite3.SQLITE_READONLY}
            or getattr(exc, "errno", None) in {errno.EACCES, errno.EPERM, errno.EROFS}):
        return "Reporting storage permissions prevent access; check the telemetry directory and service permissions"
    if isinstance(exc, FileNotFoundError) or code == sqlite3.SQLITE_CANTOPEN:
        return "Reporting storage cannot be opened; check telemetry service status and database permissions"
    if code in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED}:
        return "Reporting storage is busy; the dashboard will retry automatically"
    if code == sqlite3.SQLITE_INTERRUPT:
        return "Reporting storage exceeded its time budget; the dashboard will retry automatically"
    if code in {sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB}:
        return "Reporting storage is damaged or is not a SQLite database; preserve it and inspect telemetry service status"
    if code in {sqlite3.SQLITE_FULL, sqlite3.SQLITE_IOERR}:
        return "Reporting storage has a disk or filesystem error; inspect telemetry service status and available disk space"
    return "Reporting storage is unavailable; check the telemetry service journal for the failure reason"


class ViewerLifecycle:
    def __init__(self, *, idle_seconds=60, clock=None, initialize=None, on_sleep=None, retry_seconds=15):
        self.idle_seconds = idle_seconds
        self.clock = clock or time.monotonic
        self.initialize = initialize or (lambda: None)
        self.on_sleep = on_sleep or (lambda: None)
        self._lock = threading.RLock()
        self._slots = threading.BoundedSemaphore(4)
        self._viewers = {}
        self._pool = None
        self._initialization = None
        self._generation = 0
        self._state = "sleeping"
        self._error = None
        self._last_viewer = 0.0
        self._retry_seconds = max(1, retry_seconds)
        self._retry_at = 0.0

    def heartbeat(self, session_id, viewer_id):
        with self._lock:
            if len(self._viewers) >= 64 and (session_id, viewer_id) not in self._viewers:
                raise ReportingUnavailable("Too many open dashboard pages")
            self._viewers[(session_id, viewer_id)] = self.clock()
            self._last_viewer = self.clock()
            if self._pool is None:
                self._generation += 1
                self._state = "initializing"
                self._error = None
                self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="dashboard-report")
                generation = self._generation
                self._initialization = self._pool.submit(self._initialize, generation)
            elif self._state == "unavailable" and self.clock() >= self._retry_at:
                self._state = "initializing"
                self._initialization = self._pool.submit(self._initialize, self._generation)
            return self.state()

    def _initialize(self, generation):
        error = None
        try:
            self.initialize()
        except Exception as exc:
            error = storage_error(exc)
            logging.getLogger(__name__).error(
                "Dashboard reporting initialization failed: %s (exception=%s, sqlite=%s, errno=%s)",
                error, type(exc).__name__, getattr(exc, "sqlite_errorname", None), getattr(exc, "errno", None),
            )
        with self._lock:
            if generation == self._generation and self._pool is not None:
                self._state = "awake" if error is None else "unavailable"
                self._error = error
                self._retry_at = self.clock() + self._retry_seconds if error else 0.0

    def state(self):
        with self._lock:
            return {"state": self._state, "viewers": len(self._viewers),
                    "idle_seconds": self.idle_seconds, "error": self._error}

    def leave(self, session_id, viewer_id=None):
        with self._lock:
            self._viewers = {
                key: value for key, value in self._viewers.items()
                if not (key[0] == session_id and (viewer_id is None or key[1] == viewer_id))
            }

    def tick(self, valid_sessions=None):
        retired = None
        with self._lock:
            now = self.clock()
            self._viewers = {
                key: value for key, value in self._viewers.items()
                if now - value < self.idle_seconds and (valid_sessions is None or key[0] in valid_sessions)
            }
            if self._pool is not None and not self._viewers and now - self._last_viewer >= self.idle_seconds:
                retired = self._pool
                self._pool = None
                self._state = "draining"
                self._generation += 1
                generation = self._generation
        if retired is not None:
            # Existing bounded database reads finish; queued reports are cancelled.
            # No database connection, reporting thread, chart or aggregation task
            # remains once we announce sleeping.
            retired.shutdown(wait=True, cancel_futures=True)
            with self._lock:
                if self._generation != generation:
                    return
                self._state = "sleeping"
            self.on_sleep()

    def report(self, session_id, function, *args, **kwargs):
        if not self._slots.acquire(blocking=False):
            raise ReportingUnavailable("Reporting is busy; retry shortly")
        try:
            with self._lock:
                if self._pool is None or not any(key[0] == session_id for key in self._viewers):
                    raise ReportingUnavailable("Open a dashboard page before requesting reports")
                future = self._pool.submit(function, *args, **kwargs)
            return future.result()
        finally:
            self._slots.release()

    def close(self):
        with self._lock:
            pool, self._pool = self._pool, None
            self._viewers.clear()
            self._generation += 1
            self._state = "sleeping"
        if pool is not None:
            pool.shutdown(wait=True, cancel_futures=True)
