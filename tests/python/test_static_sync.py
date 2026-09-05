"""Exercise the real static publisher with local git repositories and rsync."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "src" / "bin"


@unittest.skipUnless(all(shutil.which(tool) for tool in ("git", "rsync", "flock")), "git, rsync and flock required")
class StaticSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "upstream"
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Sync test")
        self.git("config", "user.email", "sync@example.test")
        self.payload("first")
        self.commit()
        self.home = self.root / "home"
        self.data = self.root / "data"
        self.live = self.data / "v2"
        self.env = dict(os.environ, GB_SYNC_DOMAIN="static.example.test", GB_SYNC_VERSION="v2",
                        GB_SYNC_REPO=str(self.repo), GB_SYNC_REF="main", GB_SYNC_HOME=str(self.home),
                        GB_SYNC_DATA=str(self.data), GB_VERIFY=str(BIN / "getbible-verify-tree"),
                        GB_NOTIFY="/nonexistent-notifier", GB_SYNC_EXTENSIONS="json,sha,txt")

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def payload(self, value: str, path: str = "doc") -> None:
        target = self.repo / f"{path}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"value": value}), encoding="utf-8")
        target.with_suffix(".sha").write_text(hashlib.sha1(target.read_bytes()).hexdigest(), encoding="ascii")

    def commit(self) -> str:
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def sync(self, *, success: bool = True, **overrides: str) -> subprocess.CompletedProcess:
        result = subprocess.run(["bash", str(BIN / "getbible-sync")], env=dict(self.env, **overrides),
                                capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_atomic_rotation_and_verification_failure_preserve_live_release(self) -> None:
        first = self.git("rev-parse", "HEAD")
        self.sync()
        previous = self.live.resolve()
        old_bytes = (previous / "doc.json").read_bytes()
        observations: list[str] = []
        failures: list[str] = []
        stop = threading.Event()

        def reader() -> None:
            while not stop.is_set():
                try:
                    observations.append(json.loads((self.live / "doc.json").read_text())["value"])
                except (OSError, ValueError) as error:
                    failures.append(str(error))
                stop.wait(0.001)

        worker = threading.Thread(target=reader)
        worker.start()
        try:
            self.payload("second")
            second = self.commit()
            self.sync()
        finally:
            stop.set()
            worker.join(timeout=5)
        self.assertEqual(failures, [])
        self.assertTrue(observations)
        self.assertTrue(set(observations) <= {"first", "second"})
        self.assertEqual((previous / "doc.json").read_bytes(), old_bytes)
        self.assertEqual((previous / ".revision").read_text().strip(), first)
        self.assertEqual((self.live / ".revision").read_text().strip(), second)
        current = self.live.resolve()
        (self.repo / "doc.json").write_text('{"value":"corrupt"}')
        self.commit()
        result = self.sync(success=False)
        self.assertIn("sha1 mismatch", result.stderr)
        self.assertEqual(self.live.resolve(), current)
        self.assertEqual(len(list((self.data / "releases" / "v2").iterdir())), 2)

    def test_same_second_forced_exports_never_reuse_or_modify_release(self) -> None:
        self.sync()
        first = self.live.resolve()
        original = (first / "doc.json").read_bytes()
        marker = self.home / "state" / "v2.force"
        marker.touch()
        self.sync()
        second = self.live.resolve()
        self.sync(GB_SYNC_FORCE="1")
        third = self.live.resolve()
        self.assertEqual(len({first, second, third}), 3)
        self.assertEqual((first / "doc.json").read_bytes(), original)
        self.assertEqual((second / "doc.json").read_bytes(), original)
        self.assertFalse(marker.exists())
        # Unchanged files stay shared without rewriting any linked content.
        self.assertEqual((first / "doc.json").stat().st_ino, (third / "doc.json").stat().st_ino)
        self.assertNotEqual((first / ".revision").stat().st_ino, (third / ".revision").stat().st_ino)

    def test_annotated_qualified_tag_is_published_once_and_branch_ambiguity_fails(self) -> None:
        self.git("tag", "-a", "release", "-m", "release")
        self.sync(GB_SYNC_REF="refs/tags/release")
        first = self.live.resolve()
        self.sync(GB_SYNC_REF="refs/tags/release")
        self.assertEqual(self.live.resolve(), first)
        self.git("branch", "release")
        self.sync(success=False, GB_SYNC_REF="release")
        self.assertEqual(self.live.resolve(), first)

    def test_changed_source_path_on_same_commit_republishes(self) -> None:
        self.payload("nested", "nested/doc")
        self.commit()
        self.sync()
        self.sync(GB_SYNC_SUBPATH="nested")
        self.assertEqual(json.loads((self.live / "doc.json").read_text()), {"value": "nested"})
        self.assertFalse((self.live / "nested").exists())

    def test_changed_repository_url_uses_new_origin(self) -> None:
        self.sync()
        second = self.root / "different-upstream"
        subprocess.run(["git", "clone", "--quiet", str(self.repo), str(second)], check=True)
        self.repo = second
        self.git("config", "user.name", "Sync test")
        self.git("config", "user.email", "sync@example.test")
        self.payload("new origin")
        revision = self.commit()
        self.sync(GB_SYNC_REPO=str(second))
        self.assertEqual((self.live / ".revision").read_text().strip(), revision)
        self.assertEqual(json.loads((self.live / "doc.json").read_text())["value"], "new origin")

    def test_missing_verifier_and_symlink_escape_leave_live_untouched(self) -> None:
        self.sync()
        before = self.live.resolve()
        self.sync(success=False, GB_VERIFY="/nonexistent-verifier")
        external = self.root / "secret.json"
        external.write_text('{"secret":true}')
        (self.repo / "leak.json").symlink_to(external)
        self.commit()
        result = self.sync(success=False)
        self.assertIn("symlinks are forbidden", result.stdout)
        self.assertEqual(self.live.resolve(), before)
        self.assertFalse((self.live / "leak.json").exists())


class StrictVerificationTest(unittest.TestCase):
    def test_invalid_manifests_and_dangling_checksums_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "hashes.json"
            for content in ("[]", "null", '{"algorithm":"sha256","files":{}}', '{"algorithm":[],"files":{}}'):
                path.write_text(content)
                result = subprocess.run([str(BIN / "getbible-verify-tree"), directory], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
            path.unlink()
            (root / "missing.sha").write_text("0" * 40)
            result = subprocess.run([str(BIN / "getbible-verify-tree"), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("no safe JSON sibling", result.stderr)


if __name__ == "__main__":
    unittest.main()
