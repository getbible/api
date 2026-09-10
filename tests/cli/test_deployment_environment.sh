#!/usr/bin/env bash
# Deployment environment precedence, captured systemd settings, secret handling
# and menu-write protection. No services or external APIs are contacted.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT"
unset GETBIBLE_EXECUTION_MODE GB_EXECUTION_MODE
for lib in core config deployment; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
passed=0
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; passed=$((passed + 1)); }
reject() {
    if "$@" > "$TEST_ROOT/rejected.out" 2>&1; then
        printf 'FAILED: invalid operation succeeded: %s\n' "$1" >&2; exit 1
    fi
    passed=$((passed + 1))
}

# A fixture prefix never becomes Docker just because the test runner lives in
# a container. Explicit modes remain independent of certificate ownership.
check test "$(gb_execution_mode)" = native
export container=docker
check test "$(gb_execution_mode)" = native
export GETBIBLE_EXECUTION_MODE=native
gb_global_init
check test "$(gb_global TLS_MODE)" = managed
export GETBIBLE_TLS_MODE=external
check test "$(gb_execution_mode)" = native
check test "$(gb_global TLS_MODE)" = external
check test "$(cfg_get_raw "$GB_GLOBAL_CONF" TLS_MODE)" = managed
reject cfg_set "$GB_GLOBAL_CONF" TLS_MODE managed
check test "$(cfg_get_raw "$GB_GLOBAL_CONF" TLS_MODE)" = managed
check grep -Fq 'GETBIBLE_TLS_MODE' "$TEST_ROOT/rejected.out"

# Empty Compose placeholders are unset, whereas false and numeric zero are
# explicit values and must not accidentally fall back to saved configuration.
export GETBIBLE_TLS_MODE=""
check test "$(gb_global TLS_MODE)" = managed
cfg_set "$GB_GLOBAL_CONF" CLOUDFLARE_ENABLED true
export GETBIBLE_CLOUDFLARE_ENABLED=false GETBIBLE_DEFAULT_QUOTA_HOUR=0
check test "$(gb_global CLOUDFLARE_ENABLED)" = false
check test "$(gb_global DEFAULT_QUOTA_HOUR)" = 0
check gb_environment_validate
check test "$(cfg_get_raw "$GB_GLOBAL_CONF" CLOUDFLARE_ENABLED)" = true

# A mounted secret is read as data. A conventional final newline is accepted;
# embedded newlines, unreadable paths, unsupported _FILE keys and simultaneous
# direct/file credentials are rejected without printing the credential.
secret=fixture-private-package-token
printf '%s\n' "$secret" > "$TEST_ROOT/cloudflare-token"
chmod 0600 "$TEST_ROOT/cloudflare-token"
export GETBIBLE_CLOUDFLARE_API_TOKEN_FILE="$TEST_ROOT/cloudflare-token"
check test "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" = "$secret"
check gb_environment_validate
export GETBIBLE_CLOUDFLARE_API_TOKEN=conflicting-private-token
reject gb_environment_validate
if grep -Eq 'fixture-private-package-token|conflicting-private-token' "$TEST_ROOT/rejected.out"; then
    echo 'Secret leaked by validation' >&2; exit 1
fi
reject cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN
reject cfg_set "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN replacement
unset GETBIBLE_CLOUDFLARE_API_TOKEN
printf 'first-line\nsecond-line\n' > "$TEST_ROOT/cloudflare-token"
reject gb_environment_validate
if grep -Eq 'first-line|second-line' "$TEST_ROOT/rejected.out"; then echo 'Multiline secret leaked' >&2; exit 1; fi
export GETBIBLE_CLOUDFLARE_API_TOKEN_FILE="$TEST_ROOT/missing-token"
reject gb_environment_validate
export GETBIBLE_CLOUDFLARE_API_TOKEN_FILE="$TEST_ROOT/cloudflare-token"
printf '%s\n' "$secret" > "$TEST_ROOT/cloudflare-token"
export GETBIBLE_TLS_MODE_FILE="$TEST_ROOT/cloudflare-token"
reject gb_environment_validate
unset GETBIBLE_TLS_MODE_FILE

# Capturing values once at boot gives later systemd/exec invocations the same
# settings, even if those processes have none of Docker's direct environment.
export GETBIBLE_EXECUTION_MODE=docker GETBIBLE_TLS_MODE=external
export GETBIBLE_TELEGRAM_BOT_TOKEN=fixture-telegram-token
gb_environment_capture
check test "$(stat -c %a "$GB_ENVIRONMENT_CONF")" = 600
check test "$(cfg_get_raw "$GB_ENVIRONMENT_CONF" TLS_MODE)" = external
check test "$(cfg_get_raw "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" = ""
unset GETBIBLE_TLS_MODE GETBIBLE_CLOUDFLARE_API_TOKEN_FILE GETBIBLE_TELEGRAM_BOT_TOKEN
check test "$(gb_global TLS_MODE)" = external
check test "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" = "$secret"
reject cfg_set "$GB_GLOBAL_CONF" TLS_MODE managed
check test "$(cfg_get_raw "$GB_GLOBAL_CONF" TLS_MODE)" = managed
# shellcheck disable=SC2016 # Expansion happens in the independent child shell.
child_result="$(env -i PATH="$PATH" GB_PREFIX="$GB_PREFIX" GB_REPO_DIR="$ROOT" GETBIBLE_EXECUTION_MODE=docker bash -c '
    for lib in core config deployment; do source "$GB_REPO_DIR/src/lib/$lib.sh"; done
    printf "%s/%s\n" "$(gb_global TLS_MODE)" "$(gb_global CLOUDFLARE_ENABLED)"
')"
check test "$child_result" = external/false
gb_environment_status > "$TEST_ROOT/status.out"
if grep -Eq 'fixture-private-package-token|fixture-telegram-token' "$TEST_ROOT/status.out"; then
    echo 'Environment report leaked a credential' >&2; exit 1
fi
check grep -Fq '(configured; hidden)' "$TEST_ROOT/status.out"
check grep -Eq 'TLS_MODE +environment +external' "$TEST_ROOT/status.out"

# Direct values override the captured snapshot. Native execution ignores that
# Docker-only snapshot, allowing native installations to retain saved choices.
export GETBIBLE_TLS_MODE=managed
check test "$(gb_global TLS_MODE)" = managed
unset GETBIBLE_TLS_MODE
export GETBIBLE_EXECUTION_MODE=native
check test "$(gb_global TLS_MODE)" = managed
export GETBIBLE_EXECUTION_MODE=unknown
reject gb_environment_validate
export GETBIBLE_EXECUTION_MODE=docker

# Deployment validation must use the same limits as endpoint creation so a
# container cannot initialize with settings its runtime menu cannot deploy.
check gb_setting_validate DEFAULT_QUERY_WORKERS 64
reject gb_setting_validate DEFAULT_QUERY_WORKERS 65
reject gb_setting_validate DEFAULT_SEARCH_THREADS 128
check gb_setting_validate DEFAULT_QUERY_CACHE_TTL 9999999
reject gb_setting_validate DEFAULT_QUERY_CACHE_TTL 10000000
reject gb_setting_validate TRUSTED_PROXY_CIDRS 0.0.0.0/0
reject gb_setting_validate ORIGIN_HTTP_PORT 65536

# Recreation replaces the snapshot; removing an explicit environment setting
# restores the saved value instead of carrying a stale override indefinitely.
unset GETBIBLE_CLOUDFLARE_ENABLED GETBIBLE_DEFAULT_QUOTA_HOUR
gb_environment_capture
check test "$(gb_global TLS_MODE)" = managed
check test "$(gb_global CLOUDFLARE_ENABLED)" = true
check test "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" = ""

# A fresh Docker installation seeds its deployment defaults independently of
# native defaults, and direct overrides are never mistaken for saved values.
GB_GLOBAL_CONF="$GB_ETC/fresh-docker.conf"
export GETBIBLE_DEFAULT_QUERY_WORKERS=3
gb_global_init
check test "$(gb_global TLS_MODE)" = external
check test "$(gb_global DEFAULT_DEPLOY_MODE)" = staged
check test "$(gb_global DEFAULT_CLOUDFLARE_MODE)" = proxied
check test "$(gb_global DEFAULT_CLOUDFLARE_CACHE)" = respect
check test "$(gb_global DEFAULT_QUERY_WORKERS)" = 3
check test "$(cfg_get_raw "$GB_GLOBAL_CONF" DEFAULT_QUERY_WORKERS)" = 4
printf 'Deployment environment: %s assertions passed\n' "$passed"
