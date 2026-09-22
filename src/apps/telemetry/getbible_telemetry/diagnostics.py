"""Read-only capacity diagnostics, including configuration ownership.

This reader deliberately does not open TelemetryStore: capacity diagnosis must
remain available when the collector needs a schema migration. It reads one
bounded metadata row and never migrates, creates or resets a database.
"""
from __future__ import annotations

import json
from contextlib import closing
import os
from pathlib import Path
import shlex
import sqlite3
from types import SimpleNamespace
from typing import Any

from .capacity import capacity_report


def read_config(path: str | os.PathLike[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        with Path(path).open(encoding="utf-8") as stream:
            for raw in stream:
                if len(raw) > 16384:
                    continue
                key, separator, value = raw.strip().removeprefix("export ").partition("=")
                if not separator or not key.replace("_", "").isalnum():
                    continue
                try:
                    tokens = shlex.split(value, comments=True)
                except ValueError:
                    continue
                if len(tokens) <= 1:
                    result[key] = tokens[0] if tokens else ""
    except OSError:
        pass
    return result


def read_capacity(path: str | os.PathLike[str], config: str | os.PathLike[str],
                  environment: str | os.PathLike[str], *, now: float | None = None) -> dict[str, Any]:
    result: dict[str, Any]
    try:
        # A corrupt/locked database is not allowed to block management.
        with closing(sqlite3.connect(Path(path).absolute().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            db.execute("PRAGMA query_only=ON")
            result = capacity_report(SimpleNamespace(db=db), now=now)
    except (sqlite3.Error, ValueError, TypeError, KeyError, OSError):
        result = {"state": "unavailable", "limits": [], "collection": {"state": "unknown"},
                  "note": "Capacity history is unavailable. Inspect the collector, reporting preparation and filesystem; no history was modified."}
    saved = read_config(config)
    captured = read_config(environment)
    for row in result.get("limits", []):
        key = row.get("setting")
        if not key:
            row["configuration"] = {"owner": "host", "value": None, "editable": False}
        elif key.startswith("GETBIBLE_"):
            row["configuration"] = {"owner": "deployment", "key": key, "value": None, "editable": False,
                                    "note": "The effective cgroup limit is measured. Change the Docker host deployment configuration; its source value is not available inside the container."}
        else:
            env_key = "GETBIBLE_" + key
            override = os.environ.get(env_key) or captured.get(key) or captured.get(env_key)
            row["configuration"] = {"owner": "environment" if override else "saved", "key": env_key if override else key,
                                    "value": override or saved.get(key), "editable": not bool(override)}
    return result


def format_capacity(report: dict[str, Any]) -> str:
    lines = ["getBible capacity", "State: " + report["state"], report.get("note", ""), ""]
    collection = report.get("collection", {})
    lines.append("Collection: " + collection.get("state", "unknown"))
    for key in ("unread_bytes", "unread_files", "budgeted_spool_bytes", "retained_archive_bytes", "consumed_rotated_bytes",
                "producer_bytes_per_second", "collector_bytes_per_second", "backlog_growth_bytes_per_second", "backlog_observed_seconds"):
        if collection.get(key) is not None:
            lines.append(f"  {key}: {collection[key]}")
    lines.append("")
    for row in report.get("limits", []):
        lines.append(row["label"])
        if row.get("available"):
            lines.append(f"  Current: {row['used']:.3f} / {row['effective_limit']:.3f} {row['unit']}; observed peak: {row['high_water']:.3f} {row['unit']}")
            lines.append(f"  Saturated samples: {row['saturated_samples']} / {row['samples']}; episodes: {row['episodes']}; observed seconds: {row['observed_seconds']:.1f}")
        advice = row.get("recommendation", {})
        lines.append(f"  Advice: {advice.get('status', 'unavailable')}; suggested value: {advice.get('value')} {row['unit']}")
        lines.append("  " + advice.get("reason", ""))
        setting = row.get("configuration", {})
        lines.append(f"  Configuration: {setting.get('owner')}; {setting.get('key', '-')}={setting.get('value', 'unknown')}")
        if advice.get("assumptions"):
            lines.append("  " + advice["assumptions"])
        lines.append("")
    return "\n".join(lines)
