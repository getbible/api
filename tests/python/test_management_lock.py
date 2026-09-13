"""Foreground management waits for short background work without bypassing locks."""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ManagementLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "var/lib/getbible"
        self.state.mkdir(parents=True)
        self.environment = dict(os.environ, GB_PREFIX=str(self.root), GB_REPO_DIR=str(ROOT), GB_UI="none")
        self.environment.pop("GB_TMP", None)
        self.environment.pop("GB_MANAGEMENT_LOCK_WAIT_SECONDS", None)

    @contextmanager
    def holder(self):
        process = subprocess.Popen(["bash", "-c", 'exec 9>"$1"; flock 9; echo ready; read -r release',
                                    "holder", str(self.state / "manage.lock")], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(process.stdout.readline().strip(), "ready")
        try:
            yield process
        finally:
            if process.poll() is None:
                process.communicate("release\n", timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def command(self, environment=None, body="gb_management_lock"):
        return ["bash", "-c", 'source "$1/src/lib/core.sh"; ' + body, "manager", str(ROOT)], environment or self.environment

    def test_foreground_waits_then_acquires_and_reenters(self):
        command, environment = self.command(body="gb_management_lock && gb_management_lock")
        with self.holder() as holder:
            process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn("Waiting up to 30s", process.stderr.readline())
                self.assertIsNone(process.poll())
                holder.communicate("release\n", timeout=5)
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                process.stdout.close()
                process.stderr.close()

    def test_background_fails_fast_with_temporary_busy_status(self):
        command, environment = self.command(dict(self.environment, GB_MANAGEMENT_LOCK_WAIT_SECONDS="0"))
        with self.holder():
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 75)
        self.assertIn("deferring", result.stderr)

    def test_image_application_waits_for_existing_management_work(self):
        command, environment = self.command(dict(self.environment, GB_IMAGE_UPDATE_WAIT="true",
                                                  GB_MANAGEMENT_LOCK_WAIT_SECONDS="0"))
        with self.holder() as holder:
            process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn("Image update is waiting", process.stderr.readline())
                self.assertIsNone(process.poll())
                holder.communicate("release\n", timeout=5)
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                process.stdout.close()
                process.stderr.close()

    def test_actual_cli_propagates_busy_to_background_controller(self):
        environment = dict(self.environment, GB_MANAGEMENT_LOCK_WAIT_SECONDS="0", GETBIBLE_EXECUTION_MODE="native")
        with self.holder():
            for arguments in (("resources", "show"), ("runtime", "query.example.test", "cache", "v2", "info")):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(["bash", str(ROOT / "getbible.sh"), *arguments, "--yes"],
                                            env=environment, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 75, result.stderr)
                    self.assertIn("deferring", result.stderr)
        self.assertFalse((self.root / "etc/getbible/getbible.conf").exists())

    def test_wait_has_a_finite_deadline(self):
        command, environment = self.command(dict(self.environment, GB_MANAGEMENT_LOCK_WAIT_SECONDS="1"))
        with self.holder():
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=4)
        self.assertEqual(result.returncode, 75)
        self.assertIn("still running", result.stderr)

    def test_internal_override_rejects_invalid_or_unbounded_values(self):
        for value in ("", "-1", "1.5", "NaN", "Infinity", "301", "000", " 1"):
            with self.subTest(value=value):
                command, environment = self.command(dict(self.environment, GB_MANAGEMENT_LOCK_WAIT_SECONDS=value))
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 1)
                self.assertIn("integer between 0 and 300", result.stderr)


if __name__ == "__main__":
    unittest.main()
