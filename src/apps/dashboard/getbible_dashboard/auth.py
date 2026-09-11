"""Persistent password, Telegram challenge, block and revocable session state.

Every security state transition is serialized in SQLite, including concurrent
password failures and one-use code consumption. Password hashing and Telegram
delivery take place outside database transactions.
"""

from contextlib import contextmanager
import hashlib
import hmac
import ipaddress
import os
from pathlib import Path
import secrets
import re
import sqlite3
import threading
import time

from .telegram import DeliveryError


class AuthError(Exception):
    def __init__(self, code, message, status=401):
        super().__init__(message)
        self.code = code
        self.status = status


def canonical_ip(value):
    try:
        return str(ipaddress.ip_address(value))
    except (TypeError, ValueError):
        raise AuthError("invalid_client", "A verified client address is required", 400) from None


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def csrf_token(session_token):
    return hashlib.sha256(("getbible-dashboard-csrf\0" + session_token).encode()).hexdigest()


def password_hash(password):
    salt = secrets.token_bytes(32)
    result = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=32768, r=8, p=1,
                            maxmem=128 * 1024 * 1024, dklen=64)
    return f"scrypt$32768$8$1${salt.hex()}${result.hex()}"


def password_matches(password, encoded):
    try:
        kind, n, r, p, salt, expected = encoded.split("$")
        if kind != "scrypt" or (int(n), int(r), int(p)) != (32768, 8, 1):
            return False
        actual = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt),
                                n=int(n), r=int(r), p=int(p), maxmem=128 * 1024 * 1024,
                                dklen=64)
        return hmac.compare_digest(actual, bytes.fromhex(expected))
    except (ValueError, TypeError, UnicodeError):
        return False


class AuthStore:
    def __init__(self, state_dir, *, session_seconds=30 * 86400,
                 token_seconds=60, clock=None, audit=None):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = self.state_dir / "auth.sqlite3"
        self.clock = clock or time.time
        self.session_seconds = session_seconds
        self.token_seconds = token_seconds
        self.audit = audit or (lambda event, **fields: None)
        self._hash_slots = threading.BoundedSemaphore(4)
        with self._db() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS clients(
                    ip TEXT PRIMARY KEY, failures INTEGER NOT NULL DEFAULT 0,
                    blocked_at REAL, reason TEXT);
                CREATE TABLE IF NOT EXISTS challenges(
                    id TEXT PRIMARY KEY, ip TEXT NOT NULL UNIQUE, token_hash TEXT NOT NULL,
                    created_at REAL NOT NULL, expires_at REAL, password_epoch TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS challenge_expiry ON challenges(expires_at);
                CREATE TABLE IF NOT EXISTS sessions(
                    id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, ip TEXT NOT NULL,
                    user_agent TEXT NOT NULL, created_at REAL NOT NULL,
                    expires_at REAL NOT NULL, last_seen REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS session_expiry ON sessions(expires_at);
            """)
            current = db.execute("SELECT value FROM settings WHERE key='password'").fetchone()
        os.chmod(self.path, 0o600)
        if current is None:
            # There is deliberately no generic or printed bootstrap password.
            initial = password_hash(secrets.token_urlsafe(48))
            with self._transaction() as db:
                db.execute("INSERT OR IGNORE INTO settings VALUES('password', ?)", (initial,))
                db.execute("INSERT OR IGNORE INTO settings VALUES('password_epoch', ?)",
                           (secrets.token_hex(16),))

    @contextmanager
    def _db(self):
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=10000")
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def _transaction(self):
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
            except BaseException:
                db.rollback()
                raise
            else:
                db.commit()

    @staticmethod
    def _blocked(db, ip):
        row = db.execute("SELECT blocked_at FROM clients WHERE ip=?", (ip,)).fetchone()
        return bool(row is not None and row[0] is not None)

    @staticmethod
    def _block(db, ip, now, reason):
        db.execute("""INSERT INTO clients(ip, failures, blocked_at, reason) VALUES(?,0,?,?)
            ON CONFLICT(ip) DO UPDATE SET blocked_at=excluded.blocked_at,reason=excluded.reason""",
                   (ip, now, reason))
        db.execute("DELETE FROM challenges WHERE ip=?", (ip,))

    def check_ip(self, ip):
        ip = canonical_ip(ip)
        self.expire_challenges()
        with self._db() as db:
            if self._blocked(db, ip):
                raise AuthError("ip_blocked", "Access is blocked; use the server CLI to unblock this address", 403)
        return ip

    def expire_challenges(self):
        now = self.clock()
        with self._transaction() as db:
            expired = db.execute("SELECT ip FROM challenges WHERE expires_at IS NOT NULL AND expires_at<=?",
                                 (now,)).fetchall()
            for row in expired:
                self._block(db, row[0], now, "challenge_expired")
            # A process interrupted during delivery must not strand an IP.
            db.execute("DELETE FROM challenges WHERE expires_at IS NULL AND created_at<?", (now - 30,))
            db.execute("DELETE FROM sessions WHERE expires_at<=?", (now,))
        for row in expired:
            self.audit("dashboard.blocked", ip=row[0], reason="challenge_expired")
        return len(expired)

    def set_password(self, password):
        if not isinstance(password, str) or not 12 <= len(password) <= 1024:
            raise ValueError("Password must contain between 12 and 1024 characters")
        encoded = password_hash(password)
        with self._transaction() as db:
            db.execute("INSERT OR REPLACE INTO settings VALUES('password', ?)", (encoded,))
            db.execute("INSERT OR REPLACE INTO settings VALUES('password_epoch', ?)", (secrets.token_hex(16),))
            db.execute("DELETE FROM sessions")
            db.execute("DELETE FROM challenges")
        self.audit("dashboard.password_changed")

    def start_challenge(self, ip, password, telegram):
        ip = self.check_ip(ip)
        if not telegram.configured:
            raise AuthError("telegram_unavailable", "Telegram must be configured before signing in", 503)
        if not isinstance(password, str) or len(password) > 1024:
            password = ""
        if not self._hash_slots.acquire(blocking=False):
            raise AuthError("authentication_busy", "Authentication is busy; retry shortly", 503)
        try:
            with self._db() as db:
                settings = dict(db.execute("SELECT key,value FROM settings"))
            matches = password_matches(password, settings["password"])
        finally:
            self._hash_slots.release()
        challenge_id = secrets.token_urlsafe(32)
        code = secrets.token_urlsafe(24)
        token_seconds = self.token_seconds
        error = None
        now = self.clock()
        with self._transaction() as db:
            epoch = db.execute("SELECT value FROM settings WHERE key='password_epoch'").fetchone()[0]
            if self._blocked(db, ip):
                error = AuthError("ip_blocked", "Access is blocked; use the server CLI to unblock this address", 403)
            elif epoch != settings["password_epoch"]:
                error = AuthError("password_changed", "The password changed; sign in again", 409)
            elif not matches:
                db.execute("""INSERT INTO clients(ip,failures) VALUES(?,1)
                    ON CONFLICT(ip) DO UPDATE SET failures=failures+1""", (ip,))
                failures = db.execute("SELECT failures FROM clients WHERE ip=?", (ip,)).fetchone()[0]
                if failures >= 3:
                    self._block(db, ip, now, "password_failures")
                    error = AuthError("ip_blocked", "Access is blocked; use the server CLI to unblock this address", 403)
                else:
                    error = AuthError("invalid_password", "The password is incorrect", 401)
            elif db.execute("SELECT 1 FROM challenges WHERE ip=?", (ip,)).fetchone():
                error = AuthError("challenge_pending", "A Telegram challenge is already pending for this address", 409)
            else:
                db.execute("INSERT INTO challenges VALUES(?,?,?,?,NULL,?)",
                           (challenge_id, ip, digest(code), now, epoch))
                db.execute("UPDATE clients SET failures=0 WHERE ip=?", (ip,))
        if error:
            self.audit("dashboard.authentication_denied", ip=ip, reason=error.code)
            raise error
        try:
            telegram.login_code(code, ip, challenge_id, token_seconds)
        except DeliveryError:
            with self._transaction() as db:
                db.execute("DELETE FROM challenges WHERE id=? AND expires_at IS NULL", (challenge_id,))
            self.audit("dashboard.telegram_delivery_failed", ip=ip)
            raise AuthError("telegram_delivery_failed", "Telegram could not deliver the code; no access block was added", 503) from None
        # The countdown begins only once Telegram acknowledged the message.
        expires = self.clock() + token_seconds
        with self._transaction() as db:
            updated = db.execute("UPDATE challenges SET expires_at=? WHERE id=? AND password_epoch=?",
                                 (expires, challenge_id, settings["password_epoch"])).rowcount
        if not updated:
            raise AuthError("challenge_cancelled", "This challenge was cancelled; sign in again", 409)
        self.audit("dashboard.challenge_created", ip=ip)
        return {"challenge_id": challenge_id, "expires_at": expires, "expires_in": token_seconds}

    def finish_challenge(self, ip, challenge_id, code, user_agent=""):
        ip = canonical_ip(ip)
        now = self.clock()
        session_seconds = self.session_seconds
        token = secrets.token_urlsafe(48)
        public_id = secrets.token_hex(16)
        error = None
        with self._transaction() as db:
            row = db.execute("SELECT * FROM challenges WHERE id=?", (challenge_id,)).fetchone()
            if self._blocked(db, ip):
                error = AuthError("ip_blocked", "Access is blocked; use the server CLI to unblock this address", 403)
            elif row is None or row["ip"] != ip:
                self._block(db, ip, now, "invalid_challenge")
                error = AuthError("ip_blocked", "The challenge is invalid; this address is blocked", 403)
            elif row["expires_at"] is None:
                error = AuthError("challenge_pending", "Telegram delivery is still pending", 409)
            elif row["expires_at"] <= now:
                self._block(db, ip, now, "challenge_expired")
                error = AuthError("ip_blocked", "The challenge expired; this address is blocked", 403)
            elif not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", code) or not hmac.compare_digest(digest(code), row["token_hash"]):
                self._block(db, ip, now, "invalid_token")
                error = AuthError("ip_blocked", "The code is incorrect; this address is blocked", 403)
            else:
                db.execute("DELETE FROM challenges WHERE id=?", (challenge_id,))
                db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?)", (
                    public_id, digest(token), ip, str(user_agent)[:512], now,
                    now + session_seconds, now,
                ))
        if error:
            self.audit("dashboard.authentication_denied", ip=ip, reason=error.code)
            raise error
        self.audit("dashboard.session_created", ip=ip, session_id=public_id)
        return {"token": token, "session_id": public_id, "csrf_token": csrf_token(token),
                "expires_at": now + session_seconds, "max_age": session_seconds}

    def session(self, token, ip):
        ip = self.check_ip(ip)
        if not isinstance(token, str) or not 32 <= len(token) <= 128:
            raise AuthError("authentication_required", "Sign in to open the dashboard")
        now = self.clock()
        with self._db() as db:
            row = db.execute("SELECT * FROM sessions WHERE token_hash=? AND expires_at>?", (digest(token), now)).fetchone()
            if row is None:
                raise AuthError("authentication_required", "Your session expired or was revoked; sign in again")
            # Keep the observed session activity useful without writing every poll.
            if now - row["last_seen"] >= 60:
                db.execute("UPDATE sessions SET last_seen=? WHERE id=?", (now, row["id"]))
        return {key: row[key] for key in row.keys() if key != "token_hash"}

    def sessions(self):
        with self._db() as db:
            return [dict(row) for row in db.execute(
                "SELECT id,ip,user_agent,created_at,expires_at,last_seen FROM sessions WHERE expires_at>? ORDER BY created_at DESC",
                (self.clock(),),
            )]

    def revoke(self, session_id):
        with self._transaction() as db:
            if session_id == "all":
                count = db.execute("DELETE FROM sessions").rowcount
            else:
                count = db.execute("DELETE FROM sessions WHERE id=?", (session_id,)).rowcount
        self.audit("dashboard.session_revoked", session_id=session_id, count=count)
        return count

    def blocks(self):
        with self._db() as db:
            return [dict(row) for row in db.execute(
                "SELECT ip,blocked_at,reason FROM clients WHERE blocked_at IS NOT NULL ORDER BY blocked_at DESC"
            )]

    def unblock(self, ip):
        ip = canonical_ip(ip)
        with self._transaction() as db:
            db.execute("DELETE FROM challenges WHERE ip=?", (ip,))
            count = db.execute("DELETE FROM clients WHERE ip=?", (ip,)).rowcount
        self.audit("dashboard.ip_unblocked", ip=ip)
        return count

    def status(self):
        return {"sessions": len(self.sessions()), "blocked_addresses": len(self.blocks()),
                "session_seconds": self.session_seconds, "token_seconds": self.token_seconds}
