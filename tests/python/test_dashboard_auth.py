"""Offline security tests for durable dashboard authentication."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/dashboard"))

from getbible_dashboard.auth import AuthError, AuthStore, csrf_token
from getbible_dashboard.telegram import DeliveryError, Telegram


class Clock:
    def __init__(self):
        self.value = 1700000000.0

    def __call__(self):
        return self.value


class FakeTelegram:
    configured = True

    def __init__(self):
        self.codes = []
        self.messages = []
        self.failure = False
        self.before_delivery = None

    def login_code(self, code, ip, challenge_id, seconds):
        if self.before_delivery:
            self.before_delivery()
        if self.failure:
            raise DeliveryError("Delivery failed")
        self.codes.append((code, ip, challenge_id, seconds))

    def send(self, title, body):
        self.messages.append((title, body))


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.clock = Clock()
        self.events = []
        self.auth = AuthStore(self.directory.name, clock=self.clock,
                              audit=lambda event, **fields: self.events.append((event, fields)))
        self.password = "A sufficiently long test password"
        self.auth.set_password(self.password)
        self.telegram = FakeTelegram()
        self.ip = "192.0.2.12"

    def challenge(self, ip=None):
        return self.auth.start_challenge(ip or self.ip, self.password, self.telegram)

    def login(self, ip=None):
        ip = ip or self.ip
        challenge = self.challenge(ip)
        return self.auth.finish_challenge(ip, challenge["challenge_id"], self.telegram.codes[-1][0], "Test browser")

    def assert_auth_error(self, code, operation, *args):
        with self.assertRaises(AuthError) as error:
            operation(*args)
        self.assertEqual(code, error.exception.code)

    def test_three_password_failures_are_persistent_and_only_cli_unblocks(self):
        for attempt in range(3):
            self.assert_auth_error("invalid_password" if attempt < 2 else "ip_blocked",
                                   self.auth.start_challenge, self.ip, "wrong", self.telegram)
        restored = AuthStore(self.directory.name, clock=self.clock)
        self.assert_auth_error("ip_blocked", restored.check_ip, self.ip)
        self.clock.value += 400 * 86400
        self.assert_auth_error("ip_blocked", restored.check_ip, self.ip)
        self.auth.unblock(self.ip)
        self.assertEqual(self.ip, self.auth.check_ip(self.ip))

    def test_parallel_password_failures_cannot_lose_increment(self):
        barrier = threading.Barrier(3)

        def fail(_):
            barrier.wait()
            try:
                self.auth.start_challenge(self.ip, "wrong", self.telegram)
            except AuthError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=3) as workers:
            codes = list(workers.map(fail, range(3)))
        self.assertEqual(codes.count("invalid_password"), 2)
        self.assertEqual(codes.count("ip_blocked"), 1)
        self.assertEqual(len(self.auth.blocks()), 1)
        self.assertEqual(self.telegram.codes, [])

    def test_successful_password_resets_consecutive_failure_counter(self):
        self.assert_auth_error("invalid_password", self.auth.start_challenge, self.ip, "wrong", self.telegram)
        self.login()
        self.assert_auth_error("invalid_password", self.auth.start_challenge, self.ip, "wrong", self.telegram)
        self.assert_auth_error("invalid_password", self.auth.start_challenge, self.ip, "wrong", self.telegram)

    def test_expiry_starts_after_telegram_acknowledgement(self):
        self.telegram.before_delivery = lambda: setattr(self.clock, "value", self.clock.value + 20)
        challenge = self.challenge()
        self.assertEqual(challenge["expires_at"], self.clock.value + 60)
        self.clock.value += 59
        self.auth.finish_challenge(self.ip, challenge["challenge_id"], self.telegram.codes[-1][0])

    def test_delivery_failure_does_not_block_or_strand_challenge(self):
        self.telegram.failure = True
        self.assert_auth_error("telegram_delivery_failed", self.challenge)
        self.clock.value += 61
        self.auth.expire_challenges()
        self.assertEqual(self.auth.blocks(), [])
        self.telegram.failure = False
        self.login()

    def test_telegram_required_before_password_attempt(self):
        self.telegram.configured = False
        self.assert_auth_error("telegram_unavailable", self.auth.start_challenge, self.ip, "wrong", self.telegram)
        self.assertEqual(self.auth.blocks(), [])

    def test_pending_challenge_does_not_send_duplicate_messages(self):
        self.challenge()
        self.assert_auth_error("challenge_pending", self.challenge)
        self.assertEqual(len(self.telegram.codes), 1)

    def test_abandoned_challenge_blocks_without_another_request(self):
        self.challenge()
        self.clock.value += 60
        self.assertEqual(self.auth.expire_challenges(), 1)
        self.assertEqual(self.auth.blocks()[0]["reason"], "challenge_expired")

    def test_wrong_code_permanently_blocks(self):
        challenge = self.challenge()
        self.assert_auth_error("ip_blocked", self.auth.finish_challenge, self.ip, challenge["challenge_id"], "wrong")
        self.assertEqual(self.auth.blocks()[0]["reason"], "invalid_token")

    def test_unknown_or_cross_ip_challenge_blocks_only_requesting_ip(self):
        challenge = self.challenge()
        self.assert_auth_error("ip_blocked", self.auth.finish_challenge, "198.51.100.4", challenge["challenge_id"], self.telegram.codes[-1][0])
        self.auth.finish_challenge(self.ip, challenge["challenge_id"], self.telegram.codes[-1][0])
        self.assertEqual(self.auth.blocks()[0]["ip"], "198.51.100.4")

    def test_one_use_challenge_has_exactly_one_session_under_race(self):
        challenge = self.challenge()
        code = self.telegram.codes[-1][0]
        barrier = threading.Barrier(2)

        def finish(_):
            barrier.wait()
            try:
                return self.auth.finish_challenge(self.ip, challenge["challenge_id"], code)
            except AuthError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(finish, range(2)))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertEqual(len(self.auth.sessions()), 1)
        self.assertIn("ip_blocked", results)

    def test_password_reset_during_telegram_delivery_cancels_challenge(self):
        self.telegram.before_delivery = lambda: self.auth.set_password("Another sufficiently long password")
        self.assert_auth_error("challenge_cancelled", self.challenge)
        self.assertEqual(self.auth.blocks(), [])

    def test_persistent_session_has_fixed_thirty_day_expiry(self):
        login = self.login()
        restored = AuthStore(self.directory.name, clock=self.clock)
        self.clock.value += 29 * 86400
        self.assertEqual(restored.session(login["token"], self.ip)["id"], login["session_id"])
        self.clock.value += 86400
        self.assert_auth_error("authentication_required", restored.session, login["token"], self.ip)

    def test_session_can_roam_but_blocked_ip_cannot_use_it(self):
        login = self.login()
        self.auth.session(login["token"], "198.51.100.5")
        self.assert_auth_error("ip_blocked", self.auth.finish_challenge, "198.51.100.5", "unknown", "wrong")
        self.assert_auth_error("ip_blocked", self.auth.session, login["token"], "198.51.100.5")
        self.auth.session(login["token"], self.ip)

    def test_session_revocation_and_password_reset(self):
        first = self.login()
        second = self.login("192.0.2.13")
        self.auth.revoke(first["session_id"])
        self.assert_auth_error("authentication_required", self.auth.session, first["token"], self.ip)
        self.auth.session(second["token"], "192.0.2.13")
        self.auth.set_password("Updated sufficiently long password")
        self.assert_auth_error("authentication_required", self.auth.session, second["token"], "192.0.2.13")

    def test_no_credentials_in_state_list_or_audit(self):
        login = self.login()
        with sqlite3.connect(self.auth.path) as database:
            dump = "\n".join(database.iterdump())
        records = dump + json.dumps(self.auth.sessions()) + json.dumps(self.events)
        for secret in (self.password, login["token"], self.telegram.codes[-1][0]):
            self.assertNotIn(secret, records)
        self.assertNotIn("token_hash", json.dumps(self.auth.sessions()))
        self.assertEqual(login["csrf_token"], csrf_token(login["token"]))
        self.assertEqual(self.auth.path.stat().st_mode & 0o777, 0o600)


class TelegramTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / "telegram.conf"
        self.config.write_text("TELEGRAM_ENABLED=true\nTELEGRAM_BOT_TOKEN=123:test_secret\nTELEGRAM_CHAT_ID=-123\n")

    def response(self, status=200, payload=None):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, limit):
                return json.dumps(payload if payload is not None else {"ok": True}).encode()

        result = Response()
        result.status = status
        return result

    def test_delivery_checks_http_and_telegram_success(self):
        Telegram(self.config, opener=lambda *args, **kwargs: self.response()).send("Test", "Body")
        for response in (self.response(500), self.response(payload={"ok": False})):
            with self.assertRaises(DeliveryError):
                Telegram(self.config, opener=lambda *args, **kwargs: response).send("Test", "Body")

    def test_delivery_errors_do_not_expose_bot_token(self):
        def fail(*args, **kwargs):
            raise OSError("https://api.telegram.org/bot123:test_secret/sendMessage")

        with self.assertRaises(DeliveryError) as error:
            Telegram(self.config, opener=fail).send("Test", "Body")
        self.assertNotIn("test_secret", str(error.exception))


if __name__ == "__main__":
    unittest.main()
