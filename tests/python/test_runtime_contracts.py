"""Keep generated runtime contracts aligned with real routes and fixture responses.

These checks run in CI against the small librarian fixture; no server startup,
production corpus scan or static-document validation is added.
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from itertools import product
from pathlib import Path

from getbible import SearchBible
from getbible_api_common.settings import LibrarianSettings, ServiceSettings
from getbible_query_api.app import create_app as query_app
from getbible_query_api.config import Settings as QuerySettings
from getbible_search_api.app import ALLOWED_KEYS, create_app as search_app
from getbible_search_api.config import Settings as SearchSettings

from tests.python.support import EndpointCase, FIXTURE_REPOSITORY

ROOT = Path(__file__).resolve().parents[2]


def contract(kind: str, root: bool = False, token: bool = False, version: str = "v2") -> dict:
    variables = {
        "DOMAIN": "api.example.test", "VERSION": version,
        "PREFIX": "/" if root else f"/{version}/",
        "VERSION_PATH": "/" if root else f"/{version}",
        "DEFAULT_TRANSLATION": "test", "DEFAULT_REFERENCE": "Ge1:1",
        "IS_ROOT": str(root).lower(), "TOKEN_REQUIRED": str(token).lower(),
    }
    rendered = subprocess.run(
        [sys.executable, str(ROOT / "src/bin/getbible-render"),
         str(ROOT / "src/apps" / kind / "openapi.json.tmpl"),
         *[f"{key}={value}" for key, value in variables.items()]],
        text=True, capture_output=True, check=True,
    ).stdout
    return json.loads(rendered)


class ContractTest(unittest.TestCase):
    def test_all_rendered_contracts_resolve_local_references_and_public_health(self) -> None:
        for kind in ("query", "search"):
            for root, version in product((False, True), ("v2", "v3")):
                for token in (False, True):
                    with self.subTest(kind=kind, root=root, token=token, version=version):
                        doc = contract(kind, root, token, version)
                        self.assertEqual(doc["openapi"], "3.1.0")
                        self.assertEqual(doc["info"]["version"], version)
                        self.assertEqual(doc.get("security", []), [{"bearer": []}] if token else [])
                        for path in ("/healthz", "/readyz", ("/" if root else f"/{version}/") + "openapi.json"):
                            self.assertEqual(doc["paths"][path]["get"]["security"], [])
                        self.assertNotIn("/probez", doc["paths"])

                        def walk(value):
                            if isinstance(value, dict):
                                if "$ref" in value:
                                    target = doc
                                    for part in value["$ref"].removeprefix("#/").split("/"):
                                        target = target[part]
                                for child in value.values():
                                    walk(child)
                            elif isinstance(value, list):
                                for child in value:
                                    walk(child)

                        walk(doc)
                        operation_ids = []
                        for path, entry in doc["paths"].items():
                            for method in ("get", "post"):
                                if method not in entry:
                                    continue
                                op = entry[method]
                                operation_ids.append(op["operationId"])
                                params = entry.get("parameters", []) + op.get("parameters", [])
                                declared = {p["name"] for p in params if p.get("in") == "path"}
                                from re import findall
                                self.assertEqual(declared, set(findall(r"{([^}]+)}", path)))
                        self.assertEqual(len(operation_ids), len(set(operation_ids)))

    def test_every_search_form_documents_every_supported_filter_for_both_methods(self) -> None:
        for root, version in product((False, True), ("v2", "v3")):
            doc = contract("search", root, version=version)
            prefix = "/" if root else f"/{version}/"
            for path in (prefix + "{translation}/{search}", prefix + "{translation}", "/" if root else f"/{version}"):
                for method in ("get", "post"):
                    entry = doc["paths"][path]
                    op = entry[method]
                    parameters = entry.get("parameters", []) + op.get("parameters", [])
                    resolved = [doc["components"]["parameters"][p["$ref"].rsplit("/", 1)[-1]]
                                if "$ref" in p else p for p in parameters]
                    self.assertEqual({p["name"] for p in resolved if p["in"] == "query"}, ALLOWED_KEYS)
                    self.assertTrue({"200", "400", "401", "404", "429", "500", "503"} <= set(op["responses"]))
                    if method == "post":
                        self.assertFalse(op["requestBody"]["required"])
                        self.assertIn("415", op["responses"])
                    else:
                        self.assertNotIn("requestBody", op)
                        self.assertIn("304", op["responses"])

    def test_documented_defaults_match_the_librarian(self) -> None:
        doc = contract("search")
        params = doc["components"]["parameters"]
        for key, value in SearchBible.from_value({}).to_dict().items():
            if key in params and "default" in params[key]["schema"]:
                self.assertEqual(params[key]["schema"]["default"], value)
        settings = SearchSettings(librarian=LibrarianSettings(repository=FIXTURE_REPOSITORY),
                                  service=ServiceSettings(prefix="SEARCH"))
        self.assertEqual(params["limit"]["schema"]["maximum"], settings.max_page_size)
        self.assertEqual(params["offset"]["schema"]["maximum"], settings.max_offset)
        self.assertEqual(params["q"]["schema"]["maxLength"], settings.max_query_length)

    def test_verse_metadata_is_optional_and_allows_source_extensions(self) -> None:
        for kind, version in product(("query", "search"), ("v2", "v3")):
            with self.subTest(kind=kind, version=version):
                schemas = contract(kind, version=version)["components"]["schemas"]
                verse = schemas["Verse"]
                self.assertTrue(verse["additionalProperties"])
                self.assertTrue({"paragraph", "tokens", "spans"} <= verse["properties"].keys())
                self.assertFalse({"paragraph", "tokens", "spans"} & set(verse["required"]))
                self.assertEqual(verse["properties"]["tokens"]["items"]["$ref"],
                                 "#/components/schemas/VerseToken")
                self.assertEqual(verse["properties"]["spans"]["items"]["$ref"],
                                 "#/components/schemas/VerseSpan")
                self.assertTrue(schemas["VerseToken"]["additionalProperties"])
                self.assertTrue(schemas["VerseSpan"]["additionalProperties"])
                self.assertNotIn("editorial", schemas["Scripture"]["additionalProperties"]["properties"])

    def test_documentation_renders_selected_version_and_source_metadata(self) -> None:
        for kind, root, version in product(("query", "search"), (False, True), ("v2", "v3")):
            with self.subTest(kind=kind, root=root, version=version):
                prefix = "/" if root else f"/{version}/"
                variables = {
                    "DOMAIN": "api.example.test", "VERSION": version,
                    "PREFIX": prefix, "VERSION_PATH": "/" if root else f"/{version}",
                    "IS_ROOT": str(root).lower(), "DEFAULT_TRANSLATION": "test",
                    "DEFAULT_REFERENCE": "Ge1:1", "CACHE_SECONDS": "60",
                    "OPENAPI_URL": prefix + "openapi.json", "ACCESS_MODE_LABEL": "Open",
                    "ACCESS_HTML": "<p>Open access</p>", "HEAD_ICONS": "", "CSS": "",
                    "LOGO_URL": "", "ICON_URL": "",
                }
                rendered = subprocess.run(
                    [sys.executable, str(ROOT / "src/bin/getbible-render"),
                     str(ROOT / "src/apps" / kind / "docs.html.tmpl"),
                     *[f"{key}={value}" for key, value in variables.items()]],
                    text=True, capture_output=True, check=True,
                ).stdout
                self.assertNotIn("{{", rendered)
                self.assertIn(f"https://api.getbible.net/{version}/openapi.json", rendered)
                self.assertIn("https://api.example.test" + prefix, rendered)
                self.assertIn("<code>tokens</code>", rendered)
                self.assertIn("<code>spans</code>", rendered)
                self.assertIn("<code>editorial</code>", rendered)


class ResponseContractTest(EndpointCase, unittest.TestCase):
    def make_app(self):
        return search_app(SearchSettings(
            librarian=LibrarianSettings(repository=FIXTURE_REPOSITORY, cache_dir=self.cache_dir),
            service=ServiceSettings(prefix="SEARCH", default_translation="test",
                                    app_log=self.app_log, trust_proxy=False),
        ))

    def assert_described(self, doc: dict, schema: str, value: dict) -> None:
        description = doc["components"]["schemas"][schema]
        self.assertTrue(set(description.get("required", [])) <= value.keys(), (schema, value))
        self.assertTrue(value.keys() <= description["properties"].keys(), (schema, value))

    def test_search_and_reference_response_members_are_described(self) -> None:
        doc = contract("search")
        for text in ("beginning", "Ge1:1"):
            response = self.client.get("/v2/test/" + text)
            self.assertEqual(response.status_code, 200)
            body = response.get_json()
            self.assert_described(doc, "SearchResult", body)
            self.assert_described(doc, "SearchQuery", body["query"])
            if "criteria" in body["query"]:
                self.assert_described(doc, "Criteria", body["query"]["criteria"])
            for match in body["matches"]:
                self.assert_described(doc, "SearchMatch", match)
            for chapter in body["results"].values():
                for verse in chapter["verses"]:
                    self.assert_described(doc, "Verse", verse)

    def test_query_scripture_members_are_described(self) -> None:
        doc = contract("query")
        app = query_app(QuerySettings(
            librarian=LibrarianSettings(repository=FIXTURE_REPOSITORY, cache_dir=self.cache_dir),
            service=ServiceSettings(prefix="QUERY", default_translation="test",
                                    app_log=self.app_log, trust_proxy=False),
            default_reference="Ge1:1",
        ))
        self.addCleanup(app.extensions["getbible"].close)
        response = app.test_client().get("/v2/test/Ge1:1")
        self.assertEqual(response.status_code, 200)
        shape = doc["components"]["schemas"]["Scripture"]["additionalProperties"]
        for chapter in response.get_json().values():
            self.assertTrue(set(shape["required"]) <= chapter.keys())
            self.assertTrue(chapter.keys() <= shape["properties"].keys())
            for verse in chapter["verses"]:
                self.assert_described(doc, "Verse", verse)


if __name__ == "__main__":
    unittest.main()
