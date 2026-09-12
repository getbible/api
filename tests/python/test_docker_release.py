"""Exercise the publication shell against controlled registry/API responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/docker.yml"


def manifest_script():
    workflow = WORKFLOW.read_text()
    step = workflow.split("      - name: Candidate manifest or immutable release and latest\n", 1)[1]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


FAKE_CLIENT = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

client = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_RELEASE_EVENTS'], 'a') as stream:
    stream.write(json.dumps([client, *args]) + '\\n')
if client == 'gh':
    if args != ['api', '--paginate', 'orgs/example/packages/container/api/versions?per_page=100',
                '--jq', '.[].metadata.container.tags[]']:
        sys.exit(2)
    print(os.environ.get('TEST_RELEASE_TAGS', ''))
    if os.environ.get('TEST_RELEASE_API_ERROR'):
        print(os.environ['TEST_RELEASE_API_ERROR'], file=sys.stderr)
        sys.exit(1)
elif args[:3] == ['buildx', 'imagetools', 'create']:
    pass
elif args[:1] == ['pull']:
    if os.environ.get('TEST_RELEASE_PULL_ERROR'):
        print(os.environ['TEST_RELEASE_PULL_ERROR'], file=sys.stderr)
        sys.exit(1)
elif args[:1] == ['inspect']:
    print(os.environ.get('TEST_RELEASE_LATEST_VERSION', '1.0.0'))
else:
    sys.exit(2)
"""


class DockerReleaseTest(unittest.TestCase):
    def run_publication(self, ref="refs/tags/v2.0.0", tags="", **settings):
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory)
            for client in ("docker", "gh"):
                executable = location / client
                executable.write_text(FAKE_CLIENT)
                executable.chmod(0o755)
            events_path = location / "events.jsonl"
            environment = dict(os.environ)
            environment.update({
                "PATH": f"{location}:{os.environ['PATH']}",
                "RELEASE_REF": ref,
                "GITHUB_REPOSITORY": "example/api",
                "GITHUB_REPOSITORY_OWNER": "example",
                "GITHUB_SHA": "a" * 40,
                "RUNNER_TEMP": directory,
                "TEST_RELEASE_EVENTS": str(events_path),
                "TEST_RELEASE_TAGS": tags,
            })
            environment.update({f"TEST_RELEASE_{key}": value for key, value in settings.items()})
            result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"],
                                    input=manifest_script(), text=True, capture_output=True,
                                    env=environment, cwd=directory, check=False)
            events = [json.loads(line) for line in events_path.read_text().splitlines()]
        published = [event[event.index("-t") + 1] for event in events
                     if event[:4] == ["docker", "buildx", "imagetools", "create"]]
        return result, events, published

    def test_candidate_publishes_only_commit_manifest_without_release_lookup(self):
        result, events, published = self.run_publication(ref="refs/heads/main")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published, [f"ghcr.io/example/api:sha-{'a' * 40}"])
        self.assertFalse(any(event[0] == "gh" for event in events))

    def test_new_release_publishes_number_and_latest(self):
        result, events, published = self.run_publication(tags="sha-fixture-amd64\nsha-fixture-arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published[-2:], ["ghcr.io/example/api:2.0.0", "ghcr.io/example/api:latest"])
        self.assertFalse(any(event[:2] == ["docker", "pull"] for event in events))

    def test_newer_release_updates_latest(self):
        result, _, published = self.run_publication(tags="1.0.0\nlatest", LATEST_VERSION="1.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published[-2:], ["ghcr.io/example/api:2.0.0", "ghcr.io/example/api:latest"])

    def test_older_maintenance_release_preserves_latest(self):
        result, _, published = self.run_publication(ref="refs/tags/v1.0.1", tags="2.0.0\nlatest",
                                                     LATEST_VERSION="2.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(published[-1], "ghcr.io/example/api:1.0.1")
        self.assertNotIn("ghcr.io/example/api:latest", published)

    def test_existing_numbered_release_is_never_overwritten(self):
        result, _, published = self.run_publication(tags="1.0.0\n2.0.0\nlatest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(len(published), 1)

    def test_api_failures_including_not_found_are_not_evidence_of_a_missing_tag(self):
        for failure in ("HTTP 401 Unauthorized", "HTTP 403 Forbidden", "HTTP 404 Not Found",
                        "dial tcp: network is unreachable"):
            with self.subTest(failure=failure):
                result, _, published = self.run_publication(tags="partial-page-tag", API_ERROR=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(published), 1)

    def test_latest_pull_failure_does_not_replace_stable_tags(self):
        for failure in ("unauthorized", "manifest unknown", "network is unreachable"):
            with self.subTest(failure=failure):
                result, _, published = self.run_publication(tags="latest", PULL_ERROR=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(published), 1)

    def test_invalid_existing_version_does_not_replace_stable_tags(self):
        result, _, published = self.run_publication(tags="latest", LATEST_VERSION="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(published), 1)


if __name__ == "__main__":
    unittest.main()
