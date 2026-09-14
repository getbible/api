"""Append-only JSON transport spools consumed into canonical local telemetry."""

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
    "auth_state", "worker_pid", "in_flight", "source_generation", "resident_bytes_estimate",
    "books", "matched_books", "referrer", "endpoint_kind",
    "mcp_method", "mcp_tool", "mcp_client_name", "mcp_client_version", "mcp_outcome",
    "mcp_resource", "mcp_prompt", "upstream_service", "upstream_api_version", "upstream_operation",
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
    """Append JSON for asynchronous collection; reopen after spool rotation.

    Warnings also reach journald as an emergency diagnostic channel when the
    telemetry disk or collector is unavailable. Request history lives in the
    telemetry store; this spool is not a second retained analytics archive.
    """
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
