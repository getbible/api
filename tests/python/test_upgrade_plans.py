"""Deterministic plans and honest partial upgrade outcomes without services."""
from pathlib import Path
import json
import os
import runpy
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MOD = runpy.run_path(str(ROOT / "src/bin/getbible-upgrades"))
Journal = MOD["Journal"]
fingerprint = MOD["fingerprint"]
select = MOD["select"]


class UpgradePlansTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.journal = Journal(self.root / "state/upgrades.json")
        self.inventory = [self.row("management"), self.row("runtime/query.example.test/v2"),
                          self.row("runtime/query.example.test/v3"), self.row("mcp/mcp.example.test"),
                          self.row("static/api.example.test")]

    def row(self, identity, *, matches=True, serving="ready", value="a"):
        kind, _, domain = identity.partition("/")
        label = ""
        if kind == "runtime":
            domain, label = domain.rsplit("/", 1)
        return dict(id=identity, kind=kind, domain=domain, label=label, matches=matches,
                    serving=serving, desired_fingerprint=value * 64, generation="retained")

    def test_planning_is_read_only_and_adopts_only_verified_existing_generations(self):
        before = list(self.root.iterdir())
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["pending"], 0)
        self.assertEqual(before, list(self.root.iterdir()))
        self.inventory[1]["matches"] = False
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["pending"], 1)
        self.assertEqual(select(plan, [], "", False, False, False), [plan["targets"][1]])

    def test_explicit_empty_subset_and_unknown_targets_never_select_other_work(self):
        for row in self.inventory:
            row["matches"] = False
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(select(plan, [], "", True, False, True), [])
        with self.assertRaises(ValueError):
            select(plan, ["management", "mcp/missing.example.test"], "", False, False, True)
        with self.assertRaises(ValueError):
            select(plan, ["management"], "query.example.test", False, False, True)
        self.assertFalse(self.journal.path.exists())

    def test_force_and_selected_endpoint_do_not_select_siblings(self):
        plan = self.journal.plan(self.inventory, "3.2.0")
        identifier = self.inventory[2]["id"]
        self.assertEqual(select(plan, [identifier], "", False, False, True), [])
        self.assertEqual([r["id"] for r in select(plan, [identifier], "", True, False, True)], [identifier])
        self.assertEqual(len(select(plan, [], "query.example.test", True, False, False)), 2)

    def test_pending_skipped_targets_do_not_mark_whole_release_current(self):
        for row in self.inventory:
            self.journal.record(row, "verified", os.getpid())
            row["desired_fingerprint"] = "b" * 64
        self.journal.record(self.inventory[1], "applied", os.getpid())
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["pending"], 4)
        self.assertEqual(plan["state"], "pending")
        self.assertEqual(plan["targets"][1]["status"], "current")
        self.assertEqual(self.journal.path.stat().st_mode & 0o777, 0o600)

    def test_health_and_upgrade_completion_are_independent(self):
        row = self.inventory[1]
        self.journal.record(row, "verified", os.getpid())
        row["desired_fingerprint"] = "b" * 64
        self.journal.record(row, "failed", os.getpid(), "candidate refused; old generation still ready")
        plan = self.journal.plan(self.inventory, "3.2.0")
        target = plan["targets"][1]
        self.assertEqual(target["serving"], "ready")
        self.assertEqual(target["status"], "pending")
        self.assertEqual(target["applied_fingerprint"], "a" * 64)
        self.assertEqual([r["id"] for r in select(plan, [], "", False, True, False)], [row["id"]])
        row["serving"] = "unavailable"
        with self.assertRaises(ValueError):
            self.journal.record(row, "applied", os.getpid())

    def test_live_owner_and_interrupted_owner_are_not_confused(self):
        row = self.inventory[0]
        self.journal.record(row, "updating", os.getpid())
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["targets"][0]["status"], "updating")
        state = self.journal.read()
        state["targets"][row["id"]]["owner_identity"] = "earlier-boot:reused-pid"
        self.journal.path.write_text(json.dumps(state))
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["targets"][0]["outcome"], "interrupted")
        self.assertTrue(plan["targets"][0]["eligible"])
        state["targets"][row["id"]].update(owner_identity=None, owner_pid=None)
        self.journal.path.write_text(json.dumps(state))
        self.assertEqual(self.journal.plan(self.inventory, "3.2.0")["targets"][0]["outcome"], "interrupted")

    def test_blocked_targets_remain_pending_and_explicit_selection_fails(self):
        self.inventory[0]["error"] = "The installed history requires compatible forward recovery"
        plan = self.journal.plan(self.inventory, "3.2.0")
        self.assertEqual(plan["pending"], 1)
        self.assertEqual(select(plan, [], "", False, False, False), [])
        with self.assertRaises(ValueError):
            select(plan, ["management"], "", True, False, True)

    def test_retry_does_not_hide_a_failed_target_that_is_now_blocked(self):
        self.journal.record(self.inventory[0], "failed", os.getpid(), "earlier failure")
        self.inventory[0]["error"] = "The configured interpreter is not bundled"
        plan = self.journal.plan(self.inventory, "3.2.0")
        with self.assertRaises(ValueError):
            select(plan, [], "", False, True, False)

    def test_readiness_without_a_desired_fingerprint_cannot_mark_applied(self):
        row = self.inventory[0]
        row["desired_fingerprint"] = None
        with self.assertRaises(ValueError):
            self.journal.record(row, "applied", os.getpid())
        self.assertFalse(self.journal.path.exists())

    def test_global_version_and_usage_do_not_change_plan_identity(self):
        plan = self.journal.plan(self.inventory, "3.2.0")
        other = self.journal.plan(self.inventory, "3.2.1")
        self.assertEqual(plan["plan_id"], other["plan_id"])
        self.inventory[0]["generation"] = "a-new-serving-generation"
        self.assertNotEqual(plan["plan_id"], self.journal.plan(self.inventory, "3.2.1")["plan_id"])

    def test_unknown_state_and_duplicate_inventory_are_preserved_and_rejected(self):
        self.journal.path.parent.mkdir()
        contents = '{"format":999,"targets":{}}'
        self.journal.path.write_text(contents)
        with self.assertRaises(ValueError):
            self.journal.plan(self.inventory, "3.2.0")
        with self.assertRaises(ValueError):
            self.journal.record(self.inventory[0], "applied", os.getpid())
        self.assertEqual(self.journal.path.read_text(), contents)
        self.journal.path.unlink()
        with self.assertRaises(ValueError):
            self.journal.plan(self.inventory + [self.inventory[0]], "3.2.0")

    def test_fingerprints_are_relative_selective_and_ignore_config_order(self):
        source = self.root / "checkout"
        source.mkdir()
        (source / "runtime").mkdir()
        (source / "runtime/app.py").write_text("VALUE = 1\n")
        (source / "static.py").write_text("unrelated = True\n")
        config = self.root / "endpoint.conf"
        config.write_text("# note\nWORKERS=2\nPYTHON_VERSION=3.12.1\n")
        arguments = (["runtime"], ["endpoint=" + str(config)], ["mode=docker"], ["endpoint.PYTHON_VERSION=3.12.14"])
        original = fingerprint(source, *arguments)
        (source / "static.py").write_text("unrelated = False\n")
        (source / "runtime/__pycache__").mkdir()
        (source / "runtime/__pycache__/test.pyc").write_bytes(b"cache")
        config.write_text("PYTHON_VERSION=3.12.14\nWORKERS=2\n")
        moved = self.root / "moved"
        shutil.copytree(source, moved)
        self.assertEqual(original, fingerprint(moved, *arguments))
        config.write_text("PYTHON_VERSION=3.12.14\nWORKERS=3\n")
        self.assertNotEqual(original, fingerprint(source, *arguments))
        with self.assertRaises(ValueError):
            fingerprint(source, ["../endpoint.conf"], [], [], [])
        with self.assertRaises(ValueError):
            fingerprint(source, ["absent"], [], [], [])


if __name__ == "__main__":
    unittest.main()
