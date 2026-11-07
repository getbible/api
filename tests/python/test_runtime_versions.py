"""HTTP routing for endpoints configured with the selected local API version."""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

from getbible_query_api.app import create_app as query_app
from getbible_query_api.check import main as query_check
from getbible_search_api.app import create_app as search_app
from getbible_search_api.check import main as search_check

from tests.python.support import FIXTURE_REPOSITORY


class RuntimeVersionTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        # The shared fixture hierarchy is enough to exercise version selection;
        # the librarian owns parsing and preservation of the source verse data.
        shutil.copytree(Path(FIXTURE_REPOSITORY) / "v2", self.root / "v3")

    def environment(self, kind: str, repository: Path | None = None) -> dict[str, str]:
        repository = repository or self.root
        return {
            "GETBIBLE_REPOSITORY": str(repository),
            "GETBIBLE_VERSION": "v3",
            "GETBIBLE_CACHE_DIR": str(repository / "cache" / kind),
            "GETBIBLE_APP_LOG": str(repository / f"{kind}.log"),
            "QUERY_DEFAULT_TRANSLATION": "test",
            "SEARCH_DEFAULT_TRANSLATION": "test",
            "QUERY_DEFAULT_REFERENCE": "Ge1:1",
        }

    def app(self, kind: str, repository: Path | None = None):
        with patch.dict("os.environ", self.environment(kind, repository), clear=True):
            app = (query_app if kind == "query" else search_app)()
        self.addCleanup(app.extensions["getbible"].close)
        app.testing = True
        self.assertEqual(app.extensions["settings"].librarian.version, "v3")
        return app.test_client()

    def test_query_routes_and_redirects_use_selected_version(self) -> None:
        client = self.app("query")
        self.assertEqual(client.get("/v3/test/Ge1:1").status_code, 200)
        self.assertEqual(client.get("/Ge1:1").headers["Location"], "/v3/test/Ge1:1")
        self.assertEqual(client.get("/v3/Ge1:1").headers["Location"], "/v3/test/Ge1:1")
        self.assertEqual(client.get("/test/Ge1:1").headers["Location"], "/v3/test/Ge1:1")
        for path in ("/", "/v3", "/test", "/v3/test", "/nonsense", "/v3/nonsense", "/v3/test/nonsense"):
            with self.subTest(path=path):
                response = client.get(path)
                self.assertEqual(response.status_code, 404)
                self.assertEqual(response.mimetype, "application/problem+json")
                self.assertNotIn("Location", response.headers)
        self.assertEqual(client.get("/v2/test/Ge1:1").get_json()["code"], "unknown_version")
        self.assertEqual(client.get("/readyz").status_code, 200)

    def test_nested_v3_metadata_survives_startup_warming_and_http(self) -> None:
        baseline = self.app("query").get("/v3/test/Ge1:1").get_json()
        search_baseline = self.app("search").get("/v3/test/beginning").get_json()["results"]
        for depth in (9, 72):
            repository = self.root / f"depth-{depth}"
            shutil.copytree(self.root / "v3", repository / "v3")
            nested = "Synthetic source annotation"
            for level in range(depth):
                nested = {"content": nested} if level % 2 else [nested]

            translation_path = repository / "v3/test.json"
            chapter_path = repository / "v3/test/1/1.json"
            translation = json.loads(translation_path.read_text())
            chapter = json.loads(chapter_path.read_text())
            for value in (translation["books"][0]["chapters"][0], chapter):
                value["editorial"] = nested
                value["verses"][0]["annotations"] = nested
            for path, payload in ((translation_path, translation), (chapter_path, chapter)):
                raw = json.dumps(payload).encode("utf-8")
                path.write_bytes(raw)
                path.with_suffix(".sha").write_text(hashlib.sha1(raw, usedforsecurity=False).hexdigest())

            expected = deepcopy(baseline)
            expected["test_1_1"]["verses"][0]["annotations"] = nested
            expected_search = deepcopy(search_baseline)
            expected_search["test_1_1"]["verses"][0]["annotations"] = nested
            for kind, check in (("query", query_check), ("search", search_check)):
                with self.subTest(depth=depth, kind=kind):
                    environment = self.environment(kind, repository)
                    environment["SEARCH_WARM_TRANSLATIONS"] = "test"
                    with patch.dict("os.environ", environment, clear=True), redirect_stdout(io.StringIO()):
                        self.assertEqual(check(), 0)

                    client = self.app(kind, repository)
                    control = client.application.extensions["getbible_control"]
                    # Exercise the same source refresh and warm path used by
                    # Gunicorn before workers fork, using only synthetic data.
                    control.refresh_source(force=True)
                    self.assertEqual(control.warm("test")["abbreviation"], "test")
                    self.assertEqual(client.get("/readyz").status_code, 200)
                    response = client.get("/v3/test/Ge1:1")
                    self.assertEqual(response.status_code, 200)
                    body = response.get_json()
                    self.assertEqual(body if kind == "query" else body["results"], expected)
                    if kind == "search":
                        self.assertEqual(client.get("/probez").status_code, 200)
                        response = client.get("/v3/test/beginning")
                        self.assertEqual(response.status_code, 200)
                        self.assertEqual(set(response.get_json()), {"query", "results", "matches"})
                        self.assertEqual(response.get_json()["query"]["kind"], "search")
                        self.assertEqual(response.get_json()["results"], expected_search)

    def test_deep_v3_annotations_survive_source_refresh_and_http(self) -> None:
        depth = 600
        annotation = "Synthetic refreshed annotation"
        for level in range(depth):
            annotation = {"content": annotation} if level % 2 else [annotation]

        for kind in ("query", "search"):
            with self.subTest(kind=kind):
                repository = self.root / f"refreshed-{kind}"
                shutil.copytree(self.root / "v3", repository / "initial")
                shutil.copytree(self.root / "v3", repository / "refreshed")
                (repository / "v3").symlink_to("initial", target_is_directory=True)
                client = self.app(kind, repository)
                control = client.application.extensions["getbible_control"]
                control.refresh_source(force=True)
                self.assertEqual(control.warm("test")["abbreviation"], "test")
                paths = ["/v3/test/Ge1:1"]
                if kind == "search":
                    paths.append("/v3/test/beginning")
                baseline = {}
                for path in paths:
                    response = client.get(path)
                    self.assertEqual(response.status_code, 200)
                    baseline[path] = response.get_json()

                translation_path = repository / "refreshed/test.json"
                chapter_path = repository / "refreshed/test/1/1.json"
                translation = json.loads(translation_path.read_text())
                chapter = json.loads(chapter_path.read_text())
                for value in (translation["books"][0]["chapters"][0], chapter):
                    value["verses"][0]["annotations"] = annotation
                for path, payload in ((translation_path, translation), (chapter_path, chapter)):
                    raw = json.dumps(payload).encode("utf-8")
                    path.write_bytes(raw)
                    path.with_suffix(".sha").write_text(hashlib.sha1(raw, usedforsecurity=False).hexdigest())

                # Publish new source data over an already warmed, usable cache,
                # as the static publisher does when replacing its version link.
                replacement = repository / "next"
                replacement.symlink_to("refreshed", target_is_directory=True)
                replacement.replace(repository / "v3")
                self.assertTrue(control.refresh_source(force=True))
                self.assertEqual(control.warm("test")["abbreviation"], "test")
                for path in paths:
                    with self.subTest(path=path):
                        response = client.get(path)
                        self.assertEqual(response.status_code, 200)
                        body = response.get_json()
                        results = body if kind == "query" else body["results"]
                        verse = results["test_1_1"]["verses"][0]
                        self.assertIn("annotations", verse)
                        cursor = verse.pop("annotations")
                        # Traverse iteratively so the assertion itself does not
                        # impose deepcopy's recursion limit on valid JSON.
                        for level in reversed(range(depth)):
                            if level % 2:
                                self.assertIsInstance(cursor, dict)
                                self.assertEqual(set(cursor), {"content"})
                                cursor = cursor["content"]
                            else:
                                self.assertIsInstance(cursor, list)
                                self.assertEqual(len(cursor), 1)
                                cursor = cursor[0]
                        self.assertEqual(cursor, "Synthetic refreshed annotation")
                        if kind == "search" and body["query"]["kind"] == "search":
                            expected = baseline[path]["query"]
                            self.assertEqual(body["query"]["sha"], translation_path.with_suffix(".sha").read_text())
                            self.assertNotEqual(body["query"]["sha"], expected["sha"])
                            self.assertGreaterEqual(body["query"]["cache"]["checked_at"], expected["cache"]["checked_at"])
                            expected["sha"] = body["query"]["sha"]
                            expected["cache"]["checked_at"] = body["query"]["cache"]["checked_at"]
                        self.assertEqual(body, baseline[path])
                self.assertEqual(client.get("/readyz").status_code, 200)
                if kind == "search":
                    self.assertEqual(client.get("/probez").status_code, 200)

    def test_search_get_post_and_reference_use_selected_version(self) -> None:
        client = self.app("search")
        for response in (
            client.get("/v3/test/beginning"),
            client.get("/v3/test?q=beginning"),
            client.post("/v3", json={"q": "beginning", "translation": "test"}),
        ):
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.get_json()["query"]["kind"], "search")
        response = client.get("/v3/test/Ge1:1")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["query"]["kind"], "reference")
        self.assertEqual(client.get("/beginning").headers["Location"], "/v3/test/beginning")
        self.assertEqual(client.get("/v2/test/beginning").get_json()["code"], "unknown_version")
        self.assertEqual(client.get("/readyz").status_code, 200)


if __name__ == "__main__":
    unittest.main()
