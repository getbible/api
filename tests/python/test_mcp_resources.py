"""Admission counts serving processes separately from future update reserves."""
import subprocess
import unittest
from unittest.mock import patch

from tests.python import test_resources as resource_fixtures


class McpResourcesTests(unittest.TestCase):
    def setUp(self):
        self.fixture = resource_fixtures.ResourceTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.planner = resource_fixtures.planner
        self.mib = self.planner.MIB
        self.states = {}
        self.domain = "mcp.example.test"

    def mcp_domain(self, enabled=True):
        directory = self.fixture.registry / self.domain
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "endpoint.conf").write_text(
            f"TYPE=mcp\nENABLED={str(enabled).lower()}\n"
        )

    def mcp_generation(self, name, state="active", maximum=None):
        root = self.fixture.runtime / "mcp/mcp_example_test/deployments" / name
        root.mkdir(parents=True)
        unit = f"getbible-mcp-example-{name}.service"
        (root / ".unit").write_text(unit.removesuffix(".service") + "\n")
        self.states[unit] = (state, 256 * self.mib if maximum is None else maximum)
        return unit

    def runtime_generation(self, endpoint, name):
        root = self.fixture.runtime / endpoint["kind"] / endpoint["label"]
        generation = root / "deployments" / name
        generation.mkdir(parents=True)
        maximum = endpoint["settings"]["MEMORY_MAX"]
        (generation / "limits.conf").write_text(f"[Service]\nMemoryMax={maximum}\n")
        selected = root / "active"
        if selected.is_symlink():
            old = f"getbible-{endpoint['kind']}-{endpoint['label']}-{selected.resolve().name}.service"
            self.states[old] = ("inactive", self.states[old][1])
            selected.unlink()
        selected.symlink_to(generation)
        unit = f"getbible-{endpoint['kind']}-{endpoint['label']}-{name}.service"
        self.states[unit] = ("active", maximum)
        return unit

    def systemctl(self, command, **kwargs):
        self.assertEqual(command[1], "show")
        blocks = []
        for unit in command[3:]:
            state, maximum = self.states[unit]
            blocks.append(
                f"Id={unit}\nLoadState=loaded\nActiveState={state}\nMemoryMax={maximum}"
            )
        return subprocess.CompletedProcess(command, 0, "\n\n".join(blocks), "")

    def test_offline_targets_reserve_updates_without_inventing_live_processes(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                self.mcp_domain(enabled)
                self.mcp_generation(f"saved-{enabled}")
                args = self.fixture.args(candidate_domain=self.domain)
                with patch.object(self.planner.subprocess, "run", side_effect=AssertionError("offline")):
                    reserve, candidate, live = self.planner.mcp_memory(args)
                self.assertEqual(reserve, 512 * self.mib if enabled else 0)
                self.assertEqual(candidate, 256 * self.mib if enabled else 0)
                self.assertEqual(live, [])

    def test_actual_ceilings_include_starting_serving_and_draining_generations(self):
        self.mcp_domain()
        live_units = []
        for name, state, ceiling in (
            ("serving", "active", 256),
            ("starting", "activating", 384),
            ("reloading", "reloading", 256),
            ("draining", "deactivating", 128),
            ("stopped", "inactive", 256),
            ("failed", "failed", 256),
        ):
            unit = self.mcp_generation(name, state, ceiling * self.mib)
            if state not in {"inactive", "failed"}:
                live_units.append({"unit": unit, "memory_max": ceiling * self.mib})
        running = sum(item["memory_max"] for item in live_units)
        args = self.fixture.args(offline=False, candidate_domain=self.domain)
        with patch.object(self.planner.subprocess, "run", side_effect=self.systemctl):
            reserve, candidate, live = self.planner.mcp_memory(args)
            self.assertCountEqual(live, live_units)
            self.assertEqual(candidate, 256 * self.mib)
            self.assertEqual(reserve, running + candidate)
            self.mcp_domain(enabled=False)
            reserve, candidate, live = self.planner.mcp_memory(args)
        self.assertEqual(reserve, running)
        self.assertEqual(candidate, 0)
        self.assertCountEqual(live, live_units)

    def test_runtime_reconciliation_releases_capacity_before_new_mcp_starts(self):
        self.fixture.endpoint("query.example.test", "query")
        self.fixture.endpoint("search.example.test", "search")
        original = self.planner.plan(self.fixture.args())
        for item in original["endpoints"]:
            self.runtime_generation(item, "original")
        self.mcp_domain()
        target = self.planner.plan(self.fixture.args())
        reductions = self.planner.domain_changes(target, True, self.domain)
        self.assertTrue(reductions)
        self.assertLess(target["steady_runtime_bytes"], original["steady_runtime_bytes"])
        with patch.object(self.planner.subprocess, "run", side_effect=self.systemctl):
            for domain in reductions:
                args = self.fixture.args(offline=False, candidate_domain=domain)
                result = self.planner.plan(args)
                candidate = sum(item["settings"]["MEMORY_MAX"] for item in result["endpoints"]
                                if item["domain"] == domain)
                running = sum(maximum for state, maximum in self.states.values() if state == "active")
                base_reserve = result["infrastructure_reserve_bytes"] - result["mcp_reserve_bytes"]
                self.assertEqual(result["running_bytes"], running)
                self.assertLessEqual(running + candidate + base_reserve, result["budget_bytes"])
                for item in result["endpoints"]:
                    if item["domain"] == domain:
                        self.runtime_generation(item, "reconciled")
            admitted = self.planner.plan(self.fixture.args(offline=False, candidate_domain=self.domain))
        self.assertLessEqual(admitted["steady_runtime_bytes"] + admitted["candidate_reserve_bytes"] +
                             admitted["infrastructure_reserve_bytes"], admitted["budget_bytes"])
        self.assertEqual(admitted["mcp_reserve_bytes"], 512 * self.mib)

    def test_mcp_candidate_counts_once_at_admission_boundary(self):
        self.fixture.endpoint("query.example.test", "query")
        self.mcp_domain()
        self.mcp_generation("serving")
        target = self.planner.plan(self.fixture.args())
        query = target["endpoints"][0]
        base_reserve = target["infrastructure_reserve_bytes"] - target["mcp_reserve_bytes"]
        query["settings"]["MEMORY_MAX"] = target["budget_bytes"] - base_reserve - 512 * self.mib
        unit = self.runtime_generation(query, "serving")
        args = self.fixture.args(offline=False, candidate_domain=self.domain)
        with patch.object(self.planner.subprocess, "run", side_effect=self.systemctl):
            admitted = self.planner.plan(args)
            self.assertEqual(admitted["running_bytes"] + 256 * self.mib + base_reserve,
                             admitted["budget_bytes"])
            self.assertEqual(len(admitted["running_generations"]), 2)
            self.states[unit] = ("active", self.states[unit][1] + 1)
            with self.assertRaisesRegex(ValueError, "Candidate admission"):
                self.planner.plan(args)

    def test_runtime_admission_counts_disabled_mcp_until_it_stops(self):
        self.fixture.endpoint("query.example.test", "query")
        self.mcp_domain(enabled=False)
        self.mcp_generation("draining", "deactivating")
        target = self.planner.plan(self.fixture.args())
        query = target["endpoints"][0]
        candidate = query["settings"]["MEMORY_MAX"]
        base_reserve = target["infrastructure_reserve_bytes"]
        query["settings"]["MEMORY_MAX"] = target["budget_bytes"] - base_reserve - candidate
        self.runtime_generation(query, "serving")
        args = self.fixture.args(offline=False, candidate_domain="query.example.test")
        with patch.object(self.planner.subprocess, "run", side_effect=self.systemctl):
            with self.assertRaisesRegex(ValueError, "Candidate admission"):
                self.planner.plan(args)
            self.states["getbible-mcp-example-draining.service"] = ("inactive", 256 * self.mib)
            admitted = self.planner.plan(args)
        self.assertEqual(len(admitted["running_generations"]), 1)

    def test_live_generation_requires_a_finite_known_ceiling(self):
        self.mcp_domain()
        unit = self.mcp_generation("serving")
        args = self.fixture.args(offline=False)
        for maximum in ("infinity", "", "unknown", 0, -1, 2 ** 63):
            with self.subTest(maximum=maximum):
                self.states[unit] = ("active", maximum)
                with patch.object(self.planner.subprocess, "run", side_effect=self.systemctl):
                    with self.assertRaises(ValueError):
                        self.planner.mcp_memory(args)
        with patch.object(self.planner.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "unavailable")):
            with self.assertRaises(ValueError):
                self.planner.mcp_memory(args)

    def test_retained_unloaded_units_do_not_consume_process_capacity(self):
        self.mcp_domain()
        serving = self.mcp_generation("serving")
        retired = self.mcp_generation("retired", "inactive")
        args = self.fixture.args(offline=False)
        for maximum in ("", "MemoryMax=infinity\n"):
            with self.subTest(maximum=maximum):
                output = (f"Id={serving}\nLoadState=loaded\nActiveState=active\n"
                          f"MemoryMax={256 * self.mib}\n\n"
                          f"Id={retired}\nLoadState=not-found\nActiveState=inactive\n{maximum}")
                completed = subprocess.CompletedProcess([], 0, output, "")
                with patch.object(self.planner.subprocess, "run", return_value=completed):
                    reserve, candidate, live = self.planner.mcp_memory(args)
                self.assertEqual(reserve, 512 * self.mib)
                self.assertEqual(candidate, 0)
                self.assertEqual(live, [{"unit": serving, "memory_max": 256 * self.mib}])

    def test_systemd_inventory_must_cover_each_saved_unit_once(self):
        self.mcp_domain()
        units = [self.mcp_generation(name) for name in ("serving", "draining")]
        blocks = [f"Id={unit}\nActiveState=active\nMemoryMax={256 * self.mib}"
                  for unit in units]
        responses = (
            "",
            blocks[0],
            "\n\n".join((blocks[0], blocks[0])),
            "\n\n".join((blocks[0], blocks[1].replace(units[1], "unrequested.service"))),
            "\n\n".join((blocks[0], blocks[1].replace("ActiveState=active\n", ""))),
        )
        args = self.fixture.args(offline=False)
        for response in responses:
            with self.subTest(response=response):
                completed = subprocess.CompletedProcess([], 0, response, "")
                with patch.object(self.planner.subprocess, "run", return_value=completed):
                    with self.assertRaises(ValueError):
                        self.planner.mcp_memory(args)


if __name__ == "__main__":
    unittest.main()
