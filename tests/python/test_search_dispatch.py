"""Search intent must not let bare book aliases consume ordinary word queries."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from getbible import GetBible, RequestLimitError
from getbible_api_common import detect


class SearchReferenceDispatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bible = GetBible(
            repo_path=self.temporary.name,
            cache_dir=str(Path(self.temporary.name) / "cache"),
        )
        self.addCleanup(self.bible.close)

    def test_bare_aliases_remain_full_text_even_when_the_librarian_accepts_them(self) -> None:
        # These cover ordinary words, abbreviations, numbered names and a
        # numeric book. None explicitly supplies a chapter or verse.
        for text in ("man", "Mark", "Job", "Acts", "Genesis", "Ge", "1John", "1 John", "43"):
            for spelling in (text, text.upper(), f" {text} "):
                with self.subTest(text=spelling):
                    self.assertTrue(self.bible.valid_reference(spelling, "kjv"))
                    self.assertFalse(detect.is_reference(self.bible, spelling, "kjv", 200))

    def test_explicit_coordinates_keep_the_existing_librarian_reference_path(self) -> None:
        for text in (
            "John 3", "John 3:16", "John3:16-18", "John3:16,18", "Ge1",
            "1John3:16", "1 John 3:16", "43 3:16", "John:16", "Gen１:１",
        ):
            with self.subTest(text=text):
                self.assertTrue(detect.is_reference(self.bible, text, "kjv", 200))

    def test_coordinate_hint_does_not_replace_librarian_validation(self) -> None:
        for text in ("nonsense123", "faith 3", "John0:1", "John3:0", "John3:2-1"):
            with self.subTest(text=text):
                self.assertFalse(detect.is_reference(self.bible, text, "kjv", 200))

    def test_absent_book_and_out_of_range_chapter_still_take_reference_path(self) -> None:
        # Data availability is checked by select(), not by changing a failed
        # explicit reference into an unrelated full-text search.
        for text in ("Man1:1", "John999:1"):
            with self.subTest(text=text):
                self.assertTrue(detect.is_reference(self.bible, text, "kjv", 200))

    def test_plain_text_and_oversized_requests_do_not_call_the_parser(self) -> None:
        bible = Mock(spec=GetBible)
        for text in ("", "love and hope", "1 John", "John 3:16" + " " * 200):
            with self.subTest(text=text):
                self.assertFalse(detect.is_reference(bible, text, "kjv", 200))
        bible.valid_reference.assert_not_called()

    def test_translation_and_parser_limits_are_preserved(self) -> None:
        bible = Mock(spec=GetBible)
        bible.valid_reference.return_value = True
        self.assertTrue(detect.is_reference(bible, "Ge1:1", "aov", 200))
        bible.valid_reference.assert_called_once_with("Ge1:1", "aov")
        bible.valid_reference.side_effect = RequestLimitError("reference limit exceeded")
        with self.assertRaises(RequestLimitError):
            detect.is_reference(bible, "Ge1:1-999", "aov", 200)

    def test_dispatch_is_independent_of_the_selected_runtime_version(self) -> None:
        for version in ("v2", "v3"):
            with self.subTest(version=version):
                bible = GetBible(
                    repo_path=self.temporary.name,
                    version=version,
                    cache_dir=str(Path(self.temporary.name) / version),
                )
                try:
                    self.assertFalse(detect.is_reference(bible, "man", "kjv", 200))
                    self.assertTrue(detect.is_reference(bible, "Ge1:1", "kjv", 200))
                finally:
                    bible.close()


if __name__ == "__main__":
    unittest.main()
