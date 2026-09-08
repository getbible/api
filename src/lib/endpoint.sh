#!/usr/bin/env bash
# The endpoint pipeline shared by every type: render, install, certificate,
# documentation, and removal. Type modules supply the pieces.

[[ -n "${GB_ENDPOINT_LOADED:-}" ]] && return 0
GB_ENDPOINT_LOADED=1

endpoint_source_type() {
    local type="$1"
    [[ -f "$GB_TYPES/$type/type.sh" ]] || gb_die "Unknown endpoint type: $type"
    # shellcheck source=/dev/null
    source "$GB_TYPES/$type/type.sh"
}

# Restore routing before stopping a failed candidate. The old runtime keeps
# serving until the full configuration transaction has committed.
endpoint_apply_abort() {
    local domain="$1" reason="$2" recovery=true
    gb_warn "$reason"
    if [[ -n "${EP_ENABLE_BACKUP:-}" ]]; then
        gb_restore_file "$(nginx_enabled_file "$domain")" "$EP_ENABLE_BACKUP" || recovery=false
    fi
    nginx_transaction_rollback "$domain" || recovery=false
    if declare -F "type_${EP_TYPE}_abort" >/dev/null; then
        if [[ "$recovery" == true ]]; then
            "type_${EP_TYPE}_abort" "$domain" || recovery=false
        else
            gb_warn "Routing recovery failed; retaining runtime processes to avoid interrupting traffic."
        fi
    fi
    ep_state_set "$domain" LAST_ERROR "$reason" || true
    tg_notify fail "Endpoint update failed: $domain" "$reason. Routing recovery: $recovery."
    return 1
}

# All stages check their own errors because callers may invoke this function
# from an if/! condition, where Bash does not apply errexit inside functions.
#
# A staged endpoint runs the same pipeline minus everything that needs its
# public name: no shared-cache protection at the edge, no certificate request
# and no Cloudflare DNS or rules. It renders TLS with a placeholder
# certificate so the complete vhost can be tested before go-live.
endpoint_apply() {
    local domain="$1" stage live=true
    ep_load "$domain" || return 1
    endpoint_source_type "$EP_TYPE" || return 1
    ep_is_live "$domain" || live=false
    gb_ensure_base_dirs || return 1
    logs_ensure_endpoint_dir "$domain" || return 1
    EP_ENABLE_BACKUP="$(gb_new_backup_set "site-enable-$EP_SLUG")" || return 1
    gb_backup_file "$(nginx_enabled_file "$domain")" "$EP_ENABLE_BACKUP" || return 1
    nginx_transaction_begin "$domain" || return 1
    if [[ "$live" == true ]] && declare -F cloudflare_protect_access >/dev/null; then
        cloudflare_protect_access "$domain" || { endpoint_apply_abort "$domain" "Could not protect shared-cache access"; return 1; }
    fi
    "type_${EP_TYPE}_prepare" "$domain" || { endpoint_apply_abort "$domain" "Endpoint candidate preparation failed"; return 1; }
    docs_render "$domain" || { endpoint_apply_abort "$domain" "Endpoint documentation rendering failed"; return 1; }
    if [[ "$live" == false ]] && ! nginx_cert_exists "$domain"; then
        certs_placeholder_ensure "$domain" || gb_warn "$domain is staged without a placeholder certificate and renders HTTP-only until one exists."
    fi
    if [[ "$live" == true ]] && declare -F cloudflare_ensure_origin_files >/dev/null; then
        cloudflare_ensure_origin_files "$domain" || { endpoint_apply_abort "$domain" "Cloudflare address ranges or origin CA could not be fetched"; return 1; }
    fi

    stage="$(gb_tmpdir)/stage-$EP_SLUG"
    rm -rf -- "$stage" || return 1
    nginx_render_global "$stage" && nginx_render_endpoint "$stage" || { endpoint_apply_abort "$domain" "nginx rendering failed"; return 1; }
    nginx_enable_site "$domain" || { endpoint_apply_abort "$domain" "Could not enable the nginx site"; return 1; }
    if declare -F "type_${EP_TYPE}_before_switch" >/dev/null; then
        "type_${EP_TYPE}_before_switch" "$domain" || { endpoint_apply_abort "$domain" "Could not prepare the traffic switch"; return 1; }
    fi
    nginx_apply_stage "$stage" "$EP_SLUG" || { endpoint_apply_abort "$domain" "nginx rejected the endpoint configuration"; return 1; }

    if [[ "$live" == true ]] && ! nginx_cert_exists "$domain"; then
        if certs_obtain "$domain"; then
            rm -rf -- "$stage" || return 1
            nginx_render_global "$stage" && nginx_render_endpoint "$stage" || { endpoint_apply_abort "$domain" "TLS configuration rendering failed"; return 1; }
            nginx_apply_stage "$stage" "$EP_SLUG" || { endpoint_apply_abort "$domain" "nginx rejected the TLS configuration"; return 1; }
        else
            gb_warn "$domain is reachable over HTTP only until a certificate is issued."
        fi
    fi
    "type_${EP_TYPE}_finish" "$domain" || { endpoint_apply_abort "$domain" "Endpoint activation failed"; return 1; }
    nginx_transaction_commit "$domain" || return 1
    EP_ENABLE_BACKUP=""
    if [[ "$live" == true && -n "${GB_CLOUDFLARE_LOADED:-}" && "$(ep_get "$domain" CLOUDFLARE_MODE off)" != off ]]; then
        if cloudflare_apply "$domain"; then
            ep_state_set "$domain" CLOUDFLARE_ERROR ""
        else
            gb_warn "Cloudflare update failed for $domain; nginx is unaffected."
            ep_state_set "$domain" CLOUDFLARE_ERROR "Cloudflare update failed at $(gb_timestamp)"
        fi
    fi
    if [[ "$live" == true ]]; then
        # nginx now serves the Let's Encrypt certificate; a placeholder left
        # over from staging has no further use.
        if nginx_cert_exists "$domain"; then certs_placeholder_remove "$domain"; fi
    else
        gb_log "$domain is staged: no certificate was requested and DNS was not changed. Choose 'Go live' when it should take over its name."
    fi
    ep_state_set "$domain" LAST_APPLY "$(gb_timestamp)"
    ep_state_set "$domain" LAST_APPLY_COMMIT "$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    ep_state_set "$domain" LAST_ERROR ""
}

endpoint_apply_all() {
    local domain failures=0
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        gb_step "Updating $domain"
        if ! endpoint_apply "$domain"; then
            gb_warn "Update failed for $domain"
            failures=$((failures + 1))
        fi
    done < <(ep_list)
    return "$failures"
}

# endpoint_remove DOMAIN [purge]: stop serving, keep data unless purge.
endpoint_remove() {
    local domain="$1" purge="${2:-false}"
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    "type_${EP_TYPE}_remove" "$domain" "$purge"
    nginx_remove_endpoint "$domain"
    certs_placeholder_remove "$domain"
    if [[ "$purge" == true ]]; then
        rm -rf -- "$(ep_www_dir "$domain")" "$(ep_log_dir "$domain")"
    fi
    ep_remove_config "$domain"
    tg_notify warn "Endpoint removed" "$domain was removed from this server$([[ "$purge" == true ]] && printf ' with its data and logs' || printf '; data and logs kept')."
}

endpoint_status_text() {
    local domain="$1"
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    printf 'Endpoint    : %s (%s%s)\n' "$domain" "$EP_TYPE" "$([[ -n "$EP_KIND" && "$EP_KIND" != static ]] && printf ' %s' "$EP_KIND")"
    printf 'Publication : %s\n' "$(endpoint_publication_text "$domain")"
    printf 'Access mode : %s\n' "$EP_ACCESS_MODE"
    if [[ "$EP_ACCESS_MODE" == metered ]]; then
        printf 'Limits      : %s r/s burst %s, %s/hour, %s/day, %s connections\n' "$EP_RATE_PER_SECOND" "$EP_RATE_BURST" "$EP_QUOTA_HOUR" "$EP_QUOTA_DAY" "$EP_CONN_LIMIT"
    fi
    printf 'Tokens      : %s active\n' "$(tokens_count "$domain")"
    printf 'Certificate : %s\n' "$(certs_status_line "$domain")"
    printf 'Cloudflare  : %s\n' "$EP_CLOUDFLARE_MODE"
    printf 'nginx site  : %s\n' "$([[ -f "$(nginx_site_file "$domain")" ]] && printf installed || printf missing)"
    printf 'Last apply  : %s (%s)\n' "$(ep_state_get "$domain" LAST_APPLY never)" "$(ep_state_get "$domain" LAST_APPLY_COMMIT -)"
    printf 'Logs        : %s\n' "$(ep_log_dir "$domain")"
    printf '\n'
    "type_${EP_TYPE}_status" "$domain"
}

# endpoint_publication_text DOMAIN: the publication state for status output.
endpoint_publication_text() {
    local since
    if ep_is_live "$1"; then
        since="$(ep_state_get "$1" LIVE_AT)"
        printf 'live%s\n' "${since:+ since $since}"
    else
        printf 'staged (not live: no certificate or DNS changes until go-live)\n'
    fi
}

# --- shared prompts ----------------------------------------------------------
# Ask whether a new endpoint takes over its name now or stays staged until
# 'Go live' is chosen. The default comes from Settings. Choosing live makes
# sure the Let's Encrypt contact exists while dialogs are still possible.
endpoint_prompt_deploy_mode() {
    local domain="$1" default mode
    default="$(ep_deploy_mode_default)"
    mode="$(ui_radiolist "Go live now?" "Live: request the Let's Encrypt certificate now and, when Cloudflare manages $domain here, point its DNS at this server.\n\nStaged: install everything (code, data, services, nginx with a placeholder certificate) but leave the certificate and DNS alone, so whatever serves $domain today keeps serving until you choose 'Go live' for it." \
        live "Go live now" "$([[ "$default" == live ]] && echo on || echo off)" \
        staged "Stage it; go live later from the endpoint menu" "$([[ "$default" == staged ]] && echo on || echo off)")" || return 1
    if [[ "$mode" == live ]]; then
        certs_email_interactive || gb_warn "Without a Let's Encrypt contact email the certificate request is skipped; set it under Settings."
    fi
    printf '%s\n' "$mode"
}

endpoint_prompt_access_mode() {
    local default
    default="$(gb_global DEFAULT_ACCESS_MODE metered)"
    ui_radiolist "Access mode" "How may this endpoint be called? Token holders are never limited." \
        open "Open: no token, no limits" "$([[ "$default" == open ]] && echo on || echo off)" \
        metered "Metered: public budget per address, tokens unlimited" "$([[ "$default" == metered ]] && echo on || echo off)" \
        token "Token only: a bearer token is required" "$([[ "$default" == token ]] && echo on || echo off)"
}

# endpoint_set_access DOMAIN MODE
endpoint_set_access() {
    local domain="$1" mode="$2" previous
    access_valid_mode "$mode" || gb_die "Invalid access mode: $mode"
    previous="$(ep_get "$domain" ACCESS_MODE)"
    ep_set "$domain" ACCESS_MODE "$mode" || return 1
    if ! endpoint_apply "$domain"; then
        ep_set "$domain" ACCESS_MODE "$previous"
        return 1
    fi
    tg_notify info "Access mode changed: $domain" "Now: $(access_mode_description "$mode")"
}

# endpoint_set_limits DOMAIN RATE BURST HOUR DAY CONN (empty keeps current)
endpoint_set_limits() {
    local domain="$1" rate="$2" burst="$3" hour="$4" day="$5" conn="$6" key value
    for key in RATE_PER_SECOND:"$rate" RATE_BURST:"$burst" QUOTA_HOUR:"$hour" QUOTA_DAY:"$day" CONN_LIMIT:"$conn"; do
        value="${key#*:}"
        key="${key%%:*}"
        [[ -z "$value" ]] && continue
        gb_valid_integer "$value" && (( value > 0 )) || gb_die "$key must be a positive integer"
        ep_set "$domain" "$key" "$value"
    done
    endpoint_apply "$domain"
    tg_notify info "Limits changed: $domain" "$(ep_get "$domain" RATE_PER_SECOND) r/s burst $(ep_get "$domain" RATE_BURST), $(ep_get "$domain" QUOTA_HOUR)/hour, $(ep_get "$domain" QUOTA_DAY)/day, $(ep_get "$domain" CONN_LIMIT) connections."
}

endpoint_prompt_limits() {
    local domain="$1" rate burst hour day conn
    rate="$(ui_input "Limits" "Requests per second per address" "$(ep_get "$domain" RATE_PER_SECOND)")" || return 1
    burst="$(ui_input "Limits" "Burst above that rate" "$(ep_get "$domain" RATE_BURST)")" || return 1
    hour="$(ui_input "Limits" "Requests per hour per address" "$(ep_get "$domain" QUOTA_HOUR)")" || return 1
    day="$(ui_input "Limits" "Requests per day per address" "$(ep_get "$domain" QUOTA_DAY)")" || return 1
    conn="$(ui_input "Limits" "Concurrent connections per address" "$(ep_get "$domain" CONN_LIMIT)")" || return 1
    endpoint_set_limits "$domain" "$rate" "$burst" "$hour" "$day" "$conn"
}

# Token management for one endpoint (menu).
endpoint_tokens_menu() {
    local domain="$1" choice label expires id result out
    while true; do
        out="$(gb_tmpdir)/tokens.$$"
        tokens_list "$domain" > "$out" 2>&1 || true
        choice="$(ui_menu "Tokens for $domain" "$(head -12 "$out")" \
            add "Generate a new token" list "List tokens" revoke "Revoke a token" back "Back")" || return 0
        case "$choice" in
            add)
                label="$(ui_input "New token" "Label (who or what will use it)" "")" || continue
                expires="$(ui_input "New token" "Expiry date YYYY-MM-DD (empty for none)" "")" || continue
                result="$(tokens_add "$domain" "$label" "$expires")" || { ui_msg "Token" "Token creation failed."; continue; }
                endpoint_apply "$domain" >/dev/null
                tg_notify info "Token issued: $domain" "Label: $label"
                ui_msg "New token (shown once)" "Label: $label\n\nAuthorization: Bearer $(printf '%s' "$result" | "$GB_PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["token"])')\n\nStore it now; it cannot be displayed again."
                ;;
            list) ui_textbox "Tokens for $domain" "$out" ;;
            revoke)
                id="$(ui_input "Revoke" "Token id (tk_...)" "")" || continue
                tokens_revoke "$domain" "$id" && endpoint_apply "$domain" >/dev/null && tg_notify warn "Token revoked: $domain" "Id: $id"
                ;;
            back) return 0 ;;
        esac
    done
}
