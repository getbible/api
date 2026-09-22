#!/usr/bin/env bash
# Bundled families, no-op generations and immutable upstream environment.
# shellcheck disable=SC2329 # Lifecycle stand-ins are called by the sourced driver.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry python pages users systemd mcp; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf -- "$GB_PREFIX"' EXIT
trap 'printf "MCP upgrade check failed at line %s\n" "$LINENO" >&2' ERR
mkdir -p "$GB_LOG"
MODE=docker
calls="$GB_PREFIX/calls"; : > "$calls"
gb_is_docker() { [[ "$MODE" == docker ]]; }
py_bundle_root() { printf '%s/bundle\n' "$GB_PREFIX"; }
py_inputs_hash() { printf 'reviewed\n'; }
py_resolve_version() {
    case "$1" in 3.12|3.12.14) printf '3.12.14\n' ;; 3.13|3.13.11) printf '3.13.11\n' ;; *) return 1 ;; esac
}
[[ "$(mcp_update_python 3.12.1)" == 3.12.14 ]]
[[ "$(mcp_update_python 3.13.1)" == 3.13.11 ]]
if mcp_update_python 3.14.1; then exit 1; fi
if mcp_bundle_preflight 3.12.14 reviewed; then exit 1; fi
mkdir -p "$GB_PREFIX/bundle/wheels/3.12.14/mcp"
printf 'package==1\n' > "$GB_PREFIX/bundle/wheels/3.12.14/mcp/packages.requirements"
printf 'stale\n' > "$GB_PREFIX/bundle/wheels/3.12.14/mcp/.inputs"
if mcp_bundle_preflight 3.12.14 reviewed; then exit 1; fi
printf 'reviewed\n' > "$GB_PREFIX/bundle/wheels/3.12.14/mcp/.inputs"
mcp_bundle_preflight 3.12.14 reviewed
MODE=native
mcp_bundle_preflight 3.13.11 reviewed
nginx_external_tls() { return 0; }
nginx_origin_http_port() { printf '80\n'; }
nginx_master_pid() { printf '0\n'; }
sd_available() { return 0; }
sd_is_active() { return 0; }
sd_snapshot_nginx_workers() { : > "$1"; }
sd_retire_after() { printf 'retire %s\n' "$1" >> "$calls"; }
sd_start() { printf 'start %s\n' "$1" >> "$calls"; }
sd_enable() { :; }
sd_daemon_reload() { :; }
sd_wait_ready() { return 0; }
gb_ensure_base_groups() { :; }
gb_ensure_system_user() { :; }
tg_notify() { :; }
domain=mcp.example.test
ep_create "$domain" mcp mcp
ep_set "$domain" MCP_PYTHON_VERSION 3.12.14
ep_set "$domain" MCP_ORIGIN http://127.0.0.1:80
release="$(mcp_root "$domain")/releases/one"
old="$(mcp_root "$domain")/deployments/one"
mkdir -p "$release/.venv/bin" "$old"
printf '#!/bin/sh\nexit 0\n' > "$release/.venv/bin/python"
chmod +x "$release/.venv/bin/python"
printf 'reviewed\n' > "$release/.inputs"
printf '%s\n' "$release" > "$old/.release"
printf '%s\n' "$GB_PREFIX/old.sock" > "$old/.socket"
gb_switch_link "$release" "$(mcp_root "$domain")/current"
gb_switch_link "$old" "$(mcp_root "$domain")/active"
mcp_deployment_inputs "$domain" "$release" > "$old/.inputs"
mcp_prepare "$domain"
[[ -z "$MCP_CANDIDATE" ]]
mcp_before_switch "$domain"
mcp_commit "$domain"
mcp_finish "$domain"
[[ ! -s "$calls" && "$(mcp_active "$domain")" == "$old" ]]
# A changed environment is snapshotted; future changes to the external file
# cannot alter the selected generation on an unrelated service restart.
printf 'EXAMPLE_SETTING=old\n' > "$GB_PREFIX/upstreams.env"
ep_set "$domain" MCP_ENV_FILE "$GB_PREFIX/upstreams.env"
mcp_prepare "$domain"
[[ -n "$MCP_CANDIDATE" ]]
grep -q '^EXAMPLE_SETTING=old$' "$MCP_CANDIDATE/mcp.env"
grep -q "^EnvironmentFile=$MCP_CANDIDATE/mcp.env$" "$MCP_CANDIDATE/service.unit"
printf 'EXAMPLE_SETTING=new\n' > "$GB_PREFIX/upstreams.env"
grep -q '^EXAMPLE_SETTING=old$' "$MCP_CANDIDATE/mcp.env"
[[ "$(stat -c %a "$MCP_CANDIDATE/mcp.env")" == 600 ]]
printf 'MCP bundle, no-op and immutable environment checks passed\n'
