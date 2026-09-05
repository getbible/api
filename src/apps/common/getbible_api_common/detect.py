"""Tell a version, a translation and a reference apart, using the librarian."""

from __future__ import annotations

import re

from getbible import GetBible

from .settings import valid_translation_code, valid_version

_VERSION_LIKE = re.compile(r"v[0-9]+")


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
    if not text or len(text) > max_length:
        return False
    return bible.valid_reference(text, translation)
