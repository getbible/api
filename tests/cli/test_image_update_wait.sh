#!/usr/bin/env bash
# Historical success must not release acceptance while this boot owns the lock.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
# shellcheck source=../integration/wait-image-update.sh
source "$ROOT/tests/integration/wait-image-update.sh"

snapshot() {
    printf 'ActiveState=%s\nResult=%s\nMainPID=%s\nExecMainStartTimestampMonotonic=%s\nExecMainExitTimestampMonotonic=%s\nExecMainStatus=%s\n' "$@"
}
check_result() {
    local expected="$1" actual=0
    shift
    image_update_completion "$@" || actual=$?
    [[ "$actual" == "$expected" ]] || { printf 'Expected result %s, got %s\n' "$expected" "$actual" >&2; exit 1; }
}
check_result 75 "$(snapshot inactive success 0 0 0 0)" current
check_result 75 "$(snapshot activating success 123 100 0 0)" current
check_result 75 "$(snapshot activating success 123 300 200 0)" current
check_result 75 "$(snapshot inactive success 0 300 200 0)" current
check_result 75 "$(snapshot inactive success 0 invalid 200 0)" current
check_result 1 "$(snapshot failed dependency 0 0 0 0)" current
check_result 1 "$(snapshot inactive dependency 0 0 0 0)" failed
check_result 1 "$(snapshot failed exit-code 0 0 0 1)" current
check_result 0 "$(snapshot inactive success 0 100 200 0)" current
check_result 1 "$(snapshot failed exit-code 0 100 200 1)" current
check_result 0 "$(snapshot failed exit-code 0 100 200 1)" failed
check_result 1 "$(snapshot inactive success 0 100 200 0)" failed

printf 'DESIRED_VERSION=3.2.0\nSTATUS=current\n' > "$T/state"
printf '0\n' > "$T/polls"
# shellcheck disable=SC2329 # Stand-ins are invoked by image_update_wait.
systemctl() {
    local count
    if [[ "${1:-}" != show ]]; then return 3; fi
    if [[ "$2" == getbible-prepare.service ]]; then
        snapshot active success 0 90 95 0
        return 0
    fi
    count="$(cat "$T/polls")"; count=$((count + 1)); printf '%s\n' "$count" > "$T/polls"
    case "$count" in
        1) snapshot inactive success 0 0 0 0 ;;
        2) snapshot activating success 123 100 0 0 ;;
        *) snapshot inactive success 0 100 200 0 ;;
    esac
}
# shellcheck disable=SC2329
sleep() { :; }
# shellcheck disable=SC2329
journalctl() { :; }
image_update_wait 3.2.0 current "$T/state" 2 >/dev/null
[[ "$(cat "$T/polls")" == 3 ]]
# A completed service must still agree with the durable version and outcome.
if image_update_wait 4.0.0 current "$T/state" 2 >/dev/null 2>&1; then
    echo 'Mismatched release acknowledged' >&2; exit 1
fi
printf 'DESIRED_VERSION=3.2.0\nSTATUS=failed\n' > "$T/state"
if image_update_wait 3.2.0 current "$T/state" 2 >/dev/null 2>&1; then
    echo 'Failed application acknowledged as current' >&2; exit 1
fi

# A prerequisite can fail before the image unit executes, leaving its own
# result at the unstarted default and its durable file from a successful boot.
# Fail immediately and retain both unit diagnostics, rather than waiting until
# unrelated timer messages displace the preparation failure from the journal.
printf 'DESIRED_VERSION=3.2.0\nSTATUS=current\n' > "$T/state"
: > "$T/diagnostic-calls"
printf '0\n' > "$T/polls"
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$T/diagnostic-calls"
    if [[ "${1:-}" != show ]]; then printf 'Synthetic failed prerequisite status\n'; return 3; fi
    if [[ "$2" == getbible-prepare.service ]]; then
        snapshot failed exit-code 0 100 200 1
    else
        local count
        count="$(cat "$T/polls")"; printf '%s\n' "$((count + 1))" > "$T/polls"
        snapshot inactive success 0 0 0 0
    fi
}
sleep() { printf 'sleep %s\n' "$*" >> "$T/diagnostic-calls"; }
journalctl() {
    printf 'journalctl %s\n' "$*" >> "$T/diagnostic-calls"
    printf 'Synthetic preparation failure journal\n'
}
for expected in current failed; do
    printf '0\n' > "$T/polls"
    : > "$T/diagnostic-calls"
    if image_update_wait 3.2.0 "$expected" "$T/state" 2 > "$T/prerequisite-output" 2>&1; then
        echo 'A failed prerequisite acknowledged image application' >&2; exit 1
    fi
    [[ "$(cat "$T/polls")" == 1 ]]
    if grep -q '^sleep ' "$T/diagnostic-calls"; then
        echo 'A failed prerequisite waited instead of failing immediately' >&2; exit 1
    fi
    grep -qF 'Required image preparation failed' "$T/prerequisite-output"
    grep -qF 'Synthetic failed prerequisite status' "$T/prerequisite-output"
    grep -qF 'Synthetic preparation failure journal' "$T/prerequisite-output"
    grep -qFx 'systemctl --no-pager --full status getbible-prepare.service getbible-image-update.service' "$T/diagnostic-calls"
    grep -qFx 'journalctl -u getbible-prepare.service -u getbible-image-update.service --no-pager -n 160' "$T/diagnostic-calls"
done
printf 'Current-boot image completion, stale state, prerequisite failure and diagnostic checks passed\n'
