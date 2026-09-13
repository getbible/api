"""Stored semantic facts, cached responses, ranking scopes and clean cutover."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src/apps/telemetry"))

from getbible_telemetry import TelemetryStore
from getbible_telemetry.catalog import LocalCatalog
from getbible_telemetry.cli import main
from getbible_telemetry.collector import Collector


class ClassificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.registry = self.root / "endpoints"
        for domain, kind, label in (("api.example", "static", "v2"), ("query.example", "query", "v2"),
                                    ("search.example", "search", "v2"), ("root.example", "search", "root")):
            directory = self.registry / domain
            (directory / "versions").mkdir(parents=True)
            (directory / "endpoint.conf").write_text(f"TYPE={'static' if kind == 'static' else 'runtime'}\nKIND={kind}\nDEFAULT_ENDPOINT={label}\n")
            (directory / "versions" / (label + ".conf")).write_text(f"APP_VERSION=v2\nREPOSITORY={self.data / 'api.example'}\n")
        for code, name in (("kjv", "John"), ("test", "Localized John")):
            directory = self.data / "api.example/v2" / code
            directory.mkdir(parents=True)
            (directory / "books.json").write_text(json.dumps({"43": {"nr": 43, "name": name}, "73": {"nr": 73, "name": "Book Seventy Three"}}))
        self.catalog = LocalCatalog(self.registry, self.data)
        self.path = self.root / "traffic.sqlite3"
        self.store = TelemetryStore(self.path, catalog=self.catalog)
        self.addCleanup(lambda: self.store.close())
        self.sequence = 0

    def append(self, path, *, domain="api.example", source="edge", **extra):
        self.sequence += 1
        record = {"time": 100, "request_id": str(self.sequence), "method": "GET", "status": 200,
                  "uri": path, "request_time": .01, "bytes": 10, **extra}
        if source == "runtime":
            record["event"] = "request"
        with self.store.db:
            self.store.append(record, endpoint=domain, source=source, record_key=str(self.sequence))

    def test_static_metadata_and_checksums_have_translation_and_local_book_names(self):
        for path in ("/v2/kjv/books.json", "/v2/kjv/73/1.sha", "/v2/test/43/chapters.json", "/v2/test/43.sha"):
            self.append(path)
        self.append("/v2/kjv/43/9999.json", status=404)
        for path in ("/robots.txt", "/v2/translations.json", "/v2/unknown/other.txt"):
            self.append(path)
        report = self.store.summary(0, 200)
        self.assertEqual(report["calls"], 8)
        self.assertEqual({r["value"]: r["calls"] for r in report["breakdowns"]["translation"]}, {"kjv": 2, "test": 2})
        books = {r["value"]: r for r in report["breakdowns"]["book"]}
        self.assertEqual(books["73"]["label"], "Book Seventy Three")
        self.assertEqual(books["43"]["label"], "Localized John")
        self.assertEqual(report["breakdowns"]["search"], [])
        self.assertEqual(report["breakdowns"]["reference"], [])
        for dimension in ("translation", "book"):
            for row in report["breakdowns"][dimension]:
                self.assertEqual(len(self.store.requests(0, 200, filters=row["filters"])["items"]), row["calls"])
        for row in self.store.requests(0, 200)["items"]:
            if row["path"] in {"/robots.txt", "/v2/translations.json"}:
                self.assertEqual(row["translation"], "")

    def test_cache_hit_has_resolved_books_and_path_text_without_runtime_row(self):
        self.append("/v2/kjv/John%203%3A16", domain="query.example", cache="HIT",
                    resolved_endpoint_kind="query", resolved_operation="scripture", resolved_translation="kjv",
                    resolved_version="v2", resolved_books=quote('[43]'))
        row = self.store.requests(0, 200)["items"][0]
        self.assertIsNone(row["runtime"])
        self.assertEqual(row["reference"], "John 3:16")
        self.assertEqual(row["book_names"], {"43": "John"})
        self.assertEqual(self.store.summary(0, 200)["breakdowns"]["reference"][0]["calls"], 1)

    def test_search_and_reference_rankings_follow_endpoint_not_result_kind(self):
        self.append("/v2/kjv/John%203%3A16", domain="query.example", resolved_operation="scripture")
        self.append("/v2/kjv/love", domain="search.example", resolved_operation="search")
        self.append("/v2/kjv/John%203%3A16", domain="search.example", resolved_operation="reference")
        self.append("/v2/kjv/love", domain="search.example", status=503, resolved_operation="search")
        self.append("/v2/kjv/John%203%3A16", domain="query.example", status=301, resolved_operation="redirect")
        self.append("/v2/kjv/43/3.json?search=not-a-search&reference=not-a-reference")
        self.append("/v2/kjv.json", method="OPTIONS", status=204)
        report = self.store.summary(0, 200)
        self.assertEqual({r["value"] for r in report["breakdowns"]["search"]}, {"love", "John 3:16"})
        self.assertEqual([(r["value"], r["calls"]) for r in report["breakdowns"]["reference"]], [("John 3:16", 1)])
        self.assertEqual(sum(r["calls"] for r in report["breakdowns"]["translation"]), 4)
        for dimension in ("search", "reference"):
            for row in report["breakdowns"][dimension]:
                self.assertEqual(len(self.store.requests(0, 200, filters=row["filters"])["items"]), row["calls"])
        self.assertEqual(self.store.summary(0, 200, filters={"endpoint_kind": "query"})["breakdowns"]["search"], [])

    def test_default_translation_only_for_real_search_and_configured_root_version(self):
        self.append("/v2?q=peace", domain="search.example")
        self.append("/?q=peace", domain="root.example", resolved_endpoint_kind="search", resolved_operation="search", resolved_translation="kjv", resolved_version="v2")
        self.append("/robots.txt", domain="search.example", status=404)
        self.append("/v2/translations.json")
        rows = self.store.requests(0, 200)["items"]
        self.assertEqual([row["translation"] for row in rows[:2]], ["", ""])
        self.assertTrue(all(row["translation"] == "kjv" and row["version"] == "v2" for row in rows[2:]))
        self.assertEqual(self.store.summary(0, 200)["breakdowns"]["search"][0]["calls"], 2)

    def test_runtime_resolved_post_overrides_query_and_cache_fields_in_both_orders(self):
        for runtime_first in (True, False):
            rid = "post-" + str(runtime_first)
            edge = lambda: self.append("/v2/test?translation=kjv", domain="search.example", request_id=rid, method="POST")
            runtime = lambda: self.append("/v2/test", domain="search.example", source="runtime", request_id=rid,
                                         operation="search", endpoint_kind="search", translation="test", search="peace", books=[43])
            for action in ((runtime, edge) if runtime_first else (edge, runtime)):
                action()
        for row in self.store.requests(0, 200)["items"]:
            self.assertEqual(row["translation"], "test")
            self.assertEqual(row["search"], "peace")
            self.assertEqual(row["book_names"], {"43": "Localized John"})

    def test_referrer_user_agent_are_separate_and_errors_remain_filterable(self):
        self.append("/v2/kjv.json", referer="https://reader.example/page", user_agent="Browser A")
        self.append("/robots.txt", status=404, referer="-", user_agent="Robot A")
        self.append("/v2/kjv.json", referer="https://reader.example/page", user_agent="Browser B")
        referrers = self.store.breakdown("referrer", 0, 200)
        self.assertEqual([(r["value"], r["calls"]) for r in referrers], [("https://reader.example/page", 2)])
        self.assertEqual(len(self.store.breakdown("user_agent", 0, 200)), 3)
        self.assertEqual(len(self.store.requests(0, 200, filters={"q": "ROBOTS"})["items"]), 1)
        self.assertEqual(len(self.store.requests(0, 200, filters={"referrer_contains": "READER.EXAMPLE"})["items"]), 2)
        self.assertEqual(len(self.store.requests(0, 200, filters={"user_agent_contains": "Robot"})["items"]), 1)
        self.append("/v2/kjv.json", referer="https://user:password@reader.example/?token=secret-value", user_agent="Bearer agent-secret")
        encoded = json.dumps(self.store.requests(0, 200))
        self.assertNotIn("secret-value", encoded)
        self.assertNotIn("agent-secret", encoded)
        self.assertNotIn("user:password", encoded)

    def test_book_names_are_stored_at_ingestion_and_never_rebuilt_during_reports(self):
        self.append("/v2/kjv/43/3.json")
        with patch.object(self.catalog, "books", side_effect=AssertionError("report reread metadata")):
            self.assertEqual(self.store.breakdown("book", 0, 200)[0]["label"], "John")

    def test_catalog_preserves_raw_repository_paths_with_spaces(self):
        repository = self.root / "Bible files"
        books = repository / "v2/kjv/books.json"
        books.parent.mkdir(parents=True)
        books.write_text(json.dumps({"43": {"nr": 43, "name": "John from local repository"}}))
        (self.registry / "query.example/versions/v2.conf").write_text(f"APP_VERSION=v2\nREPOSITORY={repository}\n")
        self.append("/v2/kjv/John%203%3A16", domain="query.example", resolved_books=quote('[43]'))
        self.assertEqual(self.store.breakdown("book", 0, 200)[0]["label"], "John from local repository")

    def test_search_text_normalization_matches_miss_and_cached_paths_and_parameters(self):
        self.append("/v2/kjv/%20peace%20", domain="search.example", request_id="miss")
        self.append("/v2/kjv/ peace ", domain="search.example", request_id="miss", source="runtime",
                    endpoint_kind="search", operation="search", translation="kjv", search="peace")
        self.append("/v2/kjv/%20peace%20", domain="search.example", cache="HIT",
                    resolved_endpoint_kind="search", resolved_operation="search", resolved_translation="kjv")
        self.append("/v2?q=%20peace%20", domain="search.example", cache="HIT", resolved_translation="kjv", resolved_operation="search")
        rows = self.store.breakdown("search", 0, 200)
        self.assertEqual([(row["value"], row["calls"]) for row in rows], [("peace", 3)])

    def test_cross_rankings_preserve_inherited_usage_scope_in_drilldowns(self):
        self.append("/v2/kjv/43/3.json")
        self.append("/v2/kjv/John%203%3A16", domain="query.example", resolved_books=quote('[43]'), resolved_operation="scripture")
        self.append("/v2/kjv/peace", domain="search.example", resolved_books=quote('[43]'), resolved_operation="search")
        self.append("/v2/kjv/John%203%3A16", domain="search.example", resolved_books=quote('[43]'), resolved_operation="reference")
        for inherited in ("translation", "book", "reference", "search"):
            for dimension in ("translation", "book", "reference", "search", "endpoint_kind"):
                for row in self.store.breakdown(dimension, 0, 200, filters={"usage": inherited}):
                    with self.subTest(inherited=inherited, dimension=dimension, value=row["value"]):
                        self.assertEqual(len(self.store.requests(0, 200, filters=row["filters"])["items"]), row["calls"])

    def test_explicit_reset_refuses_collector_lock_and_skips_old_buffered_requests(self):
        self.append("/v2/kjv.json")
        collector = Collector(self.store, str(self.root))
        collector.lock()
        try:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(["reset", "--db", str(self.path), "--discard-history"])
        finally:
            collector.close()
        with self.store.db:
            self.store.db.execute("INSERT INTO sources(identity,path,offset,updated) VALUES('source','log',123,100)")
            self.store.set_metadata("journal_cursor", {"cursor": "saved"})
            self.store.db.execute("PRAGMA user_version=1")
        with self.assertRaisesRegex(RuntimeError, "database migrations"):
            TelemetryStore(self.path)
        self.store.close()
        with contextlib.redirect_stdout(io.StringIO()):
            main(["reset", "--db", str(self.path), "--discard-history"])
        self.store = TelemetryStore(self.path, catalog=self.catalog)
        self.assertEqual(self.store.db.execute("SELECT offset FROM sources").fetchone()[0], 123)
        self.assertEqual(self.store.storage()["metadata"]["journal_cursor"], {"cursor": "saved"})
        self.append("/v2/kjv.json", time=self.store.collection_started - 1)
        self.append("/v2/kjv.json", time=self.store.collection_started + 1)
        self.assertEqual(self.store.summary(0, self.store.collection_started + 2)["calls"], 1)


if __name__ == "__main__":
    unittest.main()
