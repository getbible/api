"""Exercise release review and edits in disposable tracked repositories."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/release-version.py"
FILES = ("VERSION", ".env.example", "compose.yaml", "Dockerfile")


class ReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.write_files("1.0.0")
        self.git("add", ".")
        self.git("commit", "-qm", "Base")
        self.base = self.git("rev-parse", "HEAD")
        self.write_files("2.0.0")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write_files(self, version, include_version=True):
        if include_version:
            (self.repo / "VERSION").write_text(version + "\n")
        else:
            (self.repo / "VERSION").unlink(missing_ok=True)
        (self.repo / ".env.example").write_text(f"# Settings\nGETBIBLE_IMAGE_TAG={version}\nUNCHANGED=true\n")
        (self.repo / "compose.yaml").write_text(f"services:\n  api:\n    image: example/api:${{GETBIBLE_IMAGE_TAG:-{version}}}\n")
        (self.repo / "Dockerfile").write_text(f"FROM example\nARG GETBIBLE_VERSION={version}\nARG UNCHANGED=true\n")

    def run_helper(self, *args):
        environment = dict(os.environ, GITHUB_STEP_SUMMARY=str(self.repo / "summary.md"))
        return subprocess.run([sys.executable, str(HELPER), "--repo", str(self.repo), *args],
                              cwd=self.repo, env=environment, capture_output=True, text=True, check=False)

    def review(self, body="Release-Version: 2.0.0", base=None):
        args = ["check", "--base-ref", base or self.base]
        if body is not None:
            event = self.repo / "event.json"
            event.write_text(json.dumps({"pull_request": {"body": body}}))
            args.extend(["--event", str(event)])
        return self.run_helper(*args)

    def snapshot(self):
        return {name: (self.repo / name).read_bytes() for name in FILES if (self.repo / name).exists()}

    def assert_defaults(self, version):
        self.assertEqual((self.repo / "VERSION").read_text(), version + "\n")
        self.assertIn(f"GETBIBLE_IMAGE_TAG={version}\n", (self.repo / ".env.example").read_text())
        self.assertIn(f"${{GETBIBLE_IMAGE_TAG:-{version}}}", (self.repo / "compose.yaml").read_text())
        self.assertIn(f"ARG GETBIBLE_VERSION={version}\n", (self.repo / "Dockerfile").read_text())

    def test_valid_review_reports_current_proposed_and_suggestions(self):
        before = self.snapshot()
        result = self.review()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = (self.repo / "summary.md").read_text()
        for expected in ("1.0.0", "2.0.0", "patch: `1.0.1`", "minor: `1.1.0`", "major: `2.0.0`", "review passed"):
            self.assertIn(expected, summary)
        self.assertEqual(self.snapshot(), before)

    def test_main_review_does_not_require_mutable_pr_metadata(self):
        result = self.review(body=None)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_duplicate_mismatched_and_injected_fields_are_rejected(self):
        marker = self.repo / "should-not-exist"
        for body in ("No field", "Release-Version:", "release-version: 2.0.0",
                     " Release-Version: 2.0.0", "Release-Version: 2.0.0\nRelease-Version: 2.0.0",
                     "Release-Version: 2.0.1", f"Release-Version: $(touch {marker})",
                     f"Release-Version: 2.0.0; touch {marker}"):
            with self.subTest(body=body):
                before = self.snapshot()
                result = self.review(body=body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Suggested patch: `1.0.1`", (self.repo / "summary.md").read_text())
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(marker.exists())

    def test_crlf_description_and_unrelated_text_preserve_the_exact_field(self):
        result = self.review(body="Description\r\nRelease-Version: 2.0.0\r\n\r\nValidation details")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_strict_semver_rejects_suffixes_prefixes_leading_zeroes_and_extra_parts(self):
        for value in ("v2.0.0", "02.0.0", "2.00.0", "2.0.01", "2.0", "2.0.0.1",
                      "2.0.0-dev", "2.0.0+build", "-2.0.0", "2.0.0\n3.0.0"):
            with self.subTest(value=value):
                (self.repo / "VERSION").write_text(value + "\n")
                result = self.review()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("strict MAJOR.MINOR.PATCH", result.stdout)
                self.assertIn("patch: `1.0.1`", result.stdout)

    def test_numeric_comparison_and_current_main_advance(self):
        self.write_files("2.9.9")
        self.git("add", *FILES)
        self.git("commit", "-qm", "Main advances")
        advanced = self.git("rev-parse", "HEAD")
        self.write_files("2.10.0")
        result = self.review(body="Release-Version: 2.10.0", base=advanced)
        self.assertEqual(result.returncode, 0, result.stderr)
        for proposed in ("2.9.9", "2.9.8", "1.99.99"):
            with self.subTest(proposed=proposed):
                self.write_files(proposed)
                result = self.review(body=f"Release-Version: {proposed}", base=advanced)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("greater than the current main", result.stdout)

    def test_pre_version_main_uses_numbered_env_baseline(self):
        self.write_files("1.0.0", include_version=False)
        self.git("add", *FILES)
        self.git("commit", "-qm", "Base before VERSION")
        baseline = self.git("rev-parse", "HEAD")
        self.write_files("2.0.0")
        result = self.review(base=baseline)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| 1.0.0 | 2.0.0 |", result.stdout)

    def test_malformed_pre_version_fallback_is_not_a_zero_version_guess(self):
        self.write_files("latest", include_version=False)
        self.git("add", *FILES)
        self.git("commit", "-qm", "Malformed baseline")
        baseline = self.git("rev-parse", "HEAD")
        self.write_files("2.0.0")
        result = self.review(base=baseline)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image default must contain", result.stdout)

    def test_malformed_existing_base_version_does_not_fall_back_to_env(self):
        (self.repo / "VERSION").write_text("broken\n")
        self.git("add", *FILES)
        self.git("commit", "-qm", "Invalid base VERSION")
        baseline = self.git("rev-parse", "HEAD")
        self.write_files("3.0.0")
        result = self.review(body="Release-Version: 3.0.0", base=baseline)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Base VERSION must contain", result.stdout)

    def test_default_mismatch_is_rejected(self):
        for name in (".env.example", "compose.yaml", "Dockerfile"):
            with self.subTest(name=name):
                self.write_files("2.0.0")
                path = self.repo / name
                path.write_text(path.read_text().replace("2.0.0", "1.0.0"))
                result = self.review()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} image default must match VERSION", result.stdout)

    def test_default_values_must_be_canonical_without_hidden_whitespace(self):
        for name in (".env.example", "compose.yaml", "Dockerfile"):
            with self.subTest(name=name):
                self.write_files("2.0.0")
                path = self.repo / name
                path.write_text(path.read_text().replace("2.0.0", " 2.0.0 "))
                before = self.snapshot()
                result = self.review()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no surrounding whitespace", result.stdout)
                result = self.run_helper("set", "patch")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), before)

    def test_missing_version_or_invalid_event_still_writes_suggestions(self):
        (self.repo / "VERSION").unlink()
        result = self.review()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch: `1.0.1`", result.stdout)
        self.write_files("2.0.0")
        invalid = self.repo / "invalid.json"
        invalid.write_text("{invalid")
        result = self.run_helper("check", "--base-ref", self.base, "--event", str(invalid))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch: `1.0.1`", result.stdout)

    def test_invalid_base_ref_is_not_executed_and_still_reports_proposal(self):
        marker = self.repo / "base-injection"
        result = self.review(base=f"$(touch {marker})")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn("2.0.0", result.stdout)
        self.assertIn("Cannot read the requested base commit", result.stdout)

    def test_set_explicit_and_standard_increments_synchronize_defaults(self):
        for requested, expected in (("2.0.0", "2.0.0"), ("patch", "2.0.1"),
                                    ("minor", "2.1.0"), ("major", "3.0.0"), ("4.5.6", "4.5.6")):
            with self.subTest(requested=requested):
                self.write_files("2.0.0")
                (self.repo / "Dockerfile").chmod(0o640)
                result = self.run_helper("set", requested)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_defaults(expected)
                self.assertIn(f"Release-Version: {expected}", result.stdout)
                self.assertIn("UNCHANGED=true", (self.repo / ".env.example").read_text())
                self.assertEqual(stat.S_IMODE((self.repo / "Dockerfile").stat().st_mode), 0o640)
                self.assertEqual(list(self.repo.glob(".release-version-*")), [])

    def test_set_same_number_repairs_valid_but_inconsistent_defaults(self):
        (self.repo / ".env.example").write_text("GETBIBLE_IMAGE_TAG=1.0.0\n")
        result = self.run_helper("set", "2.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_defaults("2.0.0")

    def test_set_can_introduce_version_using_existing_numbered_defaults(self):
        self.write_files("1.0.0", include_version=False)
        result = self.run_helper("set", "major")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_defaults("2.0.0")

    def test_invalid_request_or_default_shape_never_partially_updates_files(self):
        corruptions = [None, ("Dockerfile", "FROM example\n"),
                       (".env.example", "GETBIBLE_IMAGE_TAG=2.0.0\nGETBIBLE_IMAGE_TAG=2.0.0\n"),
                       ("compose.yaml", "image: example/api:${GETBIBLE_IMAGE_TAG:-latest}\n")]
        for corruption in corruptions:
            with self.subTest(corruption=corruption):
                self.write_files("2.0.0")
                if corruption:
                    (self.repo / corruption[0]).write_text(corruption[1])
                before = self.snapshot()
                result = self.run_helper("set", "patch" if corruption else "2.0.0; touch injected")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(list(self.repo.glob(".release-version-*")), [])
                self.assertFalse((self.repo / "injected").exists())

    def test_workflow_checks_pr_edits_without_images_or_write_permissions(self):
        workflow = (ROOT / ".github/workflows/release-version.yml").read_text()
        self.assertIn("types: [opened, synchronize, reopened, edited, ready_for_review]", workflow)
        self.assertIn("branches: [main]", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("group: release-version-${{ github.event.pull_request.number }}", workflow)
        self.assertIn("cancel-in-progress: true", workflow)
        self.assertIn('check --base-ref origin/main --event "$GITHUB_EVENT_PATH"', workflow)
        for forbidden in ("pull_request_target", "packages: write", "docker/build", "pull_request.body"):
            self.assertNotIn(forbidden, workflow)


if __name__ == "__main__":
    unittest.main()
