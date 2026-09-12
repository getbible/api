#!/usr/bin/env python3
"""Review a numbered release or update its tracked Docker defaults."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
TARGETS = {
    ".env.example": re.compile(r"^GETBIBLE_IMAGE_TAG=(?P<version>[^\r\n]*)$", re.MULTILINE),
    "compose.yaml": re.compile(r"\$\{GETBIBLE_IMAGE_TAG:-(?P<version>[^}\r\n]*)\}"),
    "Dockerfile": re.compile(r"^ARG GETBIBLE_VERSION=(?P<version>[^\r\n]*)$", re.MULTILINE),
}


class ReleaseError(ValueError):
    pass


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, value: str, source: str) -> Version:
        match = SEMVER.fullmatch(value.strip())
        if match is None:
            raise ReleaseError(f"{source} must contain a strict MAJOR.MINOR.PATCH version without leading zeroes or a suffix.")
        try:
            return cls(*(int(part) for part in match.groups()))
        except ValueError as error:
            raise ReleaseError(f"{source} contains an invalid version number.") from error

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    def bump(self, part: str) -> Version:
        if part == "major":
            return Version(self.major + 1, 0, 0)
        if part == "minor":
            return Version(self.major, self.minor + 1, 0)
        return Version(self.major, self.minor, self.patch + 1)


@dataclass
class Review:
    previous: Version | None = None
    proposed: Version | None = None
    errors: list[str] = field(default_factory=list)

    def summary(self) -> str:
        lines = ["## Release version", "", "| Current main | Proposed VERSION |", "| --- | --- |",
                 f"| {self.previous or 'Unavailable'} | {self.proposed or 'Missing or invalid'} |", ""]
        if self.previous is not None:
            lines.extend([f"Suggested patch: `{self.previous.bump('patch')}` · "
                          f"minor: `{self.previous.bump('minor')}` · "
                          f"major: `{self.previous.bump('major')}`", ""])
        else:
            lines.extend(["Version suggestions are unavailable until the main version can be read.", ""])
        if self.errors:
            lines.append("Release version review failed:")
            lines.extend(f"- {error}" for error in self.errors)
        else:
            lines.append(f"Release version review passed. PR review field: `Release-Version: {self.proposed}`")
        return "\n".join(lines) + "\n"


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True, check=False)
    if result.returncode:
        raise ReleaseError("Cannot read the requested base commit. Fetch current origin/main and try again.")
    return result.stdout


def target_value(content: str, name: str) -> tuple[re.Match, Version]:
    matches = list(TARGETS[name].finditer(content))
    if len(matches) != 1:
        raise ReleaseError(f"{name} must contain exactly one image version default.")
    match = matches[0]
    raw = match.group("version")
    version = Version.parse(raw, f"{name} image default")
    if raw != str(version):
        raise ReleaseError(f"{name} image default must be a canonical version with no surrounding whitespace.")
    return match, version


def base_version(repo: Path, base_ref: str) -> Version:
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", f"{base_ref}^{{commit}}").strip()
    if git(repo, "ls-tree", "--name-only", commit, "--", "VERSION").strip():
        return Version.parse(git(repo, "show", f"{commit}:VERSION"), "Base VERSION")
    # Before VERSION was introduced, the numbered image example was tracked.
    # A missing or malformed fallback is an error, never a zero-version guess.
    _, version = target_value(git(repo, "show", f"{commit}:.env.example"), ".env.example")
    return version


def pr_version(event_path: Path) -> Version:
    try:
        event = json.loads(event_path.read_text(encoding="utf-8"))
        body = event["pull_request"]["body"] or ""
        if not isinstance(body, str):
            raise TypeError
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ReleaseError("Cannot read the pull request description from the event JSON.") from error
    values = [line[len("Release-Version:"):] for line in body.splitlines()
              if line.startswith("Release-Version:")]
    if len(values) != 1:
        raise ReleaseError("The PR description must contain exactly one Release-Version: field on its own line.")
    return Version.parse(values[0], "PR Release-Version")


def check(repo: Path, base_ref: str, event_path: Path | None) -> Review:
    review = Review()
    try:
        review.previous = base_version(repo, base_ref)
    except (ReleaseError, OSError, UnicodeError) as error:
        review.errors.append(str(error) if isinstance(error, ReleaseError) else "Cannot read the main release version.")
    try:
        review.proposed = Version.parse((repo / "VERSION").read_text(encoding="utf-8"), "VERSION")
    except (ReleaseError, OSError, UnicodeError) as error:
        review.errors.append(str(error) if isinstance(error, ReleaseError) else "VERSION is missing or unreadable.")
    if review.previous is not None and review.proposed is not None and review.proposed <= review.previous:
        review.errors.append("VERSION must be greater than the current main version; choose a new number after concurrent merges.")
    for name in TARGETS:
        try:
            _, value = target_value((repo / name).read_text(encoding="utf-8"), name)
            if review.proposed is not None and value != review.proposed:
                review.errors.append(f"{name} image default must match VERSION. Use scripts/release-version.py set to synchronize defaults.")
        except (ReleaseError, OSError, UnicodeError) as error:
            review.errors.append(str(error) if isinstance(error, ReleaseError) else f"{name} is missing or unreadable.")
    if event_path is not None:
        try:
            proposed = pr_version(event_path)
            if review.proposed is not None and proposed != review.proposed:
                review.errors.append("PR Release-Version must equal the committed VERSION.")
        except ReleaseError as error:
            review.errors.append(str(error))
    return review


def set_version(repo: Path, requested: str) -> Version:
    # Validate every input and replacement before any tracked file is written.
    contents = {name: (repo / name).read_text(encoding="utf-8") for name in TARGETS}
    defaults = {name: target_value(content, name) for name, content in contents.items()}
    version_path = repo / "VERSION"
    current = Version.parse(version_path.read_text(encoding="utf-8"), "VERSION") if version_path.exists() else defaults[".env.example"][1]
    desired = current.bump(requested) if requested in ("patch", "minor", "major") else Version.parse(requested, "Requested version")
    changes = {version_path: f"{desired}\n"}
    for name, content in contents.items():
        match = defaults[name][0]
        changes[repo / name] = content[:match.start("version")] + str(desired) + content[match.end("version"):]
    staged: dict[Path, Path] = {}
    try:
        for path, content in changes.items():
            descriptor, temporary = tempfile.mkstemp(prefix=".release-version-", dir=path.parent)
            staged[path] = Path(temporary)
            mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), mode)
        for path, temporary in staged.items():
            os.replace(temporary, path)
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)
    return desired


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    commands = parser.add_subparsers(dest="command", required=True)
    review = commands.add_parser("check", help="Review the proposed release against current main.")
    review.add_argument("--base-ref", required=True)
    review.add_argument("--event", type=Path, help="Require a matching Release-Version field in this PR event JSON.")
    setter = commands.add_parser("set", help="Set a version and synchronize all numbered Docker defaults.")
    setter.add_argument("version", help="MAJOR.MINOR.PATCH, patch, minor or major")
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        result = check(arguments.repo, arguments.base_ref, arguments.event)
        summary = result.summary()
        print(summary, end="")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            try:
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                    stream.write(summary + "\n")
            except OSError:
                print("Cannot write the Actions release version summary.", file=sys.stderr)
                return 1
        return int(bool(result.errors))
    try:
        version = set_version(arguments.repo, arguments.version)
    except (ReleaseError, OSError, UnicodeError) as error:
        message = str(error) if isinstance(error, ReleaseError) else "Cannot update the tracked release version files."
        print(message, file=sys.stderr)
        return 1
    print(f"Updated VERSION and Docker defaults to {version}.\nRelease-Version: {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
