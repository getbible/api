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
check_result 0 "$(snapshot inactive success 0 100 200 0)" current
check_result 1 "$(snapshot failed exit-code 0 100 200 1)" current
check_result 0 "$(snapshot failed exit-code 0 100 200 1)" failed
check_result 1 "$(snapshot inactive success 0 100 200 0)" failed

printf 'DESIRED_VERSION=3.2.0\nSTATUS=current\n' > "$T/state"
printf '0\n' > "$T/polls"
# shellcheck disable=SC2329 # Stand-ins are invoked by image_update_wait.
systemctl() {
    local count
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
printf 'Current-boot image completion, stale state and failure checks passed\n'
