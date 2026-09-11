"""Validated dashboard configuration; never evaluate shell configuration."""

from dataclasses import dataclass
import os
from pathlib import Path
import re


def read_settings(path):
    values = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return values
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def positive_int(values, name, default, minimum=1, maximum=2147483647):
    try:
        value = int(values.get(name, default))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True)
class Config:
    domain: str = ""
    enabled: bool = False
    state_dir: str = "/var/lib/getbible/dashboard"
    socket_path: str = "/run/getbible-dashboard/http.sock"
    broker_socket: str = "/run/getbible-admin/broker.sock"
    static_dir: str = "/usr/local/share/getbible-dashboard"
    telemetry_db: str = "/var/lib/getbible/telemetry/traffic.sqlite3"
    telegram_conf: str = "/run/getbible/telegram.conf"
    session_seconds: int = 30 * 86400
    idle_seconds: int = 60
    token_seconds: int = 60
    max_body_bytes: int = 16384

    @property
    def origin(self):
        return f"https://{self.domain}"

    @classmethod
    def load(cls, path, **overrides):
        values = read_settings(path)
        for key in tuple(values) + (
            "DASHBOARD_DOMAIN", "DASHBOARD_ENABLED", "DASHBOARD_SESSION_DAYS",
            "DASHBOARD_IDLE_SECONDS", "DASHBOARD_TOKEN_SECONDS",
        ):
            env = os.environ.get("GETBIBLE_" + key)
            if env is not None:
                values[key] = env
        domain = values.get("DASHBOARD_DOMAIN", "").lower()
        if domain and (len(domain) > 253 or not re.fullmatch(
            r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
            r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", domain
        )):
            raise ValueError("DASHBOARD_DOMAIN must be a fully qualified hostname")
        enabled = values.get("DASHBOARD_ENABLED", "false")
        if enabled not in ("true", "false"):
            raise ValueError("DASHBOARD_ENABLED must be true or false")
        if enabled == "true" and not domain:
            raise ValueError("DASHBOARD_DOMAIN is required when the dashboard is enabled")
        telegram_conf = values.get("TELEGRAM_CONF", "/run/getbible/telegram.conf")
        if telegram_conf == "/run/getbible/telegram.conf" and not Path(telegram_conf).exists():
            telegram_conf = "/etc/getbible/telegram.conf"
        kwargs = {
            "domain": domain,
            "enabled": enabled == "true",
            "telegram_conf": telegram_conf,
            "session_seconds": positive_int(values, "DASHBOARD_SESSION_DAYS", 30, 1, 30) * 86400,
            "idle_seconds": positive_int(values, "DASHBOARD_IDLE_SECONDS", 60, 10, 3600),
            "token_seconds": positive_int(values, "DASHBOARD_TOKEN_SECONDS", 60, 10, 60),
        }
        path_keys = {
            "DASHBOARD_STATE_DIR": "state_dir", "DASHBOARD_SOCKET": "socket_path",
            "DASHBOARD_BROKER_SOCKET": "broker_socket", "DASHBOARD_STATIC_DIR": "static_dir",
            "BROKER_SOCKET": "broker_socket",
            "TELEMETRY_DATABASE": "telemetry_db", "TELEMETRY_DB": "telemetry_db",
        }
        for key, attribute in path_keys.items():
            if key in values:
                kwargs[attribute] = values[key]
        kwargs.update({key: value for key, value in overrides.items() if value is not None})
        return cls(**kwargs)
