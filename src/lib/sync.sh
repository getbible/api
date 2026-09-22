#!/usr/bin/env bash
# Static endpoint synchronisation: one system user per domain, independent
# deploy keys per endpoint and repository, and one timer per endpoint.

[[ -n "${GB_SYNC_LOADED:-}" ]] && return 0
GB_SYNC_LOADED=1

sync_user() { printf 'gb-sync-%s\n' "$(gb_short_slug "$1")"; }
sync_home() { printf '%s/sync/%s\n' "$GB_VAR" "$(sync_user "$1")"; }
sync_unit() { printf 'getbible-sync-%s-%s\n' "$(gb_slug "$1")" "$2"; }
sync_state_file() { printf '%s/state/%s.conf\n' "$(sync_home "$1")" "$2"; }
sync_state_get() { cfg_get "$(sync_state_file "$1" "$2")" "$3" "${4:-}"; }

sync_install_tools() {
    gb_ensure_dir "$GB_LIBEXEC" 0755 || return 1
    gb_install_file "$GB_TOOLS/getbible-sync" "$GB_LIBEXEC/getbible-sync" 0755 || return 1
    gb_install_file "$GB_TOOLS/getbible-export-tree" "$GB_LIBEXEC/getbible-export-tree" 0755 || return 1
    gb_install_file "$GB_TOOLS/getbible-notify" "$GB_LIBEXEC/getbible-notify" 0755
}

# Create the domain's shared sync user, home and data directory. Credentials
# belong to endpoints; never generate a new domain-wide deploy key here.
sync_setup_domain() {
    local domain="$1" user home data
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    data="$(ep_data_dir "$domain")"
    gb_ensure_base_groups || return 1
    gb_ensure_dir "$GB_VAR/sync" 0755 || return 1
    gb_ensure_system_user "$user" "$GB_READERS_GROUP" "$home" "$GB_NOTIFY_GROUP" || return 1
    gb_ensure_dir "$home" 0750 "$user:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$home/.ssh" 0700 "$user:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$home/repos" 0750 "$user:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$home/state" 0750 "$user:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$data" 0750 "$user:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$data/releases" 0750 "$user:$GB_READERS_GROUP" || return 1
    [[ "$GB_DRY_RUN" != true ]] || return 0
    [[ -f "$home/.ssh/known_hosts" ]] || { : > "$home/.ssh/known_hosts" && chmod 0644 "$home/.ssh/known_hosts"; } || return 1
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$user:$GB_READERS_GROUP" "$home/.ssh/known_hosts" || return 1
    fi
    ep_set "$domain" SYNC_USER "$user"
}

# Repository changes need another key too: GitHub binds a deploy key to one
# repository. Keep previous keys so switching back is stable and reversible.
sync_endpoint_key() {
    local digest
    digest="$(printf '%s' "$(ep_version_get "$1" "$2" REPO_URL)" | sha256sum | cut -d' ' -f1)"
    printf '%s/.ssh/keys/%s/%s/id_ed25519\n' "$(sync_home "$1")" "$2" "$digest"
}

sync_key_file() { sync_endpoint_key "$1" "$2"; }

sync_setup_version() {
    local domain="$1" label="$2" user home key dir
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    key="$(sync_endpoint_key "$domain" "$label")"
    for dir in "$home/.ssh/keys" "$home/.ssh/keys/$label" "${key%/*}"; do
        gb_ensure_dir "$dir" 0700 "$user:$GB_READERS_GROUP" || return 1
    done
    [[ "$GB_DRY_RUN" != true ]] || return 0
    gb_have ssh-keygen || { gb_warn "ssh-keygen is required to prepare the deploy key for $domain $label"; return 1; }
    if [[ ! -f "$key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key" -C "getbible-sync $domain $label" || return 1
        gb_log "Generated endpoint deploy key for $domain $label"
        tg_notify info "Deploy key prepared: $domain $label" "Register this endpoint's public key as read-only on $(ep_version_get "$domain" "$label" REPO_URL)." || true
    fi
    # Recover the public half if it was removed; never replace the identity.
    [[ -f "$key.pub" ]] || ssh-keygen -y -f "$key" > "$key.pub" || return 1
    chmod 0600 "$key" || return 1
    chmod 0644 "$key.pub" || return 1
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$user:$GB_READERS_GROUP" "$key" "$key.pub" || return 1
    fi
}

sync_public_key() {
    local file
    file="$(sync_endpoint_key "$1" "$2").pub"
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
    local domain="$1" url="$2" host port known lookup
    host="$(sync_repo_host "$url")"
    [[ -n "$host" ]] || return 0
    [[ "$url" == https://* ]] && return 0
    port="$(sync_repo_port "$url")"
    known="$(sync_home "$domain")/.ssh/known_hosts"
    lookup="$host"
    [[ "$port" == 22 ]] || lookup="[$host]:$port"
    if ssh-keygen -F "$lookup" -f "$known" >/dev/null 2>&1; then
        return 0
    fi
    [[ "$GB_DRY_RUN" == true || -n "$GB_PREFIX" ]] && return 0
    gb_have ssh-keyscan || { gb_warn "ssh-keyscan missing; cannot pin $host"; return 0; }
    gb_step "Pinning the SSH host key of $host"
    ssh-keyscan -p "$port" -t ed25519,rsa "$host" 2>/dev/null >> "$known" || gb_warn "Could not fetch the host key of $host; the first sync will fail until known_hosts is populated."
    gb_log "Host key fingerprints for $host:"
    ssh-keygen -l -f "$known" 2>/dev/null | grep -F "$host" || true
}

# Render only: upgrade planning reuses the exact installation templates.
sync_render_version() {
    local domain="$1" label="$2" directory="$3" schedule unit user home stage_service stage_timer extras
    ep_load "$domain"
    ep_version_load "$domain" "$label"
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    unit="$(sync_unit "$domain" "$label")"
    schedule="${EP_SYNC_SCHEDULE:-$(gb_global DEFAULT_SYNC_SCHEDULE weekly)}"
    stage_service="$directory/$unit.service"
    stage_timer="$directory/$unit.timer"
    # A page or OpenAPI document that comes from the repository is exported
    # by path, whatever file types the endpoint otherwise serves.
    extras=""
    [[ "${EV_DOCS_SOURCE:-generated}" != repository ]] || extras="${EV_DOCS_REPO_PATH:-index.html}"
    if [[ "${EV_OPENAPI_SOURCE:-$(type_static_openapi_default)}" == repository ]]; then
        extras="${extras:+$extras,}${EV_OPENAPI_REPO_PATH:-openapi.json}"
    fi
    gb_render "$GB_TYPES/static/templates/sync.service.tmpl" "$stage_service" \
        "DOMAIN=$domain" "LABEL=$label" "REPO_URL=$EV_REPO_URL" "REPO_REF=$EV_REPO_REF" \
        "SOURCE_PATH=$EV_SOURCE_PATH" "EXTENSIONS=$EP_EXTENSIONS" "EXTRA_FILES=$extras" "USER=$user" \
        "GROUP=$GB_READERS_GROUP" "HOME=$home" "KEY_FILE=$(sync_key_file "$domain" "$label")" "DATA_DIR=$(ep_data_dir "$domain")" \
        "STORAGE_MAX_GIB=$(gb_global STORAGE_MAX_GIB 0)" "STORAGE_STATE=$GB_VAR/storage" \
        "LIBEXEC=$GB_LIBEXEC" "RUN=$GB_RUN" "TELEGRAM_CONF=$GB_TELEGRAM_CONF" "GETBIBLE=${GB_SELF:-$GB_REPO_DIR/getbible.sh}" || return 1
    gb_render "$GB_TYPES/static/templates/sync.timer.tmpl" "$stage_timer" \
        "DOMAIN=$domain" "LABEL=$label" "REPO_URL=$EV_REPO_URL" "SCHEDULE=$schedule" || return 1
}

# Render and enable the service + timer for one version.
sync_install_version() {
    local domain="$1" label="$2" unit stage_service stage_timer
    unit="$(sync_unit "$domain" "$label")"
    stage_service="$(gb_tmpdir)/$unit.service"
    stage_timer="$(gb_tmpdir)/$unit.timer"
    sync_render_version "$domain" "$label" "$(gb_tmpdir)" || return 1
    sd_install_unit "$stage_service" "$unit.service" || return 1
    sd_install_unit "$stage_timer" "$unit.timer" || return 1
    sd_daemon_reload || return 1
    if [[ "$EV_ENABLED" == true ]]; then
        if [[ "${GB_LOCAL_APPLY:-false}" == true ]]; then
            # Preserve the running schedule during image application. Starting
            # an inactive persistent timer could fetch overdue source data.
            sd_enable "$unit.timer"
        else
            sd_enable --now "$unit.timer"
        fi
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
    local domain="$1" label="$2" unit result=0
    unit="$(sync_unit "$domain" "$label")"
    if sd_available; then
        gb_step "Starting $unit.service"
        "$GB_SYSTEMCTL" start "$unit.service" || result=$?
        sd_journal "$unit.service" 80
        return "$result"
    else
        gb_warn "systemd unavailable; sync not started."
        return 1
    fi
}

sync_force_now() (
    local domain="$1" label="$2" home
    home="$(sync_home "$domain")"
    sd_available || gb_die "systemd is required."
    # Serialize with an existing sync before placing this version's marker.
    # A manager-wide environment flag affects unrelated services and is not
    # inherited by system services without PassEnvironment.
    exec 9<>"$home/lock-$label" || return 1
    # A first forced sync creates this file as root. The service must be able
    # to open it afterwards as the sync user. Repair ownership on the opened
    # inode, without replacing a lock another sync may already hold.
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$(sync_user "$domain"):$GB_READERS_GROUP" /proc/self/fd/9 || return 1
    fi
    chmod 0600 /proc/self/fd/9 || return 1
    flock 9 || return 1
    touch "$home/state/$label.force" || return 1
    flock -u 9
    exec 9>&-
    sync_run_now "$domain" "$label"
)

sync_test_access() {
    # Use the same explicit identity and SSH options as the sync service.
    local domain="$1" label="$2" key url ref user home command refs branch tag
    url="$(ep_version_get "$domain" "$label" REPO_URL)"
    ref="$(ep_version_get "$domain" "$label" REPO_REF)"
    key="$(sync_key_file "$domain" "$label")"
    user="$(sync_user "$domain")"
    home="$(sync_home "$domain")"
    [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]] || { gb_warn "Repository access cannot be verified in dry-run or prefix mode."; return 1; }
    printf -v command 'ssh -F /dev/null -i %q -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes -o BatchMode=yes' "$key" "$home/.ssh/known_hosts"
    # Operators may start the CLI in a private checkout or /root. Git must run
    # from a directory the restricted sync account can traverse.
    refs="$(cd "$home" && runuser -u "$user" -- env HOME="$home" GIT_SSH_COMMAND="$command" GIT_TERMINAL_PROMPT=0 \
        git ls-remote --exit-code "$url" "$ref" "refs/heads/$ref" "refs/tags/$ref")" || return 1
    if [[ "$ref" == refs/heads/* || "$ref" == refs/tags/* || "$ref" == HEAD ]]; then
        refs="$(awk -v ref="$ref" '$2 == ref {print}' <<< "$refs")"
    else
        branch="$(awk -v ref="refs/heads/$ref" '$2 == ref {print}' <<< "$refs")"
        tag="$(awk -v ref="refs/tags/$ref" '$2 == ref {print}' <<< "$refs")"
        [[ -z "$branch" || -z "$tag" ]] || { gb_warn "Branch and tag share $ref; use refs/heads/... or refs/tags/..."; return 1; }
        refs="${branch:-$tag}"
    fi
    [[ -n "$refs" ]] || { gb_warn "Reference $ref not found in $url"; return 1; }
    printf '%s\n' "$refs"
}

sync_status_text() {
    local domain="$1" label="$2" unit next
    unit="$(sync_unit "$domain" "$label")"
    printf 'Endpoint %s of %s\n' "$(pages_label_text "$label")" "$domain"
    printf '  repository : %s (%s)\n' "$(ep_version_get "$domain" "$label" REPO_URL)" "$(ep_version_get "$domain" "$label" REPO_REF)"
    printf '  deploy key : %s\n' "$(sync_key_file "$domain" "$label").pub"
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
