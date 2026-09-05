"""Fail-fast start check run by systemd before gunicorn starts."""

from __future__ import annotations

from getbible_api_common.bible import query_client

from .config import Settings


def main() -> int:
    settings = Settings.from_environment()
    bible = query_client(
        settings.librarian,
        reference_cache_limit=settings.reference_cache_limit,
        chapter_cache_limit=settings.chapter_cache_limit,
        max_references=settings.max_references,
        max_total_verses=settings.max_total_verses,
    )
    try:
        if not bible.valid_translation(settings.service.default_translation):
            raise SystemExit(
                f"Translation {settings.service.default_translation!r} is unavailable from "
                f"{settings.librarian.repository!r} ({settings.librarian.version})."
            )
        if not bible.valid_reference(settings.default_reference, settings.service.default_translation):
            raise SystemExit(f"Default reference {settings.default_reference!r} does not resolve.")
        result = bible.select(settings.default_reference, settings.service.default_translation)
        if not any(chapter.get("verses") for chapter in result.values()):
            raise SystemExit("Default reference returned no scripture; refusing to start.")
        print(f"query endpoint ready: repository {settings.librarian.repository!r} version {settings.librarian.version!r}")
    finally:
        bible.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
