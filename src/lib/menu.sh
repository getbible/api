#!/usr/bin/env bash
# The whiptail menu tree. Every action here calls the same functions the
# command line uses; the menu only gathers input.

[[ -n "${GB_MENU_LOADED:-}" ]] && return 0
GB_MENU_LOADED=1

menu_main() {
    local choice manager_label='Update manager script from Git' update_label='Apply current checkout to all domains'
    if gb_is_docker; then
        manager_label='Update container image: host commands'
        update_label='Apply current image to all domains'
    fi
    menu_check_tools
    while true; do
        choice="$(ui_menu "getBible API" "$(menu_overview)" \
            domains "Domains: status, pages, logs, access, tokens, sync" \
            deploy "Deploy a new domain (live now, or staged for later)" \
            golive "Go live: switch a staged domain to its public name" \
            self-update "$manager_label" \
            update "$update_label" \
            analytics "Traffic analytics: calls and unique callers" \
            dashboard "Private dashboard: domain, password, sessions, blocked addresses" \
            mcp "MCP: enable, configure, update or roll back one /mcp endpoint" \
            logs "Logs: view, archives, rotate" \
            settings "Settings: Telegram, Cloudflare, icons, defaults, retention" \
            system "System: host check, dependencies, self-test" \
            exit "Exit")" || return 0
        case "$choice" in
            domains) menu_endpoints ;;
            deploy) menu_deploy ;;
            golive) golive_menu ;;
            self-update)
                if gb_is_docker; then
                    ui_msg 'Update container image' 'From the Docker host, in the directory containing compose.yaml:\n\ndocker compose pull\ndocker compose up -d\n\nSelect the image tag in .env first. Image replacement restarts the container and preserves mounted data. Apply the new image to domains explicitly afterwards.'
                    continue
                fi
                if ui_run "Update manager script" update_manager; then
                    # Libraries already sourced by this menu belong to the old
                    # checkout. End the session before another action uses them.
                    [[ "$GB_DRY_RUN" == true ]] || return 0
                fi ;;
            update) menu_update ;;
            analytics) menu_analytics ;;
            dashboard) menu_dashboard ;;
            mcp) mcp_menu ;;
            logs) menu_logs ;;
            settings) menu_settings ;;
            system) menu_system ;;
            exit) return 0 ;;
        esac
    done
}

# On start, make sure the host has what a complete deployment needs and offer
# to install it, so no walkthrough runs into a missing tool halfway through.
menu_check_tools() {
    local tool missing=""
    for tool in nginx certbot rsync git ssh-keygen openssl curl flock; do
        gb_have "$tool" || missing="$missing $tool"
    done
    [[ -n "$missing" ]] || return 0
    if gb_is_docker; then
        ui_msg 'Image dependencies' "This image lacks:$missing\n\nThe prepared image must include these tools. Select a complete image on the Docker host and run docker compose pull followed by docker compose up -d."
        return 0
    fi
    platform_detect
    if [[ "$PLATFORM_PACKAGE_MANAGER" == apt ]]; then
        if ui_yesno "Missing tools" "This host lacks:$missing\n\nDomains cannot be deployed completely without them. Install them now with apt (the same as System > Install dependencies)?" yes; then
            ui_run "Install dependencies" doctor_install_deps || true
            return 0
        fi
    fi
    ui_msg "Missing tools" "This host lacks:$missing\n\nInstall them before deploying (System > Install dependencies on Debian/Ubuntu, or your package manager:$(printf ' %s' "${GB_APT_PACKAGES[@]}")). Deployments warn about what is missing."
}

# Keep the main menu narrow and surface saved failures without probing services.
menu_domain_summary() {
    local domain="$1" kind endpoints state
    kind="$(ep_get "$domain" TYPE)"
    if [[ "$kind" == runtime ]]; then
        kind="$(ep_get "$domain" KIND)"
    fi
    endpoints="$(ep_versions "$domain" | sed 's/^root$/domain root/' | tr '\n' ' ')"
    state="$(ep_publication "$domain")"
    if [[ -n "$(ep_state_get "$domain" LAST_ERROR)" || -n "$(ep_state_get "$domain" CLOUDFLARE_ERROR)" ]]; then
        state="$state; needs attention"
    elif [[ "$(ep_state_get "$domain" GOLIVE_VERIFICATION)" == pending ]]; then
        state="$state; public check pending"
    fi
    printf '%s | %s | %s | %s\n' "$kind" "$state" "$(ep_get "$domain" ACCESS_MODE)" "$endpoints"
}

menu_overview() {
    local domain count=0 lines=""
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        count=$((count + 1))
        lines="$lines$domain"$'\n'"  $(menu_domain_summary "$domain")"$'\n'
    done < <(ep_list)
    if (( count == 0 )); then
        printf 'No domains yet. Deploy one to begin.\n'
    else
        printf '%s domain(s)\n%s' "$count" "$lines"
    fi
}

menu_endpoints() {
    local domain
    local -a items=()
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        items+=("$domain" "$(menu_domain_summary "$domain")")
    done < <(ep_list)
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Domains" "No domains are deployed yet."; return 0; }
    domain="$(ui_menu "Domains" "Choose a domain" "${items[@]}")" || return 0
    menu_endpoint "$domain"
}

menu_endpoint() {
    local domain="$1" choice out type_text certificate_label
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    type_text="$EP_TYPE"
    [[ -z "$EP_KIND" || "$EP_KIND" == "$EP_TYPE" ]] || type_text="$EP_TYPE $EP_KIND"
    while true; do
        local -a extra=() golive=()
        mapfile -t extra < <("type_${EP_TYPE}_menu_items")
        if ep_is_live "$domain"; then
            golive=(stage "Stage again: stop taking over this name (for rolling back; DNS is not changed)")
        else
            golive=(golive "Go live: certificate, DNS, HTTPS (this domain is staged)")
        fi
        certificate_label='Certificate: status, issue, renew'
        if nginx_external_tls; then
            certificate_label='TLS certificate: managed by the external proxy'
            if ! ep_is_live "$domain"; then
                golive=(golive 'Go live: HTTP origin, Cloudflare DNS and public HTTPS verification')
            fi
        fi
        choice="$(ui_menu "$domain" "$type_text · endpoints: $(pages_endpoints "$domain" | sed "s/^$GB_ROOT_LABEL\$/the domain root/" | tr '\n' ' ')· access: $(ep_get "$domain" ACCESS_MODE) · $(ep_publication "$domain")" \
            status "Status and health" \
            verify "Verify this server end to end (service, nginx, TLS)" \
            "${golive[@]+"${golive[@]}"}" \
            pages "Pages and OpenAPI: documentation pages, icons, versions.json" \
            logs "Logs" \
            access "Access mode (open, metered, token only)" \
            limits "Limits for anonymous callers" \
            tokens "Bearer tokens" \
            certificate "$certificate_label" \
            cloudflare "Cloudflare settings for this domain" \
            "${extra[@]}" \
            apply "Re-apply configuration" \
            remove "Remove this domain" \
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
            pages) pages_menu "$domain" ;;
            certificate)
                if nginx_external_tls; then
                    ui_msg 'External TLS' "The reverse proxy manages the certificate and renewal for $domain. nginx serves the HTTP origin. Configure the certificate in OPNsense HAProxy, keep Cloudflare Full (strict), then use Verify to check the public HTTPS route."
                else
                    certs_menu "$domain"
                fi ;;
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
            app "Application log (runtime domains)" \
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
    choice="$(ui_menu "Deploy" "What kind of domain?" \
        static "Static files synced from git repositories (one per endpoint)" \
        runtime "Runtime service (query or search) on the librarian" \
        back "Back")" || return 0
    case "$choice" in
        static) endpoint_source_type static; type_static_deploy_interactive ;;
        runtime) endpoint_source_type runtime; type_runtime_deploy_interactive ;;
    esac
}

menu_update() {
    local state commit dirty text apply_label='Update all domains from the current checkout'
    if gb_is_docker; then
        text="$(update_image_status)\nNew image releases apply automatically after startup. Use this action to retry or reapply the installed release. Image replacement is done from the Docker host."
        apply_label='Update all domains from the current image'
    else
        state="$(update_repo_state)"
        commit="${state%%$'\n'*}"
        dirty="${state#*$'\n'}"
        text="Checkout: $GB_REPO_DIR at $commit"
        [[ -n "$dirty" ]] && text="$text (local modifications present)"
    fi
    local choice
    choice="$(ui_menu "Update" "$text" \
        apply "$apply_label" \
        back "Back")" || return 0
    case "$choice" in
        apply) ui_run "Update all" update_system || true ;;
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
    choice="$(ui_menu "Logs" "Canonical history: up to $(gb_global TELEMETRY_MAX_GIB 10) GiB and $(gb_global TELEMETRY_RETENTION_DAYS 180) days. The oldest data is pruned first." \
        view "View a domain's logs" \
        rotate "Rotate now (files above the size limit)" \
        force "Force rotation of every log now" \
        retention "Change retention" \
        reset "Start a fresh traffic history" \
        back "Back")" || return 0
    case "$choice" in
        view)
            domain="$(menu_pick_domain)" || return 0
            menu_endpoint_logs "$domain" ;;
        rotate) ui_run "Rotate" logs_rotate_now ;;
        force) ui_run "Force rotation" logs_rotate_now ;;
        retention) menu_settings_retention ;;
        reset)
            ui_yesno "Reset traffic history" "Discard all canonical requests, events and metric history and start collecting from now? Raw logs, authentication and settings are retained." no || return 0
            ui_run "Reset traffic history" logs_reset_history --discard-history ;;
    esac
}

menu_pick_domain() {
    local domain
    local -a items=()
    while read -r domain; do [[ -n "$domain" ]] && items+=("$domain" "$(ep_get "$domain" TYPE)"); done < <(ep_list)
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Domains" "No domains yet."; return 1; }
    ui_menu "Domains" "Choose a domain" "${items[@]}"
}

# Check the whole edit before prompting or changing any configuration file.
menu_settings_editable() {
    local file="$1" key locked=""
    shift
    for key in "$@"; do
        if gb_environment_managed "$file" "$key"; then
            locked="${locked}GETBIBLE_$key\n"
        fi
    done
    [[ -n "$locked" ]] || return 0
    ui_msg 'Environment settings' "These settings are controlled by the deployment environment:\n\n$locked\nChange the environment and recreate the container to change them. No settings were saved here."
    return 1
}

# Call only after collecting every input. Validate the complete set first so a
# cancelled/invalid dialog never leaves a partly edited defaults form behind.
menu_settings_save() {
    local title="$1" key value
    shift
    local -a pairs=("$@") keys=()
    while (( $# > 0 )); do
        key="$1"; value="$2"; shift 2
        keys+=("$key")
        if ! gb_setting_validate "$key" "$value"; then
            ui_msg "$title" "Invalid value for $key. No settings were saved."
            return 1
        fi
    done
    menu_settings_editable "$GB_GLOBAL_CONF" "${keys[@]}" || return 1
    set -- "${pairs[@]}"
    while (( $# > 0 )); do
        key="$1"; value="$2"; shift 2
        if ! gb_global_set "$key" "$value"; then
            ui_msg "$title" "Could not save $key. Check the effective configuration before retrying; any earlier successful settings in this operation remain saved."
            return 1
        fi
    done
}

menu_settings() {
    local choice certmethod_label certbot_label addresses_label
    while true; do
        certmethod_label='Certificate validation: automatic, http, or dns-cloudflare'
        certbot_label="Let's Encrypt contact email"
        addresses_label='Public addresses used for DNS records (empty: detected)'
        if nginx_external_tls; then
            certmethod_label='Certificate validation: managed by the external proxy'
            certbot_label='Certificate contact: managed by the external proxy'
            addresses_label='Firewall WAN addresses used for Cloudflare DNS records'
        elif gb_is_docker; then
            addresses_label='Explicit public origin addresses used for DNS records'
        fi
        choice="$(ui_menu "Settings" "$GB_ETC" \
            deployment "Deployment mode, proxy, environment and memory budget" \
            telegram "Telegram notifications" \
            cloudflare "Cloudflare API token" \
            icons "Icons for all domains: favicon $(favicon_status_text | sed 's/^System favicon: //; s/^the repository icon .*/from the repository/'), logo $(logo_status_text | sed 's/^System logo: //; s/^the repository icons .*/from the repository/')" \
            defaults "Defaults for new domains (access, limits, caching, schedule)" \
            retention "Log retention" \
            deploymode "New domains: go live at once, or stage them for a later go-live" \
            certmethod "$certmethod_label" \
            certbot "$certbot_label" \
            addresses "$addresses_label" \
            hsts "HSTS includeSubDomains" \
            back "Back")" || return 0
        case "$choice" in
            deployment) gb_settings_menu ;;
            telegram) menu_settings_telegram ;;
            cloudflare)
                menu_settings_editable "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN || continue
                if [[ "$(gb_global CLOUDFLARE_ENABLED false)" != true ]]; then
                    menu_settings_editable "$GB_GLOBAL_CONF" CLOUDFLARE_ENABLED || continue
                fi
                cloudflare_configure || true ;;
            icons) menu_settings_icons ;;
            defaults) menu_settings_defaults ;;
            retention) menu_settings_retention ;;
            deploymode) menu_settings_deploy_mode ;;
            certmethod) menu_settings_cert_method ;;
            addresses) menu_settings_addresses ;;
            certbot)
                local email
                if nginx_external_tls; then
                    ui_msg 'External TLS' 'Certificate contact, issuance and renewal are configured on the reverse proxy. This container does not request a local certificate in external TLS mode.'
                    continue
                fi
                menu_settings_editable "$GB_GLOBAL_CONF" CERTBOT_EMAIL || continue
                email="$(ui_input "Let's Encrypt" "Contact email" "$(gb_global CERTBOT_EMAIL)")" || continue
                certs_valid_email "$email" || { ui_msg "Let's Encrypt" "'$email' is not a valid email address."; continue; }
                menu_settings_save "Let's Encrypt" CERTBOT_EMAIL "$email" || continue ;;
            hsts)
                local hsts=false answer_status
                menu_settings_editable "$GB_GLOBAL_CONF" HSTS_INCLUDE_SUBDOMAINS || continue
                if ui_yesno "HSTS" "Send includeSubDomains with Strict-Transport-Security? Only when every subdomain of every endpoint is HTTPS." "$([[ "$(gb_global HSTS_INCLUDE_SUBDOMAINS false)" == true ]] && echo yes || echo no)"; then
                    hsts=true
                else
                    answer_status=$?
                    (( answer_status == 1 )) || continue
                fi
                menu_settings_save HSTS HSTS_INCLUDE_SUBDOMAINS "$hsts" || continue
                ui_msg "HSTS" "Saved. Run Update to re-render every domain." ;;
            back) return 0 ;;
        esac
    done
}

menu_settings_deploy_mode() {
    local current mode
    menu_settings_editable "$GB_GLOBAL_CONF" DEFAULT_DEPLOY_MODE || return 0
    current="$(gb_global DEFAULT_DEPLOY_MODE live)"
    mode="$(ui_radiolist "New domains" "What should a newly deployed domain do by default? The deploy walkthrough still asks each time.\n\nStage them while building a replacement server: everything is installed, but no certificate is requested and DNS is untouched until you choose 'Go live' per domain." \
        live "Go live at once: activate the origin and configured public route" "$([[ "$current" == live ]] && echo on || echo off)" \
        staged "Stage: prepare everything, go live later per domain" "$([[ "$current" == staged ]] && echo on || echo off)")" || return 0
    menu_settings_save 'New domains' DEFAULT_DEPLOY_MODE "$mode" || return 0
    ui_msg "New domains" "New domains are $mode by default. Existing domains are not affected."
}

# The icons every domain serves unless it has its own: the favicon at
# /favicon.ico and the logo on the generated pages. The repository's icons
# (img/) apply until they are replaced here.
menu_settings_icons() {
    local choice file
    choice="$(ui_menu "Icons" "$(favicon_status_text)\n$(logo_status_text)\n\nEvery domain serves the favicon at /favicon.ico and shows the logo at the top of its generated pages (with the repository's logo, also the small icon at their foot), unless the domain has icons of its own (Domain > Pages and OpenAPI)." \
        favicon-file "Favicon: a file from this server (.ico, .png, .svg or .gif)" \
        favicon-default "Favicon: the repository's icon (img/$GB_ICON_FAVICON)" \
        favicon-none "Favicon: none (domains without their own answer 404)" \
        logo-file "Logo: a file from this server (.png, .jpg, .svg, .gif or .webp)" \
        logo-default "Logo: the repository's icons (img/$GB_ICON_LOGO and companions)" \
        logo-none "Logo: none (the pages show no images)" \
        back "Back")" || return 0
    case "$choice" in
        back) return 0 ;;
        favicon-file)
            file="$(ui_input "Favicon" "Path of the favicon file on this server" "")" || return 0
            [[ -f "$file" ]] || { ui_msg "Invalid" "No such file: $file"; return 0; }
            pages_mime_for "$file" >/dev/null || { ui_msg "Invalid" "$GB_FAVICON_TYPES_TEXT"; return 0; }
            ui_run "System favicon" favicon_set_system "$file" || return 0 ;;
        favicon-default) ui_run "System favicon" favicon_set_system default || return 0 ;;
        favicon-none)
            ui_yesno "Favicon" "Switch the system favicon off? Domains without a favicon of their own then answer 404 at /favicon.ico." no || return 0
            ui_run "System favicon" favicon_set_system none || return 0 ;;
        logo-file)
            file="$(ui_input "Logo" "Path of the logo file on this server" "")" || return 0
            [[ -f "$file" ]] || { ui_msg "Invalid" "No such file: $file"; return 0; }
            pages_logo_ext "$file" >/dev/null || { ui_msg "Invalid" "$GB_LOGO_TYPES_TEXT"; return 0; }
            ui_run "System logo" logo_set_system "$file" || return 0 ;;
        logo-default) ui_run "System logo" logo_set_system default || return 0 ;;
        logo-none)
            ui_yesno "Logo" "Switch the system logo off? The generated pages of domains without a logo of their own then show no images." no || return 0
            ui_run "System logo" logo_set_system none || return 0 ;;
    esac
    if ui_yesno "Publish" "Publish the change to every domain now? (The same as Update all domains; it can also wait for the next update.)" yes; then
        ui_run "Publish icons" endpoint_apply_all || true
    fi
}

menu_settings_cert_method() {
    local current method
    if nginx_external_tls; then
        ui_msg 'External TLS' 'Certificate issuance and renewal belong to the reverse proxy. Configure them in OPNsense HAProxy. This container serves HTTP and verifies the public HTTPS route; it does not run local certificate validation in external TLS mode.'
        return 0
    fi
    menu_settings_editable "$GB_GLOBAL_CONF" CERT_METHOD || return 0
    current="$(gb_global CERT_METHOD auto)"
    method="$(ui_radiolist "Certificate validation" "How Let's Encrypt validates a domain when a certificate is requested.\n\nDNS-01 through Cloudflare needs the certbot-dns-cloudflare plugin (System > Install dependencies) and the Cloudflare API token, and works before DNS points at this server: the zero-downtime path for a new server." \
        auto "Automatic: dns-cloudflare when available, otherwise http" "$([[ "$current" == auto ]] && echo on || echo off)" \
        http "HTTP-01: DNS must already route the name to this server" "$([[ "$current" == http ]] && echo on || echo off)" \
        dns-cloudflare "DNS-01 through the Cloudflare API token" "$([[ "$current" == dns-cloudflare ]] && echo on || echo off)")" || return 0
    menu_settings_save 'Certificate validation' CERT_METHOD "$method" || return 0
    ui_msg "Certificate validation" "Certificates are validated with: $method. 'Go live' and 'Issue certificate' can still choose per request."
}

menu_settings_addresses() {
    local ipv4 ipv6 external=false ipv4_prompt ipv6_prompt note
    menu_settings_editable "$GB_GLOBAL_CONF" SERVER_PUBLIC_IPV4 SERVER_PUBLIC_IPV6 || return 0
    ipv4_prompt="IPv4 address for this server's DNS records (empty: detected through api.ipify.org)"
    ipv6_prompt="IPv6 address for DNS records (empty: first global address found; none: remove this hostname's AAAA records)"
    if nginx_external_tls || gb_is_docker; then
        external=true
        ipv4_prompt="Firewall WAN IPv4 reachable by Cloudflare (not the Docker/LAN address; empty only when using an explicit IPv6 origin)"
        ipv6_prompt="Firewall WAN IPv6 reachable by Cloudflare (none: remove this hostname's AAAA records; empty: leave existing AAAA records unchanged)"
    fi
    ipv4="$(ui_input 'Public addresses' "$ipv4_prompt" "$(gb_global SERVER_PUBLIC_IPV4)")" || return 0
    ipv6="$(ui_input 'Public addresses' "$ipv6_prompt" "$(gb_global SERVER_PUBLIC_IPV6)")" || return 0
    if [[ "$external" == true && -z "$ipv4" && ( -z "$ipv6" || "$ipv6" == none ) ]]; then
        ui_msg 'Public addresses' 'Set at least one explicit firewall WAN address. Docker/external TLS cannot discover the correct public origin from inside the container. No settings were saved.'
        return 0
    fi
    menu_settings_save 'Public addresses' SERVER_PUBLIC_IPV4 "$ipv4" SERVER_PUBLIC_IPV6 "$ipv6" || return 0
    if [[ "$external" == true ]]; then
        note="IPv4 ${ipv4:-unchanged}, IPv6 ${ipv6:-unchanged}. No automatic address discovery is used."
    else
        note="IPv4 ${ipv4:-detected}, IPv6 ${ipv6:-detected}."
    fi
    ui_msg 'Public addresses' "Saved: $note\nGo live and Cloudflare apply use these settings; none explicitly disables IPv6 for the selected hostname."
}

menu_settings_telegram() {
    local choice
    choice="$(ui_menu "Telegram" "Enabled: $(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)" \
        configure "Enable or change bot token and chat" \
        test "Send a test message" \
        disable "Disable notifications" \
        back "Back")" || return 0
    case "$choice" in
        configure)
            menu_settings_editable "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID || return 0
            tg_configure || true ;;
        test) tg_test ;;
        disable)
            menu_settings_editable "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED || return 0
            if cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false; then
                ui_msg 'Telegram' 'Disabled.'
            else
                ui_msg 'Telegram' 'Notifications could not be disabled. Check the effective configuration before retrying.'
            fi ;;
    esac
}

menu_settings_defaults() {
    local key label value
    local -a values=()
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
        if gb_environment_managed "$GB_GLOBAL_CONF" "$key"; then
            ui_msg 'Environment setting' "$key is controlled by GETBIBLE_$key. Change it in the deployment environment."
            continue
        fi
        value="$(ui_input "Defaults" "$label" "$(gb_global "$key")")" || return 0
        values+=("$key" "$value")
    done
    (( ${#values[@]} > 0 )) || return 0
    menu_settings_save Defaults "${values[@]}" || return 0
    ui_msg "Defaults" "Saved. Existing domains keep their own values."
}

menu_settings_retention() {
    local size keep
    menu_settings_editable "$GB_GLOBAL_CONF" TELEMETRY_MAX_GIB TELEMETRY_RETENTION_DAYS || return 0
    size="$(ui_input "Traffic retention" "Maximum local traffic history size in GiB" "$(gb_global TELEMETRY_MAX_GIB 10)")" || return 0
    keep="$(ui_input "Traffic retention" "Maximum traffic history age in days (0: size limit only)" "$(gb_global TELEMETRY_RETENTION_DAYS 180)")" || return 0
    menu_settings_save 'Traffic retention' TELEMETRY_MAX_GIB "$size" TELEMETRY_RETENTION_DAYS "$keep" || return 0
    if ! infrastructure_environment || ! logs_render_rotation; then
        ui_msg 'Traffic retention' 'Settings were saved, but collector configuration could not be applied. Check the reported error before retrying.'
        return 0
    fi
    ui_msg "Traffic retention" "Traffic history is limited to $size GiB and $keep days. Oldest records are pruned first."
}

menu_system() {
    local choice out deps_label='Install dependencies (apt)'
    gb_is_docker && deps_label='Image dependencies: update through the Docker host'
    while true; do
        choice="$(ui_menu "System" "$(hostname -f 2>/dev/null || hostname)" \
            doctor "Check this host" \
            deps "$deps_label" \
            cloudflare "Cloudflare origin tools (IP ranges, origin pulls)" \
            selftest "Run the test suite" \
            back "Back")" || return 0
        out="$(gb_tmpdir)/system.$$"
        case "$choice" in
            doctor) doctor_run > "$out" 2>&1 || true; ui_textbox "Host check" "$out" ;;
            deps)
                if gb_is_docker; then
                    ui_msg 'Image dependencies' 'Dependencies are installed when the image is built. To receive updates, select the image tag in .env on the Docker host, then run:\n\ndocker compose pull\ndocker compose up -d\n\nThis replaces the container while retaining its persistent mounts.'
                else
                    ui_run "Install dependencies" doctor_install_deps || true
                fi ;;
            cloudflare) cloudflare_system_menu ;;
            selftest) ui_run "Self-test" "$GB_REPO_DIR/tests/run.sh" ;;
            back) return 0 ;;
        esac
    done
}
