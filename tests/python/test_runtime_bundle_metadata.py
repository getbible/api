"""Execute the image builder's wheel-lock stage against real ZIP fixtures."""

from hashlib import sha256
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]


class RuntimeBundleMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Execute the actual embedded lock generator, without downloading
        # interpreters or dependencies or duplicating its parsing logic.
        builder = (ROOT / "docker/build-runtimes.sh").read_text()
        match = re.search(r"<<'PY'\n(.*?)\nPY\n", builder, re.DOTALL)
        self.assertIsNotNone(match)
        self.program = match.group(1)

    def wheel(self, members):
        path = self.root / "setuptools-84.0.0-py3-none-any.whl"
        with ZipFile(path, "w") as archive:
            for name, text in members.items():
                archive.writestr(name, text)
        return path

    def run_builder(self):
        return subprocess.run(
            [sys.executable, "-I", "-", str(self.root)],
            input=self.program,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_vendored_metadata_does_not_replace_the_wheel_identity(self):
        wheel = self.wheel({
            "setuptools-84.0.0.dist-info/METADATA":
                "Metadata-Version: 2.4\nName: setuptools\nVersion: 84.0.0\n",
            "setuptools/_vendor/packaging-26.3.dist-info/METADATA":
                "Metadata-Version: 2.4\nName: packaging\nVersion: 26.3\n",
            "setuptools/_vendor/wheel-0.48.0.dist-info/METADATA":
                "Metadata-Version: 2.4\nName: wheel\nVersion: 0.48.0\n",
        })
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.root / "packages.requirements").read_text(),
            f"setuptools==84.0.0 --hash=sha256:{sha256(wheel.read_bytes()).hexdigest()}\n",
        )

    def test_nested_metadata_cannot_stand_in_for_missing_root_metadata(self):
        self.wheel({
            "setuptools/_vendor/packaging-26.3.dist-info/METADATA":
                "Name: packaging\nVersion: 26.3\n",
        })
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid wheel metadata", result.stderr)
        self.assertFalse((self.root / "packages.requirements").exists())

    def test_multiple_root_distribution_metadata_remains_invalid(self):
        self.wheel({
            "setuptools-84.0.0.dist-info/METADATA": "Name: setuptools\nVersion: 84.0.0\n",
            "unexpected-1.0.dist-info/METADATA": "Name: unexpected\nVersion: 1.0\n",
        })
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid wheel metadata", result.stderr)


if __name__ == "__main__":
    unittest.main()
