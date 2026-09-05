"""Fail-fast start check run by systemd before gunicorn starts. Warms the
configured translations so the first search after a restart is fast."""

from __future__ import annotations

from getbible_api_common.bible import search_client

from .config import Settings


def main() -> int:
    settings = Settings.from_environment()
    bible = search_client(
        settings.librarian,
        search_corpus_limit=settings.search_corpus_limit,
        translation_cache_limit=settings.translation_cache_limit,
        deadline_seconds=settings.deadline_seconds,
        max_limit=settings.max_page_size,
        max_offset=settings.max_offset,
    )
    try:
        if not bible.valid_translation(settings.service.default_translation):
            raise SystemExit(
                f"Translation {settings.service.default_translation!r} is unavailable from "
                f"{settings.librarian.repository!r} ({settings.librarian.version})."
            )
        for code in settings.warm_translations:
            report = bible.warm_translation(code, diacritics="fold")
            print(f"warmed {code} sha={report.get('sha', '?')}")
        print(f"search endpoint ready: repository {settings.librarian.repository!r} version {settings.librarian.version!r}")
    finally:
        bible.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
