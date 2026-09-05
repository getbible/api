"""RFC 9457 problem documents and the librarian exception ladder."""

from __future__ import annotations

import logging
from typing import Any

from flask import Flask, Response, g, request
from getbible import (
    CacheIntegrityError,
    ReferenceValidationError,
    RepositoryError,
    RepositoryResponseError,
    RequestLimitError,
    SearchDeadlineExceeded,
    SearchLimitError,
    SearchValidationError,
    TranslationNotFoundError,
)
from werkzeug.exceptions import HTTPException

PROBLEM_BASE = "https://getbible.net/problems/"
MEDIA_TYPE = "application/problem+json"

_TITLES = {
    400: "Bad Request",
    401: "Unauthorized",
    404: "Not Found",
    405: "Method Not Allowed",
    413: "Payload Too Large",
    415: "Unsupported Media Type",
    422: "Unprocessable Content",
    429: "Too Many Requests",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


def problem(
    app: Flask,
    status: int,
    code: str,
    detail: str,
    *,
    title: str | None = None,
    headers: dict[str, str] | None = None,
    **extra: Any,
) -> Response:
    """Build a problem document. `detail` is the human-readable message."""
    body: dict[str, Any] = {
        "type": PROBLEM_BASE + code.replace("_", "-"),
        "title": title or _TITLES.get(status, "Error"),
        "status": status,
        "code": code,
        "detail": detail,
        "instance": f"urn:request:{g.get('request_id', '-')}",
    }
    body.update(extra)
    payload = app.json.dumps(body, ensure_ascii=False, separators=(",", ":")) + "\n"
    response = Response(payload, status=status, content_type=f"{MEDIA_TYPE}; charset=utf-8")
    response.headers["Cache-Control"] = "no-store"
    for name, value in (headers or {}).items():
        response.headers[name] = value
    g.problem_code = code
    return response


class ProblemError(Exception):
    """Raise anywhere in a request to answer with a problem document."""

    def __init__(self, status: int, code: str, detail: str, **extra: Any) -> None:
        super().__init__(detail)
        self.status = status
        self.code = code
        self.detail = detail
        self.extra = extra


def register_error_handlers(app: Flask, logger: logging.Logger) -> None:
    """Map every failure to a stable problem document. Order matters: the
    librarian's deadline error is a ValueError subclass, so it is handled
    before the generic invalid-input ladder."""

    @app.errorhandler(ProblemError)
    def _problem(error: ProblemError) -> Response:
        return problem(app, error.status, error.code, error.detail, **error.extra)

    @app.errorhandler(SearchDeadlineExceeded)
    def _deadline(error: Exception) -> Response:
        logger.warning("Search deadline exceeded", extra={"event": "search_deadline", "request_id": g.get("request_id")})
        return problem(app, 503, "search_timeout",
                       "The search exceeded its time budget. Narrow the search or retry shortly.",
                       headers={"Retry-After": "5"})

    @app.errorhandler(TimeoutError)
    def _timeout(error: Exception) -> Response:
        logger.warning("Operation timed out", extra={"event": "timeout", "request_id": g.get("request_id")})
        return problem(app, 503, "timeout", "The operation timed out. Retry shortly.", headers={"Retry-After": "5"})

    @app.errorhandler(SearchLimitError)
    @app.errorhandler(RequestLimitError)
    def _limits(error: Exception) -> Response:
        return problem(app, 400, "request_limit", str(error))

    @app.errorhandler(SearchValidationError)
    def _search_invalid(error: Exception) -> Response:
        return problem(app, 400, "invalid_search", str(error))

    @app.errorhandler(ReferenceValidationError)
    def _reference_invalid(error: Exception) -> Response:
        return problem(app, 400, "invalid_reference", str(error))

    @app.errorhandler(ValueError)
    def _invalid(error: Exception) -> Response:
        return problem(app, 400, "invalid_request", str(error))

    @app.errorhandler(TranslationNotFoundError)
    def _translation(error: Exception) -> Response:
        return problem(app, 404, "translation_not_found", str(error))

    @app.errorhandler(FileNotFoundError)
    def _not_found(error: Exception) -> Response:
        return problem(app, 404, "not_found", str(error))

    @app.errorhandler(CacheIntegrityError)
    @app.errorhandler(RepositoryResponseError)
    @app.errorhandler(RepositoryError)
    def _repository(error: Exception) -> Response:
        logger.exception("Scripture repository failure", extra={
            "event": "repository_failure", "request_id": g.get("request_id"), "error_type": type(error).__name__,
        })
        return problem(app, 503, "repository_unavailable",
                       "The Scripture repository is temporarily unavailable.", headers={"Retry-After": "10"})

    @app.errorhandler(HTTPException)
    def _http(error: HTTPException) -> Response:
        status = error.code or 500
        code = {404: "not_found", 405: "method_not_allowed", 413: "payload_too_large", 415: "unsupported_media_type"}.get(
            status, "http_error")
        headers = {}
        if status == 405:
            allowed = error.get_response().headers.get("Allow", "")
            if allowed:
                headers["Allow"] = allowed
        detail = error.description or _TITLES.get(status, "Error")
        if status == 404:
            detail = "No such route on this endpoint. The documentation at the domain root lists the available paths."
        return problem(app, status, code, detail, headers=headers)

    @app.errorhandler(Exception)
    def _unexpected(error: Exception) -> Response:
        logger.exception("Unhandled exception", extra={
            "event": "unhandled_exception", "request_id": g.get("request_id"), "error_type": type(error).__name__,
        })
        return problem(app, 500, "internal_error", "An unexpected error occurred.")


def wants_json_body() -> bool:
    return request.method == "POST"
