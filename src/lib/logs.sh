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
    local size keep conf stage
    size="$(gb_global LOG_ROTATE_SIZE 1G)"
    keep="$(gb_global LOG_ROTATE_KEEP 30)"
    stage="$(gb_tmpdir)/logrotate.conf"
    cat > "$stage" <<CONF
# getBible API log rotation, rendered by getbible.sh. Run hourly by
# getbible-logrotate.timer with its own state file; the distribution's daily
# logrotate never sees these files.

"$GB_LOG/*/access.log" "$GB_LOG/*/error.log" {
    size $size
    rotate $keep
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
    olddir archive
    createolddir 0755 root root
    create 0640 root adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 "\$(cat /run/nginx.pid)" 2>/dev/null || true
        $GB_LIBEXEC/getbible-logrotate-hook "$GB_LOG" "$keep" || true
    endscript
}

"$GB_LOG/*/app/*.log" {
    size $size
    rotate $keep
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
    olddir ../archive
    sharedscripts
    postrotate
        $GB_LIBEXEC/getbible-logrotate-hook "$GB_LOG" "$keep" || true
    endscript
}
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
ExecStart=/usr/sbin/logrotate -s $GB_VAR/logrotate.state $GB_LOGROTATE_CONF
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
    /usr/sbin/logrotate -f -s "$GB_VAR/logrotate.state" "$GB_LOGROTATE_CONF"
}

# logs_archives DOMAIN: list archived files with sizes.
logs_archives() {
    local dir
    dir="$(ep_log_dir "$1")/archive"
    [[ -d "$dir" ]] || { printf '(no archives)\n'; return 0; }
    find "$dir" -maxdepth 1 -type f -printf '%10s  %TY-%Tm-%Td %TH:%TM  %f\n' | sort -k2,3
}

logs_tail() {
    # logs_tail FILE LINES
    local file="$1" lines="${2:-200}"
    [[ -f "$file" ]] || { printf '(no such log: %s)\n' "$file"; return 0; }
    tail -n "$lines" -- "$file"
}
