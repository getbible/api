"""Bounded, short-lived report reuse; concurrent identical reads share work."""

from collections import OrderedDict
from concurrent.futures import Future
import json
from pathlib import Path
import threading
import time


class ReportCache:
    def __init__(self, database, *, ttl=10.0, max_bytes=8 * 1024 * 1024, max_entries=32):
        self.database = Path(database)
        self.ttl = ttl
        self.max_bytes = max_bytes
        self.max_entries = max_entries
        self._lock = threading.Lock()
        self._cached = OrderedDict()
        self._pending = {}
        self._bytes = 0
        self._generation = 0

    def _revision(self):
        # Include WAL changes and inode replacement: both ingestion and reset /
        # migration invalidate results. Never open another database connection.
        revision = []
        for path in (self.database, Path(str(self.database) + "-wal")):
            try:
                stat = path.stat()
                revision.append((stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns))
            except FileNotFoundError:
                revision.append(None)
        return tuple(revision)

    def clear(self):
        with self._lock:
            self._generation += 1
            self._cached.clear()
            self._bytes = 0

    def get(self, key, compute):
        revision = self._revision()
        with self._lock:
            key = (self._generation, revision, key)
            cached = self._cached.pop(key, None)
            if cached is not None:
                expires, encoded = cached
                if expires > time.monotonic():
                    self._cached[key] = cached
                    return json.loads(encoded)
                self._bytes -= len(encoded)
            future = self._pending.get(key)
            owner = future is None
            if owner:
                future = self._pending[key] = Future()
        if not owner:
            return json.loads(future.result())
        try:
            result = compute()
            encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            with self._lock:
                if key[0] == self._generation and len(encoded) <= self.max_bytes:
                    self._cached[key] = (time.monotonic() + self.ttl, encoded)
                    self._bytes += len(encoded)
                    while self._bytes > self.max_bytes or len(self._cached) > self.max_entries:
                        _, (_, removed) = self._cached.popitem(last=False)
                        self._bytes -= len(removed)
            future.set_result(encoded)
            # Each caller owns a fresh response; HTTP handlers may add live state.
            return json.loads(encoded)
        except BaseException as exc:
            future.set_exception(exc)
            raise
        finally:
            with self._lock:
                self._pending.pop(key, None)
