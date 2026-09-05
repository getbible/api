#!/usr/bin/env bash
# Let's Encrypt certificates through certbot in certonly/webroot mode. The
# port-80 server block of every endpoint serves the ACME challenge directory,
# so issuance and renewal never touch the rendered configuration. Renewal
# stays certbot's own timer; a deploy hook reloads nginx and notifies.

[[ -n "${GB_CERTS_LOADED:-}" ]] && return 0
GB_CERTS_LOADED=1

certs_available() { gb_have "$GB_CERTBOT"; }

# certs_obtain DOMAIN: issue a certificate when none exists. Returns 0 when a
# usable certificate is present afterwards.
certs_obtain() {
    local domain="$1" email
    if nginx_cert_exists "$domain"; then
        gb_log "Certificate for $domain already exists; reusing it."
        return 0
    fi
    if ! certs_available; then
        gb_warn "certbot is not installed; $domain stays HTTP-only until a certificate exists."
        return 1
    fi
    [[ -n "$GB_PREFIX" ]] && { gb_log "(prefix) certbot skipped for $domain"; return 1; }
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would run certbot for $domain"; return 1; }
    email="$(gb_global CERTBOT_EMAIL)"
    if [[ -z "$email" ]]; then
        email="$(ui_input "Let's Encrypt" "Contact email for certificate expiry notices" "")" || return 1
        [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || gb_die "Invalid email address."
        gb_global_set CERTBOT_EMAIL "$email"
    fi
    gb_ensure_dir "$GB_ACME_ROOT" 0755
    gb_step "Requesting a certificate for $domain"
    if "$GB_CERTBOT" certonly --webroot -w "$GB_ACME_ROOT" -d "$domain" \
        --non-interactive --agree-tos --email "$email" --keep-until-expiring --no-eff-email; then
        certs_install_hook
        tg_notify ok "Certificate issued" "A Let's Encrypt certificate was issued for $domain."
        return 0
    fi
    gb_warn "certbot failed for $domain. Check that DNS points here and port 80 is reachable, then run 'Renew certificate' from the endpoint menu."
    tg_notify fail "Certificate failed" "certbot could not issue a certificate for $domain."
    return 1
}

# Reload nginx after every renewal and say so on Telegram.
certs_install_hook() {
    local dir="$GB_LETSENCRYPT/renewal-hooks/deploy"
    [[ -d "$GB_LETSENCRYPT" ]] || return 0
    gb_ensure_dir "$dir" 0755
    cat > "$(gb_tmpdir)/reload-hook" <<'HOOK'
#!/bin/sh
# Installed by getbible.sh: reload nginx after a certificate renewal.
systemctl reload nginx 2>/dev/null || nginx -s reload
if [ -x /usr/local/lib/getbible/getbible-notify ]; then
    /usr/local/lib/getbible/getbible-notify ok "Certificate renewed" "Renewed: ${RENEWED_DOMAINS:-unknown}. nginx reloaded."
fi
HOOK
    gb_install_file "$(gb_tmpdir)/reload-hook" "$dir/getbible-reload-nginx.sh" 0755
}

certs_renew_now() {
    local domain="$1"
    certs_available || gb_die "certbot is not installed."
    "$GB_CERTBOT" renew --cert-name "$domain" --force-renewal --non-interactive && nginx_reload
}

certs_expiry() {
    local domain="$1" pem
    pem="$(nginx_cert_dir "$domain")/fullchain.pem"
    [[ -f "$pem" ]] || { printf 'none\n'; return 0; }
    openssl x509 -enddate -noout -in "$pem" 2>/dev/null | sed 's/notAfter=//' || printf 'unknown\n'
}
