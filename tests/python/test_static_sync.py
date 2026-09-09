"""Exercise trusted static publication with tiny local Git repositories."""
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


@unittest.skipUnless(all(shutil.which(tool) for tool in ("git", "flock")), "git and flock required")
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
                        GB_SYNC_DATA=str(self.data), GB_EXPORT=str(BIN / "getbible-export-tree"),
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

    def test_atomic_rotation_and_fetch_failure_preserve_live_release(self) -> None:
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
        result = self.sync(success=False, GB_SYNC_REF="refs/heads/unavailable")
        self.assertIn("not found", result.stdout)
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

    def test_extra_files_are_exported_by_path_whatever_their_type(self) -> None:
        # The endpoint page and OpenAPI document may come from the repository
        # even when .html is not a served type; nothing else of that type,
        # no dotfile and no path with dot segments gets through.
        (self.repo / "docs").mkdir()
        (self.repo / "docs" / "index.html").write_text("<h1>docs</h1>")
        (self.repo / "docs" / "other.html").write_text("<h1>other</h1>")
        (self.repo / "openapi.json").write_text('{"openapi":"3.1.0"}')
        (self.repo / ".hidden.html").write_text("secret")
        self.commit()
        self.sync(GB_SYNC_EXTRA_FILES="docs/index.html,openapi.json")
        self.assertEqual((self.live / "docs" / "index.html").read_text(), "<h1>docs</h1>")
        self.assertTrue((self.live / "openapi.json").exists())
        self.assertFalse((self.live / "docs" / "other.html").exists())
        self.assertFalse((self.live / ".hidden.html").exists())
        # Changing the extra files republishes the same commit.
        self.sync(GB_SYNC_EXTRA_FILES="openapi.json")
        self.assertFalse((self.live / "docs").exists())
        self.assertTrue((self.live / "openapi.json").exists())
        result = self.sync(success=False, GB_SYNC_EXTRA_FILES="../escape.html")
        self.assertIn("invalid extra file path", result.stderr)
        result = self.sync(success=False, GB_SYNC_EXTRA_FILES=".git/config")
        self.assertIn("invalid extra file path", result.stderr)

    def test_root_label_publishes_the_tree_at_the_domain_root(self) -> None:
        self.sync(GB_SYNC_VERSION="root")
        live = self.data / "root"
        self.assertEqual(json.loads((live / "doc.json").read_text()), {"value": "first"})
        self.assertTrue((self.data / "releases" / "root").is_dir())
        result = self.sync(success=False, GB_SYNC_VERSION="latest")
        self.assertIn("Invalid version label", result.stderr)

    def test_missing_exporter_and_symlink_escape_leave_live_untouched(self) -> None:
        self.sync()
        before = self.live.resolve()
        self.sync(success=False, GB_EXPORT="/nonexistent-exporter")
        external = self.root / "secret.json"
        external.write_text('{"secret":true}')
        (self.repo / "leak.json").symlink_to(external)
        self.commit()
        result = self.sync(success=False)
        self.assertIn("symlinks are forbidden", result.stderr)
        self.assertEqual(self.live.resolve(), before)
        self.assertFalse((self.live / "leak.json").exists())
        self.assertEqual(list((self.data / "releases" / "v2").iterdir()), [before])


    def test_upstream_bytes_are_trusted_without_content_validation(self) -> None:
        self.sync()
        before = self.live.resolve()
        original = (before / "doc.json").read_bytes()
        payloads = {
            "doc.json": b'{"unfinished":\xff',
            "doc.sha": b"not the sibling digest\n",
            "hashes.json": b'{"algorithm":"unknown","files":{"../outside":"no"}}',
            "missing.sha": b"no JSON sibling exists",
            "empty.json": b"",
        }
        for name, content in payloads.items():
            (self.repo / name).write_bytes(content)
        revision = self.commit()
        # Legacy verifier configuration has no bearing on publication.
        self.sync(GB_VERIFY="/nonexistent-verifier")
        for name, content in payloads.items():
            self.assertEqual((self.live / name).read_bytes(), content)
        self.assertEqual((self.live / ".revision").read_text().strip(), revision)
        self.assertEqual((before / "doc.json").read_bytes(), original)

    def test_changed_blobs_and_deletions_do_not_depend_on_size_or_mtime(self) -> None:
        self.payload("steady", "unchanged")
        self.payload("gone", "nested/removed")
        self.commit()
        self.sync()
        before = self.live.resolve()
        old_stat = (before / "doc.json").stat()
        old_bytes = (before / "doc.json").read_bytes()
        self.payload("other")
        # Same file size and timestamp must never cause stale hardlink reuse.
        os.utime(self.repo / "doc.json", ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
        (self.repo / "nested" / "removed.json").unlink()
        (self.repo / "nested" / "removed.sha").unlink()
        self.commit()
        self.sync()
        current = self.live.resolve()
        self.assertEqual((current / "doc.json").stat().st_size, old_stat.st_size)
        self.assertEqual(json.loads((current / "doc.json").read_text()), {"value": "other"})
        self.assertNotEqual((current / "doc.json").stat().st_ino, old_stat.st_ino)
        self.assertNotEqual(int((current / "doc.json").stat().st_mtime), int(old_stat.st_mtime))
        self.assertEqual((before / "doc.json").read_bytes(), old_bytes)
        self.assertEqual((before / "unchanged.json").stat().st_ino,
                         (current / "unchanged.json").stat().st_ino)
        self.assertFalse((current / "nested").exists())
        self.assertTrue((before / "nested" / "removed.json").exists())

    def test_removing_all_upstream_files_publishes_the_empty_tree(self) -> None:
        self.sync()
        before = self.live.resolve()
        self.git("rm", "--quiet", "doc.json", "doc.sha")
        revision = self.commit()
        self.sync()
        self.assertNotEqual(self.live.resolve(), before)
        self.assertFalse((self.live / "doc.json").exists())
        self.assertFalse((self.live / "doc.sha").exists())
        self.assertEqual((self.live / ".revision").read_text().strip(), revision)

    def test_missing_export_index_does_not_block_sync(self) -> None:
        self.sync()
        before = self.live.resolve()
        # Previous installations have releases without the optional reuse index.
        (before / ".export-index.json").unlink()
        self.sync(GB_SYNC_FORCE="1")
        self.assertEqual((self.live / "doc.json").read_bytes(), (before / "doc.json").read_bytes())
        self.assertNotEqual(self.live.resolve(), before)


    def test_branch_advance_during_fetch_publishes_the_fetched_commit(self) -> None:
        first = self.git("rev-parse", "HEAD")
        self.payload("advanced")
        # Advance the local upstream immediately after reporting its old head.
        # This reproduces the ls-remote/fetch race without timing assumptions.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        launcher = bin_dir / "git"
        launcher.write_text("""#!/bin/sh
if [ "$1" = ls-remote ] && [ ! -f "$GB_TEST_ADVANCED" ]; then
    "$GB_TEST_GIT" "$@" || exit
    "$GB_TEST_GIT" -C "$GB_TEST_UPSTREAM" add . || exit
    "$GB_TEST_GIT" -C "$GB_TEST_UPSTREAM" commit --quiet -m advance || exit
    touch "$GB_TEST_ADVANCED"
else
    exec "$GB_TEST_GIT" "$@"
fi
""")
        launcher.chmod(0o755)
        self.sync(PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                  GB_TEST_GIT=shutil.which("git"), GB_TEST_UPSTREAM=str(self.repo),
                  GB_TEST_ADVANCED=str(self.root / "advanced"))
        revision = self.git("rev-parse", "HEAD")
        self.assertNotEqual(revision, first)
        self.assertEqual((self.live / ".revision").read_text().strip(), revision)
        self.assertEqual(json.loads((self.live / "doc.json").read_text()), {"value": "advanced"})


if __name__ == "__main__":
    unittest.main()
