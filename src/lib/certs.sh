#!/usr/bin/env bash
# Let's Encrypt certificates through certbot, with two ways to prove control
# of a name:
#
#   http            certonly in webroot mode. The port-80 server block of every
#                   domain serves the ACME challenge directory, so the name
#                   must already resolve to this server.
#   dns-cloudflare  the certbot-dns-cloudflare plugin publishes a TXT record
#                   with the stored Cloudflare API token, so a certificate can
#                   be issued for a staged domain before DNS points here.
#
# Renewal stays certbot's own timer with whichever authenticator issued the
# certificate; a deploy hook reloads nginx and notifies. All endpoints of a
# domain share its certificate. A staged domain
# carries a self-signed placeholder so its complete TLS vhost can be rendered
# and tested before go-live replaces it.

[[ -n "${GB_CERTS_LOADED:-}" ]] && return 0
GB_CERTS_LOADED=1

GB_CERT_METHODS=(auto http dns-cloudflare)

certs_available() { gb_have "$GB_CERTBOT"; }
certs_valid_method() { [[ "$1" == auto || "$1" == http || "$1" == dns-cloudflare ]]; }
certs_valid_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; }

# Under the test prefix certbot never runs: it would write to the host's
# /etc/letsencrypt. A test may supply a stand-in, which must live inside
# the sandbox so an operator's exported GB_CERTBOT cannot leak through.
certs_can_run() {
    certs_available || return 1
    [[ -z "$GB_PREFIX" || "$GB_CERTBOT" == "$GB_PREFIX"/* ]]
}

# `certbot plugins` starts a Python interpreter; ask once per run and keep
# the answer in the run's temporary directory so command substitutions share it.
certs_plugins() {
    local cache
    cache="$(gb_tmpdir)/certbot-plugins"
    if [[ ! -s "$cache" ]]; then
        certs_can_run || return 1
        { "$GB_CERTBOT" plugins --non-interactive 2>/dev/null || true; } > "$cache"
        [[ -s "$cache" ]] || printf '(none)\n' > "$cache"
    fi
    cat "$cache"
}

certs_dns_cloudflare_installed() {
    local plugins
    # Read the complete output: grep -q can close the pipe early and make
    # its producer fail with SIGPIPE under pipefail despite finding the plugin.
    plugins="$(certs_plugins)" || return 1
    [[ "$plugins" == *dns-cloudflare* ]]
}

# DNS-01 needs both the plugin and the token from Settings > Cloudflare.
certs_dns_cloudflare_available() {
    [[ -n "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" ]] || return 1
    certs_dns_cloudflare_installed
}

# certs_method DOMAIN [REQUESTED]: the concrete method for this run. `auto`
# (the default from Settings) uses dns-cloudflare for a domain that Cloudflare
# manages here (mode dns or proxied) when the plugin and token are present:
# the stored token cannot be assumed to cover any other zone. Domains whose
# DNS is on Cloudflare but not managed here choose dns-cloudflare explicitly.
certs_method() {
    local domain="$1" requested="${2:-}" method
    method="${requested:-$(gb_global CERT_METHOD auto)}"
    certs_valid_method "$method" || { gb_warn "Unknown certificate method: $method (auto, http, dns-cloudflare)"; return 1; }
    if [[ "$method" == auto ]]; then
        method=http
        if ep_exists "$domain" && [[ "$(ep_get "$domain" CLOUDFLARE_MODE off)" != off ]] && certs_dns_cloudflare_available; then
            method=dns-cloudflare
        fi
    fi
    printf '%s\n' "$method"
}

certs_method_description() {
    case "$1" in
        http) printf 'HTTP-01 through the port-80 challenge directory; DNS must already reach this server\n' ;;
        dns-cloudflare) printf 'DNS-01 through the stored Cloudflare API token; works before DNS points here\n' ;;
        *) printf 'automatic: dns-cloudflare for a Cloudflare-managed domain when its plugin and the token are present, otherwise http\n' ;;
    esac
}

# The contact address for expiry notices. Prompting is only possible while
# no dialog output is being captured; otherwise Settings must provide it.
certs_email() {
    local email
    email="$(gb_global CERTBOT_EMAIL)"
    while [[ -z "$email" ]]; do
        if [[ "${GB_UI_CAPTURED:-false}" == true ]]; then
            gb_warn "No Let's Encrypt contact email is set (Settings > Let's Encrypt contact email)."
            return 1
        fi
        email="$(ui_input "Let's Encrypt" "Contact email for certificate expiry notices" "")" || email=""
        [[ -n "$email" ]] || { gb_warn "A Let's Encrypt contact email is required (Settings > Let's Encrypt contact email)."; return 1; }
        if ! certs_valid_email "$email"; then
            ui_msg "Let's Encrypt" "'$email' is not a valid email address."
            email=""
            continue
        fi
        gb_global_set CERTBOT_EMAIL "$email"
    done
    printf '%s\n' "$email"
}

# certs_certbot_args DOMAIN METHOD EMAIL: the certbot command line, one
# argument per line, so tests can assert it without running certbot.
certs_certbot_args() {
    local domain="$1" method="$2" email="$3"
    [[ "$method" == http || "$method" == dns-cloudflare ]] || return 1
    printf '%s\n' certonly
    case "$method" in
        http) printf '%s\n' --webroot -w "$GB_ACME_ROOT" ;;
        dns-cloudflare)
            printf '%s\n' --dns-cloudflare --dns-cloudflare-credentials "$GB_CERTBOT_CLOUDFLARE_INI" \
                --dns-cloudflare-propagation-seconds 30 ;;
    esac
    printf '%s\n' -d "$domain" --non-interactive --agree-tos --email "$email" --keep-until-expiring --no-eff-email
}

# The plugin reads the token from an ini file that certbot also records in the
# renewal configuration, so it lives under /etc/getbible (root only) and is
# rewritten from cloudflare.conf whenever the token is stored or used.
certs_cloudflare_credentials_write() {
    local token stage
    token="$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)"
    [[ -n "$token" ]] || { gb_warn "No Cloudflare API token is stored (Settings > Cloudflare API token)."; return 1; }
    stage="$(gb_tmpdir)/certbot-cloudflare.ini"
    ( umask 077; printf '# Written by getbible.sh from cloudflare.conf; change the token there.\ndns_cloudflare_api_token = %s\n' "$token" > "$stage" ) || return 1
    gb_install_file "$stage" "$GB_CERTBOT_CLOUDFLARE_INI" 0600
}

# certs_http_probe DOMAIN: does http://DOMAIN/.well-known/acme-challenge/
# reach this server? A random file is placed in the challenge directory and
# fetched by its public name. Advisory only: some networks cannot reach their
# own public address, and certbot's validation is what counts.
certs_http_probe() {
    local domain="$1" timeout="${2:-10}" dir token body
    [[ -z "$GB_PREFIX" ]] || { gb_log "(prefix) reachability probe skipped for $domain"; return "${GB_FAKE_HTTP_PROBE:-0}"; }
    gb_have curl || return 0
    dir="$GB_ACME_ROOT/.well-known/acme-challenge"
    gb_ensure_dir "$dir" 0755 || return 1
    token="getbible-probe-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "$token" > "$dir/$token" || return 1
    chmod 0644 "$dir/$token"
    body="$(curl --silent --location --insecure --max-time "$timeout" --max-redirs 3 \
        "http://$domain/.well-known/acme-challenge/$token" 2>/dev/null || true)"
    rm -f -- "$dir/$token"
    [[ "$body" == "$token" ]]
}

# certs_obtain DOMAIN [METHOD]: issue a certificate when none exists. Returns
# 0 when a Let's Encrypt certificate and its renewal hook are present afterwards.
certs_obtain() {
    local domain="$1" requested="${2:-}" method email
    local -a args=()
    if nginx_cert_exists "$domain"; then
        gb_log "Certificate for $domain already exists; reusing it."
        certs_install_hook
        return $?
    fi
    if ! certs_available; then
        gb_warn "certbot is not installed; $domain has no certificate (System > Install dependencies)."
        return 1
    fi
    certs_can_run || { gb_log "(prefix) certbot skipped for $domain"; return 1; }
    method="$(certs_method "$domain" "$requested")" || return 1
    if [[ "$method" == dns-cloudflare ]] && ! certs_dns_cloudflare_available; then
        gb_warn "DNS-01 needs the certbot-dns-cloudflare plugin (System > Install dependencies) and a stored Cloudflare API token (Settings > Cloudflare API token)."
        return 1
    fi
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would run certbot ($method) for $domain"; return 1; }
    email="$(certs_email)" || return 1
    if [[ "$method" == http ]]; then
        gb_ensure_dir "$GB_ACME_ROOT" 0755
        certs_http_probe "$domain" \
            || gb_warn "http://$domain/ does not seem to reach this server yet; Let's Encrypt validation will fail unless DNS (and any proxy) already route the name here."
    else
        certs_cloudflare_credentials_write || return 1
    fi
    gb_step "Requesting a certificate for $domain ($method)"
    mapfile -t args < <(certs_certbot_args "$domain" "$method" "$email")
    if "$GB_CERTBOT" "${args[@]}"; then
        certs_install_hook || return 1
        tg_notify ok "Certificate issued" "A Let's Encrypt certificate was issued for $domain ($method)."
        return 0
    fi
    if [[ "$method" == http ]]; then
        gb_warn "certbot failed for $domain. Check that DNS points here and port 80 is reachable, then retry from Domain > Certificate (or go live again)."
    else
        gb_warn "certbot failed for $domain. Check that the Cloudflare token may edit DNS for this zone, then retry from Domain > Certificate (or go live again)."
    fi
    tg_notify fail "Certificate failed" "certbot ($method) could not issue a certificate for $domain."
    return 1
}

# certs_issue DOMAIN [METHOD]: obtain the certificate now and re-render the
# domain so nginx serves it. A staged domain stays staged: no DNS change.
certs_issue() {
    local domain="$1" method="${2:-}"
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    if nginx_cert_exists "$domain"; then
        gb_log "$domain already has a Let's Encrypt certificate (expires $(certs_expiry "$domain"))."
    fi
    certs_obtain "$domain" "$method" || return 1
    endpoint_apply "$domain"
}

# Reload nginx after every renewal and say so on Telegram.
certs_install_hook() {
    local dir="$GB_LETSENCRYPT/renewal-hooks/deploy"
    [[ -d "$GB_LETSENCRYPT" ]] || { gb_warn "Cannot install the certificate renewal hook: $GB_LETSENCRYPT is missing."; return 1; }
    gb_ensure_dir "$dir" 0755 || { gb_warn "Cannot create the certificate renewal hook directory: $dir"; return 1; }
    cat > "$(gb_tmpdir)/reload-hook" <<'HOOK' || return 1
#!/bin/sh
# Installed by getbible.sh: reload nginx after a certificate renewal.
if ! nginx -t || ! { systemctl reload nginx 2>/dev/null || nginx -s reload; }; then
    if [ -x /usr/local/lib/getbible/getbible-notify ]; then
        /usr/local/lib/getbible/getbible-notify fail "Certificate reload failed" "Renewed: ${RENEWED_DOMAINS:-unknown}. nginx validation or reload failed; check the service."
    fi
    exit 1
fi
if [ -x /usr/local/lib/getbible/getbible-notify ]; then
    /usr/local/lib/getbible/getbible-notify ok "Certificate renewed" "Renewed: ${RENEWED_DOMAINS:-unknown}. nginx reloaded."
fi
HOOK
    gb_install_file "$(gb_tmpdir)/reload-hook" "$dir/getbible-reload-nginx.sh" 0755 \
        || { gb_warn "Could not install the certificate renewal hook; nginx would not reload after renewal."; return 1; }
}

certs_renew_now() {
    local domain="$1"
    certs_available || { gb_warn "certbot is not installed (System > Install dependencies)."; return 1; }
    nginx_cert_exists "$domain" || { gb_warn "$domain has no Let's Encrypt certificate to renew; issue one first."; return 1; }
    certs_install_hook || return 1
    "$GB_CERTBOT" renew --cert-name "$domain" --force-renewal --non-interactive && nginx_test && nginx_reload
}

certs_expiry() {
    local domain="$1" pem
    pem="$(nginx_cert_dir "$domain")/fullchain.pem"
    [[ -f "$pem" ]] || { printf 'none\n'; return 0; }
    openssl x509 -enddate -noout -in "$pem" 2>/dev/null | sed 's/notAfter=//' || printf 'unknown\n'
}

# --- placeholder certificates for staged endpoints ---------------------------
certs_placeholder_dir() { printf '%s/%s\n' "$GB_PLACEHOLDER_CERTS" "$1"; }
certs_placeholder_exists() { [[ -f "$(certs_placeholder_dir "$1")/fullchain.pem" && -f "$(certs_placeholder_dir "$1")/privkey.pem" ]]; }

# A self-signed certificate lets a staged endpoint render and test its complete
# TLS vhost before any DNS change. Go-live replaces it with Let's Encrypt.
certs_placeholder_ensure() {
    local domain="$1" dir
    certs_placeholder_exists "$domain" && return 0
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would create a placeholder certificate for $domain"; return 0; }
    gb_have openssl || { gb_warn "openssl is missing; $domain gets no placeholder certificate and stays HTTP-only while staged."; return 1; }
    dir="$(certs_placeholder_dir "$domain")"
    gb_ensure_dir "$GB_PLACEHOLDER_CERTS" 0700 || return 1
    gb_ensure_dir "$dir" 0700 || return 1
    gb_step "Creating a self-signed placeholder certificate for $domain (staged)"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" -keyout "$dir/privkey.pem.tmp" -out "$dir/fullchain.pem.tmp" >/dev/null 2>&1; then
        rm -f -- "$dir/privkey.pem.tmp" "$dir/fullchain.pem.tmp"
        gb_warn "openssl could not create a placeholder certificate for $domain."
        return 1
    fi
    chmod 0600 "$dir/privkey.pem.tmp" && chmod 0644 "$dir/fullchain.pem.tmp" || return 1
    mv -f -- "$dir/privkey.pem.tmp" "$dir/privkey.pem" && mv -f -- "$dir/fullchain.pem.tmp" "$dir/fullchain.pem"
}

certs_placeholder_remove() {
    local domain="$1" dir
    dir="$(certs_placeholder_dir "$domain")"
    [[ -d "$dir" ]] || return 0
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would remove the placeholder certificate of $domain"; return 0; }
    rm -rf -- "$dir"
    gb_log "Removed the placeholder certificate of $domain."
}

# --- status ------------------------------------------------------------------
# certs_source DOMAIN: letsencrypt | placeholder | none
certs_source() {
    local domain="$1"
    if nginx_cert_exists "$domain"; then printf 'letsencrypt\n'
    elif certs_placeholder_exists "$domain"; then printf 'placeholder\n'
    else printf 'none\n'; fi
}

# The authenticator certbot recorded for renewals of DOMAIN.
certs_renewal_method() {
    local conf="$GB_LETSENCRYPT/renewal/$1.conf" value
    [[ -f "$conf" ]] || { printf 'unknown\n'; return 0; }
    value="$(sed -n 's/^authenticator[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)"
    case "$value" in
        webroot) printf 'http\n' ;;
        "") printf 'unknown\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

certs_status_line() {
    local domain="$1"
    case "$(certs_source "$domain")" in
        letsencrypt) printf "Let's Encrypt, expires %s, renewal method %s\n" "$(certs_expiry "$domain")" "$(certs_renewal_method "$domain")" ;;
        placeholder) printf 'self-signed placeholder (staged; replaced at go-live)\n' ;;
        *) printf 'none (HTTP only)\n' ;;
    esac
}

certs_status_text() {
    local domain="$1" method
    method="$(certs_method "$domain")" || method=http
    printf 'Domain      : %s (%s)\n' "$domain" "$(ep_publication "$domain")"
    printf 'Certificate : %s\n' "$(certs_status_line "$domain")"
    printf 'Directory   : %s\n' "$(nginx_tls_cert_dir "$domain")"
    printf 'Next issue  : %s (%s)\n' "$method" "$(certs_method_description "$method")"
    printf 'Setting     : %s\n' "$(gb_global CERT_METHOD auto)"
    printf 'Contact     : %s\n' "$(gb_global CERTBOT_EMAIL)"
    if certs_available; then printf 'certbot     : %s\n' "$(command -v "$GB_CERTBOT")"; else printf 'certbot     : not installed\n'; fi
    if certs_can_run; then
        if certs_dns_cloudflare_installed; then printf 'DNS plugin  : dns-cloudflare installed\n'; else printf 'DNS plugin  : not installed (python3-certbot-dns-cloudflare)\n'; fi
    fi
    if [[ -n "$(cfg_get "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN)" ]]; then printf 'Cloudflare  : token stored\n'; else printf 'Cloudflare  : no token stored\n'; fi
}

# --- prompts, menu and command line -----------------------------------------
# Ask which validation method to use. The item from Settings is preselected,
# and the automatic item says what it would do for this domain right now.
certs_prompt_method() {
    local domain="$1" setting resolved
    setting="$(gb_global CERT_METHOD auto)"
    certs_valid_method "$setting" || setting=auto
    resolved="$(certs_method "$domain" auto)" || resolved=http
    ui_radiolist "Certificate validation" "How should Let's Encrypt validate $domain? (Settings: $setting)" \
        auto "Automatic: dns-cloudflare for Cloudflare-managed domains when available, otherwise http (now: $resolved)" "$([[ "$setting" == auto ]] && echo on || echo off)" \
        http "HTTP-01: DNS must already route $domain to this server" "$([[ "$setting" == http ]] && echo on || echo off)" \
        dns-cloudflare "DNS-01: uses the stored Cloudflare token; works before DNS changes" "$([[ "$setting" == dns-cloudflare ]] && echo on || echo off)"
}

# Make sure a contact email exists while dialogs are still possible.
certs_email_interactive() {
    [[ -n "$(gb_global CERTBOT_EMAIL)" ]] && return 0
    certs_email >/dev/null
}

certs_menu() {
    local domain="$1" choice method out
    while true; do
        choice="$(ui_menu "Certificate: $domain" "$(certs_status_line "$domain")" \
            status "Show certificate details" \
            issue "Issue a Let's Encrypt certificate now (staged endpoints stay staged)" \
            renew "Force a renewal now (Let's Encrypt certificates only)" \
            back "Back")" || return 0
        case "$choice" in
            status)
                out="$(gb_tmpdir)/cert.$$"
                certs_status_text "$domain" > "$out" 2>&1 || true
                ui_textbox "Certificate: $domain" "$out" ;;
            issue)
                if nginx_cert_exists "$domain"; then
                    method=""
                else
                    method="$(certs_prompt_method "$domain")" || continue
                    certs_email_interactive || continue
                fi
                endpoint_confirm_hand_edits "$domain" || continue
                ui_run "Issue certificate for $domain" certs_issue "$domain" "$method" || true
                GB_OVERWRITE_HAND_EDITS=false ;;
            renew)
                if ! nginx_cert_exists "$domain"; then
                    ui_msg "Certificate" "$domain has no Let's Encrypt certificate to renew ($(certs_status_line "$domain")). Issue one first."
                    continue
                fi
                ui_run "Renew $domain" certs_renew_now "$domain" || true ;;
            back) return 0 ;;
        esac
    done
}

certs_cli() {
    local domain="${1:-}" action="${2:-status}" method=""
    [[ -n "$domain" ]] || gb_die "cert DOMAIN status|issue [--method auto|http|dns-cloudflare]|renew"
    shift
    [[ $# -eq 0 ]] || shift
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    case "$action" in
        status) certs_status_text "$domain" ;;
        issue)
            [[ "${1:-}" == --method ]] && method="${2:-}"
            [[ -z "$method" ]] || certs_valid_method "$method" || gb_die "Certificate methods: auto, http, dns-cloudflare"
            if ! nginx_cert_exists "$domain"; then certs_email_interactive || return 1; fi
            certs_issue "$domain" "$method" ;;
        renew) certs_renew_now "$domain" ;;
        *) gb_die "cert DOMAIN status|issue [--method auto|http|dns-cloudflare]|renew" ;;
    esac
}
