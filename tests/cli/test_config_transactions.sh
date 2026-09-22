#!/usr/bin/env bash
# General prepare/write/commit/interruption invariants, independent of systemd.
# shellcheck disable=SC2329 # Injected lifecycle implementations are called indirectly.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry python pages endpoint mcp; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
trap 'printf "Transaction check failed on line %s\n" "$LINENO" >&2' ERR
mkdir -p "$GB_LOG"
tg_notify() { :; }
nginx_external_tls() { return 0; }
nginx_origin_http_port() { printf '80\n'; }
domain=query.example.test
ep_create "$domain" runtime query
for label in v2 v3; do
    cfg_set "$(ep_version_conf "$domain" "$label")" ENABLED true
    ep_version_set "$domain" "$label" PYTHON_VERSION "3.$((10 + ${label#v})).1"
done
missing=false; fail_bundle=false; fail_write=false; mode=success; calls=0
py_resolve_version() {
    case "$1" in
        3.12|3.12.*) printf '3.12.14\n' ;;
        3.13|3.13.*) [[ "$missing" != true ]] && printf '3.13.11\n' ;;
        *) return 1 ;;
    esac
}
py_bundle_validate() { [[ "$fail_bundle" != true ]]; }
eval "$(declare -f ep_version_set | sed '1s/ep_version_set/real_ep_version_set/')"
ep_version_set() {
    real_ep_version_set "$@" || return 1
    [[ "$fail_write" != true || "$2" != v3 ]]
}
endpoint_apply() {
    calls=$((calls + 1))
    case "$mode" in
        fail) return 1 ;;
        unsafe) EP_APPLY_RECOVERY_SAFE=false; return 1 ;;
        edge) EP_ORIGIN_COMMITTED=true; EP_APPLY_EDGE_FAILED=true; return 1 ;;
        success) EP_ORIGIN_COMMITTED=true; configuration_transaction_phase "$1" origin-committed ;;
    esac
}
original="$(sha256sum "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)")"
missing=true
if rt_update "$domain"; then exit 1; fi
[[ "$calls" == 0 && "$(sha256sum "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)")" == "$original" ]]
missing=false; fail_bundle=true
if rt_update "$domain"; then exit 1; fi
[[ "$calls" == 0 && "$(sha256sum "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)")" == "$original" ]]
fail_bundle=false; fail_write=true
if rt_update "$domain"; then exit 1; fi
[[ "$calls" == 0 && "$(sha256sum "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)")" == "$original" ]]
fail_write=false; mode=fail
if rt_update "$domain"; then exit 1; fi
[[ "$calls" == 1 && "$(sha256sum "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)")" == "$original" ]]
mode=edge
if rt_update "$domain"; then exit 1; fi
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.14 && "$(ep_version_get "$domain" v3 PYTHON_VERSION)" == 3.13.11 ]]
[[ ! -d "$(configuration_transaction_dir "$domain")" ]]

# A crash before the traffic switch restores the entire original set.
configuration_transaction_begin "$domain" "$(ep_version_conf "$domain" v2)" "$(ep_version_conf "$domain" v3)"
ep_version_set "$domain" v2 PYTHON_VERSION 3.12.99
configuration_transaction_recover "$domain"
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.14 ]]

# Once a switch might have occurred, recovery completes the saved intent with
# the normal candidate path. A failed recovery is explicit and retryable.
configuration_transaction_begin "$domain" "$(ep_version_conf "$domain" v2)"
ep_version_set "$domain" v2 PYTHON_VERSION 3.12.99
configuration_transaction_prepared "$domain"
configuration_transaction_phase "$domain" switching
mode=fail
if configuration_transaction_recover "$domain"; then exit 1; fi
[[ -f "$(configuration_transaction_dir "$domain")/state" ]]
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.99 ]]
mode=success
configuration_transaction_recover "$domain"
[[ ! -d "$(configuration_transaction_dir "$domain")" ]]
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.99 ]]

# An explicit subset never changes the other endpoint's Python selection.
ep_version_set "$domain" v3 PYTHON_VERSION 3.13.1
rt_update "$domain" v2
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.14 && "$(ep_version_get "$domain" v3 PYTHON_VERSION)" == 3.13.1 ]]

# MCP update adopts its selected family's bundled patch and preserves committed
# settings when only edge work fails. Missing bundles fail before mutations.
mcp=mcp.example.test
ep_create "$mcp" mcp mcp
ep_set "$mcp" MCP_PYTHON_VERSION 3.12.1
ep_set "$mcp" MCP_ORIGIN http://127.0.0.1:80
fail_bundle=true
if mcp_image_update "$mcp"; then exit 1; fi
[[ "$(ep_get "$mcp" MCP_PYTHON_VERSION)" == 3.12.1 ]]
fail_bundle=false; mode=fail
if mcp_image_update "$mcp"; then exit 1; fi
[[ "$(ep_get "$mcp" MCP_PYTHON_VERSION)" == 3.12.1 ]]
mode=edge
if mcp_image_update "$mcp"; then exit 1; fi
[[ "$(ep_get "$mcp" MCP_PYTHON_VERSION)" == 3.12.14 ]]
printf 'Configuration transaction checks passed\n'
