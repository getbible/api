"""Search endpoint configuration (environment prefix SEARCH_)."""

from __future__ import annotations

from dataclasses import dataclass, field

from getbible import SearchBible
from getbible_api_common.settings import LibrarianSettings, ServiceSettings, env_int, env_str

_DEFAULT_KEYS = ("words", "match", "case_sensitive", "scope", "diacritics", "sort", "limit")


@dataclass(frozen=True, slots=True)
class Settings:
    librarian: LibrarianSettings
    service: ServiceSettings
    search_corpus_limit: int = 4
    translation_cache_limit: int = 4
    max_query_length: int = 500
    max_page_size: int = 100
    max_offset: int = 10_000
    deadline_seconds: float = 5.0
    max_concurrent: int = 4
    max_concurrent_expensive: int = 2
    warm_translations: tuple[str, ...] = ()
    default_criteria: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not 32 <= self.max_query_length <= 500:
            raise ValueError("SEARCH_MAX_QUERY_LENGTH must be between 32 and 500.")
        if not 1 <= self.max_page_size <= 1000:
            raise ValueError("SEARCH_MAX_PAGE_SIZE must be between 1 and 1000.")
        if not 0 <= self.max_offset <= 10_000:
            raise ValueError("SEARCH_MAX_OFFSET must be between 0 and 10000.")
        if not 0.5 <= self.deadline_seconds <= 60:
            raise ValueError("SEARCH_DEADLINE_SECONDS must be between 0.5 and 60.")
        if self.max_concurrent < 1 or self.max_concurrent_expensive < 1:
            raise ValueError("SEARCH_MAX_CONCURRENT values must be positive.")
        # The configured defaults must themselves be valid criteria.
        SearchBible.from_value(self.default_criteria)

    @classmethod
    def from_environment(cls) -> Settings:
        defaults: dict = {}
        for key in _DEFAULT_KEYS:
            raw = env_str(f"SEARCH_DEFAULT_{key.upper()}", "")
            if not raw:
                continue
            if key == "case_sensitive":
                defaults[key] = raw.strip().casefold() in {"1", "true", "yes", "on"}
            elif key == "limit":
                defaults[key] = int(raw)
            else:
                defaults[key] = raw
        warm = tuple(dict.fromkeys(code.strip().casefold() for code in env_str("SEARCH_WARM_TRANSLATIONS", "").split(",") if code.strip()))
        return cls(
            librarian=LibrarianSettings.from_environment("/var/cache/getbible/search/librarian"),
            service=ServiceSettings.from_environment("SEARCH", cache_seconds=60, max_input_length=500),
            search_corpus_limit=env_int("GETBIBLE_SEARCH_CORPUS_LIMIT", 4, 0, 1000),
            translation_cache_limit=env_int("GETBIBLE_TRANSLATION_CACHE_LIMIT", 4, 0, 1000),
            max_query_length=env_int("SEARCH_MAX_QUERY_LENGTH", 500, 32, 500),
            max_page_size=env_int("SEARCH_MAX_PAGE_SIZE", 100, 1, 1000),
            max_offset=env_int("SEARCH_MAX_OFFSET", 10_000, 0, 10_000),
            deadline_seconds=float(env_str("SEARCH_DEADLINE_SECONDS", "5")),
            max_concurrent=env_int("SEARCH_MAX_CONCURRENT", 4, 1, 256),
            max_concurrent_expensive=env_int("SEARCH_MAX_CONCURRENT_EXPENSIVE", 2, 1, 256),
            warm_translations=warm,
            default_criteria=defaults,
        )
