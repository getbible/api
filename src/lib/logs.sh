#!/usr/bin/env bash
# Log directories, size-based rotation with an hourly timer, and viewers.

[[ -n "${GB_LOGS_LOADED:-}" ]] && return 0
GB_LOGS_LOADED=1

logs_ensure_endpoint_dir() {
    local domain="$1" dir
    dir="$(ep_log_dir "$domain")"
    gb_ensure_dir "$GB_LOG" 0755
    gb_ensure_dir "$dir" 0755
    gb_ensure_dir "$dir/archive" 0755
}

# Render /etc/getbible/logrotate.conf covering every endpoint, plus the
# hourly timer that runs it with its own state file.
logs_render_rotation() {
    local stage
    stage="$(gb_tmpdir)/logrotate.conf" || return 1
    cat > "$stage" <<CONF || return 1
# getBible telemetry owns traffic and diagnostic spool rotation.
# Independent logrotate rules would delete unread records. Intentionally empty.
# Retained history is managed by TELEMETRY_MAX_GIB and TELEMETRY_RETENTION_DAYS.
CONF
    gb_install_file "$stage" "$GB_LOGROTATE_CONF" 0644 || return 1
    gb_install_file "$GB_TOOLS/getbible-logrotate-hook" "$GB_LIBEXEC/getbible-logrotate-hook" 0755 || return 1

    local unit timer
    unit="$(gb_tmpdir)/getbible-logrotate.service" || return 1
    timer="$(gb_tmpdir)/getbible-logrotate.timer" || return 1
    cat > "$unit" <<UNIT || return 1
[Unit]
Description=getBible API log rotation (size based)
Documentation=file:$GB_REPO_DIR/docs/LOGGING.md

[Service]
Type=oneshot
ExecStart=$GB_PYTHON $GB_LIBEXEC/getbible-telemetry rotate --db $GB_VAR/telemetry/traffic.sqlite3 --log-root $GB_LOG
Nice=10
IOSchedulingClass=idle
UNIT
    cat > "$timer" <<TIMER || return 1
[Unit]
Description=Check getBible API logs for rotation every hour

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    sd_install_unit "$unit" getbible-logrotate.service || return 1
    sd_install_unit "$timer" getbible-logrotate.timer || return 1
    sd_daemon_reload || return 1
    sd_enable --now getbible-logrotate.timer
}

logs_rotate_now() {
    sd_available || gb_die "systemd is required to rotate now."
    "$GB_PYTHON" "$GB_LIBEXEC/getbible-telemetry" rotate --db "$GB_VAR/telemetry/traffic.sqlite3" --log-root "$GB_LOG"
}

# A schema change starts a new canonical history only on an explicit request.
# Stop its readers/writer, retain source cursors, and restore enabled services
# even when a previous collector failed because it needs this reset.
logs_reset_history() {
    [[ "${1:-}" == --discard-history && $# -eq 1 ]] || {
        gb_warn 'Resetting traffic history requires --discard-history.'
        return 1
    }
    if [[ "$GB_DRY_RUN" == true ]]; then
        printf 'Would reset canonical traffic history; raw logs and configuration stay in place.\n'
        return 0
    fi
    local telemetry=false dashboard=false rotation=false timer=false rotation_state status=0
    local helper="$GB_LIBEXEC/getbible-telemetry"
    [[ -x "$helper" ]] || helper="$GB_TOOLS/getbible-telemetry"
    if sd_is_active getbible-telemetry.service || sd_is_enabled getbible-telemetry.service; then telemetry=true; fi
    if sd_is_active getbible-dashboard.service || sd_is_enabled getbible-dashboard.service; then dashboard=true; fi
    if sd_is_active getbible-logrotate.service; then rotation=true; fi
    if sd_is_active getbible-logrotate.timer; then timer=true; fi
    if sd_available; then
        # A Type=oneshot helper remains activating for its entire execution.
        rotation_state="$("$GB_SYSTEMCTL" show getbible-logrotate.service --property=ActiveState --value 2>/dev/null || true)"
        if [[ "$rotation_state" == activating ]]; then rotation=true; fi
        # The timer's helper opens the database too. Stop scheduling before
        # waiting for every writer/reader, then let reset take its lifetime lock.
        "$GB_SYSTEMCTL" stop getbible-logrotate.timer || status=$?
        "$GB_SYSTEMCTL" stop getbible-logrotate.service getbible-telemetry.service getbible-dashboard.service || status=$?
    fi
    if (( status == 0 )); then
        "$GB_PYTHON" "$helper" reset --discard-history \
            --db "$GB_VAR/telemetry/traffic.sqlite3" --log-root "$GB_LOG" || status=$?
    fi
    local unit
    for unit in getbible-telemetry.service getbible-dashboard.service getbible-logrotate.service getbible-logrotate.timer; do
        [[ "$unit" != getbible-telemetry.service || "$telemetry" == true ]] || continue
        [[ "$unit" != getbible-dashboard.service || "$dashboard" == true ]] || continue
        [[ "$unit" != getbible-logrotate.service || "$rotation" == true ]] || continue
        [[ "$unit" != getbible-logrotate.timer || "$timer" == true ]] || continue
        # An earlier-schema collector may already have exhausted its systemd
        # restart allowance. Permit the repaired service to start immediately.
        if sd_available; then "$GB_SYSTEMCTL" reset-failed "$unit" || status=$?; fi
        sd_start "$unit" || status=$?
    done
    if (( status != 0 )); then
        gb_warn 'Traffic history reset or service recovery failed. Check the telemetry and dashboard services.'
        return "$status"
    fi
    tg_notify warn 'Traffic history reset' 'Canonical traffic history starts now. Raw logs, authentication, and configuration were retained.'
}

# logs_archives DOMAIN: list archived files with sizes.
logs_archives() {
    "$GB_PYTHON" "$GB_LIBEXEC/getbible-telemetry" storage --db "$GB_VAR/telemetry/traffic.sqlite3"
}

logs_tail() {
    # logs_tail FILE LINES
    local file="$1" lines="${2:-200}" relative domain action=requests
    relative="${file#"$GB_LOG/"}"
    domain="${relative%%/*}"
    [[ "$file" == */error.log ]] && action=events
    "$GB_PYTHON" "$GB_LIBEXEC/getbible-telemetry" "$action" --db "$GB_VAR/telemetry/traffic.sqlite3" \
        --endpoint "$domain" --from 0 --limit "$lines"
}
