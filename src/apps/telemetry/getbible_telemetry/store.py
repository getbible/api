"""Canonical, time-indexed traffic store and on-demand reporting.

One request may have an nginx record and a runtime semantic record. They share
one row; only nginx records count as origin requests. Runtime-only rows remain
discoverable and are reported explicitly, never silently counted twice.
"""

from __future__ import annotations

import ipaddress
import json
import math
import os
import re
import sqlite3
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import parse_qsl, unquote, urlencode, urlsplit, urlunsplit

from .catalog import LocalCatalog

_SECRET_KEYS = frozenset({
    "authorization", "proxy_authorization", "password", "passwd", "otp",
    "challenge", "challenge_code", "session", "session_id", "session_token",
    "cookie", "set_cookie", "secret", "api_key", "access_token", "refresh_token",
    "bearer", "bot_token", "telegram_token", "telegram_bot_token",
})
_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
_SECRET_ASSIGNMENT = re.compile(r"(?i)\b(password|passwd|otp|access_token|refresh_token|api_key|bot_token|authorization|cookie|secret|token)=([^\s&\"']+)")
_TELEGRAM_BOT = re.compile(r"\bbot\d{5,}:[A-Za-z0-9_-]{20,}")
_TOKEN_ID = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
_STATIC_METADATA = frozenset({
    "books", "chapters", "checksums", "docs", "health", "healthz", "index",
    "metadata", "metrics", "openapi", "query", "ready", "readyz", "search",
    "translations", "versions",
})
_DIMENSIONS = {
    "endpoint": "endpoint", "version": "version", "status": "status",
    "auth": "auth", "ip": "remote_addr", "path": "path",
    "translation": "translation", "book": "book", "search": "search",
    "reference": "reference", "cache": "cache", "method": "method",
    "token": "token_id", "user_agent": "user_agent", "operation": "operation",
    "referrer": "referrer", "endpoint_kind": "endpoint_kind",
}
_USAGE = frozenset({"translation", "book", "search", "reference"})
SCHEMA_VERSION = 2


class TelemetrySchemaError(RuntimeError):
    """The stored history needs an explicit operator decision, never a reset."""

    def __init__(self, found: int) -> None:
        self.found = found
        self.expected = SCHEMA_VERSION
        super().__init__(
            f"Traffic history schema {found} is incompatible with schema {SCHEMA_VERSION}. "
            "History has been preserved. Review the installed manager version and back up "
            "history before choosing getbible logs reset --discard-history; no history conversion is performed."
        )


def reset_history(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Explicit clean start; retain ingestion cursors, never remodel old rows.

    The caller must hold the collector lifetime lock. A cutoff also excludes
    old buffered producer records that have not yet reached a source cursor.
    """
    cutoff = time.time()
    db = sqlite3.connect(path, timeout=5)
    try:
        db.executescript("BEGIN IMMEDIATE;"
                        "DROP TABLE IF EXISTS requests; DROP TABLE IF EXISTS events;"
                        "DROP TABLE IF EXISTS metrics; DROP TABLE IF EXISTS retention;" + _SCHEMA)
        db.execute("DELETE FROM metadata WHERE key!='journal_cursor'")
        db.execute("INSERT INTO metadata(key,value) VALUES('collection_started',?)", (json.dumps(cutoff),))
        db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        db.execute("INSERT INTO retention(stamp,reason,request_rows,event_rows,metric_rows,detail) "
                   "VALUES(?, 'explicit_reset', 0, 0, 0, ?)",
                   (cutoff, "Operator requested a fresh traffic history; producer cursors retained and earlier buffered requests excluded."))
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        db.close()
    return {"schema_version": SCHEMA_VERSION, "collection_started": cutoff, "history_reset": True}


def _key(value: str) -> str:
    return value.lower().replace("-", "_")


def redact(value: Any, *, field: str = "") -> Any:
    """Defence in depth; producers must never send credential headers/bodies.

The ``token`` field in the trusted API log schema is an internal token ID,
not a bearer token. Credentials embedded in URLs are always redacted.
"""
    if _key(field) in _SECRET_KEYS:
        return "[REDACTED]"
    if isinstance(value, dict):
        return {str(k): redact(v, field=str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str):
        value = _BEARER.sub("Bearer [REDACTED]", value)
        value = _SECRET_ASSIGNMENT.sub(lambda match: match[1] + "=[REDACTED]", value)
        value = _TELEGRAM_BOT.sub("bot[REDACTED]", value)
        if _key(field) in {"uri", "query", "referer", "referrer", "url"}:
            return redact_url(value, query_only=_key(field) == "query")
        return value
    return value


def redact_url(value: str, *, query_only: bool = False) -> str:
    try:
        parts = urlsplit("?" + value if query_only else value)
        pairs = parse_qsl(parts.query, keep_blank_values=True)
        changed = any(_key(k) in _SECRET_KEYS | {"token"} for k, _ in pairs)
        if not changed and not parts.username:
            return value
        query = urlencode([(k, "[REDACTED]" if _key(k) in _SECRET_KEYS | {"token"} else v)
                           for k, v in pairs])
        if query_only:
            return query
        host = parts.netloc.rsplit("@", 1)[-1]
        return urlunsplit((parts.scheme, host, parts.path, query, parts.fragment))
    except ValueError:
        return "[INVALID URL]"


def timestamp(value: Any, fallback: float | None = None) -> float:
    try:
        result = float(value)
    except (ValueError, TypeError):
        try:
            result = datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
        except (ValueError, TypeError, OverflowError):
            result = time.time() if fallback is None else fallback
    return result if math.isfinite(result) else (time.time() if fallback is None else fallback)


def _number(value: Any, default: float = 0) -> float:
    try:
        number = float(value)
        return number if math.isfinite(number) else default
    except (ValueError, TypeError):
        return default


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return str(value)


def _static_bible_path(pieces: list[str]) -> tuple[str, str]:
    """Recognise text, translation metadata and checksum paths."""
    if not pieces:
        return "", ""
    translation = re.sub(r"\.(json|sha)$", "", pieces[0]).casefold()
    if (translation in _STATIC_METADATA
            or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", translation)):
        return "", ""
    if len(pieces) == 1 and pieces[0].endswith((".json", ".sha")):
        return translation, ""
    if pieces[0].casefold() != translation:
        return "", ""
    if len(pieces) == 2 and pieces[1] in {"books.json", "books.sha", "checksums.json", "checksums.sha"}:
        return translation, ""
    if len(pieces) == 2 and re.fullmatch(r"[1-9][0-9]*\.(json|sha)", pieces[1]):
        return translation, pieces[1].split(".", 1)[0]
    if (len(pieces) == 3 and re.fullmatch(r"[1-9][0-9]*", pieces[1])
            and (re.fullmatch(r"[1-9][0-9]*\.(json|sha)", pieces[2])
                 or pieces[2] in {"chapters.json", "chapters.sha", "checksums.json", "checksums.sha"})):
        return translation, pieces[1]
    return "", ""


def _normalise(entry: dict[str, Any], endpoint: str, source: str, record_key: str,
               catalog: LocalCatalog) -> dict[str, Any]:
    entry = redact(entry)
    endpoint = endpoint or _text(entry.get("endpoint") or entry.get("host"))
    uri = _text(entry.get("uri") or entry.get("path"))
    path = uri.split("?", 1)[0]
    query = _text(entry.get("query") or (uri.split("?", 1)[1] if "?" in uri else ""))
    try:
        params = dict(parse_qsl(query, keep_blank_values=True))
    except ValueError:
        params = {}
    pieces = [unquote(part) for part in path.split("/") if part]
    version = _text(entry.get("version"))
    if pieces and re.fullmatch(r"v\d+", pieces[0]):
        version = version or pieces.pop(0)
    configured = catalog.endpoint(endpoint, version)
    # Edge semantic headers are emitted by the runtime and kept with nginx's
    # cached response. They describe the resolved request even on cache HITs.
    semantic = {}
    for key in ("translation", "books", "reference", "search", "operation", "version", "endpoint_kind"):
        value = entry.get("resolved_" + key)
        if value not in (None, "", "-"):
            semantic[key] = redact(unquote(str(value)), field=key)
        elif key in entry:
            semantic[key] = entry[key]
    version = _text(semantic.get("version")) or version
    operation = _text(semantic.get("operation"))
    kind = _text(semantic.get("endpoint_kind")) or configured["kind"]
    if not kind and source == "runtime":
        logger = _text(entry.get("logger"))
        kind = "query" if logger == "getbible.query" or operation == "scripture" else "search" if logger == "getbible.search" or operation in {"search", "reference"} else ""
    translation = _text(semantic.get("translation")).casefold()
    reference = _text(semantic.get("reference"))
    search = _text(semantic.get("search"))
    book = semantic.get("books") or entry.get("book") or []
    static_translation, static_book = _static_bible_path(pieces)
    if not kind and static_translation:
        kind = "static"
    if kind == "static":
        translation = translation or static_translation
        book = book or static_book
        operation = operation or ("static" if static_translation else "http")
    elif kind in {"query", "search"}:
        # For uncached requests the runtime supplies all resolved facts. Path
        # inference is limited to canonical forms; it never guesses what the
        # librarian would resolve from a reference or from a search body.
        canonical = len(pieces) == 2 and re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", pieces[0].casefold())
        if canonical:
            translation = translation or pieces[0].casefold()
            if kind == "query":
                reference = reference or pieces[1]
                operation = operation or "scripture"
            else:
                search = search or pieces[1]
                operation = operation or "search"
        elif kind == "search" and params.get("q") and len(pieces) <= 1:
            translation = translation or (pieces[0] if pieces else params.get("translation") or configured["default_translation"])
            search = search or params["q"]
            operation = operation or "search"
        if operation in {"scripture", "search", "reference"} and not translation:
            translation = configured["default_translation"]
        if operation in {"scripture", "search", "reference"} and not version:
            version = configured["version"]
        if kind == "search":
            search = search.strip()
    translation = translation.casefold()
    if isinstance(book, str):
        try:
            book = json.loads(book) if book.startswith("[") else [book]
        except ValueError:
            book = [book]
    if not isinstance(book, (list, tuple)):
        book = [book]
    names = catalog.books(endpoint, version, translation) if translation and book else {}
    aliases = {name.casefold(): number for number, name in names.items()}
    books = list(dict.fromkeys(aliases.get(str(value).casefold(), str(value)) for value in book if str(value)))
    book_names = {number: names[number] for number in books if number in names}
    token_id = _text(entry.get("token_id") or entry.get("token"))
    if not _TOKEN_ID.fullmatch(token_id):
        token_id = ""
    auth = _text(entry.get("auth_state") or entry.get("auth"))
    if auth not in {"anonymous", "valid", "rejected"}:
        auth = "valid" if token_id else "anonymous"
    address = _text(entry.get("remote_addr"))
    try:
        address = str(ipaddress.ip_address(address))
    except ValueError:
        pass
    duration = _number(entry.get("duration_ms"))
    if source == "edge":
        duration = _number(entry.get("request_time")) * 1000
    return {
        "endpoint": endpoint,
        "request_id": _text(entry.get("request_id")) or record_key,
        "stamp": timestamp(entry.get("time")), "method": _text(entry.get("method")),
        "path": path, "query": query, "version": version,
        "status": int(_number(entry.get("status"))), "duration_ms": duration,
        "bytes": int(_number(entry.get("bytes", entry.get("response_bytes")))),
        "remote_addr": address, "token_id": token_id, "auth": auth,
        "cache": _text(entry.get("cache")), "translation": translation,
        "book": _text(books) if books else "", "book_names": _text(book_names),
        "reference": reference, "search": search, "endpoint_kind": kind,
        "operation": operation,
        "user_agent": _text(entry.get("user_agent")),
        "referrer": "" if entry.get("referrer", entry.get("referer")) == "-" else _text(entry.get("referrer") or entry.get("referer")),
        "payload": json.dumps(entry, ensure_ascii=False, separators=(",", ":")),
    }


_SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sources (
    identity TEXT PRIMARY KEY, path TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0,
    fingerprint TEXT NOT NULL DEFAULT '', fingerprint_bytes INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL, closed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS requests (
    id INTEGER PRIMARY KEY, endpoint TEXT NOT NULL, request_id TEXT NOT NULL, stamp REAL NOT NULL,
    method TEXT NOT NULL, path TEXT NOT NULL, query TEXT NOT NULL, version TEXT NOT NULL,
    status INTEGER NOT NULL, duration_ms REAL NOT NULL, bytes INTEGER NOT NULL,
    remote_addr TEXT NOT NULL, token_id TEXT NOT NULL, auth TEXT NOT NULL,
    cache TEXT NOT NULL, translation TEXT NOT NULL, book TEXT NOT NULL,
    reference TEXT NOT NULL, search TEXT NOT NULL, operation TEXT NOT NULL, user_agent TEXT NOT NULL,
    endpoint_kind TEXT NOT NULL, referrer TEXT NOT NULL, book_names TEXT NOT NULL,
    edge_json TEXT, runtime_json TEXT, UNIQUE(endpoint, request_id)
);
CREATE INDEX IF NOT EXISTS requests_time ON requests(stamp, id);
CREATE INDEX IF NOT EXISTS requests_endpoint_time ON requests(endpoint, stamp);
CREATE INDEX IF NOT EXISTS requests_translation_time ON requests(translation, stamp);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, endpoint TEXT NOT NULL,
    source TEXT NOT NULL, level TEXT NOT NULL, event TEXT NOT NULL, payload TEXT NOT NULL,
    record_key TEXT NOT NULL UNIQUE
);
CREATE INDEX IF NOT EXISTS events_time ON events(stamp, id);
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS metrics_time ON metrics(stamp, id);
CREATE TABLE IF NOT EXISTS retention (
    id INTEGER PRIMARY KEY, stamp REAL NOT NULL, reason TEXT NOT NULL,
    first_stamp REAL, last_stamp REAL, request_rows INTEGER NOT NULL,
    event_rows INTEGER NOT NULL, metric_rows INTEGER NOT NULL, detail TEXT NOT NULL
);
"""


class TelemetryStore:
    """One connection per process/thread; use a context manager to close it."""

    def __init__(self, path: str | os.PathLike[str], *, readonly: bool = False,
                 query_timeout: float = 15.0, catalog: LocalCatalog | None = None) -> None:
        self.path = Path(path)
        self.readonly = readonly
        self.query_timeout = max(0.1, query_timeout)
        self.catalog = catalog or LocalCatalog()
        self._read_deadline = time.monotonic() + self.query_timeout if readonly else None
        if readonly:
            self.db = sqlite3.connect(self.path.absolute().as_uri() + "?mode=ro", uri=True, timeout=2)
        else:
            self.path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
            self.db = sqlite3.connect(self.path, timeout=5)
            os.chmod(self.path, 0o640)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA busy_timeout=2000")
        self.db.execute("PRAGMA temp_store=FILE")
        self.db.execute("PRAGMA cache_size=-8192")
        schema = self.db.execute("PRAGMA user_version").fetchone()[0]
        if schema not in ({SCHEMA_VERSION} if readonly else {0, SCHEMA_VERSION}):
            self.db.close()
            raise TelemetrySchemaError(schema)
        if readonly:
            self.db.execute("PRAGMA query_only=ON")
        else:
            fresh = self.db.execute("PRAGMA user_version").fetchone()[0] == 0
            if fresh:
                self.db.execute("PRAGMA auto_vacuum=INCREMENTAL")
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.execute("PRAGMA wal_autocheckpoint=1000")
            self.db.executescript(_SCHEMA)
            self.db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
            self.db.commit()
        cutoff = self.db.execute("SELECT value FROM metadata WHERE key='collection_started'").fetchone()
        self.collection_started = float(json.loads(cutoff[0])) if cutoff else 0

    def __enter__(self) -> "TelemetryStore":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def close(self) -> None:
        self.db.close()

    def _deadline(self) -> None:
        deadline = self._read_deadline or time.monotonic() + self.query_timeout
        self.db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10_000)

    def append(self, entry: dict[str, Any], *, endpoint: str, source: str,
               record_key: str) -> None:
        """Append within the caller's transaction; no per-record commit/fsync."""
        if self.collection_started and timestamp(entry.get("time")) < self.collection_started:
            return
        if source not in {"edge", "runtime"} or (source == "runtime" and entry.get("event") != "request"):
            clean = redact(entry)
            self.db.execute(
                "INSERT OR IGNORE INTO events(stamp,endpoint,source,level,event,payload,record_key) "
                "VALUES(?,?,?,?,?,?,?)",
                (timestamp(entry.get("time")), endpoint, source, _text(entry.get("level") or "INFO"),
                 _text(entry.get("event") or "diagnostic"), json.dumps(clean, ensure_ascii=False,
                 separators=(",", ":")), record_key),
            )
            return
        row = _normalise(entry, endpoint, source, record_key, self.catalog)
        payload = row.pop("payload")
        row["edge_json"] = payload if source == "edge" else None
        row["runtime_json"] = payload if source == "runtime" else None
        columns = list(row)
        # Edge owns transport facts. Semantic fields prefer nonempty runtime
        # facts, regardless of which buffered producer arrives first.
        transport = {"stamp", "method", "path", "query", "status", "duration_ms", "bytes",
                     "remote_addr", "token_id", "auth", "cache", "user_agent", "referrer"}
        semantic = {"version", "translation", "book", "book_names", "reference", "search", "operation", "endpoint_kind"}
        assignments = []
        for name in columns:
            if name in {"endpoint", "request_id"}:
                continue
            if name in {"edge_json", "runtime_json"}:
                assignments.append(f"{name}=COALESCE(excluded.{name}, requests.{name})")
            elif name in transport:
                assignments.append(f"{name}=CASE WHEN excluded.edge_json IS NOT NULL "
                                   f"OR requests.edge_json IS NULL THEN excluded.{name} ELSE requests.{name} END")
            elif name in semantic:
                assignments.append(f"{name}=CASE WHEN excluded.{name} NOT IN ('','{{}}') AND "
                                   f"(excluded.runtime_json IS NOT NULL OR requests.{name}='') "
                                   f"THEN excluded.{name} ELSE requests.{name} END")
        self.db.execute(
            f"INSERT INTO requests({','.join(columns)}) VALUES({','.join('?' for _ in columns)}) "
            "ON CONFLICT(endpoint,request_id) DO UPDATE SET " + ",".join(assignments),
            tuple(row.values()),
        )

    def append_metric(self, payload: dict[str, Any], *, stamp: float | None = None) -> None:
        self.db.execute("INSERT INTO metrics(stamp,payload) VALUES(?,?)",
                        (time.time() if stamp is None else stamp,
                         json.dumps(redact(payload), ensure_ascii=False, separators=(",", ":"))))

    def note_gap(self, reason: str, detail: str, *, first_stamp: float | None = None,
                 last_stamp: float | None = None) -> None:
        self.db.execute("INSERT INTO retention(stamp,reason,first_stamp,last_stamp,request_rows,"
                        "event_rows,metric_rows,detail) VALUES(?,?,?,?,0,0,0,?)",
                        (time.time(), reason, first_stamp, last_stamp, detail))

    @staticmethod
    def _where(start: float, end: float, endpoint: str | None = None,
               version: str | None = None, *, origin_only: bool = True,
               filters: dict[str, Any] | None = None) -> tuple[str, list[Any]]:
        if not math.isfinite(start) or not math.isfinite(end) or start > end:
            raise ValueError("invalid time range")
        terms, values = ["requests.stamp>=?", "requests.stamp<?"], [start, end]
        if origin_only:
            terms.append("edge_json IS NOT NULL")
        for name, value in (("endpoint", endpoint), ("version", version)):
            if value is not None:
                terms.append("requests." + name + "=?")
                values.append(value)
        for name, value in (filters or {}).items():
            if name == "usage":
                if value not in _USAGE:
                    raise ValueError("unsupported usage ranking")
                terms.append("(status BETWEEN 200 AND 299 OR status=304)")
                terms.append("edge_json IS NOT NULL")
                terms.append("method IN ('GET','HEAD','POST')")
                if value == "search":
                    terms.append("endpoint_kind='search' AND operation IN ('search','reference')")
                elif value == "reference":
                    terms.append("endpoint_kind='query' AND operation='scripture'")
                else:
                    terms.append("operation IN ('static','scripture','search','reference')")
                continue
            if name in {"successful", "origin_only"}:
                if str(value).lower() not in {"true", "false", "1", "0"}:
                    raise ValueError(name + " must be true or false")
                if str(value).lower() in {"true", "1"}:
                    terms.append("(status BETWEEN 200 AND 299 OR status=304)" if name == "successful" else "edge_json IS NOT NULL")
                continue
            if name in {"q", "referrer_contains", "user_agent_contains", "path_contains"}:
                columns = ["path", "query", "translation", "reference", "search", "remote_addr", "referrer", "user_agent", "book_names"] if name == "q" else [name.removesuffix("_contains")]
                terms.append("(" + " OR ".join("instr(lower(requests." + column + "),lower(?))>0" for column in columns) + ")")
                values.extend([str(value)] * len(columns))
                continue
            if name not in _DIMENSIONS:
                raise ValueError("unsupported filter: " + name)
            if name == "book":
                terms.append("EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(book) AND substr(book,1,1)='[' "
                             "THEN book ELSE json_array(book) END) WHERE CAST(value AS TEXT)=?)")
                values.append(str(value))
                continue
            terms.append("requests." + _DIMENSIONS[name] + "=?")
            values.append(value)
        return " AND ".join(terms), values

    def breakdown(self, dimension: str, start: float, end: float, *, endpoint: str | None = None,
                  version: str | None = None, top: int = 20,
                  filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if dimension not in _DIMENSIONS:
            raise ValueError("unsupported dimension: " + dimension)
        scoped = dict(filters or {})
        if dimension in _USAGE:
            scoped["successful"] = "true"
        if dimension == "search":
            scoped["endpoint_kind"] = "search"
        elif dimension == "reference":
            scoped["endpoint_kind"] = "query"
        # Scope constraints intersect with existing view filters; selecting a
        # query domain must not silently replace that filter with search.
        where, values = self._where(start, end, endpoint, version, filters=filters)
        extra, extra_values = self._where(start, end, origin_only=True,
                                         filters={key: value for key, value in scoped.items() if key not in (filters or {}) or (filters or {})[key] != value})
        where += " AND " + extra
        values.extend(extra_values)
        if dimension == "search":
            where += " AND operation IN ('search','reference')"
        elif dimension == "reference":
            where += " AND operation='scripture'"
        elif dimension in {"translation", "book"}:
            where += " AND operation IN ('static','scripture','search','reference')"
        self._deadline()
        column = _DIMENSIONS[dimension]
        if dimension in _USAGE | {"referrer", "user_agent"}:
            where += f" AND {column} NOT IN ('','-','[]')"
        if dimension in _USAGE:
            where += " AND method IN ('GET','HEAD','POST')"
        if dimension == "book":
            rows = [dict(row) for row in self.db.execute(
                "SELECT CAST(b.value AS TEXT) AS value,count(DISTINCT requests.id) AS calls,sum(bytes) AS bytes,"
                "avg(duration_ms) AS duration_ms,sum(status>=500) AS errors,"
                "min((SELECT n.value FROM json_each(book_names) n WHERE n.key=CAST(b.value AS TEXT))) AS label FROM requests,"
                "json_each(CASE WHEN json_valid(book) AND substr(book,1,1)='[' THEN book ELSE json_array(book) END) b "
                f"WHERE {where} GROUP BY b.value ORDER BY calls DESC,value LIMIT ?",
                [*values, max(1, min(int(top), 1000))])]
        else:
            rows = [dict(row) for row in self.db.execute(
                f"SELECT {column} AS value, count(*) AS calls, sum(bytes) AS bytes, "
                f"avg(duration_ms) AS duration_ms, sum(status>=500) AS errors "
                f"FROM requests WHERE {where} GROUP BY {column} ORDER BY calls DESC,value LIMIT ?",
                [*values, max(1, min(int(top), 1000))])]
        for row in rows:
            row["filters"] = {**scoped, dimension: row["value"], "origin_only": "true"}
            if endpoint is not None:
                row["filters"]["endpoint"] = endpoint
            if version is not None:
                row["filters"]["version"] = version
            # Exact operation restrictions must also survive the drill-down.
            if dimension in _USAGE:
                inherited = scoped.get("usage")
                row["filters"]["usage"] = inherited if inherited in {"search", "reference"} else dimension
            if dimension == "book" and not row["label"]:
                row["label"] = "Book " + row["value"] if row["value"].isdigit() else row["value"]
        return rows

    def endpoints(self) -> list[dict[str, Any]]:
        """Observed endpoint/version pairs, including rows awaiting an edge log."""
        self._deadline()
        return [dict(row) for row in self.db.execute(
            "SELECT endpoint,version,count(edge_json) AS calls,min(stamp) AS first_seen,max(stamp) AS last_seen "
            "FROM requests GROUP BY endpoint,version ORDER BY endpoint,version")]

    def summary(self, start: float, end: float, *, endpoint: str | None = None,
                version: str | None = None, top: int = 20,
                filters: dict[str, Any] | None = None) -> dict[str, Any]:
        where, values = self._where(start, end, endpoint, version, filters=filters)
        self._deadline()
        row = self.db.execute(
            "SELECT count(*) AS calls, COALESCE(sum(bytes),0) AS bytes, "
            "COALESCE(sum(status>=500),0) AS server_errors, COALESCE(sum(status>=400),0) AS errors, "
            "COALESCE(sum(status=429),0) AS rate_limited, COALESCE(sum(method='OPTIONS'),0) AS preflights, "
            "COALESCE(sum(cache='HIT'),0) AS cache_hits, COALESCE(sum(cache NOT IN ('','-')),0) AS cache_requests, "
            "count(DISTINCT remote_addr) AS unique_ips, count(DISTINCT NULLIF(token_id,'')) AS unique_tokens, "
            "COALESCE(avg(duration_ms),0) AS duration_ms, max(duration_ms) AS max_duration_ms, "
            "min(stamp) AS first_seen, max(stamp) AS last_seen "
            "FROM requests WHERE " + where, values,
        ).fetchone()
        result = dict(row)
        result["from"], result["to"] = start, end
        result["requests_per_second"] = result["calls"] / max(1, end - start)
        result["cache_hit_ratio"] = result["cache_hits"] / result["cache_requests"] if result["cache_requests"] else None
        result["latency_ms"] = self.latency(start, end, endpoint=endpoint, version=version, filters=filters)
        result["breakdowns"] = {dimension: self.breakdown(dimension, start, end, endpoint=endpoint,
                                  version=version, top=top, filters=filters)
                                for dimension in _DIMENSIONS}
        orphan_where, orphan_values = self._where(start, end, endpoint, version, origin_only=False, filters=filters)
        result["runtime_without_edge"] = self.db.execute(
            "SELECT count(*) FROM requests WHERE edge_json IS NULL AND " + orphan_where,
            orphan_values).fetchone()[0]
        result["origin_only"] = True
        result["retention"] = self.storage()
        return result

    def latency(self, start: float, end: float, *, endpoint: str | None = None,
                version: str | None = None, filters: dict[str, Any] | None = None) -> dict[str, Any]:
        """Exact histogram counts with explicitly approximate percentiles.

        SQLite aggregates all rows in SQL; memory is independent of traffic
        volume. Histogram upper bounds are intentionally reported alongside
        percentile estimates, rather than claiming precise sampled values.
        """
        bounds = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000]
        where, values = self._where(start, end, endpoint, version, filters=filters)
        self._deadline()
        cases = "CASE " + " ".join(f"WHEN duration_ms<={bound} THEN {i}" for i, bound in enumerate(bounds))
        cases += f" ELSE {len(bounds)} END"
        counts = dict(self.db.execute(f"SELECT {cases} AS bucket,count(*) FROM requests WHERE {where} GROUP BY bucket", values))
        total = sum(counts.values())
        result: dict[str, Any] = {"approximate": True, "histogram": [
            {"upper_ms": upper, "count": counts.get(i, 0)} for i, upper in enumerate([*bounds, None])]}
        for name, fraction in (("p50", 0.5), ("p95", 0.95), ("p99", 0.99)):
            cumulative, value = 0, None
            for i, bound in enumerate(bounds):
                cumulative += counts.get(i, 0)
                if total and cumulative >= math.ceil(total * fraction):
                    value = bound
                    break
            result[name] = value
        return result

    def series(self, start: float, end: float, bucket_seconds: int = 60, *,
               endpoint: str | None = None, version: str | None = None,
               filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        bucket_seconds = max(1, int(bucket_seconds), math.ceil((end - start) / 2000))
        where, values = self._where(start, end, endpoint, version, filters=filters)
        self._deadline()
        rows = self.db.execute(
            "SELECT CAST(stamp / ? AS INTEGER) * ? AS stamp, count(*) AS calls, "
            "sum(status>=400) AS errors, sum(status>=500) AS server_errors, "
            "sum(status=429) AS rate_limited, sum(bytes) AS bytes, "
            "avg(duration_ms) AS duration_ms, max(duration_ms) AS max_duration_ms, "
            "sum(cache='HIT') AS cache_hits FROM requests WHERE " + where + " GROUP BY 1 ORDER BY 1",
            [bucket_seconds, bucket_seconds, *values])
        return [dict(row, bucket_seconds=bucket_seconds, requests_per_second=row["calls"] / bucket_seconds) for row in rows]

    def requests(self, start: float, end: float, *, endpoint: str | None = None,
                 version: str | None = None, limit: int = 100, cursor: int | None = None,
                 filters: dict[str, Any] | None = None, origin_only: bool = False) -> dict[str, Any]:
        where, values = self._where(start, end, endpoint, version, origin_only=origin_only, filters=filters)
        if cursor is not None:
            where += " AND id<?"
            values.append(int(cursor))
        self._deadline()
        limit = max(1, min(int(limit), 1000))
        rows = []
        for record in self.db.execute("SELECT * FROM requests WHERE " + where + " ORDER BY id DESC LIMIT ?", [*values, limit]):
            item = dict(record)
            item["edge"] = json.loads(item.pop("edge_json") or "null")
            item["runtime"] = json.loads(item.pop("runtime_json") or "null")
            item["book_names"] = json.loads(item["book_names"])
            rows.append(item)
        return {"items": rows, "next_cursor": rows[-1]["id"] if len(rows) == limit else None}

    def events(self, start: float, end: float, *, endpoint: str | None = None,
               limit: int = 100, cursor: int | None = None) -> dict[str, Any]:
        where, values = ["stamp>=?", "stamp<?"], [start, end]
        if endpoint is not None:
            where.append("endpoint=?")
            values.append(endpoint)
        if cursor is not None:
            where.append("id<?")
            values.append(int(cursor))
        limit = max(1, min(int(limit), 1000))
        self._deadline()
        rows = [dict(row) for row in self.db.execute("SELECT * FROM events WHERE " + " AND ".join(where)
                + " ORDER BY id DESC LIMIT ?", [*values, limit])]
        for row in rows:
            row["payload"] = json.loads(row["payload"])
        return {"items": rows, "next_cursor": rows[-1]["id"] if len(rows) == limit else None}

    def metrics(self, start: float, end: float, bucket_seconds: int = 5) -> list[dict[str, Any]]:
        # One latest sample per bucket bounds response size for six-month views.
        bucket_seconds = max(1, int(bucket_seconds), math.ceil((end - start) / 2000))
        self._deadline()
        rows = self.db.execute("SELECT stamp,payload FROM metrics WHERE id IN (SELECT max(id) FROM metrics "
                               "WHERE stamp>=? AND stamp<? GROUP BY CAST(stamp / ? AS INTEGER)) ORDER BY stamp",
                               (start, end, bucket_seconds))
        return [{"stamp": row["stamp"], **json.loads(row["payload"])} for row in rows]

    def export(self, start: float, end: float, *, endpoint: str | None = None,
               version: str | None = None) -> Iterable[dict[str, Any]]:
        """Stream canonical records; callers must enforce authenticated access."""
        where, values = self._where(start, end, endpoint, version, origin_only=False)
        self._deadline()
        for row in self.db.execute("SELECT endpoint,request_id,stamp,edge_json,runtime_json FROM requests WHERE "
                                   + where + " ORDER BY stamp,id", values):
            yield {"endpoint": row["endpoint"], "request_id": row["request_id"], "stamp": row["stamp"],
                   "edge": json.loads(row["edge_json"] or "null"), "runtime": json.loads(row["runtime_json"] or "null")}

    def storage(self) -> dict[str, Any]:
        self._deadline()
        sizes = {suffix or "database": self._size(str(self.path) + suffix) for suffix in ("", "-wal", "-shm")}
        page_size = self.db.execute("PRAGMA page_size").fetchone()[0]
        pages = self.db.execute("PRAGMA page_count").fetchone()[0]
        free = self.db.execute("PRAGMA freelist_count").fetchone()[0]
        # Separate extrema let SQLite seek into requests_time for each bound.
        # Combining MIN and MAX in one aggregate scans the entire traffic index.
        bounds = self.db.execute("SELECT (SELECT min(stamp) FROM requests), "
                                 "(SELECT max(stamp) FROM requests)").fetchone()
        gaps = [dict(row) for row in self.db.execute("SELECT * FROM retention ORDER BY id DESC LIMIT 100")]
        return {"bytes": sum(sizes.values()), "files": sizes, "active_bytes": (pages-free)*page_size,
                "reusable_bytes": free*page_size, "first_request": bounds[0], "last_request": bounds[1],
                "retention_events": gaps,
                "metadata": {row[0]: json.loads(row[1]) for row in self.db.execute("SELECT key,value FROM metadata")}}

    @staticmethod
    def _size(path: str) -> int:
        try:
            return os.stat(path).st_size
        except OSError:
            return 0

    def set_metadata(self, key: str, value: Any) -> None:
        self.db.execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (key, json.dumps(value, ensure_ascii=False, separators=(",", ":"))))

    def prune(self, *, max_bytes: int, retention_days: float, now: float | None = None) -> dict[str, Any]:
        """Delete oldest history only; cap is a soft application storage budget.

        Active readers can pin WAL pages. A filesystem quota is required for a
        hard physical byte ceiling. Never block ingestion waiting for readers
        to release snapshots, and report physical over-budget state instead.
        """
        if max_bytes < 1024 * 1024 or not math.isfinite(retention_days) or retention_days < 0:
            raise ValueError("max_bytes must be >=1 MiB and retention_days must be finite and nonnegative")
        now = time.time() if now is None else now
        self.db.set_progress_handler(None, 0)
        self.db.commit()
        deleted = {"requests": 0, "events": 0, "metrics": 0}
        cutoff = now - retention_days * 86400
        first: float | None = None
        last: float | None = None

        def remove(before: float, reason: str) -> int:
            nonlocal first, last
            count = 0
            with self.db:
                for table in deleted:
                    bounds = self.db.execute(f"SELECT min(stamp),max(stamp),count(*) FROM {table} WHERE stamp<?", (before,)).fetchone()
                    if bounds[2]:
                        first = bounds[0] if first is None else min(first, bounds[0])
                        last = bounds[1] if last is None else max(last, bounds[1])
                    n = self.db.execute(f"DELETE FROM {table} WHERE stamp<?", (before,)).rowcount
                    deleted[table] += n
                    count += n
            return count

        if retention_days:
            remove(cutoff, "age")
        reason = "age" if sum(deleted.values()) else "size"
        # Work in bounded batches and free pages incrementally; a large request
        # cannot force deletion of newer data before older records of any kind.
        for _ in range(64):
            self.db.execute("PRAGMA wal_checkpoint(PASSIVE)")
            active = (self.db.execute("PRAGMA page_count").fetchone()[0]
                      - self.db.execute("PRAGMA freelist_count").fetchone()[0]) * self.db.execute("PRAGMA page_size").fetchone()[0]
            if active <= max_bytes * 0.90:
                break
            total_rows = sum(self.db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] for table in deleted)
            average = max(1, active / max(1, total_rows))
            needed = max(1, min(10000, math.ceil((active - max_bytes * .90) / average * .75)))
            candidates = self.db.execute(
                "SELECT source,id,stamp FROM (SELECT 'requests' AS source,id,stamp FROM requests "
                "UNION ALL SELECT 'events',id,stamp FROM events UNION ALL SELECT 'metrics',id,stamp FROM metrics) "
                "ORDER BY stamp,source,id LIMIT ?", (needed,)).fetchall()
            if not candidates:
                break
            if reason == "age":
                reason = "age_or_size"
            with self.db:
                for table in deleted:
                    ids = [row["id"] for row in candidates if row["source"] == table]
                    if ids:
                        self.db.executemany(f"DELETE FROM {table} WHERE id=?", [(value,) for value in ids])
                        deleted[table] += len(ids)
                first = candidates[0]["stamp"] if first is None else min(first, candidates[0]["stamp"])
                last = candidates[-1]["stamp"] if last is None else max(last, candidates[-1]["stamp"])
        with self.db:
            if sum(deleted.values()):
                self.db.execute("INSERT INTO retention(stamp,reason,first_stamp,last_stamp,request_rows,event_rows,metric_rows,detail) "
                                "VALUES(?,?,?,?,?,?,?,?)", (now, reason, first, last, deleted["requests"],
                                deleted["events"], deleted["metrics"], "Oldest records removed by configured history policy."))
            self.set_metadata("retention_policy", {"max_bytes": max_bytes, "days": retention_days})
            # Compact old retention reports, preserving totals and oldest gaps.
            old = self.db.execute("SELECT count(*),COALESCE(sum(request_rows),0),COALESCE(sum(event_rows),0),"
                                  "COALESCE(sum(metric_rows),0),min(first_stamp),max(last_stamp) FROM retention "
                                  "WHERE id NOT IN (SELECT id FROM retention ORDER BY id DESC LIMIT 1000)").fetchone()
            if old[0]:
                existing = self.db.execute("SELECT value FROM metadata WHERE key='retention_archive'").fetchone()
                archive = json.loads(existing[0]) if existing else {"events": 0, "requests": 0, "diagnostics": 0, "metrics": 0}
                for key, value in zip(("events", "requests", "diagnostics", "metrics"), old[:4]):
                    archive[key] = archive.get(key, 0) + value
                archive["first_stamp"] = min(x for x in (archive.get("first_stamp"), old[4]) if x is not None) if old[4] is not None else archive.get("first_stamp")
                archive["last_stamp"] = max(x for x in (archive.get("last_stamp"), old[5]) if x is not None) if old[5] is not None else archive.get("last_stamp")
                self.set_metadata("retention_archive", archive)
                self.db.execute("DELETE FROM retention WHERE id NOT IN (SELECT id FROM retention ORDER BY id DESC LIMIT 1000)")
        # incremental_vacuum yields a row per released page. Consume its
        # cursor; merely calling execute would reclaim only the first page.
        reclaim_deadline = time.monotonic() + 2
        cursor = self.db.execute("PRAGMA incremental_vacuum")
        try:
            for _ in cursor:
                if time.monotonic() >= reclaim_deadline:
                    break
        finally:
            cursor.close()
        # Shrink the WAL only when it is immediately safe. A dashboard reader
        # can defer this attempt, but cannot stall collection for a busy wait.
        self.db.execute("PRAGMA busy_timeout=0")
        try:
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        finally:
            self.db.execute("PRAGMA busy_timeout=2000")
        physical = sum(self._size(str(self.path) + suffix) for suffix in ("", "-wal", "-shm"))
        return {"deleted": deleted, "bytes": physical, "over_budget": physical > max_bytes,
                "first_removed": first, "last_removed": last}
