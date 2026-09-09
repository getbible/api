"""Environment-backed configuration shared by every runtime endpoint."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

_VERSION = re.compile(r"v[1-9][0-9]*")
_TRANSLATION = re.compile(r"[a-z0-9][a-z0-9_-]{0,29}")
_LOG_LEVELS = {"CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG"}


def env_str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = raw.strip().casefold()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean value.")


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer.") from error
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}.")
    return value


def env_ratio(name: str, default: float) -> float:
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be a number.") from error
    if not 0 <= value < 1:
        raise ValueError(f"{name} must be between 0 (inclusive) and 1.")
    return value


def translations_list(value: str) -> tuple[str, ...]:
    """A normalised allowlist; empty (or *) means every translation."""
    codes = tuple(dict.fromkeys(code.strip().casefold() for code in value.split(",") if code.strip()))
    return () if "*" in codes else codes


def valid_translation_code(code: str) -> bool:
    return isinstance(code, str) and _TRANSLATION.fullmatch(code) is not None


def valid_version(version: str) -> bool:
    return isinstance(version, str) and _VERSION.fullmatch(version) is not None


@dataclass(frozen=True, slots=True)
class LibrarianSettings:
    """What every endpoint needs to construct a librarian client."""

    repository: str = "/srv/getbible/api.getbible.net"
    version: str = "v2"
    cache_dir: str = "/var/cache/getbible/query/librarian"
    cache_ttl_seconds: int = 900
    cache_ttl_jitter: float = 0.1
    strict_freshness: bool = False
    request_connect_timeout: int = 3
    request_read_timeout: int = 30
    request_retries: int = 3
    books_cache_limit: int = 64

    def __post_init__(self) -> None:
        if not isinstance(self.repository, str) or not self.repository.startswith("/"):
            raise ValueError("GETBIBLE_REPOSITORY must be an absolute local path; remote API URLs are not supported.")
        if not valid_version(self.version):
            raise ValueError("GETBIBLE_VERSION must look like 'v2'.")
        bounds = (
            ("GETBIBLE_CACHE_TTL_SECONDS", self.cache_ttl_seconds, 0, 2_592_000),
            ("GETBIBLE_CONNECT_TIMEOUT", self.request_connect_timeout, 1, 60),
            ("GETBIBLE_READ_TIMEOUT", self.request_read_timeout, 1, 300),
            ("GETBIBLE_REQUEST_RETRIES", self.request_retries, 0, 10),
            ("GETBIBLE_BOOKS_CACHE_LIMIT", self.books_cache_limit, 0, 10_000),
        )
        for name, value, minimum, maximum in bounds:
            if not isinstance(value, int) or isinstance(value, bool) or not minimum <= value <= maximum:
                raise ValueError(f"{name} must be between {minimum} and {maximum}.")
        if not 0 <= self.cache_ttl_jitter < 1:
            raise ValueError("GETBIBLE_CACHE_TTL_JITTER must be between 0 (inclusive) and 1.")

    @property
    def is_local(self) -> bool:
        return True

    @classmethod
    def from_environment(cls, default_cache_dir: str) -> LibrarianSettings:
        defaults = cls()
        return cls(
            repository=env_str("GETBIBLE_REPOSITORY", defaults.repository),
            version=env_str("GETBIBLE_VERSION", defaults.version).strip("/"),
            cache_dir=env_str("GETBIBLE_CACHE_DIR", default_cache_dir),
            cache_ttl_seconds=env_int("GETBIBLE_CACHE_TTL_SECONDS", defaults.cache_ttl_seconds, 0, 2_592_000),
            cache_ttl_jitter=env_ratio("GETBIBLE_CACHE_TTL_JITTER", defaults.cache_ttl_jitter),
            strict_freshness=env_bool("GETBIBLE_STRICT_FRESHNESS", defaults.strict_freshness),
            request_connect_timeout=env_int("GETBIBLE_CONNECT_TIMEOUT", defaults.request_connect_timeout, 1, 60),
            request_read_timeout=env_int("GETBIBLE_READ_TIMEOUT", defaults.request_read_timeout, 1, 300),
            request_retries=env_int("GETBIBLE_REQUEST_RETRIES", defaults.request_retries, 0, 10),
            books_cache_limit=env_int("GETBIBLE_BOOKS_CACHE_LIMIT", defaults.books_cache_limit, 0, 10_000),
        )


@dataclass(frozen=True, slots=True)
class ServiceSettings:
    """HTTP-level settings shared by the endpoints (prefix QUERY_ or SEARCH_)."""

    prefix: str = "QUERY"
    default_translation: str = "kjv"
    allowed_translations: tuple[str, ...] = ()
    slow_request_milliseconds: int = 1000
    log_level: str = "INFO"
    app_log: str = ""
    trust_proxy: bool = True
    cache_seconds: int = 300
    max_input_length: int = 512
    access_mode: str = "metered"

    def __post_init__(self) -> None:
        if self.access_mode not in {"open", "metered", "token"}:
            raise ValueError("GB_ACCESS_MODE must be open, metered or token.")
        translation = self.default_translation.casefold() if isinstance(self.default_translation, str) else ""
        object.__setattr__(self, "default_translation", translation)
        if not valid_translation_code(translation):
            raise ValueError(f"{self.prefix}_DEFAULT_TRANSLATION is invalid.")
        allowed = tuple(dict.fromkeys(code.casefold() for code in self.allowed_translations))
        object.__setattr__(self, "allowed_translations", allowed)
        if any(not valid_translation_code(code) for code in allowed):
            raise ValueError(f"{self.prefix}_ALLOWED_TRANSLATIONS contains an invalid code.")
        if allowed and translation not in allowed:
            raise ValueError(f"{self.prefix}_DEFAULT_TRANSLATION must be in {self.prefix}_ALLOWED_TRANSLATIONS.")
        if self.log_level not in _LOG_LEVELS:
            raise ValueError(f"{self.prefix}_LOG_LEVEL is invalid.")
        if not 1 <= self.slow_request_milliseconds <= 300_000:
            raise ValueError(f"{self.prefix}_SLOW_REQUEST_MILLISECONDS is out of range.")
        if not 0 <= self.cache_seconds <= 86_400:
            raise ValueError(f"{self.prefix}_CACHE_SECONDS is out of range.")
        if not 32 <= self.max_input_length <= 4096:
            raise ValueError(f"{self.prefix}_MAX_INPUT_LENGTH is out of range.")

    def translation_allowed(self, code: str) -> bool:
        return not self.allowed_translations or code.casefold() in self.allowed_translations

    @classmethod
    def from_environment(cls, prefix: str, **overrides: object) -> ServiceSettings:
        defaults = cls(prefix=prefix)
        values = dict(
            prefix=prefix,
            access_mode=env_str("GB_ACCESS_MODE", defaults.access_mode),
            default_translation=env_str(f"{prefix}_DEFAULT_TRANSLATION", defaults.default_translation),
            allowed_translations=translations_list(env_str(f"{prefix}_ALLOWED_TRANSLATIONS", "")),
            slow_request_milliseconds=env_int(f"{prefix}_SLOW_REQUEST_MILLISECONDS", defaults.slow_request_milliseconds, 1, 300_000),
            log_level=env_str(f"{prefix}_LOG_LEVEL", defaults.log_level).upper(),
            app_log=env_str("GETBIBLE_APP_LOG", ""),
            trust_proxy=env_bool(f"{prefix}_TRUST_PROXY", True),
            cache_seconds=env_int(f"{prefix}_CACHE_SECONDS", overrides.pop("cache_seconds", defaults.cache_seconds), 0, 86_400),
            max_input_length=env_int(f"{prefix}_MAX_INPUT_LENGTH", overrides.pop("max_input_length", defaults.max_input_length), 32, 4096),
        )
        values.update(overrides)
        return cls(**values)
