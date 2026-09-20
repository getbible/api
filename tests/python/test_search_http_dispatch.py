"""Exercise search/reference dispatch through real routes and the librarian."""

from __future__ import annotations

import json
import shutil
import unittest
from dataclasses import replace
from pathlib import Path
from urllib.parse import quote

from getbible_api_common.settings import LibrarianSettings, ServiceSettings
from getbible_query_api.app import create_app as query_app
from getbible_query_api.config import Settings as QuerySettings
from getbible_search_api.app import create_app as search_app
from getbible_search_api.config import Settings as SearchSettings

from tests.python.support import EndpointCase, FIXTURE_REPOSITORY


class SearchHTTPDispatchCase(EndpointCase):
    """Use a small, consistent local corpus; never fetch a production Bible."""

    def make_app(self):
        repository = Path(self.temporary.name) / "repository"
        source = repository / self.version
        shutil.copytree(Path(FIXTURE_REPOSITORY) / "v2", source)
        corpus_path = source / "test.json"
        chapter_path = source / "test" / "1" / "1.json"
        corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
        chapter = json.loads(chapter_path.read_text(encoding="utf-8"))
        # Book aliases intentionally appear in verse text too. Two hits let us
        # distinguish paginated word searches from an implicit first verse.
        for index in range(2):
            text = "A man left a mark; Job records acts. 1 John and 43 are labels."
            corpus["books"][0]["chapters"][0]["verses"][index]["text"] = text
            chapter["verses"][index]["text"] = text
        corpus_path.write_text(json.dumps(corpus), encoding="utf-8")
        chapter_path.write_text(json.dumps(chapter), encoding="utf-8")
        return search_app(SearchSettings(
            librarian=LibrarianSettings(
                repository=str(repository), version=self.version, cache_dir=self.cache_dir,
            ),
            service=ServiceSettings(
                prefix="SEARCH", default_translation="test", trust_proxy=False,
                app_log=self.app_log,
            ),
        ))

    def responses(self, text, **filters):
        """Cover path, query-string and JSON-body input with default translation."""
        for method in ("GET", "POST"):
            for path in (
                f"/{self.version}/test/{quote(text, safe='')}",
                f"/{self.version}/test",
                f"/{self.version}",
            ):
                values = {"q": text, **filters}
                kwargs = {"query_string" if method == "GET" else "json": values}
                yield method, path, self.client.open(path, method=method, **kwargs)

    def test_bare_aliases_are_paginated_word_searches_on_every_route(self):
        cases = (
            ("whole_word", ("man", "Mark", "Job", "Acts", "1 John", "43")),
            ("substring", ("man", "Mark", "Job", "Acts")),
        )
        for match, texts in cases:
            for text in texts:
                for method, path, response in self.responses(text, match=match, limit=1, offset=1):
                    with self.subTest(text=text, match=match, method=method, path=path):
                        self.assertEqual(response.status_code, 200, response.get_json())
                        body = response.get_json()
                        self.assertEqual(body["query"]["kind"], "search")
                        self.assertEqual(body["query"]["total"], 2)
                        self.assertEqual(body["query"]["returned"], 1)
                        self.assertEqual(body["query"]["offset"], 1)
                        self.assertEqual(body["query"]["criteria"]["match"], match)
                        self.assertEqual(body["matches"][0]["verse"], 2)

    def test_a_bare_book_with_no_text_matches_returns_an_empty_search(self):
        for method, path, response in self.responses("Genesis"):
            with self.subTest(method=method, path=path):
                self.assertEqual(response.status_code, 200, response.get_json())
                body = response.get_json()
                self.assertEqual(body["query"]["kind"], "search")
                self.assertEqual(body["query"]["total"], 0)
                self.assertEqual(body["matches"], [])

    def test_explicit_coordinates_still_select_scripture_on_every_route(self):
        for text in ("Ge1", "Genesis 1:1", "Gen１:１"):
            for method, path, response in self.responses(text):
                with self.subTest(text=text, method=method, path=path):
                    self.assertEqual(response.status_code, 200, response.get_json())
                    body = response.get_json()
                    self.assertEqual(body["query"]["kind"], "reference")
                    self.assertEqual(body["matches"][0]["reference"], "Genesis 1:1")
                    self.assertNotIn("criteria", body["query"])

    def test_unavailable_explicit_references_do_not_fall_back_to_word_search(self):
        for text in ("Man1:1", "Genesis999:1"):
            for method, path, response in self.responses(text):
                with self.subTest(text=text, method=method, path=path):
                    self.assertEqual(response.status_code, 404, response.get_json())
                    self.assertEqual(response.mimetype, "application/problem+json")
                    self.assertEqual(response.get_json()["code"], "not_found")

    def test_missing_verse_in_an_existing_chapter_remains_a_reference_error(self):
        for method, path, response in self.responses("Genesis1:999"):
            with self.subTest(method=method, path=path):
                self.assertEqual(response.status_code, 400, response.get_json())
                self.assertEqual(response.mimetype, "application/problem+json")
                self.assertEqual(response.get_json()["code"], "invalid_reference")

    def test_bare_aliases_cannot_bypass_full_text_filter_validation(self):
        for text, filters in (("Job", {"limit": 0}), ("43", {"match": "substring"})):
            for method, path, response in self.responses(text, **filters):
                with self.subTest(text=text, method=method, path=path):
                    self.assertEqual(response.status_code, 400, response.get_json())
                    self.assertEqual(response.get_json()["code"], "invalid_search")

    def test_query_endpoint_keeps_its_reference_only_behavior(self):
        settings = self.app.extensions["settings"]
        app = query_app(QuerySettings(
            librarian=settings.librarian,
            service=replace(settings.service, prefix="QUERY"),
            default_reference="Ge1:1",
        ))
        self.addCleanup(app.extensions["getbible"].close)
        response = app.test_client().get(f"/{self.version}/test/Genesis")
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertEqual(response.get_json()["test_1_1"]["verses"][0]["name"], "Genesis 1:1")


class SearchHTTPDispatchV2Test(SearchHTTPDispatchCase, unittest.TestCase):
    version = "v2"


class SearchHTTPDispatchV3Test(SearchHTTPDispatchCase, unittest.TestCase):
    version = "v3"


if __name__ == "__main__":
    unittest.main()
