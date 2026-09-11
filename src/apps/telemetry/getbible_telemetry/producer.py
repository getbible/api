"""Small structured-event producer for administrative and health events."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from logging.handlers import WatchedFileHandler
from threading import Lock
from typing import Any

from .store import redact

_handlers: dict[str, WatchedFileHandler] = {}
_lock = Lock()


def emit_event(event: str, payload: dict[str, Any], *,
               path: str = "/var/log/getbible/dashboard/app/dashboard.log") -> None:
    """Append one event to the collector's spool; never swallow write failures.

    The installer creates the parent directory with its service identity.
    Persistent session audit references use ``session_ref``; credential-bearing
    session IDs, passwords, OTPs and cookie fields are removed defensively.
    """
    entry = {"time": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
             "event": event, "level": payload.get("level", "INFO"), **redact(payload)}
    message = json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
    with _lock:
        handler = _handlers.get(path)
        if handler is None:
            handler = WatchedFileHandler(path, encoding="utf-8")
            _handlers[path] = handler
        # Logging.Handler.emit normally swallows disk errors. Administrative
        # callers need a real error so they can expose missing audit durability.
        handler.reopenIfNeeded()
        handler.stream.write(message + "\n")
        handler.flush()


def close_producers() -> None:
    with _lock:
        for handler in _handlers.values():
            handler.close()
        _handlers.clear()
