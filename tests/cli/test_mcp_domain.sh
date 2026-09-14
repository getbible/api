#!/usr/bin/env bash
# Dedicated-domain registry, root routing, admission and publication boundaries.
# shellcheck disable=SC2329 # Test stand-ins are called by the sourced manager.
# shellcheck disable=SC2016 # nginx variables are literal configuration text.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry users systemd python pages nginx access endpoint golive; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/mcp/type.sh
source "$ROOT/src/types/mcp/type.sh"
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
trap 'printf "MCP domain assertion failed at line %s\n" "$LINENO" >&2' ERR
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; }
no_match() { ! grep -Eq -- "$1" "$2"; }
py_resolve_version() { [[ "$1" != invalid ]] && printf '3.12.14\n'; }
nginx_conflicts() { :; }
endpoint_apply() { printf '%s\n' "$1" >> "$TEST_ROOT/applied"; }
gb_ensure_base_dirs
cfg_set "$GB_GLOBAL_CONF" TLS_MODE external
cfg_set "$GB_GLOBAL_CONF" TRUSTED_PROXY_CIDRS 192.0.2.10
cfg_set "$GB_GLOBAL_CONF" PUBLIC_SCHEME https
cfg_set "$GB_GLOBAL_CONF" ORIGIN_HTTP_PORT 18080
domain=mcp.example.test
type_mcp_deploy_cli --domain "$domain" --staged --access token --python auto
check test "$(ep_get "$domain" TYPE)" = mcp
check test "$(ep_get "$domain" KIND)" = mcp
check test "$(ep_get "$domain" LIVE)" = false
check test "$(ep_get "$domain" ACCESS_MODE)" = token
check test "$(ep_get "$domain" MCP_ORIGIN)" = http://127.0.0.1:18080
check test -z "$(ep_versions "$domain")"
check test ! -e "$(ep_versions_dir "$domain")"
check grep -qx "$domain" "$TEST_ROOT/applied"
if type_mcp_deploy_cli --domain invalid.example.test --python invalid; then exit 1; fi
check test ! -e "$(ep_conf invalid.example.test)"
if type_mcp_deploy_cli --domain other.example.test --version v2; then exit 1; fi
check test ! -e "$(ep_conf other.example.test)"
ep_create static.example.test static static
if mcp_cli configure static.example.test --origin http://127.0.0.1:18080; then exit 1; fi
check test -z "$(ep_get static.example.test MCP_ORIGIN)"

generation="$(mcp_root "$domain")/deployments/ready"
mkdir -p "$generation"
printf '%s\n' "$TEST_ROOT/mcp.sock" > "$generation/.socket"
gb_switch_link "$generation" "$(mcp_root "$domain")/active"
ep_load "$domain"
pages_publish "$domain"
check test -z "$(pages_domain_docs_location "$domain")"
check test -z "$(pages_domain_openapi_location "$domain")"
check test ! -e "$(pages_versions_file "$domain")"
nginx_render_endpoint "$TEST_ROOT/stage"
site="$TEST_ROOT/stage/sites-available/$domain.conf"
check test "$(grep -c 'location = / {' "$site")" = 1
check grep -Fq 'if ($request_method !~ ^(GET|HEAD|POST|OPTIONS)$)' "$site"
check grep -Fq 'set $gb_allowed_methods "GET, HEAD, POST, OPTIONS";' "$site"
check grep -Fq 'proxy_set_header Authorization "";' "$site"
check grep -Fq 'proxy_set_header X-Forwarded-For $remote_addr;' "$site"
check grep -Fq 'proxy_set_header X-Forwarded-Proto $gb_public_scheme;' "$site"
check grep -Fq 'proxy_set_header X-GetBible-Token-Id $gb_token_id;' "$site"
check grep -Fq "include $GB_NGINX_GB/$domain/auth.conf;" "$site"
check grep -Fq "include $GB_NGINX_GB/$domain/limits.conf;" "$site"
check grep -Fq 'access.log getbible_json' "$site"
check grep -Fq 'Cache-Control "no-store"' "$site"
check grep -Fq 'proxy_hide_header X-Request-ID;' "$site"
check grep -Fq 'proxy_hide_header X-GetBible-Telemetry-Operation;' "$site"
check grep -Fq 'location = /healthz {' "$site"
check grep -Fq 'location = /readyz {' "$site"
check no_match 'location .*(/mcp|/v[0-9]|/versions.json|/version.json|/openapi.json)|index.html|json sha' "$site"
check grep -Fq 'if ($gb_token_id = "")' "$TEST_ROOT/stage/getbible/$domain/auth.conf"

# Admission runs before any service candidates start; the type delegates once.
resources_preflight() { printf 'admission\n' >> "$TEST_ROOT/order"; }
mcp_prepare() { printf 'prepare\n' >> "$TEST_ROOT/order"; }
mcp_commit() { printf 'commit\n' >> "$TEST_ROOT/order"; }
mcp_finish() { printf 'finish\n' >> "$TEST_ROOT/order"; }
type_mcp_prepare "$domain"
type_mcp_finish "$domain"
check test "$(cat "$TEST_ROOT/order")" = $'admission\nprepare\ncommit\nfinish'

# The protocol root is never used as an unauthenticated HTTP readiness probe.
sd_available() { return 0; }
sd_is_active() { return 0; }
sd_wait_ready() { printf '%s\n' "$2" > "$TEST_ROOT/probe"; }
golive_mcp_ready "$domain"
check grep -qx /readyz "$TEST_ROOT/probe"
check grep -Fq 'paths=(/healthz /readyz)' "$ROOT/src/lib/golive.sh"

# All existing version mutations must fail before static code can create records.
for action in add change remove default; do
    if env -u GB_TMP "$ROOT/getbible.sh" version "$action" "$domain" v2 --repo file:///fixture.git > "$TEST_ROOT/version-error" 2>&1; then exit 1; fi
    grep -q 'unversioned root' "$TEST_ROOT/version-error" || { cat "$TEST_ROOT/version-error"; exit 1; }
    check test ! -e "$(ep_versions_dir "$domain")"
done
if env -u GB_TMP "$ROOT/getbible.sh" pages "$domain" docs generated > "$TEST_ROOT/pages-error" 2>&1; then exit 1; fi
check grep -q 'no editable documentation pages' "$TEST_ROOT/pages-error"
printf 'MCP dedicated domain tests passed\n'
