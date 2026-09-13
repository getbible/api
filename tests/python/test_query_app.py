from __future__ import annotations

import json
import unittest
from dataclasses import replace
from unittest.mock import patch
from urllib.parse import unquote

from getbible_api_common.settings import LibrarianSettings, ServiceSettings
from getbible_query_api.app import create_app
from getbible_query_api.config import Settings

from tests.python.support import FIXTURE_REPOSITORY, EndpointCase


class QueryAppTest(EndpointCase, unittest.TestCase):
    def make_app(self):
        settings = Settings(
            librarian=LibrarianSettings(repository=FIXTURE_REPOSITORY, cache_dir=self.cache_dir),
            service=ServiceSettings(prefix="QUERY", default_translation="test", trust_proxy=False, app_log=self.app_log),
            default_reference="Ge1:1",
        )
        return create_app(settings)

    def test_canonical_route_returns_the_librarian_object(self) -> None:
        response = self.client.get("/v2/test/Ge1:1")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content_type, "application/json; charset=utf-8")
        chapter = response.get_json()["test_1_1"]
        self.assertEqual(chapter["ref"], ["Ge1:1"])
        self.assertEqual(chapter["verses"][0]["name"], "Genesis 1:1")
        self.assertIn("max-age=2592000", response.headers["Cache-Control"])
        self.assertIn("ETag", response.headers)

    def test_conditional_request_answers_304(self) -> None:
        first = self.client.get("/v2/test/Ge1:1")
        second = self.client.get("/v2/test/Ge1:1", headers={"If-None-Match": first.headers["ETag"]})
        self.assertEqual(second.status_code, 304)
        self.assertEqual(second.data, b"")
        self.assertEqual(second.headers["ETag"], first.headers["ETag"])
        self.assertEqual(second.headers["Cache-Control"], first.headers["Cache-Control"])
        self.assertEqual(json.loads(unquote(second.headers["X-GetBible-Telemetry-Books"])), [1])
        self.assertEqual(second.headers["X-GetBible-Telemetry-Operation"], "scripture")

    def test_head_and_changed_scripture_preserve_validator_semantics(self) -> None:
        path = "/v2/test/Ge1:1"
        first = self.client.get(path)
        head = self.client.head(path)
        self.assertEqual(head.status_code, 200)
        self.assertEqual(head.data, b"")
        self.assertEqual(head.headers["ETag"], first.headers["ETag"])
        self.assertEqual(head.headers["Cache-Control"], first.headers["Cache-Control"])
        changed = first.get_json()
        changed["test_1_1"]["verses"][0]["text"] = "Updated scripture fixture."
        with patch.object(self.app.extensions["getbible"], "select", return_value=changed):
            refreshed = self.client.get(path, headers={"If-None-Match": first.headers["ETag"]})
        self.assertEqual(refreshed.status_code, 200)
        self.assertEqual(refreshed.get_json(), changed)
        self.assertNotEqual(refreshed.headers["ETag"], first.headers["ETag"])

    def test_cache_metadata_is_readable_by_cross_origin_clients(self) -> None:
        for path in ("/v2/test/Ge1:1", "/v2/test/nonsense", "/healthz"):
            with self.subTest(path=path):
                response = self.client.get(path, headers={"Origin": "https://reader.example"})
                exposed = {header.strip() for header in response.headers["Access-Control-Expose-Headers"].split(",")}
                self.assertTrue({"ETag", "Cache-Control", "Last-Modified", "Age", "Retry-After", "CF-Cache-Status"} <= exposed)

    def test_health_and_problems_are_not_cacheable(self) -> None:
        for path in ("/healthz", "/readyz", "/v2/test/nonsense", "/v2/nope/Ge1:1"):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertNotIn("ETag", response.headers)

    def test_multiple_references_are_joined(self) -> None:
        response = self.client.get("/v2/test/Ge1:1;Ge1:2")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.get_json()["test_1_1"]["verses"]), 2)

    def test_bad_reference_is_a_problem_document(self) -> None:
        response = self.client.get("/v2/test/nonsense")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.content_type, "application/problem+json; charset=utf-8")
        body = response.get_json()
        self.assertEqual(body["code"], "invalid_reference")
        self.assertEqual(body["status"], 404)
        self.assertTrue(body["detail"])
        self.assertTrue(body["instance"].startswith("urn:request:"))
        self.assertEqual(body["type"], "https://getbible.net/problems/invalid-reference")

    def test_one_bad_reference_in_a_chain_rejects_the_request(self) -> None:
        self.assertEqual(self.client.get("/v2/test/Ge1:1;bad").status_code, 404)

    def test_unknown_translation_and_version(self) -> None:
        self.assertEqual(self.client.get("/v2/nope/Ge1:1").get_json()["code"], "translation_not_found")
        self.assertEqual(self.client.get("/v1/test/Ge1:1").get_json()["code"], "unknown_version")

    def test_query_strings_are_rejected(self) -> None:
        response = self.client.get("/v2/test/Ge1:1?x=1")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["code"], "parameters_not_accepted")

    def test_valid_short_forms_keep_default_translation_and_version(self) -> None:
        cases = {
            "/Ge1:1": "/v2/test/Ge1:1",
            "/v2/Ge1:2": "/v2/test/Ge1:2",
            "/test/Ge1:2": "/v2/test/Ge1:2",
        }
        for path, location in cases.items():
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 301)
                self.assertEqual(response.headers["Location"], location)
                self.assertEqual(response.headers["Cache-Control"], "public, max-age=300")

    def test_missing_references_never_select_default_scripture(self) -> None:
        bible = self.app.extensions["getbible"]
        for path in ("/", "/v2", "/v2/", "/test", "/test/", "/v2/test", "/v2/test/"):
            with self.subTest(path=path), patch.object(bible, "select") as select:
                response = self.client.get(path)
                self.assertEqual(response.status_code, 404)
                self.assertEqual(response.get_json()["code"], "missing_reference")
                self.assertNotIn("Location", response.headers)
                self.assertNotIn("ETag", response.headers)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                select.assert_not_called()
                entry = json.loads(self.log_lines()[-1])
                self.assertEqual(entry["status"], 404)
                self.assertEqual(entry["problem"], "missing_reference")

    def test_unresolved_references_log_404_without_redirects(self) -> None:
        for reference in ("nonsense", "Ge999:1", "Ge1:999", "Ge1:1;bad", "x" * 513):
            for prefix in ("/", "/v2/", "/test/", "/v2/test/"):
                with self.subTest(reference=reference, prefix=prefix):
                    response = self.client.get(prefix + reference)
                    self.assertEqual(response.status_code, 404)
                    self.assertIn(response.get_json()["code"], {"invalid_reference", "not_found"})
                    self.assertNotIn("Location", response.headers)
                    self.assertNotIn("ETag", response.headers)
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    entry = json.loads(self.log_lines()[-1])
                    self.assertEqual(entry["status"], 404)
                    self.assertEqual(entry["problem"], response.get_json()["code"])
                    self.assertEqual(entry["reference"], reference)

    def test_empty_results_are_404_in_canonical_and_short_forms(self) -> None:
        for result in ({}, {"test_1_1": {"verses": []}}):
            with patch.object(self.app.extensions["getbible"], "select", return_value=result):
                for path in ("/Ge1:1", "/v2/Ge1:1", "/test/Ge1:1", "/v2/test/Ge1:1"):
                    with self.subTest(result=result, path=path):
                        response = self.client.get(path)
                        self.assertEqual(response.status_code, 404)
                        self.assertEqual(response.get_json()["code"], "invalid_reference")
                        self.assertNotIn("Location", response.headers)

    def test_explicit_unknown_translation_is_not_replaced(self) -> None:
        for path in ("/nope/Ge1:1", "/v2/nope/Ge1:1"):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 404)
                self.assertEqual(response.get_json()["code"], "translation_not_found")
                self.assertNotIn("Location", response.headers)

    def test_king_james_remains_the_default_for_reference_only_requests(self) -> None:
        settings = self.app.extensions["settings"]
        app = create_app(replace(settings, service=replace(settings.service, default_translation="kjv")))
        self.addCleanup(app.extensions["getbible"].close)
        bible = app.extensions["getbible"]
        result = {"kjv_1_1": {"verses": [{"verse": 1, "text": "Requested scripture."}]}}
        with patch.object(bible, "valid_translation", return_value=False), patch.object(bible, "select", return_value=result) as select:
            for path in ("/Ge1:1", "/v2/Ge1:1"):
                with self.subTest(path=path):
                    response = app.test_client().get(path)
                    self.assertEqual(response.status_code, 301)
                    self.assertEqual(response.headers["Location"], "/v2/kjv/Ge1:1")
                    select.assert_called_with("Ge1:1", "kjv")

    def test_unknown_version_prefix_is_not_redirected(self) -> None:
        self.assertEqual(self.client.get("/v9").status_code, 404)
        self.assertEqual(self.client.get("/v9/test").status_code, 404)

    def test_methods_and_unknown_routes(self) -> None:
        self.assertEqual(self.client.post("/v2/test/Ge1:1").get_json()["code"], "method_not_allowed")
        self.assertEqual(self.client.get("/a/b/c/d").get_json()["code"], "not_found")

    def test_health_and_readiness(self) -> None:
        self.assertEqual(self.client.get("/healthz").get_json(), {"status": "ok"})
        self.assertEqual(self.client.get("/readyz").get_json(), {"status": "ready"})

    def test_readiness_requires_readable_scripture_not_only_metadata(self) -> None:
        bible = self.app.extensions["getbible"]
        with patch.object(bible, "valid_translation", return_value=True), \
             patch.object(bible, "select", side_effect=OSError("chapter unavailable")):
            response = self.client.get("/readyz")
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.mimetype, "application/problem+json")
            self.assertEqual(response.get_json()["code"], "readiness_failed")
            self.assertEqual(response.get_json()["status"], 503)
            self.assertEqual(response.headers["Retry-After"], "5")
            self.assertEqual(self.client.get("/healthz").status_code, 200)

    def test_token_endpoint_never_advertises_shared_caching(self) -> None:
        settings = self.app.extensions["settings"]
        app = create_app(replace(settings, service=replace(settings.service, access_mode="token")))
        self.addCleanup(app.extensions["getbible"].close)
        client = app.test_client()
        for path in ("/", "/v2/test/Ge1:1", "/v2/test/nonsense"):
            with self.subTest(path=path):
                response = client.get(path)
                self.assertEqual(response.headers["Cache-Control"], "private, no-store")
                self.assertEqual(response.headers["CDN-Cache-Control"], "no-store")

    def test_security_headers_and_request_id(self) -> None:
        response = self.client.get("/v2/test/Ge1:1", headers={"X-Request-ID": "trace-1", "X-GetBible-Token-Id": "tk_abc",
                                   "Referer": "https://reader.example/page", "User-Agent": "Reader Test"})
        self.assertEqual(response.headers["X-Request-ID"], "trace-1")
        self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")
        entry = json.loads(self.log_lines()[-1])
        self.assertEqual(entry["reference"], "Ge1:1")
        self.assertEqual(entry["translation"], "test")
        self.assertEqual(entry["token"], "tk_abc")
        self.assertEqual(entry["verses"], 1)
        self.assertEqual(entry["endpoint_kind"], "query")
        self.assertEqual(entry["referrer"], "https://reader.example/page")
        self.assertEqual(entry["user_agent"], "Reader Test")
        self.assertEqual(response.headers["X-GetBible-Telemetry-Translation"], "test")

    def test_invalid_request_id_is_replaced(self) -> None:
        response = self.client.get("/healthz", headers={"X-Request-ID": "bad id"})
        self.assertNotEqual(response.headers["X-Request-ID"], "bad id")

    def test_internal_errors_are_not_disclosed(self) -> None:
        from unittest.mock import patch
        bible = self.app.extensions["getbible"]
        with patch.object(bible, "select", side_effect=RuntimeError("secret path")):
            response = self.client.get("/v2/test/Ge1:1")
        self.assertEqual(response.status_code, 500)
        self.assertNotIn("secret path", response.get_data(as_text=True))


if __name__ == "__main__":
    unittest.main()
