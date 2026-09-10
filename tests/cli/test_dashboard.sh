#!/usr/bin/env bash
# Operator presentation and transaction outcomes without host changes or network.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
GB_VERSION='test'
GB_YES=true
GB_UI=none
GB_PYTHON=python3
# shellcheck source=../../src/lib/ui.sh
source "$ROOT/src/lib/ui.sh"
# shellcheck source=../../src/lib/endpoint.sh
source "$ROOT/src/lib/endpoint.sh"
# shellcheck source=../../src/lib/menu.sh
source "$ROOT/src/lib/menu.sh"
check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" != *"$expected"* ]]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'ok: %s\n' "$name"
}

check "health is readable" "online" "$(printf '{"status":"ok"}' | ui_health_text)"
check "readiness is readable" "ready" "$(printf '{"status":"ready"}' | ui_health_text)"
check "unavailable is retained" "unavailable" "$(printf '{"status":"unavailable"}' | ui_health_text)"
check "problem response explains failure" "Not ready (HTTP 503): Local files unavailable." \
    "$(printf '{"status":503,"title":"Not ready","detail":"Local files unavailable."}' | ui_health_text)"
check "failed connection is retained" "unreachable" "$(printf '' | ui_health_text)"
check "unexpected response is visible" "unexpected health response" "$(printf '<html>Error</html>' | ui_health_text)"
service="$(printf 'TasksCurrent=9\nMemoryCurrent=10485760\nMainPID=123\nNRestarts=2\n' | ui_service_text)"
check "service memory has units" "Memory        : 10.0 MiB" "$service"
check "service properties have labels" "Restarts      : 2" "$service"

gb_tmpdir() { printf '%s\n' "$SB"; }
ui_textbox() { cat "$2"; }
test_failure() { printf 'Repository could not be reached\n'; return 7; }
GB_UI=whiptail
status=0
ui_run "Repository sync" test_failure > "$SB/result" || status=$?
check "dialog operation keeps failure" "7" "$status"
check "dialog explains outcome" "Result: failed (exit 7)" "$(cat "$SB/result")"
check "dialog keeps diagnostics" "Repository could not be reached" "$(cat "$SB/result")"
check "dialog restores capture flag" "false" "$GB_UI_CAPTURED"
GB_UI=cli
status=0
ui_run "Repository sync" test_failure > "$SB/result" || status=$?
check "plain operation keeps failure" "7" "$status"
check "plain operation explains outcome" "Result: failed (exit 7)" "$(cat "$SB/result")"

ep_get() {
    case "$2" in
        TYPE) printf 'runtime\n' ;;
        KIND) printf 'search\n' ;;
        ACCESS_MODE) printf 'open\n' ;;
        CLOUDFLARE_MODE) printf 'dns\n' ;;
    esac
}
ep_versions() { printf 'v2\n'; }
ep_publication() { printf 'live\n'; }
ep_state_get() {
    case "$2" in
        LAST_ERROR) printf '%s' "$STATE_ERROR" ;;
        GOLIVE_VERIFICATION) printf 'pending' ;;
    esac
}
STATE_ERROR="Repository sync failed"
check "saved failure appears in menu" "needs attention" "$(menu_domain_summary example.test)"
STATE_ERROR=""
check "pending public verification appears in menu" "public check pending" "$(menu_domain_summary example.test)"

# Simulate the pipeline with all system operations replaced. A failed
# certificate must abort before finish/commit/DNS; offline rendering may skip it.
GB_PREFIX=""
GB_DRY_RUN=false
GB_CLOUDFLARE_LOADED=1
GB_REPO_DIR="$SB"
GB_TYPES="$SB/types"
EP_TYPE=fixture
EP_SLUG=example_test
GOLIVE_CHECK_ORIGIN=false
EVENTS="$SB/events"
ep_load() { :; }
endpoint_source_type() { :; }
ep_is_live() { return 0; }
gb_ensure_base_dirs() { :; }
logs_ensure_endpoint_dir() { :; }
gb_new_backup_set() { printf '%s\n' "$SB/backup"; }
gb_backup_file() { :; }
nginx_enabled_file() { printf '%s\n' "$SB/enabled"; }
nginx_validate_proxy_settings() { return 0; }
nginx_external_tls() { return 1; }
nginx_transaction_begin() { printf 'begin\n' >> "$EVENTS"; }
nginx_transaction_commit() { printf 'commit\n' >> "$EVENTS"; }
cloudflare_protect_access() { :; }
type_fixture_prepare() { :; }
pages_publish() { :; }
nginx_render_global() { :; }
nginx_render_endpoint() { :; }
nginx_enable_site() { :; }
nginx_apply_stage() { :; }
nginx_cert_exists() { [[ "$HAS_CERT" == true ]]; }
certs_install_hook() { :; }
certs_obtain() { return 1; }
certs_can_run() { return 1; }
type_fixture_finish() { printf 'finish\n' >> "$EVENTS"; }
cloudflare_apply() { printf 'dns\n' >> "$EVENTS"; }
certs_placeholder_remove() { :; }
ep_state_set() { :; }
gb_timestamp() { printf 'now\n'; }
gb_log() { :; }
endpoint_apply_abort() { printf 'abort: %s\n' "$2" >> "$EVENTS"; return 1; }
golive_verify() { printf 'verify\n' >> "$EVENTS"; return 1; }
HAS_CERT=false
: > "$EVENTS"
status=0
endpoint_apply example.test || status=$?
check "certificate failure fails apply" "1" "$status"
check "certificate failure aborts transaction" "abort: Certificate issuance failed" "$(cat "$EVENTS")"
if grep -Eq '^(finish|commit|dns)$' "$EVENTS"; then
    printf 'FAIL: certificate failure activated an incomplete deployment\n' >&2
    exit 1
fi
GB_PREFIX="$SB"
: > "$EVENTS"
endpoint_apply example.test
check "offline render still works" "commit" "$(cat "$EVENTS")"

GB_PREFIX=""
HAS_CERT=true
GOLIVE_CHECK_ORIGIN=true
: > "$EVENTS"
status=0
endpoint_apply example.test || status=$?
check "origin verification failure fails apply" "1" "$status"
check "origin verification keeps committed runtime" $'finish\ncommit\nverify' "$(cat "$EVENTS")"
if grep -Eq '^(dns|abort)' "$EVENTS"; then
    printf 'FAIL: failed origin verification changed DNS or tore down runtime\n' >&2
    exit 1
fi
printf 'Dashboard and deployment outcome checks passed.\n'
