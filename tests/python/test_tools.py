"""The helper programs under src/bin: render, tokens, verify-tree, analytics, nginx-strip."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "src" / "bin"


def run(tool: str, *args: str, check: bool = True, **kwargs):
    return subprocess.run([sys.executable, str(BIN / tool), *args], capture_output=True, text=True, check=check, **kwargs)


class RenderTest(unittest.TestCase):
    def render(self, text: str, **variables: str) -> str:
        with tempfile.NamedTemporaryFile("w", suffix=".tmpl", delete=False) as handle:
            handle.write(text)
        try:
            return run("getbible-render", handle.name, *[f"{k}={v}" for k, v in variables.items()]).stdout
        finally:
            os.unlink(handle.name)

    def test_variables_and_nested_blocks(self) -> None:
        text = "a{{#IF X}}[{{#IF Y}}y{{/IF}}{{Z}}]{{/IF}}{{#UNLESS X}}no{{/UNLESS}}b"
        self.assertEqual(self.render(text, X="true", Y="true", Z="z"), "a[yz]b")
        self.assertEqual(self.render(text, X="true", Y="false"), "a[]b")
        self.assertEqual(self.render(text, X="0"), "anob")
        self.assertEqual(self.render("{{MISSING}}-"), "-")

    def test_unterminated_block_fails(self) -> None:
        with self.assertRaises(subprocess.CalledProcessError):
            self.render("{{#IF X}}oops")


class TokensTest(unittest.TestCase):
    def test_lifecycle_and_map(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = os.path.join(directory, "tokens.json")
            created = json.loads(run("getbible-tokens", store, "add", "--label", "app one").stdout)
            self.assertTrue(created["token"].startswith("gb"))
            self.assertEqual(len(created["token"]), 54)
            self.assertEqual(created["token"], created["token"].lower())
            self.assertEqual(oct(os.stat(store).st_mode & 0o777), "0o600")
            listing = run("getbible-tokens", store, "list").stdout
            self.assertIn("app one", listing)
            rendered = run("getbible-tokens", store, "render-map", "api.example.test").stdout
            self.assertEqual(rendered.strip(), f'"api.example.test Bearer {created["token"]}" "{created["id"]}";')
            run("getbible-tokens", store, "revoke", created["id"])
            self.assertEqual(run("getbible-tokens", store, "render-map", "api.example.test").stdout, "")
            self.assertEqual(run("getbible-tokens", store, "count").stdout.strip(), "0")
            expired = json.loads(run("getbible-tokens", store, "add", "--label", "old", "--expires", "2000-01-01").stdout)
            self.assertEqual(run("getbible-tokens", store, "count").stdout.strip(), "0")
            self.assertIn(expired["id"], run("getbible-tokens", store, "list").stdout)


class VerifyTreeTest(unittest.TestCase):
    def test_sha_and_manifest_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "kjv" / "1").mkdir(parents=True)
            chapter = root / "kjv" / "1" / "1.json"
            chapter.write_text('{"a":1}')
            (root / "kjv" / "1" / "1.sha").write_text(hashlib.sha1(chapter.read_bytes()).hexdigest())
            doc = root / "doc.json"
            doc.write_text('{"b":2}')
            (root / "hashes.json").write_text(json.dumps({"algorithm": "sha256", "files": {"doc.json": hashlib.sha256(doc.read_bytes()).hexdigest()}}))
            summary = json.loads(run("getbible-verify-tree", str(root)).stdout)
            self.assertEqual(summary["sha_checked"], 1)
            self.assertEqual(summary["manifest_checked"], 1)
            chapter.write_text('{"a":2}')
            result = run("getbible-verify-tree", str(root), check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("sha1 mismatch", result.stderr)


class AnalyticsTest(unittest.TestCase):
    def test_totals_and_unique_callers(self) -> None:
        now = datetime.now(UTC).isoformat()

        def line(**fields):
            base = {"time": now, "host": "a", "endpoint": "a", "version": "v2", "remote_addr": "203.0.113.5", "method": "GET",
                    "uri": "/v2/kjv/1/1.json", "status": 200, "bytes": 512, "request_length": 100, "request_time": 0.01,
                    "upstream_time": "-", "cache": "-", "referer": "", "user_agent": "curl", "request_id": "x", "token": "",
                    "scheme": "https", "protocol": "HTTP/2.0", "tls": "TLSv1.3", "country": "-"}
            base.update(fields)
            return json.dumps(base)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.test" / "archive").mkdir(parents=True)
            (root / "b.test").mkdir()
            (root / "a.test" / "access.log").write_text("\n".join([
                line(), line(), line(remote_addr="2001:db8::1"), line(remote_addr="2001:db8::2"), line(remote_addr="2001:db9::1"),
                line(token="tk_1", remote_addr="198.51.100.1"), line(method="OPTIONS"), line(status=429), "garbage",
                line(status=404, uri="/v2/x.json?y=1"),
            ]) + "\n")
            with gzip.open(root / "a.test" / "archive" / "access.log-20260101.gz", "wt") as handle:
                handle.write(line(remote_addr="203.0.113.9") + "\n")
            (root / "b.test" / "access.log").write_text("\n".join([
                line(endpoint="b"), line(endpoint="b", token="tk_1", remote_addr="198.51.100.2", cache="HIT"), line(endpoint="b", cache="MISS"),
            ]) + "\n")
            report = json.loads(run("getbible-analytics", "--log-root", str(root), "--window", "24h", "--json").stdout)
            a, b, combined = report["endpoints"]["a.test"], report["endpoints"]["b.test"], report["combined"]
            self.assertEqual((a["total_calls"], a["unique_callers"], a["preflights"], a["rate_limited"], a["malformed_lines"]), (9, 5, 1, 1, 1))
            self.assertEqual(a["status"], {"2xx": 7, "4xx": 2})
            self.assertEqual(a["top_paths"][0], ["/v2/kjv/1/1.json", 8])
            self.assertEqual((b["total_calls"], b["unique_callers"], b["cache_hit_ratio"]), (3, 2, 0.5))
            self.assertEqual((combined["total_calls"], combined["unique_callers"], combined["unique_tokens"]), (12, 5, 1))
            text = run("getbible-analytics", "--log-root", str(root), "--window", "7d").stdout
            self.assertIn("unique callers (union): 5", text)
            self.assertNotIn("203.0.113", text)


class NginxStripTest(unittest.TestCase):
    CONFIG = """# comment
server {
    listen 80;
    server_name api.example.test query.example.test;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name api.example.test;
    location / { # } not a brace
        try_files $uri =404;
    }
}

server {
    listen 443 ssl;
    server_name other.example.test;
}
"""

    def test_removes_only_matching_blocks(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as handle:
            handle.write(self.CONFIG)
        try:
            result = run("getbible-nginx-strip", handle.name, "api.example.test")
            self.assertNotIn("api.example.test", result.stdout)
            self.assertIn("other.example.test", result.stdout)
            self.assertIn("# comment", result.stdout)
            self.assertEqual(result.stdout.count("server {"), 1)
            nothing = run("getbible-nginx-strip", handle.name, "missing.example.test", check=False)
            self.assertEqual(nothing.returncode, 3)
        finally:
            os.unlink(handle.name)


class SettingsTest(unittest.TestCase):
    def test_validation(self) -> None:
        from getbible_api_common.settings import LibrarianSettings, ServiceSettings
        with self.assertRaises(ValueError):
            LibrarianSettings(version="two")
        with self.assertRaises(ValueError):
            ServiceSettings(prefix="QUERY", default_translation="Not Valid!")
        with self.assertRaises(ValueError):
            ServiceSettings(prefix="QUERY", default_translation="kjv", allowed_translations=("aov",))
        settings = ServiceSettings(prefix="QUERY", default_translation="KJV", allowed_translations=("KJV", "aov"))
        self.assertEqual(settings.default_translation, "kjv")
        self.assertTrue(settings.translation_allowed("AOV"))
        self.assertFalse(settings.translation_allowed("vulgate"))


if __name__ == "__main__":
    unittest.main()
