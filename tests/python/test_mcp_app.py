"""Verify the engine's local-origin transport and embedded MCP lifecycle."""

from __future__ import annotations

import os
import unittest
from unittest.mock import patch

import httpx
import httpx2
from getbible_mcp.config import Settings
from getbible_mcp.contracts import ContractRegistry
from getbible_mcp_api.app import LocalOriginTransport, create_app, validate_origin
from mcp import Client
from mcp.client.streamable_http import streamable_http_client


class RecordingTransport(httpx.AsyncBaseTransport):
    def __init__(self, status: int = 200, headers: dict | None = None) -> None:
        self.requests: list[httpx.Request] = []
        self.closed = False
        self.status = status
        self.headers = headers or {}
        self.payload = {
            "chapter": {"verses": [{"verse": 16, "text": "Fixture verse",
                                    "tokens": [{"lemma": {"strong": ["G2316"]}}]}]},
        }

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        await request.aread()
        return httpx.Response(self.status, json=self.payload, headers=self.headers)

    async def aclose(self) -> None:
        self.closed = True


class OriginValidationTest(unittest.TestCase):
    def test_local_and_explicit_private_origins(self) -> None:
        for origin in (
            "http://127.0.0.1:80", "http://localhost:8080", "http://[::1]:8080/",
            "http://192.168.100.10:8080", "https://10.20.30.40", "http://172.16.0.1",
            "http://[fd00::10]:8080", "http://[::ffff:127.0.0.1]",
        ):
            with self.subTest(origin=origin):
                url = validate_origin(origin)
                self.assertIn(url.scheme, {"http", "https"})
                self.assertEqual(url.path, "/")
        self.assertEqual(validate_origin("http://localhost").host, "127.0.0.1")

    def test_public_ambiguous_or_non_origin_urls_are_rejected(self) -> None:
        for origin in (
            "", "https://api.getbible.net", "http://8.8.8.8", "http://0.0.0.0",
            "http://169.254.169.254", "http://[::]", "http://[ff02::1]",
            "http://[::ffff:8.8.8.8]", "http://[fe80::1%25eth0]",
            "http://127.0.0.1/v2", "http://127.0.0.1/?secret=yes",
            "http://127.0.0.1/?", "http://127.0.0.1/#", "http://user:secret@127.0.0.1",
            "ftp://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
            "http://127.0.0.1\n", "http://127.0.0.1:",
        ):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                validate_origin(origin)


class LocalOriginTransportTest(unittest.IsolatedAsyncioTestCase):
    async def test_tls_keeps_public_sni_and_separate_authority_connection_pools(self) -> None:
        created = []

        def make_transport(**kwargs):
            self.assertFalse(kwargs["trust_env"])
            self.assertNotIn("verify", kwargs)
            transport = RecordingTransport()
            created.append(transport)
            return transport

        with patch("getbible_mcp_api.app.httpx.AsyncHTTPTransport", side_effect=make_transport):
            transport = LocalOriginTransport(Settings(), "https://127.0.0.1:443")
        async with httpx.AsyncClient(transport=transport) as client:
            for host in ("api.getbible.net", "query.getbible.net", "api.getbible.net"):
                await client.get(
                    f"https://{host}/v3/fixture.json",
                    extensions={"sni_hostname": "wrong.example.test"},
                )
        active = [item for item in created if item.requests]
        self.assertEqual(len(active), 2)
        self.assertEqual(sorted(len(item.requests) for item in active), [1, 2])
        for pool in active:
            hosts = {request.headers["host"] for request in pool.requests}
            self.assertEqual(len(hosts), 1)
            for request in pool.requests:
                self.assertEqual(request.url.host, "127.0.0.1")
                self.assertEqual(request.url.scheme, "https")
                self.assertEqual(request.extensions["sni_hostname"], request.headers["host"])
        self.assertTrue(all(item.closed for item in created))

    async def test_every_configured_service_routes_locally_and_keeps_public_identity(self) -> None:
        settings = Settings()
        upstream = RecordingTransport()
        transport = LocalOriginTransport(settings, transport=upstream)
        async with httpx.AsyncClient(transport=transport, trust_env=False) as client:
            for contract in ContractRegistry().catalog():
                base = settings.service_base(contract["service"], contract["version"])
                url = base + "/fixture%20id.json?text=one%2Btwo&text=three"
                response = await client.get(url)
                self.assertEqual(str(response.url), url)
                sent = upstream.requests[-1]
                self.assertEqual(sent.url.host, "127.0.0.1")
                self.assertEqual(sent.url.scheme, "http")
                self.assertEqual(sent.headers["host"], httpx.URL(base).netloc.decode("ascii"))
                self.assertEqual(sent.url.raw_path, httpx.URL(url).raw_path)
        self.assertTrue(upstream.closed)

    async def test_unconfigured_destinations_are_rejected_before_network_io(self) -> None:
        upstream = RecordingTransport()
        async with httpx.AsyncClient(
            transport=LocalOriginTransport(Settings(), transport=upstream),
        ) as client:
            for url in (
                "https://example.test/v3", "http://api.getbible.net/v3",
                "https://user:secret@api.getbible.net/v3",
            ):
                with self.subTest(url=url), self.assertRaises(httpx.UnsupportedProtocol):
                    await client.get(url)
        self.assertEqual(upstream.requests, [])

    async def test_post_body_is_preserved_and_credentials_are_not_forwarded(self) -> None:
        upstream = RecordingTransport()
        settings = Settings(search_v3_base="https://search.example.test:8443/v3")
        async with httpx.AsyncClient(
            transport=LocalOriginTransport(settings, "http://[::1]:8080", transport=upstream),
        ) as client:
            body = {"q": "mercy", "match": "all", "limit": 5}
            await client.post(
                settings.search_v3_base, json=body,
                headers={"Authorization": "Bearer fixture", "Cookie": "session=fixture",
                         "Proxy-Authorization": "fixture", "Host": "wrong.example.test",
                         "Forwarded": "for=fixture", "X-Forwarded-Host": "fixture"},
            )
        sent = upstream.requests[0]
        self.assertEqual(sent.url, "http://[::1]:8080/v3")
        self.assertEqual(sent.headers["host"], "search.example.test:8443")
        self.assertEqual(sent.content, httpx.Request("POST", settings.search_v3_base, json=body).content)
        for header in ("authorization", "cookie", "proxy-authorization", "forwarded", "x-forwarded-host"):
            self.assertNotIn(header, sent.headers)


class AppTest(unittest.IsolatedAsyncioTestCase):
    async def test_readiness_tracks_lifespan_without_fetching_any_api(self) -> None:
        upstream = RecordingTransport()
        app = create_app(transport=upstream)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://127.0.0.1",
        ) as client:
            before = await client.get("/readyz")
            self.assertEqual(before.status_code, 503)
            self.assertEqual(before.headers["content-type"], "application/problem+json")
            async with app.router.lifespan_context(app):
                readiness = await client.get("/readyz")
                self.assertEqual(readiness.status_code, 200)
                self.assertEqual(readiness.json()["mcp_endpoint"], "/mcp")
                self.assertEqual(readiness.headers["cache-control"], "no-store")
                health = await client.get("/healthz")
                self.assertEqual(health.status_code, 200)
                self.assertEqual(health.json()["mcp_endpoint"], "/mcp")
                for path in ("/v2", "/v3", "/mcp/"):
                    self.assertEqual((await client.get(path)).status_code, 404)
                self.assertFalse(upstream.closed)
            self.assertEqual((await client.get("/readyz")).status_code, 503)
        self.assertEqual(upstream.requests, [])
        self.assertTrue(upstream.closed)

    async def test_protocol_discovery_and_query_use_library_with_local_origin(self) -> None:
        upstream = RecordingTransport()
        with patch.dict(os.environ, {
            "GETBIBLE_MCP_ORIGIN": "http://127.0.0.1:8080",
            "GETBIBLE_QUERY_V3_BASE": "https://query.example.test/v3",
        }):
            app = create_app(transport=upstream)
        async with (
            app.router.lifespan_context(app),
            httpx2.AsyncClient(
                transport=httpx2.ASGITransport(app), base_url="http://127.0.0.1",
            ) as client,
            Client(
                streamable_http_client(
                    "http://127.0.0.1/mcp", http_client=client, terminate_on_close=False,
                ),
                cache=None,
            ) as session,
        ):
            self.assertTrue((await session.list_tools()).tools)
            self.assertTrue((await session.list_resources()).resources)
            self.assertEqual(upstream.requests, [])
            result = await session.call_tool("query_verses", {
                "translation": "kjv", "references": "John 3:16", "api_version": "v3",
            })
        self.assertFalse(result.is_error, result.content)
        self.assertEqual(result.structured_content["data"], upstream.payload)
        self.assertEqual(result.structured_content["source"]["url"],
                         "https://query.example.test/v3/kjv/John%203%3A16")
        sent = upstream.requests[0]
        self.assertEqual(sent.url.host, "127.0.0.1")
        self.assertEqual(sent.url.port, 8080)
        self.assertEqual(sent.headers["host"], "query.example.test")
        self.assertTrue(upstream.closed)

    async def test_upstream_redirect_remains_a_native_error_without_following_it(self) -> None:
        upstream = RecordingTransport(302, {"location": "https://unconfigured.example.test/secret"})
        app = create_app(transport=upstream)
        async with (
            app.router.lifespan_context(app),
            httpx2.AsyncClient(
                transport=httpx2.ASGITransport(app), base_url="http://127.0.0.1",
            ) as client,
            Client(
                streamable_http_client(
                    "http://127.0.0.1/mcp", http_client=client, terminate_on_close=False,
                ),
                cache=None,
            ) as session,
        ):
            result = await session.call_tool("query_verses", {
                "translation": "kjv", "references": "John 3:16", "api_version": "v3",
            })
        self.assertTrue(result.is_error)
        self.assertEqual(result.structured_content["result"]["source"]["status_code"], 302)
        self.assertEqual(len(upstream.requests), 1)


if __name__ == "__main__":
    unittest.main()
