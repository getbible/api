#!/usr/bin/env bash
# Observe the current systemd instance, not a successful state from an old boot.
# Container recreations share the host kernel boot ID, so that ID is insufficient.

image_update_completion() {
    local snapshot="$1" expected="$2" key value active='' result='' process='' started='' finished='' code=''
    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState) active="$value" ;;
            Result) result="$value" ;;
            MainPID) process="$value" ;;
            ExecMainStartTimestampMonotonic) started="$value" ;;
            ExecMainExitTimestampMonotonic) finished="$value" ;;
            ExecMainStatus) code="$value" ;;
        esac
    done <<< "$snapshot"
    # Unstarted, queued and running oneshots cannot acknowledge a previous result.
    [[ "$active" == inactive || "$active" == failed ]] || return 75
    [[ "$process" == 0 && "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]] || return 75
    (( started > 0 && finished >= started )) || return 75
    [[ "$code" =~ ^[0-9]+$ && -n "$result" ]] || return 75
    if [[ "$expected" == failed ]]; then
        [[ "$result" != success && "$code" != 0 ]]
    else
        [[ "$result" == success && "$code" == 0 ]]
    fi
}

image_update_wait() {
    local desired="$1" expected="${2:-current}" state="${3:-/var/lib/getbible/state/image-update.conf}"
    local budget="${4:-600}" snapshot completion observed_version observed_status deadline
    [[ "$expected" == current || "$expected" == failed ]] || return 2
    [[ "$budget" =~ ^[1-9][0-9]{0,3}$ ]] || return 2
    deadline=$((SECONDS + budget))
    while (( SECONDS < deadline )); do
        snapshot="$(systemctl show getbible-image-update.service \
            -p ActiveState -p Result -p MainPID -p ExecMainStartTimestampMonotonic \
            -p ExecMainExitTimestampMonotonic -p ExecMainStatus)" || return 1
        completion=0
        image_update_completion "$snapshot" "$expected" || completion=$?
        if (( completion != 75 )); then
            if [[ -f "$state" ]]; then
                observed_version="$(sed -n 's/^DESIRED_VERSION=//p' "$state")"
                observed_status="$(sed -n 's/^STATUS=//p' "$state")"
                if (( completion == 0 )) && [[ "$observed_version" == "$desired" && "$observed_status" == "$expected" ]]; then
                    cat "$state"
                    return 0
                fi
            fi
            printf 'This boot completed image application without the expected result (%s, %s).\n%s\n' "$desired" "$expected" "$snapshot" >&2
            break
        fi
        sleep 1
    done
    cat "$state" 2>/dev/null || true
    journalctl -u getbible-image-update.service --no-pager -n 80 >&2 || true
    return 1
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    set -Eeuo pipefail
    image_update_wait "$@"
fi
