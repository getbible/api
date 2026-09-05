"""Cheap liveness, scripture readiness and an explicit search deployment probe."""

from __future__ import annotations

import logging

from flask import Flask, Response, g
from getbible import GetBible, SearchBible

from .http import json_response


def register_health(app: Flask, bible: GetBible, default_translation: str, logger: logging.Logger,
                    *, reference: str = "1 1:1", search_probe: bool = False) -> None:
    @app.get("/healthz")
    def _health() -> Response:
        g.operation = "health"
        return json_response(app, {"status": "ok"})

    def check(*, search: bool = False) -> Response:
        g.operation = "probe" if search else "readiness"
        try:
            # Translation metadata alone does not prove the chapter files are readable.
            scripture = bible.select(reference, default_translation)
            ready = any(chapter.get("verses") for chapter in scripture.values())
            if ready and search:
                # This deliberate deployment/monitoring probe also opens the complete
                # search corpus. Normal readiness does not build/search it repeatedly.
                result = bible.search("getbiblereadinessprobe", default_translation,
                                      SearchBible.from_value({"limit": 1}))
                ready = isinstance(result.get("query", {}).get("total"), int)
        except Exception:
            logger.exception("Readiness check failed", extra={"event": "readiness_failure", "request_id": g.get("request_id")})
            ready = False
        return json_response(app, {"status": "ready" if ready else "unavailable"}, status=200 if ready else 503)

    @app.get("/readyz")
    def _ready() -> Response:
        return check()

    if search_probe:
        @app.get("/probez")
        def _probe() -> Response:
            return check(search=True)
