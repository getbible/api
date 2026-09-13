"""Private, per-worker cache controls and cheap request activity counters.

The listener starts after Gunicorn forks. It never exposes an HTTP route and
accepts only the service account or root over a mode-0600 Unix socket. Public
Librarian methods own all corpus loading, invalidation, and cache accounting.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import threading
import time

_CODE = re.compile(r"[a-z0-9][a-z0-9_-]{0,29}")


def process_memory() -> dict:
    """Measured process memory; RSS includes pages shared with other workers."""
    values = {"rss_bytes": None, "private_bytes": None}
    try:
        fields = dict(line.split(":", 1) for line in Path("/proc/self/smaps_rollup").read_text().splitlines() if ":" in line)
        values["rss_bytes"] = int(fields["Rss"].split()[0]) * 1024
        values["private_bytes"] = sum(int(fields.get(key, "0").split()[0]) for key in ("Private_Clean", "Private_Dirty", "Private_Hugetlb")) * 1024
    except (OSError, KeyError, ValueError):
        try:
            values["rss_bytes"] = int(Path("/proc/self/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE")
        except (OSError, ValueError, IndexError):
            pass
    return values


class WorkerControl:
    def __init__(self, bible, settings, kind: str):
        self.bible = bible
        self.settings = settings
        self.kind = kind
        self.lock = threading.Lock()
        self.source_lock = threading.Lock()
        self.activity = {"inflight": 0, "completed": 0, "errors": 0, "started_at": time.time()}
        self.source_path = Path(settings.repository) / settings.version
        self.source = None
        # Operational receipts from public warm_query reports, inherited by
        # pre-fork workers. A chapter count alone cannot prove a full warm-up.
        self.query_warms = {}
        self.freshness_time = None
        self.next_source_check = 0.0
        self.listener = None
        self.socket_path = None
        self.stopped = threading.Event()

    def publication_token(self):
        try:
            metadata = self.source_path.lstat()
            return (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns)
        except OSError:
            return None

    def source_identity(self):
        # The static publisher replaces this symlink atomically. No Bible file
        # scans or checksums are introduced in the request path.
        try:
            target = self.source_path.resolve(strict=True)
            metadata = target.stat()
            return (str(target), metadata.st_dev, metadata.st_ino)
        except OSError:
            return None

    def refresh_source(self, *, force=False):
        now = time.monotonic()
        if not force and now < self.next_source_check:
            return False
        with self.source_lock:
            if not force and now < self.next_source_check:
                return False
            self.next_source_check = now + 1.0
            try:
                checked = (Path(self.settings.repository) / f".freshness-{self.settings.version}").stat().st_mtime
            except OSError:
                checked = None
            identity = self.source_identity()
            if identity is None:
                return False  # preserve the serving cache on an unavailable mount
            if force or identity != self.source:
                self.bible.transition_source(hashlib.sha256(repr(identity).encode()).hexdigest())
                if identity != self.source:
                    with self.lock:
                        self.query_warms.clear()
                self.source = identity
                self.freshness_time = checked
                return True
            self.freshness_time = checked
        return False

    def cache_seconds(self, configured):
        """Expire consumer caches relative to the last successful source check."""
        from flask import g, has_request_context
        checked = g.get("getbible_freshness_time", self.freshness_time) if has_request_context() else self.freshness_time
        if checked is None:
            return configured
        return max(0, min(configured, int(checked + configured - time.time())))

    @staticmethod
    def query_limits(cache):
        chapters = cache.get("chapters", {})
        return (chapters.get("limit"), chapters.get("memory_bytes_limit"), cache.get("ttl_seconds"))

    def translation_status(self, cache):
        """Interpret public cache metadata without loading or inspecting scripture."""
        query = cache.get("query_translations", {})
        search = cache.get("search_corpora", {}).get("translations", {})
        snapshots = cache.get("translation_cache", {}).get("translations", {})
        with self.lock:
            receipts = dict(self.query_warms)
        now = time.time()
        ttl = cache.get("ttl_seconds", 0)

        def stale(item):
            return bool(item and (item.get("stale") or (
                item.get("checked_at") is not None and item["checked_at"] + ttl <= now)))

        statuses = {}
        for code in sorted(query.keys() | search.keys() | snapshots.keys() | receipts.keys()):
            chapters = query.get(code, {})
            corpus = search.get(code, {})
            snapshot = snapshots.get(code, {})
            receipt = receipts.get(code, {})
            if receipt.get("source_generation") != cache.get("source", {}).get("generation"):
                receipt = {}
            resident = bool(chapters or corpus or snapshot)
            expected = receipt.get("loaded")
            retention_limited = bool(expected and receipt.get("retained", 0) < expected
                                     and receipt.get("limits") == self.query_limits(cache))
            if self.kind == "query":
                expired = chapters.get("expired_chapters", 0) > 0 or receipt.get("stale", False)
                ready = bool(expected and chapters.get("chapters", 0) >= expected and not expired)
                if not chapters:
                    expired = expired or stale(snapshot)
                reason = ("All warmed chapters are resident and fresh." if ready else
                          "Cached chapters need rechecking on use." if expired else
                          "The last warm-up could not retain every chapter within the cache limits." if retention_limited else
                          "Some data is resident; full chapter coverage has not been established." if resident else
                          "No translation data is resident.")
            else:
                expired = stale(corpus) if corpus else stale(snapshot)
                indexed = any(index.get("case_sensitive") is False and index.get("fold_diacritics") is True
                              for index in corpus.get("indexes", []))
                ready = bool(corpus.get("verses", 0) > 0 and indexed and not expired)
                retention_limited = False
                reason = ("The translation corpus and default search index are resident and fresh." if ready else
                          "The cached translation needs rechecking on use." if expired else
                          "Some data is resident; the default search index is not resident." if resident else
                          "No translation data is resident.")
            statuses[code] = {"ready": ready, "resident": resident, "target": self.kind,
                              "state": "warm" if ready else "stale" if expired else "partial" if resident else "cold",
                              "reason": reason, "expected_chapters": expected,
                              "retention_limited": retention_limited}
        return statuses

    def record_query_warm(self, translation, report):
        if not isinstance(report, dict) or not isinstance(report.get("loaded"), int):
            return
        cache = self.bible.cache_info()
        with self.lock:
            self.query_warms[translation] = {
                "loaded": report["loaded"], "retained": report.get("chapters", 0),
                "stale": report.get("stale", False), "source_generation": report.get("source_generation"),
                "limits": self.query_limits(cache),
            }

    def warm(self, translation):
        """Fill absent/expired coverage using the librarian's normal warm path."""
        status = self.translation_status(self.bible.cache_info()).get(translation, {})
        if status.get("ready") or (status.get("retention_limited") and status.get("state") == "partial"):
            return {"abbreviation": translation, "target": self.kind, "skipped": True,
                    "reason": "already_warm" if status.get("ready") else "retention_limited",
                    "message": status["reason"]}
        if self.kind == "query":
            result = self.bible.warm_query(translation)
            self.record_query_warm(translation, result)
        else:
            result = self.bible.warm_translation(translation, diacritics="fold")
        return result

    def snapshot(self):
        cache = self.bible.cache_info()
        with self.lock:
            activity = dict(self.activity)
        return {"pid": os.getpid(), **process_memory(), "activity": activity,
                "source_revision": hashlib.sha256(repr(self.source).encode()).hexdigest(),
                "cache": cache, "translation_status": self.translation_status(cache), "scope": "worker",
                "memory_note": "RSS includes shared pages; cache bytes are estimates, not process RSS."}

    def execute(self, command):
        action = command.get("action")
        self.refresh_source()
        if action == "info":
            return self.snapshot()
        if action == "refresh-source":
            changed = self.refresh_source(force=True)
            return {**self.snapshot(), "result": {"source_refreshed": changed}}
        translation = command.get("translation", "")
        if not isinstance(translation, str) or not _CODE.fullmatch(translation):
            raise ValueError("A valid translation code is required.")
        if action == "warm":
            result = self.warm(translation)
        elif action == "drop":
            result = self.bible.drop_translation(translation, disk=False)
            with self.lock:
                self.query_warms.pop(translation, None)
        elif action == "reload":
            result = self.bible.reload_translation(translation, target=self.kind)
            if self.kind == "query" and isinstance(result, dict):
                self.record_query_warm(translation, result.get("query"))
            elif self.kind == "search" and isinstance(result, dict):
                # reload_translation uses the librarian's default analysis
                # policy. Reuse that corpus and ensure the same folded index
                # as startup/manual warming is also resident.
                result["search"] = self.bible.warm_translation(translation, diacritics="fold")
        else:
            raise ValueError("Unknown cache operation.")
        return {**self.snapshot(), "result": result}

    def start(self):
        directory = os.environ.get("GETBIBLE_CONTROL_DIR", "")
        if not directory or self.listener is not None:
            return
        # No thread or socket exists in the preloaded parent.
        self.activity["started_at"] = time.time()
        path = Path(directory)
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)
        self.socket_path = path / f"{os.getpid()}.sock"
        self.socket_path.unlink(missing_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o600)
        listener.listen(8)
        listener.settimeout(1)
        self.listener = listener
        threading.Thread(target=self.serve, name="getbible-control", daemon=True).start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                connection.settimeout(5)
                try:
                    _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
                    if uid not in {0, os.geteuid()}:
                        continue
                    raw = bytearray()
                    while b"\n" not in raw and len(raw) <= 65536:
                        block = connection.recv(4096)
                        if not block:
                            break
                        raw.extend(block)
                    if len(raw) > 65536 or b"\n" not in raw:
                        raise ValueError("Invalid cache control request.")
                    command = json.loads(bytes(raw).split(b"\n", 1)[0])
                    if not isinstance(command, dict):
                        raise ValueError("Expected a JSON object.")
                    response = {"ok": True, "worker": self.execute(command)}
                except Exception as error:
                    response = {"ok": False, "error": str(error), "pid": os.getpid()}
                try:
                    connection.sendall(json.dumps(response, ensure_ascii=False, default=str).encode() + b"\n")
                except OSError:
                    pass

    def close(self):
        self.stopped.set()
        if self.listener:
            self.listener.close()
        if self.socket_path:
            self.socket_path.unlink(missing_ok=True)


def install_control(app, bible, settings, kind):
    from flask import g

    control = WorkerControl(bible, settings, kind)
    app.extensions["getbible_control"] = control

    @app.before_request
    def begin():
        control.refresh_source()
        g.getbible_publication = control.publication_token()
        g.getbible_source = control.source
        g.getbible_freshness_time = control.freshness_time
        with control.lock:
            control.activity["inflight"] += 1
        g.getbible_activity_counted = True

    @app.after_request
    def finish(response):
        if (g.get("getbible_source") != control.source
                or g.get("getbible_publication") != control.publication_token()):
            # A response started on the old publication must not receive the
            # new publication's cache lifetime, even when reload races it.
            response.headers["Cache-Control"] = "no-store"
            response.headers["CDN-Cache-Control"] = "no-store"
        if g.get("getbible_activity_counted"):
            with control.lock:
                control.activity["completed"] += 1
                control.activity["errors"] += int(response.status_code >= 500)
        return response

    @app.teardown_request
    def teardown(error):
        if g.get("getbible_activity_counted"):
            with control.lock:
                control.activity["inflight"] = max(0, control.activity["inflight"] - 1)
            g.getbible_activity_counted = False
