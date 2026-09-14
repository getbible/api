"""Exercise the real private Unix HTTP boundary without external services."""

from http.client import HTTPConnection, HTTPResponse
from dataclasses import replace
import io
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/dashboard"))
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_dashboard.auth import AuthStore
from getbible_dashboard.config import Config
from getbible_dashboard.lifecycle import ReportingUnavailable, ViewerLifecycle
from getbible_dashboard.server import Dashboard, DashboardHTTPServer, DashboardHandler
from tests.python.test_dashboard_auth import Clock, FakeTelegram
from getbible_telemetry.store import TelemetrySchemaError


class UnixConnection(HTTPConnection):
    def __init__(self, path):
        super().__init__("admin.example.test", timeout=5)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(self.path)


class MemorySocket:
    """Exercise BaseHTTPRequestHandler's real parser without a network grant."""

    def __init__(self, request):
        self.input = io.BytesIO(request)
        self.output = io.BytesIO()

    def settimeout(self, timeout):
        pass

    def makefile(self, mode, buffering=-1):
        return self.input

    def sendall(self, data):
        self.output.write(data)


class FakeAnalytics:
    def __init__(self):
        self.calls = []

    def initialize(self):
        self.calls.append("initialize")

    def report(self, name, query):
        self.calls.append((name, query))
        return {"calls": 42, "origin_only": True}


class FakeBroker:
    def __init__(self):
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        if method == "state":
            return {"refresh": {"state": "waiting", "pending": True, "attempts": 0,
                                "requested_at": 1, "next_retry_at": None, "last_error": None},
                    "pending_jobs": 1, "accepting_jobs": False}
        if method == "submit":
            return {"job_id": "job-123", "status": "queued"}
        if method == "job":
            return {"job_id": params["job_id"], "status": "completed"}
        return {method: []}


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "index.html").write_text("<!doctype html><title>Dashboard</title>")
        self.clock = Clock()
        self.auth = AuthStore(self.root / "state", clock=self.clock)
        self.auth.set_password("A sufficiently long password")
        self.telegram = FakeTelegram()
        self.analytics = FakeAnalytics()
        self.broker = FakeBroker()
        self.config = Config(domain="admin.example.test", enabled=True,
                             static_dir=str(self.root), socket_path=str(self.root / "http.sock"))
        self.app = Dashboard(self.config, auth=self.auth, telegram=self.telegram,
                             analytics=self.analytics, broker=self.broker)
        self.server = SimpleNamespace(app=self.app)
        self.addCleanup(self.close)
        self.cookie = ""
        self.csrf = ""

    def close(self):
        self.app.close()

    def request(self, method, path, body=None, headers=None):
        supplied = {"Host": self.config.domain, "X-GetBible-Client-IP": "192.0.2.4", "Connection": "close"}
        if method == "POST":
            supplied.update({"Origin": self.config.origin, "Content-Type": "application/json"})
        if self.cookie:
            supplied["Cookie"] = self.cookie
        if self.csrf:
            supplied["X-CSRF-Token"] = self.csrf
        supplied.update(headers or {})
        supplied = {key: value for key, value in supplied.items() if value is not None}
        encoded = json.dumps(body or {}).encode() if method == "POST" else b""
        if method == "POST":
            supplied["Content-Length"] = str(len(encoded))
        request = (f"{method} {path} HTTP/1.1\r\n" + "\r\n".join(f"{key}: {value}" for key, value in supplied.items()) + "\r\n\r\n").encode() + encoded
        transport = MemorySocket(request)
        DashboardHandler(transport, "", self.server)
        response = HTTPResponse(MemorySocket(transport.output.getvalue()))
        response.begin()
        data = response.read()
        result = (response.status, dict(response.getheaders()), json.loads(data) if response.getheader("Content-Type", "").endswith("json") else data)
        return result

    def login(self):
        status, _, challenge = self.request("POST", "/api/auth/password", {"password": "A sufficiently long password"})
        self.assertEqual(status, 200)
        status, headers, result = self.request("POST", "/api/auth/token", {
            "challenge_id": challenge["challenge_id"], "token": self.telegram.codes[-1][0],
        })
        self.assertEqual(status, 200)
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.csrf = result["csrf_token"]
        return headers, result

    def heartbeat(self):
        result = self.request("POST", "/api/dashboard/heartbeat", {"viewer_id": "viewer-123"})
        self.assertEqual(result[0], 200)
        return result

    def test_full_login_cookie_and_returning_browser_status(self):
        self.assertFalse(self.request("GET", "/api/auth/status")[2]["authenticated"])
        headers, result = self.login()
        for attribute in ("Secure", "HttpOnly", "SameSite=Strict", "Max-Age=2592000", "Path=/"):
            self.assertIn(attribute, headers["Set-Cookie"])
        self.assertNotIn("token", result)
        status, headers, data = self.request("GET", "/api/auth/status")
        self.assertEqual(status, 200)
        self.assertTrue(data["authenticated"])
        self.assertEqual(data["csrf_token"], self.csrf)
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_health_reports_the_running_release_without_opening_telemetry(self):
        release_file = self.root / "release.json"
        original = {"version": "1.2.3", "revision": "a" * 40, "fingerprint": "b" * 64}
        release_file.write_text(json.dumps(original))
        config = replace(self.config, release_file=str(release_file))
        self.app.close()
        self.app = Dashboard(config, auth=self.auth, telegram=self.telegram,
                             analytics=self.analytics, broker=self.broker)
        self.server.app = self.app
        status, headers, data = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(data["release"], original)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.analytics.calls, [])
        release_file.write_text(json.dumps({**original, "version": "1.2.4"}))
        self.app.reconfigure(config)
        self.assertEqual(self.request("GET", "/health")[2]["release"], original)
        self.assertEqual(self.request("POST", "/health")[0], 405)

    def test_private_reports_and_actions_require_authentication(self):
        for path in ("/api/overview", "/api/history", "/api/requests", "/api/events", "/api/endpoints", "/api/mcp",
                     "/api/management/state", "/api/translations", "/api/storage", "/api/sessions", "/api/jobs", "/api/operations"):
            status, headers, data = self.request("GET", path)
            self.assertEqual(status, 401, path)
            self.assertEqual(headers["Content-Type"], "application/problem+json")
        self.assertEqual(self.request("POST", "/api/actions", {"operation": "status"})[0], 401)
        self.assertEqual(self.broker.calls, [])
        self.assertEqual(self.analytics.calls, [])

    def test_management_refresh_state_is_authenticated_and_available_during_drain(self):
        self.login()
        status, headers, data = self.request("GET", "/api/management/state")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(data["refresh"]["state"], "waiting")
        self.assertFalse(data["accepting_jobs"])
        self.assertEqual(self.broker.calls[-1][0], "state")
        self.assertIn("session_id", self.broker.calls[-1][1]["actor"])

    def test_refresh_pause_is_a_retryable_problem_response(self):
        from getbible_dashboard.broker import BrokerError
        self.login()
        with patch.object(self.broker, "call", side_effect=BrokerError("Management is refreshing", "management_refresh_pending")):
            status, headers, data = self.request("POST", "/api/actions", {"operation": "domain.status", "arguments": {"domain": "api.example.test"}})
        self.assertEqual(status, 503)
        self.assertEqual(headers["Content-Type"], "application/problem+json")
        self.assertEqual(data["code"], "management_refresh_pending")

    def test_cross_origin_password_does_not_send_telegram(self):
        for origin in ("https://evil.test", "null", None):
            self.assertEqual(self.request("POST", "/api/auth/password", {"password": "A sufficiently long password"},
                                          {"Origin": origin})[0], 403)
        self.assertEqual(self.telegram.codes, [])

    def test_mutation_requires_csrf_origin_and_json(self):
        self.login()
        for headers, expected in (({"X-CSRF-Token": "wrong"}, 403),
                                  ({"Origin": "https://evil.test"}, 403),
                                  ({"Content-Type": "text/plain"}, 415)):
            self.assertEqual(self.request("POST", "/api/actions", {"operation": "status"}, headers)[0], expected)
        self.assertEqual(self.broker.calls, [])

    def test_forwarded_headers_do_not_override_verified_address(self):
        status, _, _ = self.request("POST", "/api/auth/password", {"password": "A sufficiently long password"}, {
            "X-Forwarded-For": "198.51.100.99", "CF-Connecting-IP": "198.51.100.99",
        })
        self.assertEqual(status, 200)
        self.assertEqual(self.telegram.codes[-1][1], "192.0.2.4")
        for ip in ("198.51.100.1, 192.0.2.4", "not-an-ip", None):
            self.assertEqual(self.request("GET", "/api/auth/status", headers={"X-GetBible-Client-IP": ip})[0], 400)

    def test_wrong_host_and_cross_site_fetch_are_rejected(self):
        self.assertEqual(self.request("GET", "/", headers={"Host": "evil.test"})[0], 400)
        self.assertEqual(self.request("POST", "/api/auth/password", {"password": "A sufficiently long password"},
                                      {"Sec-Fetch-Site": "cross-site"})[0], 403)

    def test_reports_need_viewer_lease(self):
        self.login()
        self.assertEqual(self.request("GET", "/api/overview")[0], 409)
        self.assertEqual(self.request("GET", "/api/mcp")[0], 409)
        self.heartbeat()
        status, _, data = self.request("GET", "/api/overview?start=100&end=200")
        self.assertEqual(status, 200)
        self.assertEqual(data["calls"], 42)
        self.assertIn(("overview", {"start": "100", "end": "200"}), self.analytics.calls)
        status, _, data = self.request("GET", "/api/mcp?start=100&end=200&mcp_tool=query_verses")
        self.assertEqual(status, 200)
        self.assertEqual(data["calls"], 42)
        self.assertIn(("mcp", {"start": "100", "end": "200", "mcp_tool": "query_verses"}), self.analytics.calls)

    def test_admin_job_arguments_are_typed_and_actor_is_not_spoofable(self):
        self.login()
        status, _, job = self.request("POST", "/api/actions", {
            "operation": "runtime.cache.warm", "arguments": {"translation": "kjv"}, "confirm": True,
            "actor": {"session_id": "spoofed", "ip": "198.51.100.3"},
        })
        self.assertEqual(status, 202)
        self.assertEqual(job["job_id"], "job-123")
        method, params = self.broker.calls[-1]
        self.assertEqual(method, "submit")
        self.assertEqual(params["arguments"], {"translation": "kjv"})
        self.assertTrue(params["confirm"])
        self.assertEqual(params["actor"]["ip"], "192.0.2.4")
        self.assertNotEqual(params["actor"]["session_id"], "spoofed")
        self.assertEqual(self.request("POST", "/api/actions", {"operation": "sh; rm -rf /"})[0], 400)

    def test_larger_administrative_uploads_require_authentication_first(self):
        body = {"operation": "pages.write", "arguments": {"content": "x" * 130000}}
        self.assertEqual(self.request("POST", "/api/actions", body)[0], 401)
        self.assertEqual(self.broker.calls, [])
        self.login()
        self.assertEqual(self.request("POST", "/api/actions", body)[0], 202)
        self.assertEqual(len(self.broker.calls[-1][1]["arguments"]["content"]), 130000)
        body["arguments"]["content"] = "x" * (2 * 1024 * 1024)
        self.assertEqual(self.request("POST", "/api/actions", body)[0], 413)

    def test_session_revoked_during_upload_cannot_submit_an_operation(self):
        self.login()
        original = DashboardHandler._body

        def read_and_revoke(handler, *args, **kwargs):
            result = original(handler, *args, **kwargs)
            self.auth.revoke("all")
            return result

        with patch.object(DashboardHandler, "_body", read_and_revoke):
            self.assertEqual(self.request("POST", "/api/actions", {
                "operation": "pages.write", "arguments": {"content": "x" * 130000},
            })[0], 401)
        self.assertEqual(self.broker.calls, [])

    def test_secret_job_output_requires_explicit_post(self):
        self.login()
        self.heartbeat()
        self.assertEqual(self.request("GET", "/api/jobs/job-123?consume_secret=true")[0], 200)
        self.assertNotIn("consume_secret", self.broker.calls[-1][1])
        self.assertEqual(self.request("POST", "/api/jobs/job-123/reveal")[0], 200)
        self.assertTrue(self.broker.calls[-1][1]["consume_secret"])

    def test_session_revocation_and_logout_immediately_remove_access(self):
        _, result = self.login()
        status, headers, _ = self.request("POST", f"/api/sessions/{result['session_id']}/revoke")
        self.assertEqual(status, 200)
        self.assertIn("Max-Age=0", headers["Set-Cookie"])
        self.assertEqual(self.request("GET", "/api/sessions")[0], 401)
        self.cookie = self.csrf = ""
        self.login()
        self.assertEqual(self.request("POST", "/api/auth/logout")[0], 200)
        self.assertEqual(self.request("GET", "/api/sessions")[0], 401)

    def test_bans_apply_to_static_shell_and_valid_sessions(self):
        self.login()
        self.assertEqual(self.request("POST", "/api/auth/token", {"challenge_id": "missing", "token": "wrong"})[0], 403)
        self.assertEqual(self.request("GET", "/")[0], 403)
        self.assertEqual(self.request("GET", "/api/sessions")[0], 403)

    def test_static_assets_have_security_headers_and_no_traversal(self):
        status, headers, _ = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        for path in ("/../state/auth.sqlite3", "/%2e%2e/state/auth.sqlite3", "/.hidden"):
            self.assertEqual(self.request("GET", path)[0], 404)

    def test_request_size_and_unsupported_method_return_problem_documents(self):
        status, headers, _ = self.request("POST", "/api/auth/password", {"password": "x" * 17000})
        self.assertEqual(status, 413)
        self.assertEqual(headers["Content-Type"], "application/problem+json")
        status, headers, _ = self.request("PUT", "/api/auth/password")
        self.assertEqual(status, 405)
        self.assertEqual(headers["Content-Type"], "application/problem+json")

    def test_real_unix_transport(self):
        try:
            server = DashboardHTTPServer(self.config.socket_path, self.app)
        except PermissionError:
            self.skipTest("This execution environment denies Unix sockets; run on disposable Ubuntu/CI")
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        try:
            connection = UnixConnection(self.config.socket_path)
            connection.request("GET", "/api/auth/status", headers={"X-GetBible-Client-IP": "192.0.2.4"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertFalse(json.loads(response.read())["authenticated"])
            connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.initialized = threading.Event()
        self.notices = []
        self.lifecycle = ViewerLifecycle(clock=self.clock, initialize=self.initialized.set,
                                         on_sleep=lambda: self.notices.append("sleeping"))
        self.addCleanup(self.lifecycle.close)

    def test_reporting_only_runs_for_authenticated_viewer_leases(self):
        self.assertEqual(self.lifecycle.state()["state"], "sleeping")
        with self.assertRaises(ReportingUnavailable):
            self.lifecycle.report("session", lambda: None)
        self.lifecycle.heartbeat("session", "page1")
        self.assertTrue(self.initialized.wait(1))
        self.assertEqual(self.lifecycle.report("session", lambda: 42), 42)

    def test_multitab_heartbeat_keeps_reports_awake_until_last_page_expires(self):
        self.lifecycle.heartbeat("session", "page1")
        self.lifecycle.heartbeat("session", "page2")
        self.clock.value += 45
        self.lifecycle.heartbeat("session", "page2")
        self.clock.value += 20
        self.lifecycle.tick({"session"})
        self.assertEqual(self.lifecycle.state()["viewers"], 1)
        self.assertEqual(self.notices, [])
        self.clock.value += 40
        self.lifecycle.tick({"session"})
        self.assertEqual(self.lifecycle.state()["state"], "sleeping")
        self.assertEqual(self.notices, ["sleeping"])
        self.lifecycle.tick({"session"})
        self.assertEqual(self.notices, ["sleeping"])

    def test_sleep_does_not_need_new_authentication_to_wake(self):
        self.lifecycle.heartbeat("remembered-session", "page1")
        self.clock.value += 61
        self.lifecycle.tick({"remembered-session"})
        self.lifecycle.heartbeat("remembered-session", "new-page")
        self.assertEqual(self.lifecycle.report("remembered-session", lambda: "awake"), "awake")

    def test_revoked_session_loses_report_access(self):
        self.lifecycle.heartbeat("session", "page1")
        self.lifecycle.tick(set())
        with self.assertRaises(ReportingUnavailable):
            self.lifecycle.report("session", lambda: None)

    def test_failed_initialization_retries_for_existing_viewers_and_recovers(self):
        attempts = []

        def initialize():
            attempts.append(True)
            if len(attempts) == 1:
                raise PermissionError("private details must not enter the dashboard or journal")

        self.lifecycle.initialize = initialize
        with self.assertLogs("getbible_dashboard.lifecycle", level="ERROR") as logs:
            self.lifecycle.heartbeat("session", "page1")
            self.lifecycle._initialization.result(timeout=1)
        self.assertEqual(self.lifecycle.state()["state"], "unavailable")
        self.assertIn("permissions", self.lifecycle.state()["error"])
        self.assertNotIn("private details", " ".join(logs.output))
        self.lifecycle.heartbeat("session", "page1")
        self.assertEqual(len(attempts), 1)
        self.clock.value += 16
        self.lifecycle.heartbeat("session", "page1")
        self.lifecycle._initialization.result(timeout=1)
        self.assertEqual(self.lifecycle.state()["state"], "awake")
        self.assertIsNone(self.lifecycle.state()["error"])
        self.assertEqual(self.lifecycle.report("session", lambda: 42), 42)

    def test_schema_failure_explains_preserved_history(self):
        from getbible_dashboard.lifecycle import storage_error
        message = storage_error(TelemetrySchemaError(1))
        self.assertIn("schema 1", message)
        self.assertIn("preserved", message)
        self.assertIn("database migrations", message)


if __name__ == "__main__":
    unittest.main()
