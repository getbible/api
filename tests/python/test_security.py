"""Security boundaries: token lifetime, cache policy and nginx transactions."""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import random
import re
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def helper(name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), str(ROOT / "src" / "bin" / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class TokenExpiryTest(unittest.TestCase):
    def test_numeric_ranges_cover_boundaries(self):
        tokens = helper("getbible-tokens")
        randomizer = random.Random(42)
        for boundary in (1, 9, 10, 11, 99, 100, 101, 1000, 1799193600, 10000000000):
            expression = re.compile(tokens.epoch_before(boundary))
            probes = {0, 1, boundary - 1, boundary, boundary + 1, 10 * boundary}
            probes.update(randomizer.randrange(0, boundary * 2) for _ in range(100))
            for second in probes:
                self.assertEqual(bool(expression.fullmatch(str(second))), second < boundary, (boundary, second))

    def test_expiry_is_checked_per_request_in_utc(self):
        tokens = helper("getbible-tokens")
        token = {"id": "tk_01234567", "token": "gb" + "a" * 52, "expires_at": "2027-01-05"}
        output = io.StringIO()
        with patch.object(tokens, "now", return_value="2027-01-05T12:00:00Z"), contextlib.redirect_stdout(output):
            tokens.cmd_render_validity_map({"tokens": [token]}, "api.example.test")
        expression = re.compile(output.getvalue().split('"')[1][1:])
        deadline = int(datetime(2027, 1, 6, tzinfo=timezone.utc).timestamp())
        self.assertTrue(expression.fullmatch(f"api.example.test tk_01234567 {deadline - 1}.999"))
        self.assertFalse(expression.fullmatch(f"api.example.test tk_01234567 {deadline}.000"))
        self.assertFalse(expression.fullmatch(f"other.example.test tk_01234567 {deadline - 1}.000"))
        self.assertNotIn(token["token"], output.getvalue())

    def test_no_expiry_and_revocation(self):
        tokens = helper("getbible-tokens")
        token = {"id": "tk_01234567", "token": "gb" + "a" * 52}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            tokens.cmd_render_validity_map({"tokens": [token]}, "api.example.test")
        self.assertTrue(re.fullmatch(output.getvalue().split('"')[1][1:], "api.example.test tk_01234567 99999999999.001"))
        token["revoked_at"] = "2026-01-01T00:00:00Z"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            tokens.cmd_render_validity_map({"tokens": [token]}, "api.example.test")
        self.assertEqual(output.getvalue(), "")

    def test_corrupt_store_cannot_inject_nginx_or_disclose_secret(self):
        tokens = helper("getbible-tokens")
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(SystemExit, "invalid token id"):
            tokens.cmd_render_map({"tokens": [{"id": 'bad"; include secret;', "token": "sensitive"}]}, "api.example.test")
        self.assertEqual(output.getvalue(), "")


class CloudflareCacheTest(unittest.TestCase):
    def test_bypass_precedes_host_scoped_purge(self):
        cloudflare = helper("getbible-cloudflare")
        operations = []

        def replace(*args, **kwargs):
            self.assertEqual(kwargs, {"last": True})
            operations.append(("rule", args))

        def request(*args):
            operations.append(("request", args))
            return {"success": True}

        with patch.object(cloudflare, "find_zone", return_value={"id": "zone", "name": "example.test", "plan": {"name": "Free Website"}}), \
                patch.object(cloudflare, "entrypoint", return_value=None), \
                patch.object(cloudflare, "replace_rule", side_effect=replace), patch.object(cloudflare, "request", side_effect=request):
            result = cloudflare.cmd_protect_access("api.example.test")
        self.assertEqual(operations[0][0], "rule")
        self.assertEqual(operations[0][1][-1]["action_parameters"], {"cache": False})
        self.assertEqual(operations[1], ("request", ("POST", "/zones/zone/purge_cache", {"hosts": ["api.example.test"]})))
        self.assertTrue(result["purged"])

    def test_failed_purge_is_not_reported_as_secured(self):
        cloudflare = helper("getbible-cloudflare")
        with patch.object(cloudflare, "find_zone", return_value={"id": "zone", "name": "example.test", "plan": {"name": "Free Website"}}), \
                patch.object(cloudflare, "entrypoint", return_value=None), \
                patch.object(cloudflare, "replace_rule"), \
                patch.object(cloudflare, "request", side_effect=cloudflare.CloudflareError("Cache Purge permission missing")), \
                self.assertRaisesRegex(cloudflare.CloudflareError, "Cache Purge"):
            cloudflare.cmd_protect_access("api.example.test")


class NginxTransactionTest(unittest.TestCase):
    def shell(self, script):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, GB_PREFIX=directory, GB_REPO_DIR=str(ROOT), GB_YES="true")
            result = subprocess.run(["bash", "-c", 'source "$GB_REPO_DIR/src/lib/core.sh"\nsource "$GB_LIB/nginx.sh"\n' + script],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unchanged_token_map_permissions_are_repaired(self):
        self.shell('''
stage="$GB_TMP/stage"
mkdir -p "$stage/getbible/tokens" "$GB_NGINX_GB/tokens"
printf '%s' secret > "$stage/getbible/tokens/example.map"
cp "$stage/getbible/tokens/example.map" "$GB_NGINX_GB/tokens/example.map"
chmod 0755 "$GB_NGINX_GB/tokens"
chmod 0644 "$GB_NGINX_GB/tokens/example.map"
nginx_test() { return 0; }
nginx_reload() { return 0; }
nginx_apply_stage "$stage" permissions
[[ "$(stat -c %a "$GB_NGINX_GB/tokens/example.map")" == 600 ]]
[[ "$(stat -c %a "$GB_NGINX_GB/tokens")" == 700 ]]
[[ -n "$(find "$GB_BACKUPS" -type f -name '*example.map')" ]]
''')

    def test_reload_failure_restores_prior_config_and_returns_failure(self):
        self.shell('''
stage="$GB_TMP/stage"
mkdir -p "$stage/conf.d" "$GB_NGINX/conf.d"
printf old > "$GB_NGINX/conf.d/endpoint.conf"
printf new > "$stage/conf.d/endpoint.conf"
nginx_test() { return 0; }
nginx_reload() {
    [[ -f "$GB_TMP/reloaded" ]] && return 0
    touch "$GB_TMP/reloaded"
    return 1
}
if nginx_apply_stage "$stage" reload; then exit 2; fi
[[ "$(cat "$GB_NGINX/conf.d/endpoint.conf")" == old ]]
''')

    def test_endpoint_rollback_restores_multiple_successful_stages(self):
        self.shell('''
stage="$GB_TMP/stage"
mkdir -p "$stage/conf.d" "$GB_NGINX/conf.d"
printf original > "$GB_NGINX/conf.d/endpoint.conf"
nginx_test() { return 0; }
nginx_reload() { return 0; }
nginx_transaction_begin example.test
printf http > "$stage/conf.d/endpoint.conf"
nginx_apply_stage "$stage" http
printf tls > "$stage/conf.d/endpoint.conf"
nginx_apply_stage "$stage" tls
[[ "$(cat "$GB_NGINX/conf.d/endpoint.conf")" == tls ]]
nginx_transaction_rollback example.test
[[ "$(cat "$GB_NGINX/conf.d/endpoint.conf")" == original ]]
''')

    def test_declined_route_edit_rejects_stage_and_restores_prior_writes(self):
        self.shell('''
stage="$GB_TMP/stage"
mkdir -p "$stage/conf.d" "$stage/sites-available" "$GB_NGINX/conf.d" "$GB_NGINX/sites-available"
shared="$GB_NGINX/conf.d/shared.conf"
site="$GB_NGINX/sites-available/query.example.test.conf"
printf original-shared > "$shared"
printf original-route > "$site"
gb_ledger_record "$shared"
gb_ledger_record "$site"
# Simulate an operator editing the old backend's route after its last apply.
printf hand-edited-old-backend > "$site"
printf new-shared > "$stage/conf.d/shared.conf"
printf new-backend > "$stage/sites-available/query.example.test.conf"
nginx_test() { return 0; }
nginx_reload() {
    # Recovery must reload only the original configuration, never a mixture.
    [[ "$(cat "$shared")" == original-shared ]]
    [[ "$(cat "$site")" == hand-edited-old-backend ]]
    touch "$GB_TMP/recovery-reloaded"
}
nginx_transaction_begin query.example.test
if nginx_apply_stage "$stage" edited-route; then exit 2; fi
[[ "$(cat "$shared")" == original-shared ]]
[[ "$(cat "$site")" == hand-edited-old-backend ]]
[[ "$(gb_ledger_get "$shared")" == "$(gb_sha256_file "$shared")" ]]
[[ "$(gb_ledger_get "$site")" != "$(gb_sha256_file "$site")" ]]
[[ -f "$GB_TMP/recovery-reloaded" ]]
[[ ${#NG_TRANSACTION_FILES[@]} == 0 ]]
''')

    def test_nginx_reload_propagates_systemctl_failure(self):
        self.shell('''
GB_PREFIX=''
NG_VERSION=1.24.0
NG_AVAILABLE=true
GB_SYSTEMCTL=false
GB_NGINX_BIN=false
if nginx_reload; then exit 2; fi
''')


if __name__ == "__main__":
    unittest.main()
