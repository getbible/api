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

    def test_host_exception_moves_only_its_own_rule_before_custom_challenges(self):
        with patch.object(self.helper, "entrypoint", return_value=copy.deepcopy(self.snapshot)), \
                patch.object(self.helper, "request", return_value={"result": self.snapshot}) as request:
            self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED, first=True)
        request.assert_called_once_with("PATCH", RULES + "/owned", dict(
            self.desired, ref="stable-ref", position={"index": 1},
        ))
        self.assertEqual(self.snapshot["rules"], [self.other, self.own])

    def test_cache_bypass_moves_after_later_broad_override_without_replacing_it(self):
        broad = dict(WANTED, id="broad", description="Website defaults", expression="true",
                     action_parameters={"cache": True, "edge_ttl": {"mode": "override_origin", "default": 3600}})
        live = {"id": "entry", "rules": [copy.deepcopy(self.own), copy.deepcopy(broad)]}
        snapshot = copy.deepcopy(live)

        def apply(method, path, body):
            self.assertEqual((method, path), ("PATCH", RULES + "/owned"))
            self.assertEqual(body["position"], {"after": ""})
            live["rules"] = [rule for rule in live["rules"] if rule["id"] != "owned"]
            live["rules"].append(dict(body, id="owned"))
            return {"result": copy.deepcopy(live)}

        with patch.object(self.helper, "entrypoint", return_value=snapshot), \
                patch.object(self.helper, "request", side_effect=apply):
            result = self.helper.replace_rule("zone", PHASE, DESCRIPTION, WANTED, last=True)
        self.assertEqual(result["rules"][0], broad)
        self.assertEqual(result["rules"][-1]["action_parameters"], {"cache": False})

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
                    self.helper.CloudflareError("permission denied"), {}, {}, {},
                ]) as replace, self.assertRaisesRegex(self.helper.CloudflareError, "permission denied"):
            self.helper.cmd_host_rules_remove("api.example.test")
        self.assertEqual(replace.call_count, 4)
        self.assertEqual(replace.call_args_list[2].args,
                         ("zone", PHASE, DESCRIPTION + ":private", None))


class CloudflareApiProfileTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.zone = {"id": "zone", "name": "example.test", "plan": {"name": "Free Website"}, "account": {"id": "account"}}
        self.domain = "api.example.test"

    def profile(self, cache="respect", bot_settings=None, features="free"):
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "request", return_value={"result": bot_settings or {"fight_mode": False}}), \
                patch.object(self.helper, "preflight_rules", return_value={"plan": "free", "query_string_requests": "cache eligible; complete hostname, path and query string retained"}), \
                patch.object(self.helper, "replace_rule", return_value={}) as replace:
            result = self.helper.cmd_host_rules(self.domain, ["--cache", cache, "--features", features])
        return result, replace.call_args_list

    def test_json_uses_origin_ttls_without_an_enterprise_cache_key(self):
        result, calls = self.profile()
        config_call = next(call for call in calls if call.args[1] == "http_config_settings")
        self.assertEqual(config_call.kwargs, {"last": True})
        self.assertEqual(config_call.args[3]["action_parameters"]["ssl"], "strict")
        public = next(call.args[3] for call in calls if call.args[1:3] == (PHASE, DESCRIPTION))
        params = public["action_parameters"]
        self.assertTrue(params["cache"])
        self.assertEqual(params["edge_ttl"], {"mode": "bypass_by_default"})
        self.assertEqual(params["browser_ttl"], {"mode": "respect_origin"})
        self.assertNotIn("cache_key", params)
        self.assertIn("/.well-known/getbible-origin/", public["expression"])
        self.assertNotIn("respect_strong_etags", params)
        self.assertNotIn("origin_error_page_passthru", params)
        self.assertEqual(result["waf_skip"], "set")
        self.assertIn("complete hostname, path and query string", result["query_string_requests"])

    def test_private_requests_bypass_public_hits_without_rule_order_dependency(self):
        _, calls = self.profile()
        cache_calls = [call for call in calls if call.args[1] == PHASE]
        private, public = [call.args[3] for call in cache_calls]
        self.assertEqual(private["action_parameters"], {"cache": False})
        self.assertTrue(all(call.kwargs == {"last": True} for call in cache_calls))
        self.assertEqual(private["expression"], '(http.host eq "api.example.test") and not ' + self.helper.PUBLIC_CACHE_REQUEST)
        self.assertEqual(public["expression"], '(http.host eq "api.example.test") and ' + self.helper.PUBLIC_CACHE_REQUEST)
        self.assertNotIn('http.request.uri.query eq ""', public["expression"])
        for required in ('{"GET" "HEAD"}', 'not has_key(http.request.headers, "authorization")',
                         'not has_key(http.request.headers, "cookie")',
                         'not http.request.headers.truncated'):
            self.assertIn(required, public["expression"])

    def test_bypass_is_host_wide_before_private_rule_is_removed(self):
        _, calls = self.profile("bypass")
        cache_calls = [call for call in calls if call.args[1] == PHASE]
        self.assertEqual(cache_calls[0].args[3]["expression"], '(http.host eq "api.example.test")')
        self.assertEqual(cache_calls[0].args[3]["action_parameters"], {"cache": False})
        self.assertEqual(cache_calls[1].args, ("zone", PHASE, DESCRIPTION + ":private", None))

    def test_skip_is_first_host_scoped_and_never_skips_ddos(self):
        for settings, has_sbfm in (({"fight_mode": False}, False), ({"sbfm_definitely_automated": "block"}, True)):
            with self.subTest(settings=settings):
                _, calls = self.profile(bot_settings=settings, features="paid" if has_sbfm else "free")
                call = next(call for call in calls if call.args[1] == "http_request_firewall_custom")
                rule = call.args[3]
                self.assertEqual(rule["expression"], '(http.host eq "api.example.test")')
                self.assertEqual(call.kwargs, {"first": True})
                self.assertEqual(rule["action_parameters"]["ruleset"], "current")
                self.assertEqual(set(rule["action_parameters"]["phases"]), {
                    "http_ratelimit", "http_request_firewall_managed",
                } | ({"http_request_sbfm"} if has_sbfm else set()))

    def test_unskippable_bot_fight_mode_aborts_before_changing_host_rules(self):
        for settings in ({"fight_mode": True}, {"stale_zone_configuration": {"fight_mode": True}}):
            with self.subTest(settings=settings), \
                    patch.object(self.helper, "find_zone", return_value=self.zone), \
                    patch.object(self.helper, "request", return_value={"result": settings}) as request, \
                    patch.object(self.helper, "replace_rule") as replace, \
                    self.assertRaisesRegex(self.helper.CloudflareError, "cannot be skipped per hostname"):
                self.helper.cmd_host_rules(self.domain, [])
            request.assert_called_once_with("GET", "/zones/zone/bot_management")
            replace.assert_not_called()

    def test_bot_settings_permission_failure_is_not_reported_as_success(self):
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "request", side_effect=self.helper.CloudflareError("permission denied")), \
                patch.object(self.helper, "replace_rule") as replace, \
                self.assertRaisesRegex(self.helper.CloudflareError, "Bot Management Read"):
            self.helper.cmd_host_rules(self.domain, [])
        replace.assert_not_called()

    def test_required_waf_and_cache_rule_errors_propagate(self):
        for failure_phase, failure_description in (("http_request_firewall_custom", DESCRIPTION),
                                                    (PHASE, DESCRIPTION + ":private")):
            def apply(zone, phase, description, rule, **kwargs):
                if (phase, description) == (failure_phase, failure_description):
                    raise self.helper.CloudflareError("plan rule limit reached")
                return {}
            with self.subTest(phase=failure_phase), \
                    patch.object(self.helper, "find_zone", return_value=self.zone), \
                    patch.object(self.helper, "request", return_value={"result": {"fight_mode": False}}), \
                    patch.object(self.helper, "preflight_rules", return_value={"plan": "free"}), \
                    patch.object(self.helper, "replace_rule", side_effect=apply), \
                    self.assertRaisesRegex(self.helper.CloudflareError, "plan rule limit"):
                self.helper.cmd_host_rules(self.domain, ["--cache", "respect"])

    def test_missing_origin_and_dns_records_is_a_failure(self):
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "dns_records", return_value=[]), \
                patch.object(self.helper, "request") as request, \
                self.assertRaisesRegex(self.helper.CloudflareError, "No A/AAAA"):
            self.helper.cmd_dns(self.domain, ["--proxied", "true"])
        request.assert_not_called()


class CloudflareApplyOrderingTest(unittest.TestCase):
    def apply(self, failure="", mode="proxied"):
        script = """
set -eu
source "$1"
test_failure="$2"
test_mode="$3"
ep_is_live() { return 0; }
ep_get() {
    case "$2" in
        CLOUDFLARE_MODE) printf '%s' "$test_mode";;
        ACCESS_MODE) printf 'open';;
        CLOUDFLARE_ORIGIN_PULLS) printf 'true';;
        *) printf '%s' "$3";;
    esac
}
cf_enabled() { [[ "$test_failure" != token ]]; }
cf_public_ipv4() { printf '192.0.2.1'; }
cf_public_ipv6() { :; }
cf_human() { printf '%s\\n' "$1"; [[ "$1" != "$test_failure" ]]; }
gb_step() { :; }
gb_warn() { printf 'warn:%s\\n' "$*"; }
gb_timestamp() { printf '2026-09-10'; }
ep_state_set() { printf 'state:%s\\n' "$2"; }
cloudflare_refresh_ips() { printf 'ips\\n'; [[ "$test_failure" != ips ]]; }
cloudflare_install_origin_ca() { printf 'ca\\n'; [[ "$test_failure" != ca ]]; }
tg_notify() { printf 'notify\\n'; }
cloudflare_apply api.example.test
"""
        return subprocess.run(
            ["bash", "-c", script, "apply-test", str(ROOT / "src/lib/cloudflare.sh"), failure, mode],
            text=True, capture_output=True, timeout=10,
        )

    def test_complete_profile_and_origin_prerequisites_precede_dns(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        # cf_human goes to stderr; local preparations go to stdout.
        self.assertEqual(result.stderr.splitlines(), ["host-rules", "origin-pulls", "dns"])
        self.assertIn("state:CLOUDFLARE_DNS_AT", result.stdout)
        self.assertIn("notify", result.stdout)

    def test_missing_token_or_profile_prerequisite_never_switches_dns(self):
        for failure in ("token", "host-rules", "ips", "origin-pulls", "ca"):
            with self.subTest(failure=failure):
                result = self.apply(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("dns", result.stderr.splitlines())
                self.assertNotIn("state:CLOUDFLARE_DNS_AT", result.stdout)
                self.assertNotIn("notify", result.stdout)

    def test_direct_routing_removes_profile_after_dns_and_reports_cleanup_failure(self):
        result = self.apply("host-rules-remove", "dns")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.splitlines(), ["dns", "host-rules-remove"])
        self.assertIn("state:CLOUDFLARE_DNS_AT", result.stdout)
        self.assertNotIn("notify", result.stdout)


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
