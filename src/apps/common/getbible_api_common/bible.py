"""Librarian client construction for the two endpoint roles."""

from __future__ import annotations

from datetime import timedelta
from pathlib import Path

from getbible import GetBible, RequestLimits, SearchLimits

from .settings import LibrarianSettings


def _common_kwargs(settings: LibrarianSettings) -> dict:
    # Availability only: source repositories already validate their own data.
    # Refuse unavailable local data before constructing the librarian client.
    if not (Path(settings.repository) / settings.version).is_dir():
        raise ValueError(f"Local scripture folder {settings.repository}/{settings.version} is unavailable; sync the static endpoint first.")
    return dict(
        repo_path=settings.repository,
        version=settings.version,
        cache_ttl=timedelta(seconds=settings.cache_ttl_seconds),
        request_timeout=(float(settings.request_connect_timeout), float(settings.request_read_timeout)),
        request_retries=settings.request_retries,
        cache_dir=settings.cache_dir,
        strict_freshness=settings.strict_freshness,
        books_cache_limit=settings.books_cache_limit,
        cache_ttl_jitter=settings.cache_ttl_jitter,
        require_checksums=settings.require_checksums,
    )


def query_client(settings: LibrarianSettings, *, reference_cache_limit: int, chapter_cache_limit: int,
                 max_references: int, max_total_verses: int) -> GetBible:
    """A client for reference lookups only: no full-translation retention."""
    return GetBible(
        reference_cache_limit=reference_cache_limit,
        chapter_cache_limit=chapter_cache_limit,
        search_corpus_limit=0,
        translation_cache_limit=0,
        request_limits=RequestLimits(max_references=max_references, max_total_verses=max_total_verses),
        **_common_kwargs(settings),
    )


def search_client(settings: LibrarianSettings, *, search_corpus_limit: int, translation_cache_limit: int,
                  deadline_seconds: float, max_limit: int, max_offset: int) -> GetBible:
    """A client for full-text search plus the chapter path for typed references."""
    return GetBible(
        reference_cache_limit=256,
        chapter_cache_limit=256,
        search_corpus_limit=search_corpus_limit,
        translation_cache_limit=translation_cache_limit,
        search_limits=SearchLimits(deadline_seconds=deadline_seconds, max_limit=max_limit, max_offset=max_offset),
        **_common_kwargs(settings),
    )
