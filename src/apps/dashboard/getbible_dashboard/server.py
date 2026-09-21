"""Private HTTP over a permissioned Unix socket behind the managed nginx vhost."""

from concurrent.futures import CancelledError
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, HTTPServer
import hmac
import json
import mimetypes
from pathlib import Path
import re
import socket
import sqlite3
from socketserver import ThreadingMixIn
import threading
from urllib.parse import parse_qs, unquote, urlsplit

from .analytics import Analytics, ReportPreparing
from .auth import AuthError, AuthStore, canonical_ip, csrf_token
from .broker import BrokerClient, BrokerError
from .lifecycle import ReportingUnavailable, ViewerLifecycle
from .telegram import DeliveryError, Telegram


COOKIE_NAME = "getbible_dashboard"


class Dashboard:
    def __init__(self, config, *, auth=None, telegram=None, broker=None, analytics=None,
                 lifecycle=None, audit=None):
        self.config = config
        self.audit = audit or (lambda event, **fields: None)
        self.auth = auth or AuthStore(config.state_dir, session_seconds=config.session_seconds,
                                     token_seconds=config.token_seconds, audit=self.audit)
        self.telegram = telegram or Telegram(config.telegram_conf)
        self.broker = broker or BrokerClient(config.broker_socket)
        self.analytics = analytics or Analytics(config.telemetry_db)
        # Capture what this process loaded; HUP must never claim new code is live.
        try:
            release = json.loads(Path(config.release_file).read_text(encoding="utf-8"))
            self.release = {key: release[key] for key in ("version", "revision", "fingerprint")
                            if isinstance(release.get(key), str)} if isinstance(release, dict) else {}
        except (OSError, ValueError):
            self.release = {}
        self.lifecycle = lifecycle or ViewerLifecycle(
            idle_seconds=config.idle_seconds, initialize=self.analytics.initialize,
            on_sleep=self._sleep_notice,
        )
        self._stop = threading.Event()
        self._watcher = None

    def _sleep_notice(self):
        if hasattr(self.analytics, "clear"):
            self.analytics.clear()
        self.audit("dashboard.sleeping")
        try:
            self.telegram.send("getBible dashboard sleeping", "All dashboard pages are inactive. Reporting has stopped; API telemetry continues.")
        except DeliveryError:
            self.audit("dashboard.sleep_notification_failed")

    def start(self):
        self._watcher = threading.Thread(target=self._watch, name="dashboard-activation", daemon=True)
        self._watcher.start()

    def _watch(self):
        while not self._stop.wait(1):
            try:
                self.auth.expire_challenges()
                self.lifecycle.tick({session["id"] for session in self.auth.sessions()})
            except Exception:
                # Keep authorization alive; never include exception messages that
                # may contain credentials or private operation arguments.
                self.audit("dashboard.activation_error")

    def close(self):
        self._stop.set()
        if self._watcher:
            self._watcher.join(timeout=15)
        self.lifecycle.close()

    def reconfigure(self, config):
        if (config.state_dir, config.socket_path) != (self.config.state_dir, self.config.socket_path):
            raise ValueError("Changing dashboard state or socket paths requires a service restart")
        self.config = config
        self.auth.session_seconds = config.session_seconds
        self.auth.token_seconds = config.token_seconds
        self.lifecycle.idle_seconds = config.idle_seconds
        self.telegram = Telegram(config.telegram_conf)
        self.broker = BrokerClient(config.broker_socket)
        self.analytics = Analytics(config.telemetry_db)
        self.lifecycle.initialize = self.analytics.initialize
        self.audit("dashboard.configuration_reloaded")


class DashboardHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "getBible"
    sys_version = ""

    def log_message(self, format, *args):
        # The common telemetry path owns request records; never log cookies,
        # request bodies, query strings or authentication secrets here.
        return

    def send_error(self, code, message=None, explain=None):
        self.close_connection = True
        self._problem(code, "invalid_http_request", "The HTTP request is not supported")

    @property
    def app(self):
        return self.server.app

    def setup(self):
        self.request.settimeout(10)
        super().setup()

    def _headers(self, status, content_type, length, *, cookie=None, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if cookie is not None:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def _json(self, status, data, *, cookie=None, problem=False):
        encoded = json.dumps(data, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()
        self._headers(status, "application/problem+json" if problem else "application/json", len(encoded), cookie=cookie)
        if self.command != "HEAD":
            self.wfile.write(encoded)

    def _problem(self, status, code, detail):
        self._json(status, {"type": "about:blank", "title": {
            400: "Invalid request", 401: "Authentication required", 403: "Access denied",
            404: "Not found", 405: "Method not allowed", 409: "Request conflict",
            413: "Request too large", 415: "Unsupported media type", 429: "Too many requests",
            500: "Server error", 503: "Service unavailable",
        }.get(status, "Request failed"), "status": status, "detail": detail, "code": code}, problem=True)

    def _client(self):
        # Only nginx may connect to this service's permissioned Unix socket. It
        # must overwrite this header after its own trusted-proxy real-IP handling.
        values = self.headers.get_all("X-GetBible-Client-IP", [])
        if len(values) != 1 or "," in values[0]:
            raise AuthError("invalid_client", "A verified client address is required", 400)
        return canonical_ip(values[0])

    def _check_host(self):
        hosts = self.headers.get_all("Host", [])
        if len(hosts) != 1 or hosts[0].lower() not in {self.app.config.domain, self.app.config.domain + ":443"}:
            raise AuthError("invalid_host", "The dashboard hostname is invalid", 400)

    def _check_origin(self):
        origins = self.headers.get_all("Origin", [])
        if len(origins) != 1 or origins[0] != self.app.config.origin:
            raise AuthError("invalid_origin", "Use the configured HTTPS dashboard origin", 403)
        if self.headers.get("Sec-Fetch-Site") not in (None, "same-origin"):
            raise AuthError("invalid_origin", "Cross-site requests are not permitted", 403)

    def _token(self):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
            return cookie[COOKIE_NAME].value if COOKIE_NAME in cookie else ""
        except Exception:
            return ""

    def _session(self, ip):
        token = self._token()
        session = self.app.auth.session(token, ip)
        if self.command == "POST":
            supplied = self.headers.get("X-CSRF-Token", "")
            if not hmac.compare_digest(supplied, csrf_token(token)):
                raise AuthError("invalid_csrf", "Refresh the dashboard before retrying this action", 403)
        return session

    def _body(self, maximum=None):
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") is not None or len(lengths) != 1:
            raise AuthError("invalid_body", "A single Content-Length is required", 400)
        try:
            length = int(lengths[0])
        except ValueError:
            raise AuthError("invalid_body", "Invalid Content-Length", 400) from None
        if length < 0 or length > (maximum or self.app.config.max_body_bytes):
            raise AuthError("body_too_large", "The request is too large", 413)
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise AuthError("invalid_content_type", "Send application/json", 415)
        try:
            body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeError):
            raise AuthError("invalid_json", "The request is not valid JSON", 400) from None
        if not isinstance(body, dict):
            raise AuthError("invalid_json", "The request must be a JSON object", 400)
        return body

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_OPTIONS(self):
        self._problem(405, "method_not_allowed", "Cross-origin access is not supported")

    def do_DELETE(self):
        self._problem(405, "method_not_allowed", "Use the documented POST action")

    do_PUT = do_DELETE
    do_PATCH = do_DELETE

    def _dispatch(self):
        try:
            self._check_host()
            ip = self._client()
            self.app.auth.check_ip(ip)
            if not self.app.config.enabled:
                raise AuthError("dashboard_disabled", "The dashboard is disabled", 404)
            parsed = urlsplit(self.path)
            if parsed.scheme or parsed.netloc or len(self.path) > 8192:
                raise AuthError("invalid_path", "The request path is invalid", 400)
            path = parsed.path
            if path == "/health":
                if self.command not in {"GET", "HEAD"}:
                    raise AuthError("method_not_allowed", "Use GET to check dashboard health", 405)
                return self._json(200, {"status": "ok", "service": "dashboard", "release": self.app.release})
            if not path.startswith("/api/"):
                if self.command not in {"GET", "HEAD"}:
                    raise AuthError("method_not_allowed", "Use GET to open the dashboard", 405)
                return self._static(path)
            if not self.app.telegram.configured:
                if path == "/api/auth/status" and self.command in {"GET", "HEAD"}:
                    return self._json(200, {"authenticated": False, "telegram_configured": False})
                raise AuthError("telegram_unavailable", "Telegram must be configured to access the dashboard", 503)
            if self.command == "POST":
                self._check_origin()
                if path == "/api/actions":
                    # Icon and documentation uploads are accepted only after
                    # checking authentication and CSRF. Check the session again
                    # after reading the body, so revocation during an upload is
                    # honored before submitting any administrative operation.
                    self._session(ip)
                    body = self._body(maximum=2 * 1024 * 1024)
                else:
                    body = self._body()
            else:
                body = {}
            query_values = parse_qs(parsed.query, keep_blank_values=True, max_num_fields=32)
            if any(len(value) != 1 for value in query_values.values()):
                raise ValueError("Each query parameter may appear only once")
            query = {key: value[0] for key, value in query_values.items()}
            if path == "/api/auth/status" and self.command in {"GET", "HEAD"}:
                try:
                    session = self.app.auth.session(self._token(), ip)
                except AuthError as exc:
                    if exc.status != 401:
                        raise
                    return self._json(200, {"authenticated": False, "telegram_configured": True})
                return self._json(200, {"authenticated": True, "telegram_configured": True,
                                        "session": session, "csrf_token": csrf_token(self._token()),
                                        "dashboard": self.app.lifecycle.state()})
            if path == "/api/auth/password" and self.command == "POST":
                return self._json(200, self.app.auth.start_challenge(ip, body.get("password"), self.app.telegram))
            if path == "/api/auth/token" and self.command == "POST":
                challenge_id = body.get("challenge_id", "")
                if not isinstance(challenge_id, str) or len(challenge_id) > 128:
                    raise ValueError("Invalid challenge identifier")
                result = self.app.auth.finish_challenge(ip, challenge_id, body.get("token"),
                                                        self.headers.get("User-Agent", ""))
                token = result.pop("token")
                cookie = self._cookie(token, result.pop("max_age"))
                return self._json(200, {"authenticated": True, **result}, cookie=cookie)
            session = self._session(ip)
            if self.command == "POST":
                return self._post(path, body, session, ip)
            return self._get(path, query, session)
        except AuthError as exc:
            self.close_connection = True
            self._problem(exc.status, exc.code, str(exc))
        except (ValueError, TypeError) as exc:
            self.close_connection = True
            self._problem(400, "invalid_request", str(exc)[:256])
        except BrokerError as exc:
            self._problem(503 if exc.code in {"broker_unavailable", "management_refresh_pending"} else 400, exc.code, str(exc)[:256])
        except (ReportingUnavailable, CancelledError) as exc:
            self._problem(409, "reporting_unavailable", str(exc) or "Reporting is sleeping; reconnect the dashboard")
        except ReportPreparing as exc:
            self._json(202, {"state": "preparing", "retry_after": 2,
                             "detail": str(exc), "progress": exc.progress})
        except sqlite3.OperationalError as exc:
            if getattr(exc, "sqlite_errorcode", None) == sqlite3.SQLITE_INTERRUPT:
                self._problem(503, "report_timeout", "This range exceeded the reporting time budget; narrow the dates or filters and retry")
            else:
                self._problem(503, "storage_unavailable", "Reporting storage is unavailable or busy; retry shortly")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except Exception:
            self.app.audit("dashboard.request_failed")
            self._problem(503, "service_unavailable", "The requested information is temporarily unavailable")

    @staticmethod
    def _cookie(token, lifetime):
        return f"{COOKIE_NAME}={token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={lifetime}"

    def _get(self, path, query, session):
        name = path.removeprefix("/api/")
        if name == "dashboard/state":
            return self._json(200, self.app.lifecycle.state())
        if name == "management/state":
            return self._json(200, self.app.broker.call("state", {"actor": {"session_id": session["id"]}}))
        if name == "sessions":
            return self._json(200, {"sessions": self.app.auth.sessions(), "current_session_id": session["id"]})
        if name in {"overview", "history", "requests", "events", "audience", "mcp", "metrics"}:
            result = self.app.lifecycle.report(session["id"], self.app.analytics.report, name, query)
            if name == "overview":
                result["dashboard"] = self.app.lifecycle.state()
            return self._json(200, result)
        if name in {"endpoints", "translations", "operations", "jobs"}:
            params = {**query, "actor": {"session_id": session["id"]}}
            result = self.app.lifecycle.report(session["id"], self.app.broker.call, name, params)
            return self._json(200, result)
        if name == "storage":
            result = self.app.lifecycle.report(session["id"], self.app.broker.call, "storage", {
                **query, "refresh": query.get("refresh") == "true",
            })
            if not isinstance(result, dict):
                result = {"components": result}
            result["telemetry"] = self.app.lifecycle.report(session["id"], self.app.analytics.report, "storage", query)
            return self._json(200, result)
        match = re.fullmatch(r"/api/jobs/([a-zA-Z0-9_-]{1,128})", path)
        if match:
            # Ordinary polling must never consume a newly generated API token.
            # The owner explicitly reveals it once through a CSRF-protected POST.
            result = self.app.lifecycle.report(session["id"], self.app.broker.call, "job", {
                "job_id": match[1], "actor": {"session_id": session["id"]},
            })
            return self._json(200, result)
        self._problem(404, "not_found", "This dashboard route does not exist")

    def _post(self, path, body, session, ip):
        if path in {"/api/dashboard/heartbeat", "/api/dashboard/leave"}:
            viewer_id = body.get("viewer_id", "")
            if not isinstance(viewer_id, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{8,128}", viewer_id):
                raise ValueError("A valid viewer_id is required")
            if path.endswith("/leave"):
                self.app.lifecycle.leave(session["id"], viewer_id)
                return self._json(200, self.app.lifecycle.state())
            return self._json(200, self.app.lifecycle.heartbeat(session["id"], viewer_id))
        if path == "/api/auth/logout":
            self.app.auth.revoke(session["id"])
            self.app.lifecycle.leave(session["id"])
            return self._json(200, {"authenticated": False}, cookie=self._cookie("", 0))
        match = re.fullmatch(r"/api/sessions/([a-zA-Z0-9_-]{1,128})/revoke", path)
        if match:
            identifier = match[1]
            count = self.app.auth.revoke(identifier)
            if identifier == "all":
                self.app.lifecycle.tick(set())
            else:
                self.app.lifecycle.leave(identifier)
            cookie = self._cookie("", 0) if identifier in {"all", session["id"]} else None
            return self._json(200, {"revoked": count}, cookie=cookie)
        if path == "/api/actions":
            operation = body.get("operation")
            arguments = body.get("arguments", {})
            if not isinstance(operation, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,80}", operation):
                raise ValueError("A valid operation is required")
            if not isinstance(arguments, dict):
                raise ValueError("Operation arguments must be an object")
            confirmation = body.get("confirm", False)
            if not isinstance(confirmation, bool):
                raise ValueError("confirm must be a boolean")
            result = self.app.broker.call("submit", {"operation": operation, "arguments": arguments, "confirm": confirmation,
                                                   "actor": {"session_id": session["id"], "ip": ip}})
            self.app.audit("dashboard.action_submitted", ip=ip, session_id=session["id"], operation=operation)
            return self._json(202, result)
        match = re.fullmatch(r"/api/jobs/([a-zA-Z0-9_-]{1,128})/reveal", path)
        if match:
            result = self.app.broker.call("job", {"job_id": match[1], "consume_secret": True,
                                                  "actor": {"session_id": session["id"], "ip": ip}})
            self.app.audit("dashboard.job_secret_revealed", session_id=session["id"], job_id=match[1])
            return self._json(200, result)
        self._problem(404, "not_found", "This dashboard action does not exist")

    def _static(self, path):
        decoded = unquote(path, errors="strict")
        if "\0" in decoded or any(part.startswith(".") for part in decoded.split("/") if part):
            return self._problem(404, "not_found", "This dashboard asset does not exist")
        root = Path(self.app.config.static_dir).resolve()
        target = (root / ("index.html" if decoded == "/" else decoded.lstrip("/"))).resolve()
        if not target.is_relative_to(root) or not target.is_file():
            return self._problem(404, "not_found", "The dashboard application is unavailable; check its installation")
        data = target.read_bytes()
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        cache = "public, max-age=31536000, immutable" if re.search(r"[.-][a-f0-9]{8,}[.-]", target.name) else "no-cache"
        self._headers(200, content_type, len(data), cache=cache)
        if self.command != "HEAD":
            self.wfile.write(data)


class DashboardHTTPServer(ThreadingMixIn, HTTPServer):
    address_family = socket.AF_UNIX
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, path, app):
        self.app = app
        self._connections = threading.BoundedSemaphore(32)
        super().__init__(path, DashboardHandler)

    def server_bind(self):
        # HTTPServer's TCP hostname resolution is inappropriate for Unix paths.
        self.socket.bind(self.server_address)
        self.server_name = self.app.config.domain
        self.server_port = 0

    def process_request(self, request, client_address):
        if not self._connections.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._connections.release()
