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
    stage="$(gb_tmpdir)/logrotate.conf"
    cat > "$stage" <<CONF
# getBible telemetry owns traffic and diagnostic spool rotation.
# Independent logrotate rules would delete unread records. Intentionally empty.
# Retained history is managed by TELEMETRY_MAX_GIB and TELEMETRY_RETENTION_DAYS.
CONF
    gb_install_file "$stage" "$GB_LOGROTATE_CONF" 0644
    gb_install_file "$GB_TOOLS/getbible-logrotate-hook" "$GB_LIBEXEC/getbible-logrotate-hook" 0755

    local unit timer
    unit="$(gb_tmpdir)/getbible-logrotate.service"
    timer="$(gb_tmpdir)/getbible-logrotate.timer"
    cat > "$unit" <<UNIT
[Unit]
Description=getBible API log rotation (size based)
Documentation=file:$GB_REPO_DIR/docs/LOGGING.md

[Service]
Type=oneshot
ExecStart=$GB_PYTHON $GB_LIBEXEC/getbible-telemetry rotate --db $GB_VAR/telemetry/traffic.sqlite3 --log-root $GB_LOG
Nice=10
IOSchedulingClass=idle
UNIT
    cat > "$timer" <<TIMER
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
    sd_install_unit "$unit" getbible-logrotate.service
    sd_install_unit "$timer" getbible-logrotate.timer
    sd_daemon_reload
    sd_enable --now getbible-logrotate.timer
}

logs_rotate_now() {
    sd_available || gb_die "systemd is required to rotate now."
    "$GB_PYTHON" "$GB_LIBEXEC/getbible-telemetry" rotate --db "$GB_VAR/telemetry/traffic.sqlite3" --log-root "$GB_LOG"
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
