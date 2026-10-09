"""Small structured-event producer for administrative and health events."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from threading import Lock
from typing import Any

from .store import redact

_lock = Lock()


def emit_event(event: str, payload: dict[str, Any], *,
               path: str = "/var/log/getbible/dashboard/app/dashboard.log") -> None:
    """Append one event to the collector's spool; never swallow write failures.

    The installer creates the parent directory with its service identity.
    Persistent session audit references use ``session_ref``; credential-bearing
    session IDs, passwords, OTPs and cookie fields are removed defensively.
    These infrequent administrative events close their append stream before
    returning, so an idle dashboard cannot pin a committed rotated spool.
    """
    entry = {"time": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
             "event": event, "level": payload.get("level", "INFO"), **redact(payload)}
    message = json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
    # Preserve serialized records and propagate write/flush/close failures to
    # callers rather than letting logging.Handler hide missing audit durability.
    with _lock, open(path, "a", encoding="utf-8") as stream:
        stream.write(message + "\n")
