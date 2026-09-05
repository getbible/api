"""Query endpoint configuration (environment prefix QUERY_)."""

from __future__ import annotations

from dataclasses import dataclass

from getbible_api_common.settings import LibrarianSettings, ServiceSettings, env_int, env_str


@dataclass(frozen=True, slots=True)
class Settings:
    librarian: LibrarianSettings
    service: ServiceSettings
    default_reference: str = "Mat7:7"
    reference_cache_limit: int = 5000
    chapter_cache_limit: int = 2048
    max_references: int = 8
    max_total_verses: int = 200

    def __post_init__(self) -> None:
        if not self.default_reference or " " in self.default_reference:
            raise ValueError("QUERY_DEFAULT_REFERENCE must use compact notation without spaces.")
        if len(self.default_reference) > self.service.max_input_length:
            raise ValueError("QUERY_DEFAULT_REFERENCE exceeds QUERY_MAX_INPUT_LENGTH.")

    @classmethod
    def from_environment(cls) -> Settings:
        return cls(
            librarian=LibrarianSettings.from_environment("/var/cache/getbible/query/librarian"),
            service=ServiceSettings.from_environment("QUERY", cache_seconds=300, max_input_length=512),
            default_reference=env_str("QUERY_DEFAULT_REFERENCE", "Mat7:7"),
            reference_cache_limit=env_int("GETBIBLE_REFERENCE_CACHE_LIMIT", 5000, 0, 1_000_000),
            chapter_cache_limit=env_int("GETBIBLE_CHAPTER_CACHE_LIMIT", 2048, 0, 100_000),
            max_references=env_int("QUERY_MAX_REFERENCES", 8, 1, 64),
            max_total_verses=env_int("QUERY_MAX_TOTAL_VERSES", 200, 1, 200),
        )
