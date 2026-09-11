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
                        GB_SYNC_DATA=str(self.data), GB_SYNC_KEY=str(self.home / ".ssh" / "id_ed25519"),
                        GB_EXPORT=str(BIN / "getbible-export-tree"),
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

    def test_unchanged_check_renews_freshness_without_republishing(self) -> None:
        self.sync()
        first = self.live.resolve()
        marker = self.data / ".freshness-v2"
        self.assertTrue(marker.is_file())
        os.utime(marker, (1, 1))
        self.sync()
        self.assertEqual(self.live.resolve(), first)
        self.assertGreater(marker.stat().st_mtime, 1)
        self.assertEqual(len(list((self.data / "releases/v2").iterdir())), 1)

    def test_storage_refusal_preserves_current_publication(self) -> None:
        self.sync()
        first = self.live.resolve()
        state = self.root / "storage"
        state.mkdir()
        import time
        (state / "usage.json").write_text(json.dumps({"generated_at": time.time(), "used_bytes": 1024**3}))
        self.payload("replacement")
        self.commit()
        refused = self.sync(success=False, GB_SYNC_STORAGE_MAX_GIB="1", GB_SYNC_STORAGE_STATE=str(state),
                            GB_STORAGE_GUARD=str(BIN / "getbible-storage-guard"))
        self.assertIn("serving and rollback releases were retained", refused.stderr)
        self.assertEqual(self.live.resolve(), first)
        self.assertEqual(len(list((self.data / "releases/v2").iterdir())), 1)

    def test_effective_storage_limit_overrides_installed_limit(self) -> None:
        import time
        state = self.root / "storage"
        state.mkdir()
        (state / "usage.json").write_text(json.dumps({"generated_at": time.time(), "used_bytes": 1024**3}))
        settings = {"GB_SYNC_STORAGE_STATE": str(state), "GB_STORAGE_GUARD": str(BIN / "getbible-storage-guard")}
        # An increased effective cap immediately permits this existing endpoint.
        self.sync(GB_SYNC_STORAGE_MAX_GIB="1", GETBIBLE_STORAGE_MAX_GIB="000002", **settings)
        first = self.live.resolve()
        self.payload("replacement")
        self.commit()
        # A decreased cap is honored without reinstalling the endpoint unit.
        self.sync(success=False, GB_SYNC_STORAGE_MAX_GIB="2", GETBIBLE_STORAGE_MAX_GIB="1", **settings)
        self.assertEqual(self.live.resolve(), first)
        self.sync(success=False, GB_SYNC_STORAGE_MAX_GIB="1", GETBIBLE_STORAGE_MAX_GIB="", **settings)
        self.assertEqual(self.live.resolve(), first)
        # Explicit zero disables the guard even when the installed cap is set.
        self.sync(GB_SYNC_STORAGE_MAX_GIB="1", GETBIBLE_STORAGE_MAX_GIB="000000", **settings)
        self.assertNotEqual(self.live.resolve(), first)

    def test_invalid_storage_limit_fails_before_creating_sync_directories(self) -> None:
        for value in ("-1", "1.5", "nan", "1000000", "1e2", "1;true", ""):
            with self.subTest(value=value):
                overrides = {"GETBIBLE_STORAGE_MAX_GIB": value, "GB_SYNC_STORAGE_MAX_GIB": "invalid"}
                result = self.sync(success=False, **overrides)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Invalid storage limit", result.stderr)
                self.assertFalse(self.home.exists())
                self.assertFalse(self.data.exists())

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
        # Forced exports reread Git so a reset also repairs locally damaged bytes.
        self.assertNotEqual((first / "doc.json").stat().st_ino, (third / "doc.json").stat().st_ino)
        self.assertNotEqual((second / "doc.json").stat().st_ino, (third / "doc.json").stat().st_ino)
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

    def ssh_transport(self, repositories: dict[str, tuple[Path, Path]]) -> dict[str, str]:
        """Exercise Git's actual SSH invocations against local upload-pack servers."""
        bin_dir = self.root / "ssh-bin"
        bin_dir.mkdir()
        config = self.root / "ssh-repositories.json"
        config.write_text(json.dumps({name: [str(repo), str(key)]
                                      for name, (repo, key) in repositories.items()}))
        launcher = bin_dir / "ssh"
        launcher.write_text("""#!/usr/bin/env python3
import json
import os
import shlex
import sys

args = sys.argv[1:]
options = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '-o']
assert args[args.index('-F') + 1] == '/dev/null', args
for option in ('IdentityAgent=none', 'IdentitiesOnly=yes',
               'StrictHostKeyChecking=yes', 'BatchMode=yes'):
    assert option in options, (option, args)
assert any(option.startswith('UserKnownHostsFile=') for option in options), args
identity = args[args.index('-i') + 1]
command = shlex.split(args[-1])
assert command[0] == 'git-upload-pack', command
with open(os.environ['GB_TEST_SSH_REPOSITORIES']) as stream:
    repository, expected_identity = json.load(stream)[command[1]]
assert identity == expected_identity, (identity, expected_identity)
assert os.path.isfile(identity), identity
with open(os.environ['GB_TEST_SSH_CALLS'], 'a') as stream:
    stream.write(json.dumps({'repository': command[1], 'identity': identity}) + '\\n')
os.execvp('git-upload-pack', ['git-upload-pack', repository])
""")
        launcher.chmod(0o755)
        return {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                "GIT_SSH_VARIANT": "ssh", "SSH_AUTH_SOCK": "/untrusted-agent.sock",
                "GB_TEST_SSH_REPOSITORIES": str(config),
                "GB_TEST_SSH_CALLS": str(self.root / "ssh-calls.jsonl")}

    def test_endpoints_use_their_selected_ssh_keys_for_discovery_and_fetch(self) -> None:
        second = self.root / "second-upstream"
        subprocess.run(["git", "clone", "--quiet", str(self.repo), str(second)], check=True)
        original = self.repo
        self.repo = second
        self.git("config", "user.name", "Sync test")
        self.git("config", "user.email", "sync@example.test")
        self.payload("second endpoint")
        self.commit()
        self.repo = original
        keys = self.home / ".ssh" / "keys with spaces"
        keys.mkdir(parents=True)
        first_key, second_key = keys / "v2's identity", keys / "v3 identity"
        first_key.write_text("v2 fixture identity")
        second_key.write_text("v3 fixture identity")
        transport = self.ssh_transport({"owner/v2.git": (original, first_key),
                                        "owner/v3.git": (second, second_key)})
        self.sync(GB_SYNC_REPO="git@origin.example.test:owner/v2.git",
                  GB_SYNC_KEY=str(first_key), **transport)
        first_release = self.live.resolve()
        self.sync(GB_SYNC_VERSION="v3", GB_SYNC_REPO="git@origin.example.test:owner/v3.git",
                  GB_SYNC_KEY=str(second_key), **transport)
        self.assertEqual(self.live.resolve(), first_release)
        self.assertEqual(json.loads((self.live / "doc.json").read_text())["value"], "first")
        self.assertEqual(json.loads((self.data / "v3" / "doc.json").read_text())["value"],
                         "second endpoint")
        calls = [json.loads(line) for line in (self.root / "ssh-calls.jsonl").read_text().splitlines()]
        # Both ls-remote and fetch authenticate to each repository. Git must
        # never offer the sibling identity or identities from an agent/config.
        for repository, key in (("owner/v2.git", first_key), ("owner/v3.git", second_key)):
            matching = [call for call in calls if call["repository"] == repository]
            self.assertGreaterEqual(len(matching), 2)
            self.assertEqual({call["identity"] for call in matching}, {str(key)})

    def test_runner_requires_an_explicit_endpoint_key(self) -> None:
        self.env.pop("GB_SYNC_KEY", None)
        result = self.sync(success=False)
        self.assertIn("GB_SYNC_KEY", result.stderr)
        self.assertFalse(self.live.exists())

    def test_repository_access_checks_selected_key_and_rejects_missing_refs(self) -> None:
        key = self.home / ".ssh" / "endpoint key"
        key.parent.mkdir(parents=True)
        key.write_text("endpoint fixture identity")
        transport = self.ssh_transport({"owner/v2.git": (self.repo, key)})
        command = """
source "$GB_TEST_ROOT/src/lib/core.sh"
source "$GB_TEST_ROOT/src/lib/sync.sh"
ep_version_get() {
    case "$3" in
        REPO_URL) printf '%s\\n' 'git@origin.example.test:owner/v2.git' ;;
        REPO_REF) printf '%s\\n' "$GB_TEST_REF" ;;
    esac
}
sync_home() { printf '%s\\n' "$GB_TEST_HOME"; }
sync_user() { printf 'fixture-sync-user\\n'; }
sync_key_file() { printf '%s\\n' "$GB_TEST_KEY"; }
runuser() { shift 3; "$@"; }
sync_test_access static.example.test v2
"""
        env = dict(os.environ, **transport, GB_PREFIX="", GB_TEST_ROOT=str(ROOT),
                   GB_TEST_HOME=str(self.home), GB_TEST_KEY=str(key), GB_TEST_REF="main")
        result = subprocess.run(["bash", "-c", command], env=env, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(self.git("rev-parse", "HEAD"), result.stdout)
        for overrides in ({"GB_TEST_REF": "missing"}, {"GB_TEST_KEY": str(key) + "-wrong"}):
            with self.subTest(overrides=overrides):
                result = subprocess.run(["bash", "-c", command], env=dict(env, **overrides),
                                        capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

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
        self.sync()
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


    def test_force_restores_repository_bytes_after_local_damage(self) -> None:
        self.sync()
        before = self.live.resolve()
        original = (before / "doc.json").read_bytes()
        damaged = original.replace(b"first", b"wrong")
        (before / "doc.json").write_bytes(damaged)
        self.sync(GB_SYNC_FORCE="1")
        self.assertEqual((self.live / "doc.json").read_bytes(), original)
        self.assertEqual((before / "doc.json").read_bytes(), damaged)
        self.assertNotEqual((self.live / "doc.json").stat().st_ino,
                            (before / "doc.json").stat().st_ino)


if __name__ == "__main__":
    unittest.main()
