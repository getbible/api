#!/usr/bin/env bash
# Host checks and dependency installation.

[[ -n "${GB_DOCTOR_LOADED:-}" ]] && return 0
GB_DOCTOR_LOADED=1

GB_APT_PACKAGES=(nginx certbot python3 python3-venv python3-pip whiptail rsync git openssh-client curl logrotate acl ca-certificates openssl)

doctor_check() {
    # doctor_check LABEL STATUS DETAIL
    printf '  %-28s %-6s %s\n' "$1" "$2" "$3"
}

doctor_run() {
    local tool
    printf 'getBible API host check\n\n'
    printf 'Host: %s   OS: %s\n\n' "$(hostname -f 2>/dev/null || hostname)" "$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME" || uname -sr)"
    for tool in nginx certbot python3 whiptail rsync git ssh-keygen curl logrotate flock setfacl openssl; do
        if gb_have "$tool"; then doctor_check "$tool" ok "$(command -v "$tool")"; else doctor_check "$tool" MISS "install with: getbible.sh install-deps"; fi
    done
    if gb_have python3; then
        python3 -c 'import venv' 2>/dev/null && doctor_check "python3 venv" ok "$(python3 --version)" || doctor_check "python3 venv" MISS "python3-venv package"
    fi
    nginx_detect
    if [[ "$NG_AVAILABLE" == true ]]; then
        doctor_check "nginx version" ok "$NG_VERSION (http2: $([[ "$NG_HTTP2_NATIVE" == true ]] && echo 'http2 on' || echo 'listen http2'), brotli: $NG_BROTLI, ipv6: $NG_IPV6)"
        if [[ -z "$GB_PREFIX" ]] && "$GB_NGINX_BIN" -t >/dev/null 2>&1; then doctor_check "nginx configuration" ok "nginx -t passes"; else doctor_check "nginx configuration" WARN "nginx -t fails or nginx missing"; fi
        sd_is_active nginx && doctor_check "nginx service" ok active || doctor_check "nginx service" WARN "not active"
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
    printf '\nListening: %s\n' "$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(80|443)$' | sort -u | tr '\n' ' ')"
}

doctor_install_deps() {
    gb_have apt-get || gb_die "Automatic installation supports Debian/Ubuntu only. Install: ${GB_APT_PACKAGES[*]}"
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would apt-get install ${GB_APT_PACKAGES[*]}"; return 0; }
    gb_step "Installing packages: ${GB_APT_PACKAGES[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${GB_APT_PACKAGES[@]}"
    if apt-cache show libnginx-mod-http-brotli-static >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-http-brotli-static || true
    fi
    gb_ensure_dir "$GB_ACME_ROOT" 0755
    sd_enable --now nginx || true
}
