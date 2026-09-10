#!/usr/bin/env bash
# Host checks and dependency installation.

[[ -n "${GB_DOCTOR_LOADED:-}" ]] && return 0
GB_DOCTOR_LOADED=1

GB_APT_PACKAGES=(nginx certbot python3 python3-venv python3-pip whiptail rsync git openssh-client curl logrotate acl ca-certificates openssl xz-utils tar util-linux)

doctor_check() {
    # doctor_check LABEL STATUS DETAIL
    printf '  %-28s %-6s %s\n' "$1" "$2" "$3"
}

doctor_required_tools() {
    printf '%s\n' nginx python3 whiptail rsync git ssh-keygen curl logrotate flock setfacl openssl tar sha256sum systemctl
    nginx_external_tls || printf '%s\n' certbot
}

# Image maintenance is a host-side pull/recreate operation. Never install OS
# packages into a running container's disposable writable layer.
doctor_image_dependencies() {
    local tool missing=0 rows=0 bundle catalog version arch build digest url manifest app
    while IFS= read -r tool; do
        if gb_have "$tool"; then doctor_check "$tool" ok "$(command -v "$tool")"
        else doctor_check "$tool" MISS "missing from this image"; missing=1; fi
    done < <(doctor_required_tools)
    bundle="$(py_bundle_root)"
    catalog="$bundle/distributions.lock"
    if [[ ! -s "$catalog" ]]; then
        doctor_check "runtime bundle" MISS "bundled Python catalog is missing"
        missing=1
    else
        while IFS=' ' read -r version arch build digest url; do
            [[ -n "$version" && "$version" != \#* ]] || continue
            rows=$((rows + 1))
            if [[ ! -x "$bundle/python/cpython-$version-$build-$arch-${digest:0:16}/bin/python3" ]]; then
                doctor_check "bundled Python $version" MISS "interpreter is missing"
                missing=1
            fi
            for manifest in "$GB_APPS"/*/manifest.conf; do
                app="$(basename "$(dirname "$manifest")")"
                if [[ ! -s "$bundle/wheels/$version/$app/packages.requirements" || ! -s "$bundle/wheels/$version/$app/.inputs" ]] || \
                    ! compgen -G "$bundle/wheels/$version/$app/*.whl" >/dev/null; then
                    doctor_check "bundled $app $version" MISS "offline dependency bundle is missing"
                    missing=1
                fi
            done
        done < "$catalog"
        if (( rows == 0 )); then
            doctor_check "runtime bundle" MISS "bundled Python catalog has no interpreter entries"
            missing=1
        fi
    fi
    if (( missing != 0 )); then
        gb_warn "This Docker image is incomplete. On the host run 'docker compose pull' and 'docker compose up -d'. If the published image is incomplete, rebuild it through the image workflow. No packages were installed in this container."
        return 1
    fi
    gb_log "Image dependencies are present. OS and manager updates are delivered through a new image; endpoint deployment uses the bundled runtime dependencies."
}

doctor_run() {
    local tool remedy="install with: getbible.sh install-deps" python_version port
    printf 'getBible API host check\n\n'
    printf 'Host: %s\nPlatform: %s\n\n' "$(hostname -f 2>/dev/null || hostname)" "$(platform_report)"
    printf 'Execution mode: %s\nTLS ownership: %s\n' "$(gb_execution_mode)" "$(nginx_tls_mode)"
    if gb_is_docker; then
        remedy="pull/recreate the container on the host; rebuild the image if incomplete"
        if python_version="$(py_resolve_version auto 2>/dev/null)"; then
            printf 'Default bundled Python: %s (offline endpoint deployment)\n' "$python_version"
        else
            doctor_check "runtime bundle" MISS "$remedy"
        fi
    else
        printf 'Default managed Python: %s (selected on first deployment)\n' "$(py_resolve_version auto)"
    fi
    while IFS= read -r tool; do
        if gb_have "$tool"; then doctor_check "$tool" ok "$(command -v "$tool")"; else doctor_check "$tool" MISS "$remedy"; fi
    done < <(doctor_required_tools)
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
    if nginx_external_tls; then
        doctor_check "certificate management" info "external reverse proxy owns issuance and renewal; local certbot is not required"
        if nginx_validate_proxy_settings; then doctor_check "external proxy settings" ok "HTTP port $(nginx_origin_http_port), public HTTPS, configured trusted peers"
        else doctor_check "external proxy settings" WARN "set valid TRUSTED_PROXY_CIDRS and ORIGIN_HTTP_PORT before deployment"; fi
    elif ! gb_is_root && [[ -z "$GB_PREFIX" ]]; then
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
        if ! nginx_external_tls; then
            sd_is_active certbot.timer && doctor_check "certbot.timer" ok active || doctor_check "certbot.timer" WARN "not active; run install-deps to enable automatic certificate renewal"
        fi
        sd_is_active getbible-logrotate.timer && doctor_check "log rotation timer" ok active || doctor_check "log rotation timer" WARN "not active; run any deploy or update"
    fi
    gb_group_exists "$GB_READERS_GROUP" && doctor_check "readers group" ok "$GB_READERS_GROUP" || doctor_check "readers group" WARN "created on first deploy"
    if [[ -x "$GB_LIBEXEC/getbible-notify" ]]; then doctor_check "telegram helper" ok "$GB_LIBEXEC/getbible-notify"; else doctor_check "telegram helper" WARN "not installed yet"; fi
    tg_enabled && doctor_check "telegram" ok enabled || doctor_check "telegram" info disabled
    [[ -n "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" ]] && doctor_check "cloudflare token" ok stored || doctor_check "cloudflare token" info "not stored"
    printf '\nDisk: %s\n' "$(df -h / 2>/dev/null | awk 'NR==2 {print $4" free of "$2" ("$5" used)"}')"
    printf 'Domains: %s\n' "$(ep_list | tr '\n' ' ')"
    printf 'Staged (not live): %s\n' "$(golive_staged_domains | tr '\n' ' ')"
    if nginx_external_tls; then
        printf 'Defaults: new domains %s, certificates managed externally\n' "$(gb_global DEFAULT_DEPLOY_MODE live)"
    else
        printf 'Defaults: new domains %s, certificate validation %s\n' "$(gb_global DEFAULT_DEPLOY_MODE live)" "$(gb_global CERT_METHOD auto)"
    fi
    port="$(nginx_origin_http_port)"
    printf '\nListening: %s\n' "$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ":($port|443)$" | sort -u | tr '\n' ' ')"
}

# Check the recorded renewal settings of registered domains for configuration
# drift: HTTP-01 needs the served webroot; DNS-01 needs its credentials and plugin.
doctor_check_dns_renewals() {
    local conf domain authenticator credentials webroot dns_broken="" webroot_broken="" unexpected=""
    nginx_external_tls && return 0
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
                [[ "${webroot%,}" == "$GB_ACME_ROOT" ]] || webroot_broken="$webroot_broken $domain"
                ;;
            *) unexpected="$unexpected $domain" ;;
        esac
    done
    if [[ -n "$dns_broken" ]]; then
        doctor_check "DNS-01 renewals" WARN "missing credentials file or plugin for:$dns_broken (store the Cloudflare token under Settings; install python3-certbot-dns-cloudflare)"
    fi
    if [[ -n "$webroot_broken" ]]; then
        doctor_check "HTTP-01 renewals" WARN "expected webroot $GB_ACME_ROOT is missing or changed for:$webroot_broken (check the domain's certbot renewal configuration)"
    fi
    if [[ -n "$unexpected" ]]; then
        doctor_check "certificate renewals" WARN "unexpected or missing authenticator for:$unexpected (expected webroot or dns-cloudflare; check the domain's certbot renewal configuration)"
    fi
}

doctor_install_deps() {
    if gb_is_docker; then
        doctor_image_dependencies
        return $?
    fi
    platform_detect
    [[ "$PLATFORM_OS" == Linux ]] || gb_die "Deployment requires Linux; detected $PLATFORM_OS."
    [[ "$PLATFORM_PACKAGE_MANAGER" == apt ]] || gb_die "Detected $PLATFORM_NAME. Install compatible nginx, certbot, systemd and these command-line tools with your package manager: ${GB_APT_PACKAGES[*]}. Then run doctor; managed runtime Python is independent of the distro."
    local package
    local -a packages=()
    for package in "${GB_APT_PACKAGES[@]}"; do
        [[ "$package" != certbot ]] || ! nginx_external_tls || continue
        packages+=("$package")
    done
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would apt-get install ${packages[*]}"; return 0; }
    gb_step "Installing packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || return 1
    if apt-cache show libnginx-mod-http-brotli-static >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-http-brotli-static || true
    fi
    # DNS-01 validation through Cloudflare: lets a staged endpoint or a new
    # server obtain certificates before DNS changes. Best effort: HTTP-01
    # still works without it.
    if ! nginx_external_tls; then
        if apt-cache show python3-certbot-dns-cloudflare >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare \
                || gb_warn "python3-certbot-dns-cloudflare could not be installed; certificates are validated over HTTP-01 only."
        else
            gb_warn "python3-certbot-dns-cloudflare is not available from apt; certificates can still be validated over HTTP-01."
        fi
    fi
    gb_ensure_dir "$GB_ACME_ROOT" 0755
    sd_enable --now nginx || true
    if ! nginx_external_tls; then
        sd_enable --now certbot.timer || { gb_warn "Could not enable certbot.timer; automatic certificate renewal is unavailable."; return 1; }
    fi
    gb_log "Installed host tools. Runtime Python and packages are installed separately during explicit deployment/update."
}
