"""Tell a version, a translation and a reference apart, using the librarian."""

from __future__ import annotations

import re

from getbible import GetBible

from .settings import valid_translation_code, valid_version

_VERSION_LIKE = re.compile(r"v[0-9]+")
# Search intent, not a reference parser: require a chapter after a book name
# (including a numeric book), or a verse after ':'. A numbered book's prefix
# alone is not a coordinate. The librarian still validates the whole input.
_EXPLICIT_COORDINATE = re.compile(r"(?:\D\d+(?=\s*(?::|$))|:\s*\d)")


def looks_like_version(segment: str) -> bool:
    return _VERSION_LIKE.fullmatch(segment) is not None


def is_known_version(segment: str, version: str) -> bool:
    return valid_version(segment) and segment == version


def is_translation(bible: GetBible, segment: str, allowed) -> bool:
    code = segment.casefold()
    if not valid_translation_code(code) or not allowed(code):
        return False
    return bible.valid_translation(code)


def is_reference(bible: GetBible, text: str, translation: str, max_length: int) -> bool:
    """Choose the search endpoint's reference fast path only for explicit input.

    Bare names/aliases can also be ordinary search words. The librarian accepts
    them by supplying default coordinates, which can even name a book absent
    from this translation. Leave them to full-text search instead. Query does
    not use this dispatcher: its reference-only routes still call select().
    """
    if not text or len(text) > max_length:
        return False
    if _EXPLICIT_COORDINATE.search(text.strip()) is None:
        return False
    return bible.valid_reference(text, translation)
