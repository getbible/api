"""The root management boundary uses typed operations and durable, redacted jobs."""
import importlib.machinery
import importlib.util
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shlex
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch
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

    def test_history_reset_has_explicit_cli_flag_and_destructive_review(self):
        spec = broker.OPS["logs.reset"]
        values = broker.validate_arguments(spec, {})
        self.assertTrue(spec["destructive"])
        self.assertIn("Permanently discard", spec["description"])
        self.assertEqual(broker.command_arguments(spec, values), ["logs", "reset", "--discard-history", "--yes"])
        with self.assertRaises(ValueError):
            broker.validate_arguments(spec, {"domain": "example.test"})


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

    def wait_for_status(self, job_id, status):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            job = self.app.job(job_id, "operator")
            if job["status"] == status:
                return job
            time.sleep(0.01)
        self.fail(f"Job did not reach {status}: {job}")

    @contextmanager
    def management_lock(self):
        directory = self.root / "var/lib/getbible"
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "manage.lock").open("w") as lock:
            # Even an inheritable lock in the privileged broker's process
            # must not cross its child-process boundary.
            os.set_inheritable(lock.fileno(), True)
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def locked_manager(self, after=""):
        self.manager.write_text("#!/bin/bash\nset -Eeuo pipefail\n"
                                f"source {shlex.quote(str(ROOT / 'src/lib/core.sh'))}\n"
                                # A normal background caller would fail with
                                # 75 immediately; a durable broker job waits.
                                "GB_MANAGEMENT_LOCK_WAIT_SECONDS=0\n"
                                "printf '%s\\n' \"$2\" >> \"$GB_PREFIX/invocations\"\n"
                                "gb_management_lock\n"
                                "printf '%s\\n' \"$2\" >> \"$GB_PREFIX/effects\"\n" + after)

    def test_busy_cli_keeps_gui_job_waiting_and_queue_resumes_exactly_once(self):
        self.locked_manager()
        with self.management_lock():
            first = self.app.submit({"operation": "domain.apply", "arguments": {"domain": "first.example.test"}}, "operator")
            waiting = self.wait_for_status(first["id"], "waiting")
            second = self.app.submit({"operation": "domain.apply", "arguments": {"domain": "second.example.test"}}, "operator")
            self.assertIsNone(waiting["started"])
            self.assertIsNone(waiting["finished"])
            self.assertIn("idle CLI menu", waiting["output"])
            self.assertEqual(self.app.job(second["id"], "operator")["status"], "queued")
            # Status and inventory reads remain responsive during contention.
            self.assertEqual({item["status"] for item in self.app.jobs()}, {"queued", "waiting"})
            self.assertEqual(self.app.state()["pending_jobs"], 2)
            self.assertEqual(self.app.endpoints()["endpoints"], [])
            self.assertFalse((self.root / "effects").exists())
        first_result = self.wait_for_status(first["id"], "succeeded")
        self.wait_for_status(second["id"], "succeeded")
        self.app.work.join()
        expected = ["first.example.test", "second.example.test"]
        self.assertEqual((self.root / "invocations").read_text().splitlines(), expected)
        self.assertEqual((self.root / "effects").read_text().splitlines(), expected)
        self.assertIsNotNone(first_result["started"])
        self.assertIn("lock acquired", first_result["output"])
        self.assertNotIn("__GETBIBLE_ADMIN_JOB__", first_result["output"])

    def test_failure_after_lock_and_mutation_is_never_retried(self):
        self.locked_manager('if [[ "$2" == first.example.test ]]; then exit 75; fi\n')
        first = self.app.submit({"operation": "domain.apply", "arguments": {"domain": "first.example.test"}}, "operator")
        second = self.app.submit({"operation": "domain.apply", "arguments": {"domain": "second.example.test"}}, "operator")
        self.wait_for_status(first["id"], "failed")
        self.wait_for_status(second["id"], "succeeded")
        self.app.work.join()
        self.assertEqual(self.app.job(first["id"], "operator")["exit_code"], 75)
        self.assertEqual((self.root / "effects").read_text().splitlines(), ["first.example.test", "second.example.test"])

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
        with self.assertRaises(ValueError):
            self.app.submit({"operation": "logs.reset", "arguments": {}}, "session-A")
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
            database.execute("INSERT INTO jobs(id,operation,arguments,actor,status,created) VALUES('waiting-job','domain.apply','{}','operator','waiting',2)")
        replacement = broker.Broker(self.root / "admin", self.manager, str(self.root))
        job = replacement.job("old-job", "operator")
        self.assertEqual(job["status"], "interrupted")
        self.assertEqual(replacement.job("waiting-job", "operator")["status"], "interrupted")
        self.assertTrue(replacement.work.empty())

    def test_refresh_signal_only_sets_a_flag_and_rejects_new_work(self):
        with patch.object(self.app, "connect", side_effect=AssertionError("signal opened database")):
            self.app.request_refresh()
        self.assertFalse(self.app.state()["accepting_jobs"])
        with self.assertRaises(broker.ManagementPaused):
            self.app.submit({"operation": "domain.status", "arguments": {"domain": "api.example.test"}}, "operator")
        self.assertEqual(self.app.jobs(), [])

    def test_refresh_drains_job_and_commits_result_before_fixed_unit_restart(self):
        started, release = threading.Event(), threading.Event()
        original = self.app.run_job
        def delayed(*args):
            started.set()
            release.wait(5)
            original(*args)
        with patch.object(self.app, "run_job", side_effect=delayed):
            job = self.app.submit({"operation": "domain.status", "arguments": {"domain": "api.example.test"}}, "operator")
            self.assertTrue(started.wait(5))
            self.app.request_refresh()
            with patch.object(broker.subprocess, "run") as restart:
                self.app.refresh_tick()
                restart.assert_not_called()
                self.assertEqual(self.app.state()["pending_jobs"], 1)
                self.assertEqual(self.app.job(job["id"], "operator")["status"], "queued")
            release.set()
            self.app.work.join()
        def schedule(*args, **kwargs):
            self.assertEqual(args[0], broker.REFRESH_COMMAND)
            self.assertFalse(kwargs.get("shell", False))
            self.assertEqual(self.app.job(job["id"], "operator")["status"], "succeeded")
            with self.app.connect() as db:
                saved = json.loads(db.execute("SELECT refresh FROM management_state WHERE id=1").fetchone()[0])
            self.assertEqual(saved["state"], "scheduling")
            return SimpleNamespace(returncode=0)
        with patch.object(broker.subprocess, "run", side_effect=schedule):
            self.app.refresh_tick()
        self.assertEqual(self.app.state()["refresh"]["state"], "scheduled")
        replacement = broker.Broker(self.root / "admin", self.manager, str(self.root))
        self.assertEqual(replacement.job(job["id"], "operator")["status"], "succeeded")
        self.assertEqual(replacement.state()["refresh"]["state"], "current")
        self.assertTrue(replacement.state()["accepting_jobs"])

    def test_refresh_keeps_one_time_output_available_until_claimed_or_expired(self):
        for consume in (True, False):
            with self.subTest(consume=consume):
                self.app.refresh.update(state="current", pending=False)
                job = self.app.submit({"operation": "token.add", "arguments": {"domain": "api.example.test", "label": "integration"}}, "operator")
                self.app.work.join()
                self.app.request_refresh()
                with patch.object(broker.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as restart:
                    self.app.refresh_tick()
                    restart.assert_not_called()
                    self.assertTrue(self.app.job(job["id"], "operator")["secret_available"])
                    if consume:
                        self.assertIn(self.token, self.app.job(job["id"], "operator", True)["one_time_output"])
                        self.app.refresh_tick()
                    else:
                        expires = self.app.output_secrets[job["id"]][0]
                        self.app.refresh_tick(now=expires + 1)
                    restart.assert_called_once()
                self.assertFalse(self.app.output_secrets)
                self.assertNotIn(self.token, self.app.database.read_bytes().decode("utf-8", "ignore"))

    def test_refresh_retries_are_bounded_persistent_and_failure_reopens_management(self):
        self.app.request_refresh()
        with patch.object(broker.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as restart:
            self.app.refresh_tick(now=100)
            self.assertEqual(self.app.state()["refresh"]["state"], "retrying")
            self.app.refresh_tick(now=100.5)
            self.assertEqual(restart.call_count, 1)
            self.app.refresh_tick(now=101)
            self.app.refresh_tick(now=106)
            self.app.refresh_tick(now=1000)
            self.assertEqual(restart.call_count, 3)
        state = self.app.state()
        self.assertEqual(state["refresh"]["state"], "failed")
        self.assertEqual(state["refresh"]["attempts"], 3)
        self.assertTrue(state["refresh"]["pending"])
        self.assertTrue(state["accepting_jobs"])
        self.assertIsNone(state["refresh"]["next_retry_at"])
        with self.app.connect() as db:
            saved = json.loads(db.execute("SELECT refresh FROM management_state WHERE id=1").fetchone()[0])
        self.assertEqual(saved, state["refresh"])
        job = self.app.submit({"operation": "domain.status", "arguments": {"domain": "api.example.test"}}, "operator")
        self.app.work.join()
        self.assertEqual(self.app.job(job["id"], "operator")["status"], "succeeded")
        self.app.request_refresh()
        with patch.object(broker.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
            self.app.refresh_tick(now=1001)
        self.assertEqual(self.app.state()["refresh"]["attempts"], 1)
        self.assertEqual(self.app.dispatch({"method": "state"}, 0)["refresh"]["state"], "scheduled")

    def test_refresh_scheduling_errors_are_visible_and_retried(self):
        self.app.request_refresh()
        with patch.object(broker.subprocess, "run", side_effect=[OSError("unavailable"), broker.subprocess.TimeoutExpired(broker.REFRESH_COMMAND, 5)]):
            self.app.refresh_tick(now=100)
            self.app.refresh_tick(now=101)
        self.assertEqual(self.app.state()["refresh"]["state"], "retrying")
        self.assertIsNotNone(self.app.state()["refresh"]["last_error"])

    def test_endpoint_inventory_never_exposes_registry_credentials(self):
        endpoint = self.root / "etc/getbible/endpoints/api.example.test"
        (endpoint / "versions").mkdir(parents=True)
        (endpoint / "endpoint.conf").write_text("DOMAIN=api.example.test\nTYPE=static\nLIVE=true\nAPI_TOKEN=do-not-show\n")
        (endpoint / "versions/v2.conf").write_text("REPO_URL=https://example.test/repo.git\nSECRET=do-not-show\n")
        data = self.app.endpoints()
        self.assertEqual(data["endpoints"][0]["label"], "v2")
        self.assertEqual(data["domains"][0]["domain"], "api.example.test")
        self.assertNotIn("do-not-show", json.dumps(data))

    def test_domain_without_endpoints_remains_in_management_inventory(self):
        domain = self.root / "etc/getbible/endpoints/query.example.test"
        domain.mkdir(parents=True)
        (domain / "endpoint.conf").write_text("TYPE=runtime\nKIND=query\nLIVE=false\nSECRET=do-not-show\n")
        result = self.app.endpoints()
        self.assertEqual(result["endpoints"], [])
        self.assertEqual(result["domains"][0]["domain"], "query.example.test")
        self.assertEqual(result["domains"][0]["kind"], "query")
        self.assertFalse(result["domains"][0]["live"])
        self.assertNotIn("do-not-show", json.dumps(result))

    def test_runtime_settings_inventory_contains_every_editable_nonsecret_key(self):
        domain = self.root / "etc/getbible/endpoints/query.example.test"
        (domain / "versions").mkdir(parents=True)
        (domain / "endpoint.conf").write_text("TYPE=runtime\nKIND=query\nLIVE=false\n")
        keys = broker.RUNTIME_KEYS.split("|")
        (domain / "versions/v2.conf").write_text("\n".join(f"{key}=current-{key}" for key in keys) + "\nSECRET=do-not-show\n")
        result = self.app.endpoints()
        settings = result["endpoints"][0]["endpoint_settings"]
        self.assertEqual(settings, {key: "current-" + key for key in keys})
        self.assertNotIn("do-not-show", json.dumps(result))

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
