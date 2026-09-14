"""Host the MCP library over Streamable HTTP using only the engine's local APIs.

The library owns the protocol, tools, schemas, API behavior and cache advice.
This host supplies an HTTP transport that reaches nginx directly while retaining
the configured public URL and virtual-host identity for every API result.
"""

from __future__ import annotations

import ipaddress
import logging
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import httpx
from getbible_api_common.logging import configure_logging
from getbible_mcp import create_app as create_mcp_app
from getbible_mcp.client import GetBibleClient
from getbible_mcp.config import Settings
from getbible_mcp.contracts import ContractRegistry
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .telemetry import MCPRequestTelemetry, record_upstream

DEFAULT_ORIGIN = "http://127.0.0.1:80"
PRIVATE_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("fc00::/7"),
)


def validate_origin(value: str) -> httpx.URL:
    """Accept an explicit local HTTP origin without paths, credentials or DNS discovery."""
    message = (
        "GETBIBLE_MCP_ORIGIN must be an HTTP(S) loopback or private IP origin "
        "without a path, credentials, query or fragment"
    )
    if not value or any(character.isspace() for character in value):
        raise ValueError(message)
    try:
        parsed = urlsplit(value)
        port = parsed.port
        hostname = parsed.hostname
        if (
            parsed.scheme not in {"http", "https"}
            or not hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.netloc.endswith(":")
            or "?" in value
            or "#" in value
            or port == 0
        ):
            raise ValueError(message)
        if hostname == "localhost":
            # Avoid even a local DNS lookup: this setting explicitly means this host.
            hostname = "127.0.0.1"
        address = ipaddress.ip_address(hostname)
        if getattr(address, "scope_id", None) is not None:
            raise ValueError(message)
        mapped_address = getattr(address, "ipv4_mapped", None)
        if mapped_address is not None:
            address = mapped_address
        if not address.is_loopback and not any(address in network for network in PRIVATE_NETWORKS):
            raise ValueError(message)
        return httpx.URL(scheme=parsed.scheme, host=str(address), port=port)
    except (ValueError, httpx.InvalidURL) as exc:
        raise ValueError(message) from exc


class LocalOriginTransport(httpx.AsyncBaseTransport):
    """Route configured upstreams to one local origin; never forward client credentials."""

    def __init__(
        self,
        settings: Settings,
        origin: str = DEFAULT_ORIGIN,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.origin = validate_origin(origin)
        self._allowed = {
            (url.scheme, url.host, url.port)
            for contract in ContractRegistry().catalog()
            for url in [httpx.URL(settings.service_base(contract["service"], contract["version"]))]
        }
        self._service_roots = [
            (httpx.URL(settings.service_base(entry["service"], entry["version"])),
             entry["service"], entry["version"])
            for entry in ContractRegistry().catalog()
        ]
        if transport is not None:
            self._transports = dict.fromkeys(self._allowed, transport)
        elif self.origin.scheme == "https":
            # TLS connections must never be reused for another public authority:
            # each pool verifies the certificate for that authority's SNI name.
            self._transports = {
                authority: httpx.AsyncHTTPTransport(trust_env=False)
                for authority in self._allowed
            }
        else:
            self._transports = dict.fromkeys(
                self._allowed, httpx.AsyncHTTPTransport(trust_env=False),
            )

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        authority = (request.url.scheme, request.url.host, request.url.port)
        if request.url.userinfo or authority not in self._allowed:
            raise httpx.UnsupportedProtocol(
                "MCP may only request configured GetBible services", request=request,
            )
        for base, service, version in self._service_roots:
            if (base.scheme, base.host, base.port) == authority and (
                request.url.path == base.path or request.url.path.startswith(base.path.rstrip("/") + "/")
            ):
                record_upstream(service, version)
                break
        headers = request.headers.copy()
        for name in ("authorization", "proxy-authorization", "cookie", "forwarded"):
            headers.pop(name, None)
        for name in list(headers):
            if name.startswith("x-forwarded-"):
                headers.pop(name, None)
        headers["host"] = request.url.netloc.decode("ascii")
        extensions = request.extensions.copy()
        extensions.pop("sni_hostname", None)
        if self.origin.scheme == "https":
            extensions["sni_hostname"] = request.url.host
        forwarded = httpx.Request(
            method=request.method,
            url=request.url.copy_with(
                scheme=self.origin.scheme, host=self.origin.host, port=self.origin.port,
            ),
            headers=headers,
            stream=request.stream,
            extensions=extensions,
        )
        # The outer AsyncClient associates the response with the original request,
        # so library source URLs stay public. Redirects are never followed by it.
        return await self._transports[authority].handle_async_request(forwarded)

    async def aclose(self) -> None:
        for transport in set(self._transports.values()):
            await transport.aclose()


def create_app(
    settings: Settings | None = None,
    *,
    origin: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    logger: logging.Logger | None = None,
) -> Starlette:
    """Serve MCP at the domain root; construction and readiness perform no network I/O.

    Production: ``gunicorn 'getbible_mcp_api.app:create_app()' -k
    uvicorn_worker.UvicornWorker``. The injected transport is for host tests;
    callers still pass through origin validation and virtual-host routing.
    """
    resolved_settings = settings if settings is not None else Settings.from_env()
    resolved_origin = origin if origin is not None else os.getenv(
        "GETBIBLE_MCP_ORIGIN", DEFAULT_ORIGIN,
    )
    local_transport = LocalOriginTransport(
        resolved_settings, resolved_origin, transport=transport,
    )
    http_client = httpx.AsyncClient(
        transport=local_transport,
        timeout=httpx.Timeout(resolved_settings.request_timeout_seconds),
        follow_redirects=False,
        trust_env=False,
        headers={"User-Agent": resolved_settings.user_agent},
    )
    api_client = GetBibleClient(settings=resolved_settings, http_client=http_client)
    app = create_mcp_app(settings=resolved_settings, api_client=api_client, path="/")
    app.state.ready = False
    library_lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(application: Starlette) -> AsyncIterator[None]:
        # An injected HTTP client belongs to its host. The library retains full
        # ownership of its own protocol manager and API-client lifecycle.
        async with http_client, library_lifespan(application):
            try:
                application.state.ready = True
                yield
            finally:
                application.state.ready = False

    async def readiness(request: Request) -> JSONResponse:
        if not request.app.state.ready:
            return JSONResponse(
                {"type": "about:blank", "title": "Service Unavailable", "status": 503,
                 "detail": "The MCP application has not completed startup."},
                status_code=503,
                media_type="application/problem+json",
                headers={"Cache-Control": "no-store"},
            )
        return JSONResponse(
            {"status": "ok", "mcp_endpoint": "/"},
            headers={"Cache-Control": "no-store"},
        )

    app.router.lifespan_context = lifespan
    app.routes.append(Route("/readyz", readiness, methods=["GET"], name="readiness"))
    app.add_middleware(
        MCPRequestTelemetry,
        logger=logger if logger is not None else configure_logging(
            "getbible.mcp", os.getenv("GETBIBLE_LOG_LEVEL", "INFO"),
            os.getenv("GETBIBLE_LOG_FILE", ""),
        ),
    )
    return app
