#!/usr/bin/env bash
# systemd units and timers: install from a staged file, enable, restart with a
# readiness gate, and roll back when the new unit fails to come up.

[[ -n "${GB_SYSTEMD_LOADED:-}" ]] && return 0
GB_SYSTEMD_LOADED=1

sd_available() { gb_have "$GB_SYSTEMCTL" && [[ -z "$GB_PREFIX" ]]; }

sd_daemon_reload() {
    sd_available || return 0
    [[ "$GB_DRY_RUN" == true ]] && return 0
    "$GB_SYSTEMCTL" daemon-reload
}

# sd_install_unit SOURCE NAME: install /etc/systemd/system/NAME from a rendered file.
sd_install_unit() {
    local source="$1" name="$2" target
    target="$GB_SYSTEMD/$name"
    gb_ensure_dir "$GB_SYSTEMD" 0755
    if [[ -f "$target" ]] && [[ "$(gb_sha256_file "$target")" == "$(gb_sha256_file "$source")" ]]; then
        return 0
    fi
    gb_install_file "$source" "$target" 0644
    gb_ledger_record "$target"
    SD_UNITS_CHANGED=true
}

# sd_install_dropin SOURCE UNIT DROPIN_NAME
sd_install_dropin() {
    local source="$1" unit="$2" dropin="$3" dir
    dir="$GB_SYSTEMD/$unit.d"
    gb_ensure_dir "$dir" 0755
    if [[ -f "$dir/$dropin" ]] && [[ "$(gb_sha256_file "$dir/$dropin")" == "$(gb_sha256_file "$source")" ]]; then
        return 0
    fi
    gb_install_file "$source" "$dir/$dropin" 0644
    gb_ledger_record "$dir/$dropin"
    SD_UNITS_CHANGED=true
}

sd_enable() {
    sd_available || return 0
    [[ "$GB_DRY_RUN" == true ]] && return 0
    "$GB_SYSTEMCTL" enable "$@" >/dev/null 2>&1 || "$GB_SYSTEMCTL" enable "$@"
}

sd_disable_now() {
    sd_available || return 0
    [[ "$GB_DRY_RUN" == true ]] && return 0
    "$GB_SYSTEMCTL" disable --now "$@" >/dev/null 2>&1 || true
}

sd_start() { sd_available || return 0; [[ "$GB_DRY_RUN" == true ]] && return 0; "$GB_SYSTEMCTL" start "$@"; }
sd_stop() { sd_available || return 0; [[ "$GB_DRY_RUN" == true ]] && return 0; "$GB_SYSTEMCTL" stop "$@" 2>/dev/null || true; }
sd_restart() { sd_available || return 0; [[ "$GB_DRY_RUN" == true ]] && return 0; "$GB_SYSTEMCTL" restart "$@"; }
sd_is_active() { sd_available || return 1; "$GB_SYSTEMCTL" is-active --quiet "$1"; }
sd_is_enabled() { sd_available || return 1; "$GB_SYSTEMCTL" is-enabled --quiet "$1" 2>/dev/null; }

sd_status_line() {
    local unit="$1"
    if ! sd_available; then printf 'unknown\n'; return 0; fi
    printf '%s/%s\n' "$("$GB_SYSTEMCTL" is-active "$unit" 2>/dev/null || true)" "$("$GB_SYSTEMCTL" is-enabled "$unit" 2>/dev/null || true)"
}

sd_remove_unit() {
    local name="$1" target
    target="$GB_SYSTEMD/$name"
    sd_disable_now "$name"
    rm -f -- "$target"
    rm -rf -- "$target.d"
    gb_ledger_forget "$target"
    SD_UNITS_CHANGED=true
}

# Wait until a unix socket answers a health URL, up to TIMEOUT seconds.
sd_wait_ready() {
    local socket="$1" path="$2" timeout="${3:-90}" waited=0
    [[ -z "$GB_PREFIX" ]] || return 0
    while (( waited < timeout )); do
        if curl --silent --fail --max-time 5 --unix-socket "$socket" "http://localhost$path" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

sd_journal() {
    local unit="$1" lines="${2:-200}"
    sd_available || { printf 'journal unavailable\n'; return 0; }
    journalctl --unit "$unit" --lines "$lines" --no-pager 2>/dev/null || true
}
