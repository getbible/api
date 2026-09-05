"""JSON line logging: one file the dashboards can read, journald as backup."""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
from datetime import datetime, timezone
from typing import Any

# Fields copied from a LogRecord's extra attributes when present.
EXTRA_FIELDS = (
    "event", "request_id", "method", "path", "query", "status", "duration_ms", "remote_addr",
    "token", "user_agent", "response_bytes", "operation", "version", "translation", "reference",
    "references", "verses", "search", "criteria", "kind", "total", "returned", "expensive",
    "cache_stale", "error_type", "problem", "dropped",
)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "time": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for field in EXTRA_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def configure_logging(name: str, level: str, path: str = "") -> logging.Logger:
    """Log JSON lines to `path` (reopened after rotation) and, for warnings
    and above, to stderr so journald keeps the failures too."""
    logger = logging.getLogger(name)
    for handler in tuple(logger.handlers):
        logger.removeHandler(handler)
        handler.close()
    formatter = JsonFormatter()
    if path:
        directory = os.path.dirname(path)
        if directory and os.path.isdir(directory) and os.access(directory, os.W_OK):
            handler: logging.Handler = logging.handlers.WatchedFileHandler(path, encoding="utf-8")
            handler.setFormatter(formatter)
            logger.addHandler(handler)
            stderr = logging.StreamHandler()
            stderr.setFormatter(formatter)
            stderr.setLevel(logging.WARNING)
            logger.addHandler(stderr)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    logger.setLevel(level)
    logger.propagate = False
    return logger
