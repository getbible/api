#!/usr/bin/env bash
# Optional, version-independent MCP service attached to an existing domain.
[[ -n "${GB_MCP_LOADED:-}" ]] && return 0
GB_MCP_LOADED=1

mcp_enabled() { [[ "$(ep_get "$1" MCP_ENABLED false)" == true ]]; }
mcp_default_origin() {
    if nginx_external_tls; then printf 'http://127.0.0.1:%s\n' "$(nginx_origin_http_port)"
    else printf 'https://127.0.0.1:443\n'; fi
}
mcp_root() { printf '%s/mcp/%s\n' "$GB_OPT" "$(gb_slug "$1")"; }
mcp_id() { printf '%s' "$1" | sha256sum | cut -c1-16; }
mcp_active() {
    local link
    link="$(mcp_root "$1")/active"
    [[ -L "$link" && -d "$link" ]] || return 0
    readlink -f -- "$link"
}
mcp_unit() { printf 'getbible-mcp-%s-%s\n' "$(mcp_id "$1")" "$(basename -- "$2")"; }
mcp_socket() { cat "$1/.socket"; }
mcp_proxy_socket() {
    if [[ "$GB_DRY_RUN" == true ]]; then printf '%s/mcp/%s/preview/http.sock\n' "$GB_RUN" "$(mcp_id "$1")"; return; fi
    if [[ "${MCP_DOMAIN:-}" == "$1" && -n "${MCP_CANDIDATE:-}" ]]; then
        mcp_socket "$MCP_CANDIDATE"
    else
        mcp_socket "$(mcp_active "$1")"
    fi
}

mcp_validate() {
    local domain="$1" origin file
    ep_exists "$domain" || { gb_warn "Unknown domain: $domain"; return 1; }
    origin="$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")"
    [[ "$origin" =~ ^https?://(localhost|127\.[0-9.]+|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|\[::1\])(:[0-9]{1,5})?$ ]] \
        || { gb_warn 'MCP_ORIGIN must identify the local/private nginx origin without a path.'; return 1; }
    file="$(ep_get "$domain" MCP_ENV_FILE)"
    [[ -z "$file" || ( "$file" == /* && "$file" != *[[:space:]]* && "$file" != *'%'* && -f "$file" ) ]] \
        || { gb_warn 'MCP_ENV_FILE must be an existing absolute file path without whitespace or %.'; return 1; }
}

mcp_prepare() {
    local domain="$1" root release python inputs generation socket target
    MCP_DOMAIN="$domain"; MCP_CANDIDATE=""; MCP_SWITCHED=false; MCP_COMMITTED=false
    MCP_ABORT_SNAPSHOT=""; MCP_SNAPSHOT=""; MCP_BACKUP=""
    MCP_OLD="$(mcp_active "$domain")"
    root="$(mcp_root "$domain")"
    if [[ -n "$MCP_OLD" && "$GB_DRY_RUN" != true ]]; then
        MCP_BACKUP="$(mktemp -d "$(gb_tmpdir)/mcp-state.XXXXXXXX")" || return 1
        for target in active previous current; do gb_backup_file "$root/$target" "$MCP_BACKUP" || return 1; done
    fi
    mcp_enabled "$domain" || return 0
    mcp_validate "$domain" || return 1
    python="$(py_resolve_version "$(ep_get "$domain" MCP_PYTHON_VERSION auto)")" || return 1
    inputs="$(py_inputs_hash mcp "$python")" || return 1
    release="$(py_current_release "$root")"
    if [[ -n "${MCP_ROLLBACK:-}" ]]; then
        release="$(cat "$MCP_ROLLBACK/.release")" || return 1
        [[ -x "$release/.venv/bin/python" ]] || { gb_warn 'The retained MCP release is unavailable.'; return 1; }
    elif [[ ! -x "$release/.venv/bin/python" || "$(py_release_inputs "$release")" != "$inputs" ]]; then
        release="$(py_build_release "$root" "$domain MCP" "$python" mcp)" || return 1
    fi
    [[ "$GB_DRY_RUN" != true ]] || { gb_log "Would prepare MCP at https://$domain/mcp"; return 0; }
    gb_ensure_base_groups || return 1
    gb_ensure_system_user getbible-mcp getbible-mcp /nonexistent || return 1
    gb_ensure_dir "$root/deployments" 0755 || return 1
    generation="$(mktemp -d "$root/deployments/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")" || return 1
    MCP_CANDIDATE="$generation"
    chmod 0755 "$generation" || return 1
    printf '%s\n' "$release" > "$generation/.release" || return 1
    socket="$GB_RUN/mcp/$(mcp_id "$domain")/$(basename "$generation")/http.sock"
    printf '%s\n' "$socket" > "$generation/.socket" || return 1
    printf '%s\n' "$(mcp_unit "$domain" "$generation")" > "$generation/.unit" || return 1
    if [[ -z "$MCP_BACKUP" ]]; then
        MCP_BACKUP="$(mktemp -d "$(gb_tmpdir)/mcp-state.XXXXXXXX")" || return 1
        for target in active previous current; do gb_backup_file "$root/$target" "$MCP_BACKUP" || return 1; done
    fi
    mcp_render_generation "$domain" "$generation" "$release" || return 1
    mcp_install_units "$domain" "$generation" || return 1
    sd_start "$(mcp_unit "$domain" "$generation").socket" || return 1
    sd_start "$(mcp_unit "$domain" "$generation").service" || return 1
    if sd_available && ! sd_wait_ready "$socket" /readyz 60; then
        gb_warn 'MCP candidate readiness failed; the serving generation is unchanged.'
        return 1
    fi
}

mcp_render_generation() {
    local domain="$1" generation="$2" release="$3" origin extra
    origin="$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")"
    extra="$(ep_get "$domain" MCP_ENV_FILE)"
    gb_render "$GB_SRC/systemd/getbible-mcp.service.tmpl" "$generation/service.unit" \
        "DOMAIN=$domain" "UNIT=$(mcp_unit "$domain" "$generation")" "RELEASE=$release" \
        "GENERATION=$generation" "ORIGIN=$origin" "EXTRA_ENV=$extra" || return 1
    gb_render "$GB_TYPES/runtime/templates/socket.tmpl" "$generation/socket.unit" \
        "KIND=MCP" "DOMAIN=$domain" "LABEL=mcp" "SOCKET=$(mcp_socket "$generation")" \
        "USER=getbible-mcp" "NGINX_USER=$GB_NGINX_USER" || return 1
    gb_render "$GB_SRC/apps/mcp/gunicorn.conf.py.tmpl" "$generation/gunicorn.conf.py" \
        "SOCKET=$(mcp_socket "$generation")" || return 1
    chmod 0644 "$generation/"*.unit "$generation/gunicorn.conf.py"
}

mcp_install_units() {
    local domain="$1" generation="$2" unit
    unit="$(mcp_unit "$domain" "$generation")"
    sd_install_unit "$generation/socket.unit" "$unit.socket" || return 1
    sd_install_unit "$generation/service.unit" "$unit.service" || return 1
    sd_daemon_reload
}

mcp_before_switch() {
    local domain="$1" master
    [[ "${MCP_DOMAIN:-}" == "$domain" && "$GB_DRY_RUN" != true ]] || return 0
    [[ -n "${MCP_CANDIDATE:-}${MCP_OLD:-}" ]] || return 0
    MCP_SNAPSHOT="$(gb_tmpdir)/mcp-nginx-workers-$(gb_slug "$domain")"
    master="$(nginx_master_pid)" || master=0
    sd_snapshot_nginx_workers "$MCP_SNAPSHOT" "$master" || return 1
    if [[ -n "$MCP_CANDIDATE" ]]; then
        sd_enable "$(mcp_unit "$domain" "$MCP_CANDIDATE").socket" "$(mcp_unit "$domain" "$MCP_CANDIDATE").service" || return 1
    fi
    MCP_SWITCHED=true
}

mcp_commit() {
    local domain="$1" root
    [[ "${MCP_DOMAIN:-}" == "$domain" && "$GB_DRY_RUN" != true ]] || return 0
    root="$(mcp_root "$domain")"
    if [[ -n "${MCP_CANDIDATE:-}" ]]; then
        MCP_COMMITTED=true
        [[ -z "$MCP_OLD" ]] || gb_switch_link "$MCP_OLD" "$root/previous" || return 1
        py_switch_release "$root" "$(cat "$MCP_CANDIDATE/.release")" || return 1
        gb_switch_link "$MCP_CANDIDATE" "$root/active" || return 1
    elif ! mcp_enabled "$domain"; then
        MCP_COMMITTED=true
        [[ -z "$MCP_OLD" ]] || gb_switch_link "$MCP_OLD" "$root/previous" || return 1
        rm -f -- "$root/active" || return 1
    fi
    return 0
}

mcp_finish() {
    local domain="$1"
    [[ "${MCP_DOMAIN:-}" == "$domain" && "$GB_DRY_RUN" != true ]] || return 0
    if [[ -n "$MCP_OLD" && -n "${MCP_SNAPSHOT:-}" ]]; then
        sd_retire_after "$(mcp_unit "$domain" "$MCP_OLD")" "$MCP_SNAPSHOT" \
            || gb_warn 'The previous MCP generation remains available while nginx drains.'
    fi
    if [[ -n "$MCP_CANDIDATE" ]]; then
        tg_notify ok "MCP ready: $domain" "All supported APIs are available at https://$domain/mcp."
    fi
    mcp_reap_unselected "$domain"
    MCP_CANDIDATE=""
    return 0
}

mcp_before_abort() {
    local domain="$1" master
    [[ "${MCP_DOMAIN:-}" == "$domain" && "${MCP_SWITCHED:-false}" == true ]] || return 0
    sd_wait_nginx_workers_reloaded "$MCP_SNAPSHOT" || return 0
    master="$(nginx_master_pid)" || return 0
    MCP_ABORT_SNAPSHOT="$(gb_tmpdir)/mcp-abort-workers-$(gb_slug "$domain")"
    sd_snapshot_nginx_workers "$MCP_ABORT_SNAPSHOT" "$master" || MCP_ABORT_SNAPSHOT=""
}

mcp_abort() {
    local domain="$1" target unit
    [[ "${MCP_DOMAIN:-}" == "$domain" ]] || return 0
    if [[ "${MCP_COMMITTED:-false}" == true && -n "${MCP_BACKUP:-}" ]]; then
        for target in active previous current; do gb_restore_file "$(mcp_root "$domain")/$target" "$MCP_BACKUP" || return 1; done
    fi
    [[ -n "${MCP_CANDIDATE:-}" ]] || return 0
    unit="$(mcp_unit "$domain" "$MCP_CANDIDATE")"
    if [[ "${MCP_SWITCHED:-false}" == true ]]; then
        if [[ -z "${MCP_ABORT_SNAPSHOT:-}" ]] || ! sd_retire_after "$unit" "$MCP_ABORT_SNAPSHOT"; then
            gb_warn "Retaining $unit until nginx can drain; a later successful apply retries retirement."
        fi
    else
        sd_remove_unit "$unit.service" || return 1
        sd_remove_unit "$unit.socket" || return 1
    fi
}

mcp_reap_unselected() {
    local domain="$1" generation active unit
    [[ -n "${MCP_SNAPSHOT:-}" && -f "$MCP_SNAPSHOT" ]] || return 0
    active="$(mcp_active "$domain")"
    while IFS= read -r generation; do
        [[ "$generation" != "$active" ]] || continue
        unit="$(mcp_unit "$domain" "$generation")"
        if sd_is_active "$unit.service" || sd_is_enabled "$unit.service"; then
            sd_retire_after "$unit" "$MCP_SNAPSHOT" || gb_warn "Retaining unselected $unit while nginx drains."
        fi
    done < <(find "$(mcp_root "$domain")/deployments" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    return 0
}

mcp_render_location() {
    local domain="$1" output="$2"
    mcp_enabled "$domain" || return 0
    gb_render "$GB_NGINX_SRC/mcp.conf.tmpl" "$output" "DOMAIN=$domain" \
        "NGINX_GB_DIR=$GB_NGINX_GB" "SOCKET=$(mcp_proxy_socket "$domain")"
}

mcp_restore() {
    local domain generation
    while IFS= read -r domain; do
        mcp_enabled "$domain" || continue
        generation="$(mcp_active "$domain")"
        [[ -n "$generation" ]] || continue
        gb_ensure_system_user getbible-mcp getbible-mcp /nonexistent || return 1
        mcp_install_units "$domain" "$generation" || return 1
        sd_enable "$(mcp_unit "$domain" "$generation").socket" "$(mcp_unit "$domain" "$generation").service" || return 1
    done < <(ep_list)
}

mcp_remove() {
    local domain="$1" purge="${2:-false}" generation unit root
    root="$(mcp_root "$domain")"
    [[ -d "$root/deployments" ]] || return 0
    while IFS= read -r generation; do
        unit="$(mcp_unit "$domain" "$generation")"
        sd_remove_unit "$unit.service" || return 1
        sd_remove_unit "$unit.socket" || return 1
    done < <(find "$root/deployments" -mindepth 1 -maxdepth 1 -type d)
    rm -f -- "$root/active" || return 1
    [[ "$purge" != true ]] || rm -rf -- "$root"
    sd_daemon_reload
}

mcp_status() {
    local domain="$1" generation
    generation="$(mcp_active "$domain")"
    printf 'Domain: %s\nMCP enabled: %s\nEndpoint: https://%s/mcp\n' "$domain" "$(ep_get "$domain" MCP_ENABLED false)" "$domain"
    printf 'Origin: %s\nEnvironment file: %s\n' "$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")" "$(ep_get "$domain" MCP_ENV_FILE '(library defaults)')"
    if [[ -n "$generation" ]]; then
        printf 'Generation: %s\nService: %s\n' "$(basename "$generation")" "$(sd_status_line "$(mcp_unit "$domain" "$generation").service")"
    fi
}

mcp_cli() {
    local action="${1:-status}" domain="${2:-}" key value backup old_enabled
    local -a keys=() values=()
    [[ -n "$domain" ]] || { gb_warn 'Usage: getbible mcp status|enable|update|disable|rollback DOMAIN [--python VERSION] [--origin URL] [--env-file FILE]'; return 1; }
    ep_exists "$domain" || { gb_warn "Unknown domain: $domain"; return 1; }
    shift 2
    if [[ "$action" == status ]]; then mcp_status "$domain"; return; fi
    case "$action" in enable|update|disable|rollback) ;; *) gb_warn "Unknown MCP action: $action"; return 1 ;; esac
    old_enabled="$(ep_get "$domain" MCP_ENABLED false)"
    while (( $# )); do
        [[ $# -ge 2 ]] || return 1
        case "$1" in --python) key=MCP_PYTHON_VERSION; value="$(py_resolve_version "$2")" || return 1 ;;
            --origin) key=MCP_ORIGIN; value="$2" ;; --env-file) key=MCP_ENV_FILE; value="$2" ;;
            *) gb_warn "Unknown MCP setting: $1"; return 1 ;; esac
        keys+=("$key"); values+=("$value")
        shift 2
    done
    if [[ "$action" != enable && "$action" != disable && "$old_enabled" != true ]]; then
        gb_warn 'Enable MCP before updating it.'; return 1
    fi
    local MCP_ROLLBACK=""
    if [[ "$action" == rollback ]]; then
        MCP_ROLLBACK="$(readlink -f -- "$(mcp_root "$domain")/previous" 2>/dev/null)" || return 1
        [[ -d "$MCP_ROLLBACK" ]] || { gb_warn 'No retained MCP generation exists.'; return 1; }
    fi
    backup="$(gb_new_backup_set "mcp-config-$(gb_slug "$domain")")" || return 1
    gb_backup_file "$(ep_conf "$domain")" "$backup" || return 1
    for key in "${!keys[@]}"; do
        if ! ep_set "$domain" "${keys[$key]}" "${values[$key]}"; then
            gb_restore_file "$(ep_conf "$domain")" "$backup" || return 1
            return 1
        fi
    done
    if [[ "$action" == disable ]]; then value=false; else value=true; fi
    if ! ep_set "$domain" MCP_ENABLED "$value"; then
        gb_restore_file "$(ep_conf "$domain")" "$backup" || return 1
        return 1
    fi
    if ! endpoint_apply "$domain"; then
        gb_restore_file "$(ep_conf "$domain")" "$backup" || return 1
        return 1
    fi
    tg_notify ok "MCP $action: $domain" "The managed MCP endpoint configuration was applied."
}

mcp_menu() {
    local domain action python origin file
    domain="$(menu_pick_domain)" || return 0
    action="$(ui_menu 'MCP endpoint' "One /mcp endpoint on $domain covers every supported API version." \
        status 'Status' enable 'Enable or configure' update 'Update installed package' disable 'Disable' rollback 'Restore previous release')" || return 0
    if [[ "$action" == enable ]]; then
        python="$(ui_input 'MCP Python' 'Managed Python selection' "$(ep_get "$domain" MCP_PYTHON_VERSION auto)")" || return 0
        origin="$(ui_input 'MCP local origin' 'Local nginx origin; HTTPS preserves the upstream TLS hostname' "$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")")" || return 0
        file="$(ui_input 'MCP configuration' 'Optional absolute environment file for custom upstream domains' "$(ep_get "$domain" MCP_ENV_FILE)")" || return 0
        ui_run "MCP $action" mcp_cli "$action" "$domain" --python "$python" --origin "$origin" --env-file "$file"
    else
        ui_run "MCP $action" mcp_cli "$action" "$domain"
    fi
}
