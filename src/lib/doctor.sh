#!/usr/bin/env bash
# Host checks and dependency installation.

[[ -n "${GB_DOCTOR_LOADED:-}" ]] && return 0
GB_DOCTOR_LOADED=1

GB_APT_PACKAGES=(nginx certbot python3 python3-venv python3-pip whiptail rsync git openssh-client curl logrotate acl ca-certificates openssl xz-utils tar util-linux)

doctor_check() {
    # doctor_check LABEL STATUS DETAIL
    printf '  %-28s %-6s %s\n' "$1" "$2" "$3"
}

doctor_run() {
    local tool
    printf 'getBible API host check\n\n'
    printf 'Host: %s\nPlatform: %s\n\n' "$(hostname -f 2>/dev/null || hostname)" "$(platform_report)"
    printf 'Default managed Python: %s (selected on first deployment)\n' "$(py_resolve_version auto)"
    for tool in nginx certbot python3 whiptail rsync git ssh-keygen curl logrotate flock setfacl openssl tar sha256sum systemctl; do
        if gb_have "$tool"; then doctor_check "$tool" ok "$(command -v "$tool")"; else doctor_check "$tool" MISS "install with: getbible.sh install-deps"; fi
    done
    if gb_have python3; then
        python3 -c 'import venv' 2>/dev/null && doctor_check "python3 venv" ok "$(python3 --version)" || doctor_check "python3 venv" MISS "python3-venv package"
    fi
    if [[ "$(uname -s)" != Linux || ! -d /run/systemd/system ]]; then
        doctor_check "service manager" WARN "Live deployment requires Linux booted with systemd; offline rendering remains available."
    fi
    nginx_detect
    if [[ "$NG_AVAILABLE" == true ]]; then
        doctor_check "nginx version" ok "$NG_VERSION (http2: $([[ "$NG_HTTP2_NATIVE" == true ]] && echo 'http2 on' || echo 'listen http2'), brotli: $NG_BROTLI, ipv6: $NG_IPV6)"
        if [[ -z "$GB_PREFIX" ]] && "$GB_NGINX_BIN" -t >/dev/null 2>&1; then doctor_check "nginx configuration" ok "nginx -t passes"; else doctor_check "nginx configuration" WARN "nginx -t fails or nginx missing"; fi
        sd_is_active nginx && doctor_check "nginx service" ok active || doctor_check "nginx service" WARN "not active"
    fi
    if ! gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        doctor_check "certificate checks" info "run as root to inspect the certbot plugins and renewals"
    elif certs_can_run; then
        if certs_dns_cloudflare_installed; then
            doctor_check "certbot dns-cloudflare" ok "DNS-01 available: certificates can be issued before DNS points here"
        else
            doctor_check "certbot dns-cloudflare" info "plugin not installed (python3-certbot-dns-cloudflare); only HTTP-01 is possible"
        fi
        doctor_check_dns_renewals
    fi
    if sd_available; then
        sd_is_active certbot.timer && doctor_check "certbot.timer" ok active || doctor_check "certbot.timer" WARN "not active (snap certbot uses its own timer)"
        sd_is_active getbible-logrotate.timer && doctor_check "log rotation timer" ok active || doctor_check "log rotation timer" WARN "not active; run any deploy or update"
    fi
    gb_group_exists "$GB_READERS_GROUP" && doctor_check "readers group" ok "$GB_READERS_GROUP" || doctor_check "readers group" WARN "created on first deploy"
    if [[ -x "$GB_LIBEXEC/getbible-notify" ]]; then doctor_check "telegram helper" ok "$GB_LIBEXEC/getbible-notify"; else doctor_check "telegram helper" WARN "not installed yet"; fi
    tg_enabled && doctor_check "telegram" ok enabled || doctor_check "telegram" info disabled
    [[ -n "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" ]] && doctor_check "cloudflare token" ok stored || doctor_check "cloudflare token" info "not stored"
    printf '\nDisk: %s\n' "$(df -h / 2>/dev/null | awk 'NR==2 {print $4" free of "$2" ("$5" used)"}')"
    printf 'Endpoints: %s\n' "$(ep_list | tr '\n' ' ')"
    printf 'Staged (not live): %s\n' "$(golive_staged_domains | tr '\n' ' ')"
    printf 'Defaults: new endpoints %s, certificate validation %s\n' "$(gb_global DEFAULT_DEPLOY_MODE live)" "$(gb_global CERT_METHOD auto)"
    printf '\nListening: %s\n' "$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(80|443)$' | sort -u | tr '\n' ' ')"
}

# Certificates issued here, or copied from another server, renew through
# what their renewal configuration names: the webroot this tool serves, or
# the DNS-01 credentials file. Anything else (a lineage from `certbot
# --nginx`, say) would edit the rendered vhosts and is better reissued.
doctor_check_dns_renewals() {
    local conf domain authenticator credentials webroot dns_broken="" foreign=""
    for conf in "$GB_LETSENCRYPT"/renewal/*.conf; do
        [[ -f "$conf" ]] || continue
        domain="$(basename "$conf" .conf)"
        ep_exists "$domain" || continue
        authenticator="$(sed -n 's/^authenticator[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)"
        case "$authenticator" in
            dns-cloudflare)
                credentials="$(sed -n 's/^dns_cloudflare_credentials[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)"
                if [[ -z "$credentials" || ! -f "$credentials" ]] || ! certs_dns_cloudflare_installed; then
                    dns_broken="$dns_broken $domain"
                fi ;;
            webroot)
                webroot="$(sed -n 's/^webroot_path[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)"
                [[ "$webroot" == *"$GB_ACME_ROOT"* ]] || foreign="$foreign $domain"
                ;;
            *) foreign="$foreign $domain" ;;
        esac
    done
    if [[ -n "$dns_broken" ]]; then
        doctor_check "DNS-01 renewals" WARN "missing credentials file or plugin for:$dns_broken (store the Cloudflare token under Settings; install python3-certbot-dns-cloudflare)"
    fi
    if [[ -n "$foreign" ]]; then
        doctor_check "certificate renewals" WARN "not issued by this tool:$foreign (renewal would use another method and could edit the rendered vhosts: certbot delete --cert-name DOMAIN, then Endpoint > Certificate > Issue)"
    fi
}

doctor_install_deps() {
    platform_detect
    [[ "$PLATFORM_OS" == Linux ]] || gb_die "Deployment requires Linux; detected $PLATFORM_OS."
    [[ "$PLATFORM_PACKAGE_MANAGER" == apt ]] || gb_die "Detected $PLATFORM_NAME. Install compatible nginx, certbot, systemd and these command-line tools with your package manager: ${GB_APT_PACKAGES[*]}. Then run doctor; managed endpoint Python is independent of the distro."
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would apt-get install ${GB_APT_PACKAGES[*]}"; return 0; }
    gb_step "Installing packages: ${GB_APT_PACKAGES[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${GB_APT_PACKAGES[@]}" || return 1
    if apt-cache show libnginx-mod-http-brotli-static >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-http-brotli-static || true
    fi
    # DNS-01 validation through Cloudflare: lets a staged endpoint or a new
    # server obtain certificates before DNS changes. Best effort: HTTP-01
    # still works without it.
    if apt-cache show python3-certbot-dns-cloudflare >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare \
            || gb_warn "python3-certbot-dns-cloudflare could not be installed; certificates are validated over HTTP-01 only."
    else
        gb_warn "python3-certbot-dns-cloudflare is not available from apt; with snap certbot install the certbot-dns-cloudflare snap for DNS-01."
    fi
    gb_ensure_dir "$GB_ACME_ROOT" 0755
    sd_enable --now nginx || true
    gb_log "Installed host tools. Endpoint Python and packages are installed separately during explicit deployment/update."
}
