"""Liveness and readiness routes used by systemd, nginx and the menu."""

from __future__ import annotations

import logging

from flask import Flask, Response, g
from getbible import GetBible, RepositoryError

from .http import json_response


def register_health(app: Flask, bible: GetBible, default_translation: str, logger: logging.Logger) -> None:
    @app.get("/healthz")
    def _health() -> Response:
        g.operation = "health"
        return json_response(app, {"status": "ok"})

    @app.get("/readyz")
    def _ready() -> Response:
        g.operation = "readiness"
        try:
            ready = bible.valid_translation(default_translation)
        except RepositoryError:
            logger.exception("Readiness check failed", extra={"event": "readiness_failure", "request_id": g.get("request_id")})
            ready = False
        return json_response(app, {"status": "ready" if ready else "unavailable"}, status=200 if ready else 503)
