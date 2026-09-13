"""Request hooks: request ids, timing, headers, CORS and the access log."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import time
import uuid
from typing import Any
from urllib.parse import quote

from flask import Flask, Response, g, request
from werkzeug.middleware.proxy_fix import ProxyFix

from .settings import ServiceSettings

_REQUEST_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
_TOKEN_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def install_request_hooks(app: Flask, settings: ServiceSettings, logger: logging.Logger) -> None:
    if settings.trust_proxy:
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)  # type: ignore[method-assign]

    @app.before_request
    def _begin() -> None:
        incoming = request.headers.get("X-Request-ID", "")
        g.request_id = incoming if _REQUEST_ID.fullmatch(incoming) else uuid.uuid4().hex
        token = request.headers.get("X-GetBible-Token-Id", "")
        g.token_id = token if _TOKEN_ID.fullmatch(token) else ""
        auth = request.headers.get("X-GetBible-Auth-State", "") if settings.trust_proxy else ""
        g.auth_state = auth if auth in {"anonymous", "valid", "rejected"} else ("valid" if g.token_id else "anonymous")
        g.started = time.perf_counter()
        g.operation = "http"

    @app.after_request
    def _finish(response: Response) -> Response:
        if settings.access_mode == "token":
            response.headers["Cache-Control"] = "private, no-store"
            response.headers["CDN-Cache-Control"] = "no-store"
            response.vary.add("Authorization")
        response.headers["X-Request-ID"] = g.get("request_id", "-")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Cross-Origin-Resource-Policy", "cross-origin")
        response.headers.setdefault("Access-Control-Allow-Origin", "*")
        response.headers.setdefault(
            "Access-Control-Expose-Headers",
            "Cache-Control, ETag, Last-Modified, Date, Age, Expires, Content-Length, "
            "Content-Range, Retry-After, X-Cache-Status, CF-Cache-Status, X-Request-ID",
        )
        duration_ms = round((time.perf_counter() - g.get("started", time.perf_counter())) * 1000, 3)
        operation = g.get("operation")
        endpoint_kind = settings.prefix.casefold()
        # nginx stores these private headers with the cached response and
        # includes them in its access log, so a cache HIT retains the exact
        # runtime resolution without running the librarian again.
        semantic = {"translation": g.get("translation"), "version": g.get("version"),
                    "endpoint_kind": endpoint_kind, "operation": operation, "books": g.get("books")}
        if 200 <= response.status_code < 300 or response.status_code == 304:
            for key, value in semantic.items():
                if value is not None:
                    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":")) if isinstance(value, (list, dict)) else str(value)
                    response.headers["X-GetBible-Telemetry-" + key.replace("_", "-")] = quote(encoded, safe="")
        if operation in {"health", "readiness"} and response.status_code < 500:
            return response
        extra: dict[str, Any] = {
            "event": "request",
            "request_id": g.get("request_id"),
            "method": request.method,
            "path": request.path,
            "query": request.query_string.decode("utf-8", "replace"),
            "status": response.status_code,
            "duration_ms": duration_ms,
            "remote_addr": request.remote_addr,
            "token": g.get("token_id") or None,
            "auth_state": g.get("auth_state"),
            "worker_pid": os.getpid(),
            "in_flight": g.get("in_flight"),
            "source_generation": g.get("source_generation"),
            "resident_bytes_estimate": g.get("resident_bytes_estimate"),
            "user_agent": request.headers.get("User-Agent", ""),
            "referrer": request.headers.get("Referer", ""),
            "endpoint_kind": endpoint_kind,
            "response_bytes": response.calculate_content_length(),
            "operation": operation,
            "version": g.get("version"),
            "translation": g.get("translation"),
            "reference": g.get("reference"),
            "references": g.get("references"),
            "books": g.get("books"),
            "matched_books": g.get("matched_books"),
            "verses": g.get("verses"),
            "search": g.get("search"),
            "criteria": g.get("criteria"),
            "kind": g.get("kind"),
            "total": g.get("total"),
            "returned": g.get("returned"),
            "expensive": g.get("expensive"),
            "cache_stale": g.get("cache_stale"),
            "problem": g.get("problem_code"),
        }
        level = logging.WARNING if response.status_code >= 500 or duration_ms >= settings.slow_request_milliseconds else logging.INFO
        logger.log(level, "request", extra=extra)
        return response


def json_response(app: Flask, payload: dict[str, Any], *, cache_seconds: int = 0, status: int = 200) -> Response:
    """Serialise a librarian result verbatim with caching headers and an ETag."""
    body = app.json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    response = Response(body, status=status, content_type="application/json; charset=utf-8")
    if status < 400 and cache_seconds > 0 and request.method in {"GET", "HEAD"}:
        response.headers["Cache-Control"] = f"public, max-age={cache_seconds}, stale-while-revalidate=60"
        response.set_etag(hashlib.sha256(body.encode("utf-8")).hexdigest())
        response.make_conditional(request)
    else:
        response.headers["Cache-Control"] = "no-store"
    return response


def redirect_permanent(location: str) -> Response:
    """Preserve POST methods and JSON bodies through canonical aliases."""
    response = Response(status=308 if request.method == "POST" else 301)
    response.headers["Location"] = location
    response.headers["Cache-Control"] = "no-store" if request.method == "POST" else "public, max-age=300"
    return response
