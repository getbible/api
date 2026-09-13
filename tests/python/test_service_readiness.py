"""Readiness deadlines against a real local HTTP service."""

from __future__ import annotations

import shutil
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ProbeServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class ProbeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(6)
        status = 503 if self.path == "/unavailable" else 200
        try:
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b'{"status":"ready"}')
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


@unittest.skipUnless(shutil.which("curl"), "curl is required for service readiness")
class ServiceReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.socket = str(Path(self.temporary.name) / "probe.sock")
        try:
            self.server = ProbeServer(self.socket, ProbeHandler)
        except PermissionError:
            self.temporary.cleanup()
            self.skipTest("Unix sockets are unavailable in this test environment")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def probe(self, path, deadline, attempt=None):
        command = ["bash", "-c", 'GB_PREFIX=""; source "$1"; shift; sd_wait_ready "$@"',
                   "readiness", str(ROOT / "src/lib/systemd.sh"), self.socket, path, str(deadline)]
        if attempt is not None:
            command.append(str(attempt))
        return subprocess.run(command, capture_output=True, text=True, timeout=deadline + 3)

    def test_deployment_probe_can_complete_within_its_startup_budget(self):
        self.assertEqual(self.probe("/slow", 12, 12).returncode, 0)

    def test_expensive_probe_cannot_exceed_the_overall_deadline(self):
        start = time.monotonic()
        self.assertNotEqual(self.probe("/slow", 2, 12).returncode, 0)
        self.assertLess(time.monotonic() - start, 4)

    def test_health_status_must_succeed(self):
        self.assertEqual(self.probe("/ready", 3).returncode, 0)
        self.assertNotEqual(self.probe("/unavailable", 2).returncode, 0)


class ReadinessBudgetTests(unittest.TestCase):
    def test_probe_latency_is_bounded_by_both_allowances(self):
        # A deterministic transport/clock also covers deadline behavior where
        # the test host does not permit binding local service sockets.
        script = r'''
GB_PREFIX=""
source "$1"
latency="$2"
deadline="$3"
attempt="$4"
curl() {
    local allowance=0
    while (( $# )); do
        if [[ "$1" == --max-time ]]; then allowance="$2"; shift; fi
        shift
    done
    if (( allowance >= latency )); then
        SECONDS=$((SECONDS + latency))
        return 0
    fi
    SECONDS=$((SECONDS + allowance))
    return 28
}
sleep() { SECONDS=$((SECONDS + $1)); }
sd_wait_ready /probe.sock /probe "$deadline" "$attempt"
'''
        for latency, deadline, attempt, succeeds in [
            (1, 15, 5, True), (9, 30, 30, True),
            (9, 4, 30, False), (9, 30, 5, False),
        ]:
            with self.subTest(latency=latency, deadline=deadline, attempt=attempt):
                result = subprocess.run(
                    ["bash", "-c", script, "budget", str(ROOT / "src/lib/systemd.sh"),
                     str(latency), str(deadline), str(attempt)], capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)


if __name__ == "__main__":
    unittest.main()
