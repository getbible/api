"""Cloudflare host changes must preserve the rest of a shared zone."""

from __future__ import annotations

import contextlib
import copy
import importlib.machinery
import importlib.util
import io
import json
import subprocess
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


class CloudflareOriginPullsTest(unittest.TestCase):
    def test_explicit_zone_toggle_matches_the_installed_shared_ca(self):
        helper = load_helper()
        for state, enabled in (("on", True), ("off", False)):
            with self.subTest(state=state), \
                    patch.object(helper, "find_zone", return_value={"id": "zone", "name": "example.test"}), \
                    patch.object(helper, "request", return_value={"result": {}}) as request:
                result = helper.cmd_origin_pulls("api.example.test", state)
            request.assert_called_once_with(
                "PATCH", "/zones/zone/settings/tls_client_auth", {"value": state}
            )
            self.assertEqual(result["authenticated_origin_pulls"], enabled)

    def domain_setting(self, enabled, failure="0"):
        script = """
set -eu
source "$1"
test_result="$3"
cf_human() { printf 'remote:%s\\n' "$*"; return "$test_result"; }
ep_set() { printf 'local:%s\\n' "$*"; }
ep_state_set() { printf 'state:%s\\n' "$*"; }
tg_notify() { printf 'notify:%s\\n' "$*"; }
cloudflare_endpoint_origin_pulls api.example.test "$2"
"""
        return subprocess.run(
            ["bash", "-c", script, "aop-test", str(ROOT / "src/lib/cloudflare.sh"), enabled, failure],
            text=True, capture_output=True, timeout=10,
        )

    def test_domain_disable_changes_only_local_requirement(self):
        result = self.domain_setting("false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("local:api.example.test CLOUDFLARE_ORIGIN_PULLS false", result.stdout)
        self.assertNotIn("remote:", result.stdout)

    def test_domain_enable_saves_only_after_remote_success(self):
        result = self.domain_setting("true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(
            result.stdout.index("remote:origin-pulls api.example.test on"),
            result.stdout.index("local:api.example.test CLOUDFLARE_ORIGIN_PULLS true"),
        )
        failed = self.domain_setting("true", "1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("state:api.example.test CLOUDFLARE_ERROR", failed.stdout)
        self.assertNotIn("local:", failed.stdout)
        self.assertNotIn("notify:", failed.stdout)

    def test_apply_does_not_report_success_after_aop_or_ca_failure(self):
        script = """
set -eu
source "$1"
test_failure="$2"
ep_is_live() { return 0; }
ep_get() {
    case "$2" in
        CLOUDFLARE_MODE) printf 'proxied';;
        ACCESS_MODE) printf 'open';;
        CLOUDFLARE_ORIGIN_PULLS) printf 'true';;
        *) printf '%s' "$3";;
    esac
}
cf_enabled() { return 0; }
cf_public_ipv4() { printf '192.0.2.1'; }
cf_public_ipv6() { :; }
cf_human() {
    if [[ "$1" == origin-pulls && "$test_failure" == api ]]; then return 1; fi
    return 0
}
gb_step() { :; }
gb_timestamp() { printf '2026-09-09'; }
ep_state_set() { :; }
cloudflare_refresh_ips() { return 0; }
cloudflare_install_origin_ca() {
    if [[ "$test_failure" == ca ]]; then return 1; fi
    printf 'unexpected CA download after API failure';
}
tg_notify() { printf 'unexpected success notification'; }
cloudflare_apply api.example.test
"""
        for failure in ("api", "ca"):
            with self.subTest(failure=failure):
                result = subprocess.run(
                    ["bash", "-c", script, "aop-test", str(ROOT / "src/lib/cloudflare.sh"), failure],
                    text=True, capture_output=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("unexpected", result.stdout + result.stderr)


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
