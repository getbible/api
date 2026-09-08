#!/usr/bin/env bash
# The whiptail menu tree. Every action here calls the same functions the
# command line uses; the menu only gathers input.

[[ -n "${GB_MENU_LOADED:-}" ]] && return 0
GB_MENU_LOADED=1

menu_main() {
    local choice
    while true; do
        choice="$(ui_menu "getBible API" "$(menu_overview)" \
            endpoints "Endpoints: status, logs, access, tokens, sync" \
            deploy "Deploy a new endpoint (live now, or staged for later)" \
            golive "Go live: switch a staged endpoint to its public name" \
            update "Update all endpoints (after git pull)" \
            analytics "Traffic analytics: calls and unique callers" \
            logs "Logs: view, archives, rotate" \
            settings "Settings: Telegram, Cloudflare, defaults, retention" \
            system "System: host check, dependencies, migration, self-test" \
            exit "Exit")" || return 0
        case "$choice" in
            endpoints) menu_endpoints ;;
            deploy) menu_deploy ;;
            golive) golive_menu ;;
            update) menu_update ;;
            analytics) menu_analytics ;;
            logs) menu_logs ;;
            settings) menu_settings ;;
            system) menu_system ;;
            exit) return 0 ;;
        esac
    done
}

menu_overview() {
    local domain count=0 lines=""
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        count=$((count + 1))
        lines="$lines$(ep_summary_line "$domain")"$'\n'
    done < <(ep_list)
    if (( count == 0 )); then
        printf 'No endpoints yet. Deploy one to begin.\n'
    else
        printf '%s' "$lines"
    fi
}

menu_endpoints() {
    local domain
    local -a items=()
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        items+=("$domain" "$(ep_get "$domain" TYPE) $(ep_get "$domain" KIND) · $(ep_get "$domain" ACCESS_MODE)")
    done < <(ep_list)
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Endpoints" "No endpoints are deployed yet."; return 0; }
    domain="$(ui_menu "Endpoints" "Choose an endpoint" "${items[@]}")" || return 0
    menu_endpoint "$domain"
}

menu_endpoint() {
    local domain="$1" choice out
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    while true; do
        local -a extra=() golive=()
        mapfile -t extra < <("type_${EP_TYPE}_menu_items")
        if ep_is_live "$domain"; then
            golive=(stage "Stage again: stop taking over this name (for rolling back; DNS is not changed)")
        else
            golive=(golive "Go live: certificate, DNS, HTTPS (this endpoint is staged)")
        fi
        choice="$(ui_menu "$domain" "$EP_TYPE $EP_KIND · access: $(ep_get "$domain" ACCESS_MODE) · $(ep_publication "$domain")" \
            status "Status and health" \
            verify "Verify this server end to end (service, nginx, TLS)" \
            "${golive[@]+"${golive[@]}"}" \
            logs "Logs" \
            access "Access mode (open, metered, token only)" \
            limits "Limits for anonymous callers" \
            tokens "Bearer tokens" \
            certificate "Certificate: status, issue, renew" \
            cloudflare "Cloudflare settings for this domain" \
            "${extra[@]}" \
            apply "Re-apply configuration" \
            remove "Remove this endpoint" \
            back "Back")" || return 0
        case "$choice" in
            status)
                out="$(gb_tmpdir)/status.$$"
                endpoint_status_text "$domain" > "$out" 2>&1 || true
                ui_textbox "Status: $domain" "$out" ;;
            verify)
                out="$(gb_tmpdir)/verify.$$"
                golive_verify "$domain" > "$out" 2>&1 || true
                ui_textbox "Verify: $domain" "$out" ;;
            golive) golive_interactive "$domain" || true ;;
            stage) golive_stage_again_interactive "$domain" ;;
            certificate) certs_menu "$domain" ;;
            logs) menu_endpoint_logs "$domain" ;;
            access)
                local mode
                mode="$(endpoint_prompt_access_mode)" || continue
                ui_run "Access mode" endpoint_set_access "$domain" "$mode" ;;
            limits) endpoint_prompt_limits "$domain" ;;
            tokens) endpoint_tokens_menu "$domain" ;;
            cloudflare) cloudflare_endpoint_menu "$domain" ;;
            apply)
                endpoint_confirm_hand_edits "$domain" || continue
                ui_run "Apply $domain" endpoint_apply "$domain" || true
                GB_OVERWRITE_HAND_EDITS=false ;;
            remove)
                if ui_yesno "Remove" "Stop serving $domain and remove its configuration?" no; then
                    local purge=false
                    ui_yesno "Remove" "Also delete its synced data, releases and logs?" no && purge=true
                    ui_run "Remove $domain" endpoint_remove "$domain" "$purge"
                    return 0
                fi ;;
            back) return 0 ;;
            *) "type_${EP_TYPE}_menu_action" "$domain" "$choice" ;;
        esac
    done
}

menu_endpoint_logs() {
    local domain="$1" choice out
    while true; do
        choice="$(ui_menu "Logs: $domain" "$(ep_log_dir "$domain")" \
            access "Access log (last 200 lines)" \
            error "Error log (last 200 lines)" \
            app "Application log (runtime endpoints)" \
            journal "Service journal" \
            archives "Archived logs" \
            back "Back")" || return 0
        [[ "$choice" == back ]] && return 0
        out="$(gb_tmpdir)/log.$$"
        case "$choice" in
            archives) logs_archives "$domain" > "$out" ;;
            *) cmd_logs "$domain" "$choice" --lines 200 > "$out" 2>&1 || true ;;
        esac
        ui_textbox "$choice: $domain" "$out"
    done
}

menu_deploy() {
    local choice
    choice="$(ui_menu "Deploy" "What kind of endpoint?" \
        static "Static files synced from a git repository" \
        runtime "Runtime service (query or search) on the librarian" \
        back "Back")" || return 0
    case "$choice" in
        static) endpoint_source_type static; type_static_deploy_interactive ;;
        runtime) endpoint_source_type runtime; type_runtime_deploy_interactive ;;
    esac
}

menu_update() {
    local state commit dirty
    state="$(update_repo_state)"
    commit="${state%%$'\n'*}"
    dirty="${state#*$'\n'}"
    local text="Checkout: $GB_REPO_DIR at $commit"
    [[ -n "$dirty" ]] && text="$text (local modifications present)"
    local choice
    choice="$(ui_menu "Update" "$text" \
        apply "Update all endpoints from the current checkout" \
        pull "git pull first, then update all endpoints" \
        back "Back")" || return 0
    case "$choice" in
        apply) ui_run "Update all" update_all ;;
        pull) update_pull_and_all ;;
    esac
}

menu_analytics() {
    local window domain out
    window="$(ui_radiolist "Analytics" "Time window" today "Today" off 24h "Last 24 hours" on 7d "Last 7 days" off 30d "Last 30 days" off all "Everything retained" off)" || return 0
    out="$(gb_tmpdir)/analytics.$$"
    analytics_report "$window" "" > "$out" 2>&1 || true
    ui_textbox "Analytics ($window)" "$out"
}

menu_logs() {
    local choice domain out
    choice="$(ui_menu "Logs" "Retention: $(gb_global LOG_ROTATE_KEEP 30) archives of $(gb_global LOG_ROTATE_SIZE 1G) each, checked hourly" \
        view "View an endpoint's logs" \
        rotate "Rotate now (files above the size limit)" \
        force "Force rotation of every log now" \
        retention "Change retention" \
        back "Back")" || return 0
    case "$choice" in
        view)
            domain="$(menu_pick_domain)" || return 0
            menu_endpoint_logs "$domain" ;;
        rotate) ui_run "Rotate" /usr/sbin/logrotate -s "$GB_VAR/logrotate.state" "$GB_LOGROTATE_CONF" ;;
        force) ui_run "Force rotation" logs_rotate_now ;;
        retention) menu_settings_retention ;;
    esac
}

menu_pick_domain() {
    local domain
    local -a items=()
    while read -r domain; do [[ -n "$domain" ]] && items+=("$domain" "$(ep_get "$domain" TYPE)"); done < <(ep_list)
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Endpoints" "No endpoints yet."; return 1; }
    ui_menu "Endpoints" "Choose an endpoint" "${items[@]}"
}

menu_settings() {
    local choice
    while true; do
        choice="$(ui_menu "Settings" "$GB_ETC" \
            telegram "Telegram notifications" \
            cloudflare "Cloudflare API token" \
            defaults "Defaults for new endpoints (access, limits, caching, schedule)" \
            retention "Log retention" \
            deploymode "New endpoints: go live at once, or stage them for a later go-live" \
            certmethod "Certificate validation: automatic, http, or dns-cloudflare" \
            certbot "Let's Encrypt contact email" \
            addresses "Public addresses used for DNS records (empty: detected)" \
            hsts "HSTS includeSubDomains" \
            back "Back")" || return 0
        case "$choice" in
            telegram) menu_settings_telegram ;;
            cloudflare) cloudflare_configure ;;
            defaults) menu_settings_defaults ;;
            retention) menu_settings_retention ;;
            deploymode) menu_settings_deploy_mode ;;
            certmethod) menu_settings_cert_method ;;
            addresses) menu_settings_addresses ;;
            certbot)
                local email
                email="$(ui_input "Let's Encrypt" "Contact email" "$(gb_global CERTBOT_EMAIL)")" || continue
                certs_valid_email "$email" || { ui_msg "Let's Encrypt" "'$email' is not a valid email address."; continue; }
                gb_global_set CERTBOT_EMAIL "$email" ;;
            hsts)
                if ui_yesno "HSTS" "Send includeSubDomains with Strict-Transport-Security? Only when every subdomain of every endpoint is HTTPS." "$([[ "$(gb_global HSTS_INCLUDE_SUBDOMAINS false)" == true ]] && echo yes || echo no)"; then
                    gb_global_set HSTS_INCLUDE_SUBDOMAINS true
                else
                    gb_global_set HSTS_INCLUDE_SUBDOMAINS false
                fi
                ui_msg "HSTS" "Saved. Run Update to re-render every endpoint." ;;
            back) return 0 ;;
        esac
    done
}

menu_settings_deploy_mode() {
    local current mode
    current="$(gb_global DEFAULT_DEPLOY_MODE live)"
    mode="$(ui_radiolist "New endpoints" "What should a newly deployed endpoint do by default? The deploy walkthrough still asks each time.\n\nStage them while building a replacement server: everything is installed, but no certificate is requested and DNS is untouched until you choose 'Go live' per endpoint." \
        live "Go live at once: certificate and Cloudflare DNS on deploy" "$([[ "$current" == live ]] && echo on || echo off)" \
        staged "Stage: prepare everything, go live later per endpoint" "$([[ "$current" == staged ]] && echo on || echo off)")" || return 0
    gb_global_set DEFAULT_DEPLOY_MODE "$mode"
    ui_msg "New endpoints" "New endpoints are $mode by default. Existing endpoints are not affected."
}

menu_settings_cert_method() {
    local current method
    current="$(gb_global CERT_METHOD auto)"
    method="$(ui_radiolist "Certificate validation" "How Let's Encrypt validates a domain when a certificate is requested.\n\nDNS-01 through Cloudflare needs the certbot-dns-cloudflare plugin (System > Install dependencies) and the Cloudflare API token, and works before DNS points at this server: the zero-downtime path for a new server." \
        auto "Automatic: dns-cloudflare when available, otherwise http" "$([[ "$current" == auto ]] && echo on || echo off)" \
        http "HTTP-01: DNS must already route the name to this server" "$([[ "$current" == http ]] && echo on || echo off)" \
        dns-cloudflare "DNS-01 through the Cloudflare API token" "$([[ "$current" == dns-cloudflare ]] && echo on || echo off)")" || return 0
    gb_global_set CERT_METHOD "$method"
    ui_msg "Certificate validation" "Certificates are validated with: $method. 'Go live' and 'Issue certificate' can still choose per request."
}

menu_settings_addresses() {
    local ipv4 ipv6
    ipv4="$(ui_input "Public addresses" "IPv4 address for this server's DNS records (empty: detected through api.ipify.org)" "$(gb_global SERVER_PUBLIC_IPV4)")" || return 0
    [[ -z "$ipv4" || "$ipv4" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { ui_msg "Invalid" "$ipv4 is not an IPv4 address."; return 0; }
    ipv6="$(ui_input "Public addresses" "IPv6 address for this server's DNS records (empty: first global address found)" "$(gb_global SERVER_PUBLIC_IPV6)")" || return 0
    [[ -z "$ipv6" || "$ipv6" =~ ^[0-9A-Fa-f:]+$ && "$ipv6" == *:* ]] || { ui_msg "Invalid" "$ipv6 is not an IPv6 address."; return 0; }
    gb_global_set SERVER_PUBLIC_IPV4 "$ipv4"
    gb_global_set SERVER_PUBLIC_IPV6 "$ipv6"
    ui_msg "Public addresses" "DNS records point at: IPv4 ${ipv4:-detected}, IPv6 ${ipv6:-detected}. Go live and Cloudflare apply use these."
}

menu_settings_telegram() {
    local choice
    choice="$(ui_menu "Telegram" "Enabled: $(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)" \
        configure "Enable or change bot token and chat" \
        test "Send a test message" \
        disable "Disable notifications" \
        back "Back")" || return 0
    case "$choice" in
        configure) tg_configure ;;
        test) tg_test ;;
        disable) cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false; ui_msg "Telegram" "Disabled." ;;
    esac
}

menu_settings_defaults() {
    local key label value
    for key in DEFAULT_ACCESS_MODE:"Default access mode (open, metered, token)" \
               DEFAULT_RATE_PER_SECOND:"Requests per second per address" \
               DEFAULT_RATE_BURST:"Burst" DEFAULT_QUOTA_HOUR:"Requests per hour" \
               DEFAULT_QUOTA_DAY:"Requests per day" DEFAULT_CONN_LIMIT:"Concurrent connections" \
               DEFAULT_CACHE_TTL:"Cache-Control max-age for documents (seconds)" \
               DEFAULT_SHA_CACHE_TTL:"Cache-Control max-age for .sha files (seconds)" \
               DEFAULT_SYNC_SCHEDULE:"Sync schedule (daily, weekly, monthly)" \
               DEFAULT_EXTENSIONS:"Default file types"; do
        label="${key#*:}"
        key="${key%%:*}"
        value="$(ui_input "Defaults" "$label" "$(gb_global "$key")")" || return 0
        gb_global_set "$key" "$value"
    done
    ui_msg "Defaults" "Saved. Existing endpoints keep their own values."
}

menu_settings_retention() {
    local size keep
    size="$(ui_input "Log retention" "Rotate a log once it reaches this size (e.g. 1G, 500M)" "$(gb_global LOG_ROTATE_SIZE 1G)")" || return 0
    keep="$(ui_input "Log retention" "Archived files to keep per log" "$(gb_global LOG_ROTATE_KEEP 30)")" || return 0
    [[ "$size" =~ ^[0-9]+[kMG]?$ ]] || { ui_msg "Invalid" "Sizes look like 1G or 500M."; return 0; }
    gb_valid_integer "$keep" || { ui_msg "Invalid" "Keep must be a number."; return 0; }
    gb_global_set LOG_ROTATE_SIZE "$size"
    gb_global_set LOG_ROTATE_KEEP "$keep"
    logs_render_rotation
    ui_msg "Log retention" "Logs rotate at $size and $keep archives are kept."
}

menu_system() {
    local choice out
    while true; do
        choice="$(ui_menu "System" "$(hostname -f 2>/dev/null || hostname)" \
            doctor "Check this host" \
            deps "Install dependencies (apt)" \
            migrate "Retire the legacy nginx/systemd setup" \
            cloudflare "Cloudflare origin tools (IP ranges, origin pulls)" \
            selftest "Run the test suite" \
            back "Back")" || return 0
        out="$(gb_tmpdir)/system.$$"
        case "$choice" in
            doctor) doctor_run > "$out" 2>&1 || true; ui_textbox "Host check" "$out" ;;
            deps) ui_run "Install dependencies" doctor_install_deps ;;
            migrate) migrate_interactive ;;
            cloudflare) cloudflare_system_menu ;;
            selftest) ui_run "Self-test" "$GB_REPO_DIR/tests/run.sh" ;;
            back) return 0 ;;
        esac
    done
}
