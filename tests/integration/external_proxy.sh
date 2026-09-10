#!/usr/bin/env bash
# Two domains share one HTTP origin port. Exercise actual nginx virtual-host
# routing, peer trust, bearer validation and runtime header normalization;
# when installed, HAProxy terminates fixture TLS in front of that same origin.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
ORIGIN_PORT=18980
FRONT_PORT=18943
ECHO_PID=""
HAPROXY_PID=""
cleanup() {
    local result="$?"
    if (( result != 0 )); then
        it_failure_logs
        for log in "$IT_SB/capture.log" "$IT_SB/haproxy.log" "$IT_SB/token-error.log"; do
            [[ ! -f "$log" ]] || tail -20 "$log"
        done
    fi
    it_nginx_stop
    [[ -z "$HAPROXY_PID" ]] || kill "$HAPROXY_PID" 2>/dev/null || true
    [[ -z "$ECHO_PID" ]] || kill "$ECHO_PID" 2>/dev/null || true
    rm -rf "$IT_SB"
}
trap cleanup EXIT
mkdir -p "$IT_SB/etc/getbible"
cat > "$IT_SB/etc/getbible/getbible.conf" <<EOF
TLS_MODE=external
TRUSTED_PROXY_CIDRS=127.0.0.2/32
PUBLIC_SCHEME=https
ORIGIN_HTTP_PORT=$ORIGIN_PORT
EOF
FIRST=public.example.test
SECOND=private.example.test
for domain in "$FIRST" "$SECOND"; do
    access=open
    [[ "$domain" != "$SECOND" ]] || access=token
    "$IT_ROOT/getbible.sh" deploy static --domain "$domain" --version v2 \
        --repo file:///fixture.git --access "$access" --staged > "$IT_SB/deploy-$domain.log" 2>&1
    release="$IT_SB/srv/getbible/$domain/releases/v2/fixture"
    mkdir -p "$release"
    printf '{"domain":"%s"}\n' "$domain" > "$release/data.json"
    ln -s releases/v2/fixture "$IT_SB/srv/getbible/$domain/v2"
    chgrp -R "$IT_NGINX_USER" "$IT_SB/srv/getbible/$domain"
    chmod -R g+rX "$IT_SB/srv/getbible/$domain"
done
it_log 'Preparing bearer fixture'
TOKEN_JSON="$("$IT_ROOT/getbible.sh" token "$SECOND" add 'proxy fixture' 2>"$IT_SB/token-error.log")"
TOKEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$TOKEN_JSON")"
TOKEN_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$TOKEN_JSON")"

# This fixture upstream observes the exact headers produced by the generated
# proxy/auth snippets, with no framework normalization hiding errors.
cat > "$IT_SB/capture.py" <<'PY'
import http.server
import json
import os
import socketserver
import sys

class Capture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(dict(self.headers.items())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

with socketserver.UnixStreamServer(sys.argv[1], Capture) as server:
    os.chmod(sys.argv[1], 0o666)
    server.serve_forever()
PY
python3 "$IT_SB/capture.py" "$IT_SB/capture.sock" > "$IT_SB/capture.log" 2>&1 &
ECHO_PID=$!
for attempt in {1..30}; do [[ -S "$IT_SB/capture.sock" ]] && break; sleep .1; done
[[ -S "$IT_SB/capture.sock" ]]
it_log 'Capture socket ready'
for domain in "$FIRST" "$SECOND"; do
    # An inspection route only in this isolated test; all directives it
    # exercises come from the generated production snippets.
    python3 - "$IT_SB/etc/nginx/sites-available/$domain.conf" "$IT_SB" "$domain" <<'PY'
from pathlib import Path
import sys
path, sandbox, domain = sys.argv[1:]
site = Path(path).read_text()
# Match the complete indentation from the start of the line. Version folders
# have their own nested dotfile location with eight spaces; matching a bare
# substring would inject /inspect there as well as at server scope.
marker = "\n    location ~ /\\. {"
assert site.count(marker) == 1, "expected one server-level dotfile location"
location = f"""    location = /inspect {{
        include {sandbox}/etc/nginx/getbible/{domain}/auth.conf;
        include snippets/getbible/proxy.conf;
        proxy_pass http://unix:{sandbox}/capture.sock:;
    }}
"""
Path(path).write_text(site.replace(marker, "\n" + location + marker, 1))
PY
done
it_nginx_start
it_log 'HTTP origin ready'
origin() {
    local domain="$1" path="$2"
    shift 2
    curl --silent --show-error --noproxy '*' --max-time 5 \
        --header "Host: $domain" "$@" "http://127.0.0.1:$ORIGIN_PORT$path"
}
it_check 'public domain selects its data' "$FIRST" "$(origin "$FIRST" /v2/data.json)"
it_check 'private domain authenticates' '401' "$(origin "$SECOND" /v2/data.json -o /dev/null -w '%{http_code}')"
it_check 'private domain selects its own data' "$SECOND" "$(origin "$SECOND" /v2/data.json -H "Authorization: Bearer $TOKEN")"
it_check 'redirect stays relative across HTTP origin' 'Location: /v2/' "$(origin "$FIRST" /v2 -D - -o /dev/null)"
TRUSTED="$(origin "$SECOND" /inspect --interface 127.0.0.2 -H 'X-Forwarded-For: 203.0.113.40' \
    -H 'X-Forwarded-Proto: http' -H 'X-Forwarded-Host: forged.example.test' \
    -H 'X-GetBible-Token-Id: forged-id' -H "Authorization: Bearer $TOKEN")"
it_check 'runtime gets original domain' "\"Host\": \"$SECOND\"" "$TRUSTED"
it_check 'trusted peer supplies client address' '"X-Real-IP": "203.0.113.40"' "$TRUSTED"
it_check 'forwarded address chain is normalized' '"X-Forwarded-For": "203.0.113.40"' "$TRUSTED"
it_check 'public scheme ignores forged header' '"X-Forwarded-Proto": "https"' "$TRUSTED"
it_check 'forwarded hostname ignores forged header' "\"X-Forwarded-Host\": \"$SECOND\"" "$TRUSTED"
it_check 'token identity supplied by nginx' "\"X-GetBible-Token-Id\": \"$TOKEN_ID\"" "$TRUSTED"
it_check 'bearer secret is stripped before runtime' '' "$(printf '%s' "$TRUSTED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Authorization", ""))')"
UNTRUSTED="$(origin "$FIRST" /inspect -H 'X-Forwarded-For: 203.0.113.99' -H 'CF-Connecting-IP: 203.0.113.98')"
it_check 'untrusted peer cannot forge client address' '"X-Real-IP": "127.0.0.1"' "$UNTRUSTED"
mkdir -p "$IT_SB/var/lib/getbible/origin-probes"
printf 'fixture-origin' > "$IT_SB/var/lib/getbible/origin-probes/fixture"
it_check 'identity is independent of ACME and auth' 'fixture-origin' "$(origin "$SECOND" /.well-known/getbible-origin/fixture)"
it_check 'identity cannot be cached' 'Cache-Control: no-store' "$(origin "$SECOND" /.well-known/getbible-origin/fixture -D - -o /dev/null)"

if command -v haproxy >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=proxy.example.test \
        -keyout "$IT_SB/tls.key" -out "$IT_SB/tls.crt" > /dev/null 2>&1
    cat "$IT_SB/tls.crt" "$IT_SB/tls.key" > "$IT_SB/tls.pem"
    cat > "$IT_SB/haproxy.cfg" <<EOF
global
    maxconn 64
defaults
    mode http
    timeout connect 3s
    timeout client 10s
    timeout server 10s
frontend api
    bind 127.0.0.1:$FRONT_PORT ssl crt $IT_SB/tls.pem
    # Loopback .3 represents a verified Cloudflare peer in this fixture only.
    acl verified_cloudflare src 127.0.0.3/32
    acl valid_client_header req.hdr_ip(CF-Connecting-IP) -m found
    http-request set-var(txn.client_ip) src
    http-request set-var(txn.client_ip) req.hdr_ip(CF-Connecting-IP) if verified_cloudflare valid_client_header
    http-request set-header X-Forwarded-For %[var(txn.client_ip)]
    http-request set-header X-Forwarded-Proto https
    default_backend origin
backend origin
    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host $FIRST
    server getbible 127.0.0.1:$ORIGIN_PORT source 127.0.0.2 check
EOF
    haproxy -c -f "$IT_SB/haproxy.cfg"
    haproxy -db -f "$IT_SB/haproxy.cfg" > "$IT_SB/haproxy.log" 2>&1 &
    HAPROXY_PID=$!
    edge() {
        local domain="$1" path="$2"
        shift 2
        curl --silent --show-error --insecure --noproxy '*' --max-time 5 \
            --resolve "$domain:$FRONT_PORT:127.0.0.1" --header "Host: $domain" "$@" "https://$domain:$FRONT_PORT$path"
    }
    for attempt in {1..30}; do
        if edge "$FIRST" /healthz > /dev/null 2>&1; then break; fi
        sleep .1
    done
    it_check 'HAProxy preserves public Host to shared port' "$FIRST" "$(edge "$FIRST" /v2/data.json)"
    it_check 'HAProxy preserves private Host and bearer to same port' "$SECOND" "$(edge "$SECOND" /v2/data.json -H "Authorization: Bearer $TOKEN")"
    EDGE="$(edge "$SECOND" /inspect --interface 127.0.0.3 -H 'CF-Connecting-IP: 203.0.113.51' \
        -H 'X-Forwarded-For: 203.0.113.1' -H "Authorization: Bearer $TOKEN")"
    it_check 'HAProxy trusts verified CF client IP' '"X-Real-IP": "203.0.113.51"' "$EDGE"
    it_check 'HAProxy route retains HTTPS public scheme' '"X-Forwarded-Proto": "https"' "$EDGE"
    EDGE="$(edge "$FIRST" /inspect -H 'CF-Connecting-IP: 203.0.113.51' -H 'X-Forwarded-For: 203.0.113.1')"
    it_check 'HAProxy replaces spoofed headers from untrusted peers' '"X-Real-IP": "127.0.0.1"' "$EDGE"
else
    it_log 'HAProxy executable unavailable: outer TLS hop skipped; direct nginx trust/routing tests ran.'
fi
it_summary
