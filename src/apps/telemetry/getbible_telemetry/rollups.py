"""Exact hourly reporting projections of the canonical request history.

Only observed combinations of the low-cardinality request fields are stored.
Other dimensions have independent marginals, never a cross-product cube.
Canonical requests remain authoritative: triggers invalidate affected hours and
the collector rebuilds one bounded hour in the same transaction as its marker.
"""

from __future__ import annotations

from collections import Counter
import json
import math
import time


HOUR = 3600
RAW_LIMIT = 50_000
BOUNDS = (1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000)
SCOPE = ("endpoint", "version", "endpoint_kind", "status", "auth", "cache", "method",
         "operation", "translation", "mcp_outcome")
COUNTS = ("calls", "bytes", "server_errors", "errors", "http_errors", "mcp_requests",
          "mcp_errors", "mcp_tool_calls", "rate_limited", "preflights", "cache_hits",
          "cache_requests", "duration_total", "runtime_without_edge")
HISTOGRAM = tuple("h" + str(index) for index in range(len(BOUNDS) + 1))
SUMS = COUNTS + HISTOGRAM
TOTALS = SUMS + ("max_duration_ms", "first_seen", "last_seen")
FAILURES = frozenset({"tool_error", "protocol_error", "transport_error"})


class ReportingPreparing(RuntimeError):
    """The collector is preparing exact projections of existing history."""

    def __init__(self, progress):
        self.progress = progress
        super().__init__("Preparing historical reports; traffic collection continues")


def effective_bucket_seconds(start, end, requested):
    bucket = max(1, int(requested), math.ceil((end - start) / 2000))
    if end - start >= 86400:
        bucket = math.ceil(bucket / HOUR) * HOUR
    return bucket


def _empty_totals():
    return {**dict.fromkeys(SUMS, 0), "max_duration_ms": None, "first_seen": None, "last_seen": None}


def _merge_totals(target, other):
    for key in SUMS:
        target[key] += other[key] or 0
    for key, operator in (("max_duration_ms", max), ("first_seen", min), ("last_seen", max)):
        value = other[key]
        if value is not None:
            target[key] = value if target[key] is None else operator(target[key], value)


def _latency(totals):
    counts = [totals[key] for key in HISTOGRAM]
    total = sum(counts)
    result = {"approximate": True, "histogram": [
        {"upper_ms": bound, "count": count} for bound, count in zip((*BOUNDS, None), counts)]}
    for name, fraction in (("p50", .5), ("p95", .95), ("p99", .99)):
        cumulative, value = 0, None
        for bound, count in zip(BOUNDS, counts):
            cumulative += count
            if total and cumulative >= math.ceil(total * fraction):
                value = bound
                break
        result[name] = value
    return result


def _scalar(value):
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if value is True:
        return "1"
    if value is False:
        return "0"
    return "" if value is None else str(value)


class Rollups:
    def __init__(self, store):
        self.store = store
        self.db = store.db

    def progress(self):
        state = dict(self.db.execute("SELECT * FROM reporting_state WHERE id=1").fetchone())
        current = math.floor(time.time() / HOUR) * HOUR
        pending = self.db.execute("SELECT count(*) FROM reporting_dirty WHERE hour<?", (current,)).fetchone()[0]
        caught_up = state["complete"] or state["next_hour"] >= min(current, state["through_hour"])
        return {"ready": bool(caught_up and not pending),
                "backfill_complete": bool(state["complete"]), "next_hour": state["next_hour"],
                "through_hour": state["through_hour"], "pending_hours": pending}

    def refresh(self, max_buckets=4, time_budget=.25):
        if self.store.readonly:
            raise ValueError("Reporting projections require the collector's writable connection")
        if not isinstance(max_buckets, int) or not 1 <= max_buckets <= 10000:
            raise ValueError("max_buckets must be between 1 and 10000")
        if not math.isfinite(time_budget) or time_budget <= 0:
            raise ValueError("time_budget must be positive and finite")
        if self.db.in_transaction:
            raise RuntimeError("Commit ingestion before refreshing reporting projections")
        self.db.set_progress_handler(None, 0)
        deadline = time.monotonic() + time_budget
        processed = 0
        for _ in range(max_buckets):
            if processed and time.monotonic() >= deadline:
                break
            current = math.floor(time.time() / HOUR) * HOUR
            with self.db:
                # Reserve the sole writer before reading facts or invalidations.
                self.db.execute("BEGIN IMMEDIATE")
                state = self.db.execute("SELECT * FROM reporting_state WHERE id=1").fetchone()
                dirty = self.db.execute("SELECT hour FROM reporting_dirty WHERE hour<? ORDER BY hour LIMIT 1", (current,)).fetchone()
                hour = dirty[0] if dirty else None
                backfill = False
                if hour is None and not state["complete"]:
                    record = self.db.execute("SELECT stamp FROM requests WHERE stamp>=? AND stamp<? "
                                             "ORDER BY stamp LIMIT 1", (state["next_hour"], min(current, state["through_hour"]))).fetchone()
                    if record:
                        hour = math.floor(record[0] / HOUR) * HOUR
                        backfill = True
                    else:
                        # Keep the cursor for the current/future hours that
                        # predate migration. Producer clock skew may leave more
                        # than one such hour, and none had invalidation triggers.
                        next_hour = min(current, state["through_hour"])
                        self.db.execute("UPDATE reporting_state SET next_hour=?,complete=(?>=through_hour) WHERE id=1",
                                        (next_hour, next_hour))
                if hour is None:
                    break
                self._rebuild(hour)
                if backfill:
                    self.db.execute("UPDATE reporting_state SET next_hour=?,complete=(?>=through_hour) WHERE id=1", (hour + HOUR, hour + HOUR))
                processed += 1
        return {**self.progress(), "processed": processed}

    def _rebuild(self, hour):
        from .store import _DIMENSIONS, _MCP_DIMENSIONS, _USAGE
        totals, members = {}, {}
        columns = ("endpoint", "version", "endpoint_kind", "status", "auth", "cache", "method",
                   "operation", "translation", "duration_ms", "bytes", "stamp", "remote_addr", "path",
                   "book", "book_names", "search", "reference", "token_id", "user_agent", "referrer", "runtime_json")
        sql = "SELECT " + ",".join(columns) + ",edge_json IS NOT NULL AS origin FROM requests WHERE stamp>=? AND stamp<?"
        for row in self.db.execute(sql, (hour, hour + HOUR)):
            item = dict(row)
            protocol = json.loads(item["runtime_json"] or "null") or {} if item["endpoint_kind"] == "mcp" else {}
            item["mcp_outcome"] = _scalar(protocol.get("mcp_outcome", ""))
            scope = tuple(item[key] for key in SCOPE)
            total = totals.get(scope)
            if total is None:
                total = totals[scope] = _empty_totals()
            if not item["origin"]:
                total["runtime_without_edge"] += 1
                continue
            failure = item["status"] >= 400 or (item["endpoint_kind"] == "mcp" and item["mcp_outcome"] in FAILURES)
            good = (200 <= item["status"] <= 299 or item["status"] == 304) and not (item["endpoint_kind"] == "mcp" and item["mcp_outcome"] in FAILURES)
            facts = {"calls": 1, "bytes": item["bytes"], "server_errors": item["status"] >= 500,
                     "errors": failure, "http_errors": item["status"] >= 400,
                     "mcp_requests": item["endpoint_kind"] == "mcp",
                     "mcp_errors": item["endpoint_kind"] == "mcp" and failure,
                     "mcp_tool_calls": item["endpoint_kind"] == "mcp" and protocol.get("mcp_method") == "tools/call",
                     "rate_limited": item["status"] == 429, "preflights": item["method"] == "OPTIONS",
                     "cache_hits": item["cache"] == "HIT", "cache_requests": item["cache"] not in ("", "-"),
                     "duration_total": item["duration_ms"]}
            for key, value in facts.items():
                total[key] += value
            slot = next((i for i, bound in enumerate(BOUNDS) if item["duration_ms"] <= bound), len(BOUNDS))
            total[HISTOGRAM[slot]] += 1
            for key, value, operator in (("max_duration_ms", item["duration_ms"], max), ("first_seen", item["stamp"], min), ("last_seen", item["stamp"], max)):
                total[key] = value if total[key] is None else operator(total[key], value)
            for dimension, column in _DIMENSIONS.items():
                if dimension in SCOPE:
                    continue
                if dimension in _USAGE:
                    if not good or item["method"] not in ("GET", "HEAD", "POST"):
                        continue
                    if dimension == "search" and not (item["endpoint_kind"] == "search" and item["operation"] in ("search", "reference")):
                        continue
                    if dimension == "reference" and not (item["endpoint_kind"] == "query" and item["operation"] == "scripture"):
                        continue
                    if dimension == "book" and item["operation"] not in ("static", "scripture", "search", "reference"):
                        continue
                value = protocol.get(dimension, "") if dimension in _MCP_DIMENSIONS else item[column]
                if dimension in _MCP_DIMENSIONS and item["endpoint_kind"] != "mcp":
                    continue
                if dimension in _USAGE | _MCP_DIMENSIONS | {"referrer", "user_agent"} and value in ("", "-", "[]", None):
                    continue
                names = {}
                if dimension == "book":
                    try:
                        values = json.loads(value) if value.startswith("[") else [value]
                    except (ValueError, TypeError):
                        values = [value]
                    names = json.loads(item["book_names"] or "{}")
                    occurrences = Counter(_scalar(value) for value in values).items()
                else:
                    occurrences = ((_scalar(value), 1),)
                for value, multiplicity in occurrences:
                    key = (scope, dimension, value)
                    member = members.get(key)
                    if member is None:
                        member = members[key] = [0, 0, 0., 0, 0, None]
                    member[0] += 1
                    member[1] += item["bytes"] * multiplicity
                    member[2] += item["duration_ms"] * multiplicity
                    member[3] += int(failure) * multiplicity
                    member[4] += multiplicity
                    label = names.get(value)
                    if label is not None:
                        member[5] = label if member[5] is None else min(member[5], label)
        self.db.execute("DELETE FROM reporting_totals WHERE hour=?", (hour,))
        self.db.execute("DELETE FROM reporting_values WHERE hour=?", (hour,))
        ids = {}
        fields = ",".join(SCOPE)
        placeholders = ",".join("?" for _ in SCOPE)
        for scope, total in totals.items():
            self.db.execute(f"INSERT OR IGNORE INTO reporting_scopes({fields}) VALUES({placeholders})", scope)
            scope_id = self.db.execute("SELECT id FROM reporting_scopes WHERE " + " AND ".join(key + "=?" for key in SCOPE), scope).fetchone()[0]
            ids[scope] = scope_id
            self.db.execute("INSERT INTO reporting_totals(hour,scope_id," + ",".join(TOTALS) + ") VALUES(" + ",".join("?" for _ in range(len(TOTALS) + 2)) + ")", (hour, scope_id, *(total[key] for key in TOTALS)))
        self.db.executemany("INSERT INTO reporting_values(hour,scope_id,dimension,value,calls,bytes,duration_total,errors,samples,label) VALUES(?,?,?,?,?,?,?,?,?,?)",
                            ((hour, ids[scope], dimension, value, *member) for (scope, dimension, value), member in members.items()))
        self.db.execute("INSERT INTO reporting_hours(hour) VALUES(?) ON CONFLICT DO NOTHING", (hour,))
        self.db.execute("DELETE FROM reporting_dirty WHERE hour=?", (hour,))

    def discard_dirty(self):
        """Release stale projection pages inside the retention transaction.

        Size pruning must not delete additional canonical history just because
        invalidated projections still occupy pages pending collector refresh.
        """
        for table in ("reporting_totals", "reporting_values", "reporting_hours"):
            self.db.execute(f"DELETE FROM {table} WHERE hour IN (SELECT hour FROM reporting_dirty)")
        self.db.execute("DELETE FROM reporting_dirty WHERE NOT EXISTS(SELECT 1 FROM requests "
                        "WHERE stamp>=reporting_dirty.hour AND stamp<reporting_dirty.hour+3600)")
        self.db.execute("DELETE FROM reporting_scopes WHERE id NOT IN "
                        "(SELECT DISTINCT scope_id FROM reporting_totals)")

    def _scope_where(self, endpoint=None, version=None, filters=None):
        from .store import _USAGE
        terms, values = [], []
        for key, value in (("endpoint", endpoint), ("version", version)):
            if value is not None:
                terms.append("s." + key + "=?")
                values.append(value)
        for key, value in (filters or {}).items():
            if key in SCOPE:
                terms.append("s." + key + "=?")
                values.append(value)
            elif key in {"successful", "origin_only"}:
                if str(value).lower() not in {"true", "false", "1", "0"}:
                    raise ValueError(key + " must be true or false")
                if key == "successful" and str(value).lower() in {"true", "1"}:
                    terms.append("(s.status BETWEEN 200 AND 299 OR s.status=304) AND NOT "
                                 "(s.endpoint_kind='mcp' AND s.mcp_outcome IN ('tool_error','protocol_error','transport_error'))")
            elif key == "usage":
                if value not in _USAGE:
                    raise ValueError("unsupported usage ranking")
                terms.append("(s.status BETWEEN 200 AND 299 OR s.status=304) AND s.method IN ('GET','HEAD','POST')")
                terms.append("s.endpoint_kind='search' AND s.operation IN ('search','reference')" if value == "search" else
                             "s.endpoint_kind='query' AND s.operation='scripture'" if value == "reference" else
                             "s.operation IN ('static','scripture','search','reference')")
            else:
                return None
        return " AND ".join(terms) or "1", values

    def _plan(self, start, end, endpoint=None, version=None, filters=None):
        self.store._where(start, end, endpoint, version, filters=filters)
        scoped = self._scope_where(endpoint, version, filters)
        if scoped is None:
            return None
        first, last = math.ceil(start / HOUR) * HOUR, math.floor(end / HOUR) * HOUR
        if last <= first:
            return None
        covered = [row[0] for row in self.db.execute("SELECT hour FROM reporting_hours WHERE hour>=? AND hour<? "
                    "AND NOT EXISTS(SELECT 1 FROM reporting_dirty d WHERE d.hour=reporting_hours.hour) ORDER BY hour", (first, last))]
        raw, cursor = [], start
        for hour in covered:
            if hour > cursor:
                raw.append((cursor, hour))
            cursor = hour + HOUR
        if cursor < end:
            raw.append((cursor, end))
        remaining = RAW_LIMIT
        current = math.floor(time.time() / HOUR) * HOUR
        for left, right in raw:
            # Refresh can prepare only complete, closed hours. Exact boundary
            # fragments and the live hour always remain raw; reporting them as
            # preparing would otherwise create a retry that can never finish.
            pending_start = math.ceil(left / HOUR) * HOUR
            pending_end = min(math.floor(right / HOUR) * HOUR, current)
            if pending_end <= pending_start:
                continue
            count = self.db.execute("SELECT count(*) FROM (SELECT 1 FROM requests WHERE stamp>=? AND stamp<? LIMIT ?)", (pending_start, pending_end, remaining + 1)).fetchone()[0]
            remaining -= count
            if remaining < 0:
                raise ReportingPreparing(self.progress())
        if not covered:
            return None
        return {"start": start, "end": end, "first": first, "last": last, "raw": raw,
                "scope": scoped, "endpoint": endpoint, "version": version, "filters": filters}

    @staticmethod
    def _ready(alias):
        return (f"EXISTS(SELECT 1 FROM reporting_hours h WHERE h.hour={alias}.hour) AND "
                f"NOT EXISTS(SELECT 1 FROM reporting_dirty d WHERE d.hour={alias}.hour)")

    def _totals(self, plan):
        from .store import _ERROR
        self.store._deadline()
        where, values = plan["scope"]
        select = [f"COALESCE(sum(t.{key}),0) AS {key}" for key in SUMS]
        select += ["max(t.max_duration_ms) AS max_duration_ms", "min(t.first_seen) AS first_seen", "max(t.last_seen) AS last_seen"]
        total = dict(self.db.execute("SELECT " + ",".join(select) + " FROM reporting_totals t JOIN reporting_scopes s ON s.id=t.scope_id "
                     "WHERE t.hour>=? AND t.hour<? AND " + self._ready("t") + " AND " + where, [plan["first"], plan["last"], *values]).fetchone())
        for left, right in plan["raw"]:
            raw_where, raw_values = self.store._where(left, right, plan["endpoint"], plan["version"], filters=plan["filters"])
            expressions = {"calls": "count(*)", "bytes": "sum(bytes)", "server_errors": "sum(status>=500)",
                "errors": f"sum({_ERROR})", "http_errors": "sum(status>=400)", "mcp_requests": "sum(endpoint_kind='mcp')",
                "mcp_errors": f"sum(endpoint_kind='mcp' AND {_ERROR})", "mcp_tool_calls": "sum(endpoint_kind='mcp' AND json_extract(runtime_json,'$.mcp_method')='tools/call')",
                "rate_limited": "sum(status=429)", "preflights": "sum(method='OPTIONS')", "cache_hits": "sum(cache='HIT')",
                "cache_requests": "sum(cache NOT IN ('','-'))", "duration_total": "sum(duration_ms)", "runtime_without_edge": "0"}
            for index, key in enumerate(HISTOGRAM):
                condition = f"duration_ms>{BOUNDS[-1]}" if index == len(BOUNDS) else f"duration_ms<={BOUNDS[index]}" + (f" AND duration_ms>{BOUNDS[index-1]}" if index else "")
                expressions[key] = "sum(" + condition + ")"
            statement = "SELECT " + ",".join(f"COALESCE({expressions[key]},0) AS {key}" for key in SUMS)
            statement += ",max(duration_ms) AS max_duration_ms,min(stamp) AS first_seen,max(stamp) AS last_seen FROM requests WHERE " + raw_where
            piece = dict(self.db.execute(statement, raw_values).fetchone())
            orphan_where, orphan_values = self.store._where(left, right, plan["endpoint"], plan["version"], origin_only=False, filters=plan["filters"])
            piece["runtime_without_edge"] = self.db.execute("SELECT count(*) FROM requests WHERE edge_json IS NULL AND " + orphan_where, orphan_values).fetchone()[0]
            _merge_totals(total, piece)
        filters = plan["filters"] or {}
        if "usage" in filters or str(filters.get("origin_only", "false")).lower() in {"true", "1"}:
            total["runtime_without_edge"] = 0
        return total

    def _dimension_query(self, dimension, plan):
        from .store import _DIMENSIONS, _MCP_DIMENSIONS, _USAGE, _ERROR, _dimension_sql
        # Use the canonical predicate builder for raw boundaries and its scoped
        # filter contract for the rolled interior; neither can replace a filter.
        _, _, scoped = self.store._breakdown_spec(dimension, plan["start"], plan["end"], plan["endpoint"], plan["version"], plan["filters"])
        where, values = plan["scope"]
        extra = {key: value for key, value in scoped.items() if key not in (plan["filters"] or {}) or (plan["filters"] or {})[key] != value}
        extra_where, extra_values = self._scope_where(filters=extra)
        terms = [where, extra_where]
        if dimension == "search":
            terms.append("s.operation IN ('search','reference')")
        elif dimension == "reference":
            terms.append("s.operation='scripture'")
        elif dimension in {"translation", "book"}:
            terms.append("s.operation IN ('static','scripture','search','reference')")
        if dimension in _USAGE:
            terms.append("s.method IN ('GET','HEAD','POST')")
        if dimension in SCOPE:
            table, column = "reporting_totals", "s." + dimension
            if dimension in _USAGE | _MCP_DIMENSIONS | {"referrer", "user_agent"}:
                terms.append(column + " NOT IN ('','-','[]')")
            columns = f"{column} AS value,t.calls,t.bytes,t.duration_total,t.errors,t.calls AS samples,NULL AS label"
        else:
            table = "reporting_values"
            columns = "t.value,t.calls,t.bytes,t.duration_total,t.errors,t.samples,t.label"
            terms.append("t.dimension=?")
        statement = f"SELECT {columns} FROM {table} t JOIN reporting_scopes s ON s.id=t.scope_id WHERE t.hour>=? AND t.hour<? AND " + self._ready("t") + " AND " + " AND ".join(terms)
        params = [plan["first"], plan["last"], *values, *extra_values]
        if dimension not in SCOPE:
            params.append(dimension)
        queries = [statement]
        for left, right in plan["raw"]:
            raw_where, raw_values, _ = self.store._breakdown_spec(dimension, left, right, plan["endpoint"], plan["version"], plan["filters"])
            if dimension == "book":
                raw = "SELECT CAST(b.value AS TEXT) AS value,count(DISTINCT requests.id) AS calls,sum(bytes) AS bytes,sum(duration_ms) AS duration_total," + f"sum({_ERROR}) AS errors,count(*) AS samples," + "min((SELECT n.value FROM json_each(book_names) n WHERE n.key=CAST(b.value AS TEXT))) AS label FROM requests,json_each(CASE WHEN json_valid(book) AND substr(book,1,1)='[' THEN book ELSE json_array(book) END) b WHERE " + raw_where + " GROUP BY b.value"
            else:
                column = _dimension_sql(dimension)
                raw = f"SELECT {column} AS value,count(*) AS calls,sum(bytes) AS bytes,sum(duration_ms) AS duration_total,sum({_ERROR}) AS errors,count(*) AS samples,NULL AS label FROM requests WHERE " + raw_where + " GROUP BY " + column
            queries.append(raw)
            params.extend(raw_values)
        return " UNION ALL ".join(queries), params, scoped

    def breakdown(self, dimension, start, end, endpoint=None, version=None, top=20, filters=None, plan=None):
        from .store import _DIMENSIONS, _USAGE
        if dimension not in _DIMENSIONS:
            raise ValueError("unsupported dimension: " + dimension)
        plan = plan or self._plan(start, end, endpoint, version, filters)
        if plan is None:
            return None
        self.store._deadline()
        query, values, scoped = self._dimension_query(dimension, plan)
        rows = [dict(row) for row in self.db.execute("SELECT value,sum(calls) AS calls,sum(bytes) AS bytes,"
                    "sum(duration_total)/CAST(sum(samples) AS REAL) AS duration_ms,sum(errors) AS errors,min(label) AS label "
                    "FROM (" + query + ") GROUP BY value HAVING sum(calls)>0 ORDER BY calls DESC,value LIMIT ?", [*values, max(1, min(int(top), 1000))])]
        for row in rows:
            row["filters"] = {**scoped, dimension: row["value"], "origin_only": "true"}
            if endpoint is not None:
                row["filters"]["endpoint"] = endpoint
            if version is not None:
                row["filters"]["version"] = version
            if dimension in _USAGE:
                inherited = scoped.get("usage")
                row["filters"]["usage"] = inherited if inherited in {"search", "reference"} else dimension
            if dimension == "book":
                if not row["label"]:
                    row["label"] = "Book " + row["value"] if row["value"].isdigit() else row["value"]
            else:
                row.pop("label")
        return rows

    def summary(self, start, end, endpoint=None, version=None, top=20, filters=None, dimensions=None):
        from .store import _DIMENSIONS, _MCP_DIMENSIONS
        dimensions = tuple(_DIMENSIONS if dimensions is None else dimensions)
        if any(dimension not in _DIMENSIONS for dimension in dimensions):
            raise ValueError("unsupported reporting dimension")
        plan = self._plan(start, end, endpoint, version, filters)
        if plan is None:
            return None
        totals = self._totals(plan)
        result = {key: totals[key] for key in COUNTS if key != "duration_total"}
        result.update({key: totals[key] for key in ("max_duration_ms", "first_seen", "last_seen")})
        for dimension, name in (("ip", "unique_ips"), ("token", "unique_tokens")):
            query, values, _ = self._dimension_query(dimension, plan)
            suffix = " WHERE value!=''" if dimension == "token" else ""
            result[name] = self.db.execute("SELECT count(DISTINCT value) FROM (" + query + ")" + suffix, values).fetchone()[0]
        result.update({"from": start, "to": end, "duration_ms": totals["duration_total"] / totals["calls"] if totals["calls"] else 0,
                       "requests_per_second": totals["calls"] / max(1, end - start), "origin_only": True,
                       "cache_hit_ratio": totals["cache_hits"] / totals["cache_requests"] if totals["cache_requests"] else None,
                       "latency_ms": _latency(totals), "retention": self.store.storage()})
        result["breakdowns"] = {dimension: [] if dimension in _MCP_DIMENSIONS and not totals["mcp_requests"] else
                                self.breakdown(dimension, start, end, endpoint, version, top, filters, plan) for dimension in dimensions}
        return result

    def latency(self, start, end, endpoint=None, version=None, filters=None):
        plan = self._plan(start, end, endpoint, version, filters)
        return None if plan is None else _latency(self._totals(plan))

    def series(self, start, end, bucket_seconds, endpoint=None, version=None, filters=None):
        bucket = effective_bucket_seconds(start, end, bucket_seconds)
        if bucket % HOUR:
            return None
        plan = self._plan(start, end, endpoint, version, filters)
        if plan is None:
            return None
        self.store._deadline()
        fields = ("calls", "errors", "server_errors", "mcp_errors", "rate_limited", "bytes", "duration_total", "cache_hits")
        where, values = plan["scope"]
        rows = self.db.execute("SELECT CAST(t.hour / ? AS INTEGER)*? AS stamp," + ",".join("sum(t." + key + ") AS " + key for key in fields) +
                ",max(t.max_duration_ms) AS max_duration_ms FROM reporting_totals t JOIN reporting_scopes s ON s.id=t.scope_id "
                "WHERE t.hour>=? AND t.hour<? AND " + self._ready("t") + " AND " + where + " GROUP BY 1 HAVING sum(t.calls)>0",
                [bucket, bucket, plan["first"], plan["last"], *values])
        series = {row["stamp"]: dict(row) for row in rows}
        for left, right in plan["raw"]:
            for row in self.store._series_raw(left, right, bucket, endpoint=endpoint, version=version, filters=filters):
                row["duration_total"] = row["duration_ms"] * row["calls"]
                current = series.setdefault(row["stamp"], {**dict.fromkeys(fields, 0), "stamp": row["stamp"], "max_duration_ms": None})
                for key in fields:
                    current[key] += row[key]
                current["max_duration_ms"] = row["max_duration_ms"] if current["max_duration_ms"] is None else max(current["max_duration_ms"], row["max_duration_ms"])
        return [{**{key: row[key] for key in row if key != "duration_total"}, "duration_ms": row["duration_total"] / row["calls"],
                 "bucket_seconds": bucket, "requests_per_second": row["calls"] / bucket} for _, row in sorted(series.items())]
