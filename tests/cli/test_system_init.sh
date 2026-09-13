#!/usr/bin/env bash
# Required initialization failures stop conditional callers before deployment.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GETBIBLE_EXECUTION_MODE=native
for lib in core config deployment users telegram sync logs; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf "$TEST_ROOT"' EXIT

# Load the real entry-point function without executing main or replacing its
# implementation with a test copy. These cases exercise Bash conditional calls.
sed -n '/^gb_system_init() {$/,/^}$/p' "$ROOT/getbible.sh" > "$TEST_ROOT/system-init.sh"
[[ -s "$TEST_ROOT/system-init.sh" ]]
# shellcheck source=/dev/null
source "$TEST_ROOT/system-init.sh"

for scenario in config group helper; do
    # shellcheck disable=SC2317,SC2329 # Hooks invoked by the sourced init function; codes vary by ShellCheck version.
    (
        calls="$TEST_ROOT/$scenario.calls"
        : > "$calls"
        gb_require_root() { :; }
        gb_management_lock() { :; }
        gb_environment_validate() { :; }
        infrastructure_ensure() { printf 'infrastructure\n' >> "$calls"; }
        endpoint_apply() { printf 'endpoint\n' >> "$calls"; }
        case "$scenario" in
            config)
                # A failure inside cfg_set must cross gb_global_init and init.
                chmod() { printf 'config-mode\n' >> "$calls"; return 1; }
                ;;
            group)
                gb_global_init() { :; }
                # Retain real base/group helpers; never create a host account.
                GB_PREFIX=''
                gb_group_exists() { return 1; }
                groupadd() { printf 'group-create\n' >> "$calls"; return 1; }
                gb_identity_record() { printf 'identity-record\n' >> "$calls"; }
                ;;
            helper)
                gb_global_init() { :; }
                gb_ensure_base_groups() { :; }
                # The real Telegram installer must not hide its failed copy.
                gb_install_file() { printf 'helper-install\n' >> "$calls"; return 1; }
                ;;
        esac
        if gb_system_init; then
            endpoint_apply
            printf 'Initialization accepted a failed %s step\n' "$scenario" >&2
            exit 1
        fi
        [[ -s "$calls" ]]
        if grep -Eq '^(infrastructure|endpoint|identity-record)$' "$calls"; then
            printf 'Initialization continued after a failed %s step\n' "$scenario" >&2
            exit 1
        fi
        [[ "$(wc -l < "$calls")" == 1 ]]
    )
done

# Unit installation must stop before activating a timer when an earlier unit
# failed to install, even though the caller inspects the return value.
# shellcheck disable=SC2317,SC2329 # These service hooks are invoked indirectly by logs_render_rotation.
(
    calls="$TEST_ROOT/rotation.calls"
    : > "$calls"
    gb_install_file() { :; }
    sd_install_unit() { printf 'unit\n' >> "$calls"; return 1; }
    sd_daemon_reload() { printf 'reload\n' >> "$calls"; }
    sd_enable() { printf 'enable\n' >> "$calls"; }
    if logs_render_rotation; then echo 'Rotation installation failure was hidden' >&2; exit 1; fi
    [[ "$(cat "$calls")" == unit ]]
)
printf 'ok: conditional initialization propagates config, identity, helper and unit failures\n'
