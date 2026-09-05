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

# endpoint_apply DOMAIN: make the live configuration match the registry.
# Phase one renders the HTTP vhost, phase two adds TLS once a certificate
# exists. Safe to run repeatedly; a second run changes nothing.
endpoint_apply() {
    local domain="$1" stage
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    gb_ensure_base_dirs
    logs_ensure_endpoint_dir "$domain"
    "type_${EP_TYPE}_prepare" "$domain"
    docs_render "$domain"

    stage="$(gb_tmpdir)/stage-$EP_SLUG"
    rm -rf -- "$stage"
    nginx_render_global "$stage"
    nginx_render_endpoint "$stage"
    nginx_enable_site "$domain"
    nginx_apply_stage "$stage" "$EP_SLUG" || gb_die "nginx refused the configuration for $domain; previous files restored."

    if ! nginx_cert_exists "$domain"; then
        if certs_obtain "$domain"; then
            rm -rf -- "$stage"
            nginx_render_global "$stage"
            nginx_render_endpoint "$stage"
            nginx_apply_stage "$stage" "$EP_SLUG" || gb_die "nginx refused the TLS configuration for $domain."
        else
            gb_warn "$domain is reachable over HTTP only until a certificate is issued."
        fi
    fi
    "type_${EP_TYPE}_finish" "$domain"
    if [[ -n "${GB_CLOUDFLARE_LOADED:-}" && "$(ep_get "$domain" CLOUDFLARE_MODE off)" != off ]]; then
        cloudflare_apply "$domain" || gb_warn "Cloudflare update failed for $domain; nginx is unaffected."
    fi
    ep_state_set "$domain" LAST_APPLY "$(gb_timestamp)"
    ep_state_set "$domain" LAST_APPLY_COMMIT "$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
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
    printf 'Access mode : %s\n' "$EP_ACCESS_MODE"
    if [[ "$EP_ACCESS_MODE" == metered ]]; then
        printf 'Limits      : %s r/s burst %s, %s/hour, %s/day, %s connections\n' "$EP_RATE_PER_SECOND" "$EP_RATE_BURST" "$EP_QUOTA_HOUR" "$EP_QUOTA_DAY" "$EP_CONN_LIMIT"
    fi
    printf 'Tokens      : %s active\n' "$(tokens_count "$domain")"
    printf 'Certificate : %s\n' "$(certs_expiry "$domain")"
    printf 'Cloudflare  : %s\n' "$EP_CLOUDFLARE_MODE"
    printf 'nginx site  : %s\n' "$([[ -f "$(nginx_site_file "$domain")" ]] && printf installed || printf missing)"
    printf 'Last apply  : %s (%s)\n' "$(ep_state_get "$domain" LAST_APPLY never)" "$(ep_state_get "$domain" LAST_APPLY_COMMIT -)"
    printf 'Logs        : %s\n' "$(ep_log_dir "$domain")"
    printf '\n'
    "type_${EP_TYPE}_status" "$domain"
}

# --- shared prompts ----------------------------------------------------------
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
    local domain="$1" mode="$2"
    access_valid_mode "$mode" || gb_die "Invalid access mode: $mode"
    ep_set "$domain" ACCESS_MODE "$mode"
    endpoint_apply "$domain"
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
