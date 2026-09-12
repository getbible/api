"""Execute merge planning and publication against controlled GitHub responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/docker.yml"


def workflow_script(name):
    step = WORKFLOW.read_text().split(f"      - name: {name}\n", 1)[1]
    run = step.split("        run: |\n", 1)[1]
    lines = []
    for line in run.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line)
    return textwrap.dedent("\n".join(lines))


FAKE_CLIENT = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

client = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_RELEASE_EVENTS'], 'a') as stream:
    stream.write(json.dumps([client, *args]) + '\\n')
if client == 'docker':
    if args[:3] == ['buildx', 'imagetools', 'inspect']:
        mode = 'CANDIDATE' if ':sha-' in args[-1] else 'EXISTING'
        print(os.environ.get('TEST_RELEASE_' + mode, '{"schemaVersion":2,"manifests":[]}'))
        if os.environ.get('TEST_RELEASE_' + mode + '_ERROR'):
            print(os.environ['TEST_RELEASE_' + mode + '_ERROR'], file=sys.stderr)
            sys.exit(1)
    elif args[:3] != ['buildx', 'imagetools', 'create']:
        sys.exit(2)
    elif args[args.index('-t') + 1].endswith(':latest') and os.environ.get('TEST_RELEASE_LATEST_ERROR'):
        print(os.environ['TEST_RELEASE_LATEST_ERROR'], file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if args[:1] != ['api']:
    sys.exit(2)
if any('/commits/' in arg and arg.endswith('/pulls') for arg in args):
    mode = 'PRS'
    if '--paginate' not in args or '--slurp' not in args:
        sys.exit(2)
    result = os.environ.get('TEST_RELEASE_PRS', '[]')
elif any('/packages/container/api/versions?' in arg for arg in args):
    mode = 'TAGS'
    if '--paginate' not in args:
        sys.exit(2)
    result = os.environ.get('TEST_RELEASE_TAGS', '')
elif any(arg.endswith('/git/ref/heads/main') for arg in args):
    mode = 'MAIN'
    result = os.environ.get('TEST_RELEASE_MAIN', os.environ['GITHUB_SHA'])
else:
    sys.exit(2)
print(result)
if os.environ.get('TEST_RELEASE_' + mode + '_ERROR'):
    print(os.environ['TEST_RELEASE_' + mode + '_ERROR'], file=sys.stderr)
    sys.exit(1)
"""


class DockerReleaseTest(unittest.TestCase):
    def execute(self, script, location, **settings):
        for client in ("docker", "gh"):
            executable = location / client
            executable.write_text(FAKE_CLIENT)
            executable.chmod(0o755)
        events_path = location / "events.jsonl"
        environment = dict(os.environ)
        environment.update({
            "PATH": f"{location}:{os.environ['PATH']}",
            "GITHUB_REPOSITORY": "example/api",
            "GITHUB_REPOSITORY_OWNER": "example",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main",
            "RUNNER_TEMP": str(location),
            "GITHUB_OUTPUT": str(location / "output"),
            "TEST_RELEASE_EVENTS": str(events_path),
        })
        environment.update(settings)
        result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"],
                                input=workflow_script(script), text=True, capture_output=True,
                                env=environment, cwd=location, check=False)
        events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
        output = location / "output"
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
        return result, events, outputs

    def run_plan(self, previous="2.0.0", current="2.0.0", pr_change=None, **settings):
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory)
            def git(*args):
                return subprocess.run(["git", *args], cwd=location, check=True, text=True,
                                      capture_output=True).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            if previous is not None:
                (location / "VERSION").write_text(previous + "\n")
                git("add", "VERSION")
            git("commit", "-qm", "Previous main", "--allow-empty")
            before = git("rev-parse", "HEAD")
            (location / "VERSION").write_text(current + "\n")
            git("add", "VERSION")
            git("commit", "-qm", "Merged change", "--allow-empty")
            sha = git("rev-parse", "HEAD")
            pr = {"merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": sha,
                  "base": {"ref": "main", "repo": {"full_name": "example/api"}}}
            if pr_change:
                pr_change(pr)
            environment = {"GITHUB_SHA": sha, "PREVIOUS_MAIN": before,
                           "TEST_RELEASE_PRS": json.dumps([[pr]])}
            environment.update(settings)
            return self.execute("Plan merged main image", location, **environment)

    def run_publication(self, numbered="2.0.0", **settings):
        with tempfile.TemporaryDirectory() as directory:
            result, events, _ = self.execute("Publish merged main manifest and optional numbered release",
                                             Path(directory), NUMBERED_VERSION=numbered, **settings)
        published = [event[event.index("-t") + 1] for event in events
                     if event[:4] == ["docker", "buildx", "imagetools", "create"]]
        return result, events, published

    def test_workflow_builds_only_on_main_push_and_requires_merge_gate(self):
        workflow = WORKFLOW.read_text()
        triggers = workflow.split("on:\n", 1)[1].split("permissions:\n", 1)[0]
        self.assertEqual(triggers.strip(), "push:\n    branches: [main]")
        self.assertIn("group: docker-main\n  queue: max\n  cancel-in-progress: false", workflow)
        for job in ("plan", "validate", "publish", "manifest"):
            section = workflow.split(f"  {job}:\n", 1)[1].split("    runs-on:", 1)[0]
            self.assertIn("if: github.event_name == 'push' && github.ref == 'refs/heads/main'", section)
            if job != "plan":
                self.assertIn("needs.plan.outputs.build == 'true'", section)

    def test_first_version_is_numbered_without_a_git_tag(self):
        result, _, output = self.run_plan(previous=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {"build": "true", "image_version": "2.0.0", "numbered_version": "2.0.0"})

    def test_changed_version_is_numbered(self):
        result, _, output = self.run_plan(previous="1.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["numbered_version"], "2.0.0")
        self.assertEqual(output["image_version"], "2.0.0")

    def test_unchanged_version_keeps_numbered_release_and_uses_development_label(self):
        result, _, output = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {"build": "true", "image_version": "2.0.0-dev", "numbered_version": ""})

    def test_gate_uses_final_merge_commit_instead_of_pr_head(self):
        result, _, output = self.run_plan(pr_change=lambda pr: pr.update(head={"sha": "b" * 40}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["build"], "true")

    def test_direct_unmerged_and_unrelated_pushes_skip_build(self):
        for change in (lambda pr: pr.update(merged_at=None),
                       lambda pr: pr.update(merge_commit_sha="b" * 40),
                       lambda pr: pr["base"].update(ref="staging"),
                       lambda pr: pr["base"]["repo"].update(full_name="elsewhere/api")):
            with self.subTest(change=change):
                result, _, output = self.run_plan(pr_change=change)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, {"build": "false"})
        result, _, output = self.run_plan(TEST_RELEASE_PRS="[[]]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {"build": "false"})

    def test_pr_tag_feature_and_manual_contexts_do_not_request_merge_or_build(self):
        for event, ref in (("pull_request", "refs/pull/13/merge"), ("push", "refs/tags/v2.0.0"),
                           ("push", "refs/heads/feature/demo"), ("workflow_dispatch", "refs/heads/main")):
            with self.subTest(event=event, ref=ref):
                result, events, output = self.run_plan(GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, {"build": "false"})
                self.assertEqual(events, [])

    def test_merge_api_failure_and_invalid_version_fail_before_build(self):
        for settings in ({"TEST_RELEASE_PRS_ERROR": "HTTP 403 Forbidden"}, {"current": "not-a-version"}):
            with self.subTest(settings=settings):
                result, _, output = self.run_plan(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, {"build": "false"})

    def test_release_publishes_number_and_latest_from_the_accepted_manifest(self):
        result, events, published = self.run_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published[-2:], ["ghcr.io/example/api:2.0.0", "ghcr.io/example/api:latest"])
        creates = [event for event in events if event[:4] == ["docker", "buildx", "imagetools", "create"]]
        candidate = f"ghcr.io/example/api:sha-{'a' * 40}"
        self.assertEqual(creates[0][-2:], [candidate + "-amd64", candidate + "-arm64"])
        self.assertTrue(all(event[-1] == candidate for event in creates[1:]))

    def test_regular_merge_publishes_latest_without_numbered_lookup(self):
        result, events, published = self.run_publication(numbered="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, [f"ghcr.io/example/api:sha-{'a' * 40}", "ghcr.io/example/api:latest"])
        self.assertFalse(any("/packages/" in arg for event in events for arg in event))

    def test_conflicting_numbered_release_is_never_overwritten(self):
        result, _, published = self.run_publication(TEST_RELEASE_TAGS="1.0.0\n2.0.0\nlatest",
                                                   TEST_RELEASE_EXISTING='{"schemaVersion":2,"manifests":["different"]}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(len(published), 1)

    def test_matching_numbered_release_is_retained_and_latest_completes(self):
        result, _, published = self.run_publication(TEST_RELEASE_TAGS="2.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, [f"ghcr.io/example/api:sha-{'a' * 40}", "ghcr.io/example/api:latest"])
        self.assertIn("retaining it", result.stdout)

    def test_failed_latest_push_can_retry_the_same_numbered_image(self):
        failed, _, attempted = self.run_publication(TEST_RELEASE_LATEST_ERROR="network unavailable")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("ghcr.io/example/api:2.0.0", attempted)
        retry, _, published = self.run_publication(TEST_RELEASE_TAGS="2.0.0")
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertNotIn("ghcr.io/example/api:2.0.0", published)
        self.assertIn("ghcr.io/example/api:latest", published)

    def test_existing_or_candidate_manifest_lookup_errors_fail_closed(self):
        for mode in ("EXISTING", "CANDIDATE"):
            with self.subTest(mode=mode):
                result, _, published = self.run_publication(TEST_RELEASE_TAGS="2.0.0",
                                                            **{f"TEST_RELEASE_{mode}_ERROR": "unauthorized"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(published), 1)

    def test_tag_api_failures_are_not_evidence_of_a_missing_release(self):
        for failure in ("HTTP 401 Unauthorized", "HTTP 403 Forbidden", "HTTP 404 Not Found",
                        "dial tcp: network is unreachable"):
            with self.subTest(failure=failure):
                result, _, published = self.run_publication(TEST_RELEASE_TAGS="partial-page-tag",
                                                            TEST_RELEASE_TAGS_ERROR=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(published), 1)

    def test_stale_rerun_does_not_move_latest(self):
        result, _, published = self.run_publication(numbered="", TEST_RELEASE_MAIN="b" * 40)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, [f"ghcr.io/example/api:sha-{'a' * 40}"])

    def test_main_lookup_error_or_invalid_revision_never_moves_latest(self):
        for settings in ({"TEST_RELEASE_MAIN_ERROR": "HTTP 403 Forbidden"}, {"TEST_RELEASE_MAIN": "unknown"}):
            with self.subTest(settings=settings):
                result, _, published = self.run_publication(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(published, [f"ghcr.io/example/api:sha-{'a' * 40}"])


if __name__ == "__main__":
    unittest.main()
