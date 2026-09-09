"""Runtime deployment consumes trusted local mirrors exclusively."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from getbible_api_common.bible import query_client
from getbible_api_common.settings import LibrarianSettings


class LocalRepositoryTests(unittest.TestCase):
    def test_remote_and_relative_repositories_are_rejected(self):
        for repository in ("https://api.getbible.net", "http://api.getbible.net", "mirror", ""):
            with self.subTest(repository=repository), self.assertRaisesRegex(ValueError, "absolute local path"):
                LibrarianSettings(repository=repository)

    def test_missing_version_is_rejected_before_client_construction(self):
        with tempfile.TemporaryDirectory() as repository:
            settings = LibrarianSettings(repository=repository)
            with patch("getbible_api_common.bible.GetBible") as client:
                with self.assertRaisesRegex(ValueError, "sync the static endpoint first"):
                    query_client(settings, reference_cache_limit=16, chapter_cache_limit=16,
                                 max_references=10, max_total_verses=100)
                client.assert_not_called()

    def test_local_client_does_not_require_checksum_files(self):
        with tempfile.TemporaryDirectory() as repository:
            Path(repository, "v2").mkdir()
            with patch.dict(os.environ, {
                "GETBIBLE_REPOSITORY": repository,
                "GETBIBLE_VERSION": "v2",
            }, clear=True):
                settings = LibrarianSettings.from_environment(repository + "/cache")
            self.assertTrue(settings.is_local)
            with patch("getbible_api_common.bible.GetBible") as client:
                query_client(settings, reference_cache_limit=16, chapter_cache_limit=16,
                             max_references=10, max_total_verses=100)
                self.assertEqual(client.call_args.kwargs["repo_path"], repository)
                self.assertFalse(client.call_args.kwargs["require_checksums"])


if __name__ == "__main__":
    unittest.main()
