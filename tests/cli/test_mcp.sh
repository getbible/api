#!/usr/bin/env bash
# MCP lifecycle boundaries without network access or systemd mutation.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT"
# shellcheck source=../../src/lib/core.sh
source "$ROOT/src/lib/core.sh"
# shellcheck source=../../src/lib/config.sh
source "$ROOT/src/lib/config.sh"
# shellcheck source=../../src/lib/registry.sh
source "$ROOT/src/lib/registry.sh"
# shellcheck source=../../src/lib/python.sh
source "$ROOT/src/lib/python.sh"
# shellcheck source=../../src/lib/mcp.sh
source "$ROOT/src/lib/mcp.sh"
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; }
nginx_origin_http_port() { printf '80\n'; }
nginx_external_tls() { return 0; }
nginx_master_pid() { printf '0\n'; }
sd_snapshot_nginx_workers() { : > "$1"; }
sd_enable() { printf 'enable %s\n' "$*" >> "$TEST_ROOT/events"; }
sd_retire_after() { printf 'retire %s\n' "$1" >> "$TEST_ROOT/events"; }
sd_status_line() { printf 'active\n'; }
sd_is_enabled() { return 1; }
sd_is_active() { return 1; }
tg_notify() { :; }
domain=api.example.test
gb_ensure_dir "$(ep_dir "$domain")"
ep_set "$domain" TYPE static
ep_set "$domain" MCP_ENABLED true
check mcp_validate "$domain"
check test -z "$(mcp_active "$domain")"
ep_set "$domain" MCP_ORIGIN https://outside.example.test
if mcp_validate "$domain" >/dev/null 2>&1; then echo 'Public origin accepted' >&2; exit 1; fi
ep_set "$domain" MCP_ORIGIN http://127.0.0.1:80

root="$(mcp_root "$domain")"
old="$root/deployments/old"; candidate="$root/deployments/new"
mkdir -p "$old" "$candidate" "$root/releases/old" "$root/releases/new"
printf '%s\n' "$root/releases/old" > "$old/.release"
printf '%s\n' "$root/releases/new" > "$candidate/.release"
printf '%s\n' "$TEST_ROOT/old.sock" > "$old/.socket"
printf '%s\n' "$TEST_ROOT/new.sock" > "$candidate/.socket"
gb_switch_link "$old" "$root/active"
gb_switch_link "$root/releases/old" "$root/current"
MCP_DOMAIN="$domain"; MCP_OLD="$old"; MCP_CANDIDATE="$candidate"; MCP_SWITCHED=false
MCP_BACKUP="$TEST_ROOT/backup"
mkdir -p "$MCP_BACKUP"
for target in active previous current; do gb_backup_file "$root/$target" "$MCP_BACKUP"; done
check test "$(mcp_proxy_socket "$domain")" = "$TEST_ROOT/new.sock"
mcp_render_generation "$domain" "$candidate" "$root/releases/new"
check grep -q 'Type=notify' "$candidate/service.unit"
check grep -q 'getbible_mcp_api.app:create_app()' "$candidate/service.unit"
check grep -q 'uvicorn_worker.UvicornWorker' "$candidate/gunicorn.conf.py"
check grep -q 'MemoryMax=256M' "$candidate/service.unit"
mcp_render_location "$domain" "$TEST_ROOT/location.conf"
check grep -q 'location = /mcp' "$TEST_ROOT/location.conf"
check grep -q 'proxy_cache off' "$TEST_ROOT/location.conf"
check grep -q 'proxy_buffering off' "$TEST_ROOT/location.conf"
check grep -q "auth.conf" "$TEST_ROOT/location.conf"
mcp_before_switch "$domain"
check test "$MCP_SWITCHED" = true
check test "$(mcp_active "$domain")" = "$old"
mcp_commit "$domain"
mcp_finish "$domain"
check test "$(mcp_active "$domain")" = "$candidate"
check test "$(readlink -f "$root/previous")" = "$old"
check grep -q "retire $(mcp_unit "$domain" "$old")" "$TEST_ROOT/events"

# Disabling is reversible if another participant cannot finish its commit.
ep_set "$domain" MCP_ENABLED false
mcp_prepare "$domain"
mcp_commit "$domain"
check test -z "$(mcp_active "$domain")"
mcp_abort "$domain"
check test "$(mcp_active "$domain")" = "$candidate"
ep_set "$domain" MCP_ENABLED true

# A failed enable/update restores the exact prior configuration.
cp "$(ep_conf "$domain")" "$TEST_ROOT/config-before"
endpoint_apply() { return 1; }
if mcp_cli enable "$domain" --origin http://127.0.0.1:81; then echo 'Failed apply accepted' >&2; exit 1; fi
check cmp "$(ep_conf "$domain")" "$TEST_ROOT/config-before"
if mcp_cli enable "$domain" --origin http://127.0.0.1:81 --invalid x; then echo 'Unknown option accepted' >&2; exit 1; fi
check cmp "$(ep_conf "$domain")" "$TEST_ROOT/config-before"
printf 'MCP lifecycle and configuration tests passed\n'
