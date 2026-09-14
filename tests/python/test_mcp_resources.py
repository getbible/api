"""MCP process ceilings remain visible to aggregate deployment admission."""
import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class McpResourcesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[2] / "src/bin/getbible-resources"
        loader = importlib.machinery.SourceFileLoader("mcp_resource_planner", str(path))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.planner = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.planner)

    def test_serving_candidate_and_draining_generations_are_reserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registry = root / "registry"
            domain = registry / "api.example.test"
            domain.mkdir(parents=True)
            conf = domain / "endpoint.conf"
            conf.write_text("TYPE=static\nMCP_ENABLED=false\n")
            args = SimpleNamespace(registry=str(registry), runtime_root=str(root / "runtime"),
                                   systemctl="systemctl", offline=True)
            self.assertEqual(self.planner.mcp_memory_reserve(args), 0)
            conf.write_text("TYPE=static\nMCP_ENABLED=true\n")
            self.assertEqual(self.planner.mcp_memory_reserve(args), 512 * self.planner.MIB)
            for number in range(3):
                generation = root / "runtime/mcp/api_example_test/deployments" / str(number)
                generation.mkdir(parents=True)
                (generation / ".unit").write_text(f"getbible-mcp-example-{number}\n")
            args.offline = False
            with patch.object(self.planner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                self.assertEqual(self.planner.mcp_memory_reserve(args), 1024 * self.planner.MIB)
                conf.write_text("TYPE=static\nMCP_ENABLED=false\n")
                self.assertEqual(self.planner.mcp_memory_reserve(args), 768 * self.planner.MIB)


if __name__ == "__main__":
    unittest.main()
