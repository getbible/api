#!/usr/bin/env bash
# Dedicated MCP domain: one unversioned transport at the domain root.
[[ -n "${GB_MCP_LOADED:-}" ]] && return 0
GB_MCP_LOADED=1
# shellcheck source=transactions.sh
source "${GB_LIB:-$(dirname -- "${BASH_SOURCE[0]}")}/transactions.sh"

mcp_enabled() { [[ "$(ep_get "$1" TYPE)" == mcp && "$(ep_get "$1" ENABLED true)" == true ]]; }
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
    [[ "$(ep_get "$domain" TYPE)" == mcp ]] || { gb_warn "$domain is not an MCP domain."; return 1; }
    origin="$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")"
    file="$(mcp_environment_source "$domain")"
    mcp_validate_origin "$origin" && mcp_validate_env_file "$file"
}

mcp_validate_origin() {
    [[ "$1" =~ ^https?://(localhost|127\.[0-9.]+|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|\[::1\])(:[0-9]{1,5})?$ ]] \
        || { gb_warn 'MCP_ORIGIN must identify the local/private nginx origin without a path.'; return 1; }
}

mcp_validate_env_file() {
    [[ -z "$1" || ( "$1" == /* && "$1" != *[[:space:]]* && "$1" != *'%'* && -f "$1" ) ]] \
        || { gb_warn 'MCP_ENV_FILE must be an existing absolute file path without whitespace or %.'; return 1; }
}

mcp_update_python() {
    local configured="$1"
    [[ "$configured" != *.*.* ]] || configured="${configured%.*}"
    py_resolve_version "$configured"
}

mcp_bundle_preflight() { py_bundle_validate mcp "$1" "$2"; }

mcp_environment_source() {
    if [[ -n "${MCP_ROLLBACK:-}" && -f "$MCP_ROLLBACK/mcp.env" ]]; then
        printf '%s\n' "$MCP_ROLLBACK/mcp.env"
    else
        ep_get "$1" MCP_ENV_FILE
    fi
}

mcp_deployment_inputs() {
    local domain="$1" release="$2" extra
    extra="$(mcp_environment_source "$domain")"
    {
        printf '%s\n' "$domain" "$release" "$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")"
        [[ -z "$extra" ]] || sha256sum < "$extra" || return 1
        (cd "$GB_SRC" && sha256sum systemd/getbible-mcp.service.tmpl types/runtime/templates/socket.tmpl \
            apps/mcp/gunicorn.conf.py.tmpl) || return 1
    } | sha256sum | cut -d' ' -f1
}

mcp_image_update() {
    # shellcheck disable=SC2034 # Used by the common endpoint transaction.
    local GB_LOCAL_APPLY=true
    mcp_cli update "$1"
}

mcp_prepare() {
    local domain="$1" root release python inputs generation socket target deployment_inputs extra
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
    deployment_inputs="$(mcp_deployment_inputs "$domain" "$release")" || return 1
    if [[ -z "${MCP_ROLLBACK:-}" && "${MCP_FORCE_DEPLOY:-false}" != true && -n "$MCP_OLD" \
          && "$(cat "$MCP_OLD/.inputs" 2>/dev/null)" == "$deployment_inputs" ]]; then
        if ! sd_available || sd_is_active "$(mcp_unit "$domain" "$MCP_OLD").service"; then
            gb_log "MCP generation $(basename "$MCP_OLD") of $domain is current."
            return 0
        fi
    fi
    [[ "$GB_DRY_RUN" != true ]] || { gb_log "Would prepare MCP at https://$domain/"; return 0; }
    gb_ensure_base_groups || return 1
    gb_ensure_system_user getbible-mcp getbible-mcp /nonexistent || return 1
    gb_ensure_dir "$(ep_log_dir "$domain")/app" 0750 getbible-mcp:getbible-mcp || return 1
    gb_ensure_dir "$root/deployments" 0755 || return 1
    generation="$(mktemp -d "$root/deployments/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")" || return 1
    MCP_CANDIDATE="$generation"
    chmod 0755 "$generation" || return 1
    printf '%s\n' "$release" > "$generation/.release" || return 1
    printf '%s\n' "$deployment_inputs" > "$generation/.inputs" || return 1
    gb_install_file "$(ep_conf "$domain")" "$generation/endpoint.conf" 0600 || return 1
    extra="$(mcp_environment_source "$domain")"
    if [[ -n "$extra" ]]; then gb_install_file "$extra" "$generation/mcp.env" 0600 || return 1; fi
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
    extra=""
    [[ ! -f "$generation/mcp.env" ]] || extra="$generation/mcp.env"
    gb_render "$GB_SRC/systemd/getbible-mcp.service.tmpl" "$generation/service.unit" \
        "DOMAIN=$domain" "UNIT=$(mcp_unit "$domain" "$generation")" "RELEASE=$release" \
        "GENERATION=$generation" "ORIGIN=$origin" "EXTRA_ENV=$extra" "LOG_DIR=$(ep_log_dir "$domain")" || return 1
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
    if [[ -n "$MCP_OLD" && -n "${MCP_SNAPSHOT:-}" ]] && { [[ -n "$MCP_CANDIDATE" ]] || ! mcp_enabled "$domain"; }; then
        sd_retire_after "$(mcp_unit "$domain" "$MCP_OLD")" "$MCP_SNAPSHOT" \
            || gb_warn 'The previous MCP generation remains available while nginx drains.'
    fi
    if [[ -n "$MCP_CANDIDATE" ]]; then
        tg_notify ok "MCP ready: $domain" "All supported APIs are available at https://$domain/."
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
        gb_ensure_dir "$(ep_log_dir "$domain")/app" 0750 getbible-mcp:getbible-mcp || return 1
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
    printf 'Domain: %s\nMCP enabled: %s\nEndpoint: https://%s/\n' "$domain" "$(ep_get "$domain" ENABLED true)" "$domain"
    printf 'Origin: %s\nEnvironment file: %s\n' "$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")" "$(ep_get "$domain" MCP_ENV_FILE '(library defaults)')"
    if [[ -n "$generation" ]]; then
        printf 'Generation: %s\nService: %s\n' "$(basename "$generation")" "$(sd_status_line "$(mcp_unit "$domain" "$generation").service")"
    fi
}

mcp_cli() {
    local action="${1:-status}" domain="${2:-}" key value python="" configured status=0 index
    local -a keys=() values=()
    local GB_CONFIGURATION_TRANSACTION="" MCP_ROLLBACK=""
    [[ -n "$domain" ]] || { gb_warn 'mcp status|configure|update|rollback DOMAIN [--python VERSION] [--origin URL] [--env-file FILE]'; return 1; }
    ep_exists "$domain" || { gb_warn "Unknown domain: $domain"; return 1; }
    [[ "$(ep_get "$domain" TYPE)" == mcp ]] || { gb_warn "$domain is not an MCP domain."; return 1; }
    shift 2
    if [[ "$action" == status ]]; then [[ $# == 0 ]] || return 1; mcp_status "$domain"; return; fi
    case "$action" in configure|update|rollback) ;; *) gb_warn "Unknown MCP action: $action"; return 1 ;; esac
    [[ "$action" != rollback || $# == 0 ]] || { gb_warn 'MCP rollback restores the retained code and settings; configure overrides separately.'; return 1; }
    configuration_transaction_recover "$domain" || return 1
    while (( $# )); do
        [[ $# -ge 2 ]] || return 1
        case "$1" in
            --python) key=MCP_PYTHON_VERSION; value="$(py_resolve_version "$2")" || return 1; python="$value" ;;
            --origin) key=MCP_ORIGIN; value="$2"; mcp_validate_origin "$value" || return 1 ;;
            --env-file) key=MCP_ENV_FILE; value="$2"; mcp_validate_env_file "$value" || return 1 ;;
            *) gb_warn "Unknown MCP setting: $1"; return 1 ;;
        esac
        keys+=("$key"); values+=("$value")
        shift 2
    done
    if [[ "$action" == update && -z "$python" ]]; then
        configured="$(ep_get "$domain" MCP_PYTHON_VERSION auto)"
        python="$(mcp_update_python "$configured")" || return 1
        keys+=(MCP_PYTHON_VERSION); values+=("$python")
    fi
    if [[ "$action" == rollback ]]; then
        MCP_ROLLBACK="$(readlink -f -- "$(mcp_root "$domain")/previous" 2>/dev/null)" || return 1
        [[ -d "$MCP_ROLLBACK" ]] || { gb_warn 'No retained MCP generation exists.'; return 1; }
        if [[ -f "$MCP_ROLLBACK/endpoint.conf" ]]; then
            for key in MCP_PYTHON_VERSION MCP_ORIGIN MCP_ENV_FILE; do
                keys+=("$key"); values+=("$(cfg_get "$MCP_ROLLBACK/endpoint.conf" "$key")")
            done
        fi
    elif [[ -n "$python" ]]; then
        py_bundle_validate mcp "$python" || return 1
    fi
    [[ "$GB_DRY_RUN" != true ]] || { gb_log "Would $action MCP on $domain."; return 0; }
    configuration_transaction_begin "$domain" "$(ep_conf "$domain")" || return 1
    EP_ORIGIN_COMMITTED=false; EP_APPLY_EDGE_FAILED=false; EP_APPLY_RECOVERY_SAFE=true
    for index in "${!keys[@]}"; do
        if ! ep_set "$domain" "${keys[$index]}" "${values[$index]}"; then status=1; break; fi
    done
    if (( status == 0 )); then configuration_transaction_prepared "$domain" || status=$?; fi
    if (( status == 0 )); then endpoint_apply "$domain" || status=$?; fi
    configuration_transaction_finish "$status" || return "$?"
    tg_notify ok "MCP $action: $domain" 'The managed MCP endpoint configuration was applied.'
}

mcp_menu() {
    local domain="${1:-}" action python origin file item
    local -a domains=()
    if [[ -z "$domain" ]]; then
        while IFS= read -r item; do [[ -z "$item" ]] || domains+=("$item" "MCP at https://$item/"); done < <(ep_list_by_type mcp)
        [[ ${#domains[@]} -gt 0 ]] || { ui_msg 'MCP domains' 'Deploy an MCP domain from Deploy > MCP service.'; return 0; }
        domain="$(ui_menu 'MCP domains' 'Choose a dedicated MCP domain.' "${domains[@]}")" || return 0
    fi
    action="$(ui_menu 'MCP service' "https://$domain/ covers every supported API version." \
        status 'Status' configure 'Configure Python and upstream origin' update 'Update installed package' rollback 'Restore previous release')" || return 0
    if [[ "$action" == configure ]]; then
        python="$(ui_input 'MCP Python' 'Managed Python selection' "$(ep_get "$domain" MCP_PYTHON_VERSION auto)")" || return 0
        origin="$(ui_input 'MCP local origin' 'Local nginx origin; HTTPS preserves the upstream TLS hostname' "$(ep_get "$domain" MCP_ORIGIN "$(mcp_default_origin)")")" || return 0
        file="$(ui_input 'MCP configuration' 'Optional absolute environment file for custom upstream domains' "$(ep_get "$domain" MCP_ENV_FILE)")" || return 0
        ui_run "MCP $action" mcp_cli "$action" "$domain" --python "$python" --origin "$origin" --env-file "$file"
    else
        ui_run "MCP $action" mcp_cli "$action" "$domain"
    fi
}
