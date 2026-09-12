"""Resource planning uses real cgroup fixtures, never production scripture."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader("resource_planner", str(ROOT / "src/bin/getbible-resources"))
spec = importlib.util.spec_from_loader(loader.name, loader)
planner = importlib.util.module_from_spec(spec)
loader.exec_module(planner)
MIB = planner.MIB


class ResourceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.proc = self.root / "proc"
        self.cg = self.root / "cgroup"
        self.registry = self.root / "endpoints"
        self.runtime = self.root / "runtime"
        (self.proc / "self").mkdir(parents=True)
        (self.proc / "1").mkdir()
        (self.proc / "1/cgroup").write_text("0::/\n")
        (self.cg / "system.slice/operator.scope").mkdir(parents=True)
        (self.proc / "self/cgroup").write_text("0::/system.slice/operator.scope\n")
        (self.proc / "self/mountinfo").write_text("10 9 0:2 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n")
        (self.cg / "memory.max").write_text(str(4 * 1024 * MIB))
        (self.cg / "system.slice/memory.max").write_text("max")
        (self.cg / "system.slice/operator.scope/memory.max").write_text("max")
        (self.cg / "cpu.max").write_text("250000 100000")

    def endpoint(self, domain, kind, label="v2", **settings):
        directory = self.registry / domain
        (directory / "versions").mkdir(parents=True, exist_ok=True)
        (directory / "endpoint.conf").write_text(f"TYPE=runtime\nKIND={kind}\nENABLED=true\n")
        (directory / f"versions/{label}.conf").write_text("ENABLED=true\n" + "".join(f"{key}={value}\n" for key, value in settings.items()))

    def args(self, **overrides):
        args = dict(mode="docker", budget="auto", proc_root=str(self.proc), cgroup_root=str(self.cg),
                    registry=str(self.registry), runtime_root=str(self.runtime), systemctl="systemctl",
                    offline=True, candidate_domain=None)
        return SimpleNamespace(**(args | overrides))

    def test_reads_ancestor_limits_and_subtree_mounts(self):
        # An operator shell's own cgroup is unlimited; the container ancestor is not.
        limits = planner.cgroup_limits(self.proc, self.cg)
        self.assertEqual(limits["memory"], 4096 * MIB)
        self.assertLessEqual(limits["cpus"], 2.5)
        (self.cg / "system.slice/memory.max").write_text(str(3 * 1024 * MIB))
        self.assertEqual(planner.cgroup_limits(self.proc, self.cg)["memory"], 3072 * MIB)
        # A mount rooted at the container subtree must subtract that root once.
        (self.proc / "self/cgroup").write_text("0::/containers/getbible/system.slice/operator.scope\n")
        (self.proc / "self/mountinfo").write_text("10 9 0:2 /containers/getbible /sys/fs/cgroup rw - cgroup2 cgroup rw\n")
        self.assertEqual(planner.cgroup_limits(self.proc, self.cg)["memory"], 3072 * MIB)

    def test_four_gib_fits_query_and_search_with_update_overlap(self):
        self.endpoint("query.example.test", "query", WORKERS=4, THREADS=4)
        self.endpoint("search.example.test", "search", WORKERS=2, THREADS=4,
                      WARM_TRANSLATIONS="kjv,asv,web,ylt,darby")
        result = planner.plan(self.args())
        self.assertEqual(len(result["endpoints"]), 2)
        self.assertLessEqual(result["steady_runtime_bytes"] + result["candidate_reserve_bytes"] +
                             result["infrastructure_reserve_bytes"], result["budget_bytes"])
        query, search = result["endpoints"]
        self.assertGreater(search["settings"]["MEMORY_MAX"], query["settings"]["MEMORY_MAX"])
        self.assertGreaterEqual(search["settings"]["SEARCH_CORPUS_LIMIT"], 1)
        self.assertLessEqual(len(search["settings"]["WARM_TRANSLATIONS"].split(",")),
                             search["settings"]["SEARCH_CORPUS_LIMIT"])
        # Adaptation never edits the desired warm set or the endpoint's access.
        saved = planner.config(self.registry / "search.example.test/versions/v2.conf")
        self.assertEqual(saved["WARM_TRANSLATIONS"], "kjv,asv,web,ylt,darby")

    def test_all_versions_in_a_domain_have_overlap_reserved_together(self):
        self.endpoint("search.example.test", "search", "v2")
        self.endpoint("search.example.test", "search", "v3")
        result = planner.plan(self.args(budget="3G"))
        self.assertEqual(result["steady_runtime_bytes"], result["candidate_reserve_bytes"])
        self.assertEqual(result["budget_bytes"], 3072 * MIB)

    def test_disabled_endpoints_and_static_data_do_not_consume_runtime_allocation(self):
        self.endpoint("query.example.test", "query")
        self.endpoint("search.example.test", "search", ENABLED="false")
        self.endpoint("static.example.test", "query")
        (self.registry / "static.example.test/endpoint.conf").write_text("TYPE=static\nENABLED=true\n")
        result = planner.plan(self.args())
        self.assertEqual([item["domain"] for item in result["endpoints"]], ["query.example.test"])

    def test_insufficient_budget_fails_before_any_registry_mutation(self):
        self.endpoint("search.example.test", "search")
        path = self.registry / "search.example.test/versions/v2.conf"
        original = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "Existing services were not changed"):
            planner.plan(self.args(budget="512M"))
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(self.runtime.exists())

    def test_native_auto_preserves_existing_tuning(self):
        self.endpoint("search.example.test", "search", WORKERS=12)
        self.assertFalse(planner.plan(self.args(mode="native"))["enabled"])
        result = planner.plan(self.args(mode="native", budget="2G"))
        self.assertTrue(result["enabled"])
        self.assertEqual(result["budget_bytes"], 2048 * MIB)

    def test_container_cannot_use_host_ram_as_missing_cgroup_limit(self):
        (self.cg / "memory.max").write_text("max")
        with self.assertRaisesRegex(ValueError, "finite cgroup v2"):
            planner.plan(self.args(budget="4G"))
        with self.assertRaisesRegex(ValueError, "cannot be disabled"):
            planner.plan(self.args(budget="off"))

    def test_lower_cgroup_limit_wins_over_requested_budget(self):
        result = planner.plan(self.args(budget="12G"))
        self.assertEqual(result["budget_bytes"], 4096 * MIB)
        self.assertIn("lower", result["source"])
        self.assertEqual(planner.memory_bytes("1.5GiB"), 1536 * MIB)

    def test_admission_counts_retiring_generations_and_refuses_overlap(self):
        self.endpoint("search.example.test", "search")
        for name in ("active", "retiring"):
            generation = self.runtime / f"search/v2/deployments/{name}"
            generation.mkdir(parents=True)
            (generation / "limits.conf").write_text("[Service]\nMemoryMax=2G\n")
        states = "\n\n".join(f"Id=getbible-search-v2-{name}.service\nActiveState=active\nMemoryMax={2048 * MIB}"
                               for name in ("active", "retiring"))
        with patch.object(planner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, states, "")) as call:
            with self.assertRaisesRegex(ValueError, "previous generation may still be draining"):
                planner.plan(self.args(offline=False, candidate_domain="search.example.test"))
        self.assertIn("getbible-search-v2-retiring.service", call.call_args.args[0])

    def test_bootstrap_recalculates_without_treating_saved_generations_as_running(self):
        self.endpoint("search.example.test", "search")
        generation = self.runtime / "search/v2/deployments/old"
        generation.mkdir(parents=True)
        (generation / "limits.conf").write_text("[Service]\nMemoryMax=3G\n")
        with patch.object(planner.subprocess, "run", side_effect=AssertionError("no systemd before bootstrap")):
            result = planner.plan(self.args(candidate_domain="search.example.test"))
        self.assertEqual(result["running_bytes"], 0)

    def test_adding_search_shrinks_existing_query_before_consuming_new_capacity(self):
        self.endpoint("query.example.test", "query")
        original = planner.plan(self.args())["endpoints"][0]["settings"]["MEMORY_MAX"]
        generation = self.runtime / "query/v2/deployments/first"
        generation.mkdir(parents=True)
        (generation / "limits.conf").write_text(f"[Service]\nMemoryMax={original}\n")
        (self.runtime / "query/v2/active").symlink_to(generation)
        self.endpoint("search.example.test", "search")
        result = planner.plan(self.args())
        self.assertEqual(planner.domain_changes(result, True, "search.example.test"), ["query.example.test"])
        query, search = result["endpoints"]
        available = result["budget_bytes"] - result["infrastructure_reserve_bytes"]
        self.assertLessEqual(original + query["settings"]["MEMORY_MAX"], available)
        self.assertLessEqual(query["settings"]["MEMORY_MAX"] + 2 * search["settings"]["MEMORY_MAX"], available)

    def test_management_service_cap_does_not_replace_aggregate_container_budget(self):
        self.endpoint("query.example.test", "query")
        self.endpoint("search.example.test", "search")
        (self.cg / "system.slice/operator.scope/memory.max").write_text(str(512 * MIB))
        result = planner.plan(self.args())
        self.assertEqual(result["budget_bytes"], 4096 * MIB)
        self.assertEqual(planner.cgroup_limits(self.proc, self.cg)["memory"], 512 * MIB)

    def test_large_host_uses_shared_cpu_and_configurable_cache_budgets(self):
        self.endpoint("search.example.test", "search", WORKERS="auto", WARM_TRANSLATIONS="kjv,asv,web,ylt,darby")
        (self.cg / "memory.max").write_text(str(24 * 1024 * MIB))
        (self.cg / "cpu.max").write_text("600000 100000")
        with patch.object(planner.os, "sched_getaffinity", return_value=set(range(8))):
            result = planner.plan(self.args())
        settings = result["endpoints"][0]["settings"]
        self.assertEqual(settings["CPU_QUOTA"], "")
        self.assertEqual(settings["WORKERS"], 6)
        self.assertEqual(settings["SEARCH_CORPUS_LIMIT"], 256)
        self.assertEqual(settings["MEMORY_CACHE_TTL"], 2592000)
        self.assertEqual(settings["WARM_TRANSLATIONS"], "kjv,asv,web,ylt,darby")
        cache_bytes = sum(settings[key] for key in ("SHARED_CORPUS_BYTES", "CHAPTER_CACHE_BYTES", "TRANSLATION_CACHE_BYTES"))
        self.assertLessEqual(cache_bytes * settings["WORKERS"], settings["MEMORY_MAX"] // 2)

    def test_explicit_environment_policy_overrides_existing_endpoint_settings(self):
        self.endpoint("search.example.test", "search", CPU_QUOTA="100%", WARM_TRANSLATIONS="asv")
        result = planner.plan(self.args(policy=["SEARCH_CPU_QUOTA=250%", "SEARCH_WARM_TRANSLATIONS=kjv"],
                                        authoritative=["SEARCH_CPU_QUOTA", "SEARCH_WARM_TRANSLATIONS"]))
        settings = result["endpoints"][0]["settings"]
        self.assertEqual(settings["CPU_QUOTA"], "250%")
        self.assertEqual(settings["WARM_TRANSLATIONS"], "kjv")

    def test_recreation_clamps_retained_adaptive_target_to_new_environment_bounds(self):
        self.endpoint("query.example.test", "query", WORKERS="auto")
        (self.cg / "cpu.max").write_text("800000 100000")
        state = self.root / "adaptive.json"
        for previous, expected in ((8, 4), (1, 3)):
            with self.subTest(previous=previous):
                state.write_text(json.dumps({"targets": {"query.example.test/v2": {"workers": previous}}}))
                with patch.object(planner.os, "sched_getaffinity", return_value=set(range(8))):
                    result = planner.plan(self.args(
                        adaptive_state=str(state),
                        policy=["QUERY_WORKERS_MIN=3", "QUERY_WORKERS_MAX=4"],
                        authoritative=["QUERY_WORKERS_MIN", "QUERY_WORKERS_MAX"]))
                self.assertEqual(result["endpoints"][0]["settings"]["WORKERS"], expected)
                self.assertEqual(json.loads(state.read_text())["targets"]["query.example.test/v2"]["workers"], previous)
        state.write_text(json.dumps({"targets": {"query.example.test/v2": {"workers": 65}}}))
        with self.assertRaisesRegex(ValueError, "adaptive workers must be between 1 and 64"):
            planner.plan(self.args(adaptive_state=str(state)))

    def test_explicit_memory_ceiling_is_respected_with_update_overlap(self):
        self.endpoint("query.example.test", "query")
        self.endpoint("search.example.test", "search")
        result = planner.plan(self.args(policy=["QUERY_MEMORY_MAX=512M", "SEARCH_MEMORY_MAX=768M"]))
        query, search = result["endpoints"]
        self.assertEqual(query["settings"]["MEMORY_MAX"], 512 * MIB)
        self.assertEqual(search["settings"]["MEMORY_MAX"], 768 * MIB)
        self.assertLessEqual(result["steady_runtime_bytes"] + result["candidate_reserve_bytes"] + result["infrastructure_reserve_bytes"], result["budget_bytes"])

    def test_drain_timeout_keeps_old_generation_alive(self):
        self.endpoint("search.example.test", "search")
        generation = self.runtime / "search/v2/deployments/old"
        generation.mkdir(parents=True)
        (generation / "limits.conf").write_text("[Service]\nMemoryMax=512M\n")
        state = f"Id=getbible-search-v2-old.service\nActiveState=active\nMemoryMax={512 * MIB}"
        args = self.args(offline=False, wait_drain="search.example.test", drain_timeout=0)
        with patch.object(planner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, state, "")) as call:
            with self.assertRaisesRegex(ValueError, "kept serving"):
                planner.wait_drain(args)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(call.call_args.args[0][1], "show")


if __name__ == "__main__":
    unittest.main()
