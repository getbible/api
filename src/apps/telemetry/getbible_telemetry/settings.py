"""Strict numeric settings shared by collector startup and live reload."""

from __future__ import annotations

import re


# Match the manager's public configuration contract, including decimal spelling.
_RULES = {
    "TELEMETRY_MAX_GIB": (r"[1-9][0-9]{0,5}", 1, 999999),
    "TELEMETRY_RETENTION_DAYS": (r"[0-9]{1,6}", 0, 999999),
    "TELEMETRY_SPOOL_MAX_GIB": (r"[1-9][0-9]{0,5}", 1, 999999),
    "TELEMETRY_SPOOL_ROTATE_MIB": (r"[1-9][0-9]{0,5}", 1, 999999),
    "TELEMETRY_BATCH_SIZE": (r"[1-9][0-9]{0,5}", 1, 100000),
    "TELEMETRY_FLUSH_SECONDS": (r"[1-9][0-9]{0,7}", 1, 99999999),
    "TELEMETRY_METRICS_SECONDS": (r"[1-9][0-9]{0,7}", 1, 99999999),
    "ALERT_COOLDOWN_SECONDS": (r"[1-9][0-9]{0,5}", 1, 999999),
    "ALERT_HOLD_SECONDS": (r"[1-9][0-9]{0,5}", 1, 999999),
    "ALERT_SYNC_GRACE_SECONDS": (r"[1-9][0-9]{0,5}", 1, 999999),
    **{name: (r"[0-9]{1,2}", 1, 95) for name in (
        "ALERT_CPU_PERCENT", "ALERT_MEMORY_PERCENT", "ALERT_DISK_PERCENT",
        "ALERT_MEMORY_PRESSURE_PERCENT")},
}


def numeric_setting(name: str, value: str | int) -> int:
    pattern, minimum, maximum = _RULES[name]
    text = str(value)
    if not re.fullmatch(pattern, text) or not minimum <= int(text) <= maximum:
        raise ValueError(f"{name} must be a decimal integer between {minimum} and {maximum}")
    return int(text)


SETTING_NAMES = frozenset(_RULES)
