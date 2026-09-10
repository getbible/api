#!/usr/bin/env bash
# shellcheck disable=SC2329 # Mocks are invoked by dynamically sourced manager functions.
# External TLS must prepare complete HTTP origins without local certificates,
# while native certificate deployment keeps its existing behavior.
# shellcheck disable=SC2016 # nginx variables in assertions are literal
# shellcheck disable=SC2317 # curl stand-ins are called through sourced helpers
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
trap 'printf "External proxy CLI assertion failed at line %s\n" "$LINENO" >&2' ERR
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false GB_NGINX_FAKE_BROTLI=false
GB="$ROOT/getbible.sh"
no_match() { if grep -Eq -- "$1" "$2"; then printf 'Unexpected match: %s in %s\n' "$1" "$2" >&2; return 1; fi; }
mkdir -p "$SB/etc/getbible" "$SB/bin"
cat > "$SB/etc/getbible/getbible.conf" <<'CONF'
TLS_MODE=external
TRUSTED_PROXY_CIDRS=192.0.2.10,2001:db8::10/128
PUBLIC_SCHEME=https
ORIGIN_HTTP_PORT=18080
CONF
cat > "$SB/bin/certbot" <<'CERTBOT'
#!/usr/bin/env bash
echo 'unexpected certificate operation' >&2
exit 99
CERTBOT
chmod +x "$SB/bin/certbot"
export GB_CERTBOT="$SB/bin/certbot"
DOMAIN=external.example.test
"$GB" deploy static --domain "$DOMAIN" --version v2 --repo file:///fixture.git --staged > "$SB/deploy.log" 2>&1
SITE="$SB/etc/nginx/sites-available/$DOMAIN.conf"
grep -q 'listen 18080;' "$SITE"
grep -q 'location = /healthz' "$SITE"
grep -q 'absolute_redirect off;' "$SITE"
no_match 'listen 443|ssl_certificate|return 301 https|cloudflare-real-ip' "$SITE"
[[ ! -d "$SB/etc/getbible/placeholder-certs/$DOMAIN" ]]
grep -q 'set_real_ip_from 192.0.2.10/32;' "$SB/etc/nginx/snippets/getbible/external-proxy.conf"
grep -q 'real_ip_recursive off;' "$SB/etc/nginx/snippets/getbible/external-proxy.conf"
grep -q 'default https;' "$SB/etc/nginx/conf.d/getbible-http.conf"
grep -q 'proxy_set_header X-Forwarded-For $remote_addr;' "$SB/etc/nginx/snippets/getbible/proxy.conf"
grep -q 'proxy_set_header Authorization "";' "$SB/etc/nginx/snippets/getbible/proxy.conf"
"$GB" cert "$DOMAIN" status > "$SB/cert-status.log"
grep -q 'external TLS terminator' "$SB/cert-status.log"
if "$GB" cert "$DOMAIN" issue > "$SB/cert.log" 2>&1; then echo 'External certificate issuance was accepted' >&2; exit 1; fi
grep -q 'external reverse proxy' "$SB/cert.log"
no_match 'unexpected certificate operation' "$SB/cert.log"
"$GB" verify "$DOMAIN" > "$SB/verify.log" 2>&1
grep -q 'HTTP origin probe.*skip' "$SB/verify.log"
"$GB" doctor > "$SB/doctor.log" 2>&1
grep -q 'TLS ownership: external' "$SB/doctor.log"
grep -q 'external reverse proxy owns issuance and renewal' "$SB/doctor.log"
no_match 'certbot.timer|unexpected certificate operation' "$SB/doctor.log"

mkdir -p "$SB/srv/getbible/$DOMAIN/releases/v2/fixture"
ln -s releases/v2/fixture "$SB/srv/getbible/$DOMAIN/v2"
"$GB" go-live "$DOMAIN" > "$SB/live.log" 2>&1
grep -q '^LIVE=true$' "$SB/etc/getbible/endpoints/$DOMAIN/endpoint.conf"
no_match 'unexpected certificate operation' "$SB/live.log"
"$GB" stage "$DOMAIN" > /dev/null 2>&1
grep -q '^LIVE=false$' "$SB/etc/getbible/endpoints/$DOMAIN/endpoint.conf"
grep -q 'location = /healthz' "$SITE"

# A malformed or universally trusted peer list must fail before rendering.
for cidrs in '0.0.0.0/0' '::/0' '192.0.2.10; include /tmp/untrusted' ''; do
    sed -i "s|^TRUSTED_PROXY_CIDRS=.*|TRUSTED_PROXY_CIDRS=$cidrs|" "$SB/etc/getbible/getbible.conf"
    if "$GB" render "$DOMAIN" --out "$SB/rejected" > "$SB/rejected.log" 2>&1; then
        echo "Unsafe trust setting was accepted: $cidrs" >&2; exit 1
    fi
done
sed -i 's|^TRUSTED_PROXY_CIDRS=.*|TRUSTED_PROXY_CIDRS=192.0.2.10|' "$SB/etc/getbible/getbible.conf"

# Exercise the probe URL and trust policy without contacting public DNS.
export GB_REPO_DIR="$ROOT"
for lib in core config nginx certs python golive doctor; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'rm -rf "$SB"; gb_cleanup' EXIT
trap 'printf "External proxy CLI assertion failed at line %s\n" "$LINENO" >&2' ERR
(
    GB_PREFIX=""
    curl() {
        printf '%s\n' "$@" > "$SB/public-probe-args"
        local argument
        for argument in "$@"; do
            if [[ "$argument" == https://* ]]; then
                cat "$GB_VAR/origin-probes/${argument##*/}"
            fi
        done
    }
    golive_origin_identity_probe "$DOMAIN" 2
    grep -q "https://$DOMAIN/.well-known/getbible-origin/" "$SB/public-probe-args"
    no_match '--insecure|acme-challenge' "$SB/public-probe-args"
    [[ -z "$(ls -A "$GB_VAR/origin-probes")" ]]
    curl() { printf '%s\n' "$@" > "$SB/origin-probe-args"; printf '200'; }
    [[ "$(golive_probe "$DOMAIN" /healthz false)" == 200 ]]
    grep -q "Host: $DOMAIN" "$SB/origin-probe-args"
    grep -q "http://$DOMAIN:18080/healthz" "$SB/origin-probe-args"
)

# Docker install-deps verifies the image payload and never invokes apt.
(
    gb_is_docker() { return 0; }
    gb_have() { return 0; }
    apt-get() { printf 'apt was called\n' > "$SB/apt-called"; return 1; }
    GB_RUNTIME_BUNDLE="$SB/bundle"
    mkdir -p "$GB_RUNTIME_BUNDLE/python/cpython-3.12.1-20260101-x86_64-aaaaaaaaaaaaaaaa/bin"
    printf '#!/bin/sh\nexit 0\n' > "$GB_RUNTIME_BUNDLE/python/cpython-3.12.1-20260101-x86_64-aaaaaaaaaaaaaaaa/bin/python3"
    chmod +x "$GB_RUNTIME_BUNDLE/python/cpython-3.12.1-20260101-x86_64-aaaaaaaaaaaaaaaa/bin/python3"
    printf '3.12.1 x86_64 20260101 aaaaaaaaaaaaaaaa https://fixture\n' > "$GB_RUNTIME_BUNDLE/distributions.lock"
    for manifest in "$GB_APPS"/*/manifest.conf; do
        app="$(basename "$(dirname "$manifest")")"
        mkdir -p "$GB_RUNTIME_BUNDLE/wheels/3.12.1/$app"
        printf 'fixture==1\n' > "$GB_RUNTIME_BUNDLE/wheels/3.12.1/$app/packages.requirements"
        printf 'fixture\n' > "$GB_RUNTIME_BUNDLE/wheels/3.12.1/$app/.inputs"
        : > "$GB_RUNTIME_BUNDLE/wheels/3.12.1/$app/fixture.whl"
    done
    if ! doctor_install_deps > "$SB/image-check.log" 2>&1; then cat "$SB/image-check.log" >&2; exit 1; fi
    [[ ! -f "$SB/apt-called" ]]
    grep -q 'Image dependencies are present' "$SB/image-check.log"
    gb_have() { [[ "$1" != nginx ]]; }
    if doctor_install_deps > "$SB/image-missing.log" 2>&1; then
        echo 'Missing image dependency was accepted' >&2; exit 1
    fi
    grep -q 'docker compose pull' "$SB/image-missing.log"
    [[ ! -f "$SB/apt-called" ]]
)

# Switching the explicitly selected mode back to native reuses its original
# staged placeholder/certificate workflow, independent of the host environment.
sed -i 's/^TLS_MODE=external$/TLS_MODE=managed/' "$SB/etc/getbible/getbible.conf"
env -u GB_TMP "$GB" apply "$DOMAIN" > "$SB/native.log" 2>&1
grep -q 'listen 443 ssl' "$SITE"
grep -q 'placeholder-certs' "$SITE"
printf 'External TLS CLI, probes and native-mode preservation passed.\n'
