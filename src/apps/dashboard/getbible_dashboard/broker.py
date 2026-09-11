"""Bounded typed management RPC; the dashboard never executes shell commands."""

import json
import secrets
import socket


class BrokerError(Exception):
    def __init__(self, message, code="broker_unavailable"):
        super().__init__(message)
        self.code = code


class BrokerClient:
    def __init__(self, path, timeout=10):
        self.path = path
        self.timeout = timeout

    def call(self, method, params=None):
        if method not in {"state", "operations", "submit", "job", "jobs", "endpoints", "storage", "translations"}:
            raise BrokerError("Unsupported management request", "invalid_method")
        request_id = secrets.token_hex(16)
        encoded = json.dumps({"id": request_id, "method": method, "params": params or {}},
                             separators=(",", ":")).encode() + b"\n"
        maximum = 2 * 1024 * 1024 if method == "submit" else 16384
        if len(encoded) > maximum:
            raise BrokerError("Management request is too large", "invalid_request")
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(self.path)
                connection.sendall(encoded)
                with connection.makefile("rb") as stream:
                    response = stream.readline(4 * 1024 * 1024 + 1)
            if len(response) > 4 * 1024 * 1024 or not response.endswith(b"\n"):
                raise BrokerError("Invalid management response")
            data = json.loads(response)
            if data.get("id") != request_id:
                raise BrokerError("Invalid management response")
            if "error" in data:
                error = data["error"]
                raise BrokerError(str(error.get("message", "Management request failed")),
                                  str(error.get("code", "operation_failed")))
            return data["result"]
        except (OSError, ValueError, KeyError, TypeError):
            raise BrokerError("The management service is unavailable") from None
