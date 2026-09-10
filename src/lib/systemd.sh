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
    gb_ensure_dir "$GB_SYSTEMD" 0755 || return 1
    if [[ -f "$target" ]] && [[ "$(gb_sha256_file "$target")" == "$(gb_sha256_file "$source")" ]]; then
        return 0
    fi
    gb_install_file "$source" "$target" 0644 || return 1
    gb_ledger_record "$target" || return 1
    SD_UNITS_CHANGED=true
}

# sd_install_dropin SOURCE UNIT DROPIN_NAME
sd_install_dropin() {
    local source="$1" unit="$2" dropin="$3" dir
    dir="$GB_SYSTEMD/$unit.d"
    gb_ensure_dir "$dir" 0755 || return 1
    if [[ -f "$dir/$dropin" ]] && [[ "$(gb_sha256_file "$dir/$dropin")" == "$(gb_sha256_file "$source")" ]]; then
        return 0
    fi
    gb_install_file "$source" "$dir/$dropin" 0644 || return 1
    gb_ledger_record "$dir/$dropin" || return 1
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
    local socket="$1" path="$2" timeout="${3:-90}" deadline remaining request_timeout
    [[ -z "$GB_PREFIX" ]] || return 0
    deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        remaining=$((deadline - SECONDS)); request_timeout=5
        (( remaining >= request_timeout )) || request_timeout="$remaining"
        if curl --silent --fail --max-time "$request_timeout" --unix-socket "$socket" "http://localhost$path" >/dev/null 2>&1; then
            return 0
        fi
        (( SECONDS < deadline )) && sleep 1
    done
    return 1
}

sd_journal() {
    local unit="$1" lines="${2:-200}"
    sd_available || { printf 'journal unavailable\n'; return 0; }
    journalctl --unit "$unit" --lines "$lines" --no-pager 2>/dev/null || true
}

# Record worker identities, optionally restricted to one nginx master. A master
# value of 0 records no workers (the managed nginx has not started yet).
sd_snapshot_nginx_workers() {
    local target="$1" master="${2:-}" entry title pid stat
    local -a fields
    : > "$target" || return 1
    for entry in /proc/[0-9]*/cmdline; do
        title=""
        IFS= read -r -d '' title 2>/dev/null < "$entry" || true
        [[ "$title" == 'nginx: worker process'* ]] || continue
        pid="${entry#/proc/}"; pid="${pid%/cmdline}"
        stat=""
        IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || continue
        IFS=' ' read -r -a fields <<< "${stat##*) }"
        [[ -z "$master" || "${fields[1]:-}" == "$master" ]] || continue
        [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
        printf '%s %s\n' "$pid" "${fields[19]}" >> "$target" || return 1
    done
    chmod 0600 "$target"
}

# nginx's reload command acknowledges a signal, not the completed reload.
# A replacement worker cohort exists once the previous accepting workers have
# exited or entered graceful shutdown. Do not wait for their requests to finish.
sd_wait_nginx_workers_reloaded() {
    local snapshot="$1" timeout="${2:-15}" accepting="${3:-false}" master="${4:-}" deadline pid started stat title waiting entry
    local -a fields
    [[ -f "$snapshot" ]] || return 1
    deadline=$((SECONDS + timeout))
    while true; do
        waiting=false
        while IFS=' ' read -r pid started; do
            [[ "$pid" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || return 1
            stat=""
            IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || continue
            IFS=' ' read -r -a fields <<< "${stat##*) }"
            [[ "${fields[19]:-}" == "$started" && "${fields[0]:-}" != Z ]] || continue
            title=""
            IFS= read -r -d '' title 2>/dev/null < "/proc/$pid/cmdline" || true
            if [[ "$title" == 'nginx: worker process'* && "$title" != 'nginx: worker process is shutting down'* ]]; then
                waiting=true; break
            fi
        done < "$snapshot"
        if [[ "$waiting" == false ]]; then
            [[ "$accepting" == true ]] || return 0
            # On a first start there may be no previous workers. Confirm a
            # worker exists before allowing another configuration switch.
            for entry in /proc/[0-9]*/cmdline; do
                title=""
                IFS= read -r -d '' title 2>/dev/null < "$entry" || true
                if [[ "$title" == 'nginx: worker process'* && "$title" != 'nginx: worker process is shutting down'* ]]; then
                    if [[ -n "$master" ]]; then
                        pid="${entry#/proc/}"; pid="${pid%/cmdline}"
                        stat=""
                        IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || continue
                        IFS=' ' read -r -a fields <<< "${stat##*) }"
                        [[ "${fields[1]:-}" == "$master" ]] || continue
                    fi
                    return 0
                fi
            done
        fi
        (( SECONDS < deadline )) || return 1
        sleep 0.1
    done
}

# Retirement runs independently of the CLI. No timeout can kill an old
# backend while pre-reload nginx workers still depend on it. Disabling its
# units immediately prevents a drained generation from returning on reboot.
sd_retire_after() {
    local unit="$1" snapshot="$2" helper="$GB_LIBEXEC/getbible-runtime-retire" retained
    sd_available || return 0
    [[ "$GB_DRY_RUN" == true ]] && return 0
    [[ -f "$snapshot" ]] || { gb_warn "No nginx worker snapshot; retaining $unit"; return 1; }
    gb_install_file "$GB_TOOLS/getbible-runtime-retire" "$helper" 0755 || return 1
    retained="$GB_STATE/runtime-retire/$unit.workers"
    gb_ensure_dir "$GB_STATE/runtime-retire" 0700 || return 1
    gb_install_file "$snapshot" "$retained" 0600 || return 1
    "$GB_SYSTEMCTL" disable "$unit.socket" "$unit.service" >/dev/null 2>&1 || return 1
    systemd-run --quiet --collect --unit="$unit-retire" \
        --property=Type=oneshot --property=TimeoutStartSec=infinity \
        "$helper" "$GB_SYSTEMCTL" "$unit" "$retained"
}
