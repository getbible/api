"""Cloudflare host changes must preserve the rest of a shared zone."""

from __future__ import annotations

import contextlib
import copy
import importlib.machinery
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PHASE = "http_request_cache_settings"
DESCRIPTION = "getbible:api.example.test"
BASE = "/zones/zone/rulesets"
RULES = BASE + "/entry/rules"
WANTED = {
    "action": "set_cache_settings",
    "expression": '(http.host eq "api.example.test")',
    "enabled": True,
    "action_parameters": {"cache": False},
}


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "cloudflare_rules_test_helper", str(ROOT / "src/bin/getbible-cloudflare")
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CloudflareRulesTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.other = {
            "id": "other", "description": "Website rule", "action": "skip",
            "expression": '(http.host eq "www.example.test")', "enabled": True,
            "ref": "operator-owned", "logging": {"enabled": True},
            "action_parameters": {"ruleset": "current"},
            "version": "8", "last_updated": "2026-09-01",
        }
        self.own = dict(WANTED, id="owned", description=DESCRIPTION, ref="stable-ref")
        self.snapshot = {"id": "entry", "rules": [self.other, self.own]}
        self.desired = dict(WANTED, description=DESCRIPTION)

    def test_update_preserves_position_and_concurrent_unrelated_edits(self):
        live = copy.deepcopy(self.snapshot)
        # A different writer updates an unrelated rule and inserts a new one
        # after the manager reads the entry point.
        live["rules"][0]["logging"]["enabled"] = False
        live["rules"].append({"id": "new", "description": "Added concurrently", "action": "block"})
        unrelated_before = copy.deepcopy([live["rules"][0], live["rules"][2]])

        def apply(method, path, body=None):
            self.assertEqual((method, path), ("PATCH", RULES + "/owned"))
            self.assertEqual(body, dict(self.desired, ref="stable-ref"))
            self.assertNotIn("position", body)
            live["rules"][1] = dict(body, id="owned")
            return {"result": copy.deepcopy(live)}

        with patch.object(self.helper, "entrypoint", return_value=copy.deepcopy(self.snapshot)), \
                patch.object(self.helper, "request", side_effect=apply):
            result = self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)
        self.assertEqual([r["id"] for r in result["rules"]], ["other", "owned", "new"])
        self.assertEqual([result["rules"][0], result["rules"][2]], unrelated_before)
        self.assertEqual(self.snapshot["rules"][1], self.own)
        self.assertNotIn("description", WANTED)

    def test_add_rule_never_resubmits_other_rules(self):
        current = {"id": "entry", "rules": [self.other]}
        with patch.object(self.helper, "entrypoint", return_value=current), \
                patch.object(self.helper, "request", return_value={"result": current}) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)
        request.assert_called_once_with("POST", RULES, self.desired)

    def test_missing_ruleset_uses_create_not_overwrite(self):
        with patch.object(self.helper, "entrypoint", return_value=None), \
                patch.object(self.helper, "request", return_value={"result": self.snapshot}) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)
        request.assert_called_once_with("POST", BASE, {
            "name": f"getBible {PHASE}", "kind": "zone", "phase": PHASE,
            "rules": [self.desired],
        })

    def test_concurrently_created_ruleset_is_reread_and_appended_to(self):
        current = {"id": "entry", "rules": [self.other]}
        with patch.object(self.helper, "entrypoint", side_effect=[None, current]), \
                patch.object(self.helper, "request", side_effect=[
                    self.helper.CloudflareError("entry point already exists"),
                    {"result": current},
                ]) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)
        self.assertEqual(request.call_args_list[0].args[0:2], ("POST", BASE))
        self.assertEqual(request.call_args_list[1].args, ("POST", RULES, self.desired))

    def test_creation_error_remains_a_failure_when_no_ruleset_appears(self):
        with patch.object(self.helper, "entrypoint", return_value=None), \
                patch.object(self.helper, "request", side_effect=self.helper.CloudflareError("permission denied")), \
                self.assertRaisesRegex(self.helper.CloudflareError, "permission denied"):
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)

    def test_remove_deletes_only_exact_host_matches(self):
        other_host = dict(self.own, id="other-host", description=DESCRIPTION + ".extra")
        duplicate = dict(self.own, id="duplicate")
        current = {"id": "entry", "rules": [self.other, self.own, other_host, duplicate]}
        with patch.object(self.helper, "entrypoint", return_value=current), \
                patch.object(self.helper, "request", return_value={"result": current}) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, None)
        self.assertEqual([c.args for c in request.call_args_list], [
            ("DELETE", RULES + "/owned"), ("DELETE", RULES + "/duplicate"),
        ])
        self.assertEqual(len(current["rules"]), 4)

    def test_update_removes_historical_duplicates_after_updating_first_rule(self):
        duplicate = dict(self.own, id="duplicate")
        current = {"id": "entry", "rules": [self.own, self.other, duplicate]}
        with patch.object(self.helper, "entrypoint", return_value=current), \
                patch.object(self.helper, "request", return_value={"result": current}) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED)
        self.assertEqual([c.args[0:2] for c in request.call_args_list], [
            ("PATCH", RULES + "/owned"), ("DELETE", RULES + "/duplicate"),
        ])

    def test_remove_absent_rule_and_absent_ruleset_are_read_only(self):
        for current in (None, {"id": "entry", "rules": [self.other]}):
            with self.subTest(current=current), \
                    patch.object(self.helper, "entrypoint", return_value=current), \
                    patch.object(self.helper, "request") as request:
                self.helper.replace_rule("zone", PHASE, DESCRIPTION, None)
                request.assert_not_called()

    def test_removal_error_is_reported_after_attempting_remaining_phases(self):
        with patch.object(self.helper, "find_zone", return_value={"id": "zone", "name": "example.test"}), \
                patch.object(self.helper, "replace_rule", side_effect=[
                    self.helper.CloudflareError("permission denied"), {}, {},
                ]) as replace, self.assertRaisesRegex(self.helper.CloudflareError, "permission denied"):
            self.helper.cmd_host_rules_remove("api.example.test")
        self.assertEqual(replace.call_count, 3)


class CloudflareOutputTest(unittest.TestCase):
    def test_json_cli_and_readable_menu_share_the_same_result(self):
        helper = load_helper()
        result = {"zone": "example.test", "records": [
            {"type": "A", "content": "192.0.2.1", "proxied": False},
            {"type": "AAAA", "content": "2001:db8::1", "proxied": True},
        ]}
        with patch.object(helper, "cmd_dns_show", return_value=result):
            json_output = io.StringIO()
            with contextlib.redirect_stdout(json_output):
                self.assertEqual(helper.main(["getbible-cloudflare", "dns-show", "api.example.test"]), 0)
            self.assertEqual(json.loads(json_output.getvalue()), result)
            human_output = io.StringIO()
            with contextlib.redirect_stdout(human_output):
                self.assertEqual(helper.main(["getbible-cloudflare", "--human", "dns-show", "api.example.test"]), 0)
        rendered = human_output.getvalue()
        for text in ("Zone", "DNS records", "Direct / DNS only", "Cloudflare proxy", "192.0.2.1", "2001:db8::1"):
            self.assertIn(text, rendered)


if __name__ == "__main__":
    unittest.main()
