"""Observe MCP HTTP interactions without changing protocol bodies or buffering streams."""

from __future__ import annotations

import json
import logging
import os
import re
import time
import uuid
from contextvars import ContextVar
from typing import Any
from urllib.parse import quote

from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

_REQUEST_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
_TOKEN_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
_BEARER = re.compile(r"\bBearer\s+[^\s\"'&,;]+", re.IGNORECASE)
_SECRET = re.compile(
    r"\b(authorization|password|secret|api[_-]?key|access[_-]?token|token)\s*[:=]\s*[^\s&,;]+",
    re.IGNORECASE,
)
_UPSTREAM: ContextVar[dict[str, str] | None] = ContextVar("mcp_upstream", default=None)


def record_upstream(service: str, version: str) -> None:
    """Record resolved destinations within the current request, including concurrent calls."""
    metadata = _UPSTREAM.get()
    if metadata is not None:
        for key, value in (("upstream_service", service), ("upstream_api_version", version)):
            previous = metadata.get(key)
            metadata[key] = value if previous in {None, value} else "multiple"


def _text(value: Any, limit: int = 512) -> str:
    if not isinstance(value, str):
        return ""
    # Sanitize before truncating, including user-supplied client names and references.
    value = _BEARER.sub("Bearer [REDACTED]", value)
    value = _SECRET.sub(lambda match: match[1] + "=[REDACTED]", value)
    return value[:limit]


class JsonObservation:
    """Retain only a bounded copy; every original chunk continues immediately."""

    def __init__(self, limit: int = 64 * 1024) -> None:
        self.limit = limit
        self.body = bytearray()
        self.complete = False
        self.overflow = False

    def feed(self, message: Message) -> None:
        chunk = message.get("body", b"")
        if not self.overflow:
            if len(self.body) + len(chunk) > self.limit:
                self.body.clear()
                self.overflow = True
            else:
                self.body.extend(chunk)
        self.complete = not message.get("more_body", False)

    def document(self) -> dict[str, Any]:
        if not self.complete or self.overflow or not self.body:
            return {}
        try:
            document = json.loads(self.body)
        except (ValueError, UnicodeError, RecursionError):
            return {}
        return document if isinstance(document, dict) else {}


def request_metadata(document: dict[str, Any]) -> dict[str, str]:
    method = _text(document.get("method"), 128)
    params = document.get("params")
    params = params if isinstance(params, dict) else {}
    meta = params.get("_meta")
    meta = meta if isinstance(meta, dict) else {}
    client = meta.get("io.modelcontextprotocol/clientInfo") or params.get("clientInfo")
    client = client if isinstance(client, dict) else {}
    tool = _text(params.get("name"), 128) if method == "tools/call" else ""
    fields = {
        "operation": tool or method or "http",
        "mcp_method": method,
        "mcp_tool": tool,
        "mcp_client_name": _text(client.get("name")),
        "mcp_client_version": _text(client.get("version"), 128),
    }
    if method == "resources/read":
        fields["mcp_resource"] = _text(params.get("uri"))
    if method == "prompts/get":
        fields["mcp_prompt"] = _text(params.get("name"), 128)
    arguments = params.get("arguments") if tool else None
    if isinstance(arguments, dict):
        fields.update({
            "upstream_service": _text(arguments.get("service"), 64),
            "upstream_api_version": _text(arguments.get("api_version"), 32),
            "upstream_operation": _text(arguments.get("operation_id"), 128),
        })
        inputs = arguments.get("parameters") if tool == "call_api_operation" else arguments
        if isinstance(inputs, dict):
            fields.update({
                "translation": _text(inputs.get("translation"), 64),
                "reference": _text(inputs.get("references", inputs.get("reference"))),
                "search": _text(inputs.get("q")),
            })
    return fields


def response_outcome(status: int, observed: JsonObservation, failed: bool) -> str:
    if failed:
        return "transport_error"
    document = observed.document()
    if isinstance(document.get("error"), dict):
        return "protocol_error"
    if status >= 400:
        return "transport_error"
    result = document.get("result")
    if isinstance(result, dict):
        return "tool_error" if result.get("isError") is True else "success"
    if status in {202, 204} and observed.complete and not observed.body:
        return "success"
    # A large or streaming result is not parsed in full just to produce a log.
    # Its HTTP outcome is still recorded; never infer a successful tool result.
    return "unknown"


class MCPRequestTelemetry:
    """Join protocol semantics to the edge request using nginx's request identity."""

    def __init__(self, app: ASGIApp, logger: logging.Logger) -> None:
        self.app = app
        self.logger = logger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        incoming = headers.get("x-request-id", "")
        request_id = incoming if _REQUEST_ID.fullmatch(incoming) else uuid.uuid4().hex
        token = headers.get("x-getbible-token-id", "")
        token_id = token if _TOKEN_ID.fullmatch(token) else ""
        auth = headers.get("x-getbible-auth-state", "")
        auth = auth if auth in {"anonymous", "valid", "rejected"} else "anonymous"
        started = time.perf_counter()
        request_body, response_body = JsonObservation(), JsonObservation()
        status, size, failed = 500, 0, False
        path = scope.get("path", "/")
        metadata: dict[str, str] = {}
        destinations: dict[str, str] = {}
        context_token = _UPSTREAM.set(destinations)

        async def observed_receive() -> Message:
            message = await receive()
            if message["type"] == "http.request":
                request_body.feed(message)
            return message

        async def observed_send(message: Message) -> None:
            nonlocal status, size, metadata
            if message["type"] == "http.response.start":
                status = message["status"]
                metadata = request_metadata(request_body.document())
                if path in {"/healthz", "/readyz"}:
                    metadata["operation"] = "health" if path == "/healthz" else "readiness"
                message = dict(message)
                message["headers"] = list(message.get("headers", []))
                output = MutableHeaders(scope=message)
                output["X-Request-ID"] = request_id
                output["X-GetBible-Telemetry-Endpoint-Kind"] = "mcp"
                output["X-GetBible-Telemetry-Operation"] = quote(metadata["operation"], safe="")
            elif message["type"] == "http.response.body":
                size += len(message.get("body", b""))
                response_body.feed(message)
            await send(message)

        try:
            await self.app(scope, observed_receive, observed_send)
        except BaseException:
            failed = True
            raise
        finally:
            _UPSTREAM.reset(context_token)
            if not metadata:
                metadata = request_metadata(request_body.document())
            if failed or path not in {"/healthz", "/readyz"} or status >= 500:
                client = scope.get("client") or ("", 0)
                address = headers.get("x-forwarded-for", "").split(",")[-1].strip() or client[0]
                outcome = response_outcome(status, response_body, failed)
                extra = {
                    "event": "request", "request_id": request_id,
                    "method": scope["method"], "path": _text(path, 2048),
                    "query": _text(scope.get("query_string", b"").decode("utf-8", "replace"), 2048),
                    "status": status, "duration_ms": round((time.perf_counter() - started) * 1000, 3),
                    "response_bytes": size, "remote_addr": _text(address, 128),
                    "token": token_id, "auth_state": auth, "worker_pid": os.getpid(),
                    "user_agent": _text(headers.get("user-agent", ""), 2048),
                    "endpoint_kind": "mcp", "mcp_outcome": outcome, **metadata, **destinations,
                }
                level = logging.WARNING if outcome.endswith("error") else logging.INFO
                try:
                    self.logger.log(level, "request", extra=extra)
                except Exception as exc:
                    # Spool rotation/storage failure must not replace the protocol
                    # response or an in-flight cancellation with a logging error.
                    try:
                        os.write(2, f"MCP request telemetry unavailable ({type(exc).__name__}).\n".encode())
                    except OSError:
                        pass
