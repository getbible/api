#!/usr/bin/env bash
# Helpers for integration tests: a throw-away prefix, self-signed
# certificates, and an nginx started from the rendered configuration.

set -Eeuo pipefail

IT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IT_SB="${IT_SB:-$(mktemp -d)}"
chmod 0755 "$IT_SB"
IT_HTTP_PORT="${IT_HTTP_PORT:-18080}"
IT_HTTPS_PORT="${IT_HTTPS_PORT:-18443}"
IT_PASS=0
IT_FAIL=0

export GB_PREFIX="$IT_SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false
# Talk to the local nginx directly, never through an environment proxy.
export no_proxy='*' NO_PROXY='*'
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

it_log() { printf '[it] %s\n' "$*"; }

it_check() {
    # it_check LABEL EXPECTED ACTUAL (substring, case-insensitive)
    local label="$1" expected="$2" actual="$3"
    if [[ "${actual,,}" == *"${expected,,}"* ]]; then
        printf '  ok    %s\n' "$label"
        IT_PASS=$((IT_PASS + 1))
    else
        printf '  FAIL  %-50s expected %-30s got: %s\n' "$label" "$expected" "${actual:0:200}"
        IT_FAIL=$((IT_FAIL + 1))
    fi
}

it_summary() {
    printf '\n== %d passed, %d failed ==\n' "$IT_PASS" "$IT_FAIL"
    [[ "$IT_FAIL" -eq 0 ]]
}

it_selfsigned() {
    local domain="$1" dir="$IT_SB/etc/letsencrypt/live/$1"
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$dir/privkey.pem" \
        -out "$dir/fullchain.pem" -subj "/CN=$domain" 2>/dev/null
}

# Rewrite the rendered sites to high ports so the test needs no privileges.
it_nginx_start() {
    local conf="$IT_SB/etc/nginx/nginx-test.conf" site
    mkdir -p "$IT_SB/etc/nginx/logs" "$IT_SB/var/cache/nginx/getbible" "$IT_SB/run"
    for site in "$IT_SB"/etc/nginx/sites-enabled/*.conf; do
        sed -i -e "s/listen 80;/listen 127.0.0.1:$IT_HTTP_PORT;/" \
               -e "s/listen 443 ssl\(.*\);/listen 127.0.0.1:$IT_HTTPS_PORT ssl\1;/" "$(readlink -f "$site")"
    done
    cat > "$conf" <<EOF
pid $IT_SB/run/nginx.pid;
user root root;
error_log $IT_SB/nginx-error.log warn;
worker_processes 1;
events { worker_connections 128; }
http {
    access_log off;
    include /etc/nginx/mime.types;
    include $IT_SB/etc/nginx/conf.d/*.conf;
    include $IT_SB/etc/nginx/sites-enabled/*.conf;
}
EOF
    nginx -t -c "$conf" -p "$IT_SB/etc/nginx" >/dev/null 2>&1 || { nginx -t -c "$conf" -p "$IT_SB/etc/nginx"; return 1; }
    nginx -c "$conf" -p "$IT_SB/etc/nginx"
    sleep 0.5
}

# Fast shutdown, then wait until the master is really gone so the next start
# never races an old process for the listening ports.
it_nginx_stop() {
    local pid="" tries=0
    [[ -f "$IT_SB/run/nginx.pid" ]] && pid="$(cat "$IT_SB/run/nginx.pid")"
    [[ -n "$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    while kill -0 "$pid" 2>/dev/null && (( tries < 100 )); do
        sleep 0.1
        tries=$((tries + 1))
    done
    kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; sleep 0.2; }
    rm -f "$IT_SB/run/nginx.pid"
}

# Restart after a configuration change; a start failure ends the test.
it_nginx_restart() {
    it_nginx_stop
    it_nginx_start || { it_log "nginx failed to restart"; exit 1; }
}

# it_curl DOMAIN PATH [curl args...] -> prints "STATUS\n<headers>\n\n<body>"
it_curl() {
    local domain="$1" path="$2"
    shift 2
    curl --silent --show-error --insecure --noproxy '*' --max-time 10 \
        --resolve "$domain:$IT_HTTPS_PORT:127.0.0.1" \
        --write-out '\n__STATUS__:%{http_code}' \
        --dump-header - "$@" "https://$domain:$IT_HTTPS_PORT$path" 2>&1 || true
}

it_status() { it_curl "$@" | sed -n 's/^__STATUS__://p'; }

# it_headers DOMAIN PATH [curl args...] -> response headers only
it_headers() {
    local domain="$1" path="$2"
    shift 2
    curl --silent --show-error --insecure --noproxy '*' --max-time 10 \
        --resolve "$domain:$IT_HTTPS_PORT:127.0.0.1" --output /dev/null \
        --dump-header - "$@" "https://$domain:$IT_HTTPS_PORT$path" 2>&1 | tr -d '\r' || true
}

# it_wait_log FILE PATTERN [SECONDS]: wait for a buffered log line to appear.
it_wait_log() {
    local file="$1" pattern="$2" seconds="${3:-10}" waited=0
    while (( waited < seconds )); do
        grep -q -- "$pattern" "$file" 2>/dev/null && { grep -- "$pattern" "$file" | tail -1; return 0; }
        sleep 1
        waited=$((waited + 1))
    done
    printf 'pattern not found in %s\n' "$file"
}
it_header() {
    # it_header DOMAIN PATH HEADER
    local header="$3"
    it_curl "$1" "$2" | grep -i "^$header:" | tr -d '\r' | tail -1
}
it_body() { it_curl "$@" | sed '/^__STATUS__:/d' | awk 'body {print} /^\r?$/ {body=1}'; }
