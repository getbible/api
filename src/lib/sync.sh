#!/usr/bin/env bash
# Static endpoint synchronisation: one isolated system user per domain with
# its own deploy key, one timer per version, releases under /srv/getbible.

[[ -n "${GB_SYNC_LOADED:-}" ]] && return 0
GB_SYNC_LOADED=1

sync_user() { printf 'gb-sync-%s\n' "$(gb_short_slug "$1")"; }
sync_home() { printf '%s/sync/%s\n' "$GB_VAR" "$(sync_user "$1")"; }
sync_unit() { printf 'getbible-sync-%s-%s\n' "$(gb_slug "$1")" "$2"; }
sync_state_file() { printf '%s/state/%s.conf\n' "$(sync_home "$1")" "$2"; }
sync_state_get() { cfg_get "$(sync_state_file "$1" "$2")" "$3" "${4:-}"; }

sync_install_tools() {
    gb_ensure_dir "$GB_LIBEXEC" 0755
    gb_install_file "$GB_TOOLS/getbible-sync" "$GB_LIBEXEC/getbible-sync" 0755
    gb_install_file "$GB_TOOLS/getbible-verify-tree" "$GB_LIBEXEC/getbible-verify-tree" 0755
    gb_install_file "$GB_TOOLS/getbible-notify" "$GB_LIBEXEC/getbible-notify" 0755
}

# Create the sync user, its home, its deploy key and the data directory.
sync_setup_domain() {
    local domain="$1" user home data
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    data="$(ep_data_dir "$domain")"
    gb_ensure_base_groups
    gb_ensure_dir "$GB_VAR/sync" 0755
    gb_ensure_system_user "$user" "$GB_READERS_GROUP" "$home" "$GB_NOTIFY_GROUP"
    gb_ensure_dir "$home" 0750 "$user:$GB_READERS_GROUP"
    gb_ensure_dir "$home/.ssh" 0700 "$user:$GB_READERS_GROUP"
    gb_ensure_dir "$home/repos" 0750 "$user:$GB_READERS_GROUP"
    gb_ensure_dir "$home/state" 0750 "$user:$GB_READERS_GROUP"
    gb_ensure_dir "$data" 0750 "$user:$GB_READERS_GROUP"
    gb_ensure_dir "$data/releases" 0750 "$user:$GB_READERS_GROUP"
    if [[ ! -f "$home/.ssh/id_ed25519" && "$GB_DRY_RUN" != true ]] && gb_have ssh-keygen; then
        ssh-keygen -q -t ed25519 -N '' -f "$home/.ssh/id_ed25519" -C "getbible-sync $domain@$(hostname -f 2>/dev/null || hostname)"
        if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
            chown "$user:$GB_READERS_GROUP" "$home/.ssh/id_ed25519" "$home/.ssh/id_ed25519.pub"
        fi
        chmod 0600 "$home/.ssh/id_ed25519"
        gb_log "Generated deploy key for $domain"
    fi
    gb_have ssh-keygen || gb_warn "ssh-keygen is missing; no deploy key was generated for $domain (install openssh-client and re-apply)."
    [[ -f "$home/.ssh/known_hosts" ]] || { : > "$home/.ssh/known_hosts"; chmod 0644 "$home/.ssh/known_hosts"; }
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$user:$GB_READERS_GROUP" "$home/.ssh/known_hosts"
    fi
    ep_set "$domain" SYNC_USER "$user"
}

sync_public_key() {
    local file
    file="$(sync_home "$1")/.ssh/id_ed25519.pub"
    [[ -f "$file" ]] && cat "$file" || printf '(no key yet)\n'
}

# Host part of a git URL for known_hosts pinning.
sync_repo_host() {
    local url="$1" host
    case "$url" in
        ssh://*) host="${url#ssh://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}" ;;
        *@*:*) host="${url#*@}"; host="${host%%:*}" ;;
        https://*) host="${url#https://}"; host="${host%%/*}" ;;
        *) host="" ;;
    esac
    printf '%s\n' "$host"
}

sync_repo_port() {
    local url="$1" hostport
    case "$url" in
        ssh://*) hostport="${url#ssh://}"; hostport="${hostport%%/*}"; hostport="${hostport##*@}"
                 [[ "$hostport" == *:* ]] && printf '%s\n' "${hostport##*:}" || printf '22\n' ;;
        *) printf '22\n' ;;
    esac
}

# Pin the repository host key so the sync user never answers a prompt.
sync_pin_host() {
    local domain="$1" url="$2" host port known
    host="$(sync_repo_host "$url")"
    [[ -n "$host" ]] || return 0
    [[ "$url" == https://* ]] && return 0
    port="$(sync_repo_port "$url")"
    known="$(sync_home "$domain")/.ssh/known_hosts"
    if grep -q "^\(\[$host\]:$port\|$host\) " "$known" 2>/dev/null; then
        return 0
    fi
    [[ "$GB_DRY_RUN" == true || -n "$GB_PREFIX" ]] && return 0
    gb_have ssh-keyscan || { gb_warn "ssh-keyscan missing; cannot pin $host"; return 0; }
    gb_step "Pinning the SSH host key of $host"
    ssh-keyscan -p "$port" -t ed25519,rsa "$host" 2>/dev/null >> "$known" || gb_warn "Could not fetch the host key of $host; the first sync will fail until known_hosts is populated."
    gb_log "Host key fingerprints for $host:"
    ssh-keygen -l -f "$known" 2>/dev/null | grep -F "$host" || true
}

# Render and enable the service + timer for one version.
sync_install_version() {
    local domain="$1" label="$2" schedule unit user home stage_service stage_timer
    ep_load "$domain"
    ep_version_load "$domain" "$label"
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    unit="$(sync_unit "$domain" "$label")"
    schedule="${EP_SYNC_SCHEDULE:-$(gb_global DEFAULT_SYNC_SCHEDULE weekly)}"
    stage_service="$(gb_tmpdir)/$unit.service"
    stage_timer="$(gb_tmpdir)/$unit.timer"
    gb_render "$GB_TYPES/static/templates/sync.service.tmpl" "$stage_service" \
        "DOMAIN=$domain" "LABEL=$label" "REPO_URL=$EV_REPO_URL" "REPO_REF=$EV_REPO_REF" \
        "SOURCE_PATH=$EV_SOURCE_PATH" "EXTENSIONS=$EP_EXTENSIONS" "USER=$user" \
        "GROUP=$GB_READERS_GROUP" "HOME=$home" "DATA_DIR=$(ep_data_dir "$domain")" \
        "LIBEXEC=$GB_LIBEXEC" "TELEGRAM_CONF=$GB_TELEGRAM_CONF"
    gb_render "$GB_TYPES/static/templates/sync.timer.tmpl" "$stage_timer" \
        "DOMAIN=$domain" "LABEL=$label" "REPO_URL=$EV_REPO_URL" "SCHEDULE=$schedule"
    sd_install_unit "$stage_service" "$unit.service"
    sd_install_unit "$stage_timer" "$unit.timer"
    sd_daemon_reload
    if [[ "$EV_ENABLED" == true ]]; then
        sd_enable --now "$unit.timer"
    else
        sd_disable_now "$unit.timer"
    fi
}

sync_remove_version() {
    local domain="$1" label="$2" unit
    unit="$(sync_unit "$domain" "$label")"
    sd_remove_unit "$unit.timer"
    sd_remove_unit "$unit.service"
    sd_daemon_reload
}

# Run the sync for one version right now, in the foreground, as the sync user.
sync_run_now() {
    local domain="$1" label="$2" unit
    unit="$(sync_unit "$domain" "$label")"
    if sd_available; then
        gb_step "Starting $unit.service"
        "$GB_SYSTEMCTL" start "$unit.service" || true
        sd_journal "$unit.service" 80
    else
        gb_warn "systemd unavailable; sync not started."
    fi
}

sync_force_now() {
    local domain="$1" label="$2" unit
    unit="$(sync_unit "$domain" "$label")"
    sd_available || gb_die "systemd is required."
    "$GB_SYSTEMCTL" set-environment GB_SYNC_FORCE=1 >/dev/null 2>&1 || true
    "$GB_SYSTEMCTL" start "$unit.service" || true
    "$GB_SYSTEMCTL" unset-environment GB_SYNC_FORCE >/dev/null 2>&1 || true
    sd_journal "$unit.service" 80
}

sync_test_access() {
    # Can the sync user reach the repository? Prints the head commit or an error.
    local domain="$1" url="$2" ref="$3" user home
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]] || { printf 'skipped\n'; return 0; }
    runuser -u "$user" -- env HOME="$home" \
        GIT_SSH_COMMAND="ssh -i $home/.ssh/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=$home/.ssh/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes" \
        GIT_TERMINAL_PROMPT=0 git ls-remote "$url" "$ref" 2>&1 | head -3
}

sync_status_text() {
    local domain="$1" label="$2" unit next
    unit="$(sync_unit "$domain" "$label")"
    printf 'Version %s of %s\n' "$label" "$domain"
    printf '  repository : %s (%s)\n' "$(ep_version_get "$domain" "$label" REPO_URL)" "$(ep_version_get "$domain" "$label" REPO_REF)"
    printf '  source path: %s\n' "$(ep_version_get "$domain" "$label" SOURCE_PATH)"
    printf '  live path  : %s\n' "$(ep_version_path "$domain" "$label")"
    printf '  last sync  : %s\n' "$(sync_state_get "$domain" "$label" LAST_SYNC never)"
    printf '  last check : %s\n' "$(sync_state_get "$domain" "$label" LAST_CHECK never)"
    printf '  commit     : %s\n' "$(sync_state_get "$domain" "$label" LAST_SHA -)"
    printf '  files      : %s (changed last time: %s)\n' "$(sync_state_get "$domain" "$label" FILES -)" "$(sync_state_get "$domain" "$label" CHANGED -)"
    printf '  timer      : %s\n' "$(sd_status_line "$unit.timer")"
    if sd_available; then
        next="$("$GB_SYSTEMCTL" list-timers --all --no-legend "$unit.timer" 2>/dev/null | awk '{print $1" "$2" "$3}' | head -1)"
        printf '  next run   : %s\n' "${next:-unknown}"
    fi
}
