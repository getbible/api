"""HTTP routing for endpoints configured with the selected local API version."""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from getbible_query_api.app import create_app as query_app
from getbible_search_api.app import create_app as search_app

from tests.python.support import FIXTURE_REPOSITORY


class RuntimeVersionTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        # The shared fixture hierarchy is enough to exercise version selection;
        # the librarian owns parsing and preservation of the source verse data.
        shutil.copytree(Path(FIXTURE_REPOSITORY) / "v2", self.root / "v3")

    def app(self, kind: str):
        environment = {
            "GETBIBLE_REPOSITORY": str(self.root),
            "GETBIBLE_VERSION": "v3",
            "GETBIBLE_CACHE_DIR": str(self.root / "cache" / kind),
            "GETBIBLE_APP_LOG": str(self.root / f"{kind}.log"),
            "QUERY_DEFAULT_TRANSLATION": "test",
            "SEARCH_DEFAULT_TRANSLATION": "test",
            "QUERY_DEFAULT_REFERENCE": "Ge1:1",
        }
        with patch.dict("os.environ", environment, clear=True):
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
