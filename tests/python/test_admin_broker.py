"""The root management boundary uses typed operations and durable, redacted jobs."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOADER = importlib.machinery.SourceFileLoader("getbible_admin_broker", str(ROOT / "src/bin/getbible-admin-broker"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
broker = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(broker)


class OperationTests(unittest.TestCase):
    def test_unknown_fields_and_flag_injection_are_rejected(self):
        spec = broker.OPS["domain.apply"]
        for arguments in ({"domain": "example.test", "shell": "true"}, {"domain": "--help"}, {"domain": "example.test; touch /tmp/unwanted"}, {"domain": "example.test\nother"}):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                broker.validate_arguments(spec, arguments)

    def test_optional_endpoint_preserves_existing_cli_grammar(self):
        spec = broker.OPS["runtime.update"]
        arguments = broker.validate_arguments(spec, {"domain": "search.example.test", "python": "auto"})
        self.assertEqual(broker.command_arguments(spec, arguments), ["runtime", "search.example.test", "update", "--python", "auto", "--yes"])
        arguments["endpoint"] = "v2"
        self.assertEqual(broker.command_arguments(spec, arguments)[1:4], ["search.example.test", "v2", "update"])

    def test_cache_actions_cannot_escape_translation_identity(self):
        spec = broker.OPS["runtime.cache"]
        with self.assertRaises(ValueError):
            broker.validate_arguments(spec, {"domain": "query.example.test", "endpoint": "v2", "action": "warm", "translation": "../secret"})
        values = broker.validate_arguments(spec, {"domain": "query.example.test", "endpoint": "v2", "action": "warm", "translation": "kjv"})
        self.assertEqual(broker.command_arguments(spec, values), ["runtime", "query.example.test", "cache", "v2", "warm", "kjv", "--yes"])

    def test_browser_has_no_unblock_or_arbitrary_shell_operation(self):
        self.assertNotIn("dashboard.unblock", broker.OPS)
        self.assertNotIn("shell", broker.OPS)
        self.assertTrue(broker.OPS["dashboard.password"]["fields"][0]["secret"])
        self.assertTrue(broker.OPS["domain.remove"]["destructive"])
        self.assertTrue(broker.OPS["token.add"]["secret_output"])
        with self.assertRaises(ValueError):
            broker.validate_arguments(broker.OPS["runtime.set"], {"domain": "query.example.test", "key": "TELEGRAM_BOT_TOKEN", "value": "secret"})
        values = broker.validate_arguments(broker.OPS["runtime.set"], {"domain": "query.example.test", "key": "WARM_TRANSLATIONS", "value": ""})
        self.assertEqual(broker.command_arguments(broker.OPS["runtime.set"], values)[-3:], ["WARM_TRANSLATIONS", "", "--yes"])


class JobTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        Path(self.root, "var/log/getbible/management/app").mkdir(parents=True)
        self.manager = self.root / "manager"
        self.token = "gb" + "a" * 52
        self.manager.write_text("#!/usr/bin/python3\nimport sys\nif 'token' in sys.argv:\n print(" + repr(json.dumps({"token": self.token})) + ")\nelse:\n print(sys.stdin.read())\n")
        self.manager.chmod(0o755)
        self.app = broker.Broker(self.root / "admin", self.manager, str(self.root))

    def test_token_secret_is_not_persisted_and_is_returned_only_once_to_issuer(self):
        result = self.app.submit({"operation": "token.add", "arguments": {"domain": "api.example.test", "label": "integration"}}, "session-A")
        self.app.work.join()
        job_id = result["job_id"]
        self.assertNotIn(self.token, self.app.database.read_bytes().decode("utf-8", "ignore"))
        self.assertTrue(self.app.job(job_id, "session-A")["secret_available"])
        self.assertFalse(self.app.job(job_id, "session-B")["secret_available"])
        self.assertNotIn("one_time_output", self.app.job(job_id, "session-B", True))
        self.assertIn(self.token, self.app.job(job_id, "session-A", True)["one_time_output"])
        self.assertNotIn("one_time_output", self.app.job(job_id, "session-A", True))
        self.assertFalse(self.app.job(job_id, "session-A")["secret_available"])
        self.assertNotIn(self.token, self.app.job(job_id, "session-A")["output"])

    def test_password_never_appears_in_job_arguments_or_captured_output(self):
        password = "test-password-that-must-stay-private"
        result = self.app.submit({"operation": "dashboard.password", "arguments": {"secret": password}, "confirm": True}, "session-A")
        self.app.work.join()
        self.assertNotIn(password, self.app.database.read_bytes().decode("utf-8", "ignore"))
        self.assertNotIn(password, json.dumps(self.app.job(result["job_id"], "session-A")))
        self.assertEqual(self.app.secrets, {})
        self.assertEqual(self.app.database.stat().st_mode & 0o777, 0o600)

    def test_destructive_actions_require_explicit_confirmation(self):
        with self.assertRaises(ValueError):
            self.app.submit({"operation": "domain.remove", "arguments": {"domain": "api.example.test", "purge": True}}, "session-A")
        self.assertEqual(self.app.jobs(), [])

    def test_one_time_secret_follows_issuer_session_across_address_changes(self):
        actor = json.dumps({"uid": 100, "session_id": "session-A", "ip": "192.0.2.1"})
        moved = json.dumps({"uid": 100, "session_id": "session-A", "ip": "192.0.2.2"})
        other = json.dumps({"uid": 100, "session_id": "session-B", "ip": "192.0.2.1"})
        result = self.app.submit({"operation": "token.add", "arguments": {"domain": "api.example.test", "label": "integration"}}, actor)
        self.app.work.join()
        self.assertTrue(self.app.job(result["job_id"], moved)["secret_available"])
        self.assertFalse(self.app.job(result["job_id"], other)["secret_available"])

    def test_broker_restart_reports_interruption_without_replaying_mutation(self):
        with self.app.connect() as database:
            database.execute("INSERT INTO jobs(id,operation,arguments,actor,status,created) VALUES('old-job','domain.apply','{}','operator','running',1)")
        replacement = broker.Broker(self.root / "admin", self.manager, str(self.root))
        job = replacement.job("old-job", "operator")
        self.assertEqual(job["status"], "interrupted")
        self.assertTrue(replacement.work.empty())

    def test_endpoint_inventory_never_exposes_registry_credentials(self):
        endpoint = self.root / "etc/getbible/endpoints/api.example.test"
        (endpoint / "versions").mkdir(parents=True)
        (endpoint / "endpoint.conf").write_text("DOMAIN=api.example.test\nTYPE=static\nLIVE=true\nAPI_TOKEN=do-not-show\n")
        (endpoint / "versions/v2.conf").write_text("REPO_URL=https://example.test/repo.git\nSECRET=do-not-show\n")
        data = self.app.endpoints()
        self.assertEqual(data["endpoints"][0]["label"], "v2")
        self.assertNotIn("do-not-show", json.dumps(data))

    def test_browser_cannot_publish_private_files_or_symlinked_imports(self):
        imports = self.root / "var/lib/getbible/imports"
        imports.mkdir(parents=True)
        private = self.root / "private-secret"
        private.write_text("secret")
        link = imports / "page.html"
        link.symlink_to(private)
        for source in (str(private), str(link), "/etc/shadow"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.app.submit({"operation": "pages.docs", "arguments": {"domain": "api.example.test", "action": "from", "source": source}}, "session-A")
        public = imports / "safe.html"
        public.write_text("<p>Public page</p>")
        self.assertEqual(self.app.safe_import(str(public)), str(public))
        self.assertEqual(self.app.jobs(), [])

    def test_credential_keys_are_rejected_before_generic_setting_persistence(self):
        self.app.manager = str(ROOT / "getbible.sh")
        for key in ("TELEGRAM_BOT_TOKEN", "CLOUDFLARE_API_TOKEN", "UNKNOWN_SETTING"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.app.submit({"operation": "settings.set", "arguments": {"key": key, "value": "do-not-persist-this-value"}}, "session-A")
        self.assertNotIn(b"do-not-persist-this-value", self.app.database.read_bytes())
        self.assertEqual(self.app.jobs(), [])

    def test_translation_inventory_counts_files_without_loading_or_duplicating_hardlinks(self):
        repository = self.root / "corpus"
        translation = repository / "v2/kjv"
        translation.mkdir(parents=True)
        (translation / "books.json").write_text("not parsed by inventory")
        chapter = translation / "1.json"
        chapter.write_text("also not parsed")
        (translation / "same-inode.json").hardlink_to(chapter)
        (repository / "v2/kjv.json").write_text("full translation bytes")
        result = self.app.translation_inventory(str(repository), "v2")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["translation"], "kjv")
        self.assertEqual(result[0]["files"], 3)
        self.assertGreater(result[0]["allocated_bytes"], 0)
        self.assertIs(self.app.translation_inventory(str(repository), "v2"), result)


if __name__ == "__main__":
    unittest.main()
