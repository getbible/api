"""Bounded, persistent capacity observations and explicit sizing advice.

Advice is a headroom calculation over observed demand, not an automatic setting
change or a promise that capped demand has been measured. Collection gaps and
missing sensors are explicit; historical maxima are retained for 24 hours.
"""
from __future__ import annotations

import json
import math
import time
from typing import Any

GIB = 1024**3
MIB = 1024**2
WINDOW = 24 * 3600
HEADROOM = .25


def finite(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and value >= 0 else None


def incident_update(state: dict[str, Any], value: float, limit: float, *, now: float,
                    hold: float, cooldown: float, reminder: float) -> str | None:
    """Mutate one durable incident, returning only meaningful notifications.

    Cooldown bounds deterioration notifications; it is *not* a repeat interval.
    Recovery requires sustained usage below 80% of the triggering threshold.
    Old health_alerts records are accepted without resetting active incidents.
    """
    if finite(value) is None or finite(limit) in (None, 0):
        return None
    ratio = value / limit
    state.setdefault("active", False)
    state.setdefault("since", None)
    state.setdefault("last_sent", 0)
    state.setdefault("episodes", 0)
    state["value"], state["limit"], state["observed_at"] = value, limit, now
    state["high_water"] = max(value, state.get("high_water", 0))
    if ratio >= 1:
        if state["since"] is None or state["since"] > now:
            state["since"] = now
        state["clear_since"] = None
        if now - state["since"] < hold:
            return None
        event = None
        if not state["active"]:
            state["active"] = True
            state["episodes"] += 1
            event = "onset"
        elif now - state["last_sent"] >= cooldown and ratio >= max(1.25, state.get("sent_ratio", ratio) * 1.5):
            event = "worsened"
        elif now - state["last_sent"] >= max(reminder, cooldown):
            event = "reminder"
        if event:
            state["last_sent"], state["sent_ratio"] = now, ratio
            state["last_event"] = event
        return event
    if not state["active"]:
        state["since"] = None
        return None
    if ratio > .8:
        state["clear_since"] = None
        return None
    if state.get("clear_since") is None or state["clear_since"] > now:
        state["clear_since"] = now
    if now - state["clear_since"] < hold:
        return None
    state.update(active=False, since=None, clear_since=None, last_event="recovered")
    return "recovered"


class CapacityTracker:
    def __init__(self, store) -> None:
        self.store = store
        row = store.db.execute("SELECT value FROM metadata WHERE key='capacity_internal:history'").fetchone()
        try:
            self.history = json.loads(row[0]) if row else {}
        except (ValueError, TypeError):
            self.history = {}
        self.history.setdefault("hours", {})

    def observe(self, sample: dict[str, Any], spool: dict[str, Any], *, now: float | None = None) -> dict[str, Any]:
        now = time.time() if now is None else now
        old = self.history.get("previous", {})
        elapsed = now - old.get("stamp", now)
        # Missing time is not reported as either healthy or saturated time.
        duration = elapsed if 0 < elapsed <= 60 else 0
        hours = self.history["hours"]
        hours = {key: value for key, value in hours.items() if now - WINDOW <= float(key) * 3600 <= now}
        self.history["hours"] = hours
        bucket = hours.setdefault(str(int(now // 3600)), {})
        memory = sample.get("memory", {})
        cpu = sample.get("cpu", {})
        pids = sample.get("pids", {})
        usage = spool.get("budgeted_spool_bytes", spool.get("spool_bytes"))
        definitions = [
            ("telemetry_spool", "Telemetry transport", "TELEMETRY_SPOOL_MAX_GIB", "GiB", usage, spool.get("spool_max_bytes"), GIB),
            ("telemetry_history", "Telemetry history", "TELEMETRY_MAX_GIB", "GiB", spool.get("history_active_bytes"), spool.get("history_max_bytes"), GIB),
            ("memory", "Memory", "GETBIBLE_MEMORY_LIMIT" if sample.get("scope") == "cgroup" else None, "GiB", memory.get("current_bytes"), memory.get("limit_bytes"), GIB),
            ("cpu", "CPU", "GETBIBLE_CPU_LIMIT" if sample.get("scope") == "cgroup" else None, "cores", cpu.get("used_units"), cpu.get("capacity"), 1),
            ("pids", "Processes / threads", "GETBIBLE_PIDS_LIMIT" if sample.get("scope") == "cgroup" else None, "tasks", pids.get("current"), pids.get("limit"), 1),
        ]
        for disk in sample.get("disks", []):
            definitions.append(("disk:" + disk["path"], "Filesystem " + disk["path"], None, "GiB",
                                disk.get("used_bytes"), disk.get("total_bytes"), GIB))
        current = []
        for key, label, setting, unit, value, limit, scale in definitions:
            value, limit = finite(value), finite(limit)
            if value is None or limit in (None, 0):
                current.append({"id": key, "label": label, "setting": setting, "unit": unit,
                                "available": False, "recommendation": {"status": "unavailable", "value": None,
                                "reason": "The effective limit or measured usage is unavailable."}})
                continue
            record = bucket.setdefault(key, {"peak": 0, "samples": 0, "seconds": 0,
                                             "saturated_seconds": 0, "saturated_samples": 0, "episodes": 0})
            above = value >= limit * .9
            record["peak"] = max(record["peak"], value)
            record["samples"] += 1
            record["seconds"] += duration
            if above:
                record["saturated_seconds"] += duration
                record["saturated_samples"] += 1
                if not old.get("above", {}).get(key, False):
                    record["episodes"] += 1
            aggregate = [hour[key] for hour in hours.values() if key in hour]
            row = {"id": key, "label": label, "setting": setting, "unit": unit, "available": True,
                   "effective_limit": limit / scale, "used": value / scale, "usage_fraction": value / limit,
                   "high_water": max(item["peak"] for item in aggregate) / scale,
                   "samples": sum(item["samples"] for item in aggregate),
                   "observed_seconds": sum(item["seconds"] for item in aggregate),
                   "saturated_seconds": sum(item["saturated_seconds"] for item in aggregate),
                   "saturated_samples": sum(item["saturated_samples"] for item in aggregate),
                   "episodes": sum(item["episodes"] for item in aggregate), "saturation_threshold": .9}
            row["recommendation"] = self._recommend(row, sample, spool)
            current.append(row)
        rates = {"producer_bytes_per_second": None, "collector_bytes_per_second": None,
                 "backlog_growth_bytes_per_second": None, "collector_records_per_second": None}
        same_instance = old.get("instance") == spool.get("collector_instance")
        if duration and same_instance:
            committed = spool.get("committed_bytes", 0) - old.get("committed_bytes", 0)
            records = spool.get("committed_records", 0) - old.get("committed_records", 0)
            growth = spool.get("unread_bytes", 0) - old.get("unread_bytes", 0)
            if committed >= 0 and records >= 0:
                rates.update(collector_bytes_per_second=committed / duration,
                             collector_records_per_second=records / duration,
                             backlog_growth_bytes_per_second=growth / duration)
                if not spool.get("compressed_pending_bytes") and not old.get("compressed_pending_bytes"):
                    rates["producer_bytes_per_second"] = max(0, committed + growth) / duration
        pending = bool(spool.get("unread_files"))
        since = old.get("backlog_since") if duration and old.get("backlog_since") is not None else now
        since = since if pending else None
        observations = self.history.setdefault("rates", [])
        observations[:] = [row for row in observations if now - 300 <= row["stamp"] <= now]
        observations.append({"stamp": now, **rates})
        # Bounded at the default five-second sampling interval; faster custom
        # metrics never make diagnostic memory or stored state unbounded.
        del observations[:-120]
        for key in rates:
            values = [row[key] for row in observations if row.get(key) is not None]
            rates[key] = sum(values) / len(values) if values else None
        backlog_age = now - since if since is not None else 0
        collecting = rates["collector_bytes_per_second"]
        growth = rates["backlog_growth_bytes_per_second"]
        state = "unknown" if collecting is None else "caught_up" if not pending else (
            "stalled" if collecting == 0 and backlog_age >= 60 else "falling_behind" if growth and growth > 0 and backlog_age >= 60 else "catching_up")
        for row in current:
            if row["id"] == "telemetry_spool" and state in {"stalled", "falling_behind"}:
                row["recommendation"] = {"status": "investigate_collection", "value": None,
                    "reason": "The backlog is not clearing. A larger spool only delays exhaustion; inspect collection throughput and blocked sources first."}
        result = {"sampled_at": now, "window_seconds": WINDOW, "headroom_fraction": HEADROOM,
                  "limits": current, "collection": {"state": state, "backlog_observed_seconds": backlog_age,
                  "unread_bytes": spool.get("unread_bytes"), "unread_files": spool.get("unread_files"),
                  "budgeted_spool_bytes": usage, "retained_archive_bytes": spool.get("retained_archive_bytes"),
                  "compressed_pending_bytes": spool.get("compressed_pending_bytes"), "rate_window_seconds": 300,
                  "rate_samples": len(observations), **rates}, "problems": spool.get("problems", {}),
                  "note": "Suggested values use observed peak / 0.75. Capped demand is a lower bound, not an ideal-value guarantee. No setting is changed automatically."}
        self.history["previous"] = {"stamp": now, "instance": spool.get("collector_instance"),
            "committed_bytes": spool.get("committed_bytes", 0), "committed_records": spool.get("committed_records", 0),
            "unread_bytes": spool.get("unread_bytes", 0), "compressed_pending_bytes": spool.get("compressed_pending_bytes", 0),
            "backlog_since": since, "above": {row["id"]: row.get("usage_fraction", 0) >= .9 for row in current}}
        self.store.set_metadata("capacity_internal:history", self.history)
        self.store.set_metadata("capacity", result)
        return result

    @staticmethod
    def _recommend(row: dict[str, Any], sample: dict[str, Any], spool: dict[str, Any]) -> dict[str, Any]:
        if row["observed_seconds"] < 60 or row["samples"] < 6:
            return {"status": "insufficient_data", "value": None,
                    "reason": "Collect at least 60 observed seconds and six samples before sizing."}
        if row["setting"] is None:
            return {"status": "operator_review", "value": None,
                    "reason": "This is a host/filesystem measurement, not an adjustable application allowance. Review physical headroom and workload."}
        desired = max(row["effective_limit"], row["high_water"] / (1 - HEADROOM))
        quantum = .1 if row["unit"] == "cores" else .25 if row["id"] == "memory" else 1
        desired = math.ceil(desired / quantum) * quantum
        if row["id"] == "telemetry_spool":
            if spool.get("consumed_rotated_bytes", 0) > spool.get("spool_max_bytes", GIB) * .25 and spool.get("problems", {}).get("spool_cleanup", {}).get("retained", 0):
                return {"status": "investigate_cleanup", "value": None,
                        "reason": "Committed transport files are awaiting safe closure or filesystem lease support; inspect spool_cleanup before increasing the budget."}
        if row["id"] in {"telemetry_spool", "telemetry_history"}:
            disks = sample.get("disks", [])
            if not disks:
                return {"status": "headroom_unknown", "value": None, "reason": "Filesystem free space is unavailable."}
            headroom = min(max(0, disk.get("free_bytes", 0) - max(GIB, disk.get("total_bytes", 0) * .1)) for disk in disks) / GIB
            if desired - row["effective_limit"] > headroom:
                return {"status": "insufficient_headroom", "value": None,
                        "reason": "The suggested increase does not fit measured filesystem headroom while retaining a 10% / 1 GiB reserve."}
        if row["id"] == "memory" and desired > row["effective_limit"]:
            available = finite(sample.get("memory", {}).get("host_available_bytes"))
            if available is None or (desired - row["effective_limit"]) * GIB > available * .5:
                return {"status": "headroom_unknown" if available is None else "insufficient_headroom", "value": None,
                        "reason": "An increased container memory limit needs confirmed host headroom; reserve at least half of currently available host memory."}
        return {"status": "adequate" if desired <= row["effective_limit"] else "suggested",
                "value": round(desired, 2), "reason": "Observed 24-hour peak with 25% headroom; never automatically lowers the current allowance.",
                "assumptions": "Observed demand may be censored by current limits. Confirm workload and physical/provider capacity before applying."}


def capacity_report(store, *, now: float | None = None) -> dict[str, Any]:
    """Read a tiny persisted diagnostic snapshot, never scan traffic history."""
    now = time.time() if now is None else now
    row = store.db.execute("SELECT value FROM metadata WHERE key='capacity'").fetchone()
    if not row:
        return {"state": "insufficient_data", "limits": [], "collection": {"state": "unknown"},
                "note": "Capacity observations will appear after the collector samples this release."}
    result = json.loads(row[0])
    result["age_seconds"] = max(0, now - result["sampled_at"])
    result["stale"] = result["age_seconds"] > 60
    result["state"] = "stale" if result["stale"] else "observed"
    if result["stale"]:
        for item in result.get("limits", []):
            item["recommendation"] = {"status": "stale", "value": None, "reason": "Collection is not providing current observations."}
    return result
