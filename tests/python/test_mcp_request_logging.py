"""MCP interaction records retain transport and protocol identity without payload archives."""

from __future__ import annotations

import io
import json
import logging
import unittest

import httpx
import httpx2
from getbible_api_common.logging import JsonFormatter
from getbible_mcp_api.app import create_app
from getbible_mcp_api.telemetry import (
    JsonObservation,
    MCPRequestTelemetry,
    response_outcome,
)
from mcp import Client
from mcp.client.streamable_http import streamable_http_client
from mcp.types import Implementation


def recording_logger() -> tuple[logging.Logger, io.StringIO]:
    output = io.StringIO()
    logger = logging.Logger("getbible.mcp", logging.INFO)
    handler = logging.StreamHandler(output)
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)
    return logger, output


class TelemetryTest(unittest.IsolatedAsyncioTestCase):
    async def test_spool_failure_preserves_responses_and_application_exceptions(self) -> None:
        class UnavailableHandler(logging.Handler):
            def emit(self, record):
                raise OSError("Spool unavailable")

        logger = logging.Logger("getbible.mcp", logging.INFO)
        logger.addHandler(UnavailableHandler())
        failure = RuntimeError("Application failed")
        for raises in (False, True):
            sent = []

            async def application(scope, receive, send):
                if raises:
                    raise failure
                await send({"type": "http.response.start", "status": 204, "headers": []})
                await send({"type": "http.response.body", "body": b""})

            async def receive():
                return {"type": "http.request", "body": b""}

            async def send(message):
                sent.append(message)

            observer = MCPRequestTelemetry(application, logger)
            scope = {"type": "http", "method": "POST", "path": "/", "headers": []}
            if raises:
                with self.assertRaises(RuntimeError) as caught:
                    await observer(scope, receive, send)
                self.assertIs(caught.exception, failure)
            else:
                await observer(scope, receive, send)
                self.assertEqual(sent[0]["status"], 204)

    async def test_sdk_requests_log_client_tool_and_semantic_failures(self) -> None:
        logger, output = recording_logger()
        status = 200

        def upstream(request: httpx.Request) -> httpx.Response:
            return httpx.Response(status, json={"chapter": {"verses": []}})

        app = create_app(transport=httpx.MockTransport(upstream), logger=logger)
        async with (
            app.router.lifespan_context(app),
            httpx2.AsyncClient(
                transport=httpx2.ASGITransport(app), base_url="http://127.0.0.1",
                headers={"User-Agent": "ExampleRobot/1.0", "X-Forwarded-For": "192.0.2.8",
                         "X-GetBible-Token-Id": "robot-reader", "X-GetBible-Auth-State": "valid"},
            ) as http,
            Client(streamable_http_client("http://127.0.0.1/", http_client=http,
                                          terminate_on_close=False), cache=None,
                   client_info=Implementation(name="ExampleRobot", version="1.0")) as client,
        ):
            http.headers["X-Request-ID"] = "request-success"
            result = await client.call_tool("query_verses", {"references": "John 3:16"})
            self.assertFalse(result.is_error)
            status = 404
            http.headers["X-Request-ID"] = "request-failure"
            result = await client.call_tool("query_verses", {"references": "John 3:16"})
            self.assertTrue(result.is_error)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        calls = [row for row in rows if row["mcp_method"] == "tools/call"]
        self.assertEqual(len(calls), 2)
        self.assertEqual([row["mcp_outcome"] for row in calls], ["success", "tool_error"])
        self.assertEqual([row["request_id"] for row in calls], ["request-success", "request-failure"])
        for row in calls:
            self.assertEqual(row["status"], 200)
            self.assertEqual(row["endpoint_kind"], "mcp")
            self.assertEqual(row["mcp_tool"], "query_verses")
            self.assertEqual(row["mcp_client_name"], "ExampleRobot")
            self.assertEqual(row["mcp_client_version"], "1.0")
            self.assertEqual(row["remote_addr"], "192.0.2.8")
            self.assertEqual(row["token"], "robot-reader")
            self.assertEqual(row["upstream_service"], "query")
            self.assertEqual(row["upstream_api_version"], "v3")
            self.assertGreater(row["response_bytes"], 0)
            self.assertNotIn("arguments", row)
            self.assertNotIn("body", row)

    async def test_observer_preserves_stream_chunks_and_redacts_metadata(self) -> None:
        logger, output = recording_logger()
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "example", "arguments": {"password": "private-body"},
            "_meta": {"io.modelcontextprotocol/clientInfo": {"name": "Bearer private-client"}},
        }}
        body = json.dumps(request).encode()
        incoming = [
            {"type": "http.request", "body": body[:23], "more_body": True},
            {"type": "http.request", "body": body[23:], "more_body": False},
        ]
        chunks = [b'{"jsonrpc":"2.0","id":1,"result":', b'{"isError":false}}']
        forwarded = []

        async def application(scope, receive, send):
            self.assertIs(await receive(), incoming[0])
            self.assertIs(await receive(), incoming[1])
            await send({"type": "http.response.start", "status": 200, "headers": []})
            for index, chunk in enumerate(chunks):
                await send({"type": "http.response.body", "body": chunk,
                            "more_body": index < len(chunks) - 1})

        iterator = iter(incoming)

        async def receive():
            return next(iterator)

        async def send(message):
            forwarded.append(message)

        await MCPRequestTelemetry(application, logger)(
            {"type": "http", "method": "POST", "path": "/", "query_string": b"",
             "headers": [(b"authorization", b"Bearer private-header"),
                         (b"user-agent", b"Robot Bearer private-agent")], "client": ("192.0.2.1", 80)},
            receive, send,
        )
        self.assertEqual([message["body"] for message in forwarded[1:]], chunks)
        record = json.loads(output.getvalue())
        self.assertEqual(record["mcp_outcome"], "success")
        self.assertEqual(record["mcp_client_name"], "Bearer [REDACTED]")
        self.assertEqual(record["user_agent"], "Robot Bearer [REDACTED]")
        for secret in ("private-body", "private-client", "private-header", "private-agent"):
            self.assertNotIn(secret, output.getvalue())

    async def test_malformed_or_rejected_robot_request_is_still_logged(self) -> None:
        logger, output = recording_logger()
        app = create_app(transport=httpx.MockTransport(lambda _: httpx.Response(200)), logger=logger)
        async with (
            app.router.lifespan_context(app),
            httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="http://127.0.0.1") as client,
        ):
            response = await client.post("/", content=b"not-json", headers={
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                "User-Agent": "UnrecognizedRobot", "X-Request-ID": "bad-request",
            })
        record = json.loads(output.getvalue())
        self.assertGreaterEqual(response.status_code, 400)
        self.assertEqual(record["request_id"], "bad-request")
        self.assertEqual(record["endpoint_kind"], "mcp")
        self.assertEqual(record["user_agent"], "UnrecognizedRobot")
        self.assertIn(record["mcp_outcome"], {"protocol_error", "transport_error"})


class ObservationBoundsTest(unittest.TestCase):
    def test_large_incomplete_or_unparseable_results_do_not_claim_success(self) -> None:
        for chunks in ([b"x" * 65], [b'{"result":', b'{"isError":true}}'], [b"invalid-json"]):
            with self.subTest(chunks=chunks):
                observed = JsonObservation(limit=32)
                for chunk in chunks:
                    observed.feed({"body": chunk, "more_body": len(chunks) > 1})
                self.assertEqual(response_outcome(200, observed, False), "unknown")
                self.assertLessEqual(len(observed.body), 32)
        observed = JsonObservation()
        observed.feed({"body": b'{"error":{"code":-32602}}'})
        self.assertEqual(response_outcome(200, observed, False), "protocol_error")
        self.assertEqual(response_outcome(200, observed, True), "transport_error")


if __name__ == "__main__":
    unittest.main()
