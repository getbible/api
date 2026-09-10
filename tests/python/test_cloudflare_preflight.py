"""Cloudflare Free deployment audits all prerequisites before changing a zone."""

from __future__ import annotations

import copy
import subprocess
import unittest
from unittest.mock import patch

from tests.python.test_cloudflare_rules import DESCRIPTION, PHASE, ROOT, load_helper


class CloudflarePreflightTest(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.domain = "api.example.test"
        self.zone = {"id": "zone", "name": "example.test", "plan": {"name": "Free Website"},
                     "account": {"id": "account"}}
        self.snapshots = {phase: {"id": phase, "rules": []} for phase in self.helper.RULE_PHASES}
        self.responses = {
            "/zones/zone/bot_management": {"fight_mode": False},
            "/zones/zone/rulesets?per_page=50&page=1": [],
            "/zones/zone/settings/cache_level": {"value": "aggressive"},
            "/zones/zone/pagerules?status=active&per_page=50&page=1": [],
            "/zones/zone/workers/routes": [],
            "/accounts/account/workers/domains?hostname=api.example.test&zone_id=zone&per_page=50&page=1": [],
        }
        self.requests = []

    def request(self, method, path, body=None):
        self.requests.append((method, path, body))
        self.assertEqual(method, "GET", "preflight performed a mutation")
        value = self.responses[path]
        if isinstance(value, Exception) or isinstance(value, SystemExit):
            raise value
        return {"success": True, "result": copy.deepcopy(value)}

    def run_profile(self, *, features="free", cache="respect", check=True):
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "entrypoint", side_effect=lambda zone, phase: self.snapshots[phase]), \
                patch.object(self.helper, "request", side_effect=self.request), \
                patch.object(self.helper, "replace_rule", return_value={}) as replace:
            out = self.helper.cmd_host_rules(self.domain, ["--cache", cache, "--features", features] + (["--check"] if check else []))
        return out, replace.call_args_list

    def assert_preflight_failure(self, message, *, features="free"):
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "entrypoint", side_effect=lambda zone, phase: self.snapshots[phase]), \
                patch.object(self.helper, "request", side_effect=self.request), \
                patch.object(self.helper, "replace_rule") as mutate, \
                self.assertRaisesRegex(self.helper.CloudflareError, message):
            self.helper.cmd_host_rules(self.domain, ["--cache", "respect", "--features", features])
        mutate.assert_not_called()
        self.assertTrue(all(method == "GET" for method, _, _ in self.requests))

    def test_free_plan_caches_full_queries_without_paid_fields_or_mutating_check(self):
        out, calls = self.run_profile()
        self.assertEqual(out["plan"], "free")
        self.assertEqual(out["features"], "free")
        self.assertIn("complete hostname, path and query string", out["query_string_requests"])
        self.assertEqual(out["rule_capacity"][PHASE], {"existing": 0, "additional": 2, "limit": 10})
        self.assertFalse(calls)
        self.assertEqual(len(self.requests), len(self.responses))
        out, calls = self.run_profile(check=False)
        public = next(call.args[3] for call in calls if call.args[1:3] == (PHASE, DESCRIPTION))
        self.assertEqual(set(public["action_parameters"]), {"cache", "edge_ttl", "browser_ttl"})
        self.assertNotIn('uri.query eq ""', public["expression"])
        self.assertIn('not has_key(http.request.headers, "authorization")', public["expression"])
        self.assertIn('not has_key(http.request.headers, "cookie")', public["expression"])

    def test_paid_selection_requires_actual_paid_plan_before_any_rule_changes(self):
        self.assert_preflight_failure("zone is on Cloudflare Free", features="paid")

    def test_paid_zone_retains_free_features_until_opt_in(self):
        self.zone["plan"] = {"legacy_id": "pro"}
        out, _ = self.run_profile()
        self.assertEqual(out["rule_capacity"][PHASE]["limit"], 10)
        out, _ = self.run_profile(features="paid")
        self.assertEqual(out["rule_capacity"][PHASE]["limit"], 25)

    def test_sbfm_challenges_require_explicit_entitled_opt_in(self):
        self.zone["plan"] = {"name": "Pro Website"}
        self.responses["/zones/zone/bot_management"] = {"fight_mode": False, "sbfm_definitely_automated": "block"}
        self.assert_preflight_failure("requires explicit")
        _, calls = self.run_profile(features="paid", check=False)
        rule = next(call.args[3] for call in calls if call.args[1] == "http_request_firewall_custom")
        self.assertIn("http_request_sbfm", rule["action_parameters"]["phases"])

    def test_inactive_sbfm_fields_do_not_send_paid_flags_on_free(self):
        self.responses["/zones/zone/bot_management"] = {"fight_mode": False, "sbfm_definitely_automated": "allow"}
        _, calls = self.run_profile(check=False)
        rule = next(call.args[3] for call in calls if call.args[1] == "http_request_firewall_custom")
        self.assertNotIn("http_request_sbfm", rule["action_parameters"]["phases"])

    def test_enterprise_origin_control_is_explicit_and_entitled(self):
        self.zone["plan"] = {"name": "Enterprise Website"}
        self.assert_preflight_failure("Origin Cache Control")
        _, calls = self.run_profile(features="paid", check=False)
        rule = next(call.args[3] for call in calls if call.args[1:3] == (PHASE, DESCRIPTION))
        self.assertTrue(rule["action_parameters"]["origin_cache_control"])

    def test_cache_capacity_is_checked_before_config_rule_mutation(self):
        self.snapshots[PHASE]["rules"] = [{"id": str(i), "description": f"other {i}"} for i in range(9)]
        self.assert_preflight_failure("9 existing \\+ 2 needed, limit 10")

    def test_existing_owned_rules_do_not_need_new_capacity(self):
        self.snapshots[PHASE]["rules"] = [{"id": str(i), "description": f"other {i}"} for i in range(8)] + [
            {"id": "owned", "description": DESCRIPTION}, {"id": "private", "description": DESCRIPTION + ":private"},
        ]
        out, _ = self.run_profile()
        self.assertEqual(out["rule_capacity"][PHASE]["additional"], 0)

    def test_waf_capacity_includes_custom_rulesets(self):
        self.responses["/zones/zone/rulesets?per_page=50&page=1"] = [
            {"id": "custom", "phase": "http_request_firewall_custom", "kind": "custom"},
        ]
        self.responses["/zones/zone/rulesets/custom"] = {"rules": [{"id": str(i)} for i in range(5)]}
        self.assert_preflight_failure("5 existing \\+ 1 needed, limit 5")

    def test_query_ignoring_zone_setting_is_an_actionable_read_only_failure(self):
        self.responses["/zones/zone/settings/cache_level"] = {"value": "simplified"}
        self.assert_preflight_failure("Standard")

    def test_shared_key_override_is_detected_even_before_final_host_cache_rule(self):
        self.snapshots[PHASE]["rules"] = [{
            "id": "website-defaults", "expression": "true", "enabled": True,
            "action_parameters": {"cache_key": {"custom_key": {"query_string": {"exclude": ["*"]}}}},
        }]
        self.assert_preflight_failure("website-defaults")

    def test_disjoint_hostname_custom_key_is_left_alone(self):
        self.snapshots[PHASE]["rules"] = [{
            "id": "website", "expression": '(http.host eq "www.example.test")', "enabled": True,
            "action_parameters": {"cache_key": {"custom_key": {"query_string": {"exclude": ["*"]}}}},
        }]
        out, _ = self.run_profile()
        self.assertIn("checked", out["cache_audit"])

    def test_host_pattern_matching_includes_https_port_and_wildcard_hosts(self):
        for pattern in ("https://api.example.test:443/*", "*.example.test/*", "*example.test*"):
            self.assertTrue(self.helper.url_pattern_may_match(pattern, self.domain), pattern)
        self.assertFalse(self.helper.url_pattern_may_match("https://www.example.test:443/*", self.domain))

    def test_page_rule_query_key_conflict_is_named(self):
        self.responses["/zones/zone/pagerules?status=active&per_page=50&page=1"] = [{
            "id": "page-rule", "status": "active", "targets": [{"constraint": {"value": "*example.test/*"}}],
            "actions": [{"id": "cache_level", "value": "ignore_query_string"}],
        }]
        self.assert_preflight_failure("Page Rule page-rule")

    def test_worker_routes_and_custom_domains_cannot_silently_override_contract(self):
        for path, value, message in (
            ("/zones/zone/workers/routes", [{"id": "worker", "pattern": "*.example.test/*", "script": "site"}], "Worker route worker"),
            ("/accounts/account/workers/domains?hostname=api.example.test&zone_id=zone&per_page=50&page=1",
             [{"id": "custom-domain", "hostname": self.domain}], "Worker custom domain custom-domain"),
        ):
            with self.subTest(path=path):
                self.responses[path] = value
                self.assert_preflight_failure(message)
                self.responses[path] = []

    def test_unrelated_worker_and_no_script_route_do_not_block_deployment(self):
        self.responses["/zones/zone/workers/routes"] = [
            {"id": "website", "pattern": "www.example.test/*", "script": "website"},
            {"id": "excluded", "pattern": "api.example.test/*"},
        ]
        self.run_profile()

    def test_permission_failures_and_malformed_audits_never_mean_empty_configuration(self):
        for result in (None, self.helper.CloudflareError("Workers Routes Read permission denied")):
            with self.subTest(result=result):
                self.responses["/zones/zone/workers/routes"] = result
                self.assert_preflight_failure("[Pp]ermission")

    def test_protected_transition_checks_cache_capacity_without_mutating(self):
        current = {"rules": [{"description": f"other {i}"} for i in range(10)]}
        with patch.object(self.helper, "find_zone", return_value=self.zone), \
                patch.object(self.helper, "entrypoint", return_value=current), \
                patch.object(self.helper, "request") as request, \
                patch.object(self.helper, "replace_rule") as replace, \
                self.assertRaisesRegex(self.helper.CloudflareError, "capacity is full"):
            self.helper.cmd_protect_access(self.domain)
        request.assert_not_called()
        replace.assert_not_called()

    def test_paginated_reads_inspect_every_page(self):
        values = [
            {"result": [{"id": "first"}], "result_info": {"total_pages": 2}},
            {"result": [{"id": "last"}], "result_info": {"total_pages": 2}},
        ]
        with patch.object(self.helper, "request", side_effect=values) as request:
            result = self.helper.read_list("/zones/zone/rulesets", paginate=True)
        self.assertEqual([item["id"] for item in result], ["first", "last"])
        self.assertTrue(request.call_args_list[-1].args[1].endswith("page=2"))


class CloudflareConfigureTest(unittest.TestCase):
    def test_already_enabled_environment_does_not_rewrite_managed_setting(self):
        script = r'''
set -eu
source "$1"
ui_password() { :; }
cf_human() { printf verified; }
gb_global() { printf true; }
gb_global_set() { printf 'unexpected managed write'; return 9; }
ui_msg() { printf '%s\n' "$*"; }
cloudflare_configure
'''
        result = subprocess.run(["bash", "-c", script, "managed-cf", str(ROOT / "src/lib/cloudflare.sh")],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Token verified", result.stdout)
        self.assertNotIn("unexpected", result.stdout)

    def test_rejected_token_write_cannot_report_success(self):
        script = r'''
set -eu
source "$1"
GB_CLOUDFLARE_CONF=/not-written
ui_password() { printf replacement-token; }
cfg_set() { return 1; }
cf_human() { printf 'unexpected verification'; }
ui_msg() { printf 'unexpected success'; }
cloudflare_configure
'''
        result = subprocess.run(["bash", "-c", script, "managed-cf", str(ROOT / "src/lib/cloudflare.sh")],
                                text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected", result.stdout + result.stderr)


class CloudflareHistoricalCacheTest(unittest.TestCase):
    def sequence(self, *, failed_purge=False, direct=False):
        script = r'''
set -eu
source "$1"
test_fail="$2"
test_direct="$3"
test_mode=proxied
test_access=open
test_policy=
test_pending=false
ep_is_live() { return 0; }
ep_get() {
    case "$2" in
        CLOUDFLARE_MODE) printf '%s' "$test_mode";;
        ACCESS_MODE) printf '%s' "$test_access";;
        CLOUDFLARE_CACHE) printf respect;;
        *) printf '%s' "${3:-}";;
    esac
}
ep_state_get() {
    case "$2" in
        EDGE_CACHE_POLICY) printf '%s' "$test_policy";;
        EDGE_CACHE_PUBLIC_PENDING) printf '%s' "$test_pending";;
    esac
}
ep_state_set() {
    if [[ "$2" == EDGE_CACHE_POLICY ]]; then test_policy="$3"; fi
    if [[ "$2" == EDGE_CACHE_PUBLIC_PENDING ]]; then test_pending="$3"; fi
    printf 'state:%s:%s\n' "$2" "$3"
}
cf_enabled() { return 0; }
cf_public_ipv4() { printf 192.0.2.1; }
cf_public_ipv6() { :; }
cf_human() { printf 'remote:%s\n' "$1"; [[ "$1" != protect-access || "$test_fail" != 1 ]]; }
cloudflare_refresh_ips() { :; }
gb_step() { :; }
gb_warn() { :; }
gb_timestamp() { printf now; }
tg_notify() { :; }
cloudflare_apply api.example.test
printf 'initial:%s\n' "$test_policy"
if [[ "$test_direct" == 1 ]]; then test_mode=dns; cloudflare_apply api.example.test; fi
test_mode=off
cloudflare_apply api.example.test
printf 'off:%s\n' "$test_policy"
test_access=token
if ! cloudflare_protect_access api.example.test; then printf 'protection-failed\n'; fi
printf 'private:%s\n' "$test_policy"
'''
        return subprocess.run(["bash", "-c", script, "cache-history", str(ROOT / "src/lib/cloudflare.sh"),
                               "1" if failed_purge else "0", "1" if direct else "0"],
                              text=True, capture_output=True, timeout=10)

    def test_off_then_private_still_protects_last_successful_public_cache(self):
        result = self.sequence()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("initial:public-respect", result.stdout)
        self.assertIn("off:public-respect", result.stdout)
        self.assertIn("private:protected-v1", result.stdout)
        self.assertEqual(result.stderr.splitlines(), ["remote:host-rules", "remote:dns", "remote:protect-access"])

    def test_failed_protection_preserves_public_history_for_retry(self):
        result = self.sequence(failed_purge=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("protection-failed", result.stdout)
        self.assertIn("private:public-respect", result.stdout)
        self.assertNotIn("private:protected-v1", result.stdout)

    def test_uncertain_public_write_invalidates_old_protected_state(self):
        script = r'''
set -eu
source "$1"
ep_get() {
    case "$2" in ACCESS_MODE) printf token;; CLOUDFLARE_MODE) printf off;; esac
}
ep_state_get() {
    case "$2" in EDGE_CACHE_POLICY) printf protected-v1;; EDGE_CACHE_PUBLIC_PENDING) printf true;; esac
}
ep_state_set() { printf 'state:%s:%s\n' "$2" "$3"; }
cf_enabled() { return 0; }
cf_human() { printf 'remote:%s\n' "$1"; }
gb_step() { :; }
tg_notify() { :; }
cloudflare_protect_access api.example.test
'''
        result = subprocess.run(["bash", "-c", script, "uncertain-cache", str(ROOT / "src/lib/cloudflare.sh")],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.splitlines(), ["remote:protect-access"])
        self.assertIn("state:EDGE_CACHE_PUBLIC_PENDING:false", result.stdout)

    def test_successful_direct_dns_sync_clears_old_edge_guard(self):
        result = self.sequence(direct=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("off:direct-v1", result.stdout)
        self.assertIn("private:direct-v1", result.stdout)
        self.assertNotIn("remote:protect-access", result.stderr)


class CloudflareExternalOriginTest(unittest.TestCase):
    def test_external_origin_never_discovers_container_addresses(self):
        script = '''
set -eu
source "$1"
gb_global() { :; }
gb_is_docker() { return 0; }
curl() { printf 'unexpected curl'; return 91; }
ip() { printf 'unexpected ip'; return 92; }
cf_public_ipv4
cf_public_ipv6
'''
        result = subprocess.run(["bash", "-c", script, "origin-test", str(ROOT / "src/lib/cloudflare.sh")],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unexpected", result.stdout + result.stderr)

    def test_external_tls_does_not_install_cloudflare_ca_or_nginx_trust_ranges(self):
        script = '''
set -eu
source "$1"
nginx_external_tls() { return 0; }
ep_get() { printf proxied; }
cloudflare_refresh_ips() { printf 'unexpected IP download'; return 91; }
cloudflare_install_origin_ca() { printf 'unexpected CA download'; return 92; }
cloudflare_ensure_origin_files api.example.test
'''
        result = subprocess.run(["bash", "-c", script, "origin-test", str(ROOT / "src/lib/cloudflare.sh")],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unexpected", result.stdout + result.stderr)

    def test_ipv6_none_removes_only_selected_hosts_aaaa_records(self):
        helper = load_helper()
        records = [{"id": "a", "type": "A", "name": "api.example.test", "content": "192.0.2.1", "proxied": True},
                   {"id": "aaaa", "type": "AAAA", "name": "api.example.test", "content": "2001:db8::1", "proxied": True}]
        with patch.object(helper, "find_zone", return_value={"id": "zone", "name": "example.test"}), \
                patch.object(helper, "dns_records", return_value=records), \
                patch.object(helper, "request", return_value={"result": {}}) as request:
            out = helper.cmd_dns("api.example.test", ["--ipv4", "192.0.2.1", "--ipv6", "none", "--proxied", "true"])
        request.assert_called_once_with("DELETE", "/zones/zone/dns_records/aaaa")
        self.assertEqual(out["removed"], [{"type": "AAAA", "content": "2001:db8::1"}])

    def test_ipv6_none_cannot_remove_the_only_origin_address(self):
        helper = load_helper()
        with patch.object(helper, "find_zone", return_value={"id": "zone", "name": "example.test"}), \
                patch.object(helper, "dns_records", return_value=[]), \
                patch.object(helper, "request") as request, \
                self.assertRaisesRegex(helper.CloudflareError, "only DNS origin"):
            helper.cmd_dns("api.example.test", ["--ipv6", "none", "--proxied", "true"])
        request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
