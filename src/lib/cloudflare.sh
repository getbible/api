#!/usr/bin/env bash
# Cloudflare: one API token, per-domain proxy mode and rules, origin-side
# real IP restoration and authenticated origin pulls.

[[ -n "${GB_CLOUDFLARE_LOADED:-}" ]] && return 0
GB_CLOUDFLARE_LOADED=1

cf_token() { cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN; }
cf_enabled() { [[ -n "$(cf_token)" ]]; }
cf_real_ip_file() { printf '%s/cloudflare-real-ip.conf\n' "$GB_NGINX_GB"; }
cf_origin_ca_file() { printf '%s/cloudflare-origin-pull-ca.pem\n' "$GB_NGINX_GB"; }

cf_cmd() {
    CLOUDFLARE_API_TOKEN="$(cf_token)" "$GB_PYTHON" "$GB_TOOLS/getbible-cloudflare" "$@"
}

# Keep CLI JSON for scripts; menus and operation logs use readable reports.
cf_human() { cf_cmd --human "$@"; }

cloudflare_configure() {
    local token result
    token="$(ui_password "Cloudflare" "API token (Zone:Read, DNS:Edit, Zone Settings:Edit, Zone WAF:Edit, Cache Purge:Purge, SSL and Certificates:Edit). Empty keeps the stored one.")" || return 1
    if [[ -n "$token" ]]; then
        cfg_set "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN "$token"
        chmod 0600 "$GB_CLOUDFLARE_CONF" 2>/dev/null || true
        # Keep certbot's DNS-01 renewal credentials current when the token rotates.
        if declare -F certs_cloudflare_credentials_write >/dev/null; then
            certs_cloudflare_credentials_write || {
                ui_msg "Cloudflare" "The token was saved, but Certbot's DNS-01 credentials could not be updated. Check the file permissions and save the token again before certificate renewal."
                tg_notify fail "Cloudflare token update incomplete" "Certbot's DNS-01 renewal credentials could not be updated."
                return 1
            }
        fi
    fi
    if result="$(cf_human verify 2>&1)"; then
        gb_global_set CLOUDFLARE_ENABLED true
        ui_msg "Cloudflare" "Token verified:\n$result"
    else
        ui_msg "Cloudflare" "Token verification failed:\n$result"
        return 1
    fi
}

# Public addresses of this server, from the global config or detected.
cf_public_ipv4() {
    local ip
    ip="$(gb_global SERVER_PUBLIC_IPV4)"
    [[ -n "$ip" ]] || ip="$(curl --silent --max-time 10 -4 https://api.ipify.org 2>/dev/null || true)"
    printf '%s\n' "$ip"
}

cf_public_ipv6() {
    local ip
    ip="$(gb_global SERVER_PUBLIC_IPV6)"
    [[ -n "$ip" ]] || ip="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | grep -v '^fd\|^fc' | head -1 || true)"
    printf '%s\n' "$ip"
}

# cloudflare_apply DOMAIN: make DNS and rules match the endpoint's settings.
# Must run before publishing a token-only endpoint. A prior public response
# must not remain retrievable at the edge after origin authentication changes.
cloudflare_protect_access() {
    local domain="$1"
    [[ "$(ep_get "$domain" ACCESS_MODE metered)" == token ]] || return 0
    [[ "$(ep_get "$domain" CLOUDFLARE_MODE off)" == proxied ]] || return 0
    [[ "$(ep_state_get "$domain" EDGE_CACHE_POLICY)" == protected-v1 ]] && return 0
    if ! cf_enabled; then
        gb_warn "Cannot secure cached responses for $domain without the Cloudflare token (including Cache Purge permission)."
        return 1
    fi
    gb_step "Disable shared caching and purge formerly public responses for $domain"
    cf_human protect-access "$domain" >&2 || return 1
    ep_state_set "$domain" EDGE_CACHE_POLICY protected-v1
    tg_notify info "Protected cache policy: $domain" "Cloudflare caching disabled; previously cached host content purged."
}

cloudflare_apply() {
    local domain="$1" mode cache ipv4 ipv6 proxied
    # A staged endpoint must not take over its name: the records still point
    # at whatever serves it today. Go-live applies DNS and rules.
    if ! ep_is_live "$domain"; then
        gb_log "$domain is staged; Cloudflare DNS and rules are applied when it goes live."
        return 0
    fi
    mode="$(ep_get "$domain" CLOUDFLARE_MODE off)"
    cache="$(ep_get "$domain" CLOUDFLARE_CACHE bypass)"
    if [[ "$(ep_get "$domain" ACCESS_MODE metered)" == token ]]; then
        cache=bypass
        cloudflare_protect_access "$domain" || return 1
    fi
    [[ "$mode" == off ]] && return 0
    cf_enabled || { gb_warn "No Cloudflare token stored; skipping Cloudflare for $domain."; return 0; }
    ipv4="$(cf_public_ipv4)"
    ipv6="$(cf_public_ipv6)"
    proxied=false
    [[ "$mode" == proxied ]] && proxied=true
    gb_step "Cloudflare DNS for $domain (proxied: $proxied)"
    local -a args=(dns "$domain" --proxied "$proxied")
    [[ -n "$ipv4" ]] && args+=(--ipv4 "$ipv4")
    [[ -n "$ipv6" ]] && args+=(--ipv6 "$ipv6")
    cf_human "${args[@]}" >&2 || return 1
    ep_state_set "$domain" CLOUDFLARE_DNS_AT "$(gb_timestamp)"
    if [[ "$mode" == proxied ]]; then
        gb_step "Cloudflare rules for $domain (cache: $cache)"
        cf_human host-rules "$domain" --cache "$cache" --security api >&2 || return 1
        if [[ "$(ep_get "$domain" ACCESS_MODE metered)" != token ]]; then
            ep_state_set "$domain" EDGE_CACHE_POLICY "public-$cache"
        fi
        cloudflare_refresh_ips || return 1
        if [[ "$(ep_get "$domain" CLOUDFLARE_ORIGIN_PULLS false)" == true ]]; then
            cf_human origin-pulls "$domain" on >&2 || return 1
            cloudflare_install_origin_ca || return 1
        fi
    else
        cf_human host-rules-remove "$domain" >&2 || gb_warn "DNS now routes directly, but some managed Cloudflare rules could not be removed."
    fi
    tg_notify info "Cloudflare updated: $domain" "Mode: $mode, cache: $cache."
}

# The vhost of a live proxied endpoint includes the real-IP ranges and, with
# origin pulls, Cloudflare's client CA. Both are public downloads that need no
# token and change nothing at Cloudflare, so they can be fetched before the
# vhost is rendered: a staged endpoint has neither until it goes live.
cloudflare_ensure_origin_files() {
    local domain="$1"
    [[ "$(ep_get "$domain" CLOUDFLARE_MODE off)" == proxied ]] || return 0
    if [[ ! -f "$(cf_real_ip_file)" ]]; then
        cloudflare_refresh_ips || return 1
    fi
    if [[ "$(ep_get "$domain" CLOUDFLARE_ORIGIN_PULLS false)" == true && ! -f "$(cf_origin_ca_file)" ]]; then
        cloudflare_install_origin_ca || return 1
    fi
}

# Render the real-IP include from Cloudflare's published ranges.
cloudflare_refresh_ips() {
    local json stage ranges
    json="$(cf_cmd ips 2>/dev/null)" || { gb_warn "Could not fetch Cloudflare address ranges."; return 1; }
    ranges="$(printf '%s' "$json" | "$GB_PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(f"set_real_ip_from {r};" for r in d["ipv4"]+d["ipv6"]))')"
    stage="$(gb_tmpdir)/cloudflare-real-ip.conf"
    gb_render "$GB_NGINX_SRC/snippets/cloudflare-real-ip.conf.tmpl" "$stage" "RANGES=$ranges" "REFRESHED=$(gb_timestamp)"
    gb_ensure_dir "$GB_NGINX_GB" 0755
    if [[ -f "$(cf_real_ip_file)" ]] && diff -q <(grep -v REFRESHED "$stage" | grep -v refresh) <(grep -v refresh "$(cf_real_ip_file)") >/dev/null 2>&1; then
        return 0
    fi
    gb_install_file "$stage" "$(cf_real_ip_file)" 0644
    gb_ledger_record "$(cf_real_ip_file)"
    gb_log "Cloudflare address ranges refreshed."
    cloudflare_install_ip_timer
}

cloudflare_refresh_ips_if_enabled() {
    local domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        if [[ "$(ep_get "$domain" CLOUDFLARE_MODE off)" == proxied ]]; then
            cloudflare_refresh_ips && nginx_test && nginx_reload
            return 0
        fi
    done < <(ep_list)
    return 0
}

cloudflare_install_ip_timer() {
    local unit timer
    unit="$(gb_tmpdir)/getbible-cloudflare-ips.service"
    timer="$(gb_tmpdir)/getbible-cloudflare-ips.timer"
    cat > "$unit" <<UNIT
[Unit]
Description=Refresh Cloudflare address ranges for getBible endpoints

[Service]
Type=oneshot
ExecStart=$GB_REPO_DIR/getbible.sh cloudflare refresh-ips --yes
UNIT
    cat > "$timer" <<TIMER
[Unit]
Description=Refresh Cloudflare address ranges daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    sd_install_unit "$unit" getbible-cloudflare-ips.service
    sd_install_unit "$timer" getbible-cloudflare-ips.timer
    sd_daemon_reload
    sd_enable --now getbible-cloudflare-ips.timer
}

cloudflare_install_origin_ca() {
    local stage
    stage="$(gb_tmpdir)/origin-pull-ca.pem"
    cf_cmd origin-ca > "$stage" 2>/dev/null || { gb_warn "Could not download the Cloudflare origin pull CA."; return 1; }
    grep -q 'BEGIN CERTIFICATE' "$stage" || { gb_warn "Downloaded origin pull CA is not a certificate."; return 1; }
    gb_install_file "$stage" "$(cf_origin_ca_file)" 0644
    gb_ledger_record "$(cf_origin_ca_file)"
}

cloudflare_apply_and_render() { cloudflare_apply "$1" && endpoint_apply "$1"; }
cloudflare_refresh_and_reload() { cloudflare_refresh_ips && nginx_test && nginx_reload; }

# The shared certificate is a zone-wide prerequisite, but enforcement is
# selected per nginx vhost. Disabling a domain never disables the shared
# feature for other hosts in the zone.
cloudflare_endpoint_origin_pulls() {
    local domain="$1" enabled="$2"
    [[ "$enabled" == true || "$enabled" == false ]] || return 2
    if [[ "$enabled" == true ]]; then
        if ! cf_human origin-pulls "$domain" on; then
            ep_state_set "$domain" CLOUDFLARE_ERROR "Authenticated origin pulls could not be enabled; the domain setting was kept."
            return 1
        fi
    fi
    ep_set "$domain" CLOUDFLARE_ORIGIN_PULLS "$enabled" || return 1
    tg_notify info "Origin pulls configured: $domain" "Origin certificate requirement: $enabled. Apply the domain to render nginx."
}

# --- menu --------------------------------------------------------------------
cloudflare_endpoint_menu() {
    local domain="$1" choice mode cache pulls
    cf_enabled || { ui_msg "Cloudflare" "Store an API token first: Settings > Cloudflare API token."; return 0; }
    while true; do
        mode="$(ep_get "$domain" CLOUDFLARE_MODE off)"
        cache="$(ep_get "$domain" CLOUDFLARE_CACHE bypass)"
        pulls="$(ep_get "$domain" CLOUDFLARE_ORIGIN_PULLS false)"
        choice="$(ui_menu "Cloudflare: $domain" "mode: $mode · edge cache: $cache · origin pulls: $pulls$(ep_is_live "$domain" || printf ' · staged: DNS and rules are applied at go-live')" \
            mode "Mode: off (not managed), dns (pass-through), proxied (orange cloud)" \
            cache "Edge caching: bypass (origin logs complete) or respect origin Cache-Control" \
            pulls "Authenticated origin pulls (only Cloudflare can reach the origin)" \
            apply "Apply DNS and rules now" \
            show "Show DNS records" \
            back "Back")" || return 0
        case "$choice" in
            mode)
                mode="$(ui_radiolist "Cloudflare mode" "How should Cloudflare treat $domain?" \
                    off "Not managed by getbible.sh" "$([[ "$mode" == off ]] && echo on || echo off)" \
                    dns "DNS only: traffic reaches the origin directly" "$([[ "$mode" == dns ]] && echo on || echo off)" \
                    proxied "Proxied: DDoS shield, TLS at the edge, API-safe security profile" "$([[ "$mode" == proxied ]] && echo on || echo off)")" || continue
                ep_set "$domain" CLOUDFLARE_MODE "$mode" ;;
            cache)
                if [[ "$(ep_get "$domain" ACCESS_MODE metered)" == token ]]; then
                    ui_msg "Edge cache" "Token-only domains always bypass shared caches."
                    continue
                fi
                cache="$(ui_radiolist "Edge cache" "Cache responses at Cloudflare's edge?" \
                    bypass "Bypass: every request reaches the origin and its logs" "$([[ "$cache" == bypass ]] && echo on || echo off)" \
                    respect "Respect origin: cache per Cache-Control, origin logs see only misses" "$([[ "$cache" == respect ]] && echo on || echo off)")" || continue
                ep_set "$domain" CLOUDFLARE_CACHE "$cache" ;;
            pulls)
                if ui_yesno "Origin pulls" "Require Cloudflare's client certificate on this domain? Enabling also enables Cloudflare's shared certificate for the zone; only selected nginx domains require it. Disabling this domain leaves the shared feature enabled for other hosts. Apply the domain afterwards. Only meaningful in proxied mode; direct origin HTTPS will stop working." "$([[ "$pulls" == true ]] && echo yes || echo no)"; then
                    ui_run "Enable origin pulls" cloudflare_endpoint_origin_pulls "$domain" true || true
                else
                    ui_run "Disable origin requirement" cloudflare_endpoint_origin_pulls "$domain" false || true
                fi ;;
            apply) ui_run "Cloudflare apply" cloudflare_apply_and_render "$domain" ;;
            show) ui_run "DNS records" cf_human dns-show "$domain" ;;
            back) return 0 ;;
        esac
    done
}

cloudflare_system_menu() {
    local choice
    choice="$(ui_menu "Cloudflare origin tools" "Token: $(cf_enabled && echo stored || echo missing)" \
        ips "Refresh Cloudflare address ranges now" \
        botfight "Turn Bot Fight Mode off for the whole zone (it blocks API clients)" \
        settings "Apply zone-wide settings: HTTP/3, brotli, TLS 1.2 minimum, always HTTPS" \
        back "Back")" || return 0
    case "$choice" in
        ips) ui_run "Refresh ranges" cloudflare_refresh_and_reload ;;
        botfight)
            local domain
            domain="$(ui_input "Zone" "A domain inside the zone" "$(ep_list | head -1)")" || return 0
            ui_run "Bot Fight Mode off" cf_human bot-fight "$domain" off ;;
        settings)
            local domain
            domain="$(ui_input "Zone" "A domain inside the zone" "$(ep_list | head -1)")" || return 0
            ui_run "Zone settings" cf_human zone-settings "$domain" --http3 on --brotli on --min-tls 1.2 --always-https on --tls13 on ;;
    esac
}

cloudflare_cli() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        token) cloudflare_configure ;;
        verify) cf_cmd verify ;;
        apply) cloudflare_apply "${1:?domain}" ;;
        mode)
            local domain="${1:?domain}" mode="${2:?off|dns|proxied}"
            [[ "$mode" =~ ^(off|dns|proxied)$ ]] || gb_die "mode is off, dns or proxied"
            ep_set "$domain" CLOUDFLARE_MODE "$mode"
            cloudflare_apply "$domain"
            endpoint_apply "$domain" ;;
        cache)
            local domain="${1:?domain}" cache="${2:?bypass|respect}"
            [[ "$cache" =~ ^(bypass|respect)$ ]] || gb_die "cache is bypass or respect"
            [[ "$cache" != respect || "$(ep_get "$domain" ACCESS_MODE metered)" != token ]] || gb_die "Token-only domains must bypass shared caches."
            ep_set "$domain" CLOUDFLARE_CACHE "$cache"
            cloudflare_apply "$domain" ;;
        refresh-ips) cloudflare_refresh_and_reload ;;
        dns) cf_cmd dns-show "${1:?domain}" ;;
        zone) cf_cmd zone "${1:?domain}" ;;
        bot-fight) cf_cmd bot-fight "${1:?domain}" "${2:?on|off}" ;;
        origin-pulls) cf_cmd origin-pulls "${1:?domain}" "${2:?on|off}" ;;
        *)
            cat <<'HELP'
getbible.sh cloudflare <command>
  token                       store and verify the API token
  verify                      verify the stored token
  mode DOMAIN off|dns|proxied set how Cloudflare treats the domain and apply
  cache DOMAIN bypass|respect edge caching for a proxied domain
  apply DOMAIN                apply DNS and rules for the domain
  refresh-ips                 refresh the real-IP address ranges
  dns DOMAIN                  show DNS records
  zone DOMAIN                 show the zone and plan
  bot-fight DOMAIN on|off     zone-wide Bot Fight Mode
  origin-pulls DOMAIN on|off  zone-wide authenticated origin pulls
HELP
            ;;
    esac
}
