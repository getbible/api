from __future__ import annotations

import json
import unittest
from dataclasses import replace
from unittest.mock import patch

from getbible_api_common.settings import LibrarianSettings, ServiceSettings
from getbible_search_api.app import create_app
from getbible_search_api.config import Settings

from tests.python.support import FIXTURE_REPOSITORY, EndpointCase


class SearchAppTest(EndpointCase, unittest.TestCase):
    def make_app(self):
        settings = Settings(
            librarian=LibrarianSettings(repository=FIXTURE_REPOSITORY, cache_dir=self.cache_dir),
            service=ServiceSettings(prefix="SEARCH", default_translation="test", trust_proxy=False, app_log=self.app_log,
                                    cache_seconds=60, max_input_length=500),
        )
        return create_app(settings)

    def test_path_search_returns_the_envelope(self) -> None:
        response = self.client.get("/v2/test/beginning")
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(list(body), ["query", "results", "matches"])
        self.assertEqual(body["query"]["kind"], "search")
        self.assertEqual(body["query"]["total"], 1)
        self.assertEqual(body["query"]["translation"]["abbreviation"], "test")
        self.assertIn("max-age=60", response.headers["Cache-Control"])

    def test_filters_by_query_string_and_body(self) -> None:
        by_query = self.client.get("/v2/test/beginning?words=any&limit=5").get_json()
        self.assertEqual(by_query["query"]["criteria"]["words"], "any")
        by_body = self.client.post("/v2/test/beginning", json={"words": "any"}).get_json()
        self.assertEqual(by_body["query"]["criteria"]["words"], "any")

    def test_precedence_path_then_query_then_body(self) -> None:
        body = self.client.post("/v2/test/beginning?words=phrase", json={"words": "any", "q": "zzzz"}).get_json()
        self.assertEqual(body["query"]["text"], "beginning")
        self.assertEqual(body["query"]["criteria"]["words"], "phrase")

    def test_search_string_in_parameter_or_body(self) -> None:
        self.assertEqual(self.client.get("/v2/test?q=beginning").get_json()["query"]["kind"], "search")
        self.assertEqual(self.client.get("/v2?q=beginning&translation=test").get_json()["query"]["kind"], "search")
        self.assertEqual(self.client.post("/v2", json={"q": "beginning", "translation": "test"}).status_code, 200)
        self.assertEqual(self.client.post("/v2/test", json={"q": "beginning"}).status_code, 200)

    def test_missing_search_string(self) -> None:
        response = self.client.get("/v2/test")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["code"], "missing_search")

    def test_reference_typed_as_search_returns_scripture(self) -> None:
        body = self.client.get("/v2/test/Ge1:1").get_json()
        self.assertEqual(body["query"]["kind"], "reference")
        self.assertEqual(body["query"]["translation"]["abbreviation"], "test")
        self.assertEqual(body["matches"][0]["reference"], "Genesis 1:1")
        self.assertIn("test_1_1", body["results"])

    def test_parameter_validation(self) -> None:
        self.assertEqual(self.client.get("/v2/test/beginning?bogus=1").get_json()["code"], "unknown_parameter")
        self.assertEqual(self.client.get("/v2/test/beginning?limit=1&limit=2").get_json()["code"], "repeated_parameter")
        self.assertEqual(self.client.get("/v2/test/beginning?limit=5000").get_json()["code"], "invalid_search")
        self.assertEqual(self.client.post("/v2/test", json={"q": "x", "nope": 1}).get_json()["code"], "unknown_parameter")
        self.assertEqual(self.client.post("/v2/test", json=[1]).get_json()["code"], "invalid_body")
        self.assertEqual(self.client.post("/v2/test", data={"q": "x"}).status_code, 415)

    def test_redirects_to_the_default_translation(self) -> None:
        response = self.client.get("/v2/beginning?limit=3")
        self.assertEqual(response.status_code, 301)
        self.assertEqual(response.headers["Location"], "/v2/test/beginning?limit=3")
        self.assertEqual(self.client.get("/beginning").headers["Location"], "/v2/test/beginning")
        self.assertEqual(self.client.get("/test/beginning").headers["Location"], "/v2/test/beginning")

    def test_post_alias_redirect_preserves_body_and_query_precedence(self) -> None:
        for path in ("/test", "/beginning", "/test/beginning", "/v2/beginning"):
            with self.subTest(path=path):
                response = self.client.post(path + "?limit=1", json={"q": "beginning", "words": "any", "limit": 2})
                self.assertEqual(response.status_code, 308)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                result = self.client.post(path + "?limit=1", json={"q": "beginning", "words": "any", "limit": 2},
                                          follow_redirects=True)
                self.assertEqual(result.status_code, 200)
                criteria = result.get_json()["query"]["criteria"]
                self.assertEqual(criteria["words"], "any")
                self.assertEqual(criteria["limit"], 1)

    def test_encoded_delimiters_stay_in_search_path_on_redirect(self) -> None:
        response = self.client.get("/v2/why%3F%23yes?limit=1")
        self.assertEqual(response.status_code, 301)
        self.assertEqual(response.headers["Location"], "/v2/test/why%3F%23yes?limit=1")
        result = self.client.get("/v2/why%3F%23yes?limit=1", follow_redirects=True)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.get_json()["query"]["text"], "why?#yes")

    def test_readiness_is_cheap_and_explicit_probe_exercises_search(self) -> None:
        bible = self.app.extensions["getbible"]
        with patch.object(bible, "search", wraps=bible.search) as search:
            self.assertEqual(self.client.get("/readyz").status_code, 200)
            search.assert_not_called()
            self.assertEqual(self.client.get("/probez").status_code, 200)
            search.assert_called_once()
        with patch.object(bible, "search", side_effect=OSError("corpus unavailable")):
            response = self.client.get("/probez")
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.mimetype, "application/problem+json")
            self.assertEqual(response.get_json()["code"], "readiness_failed")
            self.assertEqual(response.get_json()["status"], 503)
            self.assertEqual(response.headers["Retry-After"], "5")

    def test_unknown_version_and_translation(self) -> None:
        self.assertEqual(self.client.get("/v1/test/beginning").get_json()["code"], "unknown_version")
        self.assertEqual(self.client.get("/v2/nope/beginning").get_json()["code"], "translation_not_found")
        self.assertEqual(self.client.get("/v2?q=beginning&translation=nope").status_code, 404)

    def test_post_is_never_cached(self) -> None:
        response = self.client.post("/v2/test", json={"q": "beginning"})
        self.assertEqual(response.headers["Cache-Control"], "no-store")

    def test_root_and_methods(self) -> None:
        self.assertEqual(self.client.get("/").status_code, 404)
        self.assertEqual(self.client.put("/v2/test/x").get_json()["code"], "method_not_allowed")

    def test_search_text_is_logged(self) -> None:
        self.client.get("/v2/test/beginning?limit=2")
        entry = json.loads(self.log_lines()[-1])
        self.assertEqual(entry["search"], "beginning")
        self.assertEqual(entry["kind"], "search")
        self.assertEqual(entry["criteria"]["limit"], 2)
        self.assertEqual(entry["query"], "limit=2")

    def test_capacity_gate_answers_503(self) -> None:
        gate = self.app.extensions["getbible"]
        from getbible_search_api import app as module
        busy = module._Gate(1, 1)
        held = busy.acquire(False)
        with self.assertRaises(module.ProblemError) as raised:
            busy.acquire(False)
        self.assertEqual(raised.exception.status, 503)
        for semaphore in held:
            semaphore.release()
        self.assertIsNotNone(gate)


    def test_all_filters_work_on_every_get_and_post_search_route(self) -> None:
        filters = {
            "words": "all", "match": "whole_word", "case_sensitive": False,
            "scope": "old_testament", "book": ["Genesis"], "books": "1",
            "diacritics": "fold", "exclude": ["zzzz"], "proximity": 0,
            "sort": "relevance", "limit": 2, "offset": 0,
        }
        urls = ("/v2/test/beginning", "/v2/test", "/v2")
        baseline = None
        for path in urls:
            values = {"q": "beginning", "translation": "test", **filters}
            # Query parameters use strings; the JSON form uses native types.
            query = {key: str(value).lower() if isinstance(value, bool) else value
                     for key, value in values.items()}
            for method in ("get", "post_query", "post_body"):
                with self.subTest(path=path, method=method):
                    if method == "post_body":
                        response = self.client.post(path, json=values)
                    elif method == "post_query":
                        response = self.client.post(path, query_string=query)
                    else:
                        response = self.client.get(path, query_string=query)
                    self.assertEqual(response.status_code, 200, response.get_data(as_text=True))
                    body = response.get_json()
                    comparable = (body["query"]["criteria"], body["results"], body["matches"])
                    if baseline is None:
                        baseline = comparable
                    self.assertEqual(comparable, baseline)

    def test_explicit_url_and_body_filters_override_configured_defaults(self) -> None:
        settings = replace(self.app.extensions["settings"], default_criteria={
            "words": "any", "case_sensitive": True, "scope": "new_testament", "limit": 1,
        })
        app = create_app(settings)
        self.addCleanup(app.extensions["getbible"].close)
        client = app.test_client()
        for method in ("get", "post"):
            with self.subTest(method=method):
                values = {"words": "all", "scope": "bible", "case_sensitive": False, "limit": 2, "offset": 0}
                response = (client.get("/v2/test/beginning", query_string={
                    **values, "case_sensitive": "false",
                }) if method == "get" else client.post("/v2/test/beginning", json=values))
                self.assertEqual(response.status_code, 200)
                criteria = response.get_json()["query"]["criteria"]
                for key, value in values.items():
                    self.assertEqual(criteria[key], value)

    def test_busy_response_has_retry_after_header(self) -> None:
        from getbible_search_api.app import ProblemError, _Gate
        busy = _Gate(1, 1)
        held = busy.acquire(False)
        try:
            with self.assertRaises(ProblemError) as raised:
                busy.acquire(False)
        finally:
            for semaphore in held:
                semaphore.release()
        with patch.object(self.app.extensions["getbible"], "search", side_effect=raised.exception):
            response = self.client.get("/v2/test/beginning")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.mimetype, "application/problem+json")
        self.assertEqual(response.headers["Retry-After"], "2")
        self.assertEqual(response.get_json()["code"], "busy")


if __name__ == "__main__":
    unittest.main()
