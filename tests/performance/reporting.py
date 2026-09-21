#!/usr/bin/env python3
"""Disposable reporting benchmark; deliberately excluded from normal CI.

    python3 tests/performance/reporting.py
    python3 tests/performance/reporting.py --rows-per-day 1000 --days 30

Defaults model 300,000 origin requests/day over 30 days. Fixture creation copies
canonical rows produced by TelemetryStore.append, updating their identities and
JSON timestamps in SQL. Timed concurrent ingestion and late joins use append
itself. Every run creates and removes its own temporary database; this program
never opens an operator-supplied database. Progress goes to stderr and the final
machine-readable measurements go to stdout. A correctness failure, reader
timeout, stalled backfill, or ingestion failure produces a nonzero exit status.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import resource
import statistics
import sys
import tempfile
import threading
import time
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_telemetry import TelemetryStore

DAY = 86400


def progress(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rows-per-day", type=positive, default=300000)
    parser.add_argument("--days", type=positive, default=30)
    parser.add_argument("--dimensions", type=positive, default=64,
                        help="distinct request profiles, cycling across four service kinds")
    parser.add_argument("--batch-size", type=positive, default=10000)
    parser.add_argument("--query-timeout", type=positive, default=10,
                        help="seconds available to each report, matching the dashboard default")
    parser.add_argument("--rollup-timeout", type=positive, default=1800,
                        help="maximum total seconds to finish fixture backfill")
    parser.add_argument("--ingest-rate", type=positive, default=100,
                        help="target origin requests/second while reports run")
    parser.add_argument("--late-joins", type=positive, default=32)
    parser.add_argument("--repeat", type=positive, default=1)
    parser.add_argument("--work-dir", type=Path,
                        help="parent directory for the disposable database (default: system temp)")
    return parser.parse_args()


def fixture(index: int, stamp: float, request_id: str) -> tuple[str, dict[str, Any], dict[str, Any]]:
    kind = ("query", "search", "static", "mcp")[index % 4]
    version = "v2" if (index // 4) % 2 == 0 else "v3"
    translation = ("kjv", "asv", "web", "bbe")[(index // 8) % 4]
    book = str(index % 66 + 1)
    reference = f"Book {book}:1"
    operation = {"query": "scripture", "search": "search", "static": "static", "mcp": "tools/call"}[kind]
    path = "/" if kind == "mcp" else f"/{version}/{translation}/{index % 97 + 1}"
    status = 503 if index % 29 == 0 else 429 if index % 17 == 0 else 200
    edge = {
        "time": stamp, "request_id": request_id, "method": "GET", "uri": path,
        "status": status, "request_time": (index % 100 + 1) / 1000,
        "bytes": 256 + index % 4096, "remote_addr": f"2001:db8::{index + 1:x}",
        "token_id": f"fixture-{index}" if index % 5 == 0 else "",
        "cache": "HIT" if index % 3 else "MISS", "endpoint_kind": kind,
        "user_agent": f"FixtureReader/{index}", "referrer": f"https://reader.example/{index}",
    }
    runtime = {
        "time": stamp, "request_id": request_id, "event": "request", "method": "GET",
        "path": path, "status": status, "version": "" if kind == "mcp" else version,
        "endpoint_kind": kind, "operation": operation,
        "translation": "" if kind == "mcp" else translation,
        "books": [] if kind == "mcp" else [book],
        "reference": reference if kind == "query" else "",
        "search": f"word {index}" if kind == "search" else "",
    }
    if kind == "mcp":
        runtime.update(mcp_method="tools/call", mcp_tool="scripture",
                       mcp_client_name=f"fixture-client-{index}", mcp_client_version="1.0",
                       mcp_outcome="tool_error" if index % 11 == 0 else "success",
                       upstream_service="query", upstream_api_version=version,
                       upstream_operation="reference")
    return f"{kind}.example.test", edge, runtime


def seed(store: TelemetryStore, args: argparse.Namespace, start: float) -> tuple[list[dict[str, Any]], float]:
    """Populate real canonical request rows without timing Python fixture generation."""
    began = time.perf_counter()
    for index in range(args.dimensions):
        endpoint, edge, runtime = fixture(index, start, f"template-{index}")
        store.append(edge, endpoint=endpoint, source="edge", record_key=f"template-edge-{index}")
        store.append(runtime, endpoint=endpoint, source="runtime", record_key=f"template-runtime-{index}")
    profiles = [dict(row) for row in store.db.execute("SELECT * FROM requests ORDER BY id")]
    columns = [name for name in profiles[0] if name != "id"]
    # Templates remain temporary and never contribute to report totals.
    store.db.execute("CREATE TEMP TABLE reporting_templates AS SELECT * FROM requests")
    store.db.execute("DELETE FROM requests")
    store.db.execute("CREATE TEMP TABLE reporting_sequence(n INTEGER PRIMARY KEY)")
    store.db.executemany("INSERT INTO reporting_sequence VALUES(?)", ((i,) for i in range(args.batch_size)))
    store.db.commit()
    identifier = "'seed-' || (?1 + sequence.n)"
    stamp = "?2 + (?1 + sequence.n + 0.5) * 86400.0 / ?3"
    expressions = []
    for column in columns:
        if column == "request_id":
            expressions.append(identifier)
        elif column == "stamp":
            expressions.append(stamp)
        elif column in {"edge_json", "runtime_json"}:
            expressions.append(f"json_set(profile.{column}, '$.request_id', {identifier}, '$.time', {stamp})")
        else:
            expressions.append(f'profile."{column}"')
    sql = ("INSERT INTO requests(" + ",".join(f'"{column}"' for column in columns) + ") SELECT "
           + ",".join(expressions) + " FROM reporting_sequence AS sequence JOIN reporting_templates AS profile "
           "ON profile.id = ((?1 + sequence.n) % ?4) + 1 WHERE sequence.n < ?5")
    total = args.rows_per_day * args.days
    next_progress = 0.0
    for first in range(0, total, args.batch_size):
        size = min(args.batch_size, total - first)
        store.db.execute(sql, (first, start, args.rows_per_day, args.dimensions, size))
        store.db.commit()
        now = time.perf_counter()
        if now >= next_progress or first + size == total:
            progress(f"Seeded {first + size:,}/{total:,} canonical requests ({now - began:.1f}s)")
            next_progress = now + 10
    store.db.execute("DROP TABLE reporting_templates")
    store.db.execute("DROP TABLE reporting_sequence")
    store.db.commit()
    return profiles, time.perf_counter() - began


def refresh(store: TelemetryStore, timeout: float) -> dict[str, Any]:
    began = time.perf_counter()
    iterations = 0
    batches: list[float] = []
    while True:
        tick = time.perf_counter()
        state = store.refresh_rollups(max_buckets=4, time_budget=0.25)
        store.db.commit()
        batches.append(time.perf_counter() - tick)
        iterations += 1
        if state.get("ready"):
            ordered = sorted(batches)
            return {"seconds": time.perf_counter() - began, "iterations": iterations, "state": state,
                    "max_refresh_seconds": max(ordered),
                    "p95_refresh_seconds": ordered[math.ceil(len(ordered) * 0.95) - 1]}
        if time.perf_counter() - began >= timeout:
            raise RuntimeError(f"Rollup backfill did not finish within {timeout}s: {state}")
        if iterations % 40 == 0:
            progress(f"Rollup backfill: {time.perf_counter() - began:.1f}s; {state}")


def expected(profiles: list[dict[str, Any]], args: argparse.Namespace, seed_start: float,
             start: float, end: float, filters: dict[str, Any]) -> dict[str, Any]:
    first = max(0, math.ceil((start - seed_start) * args.rows_per_day / DAY - 0.5))
    last = min(args.rows_per_day * args.days, math.ceil((end - seed_start) * args.rows_per_day / DAY - 0.5))
    result: Counter[str] = Counter()
    ips, tokens = set(), set()
    duration = 0.0
    for index, row in enumerate(profiles):
        count = max(0, (last - 1 - index) // args.dimensions - (first - 1 - index) // args.dimensions)
        if not count or any(row[key] != value for key, value in filters.items()):
            continue
        payload = json.loads(row["runtime_json"])
        mcp = row["endpoint_kind"] == "mcp"
        protocol_error = mcp and payload.get("mcp_outcome") in {"tool_error", "protocol_error", "transport_error"}
        result.update({"calls": count, "bytes": row["bytes"] * count,
                       "http_errors": count * (row["status"] >= 400),
                       "server_errors": count * (row["status"] >= 500),
                       "errors": count * (row["status"] >= 400 or protocol_error),
                       "rate_limited": count * (row["status"] == 429),
                       "cache_hits": count * (row["cache"] == "HIT"),
                       "cache_requests": count, "mcp_requests": count * mcp,
                       "mcp_errors": count * (mcp and (row["status"] >= 400 or protocol_error)),
                       "mcp_tool_calls": count * mcp})
        duration += count * row["duration_ms"]
        ips.add(row["remote_addr"])
        if row["token_id"]:
            tokens.add(row["token_id"])
    return {**result, "unique_ips": len(ips), "unique_tokens": len(tokens),
            "duration_ms": duration / result["calls"] if result["calls"] else 0,
            "calls": result["calls"], "runtime_without_edge": 0}


def assert_totals(actual: dict[str, Any], totals: dict[str, Any]) -> None:
    for field, value in totals.items():
        observed = actual[field]
        if field == "duration_ms":
            equal = math.isclose(observed, value, rel_tol=1e-8, abs_tol=1e-8)
        else:
            equal = observed == value
        if not equal:
            raise AssertionError(f"{field}: expected {value}, received {observed}")


class Ingestor(threading.Thread):
    def __init__(self, path: Path, stamp: float, rate: int) -> None:
        super().__init__(name="reporting-benchmark-ingestor", daemon=True)
        self.path, self.stamp, self.rate = path, stamp, rate
        self.stop_event, self.started_event = threading.Event(), threading.Event()
        self.calls = 0
        self.commits: list[float] = []
        self.error = ""
        self.elapsed = 0.0

    def run(self) -> None:
        began = time.perf_counter()
        try:
            with TelemetryStore(self.path) as store:
                batch = max(1, min(100, self.rate // 10))
                while not self.stop_event.is_set():
                    tick = time.perf_counter()
                    for _ in range(batch):
                        _, edge, _ = fixture(self.calls % 16, self.stamp + self.calls / self.rate,
                                             f"concurrent-{self.calls}")
                        store.append(edge, endpoint="ingest.example.test", source="edge",
                                     record_key=f"concurrent-{self.calls}")
                        self.calls += 1
                    store.db.commit()
                    self.commits.append(time.perf_counter() - tick)
                    self.started_event.set()
                    store.refresh_rollups(max_buckets=1, time_budget=0.05)
                    store.db.commit()
                    self.stop_event.wait(max(0, batch / self.rate - (time.perf_counter() - tick)))
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
            self.started_event.set()
        finally:
            self.elapsed = time.perf_counter() - began

    def result(self) -> dict[str, Any]:
        ordered = sorted(self.commits)
        return {"calls": self.calls, "seconds": self.elapsed,
                "requests_per_second": self.calls / self.elapsed if self.elapsed else 0,
                "commit_median_seconds": statistics.median(ordered) if ordered else None,
                "commit_p95_seconds": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)] if ordered else None,
                "commit_max_seconds": max(ordered) if ordered else None, "error": self.error or None}


def late_joins(path: Path, args: argparse.Namespace, start: float, end: float) -> dict[str, Any]:
    began = time.perf_counter()
    endpoint = "late-joins.example.test"
    with TelemetryStore(path) as store:
        for index in range(args.late_joins):
            # Half arrive nginx-first; the remainder start as runtime-only rows.
            edge = {"time": end - 1800, "request_id": f"late-{index}", "method": "POST",
                    "uri": "/v2/", "status": 200, "bytes": 128, "request_time": 0.01,
                    "remote_addr": "192.0.2.1", "endpoint_kind": "search"}
            # Runtime-first records also exercise an edge correction into a
            # different hour: both old and new aggregates must be invalidated.
            runtime = {"time": end - (7201 if index % 2 else 1800),
                       "request_id": f"late-{index}", "event": "request",
                       "version": "v3", "endpoint_kind": "search", "operation": "reference",
                       "translation": "late_fixture", "reference": "John 3:16", "books": [43]}
            source = "edge" if index % 2 == 0 else "runtime"
            store.append(edge if source == "edge" else runtime, endpoint=endpoint,
                         source=source, record_key=f"late-initial-{index}")
        store.db.commit()
        refresh(store, args.rollup_timeout)
        with TelemetryStore(path, readonly=True, query_timeout=args.query_timeout) as reader:
            reader.db.execute("BEGIN")
            before = reader.summary(start, end, endpoint=endpoint)
        assert_totals(before, {"calls": (args.late_joins + 1) // 2,
                               "runtime_without_edge": args.late_joins // 2})
        for index in range(args.late_joins):
            if index % 2 == 0:
                entry = {"time": end - 1800, "request_id": f"late-{index}", "event": "request",
                         "version": "v3", "endpoint_kind": "search", "operation": "reference",
                         "translation": "late_fixture", "reference": "John 3:16", "books": [43]}
                source = "runtime"
            else:
                entry = {"time": end - 1800, "request_id": f"late-{index}", "method": "POST",
                         "uri": "/v2/", "status": 200, "bytes": 128, "request_time": 0.01,
                         "remote_addr": "192.0.2.1", "endpoint_kind": "search"}
                source = "edge"
            store.append(entry, endpoint=endpoint, source=source, record_key=f"late-completion-{index}")
        store.db.commit()
        # A dirty-hour report must be correct even before refresh catches up.
        with TelemetryStore(path, readonly=True, query_timeout=args.query_timeout) as reader:
            reader.db.execute("BEGIN")
            dirty = reader.summary(start, end, endpoint=endpoint)
        assert_totals(dirty, {"calls": args.late_joins, "bytes": args.late_joins * 128,
                              "runtime_without_edge": 0})
        refresh(store, args.rollup_timeout)
        with TelemetryStore(path, readonly=True, query_timeout=args.query_timeout) as reader:
            reader.db.execute("BEGIN")
            after = reader.summary(start, end, endpoint=endpoint, version="v3")
        assert_totals(after, {"calls": args.late_joins, "bytes": args.late_joins * 128,
                              "runtime_without_edge": 0})
    return {"seconds": time.perf_counter() - began, "joined_requests": args.late_joins,
            "dirty_totals_verified": True, "refreshed_totals_verified": True}


def run(args: argparse.Namespace, path: Path) -> dict[str, Any]:
    end = int(time.time() // 3600) * 3600
    seed_start = end - args.days * DAY
    result: dict[str, Any] = {"rows_per_day": args.rows_per_day, "days": args.days,
                              "rows": args.rows_per_day * args.days, "dimensions": args.dimensions,
                              "query_timeout_seconds": args.query_timeout, "reports": [], "failures": []}
    with TelemetryStore(path) as store:
        if not callable(getattr(store, "refresh_rollups", None)):
            raise RuntimeError("This checkout does not expose TelemetryStore.refresh_rollups")
        profiles, result["seed_seconds"] = seed(store, args, seed_start)
        progress("Refreshing derived hourly reporting data")
        result["backfill"] = refresh(store, args.rollup_timeout)
        result["database_bytes"] = store.storage()["bytes"]
    ingestor = Ingestor(path, end + 1, args.ingest_rate)
    ingestor.start()
    try:
        if not ingestor.started_event.wait(10) or ingestor.error:
            raise RuntimeError("Concurrent ingestion could not start: " + ingestor.error)
        windows = sorted({min(args.days, days) for days in (1, 7, 30)})
        scopes = (("all", {}), ("endpoint", {"endpoint": profiles[0]["endpoint"]}),
                  ("service", {"endpoint_kind": "mcp"}),
                  ("translation", {"translation": profiles[0]["translation"]}),
                  ("partial-hour", {}))
        for repeat in range(args.repeat):
            for days in windows:
                for name, filters in scopes:
                    start, until = end - days * DAY, end
                    if name == "partial-hour":
                        start, until = start + 137, until - 211
                    totals = expected(profiles, args, seed_start, start, until, filters)
                    began = time.perf_counter()
                    report: dict[str, Any] = {"days": days, "scope": name, "repeat": repeat + 1}
                    try:
                        with TelemetryStore(path, readonly=True, query_timeout=args.query_timeout) as reader:
                            reader.db.execute("BEGIN")
                            summary = reader.summary(start, until, filters=filters)
                        assert_totals(summary, totals)
                        report.update(seconds=time.perf_counter() - began, calls=summary["calls"], correct=True)
                    except Exception as error:
                        report.update(seconds=time.perf_counter() - began, correct=False,
                                      error=f"{type(error).__name__}: {error}")
                        result["failures"].append(report)
                    result["reports"].append(report)
                    progress(f"{days}d {name}: {report['seconds']:.3f}s; correct={report['correct']}")
                began = time.perf_counter()
                report = {"days": days, "scope": "partial-hour-series", "repeat": repeat + 1}
                try:
                    start, until = end - days * DAY + 137, end - 211
                    with TelemetryStore(path, readonly=True, query_timeout=args.query_timeout) as reader:
                        reader.db.execute("BEGIN")
                        series = reader.series(start, until, bucket_seconds=60)
                    calls = sum(row["calls"] for row in series)
                    assert_totals({"calls": calls}, {"calls": expected(profiles, args, seed_start, start, until, {})["calls"]})
                    report.update(seconds=time.perf_counter() - began, calls=calls, buckets=len(series), correct=True)
                except Exception as error:
                    report.update(seconds=time.perf_counter() - began, correct=False,
                                  error=f"{type(error).__name__}: {error}")
                    result["failures"].append(report)
                result["reports"].append(report)
                progress(f"{days}d series: {report['seconds']:.3f}s; correct={report['correct']}")
    finally:
        ingestor.stop_event.set()
        ingestor.join(timeout=30)
        if ingestor.is_alive():
            raise RuntimeError("Concurrent ingestion did not stop within 30 seconds")
        result["concurrent_ingestion"] = ingestor.result()
    if ingestor.error:
        result["failures"].append({"scope": "ingestion", "error": ingestor.error})
    try:
        result["late_joins"] = late_joins(path, args, seed_start, end)
    except Exception as error:
        result["failures"].append({"scope": "late-joins", "error": f"{type(error).__name__}: {error}"})
    result["ok"] = not result["failures"]
    return result


def main() -> int:
    args = arguments()
    began = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="getbible-reporting-benchmark-", dir=args.work_dir) as directory:
        progress(f"Disposable benchmark: {args.rows_per_day * args.days:,} rows; {args.dimensions} profiles")
        result = run(args, Path(directory) / "traffic.sqlite3")
    result["total_seconds"] = time.perf_counter() - began
    result["process_peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
