#!/usr/bin/env bash
# Exercise the actual dedicated MCP nginx route with a stdlib Unix-socket
# upstream. Protocol behavior belongs to the ASGI tests; this test requires
# neither a published MCP package nor managed Python/systemd installation.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
export GB_REPO_DIR="$IT_ROOT" GB_NGINX_USER="$IT_NGINX_USER"
for lib in core config registry nginx access pages endpoint; do
    # shellcheck source=/dev/null
    source "$IT_ROOT/src/lib/$lib.sh"
done
MCP_IT_PORT=18981
MCP_IT_DOMAIN=mcp.example.test
MCP_IT_ECHO_PID=""
cleanup() {
    local result="$?"
    if (( result != 0 )); then
        it_failure_logs
        [[ ! -f "$IT_SB/capture.log" ]] || tail -20 "$IT_SB/capture.log"
    fi
    it_nginx_stop
    if [[ -n "$MCP_IT_ECHO_PID" ]]; then
        kill "$MCP_IT_ECHO_PID" 2>/dev/null || true
        wait "$MCP_IT_ECHO_PID" 2>/dev/null || true
    fi
    gb_cleanup
    rm -rf -- "$IT_SB"
}
trap cleanup EXIT

mkdir -p "$GB_ETC"
cat > "$GB_GLOBAL_CONF" <<EOF
TLS_MODE=external
TRUSTED_PROXY_CIDRS=127.0.0.2/32
PUBLIC_SCHEME=https
ORIGIN_HTTP_PORT=$MCP_IT_PORT
EOF
ep_create "$MCP_IT_DOMAIN" mcp mcp
ep_set "$MCP_IT_DOMAIN" ACCESS_MODE token
ep_set "$MCP_IT_DOMAIN" LIVE false
ep_set "$MCP_IT_DOMAIN" DOCS_SOURCE none
ep_set "$MCP_IT_DOMAIN" FAVICON_SOURCE none
ep_set "$MCP_IT_DOMAIN" LOGO_SOURCE none
endpoint_source_type mcp
MCP_IT_GENERATION="$(mcp_root "$MCP_IT_DOMAIN")/deployments/fixture"
mkdir -p "$MCP_IT_GENERATION" "$(ep_log_dir "$MCP_IT_DOMAIN")" "$GB_NGINX/sites-enabled"
printf '%s\n' "$IT_SB/capture.sock" > "$MCP_IT_GENERATION/.socket"
gb_switch_link "$MCP_IT_GENERATION" "$(mcp_root "$MCP_IT_DOMAIN")/active"
MCP_IT_TOKEN_JSON="$(tokens_add "$MCP_IT_DOMAIN" 'MCP proxy fixture')"
MCP_IT_TOKEN="$(printf '%s' "$MCP_IT_TOKEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
MCP_IT_TOKEN_ID="$(printf '%s' "$MCP_IT_TOKEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

# Copy the complete production render unchanged, including auth, identity,
# error and access-log definitions. Only the service behind its socket is a
# fixture, so duplicate roots or invalid proxy directives fail nginx -t.
MCP_IT_STAGE="$IT_SB/stage"
nginx_render_global "$MCP_IT_STAGE"
ep_load "$MCP_IT_DOMAIN"
nginx_render_endpoint "$MCP_IT_STAGE"
cp -a "$MCP_IT_STAGE/." "$GB_NGINX/"
ln -s "$(nginx_site_file "$MCP_IT_DOMAIN")" "$(nginx_enabled_file "$MCP_IT_DOMAIN")"

cat > "$IT_SB/capture.py" <<'PY'
import http.server
import json
import os
import socketserver
import sys


class Capture(http.server.BaseHTTPRequestHandler):
    def respond(self):
        self.server.sequence += 1
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        document = {"headers": dict(self.headers.items()), "method": self.command,
                    "path": self.path, "body": body.decode(), "sequence": self.server.sequence}
        payload = json.dumps(document).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        # Deliberately cacheable: the managed MCP route must replace this.
        self.send_header("Cache-Control", "public, max-age=600")
        self.send_header("X-Request-ID", "untrusted-upstream-id")
        self.send_header("X-GetBible-Telemetry-Endpoint-Kind", "mcp")
        self.send_header("X-GetBible-Telemetry-Operation", "ping")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_GET = do_HEAD = do_POST = respond

    def log_message(self, *args):
        pass


with socketserver.UnixStreamServer(sys.argv[1], Capture) as server:
    server.sequence = 0
    os.chmod(sys.argv[1], 0o666)
    server.serve_forever()
PY
python3 "$IT_SB/capture.py" "$IT_SB/capture.sock" > "$IT_SB/capture.log" 2>&1 &
MCP_IT_ECHO_PID=$!
for attempt in {1..30}; do [[ -S "$IT_SB/capture.sock" ]] && break; sleep .1; done
[[ -S "$IT_SB/capture.sock" ]]
it_nginx_start

origin() {
    local path="$1"
    shift
    curl --silent --show-error --noproxy '*' --max-time 5 \
        --header "Host: $MCP_IT_DOMAIN" "$@" "http://127.0.0.1:$MCP_IT_PORT$path"
}
status() { origin "$@" -o /dev/null -w '%{http_code}'; }
field() {
    python3 -c 'import json,sys; value=json.load(sys.stdin)
for key in sys.argv[1:]: value=value[key]
print(value)' "$@"
}

it_log 'Dedicated MCP transport and public health routes'
it_check 'root POST requires a token' 401 "$(status / -X POST -d '{}')"
it_check 'unauthorized root response cannot be cached' 'Cache-Control: no-store' "$(origin / -X POST -d '{}' -D - -o /dev/null)"
it_check 'invalid token is rejected' 401 "$(status / -X POST -H 'Authorization: Bearer invalid' -d '{}')"
it_check 'valid token reaches root POST' 200 "$(status / -X POST -H "Authorization: Bearer $MCP_IT_TOKEN" -d '{}')"
for path in /healthz /readyz; do
    it_check "$path remains public" 200 "$(status "$path")"
    it_check "$path cannot be cached" 'Cache-Control: no-store' "$(origin "$path" -D - -o /dev/null)"
done
for path in /mcp /mcp/ /v2 /v2/ /v3/ /versions.json /openapi.json; do
    it_check "$path is not an MCP route" 404 "$(status "$path" -H "Authorization: Bearer $MCP_IT_TOKEN")"
done
it_check 'unversioned root preflight stays public' 204 "$(status / -X OPTIONS)"
it_check 'unsupported root method is rejected' 405 "$(status / -X DELETE -H "Authorization: Bearer $MCP_IT_TOKEN")"
it_check 'method rejection advertises protocol POST' 'Allow: GET, HEAD, POST, OPTIONS' "$(origin / -X DELETE -H "Authorization: Bearer $MCP_IT_TOKEN" -D - -o /dev/null)"
it_check 'root response overrides upstream caching' 'Cache-Control: no-store' "$(origin / -H "Authorization: Bearer $MCP_IT_TOKEN" -D - -o /dev/null)"

MCP_IT_HEADERS="$(origin / -H "Authorization: Bearer $MCP_IT_TOKEN" -D - -o /dev/null)"
it_check 'one public request ID is emitted' 1 "$(printf '%s\n' "$MCP_IT_HEADERS" | grep -ic '^X-Request-ID:')"
it_check 'internal operation header is hidden' '' "$(printf '%s\n' "$MCP_IT_HEADERS" | grep -i '^X-GetBible-Telemetry-' || true)"

MCP_IT_TRUSTED="$(origin / --interface 127.0.0.2 -X POST -H "Authorization: Bearer $MCP_IT_TOKEN" \
    -H 'Content-Type: application/json' -H 'X-Forwarded-For: 203.0.113.40' \
    -H 'X-Real-IP: 203.0.113.99' -H 'X-Forwarded-Proto: http' \
    -H 'X-Forwarded-Host: forged.example.test' -H 'X-Request-ID: forged-request' \
    -H 'X-GetBible-Token-Id: forged-id' -H 'X-GetBible-Auth-State: anonymous' \
    -d '{"jsonrpc":"2.0","id":1,"method":"ping"}')"
it_check 'transport remains at the domain root' / "$(printf '%s' "$MCP_IT_TRUSTED" | field path)"
it_check 'JSON POST body reaches the service' '"method":"ping"' "$(printf '%s' "$MCP_IT_TRUSTED" | field body)"
it_check 'public hostname reaches the service' "$MCP_IT_DOMAIN" "$(printf '%s' "$MCP_IT_TRUSTED" | field headers Host)"
it_check 'trusted client address is normalized' 203.0.113.40 "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-Real-IP)"
it_check 'forwarding chain is replaced' 203.0.113.40 "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-Forwarded-For)"
it_check 'public scheme ignores forged input' https "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-Forwarded-Proto)"
it_check 'forwarded host ignores forged input' "$MCP_IT_DOMAIN" "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-Forwarded-Host)"
it_check 'nginx supplies the verified token ID' "$MCP_IT_TOKEN_ID" "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-GetBible-Token-Id)"
it_check 'nginx supplies authentication state' valid "$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-GetBible-Auth-State)"
it_check 'bearer is removed before the service' false "$(printf '%s' "$MCP_IT_TRUSTED" | python3 -c 'import json,sys; print(str(any(key.lower()=="authorization" for key in json.load(sys.stdin)["headers"])).lower())')"
MCP_IT_REQUEST_ID="$(printf '%s' "$MCP_IT_TRUSTED" | field headers X-Request-ID)"
it_check 'nginx replaces the caller request ID' true "$([[ "$MCP_IT_REQUEST_ID" =~ ^[0-9a-f]{32}$ ]] && printf true || printf false)"
MCP_IT_LOG="$(it_wait_log "$(ep_log_dir "$MCP_IT_DOMAIN")/access.log" "\"request_id\":\"$MCP_IT_REQUEST_ID\"" 5)"
it_check 'access log records safe token identity' "\"token\":\"$MCP_IT_TOKEN_ID\"" "$MCP_IT_LOG"
it_check 'access log records authentication' '"auth_state":"valid"' "$MCP_IT_LOG"
it_check 'access log records the public scheme' '"scheme":"https"' "$MCP_IT_LOG"
it_check 'access log records the trusted client' '"remote_addr":"203.0.113.40"' "$MCP_IT_LOG"
it_check 'access log records root POST' '"uri":"/"' "$MCP_IT_LOG"
it_check 'access log records the request method' '"method":"POST"' "$MCP_IT_LOG"
it_check 'access log never stores the bearer' false "$(if grep -Fq -- "$MCP_IT_TOKEN" "$(ep_log_dir "$MCP_IT_DOMAIN")/access.log"; then printf true; else printf false; fi)"

MCP_IT_UNTRUSTED="$(origin / -H "Authorization: Bearer $MCP_IT_TOKEN" -H 'X-Forwarded-For: 203.0.113.99' -H 'CF-Connecting-IP: 203.0.113.98')"
it_check 'untrusted client cannot forge an address' 127.0.0.1 "$(printf '%s' "$MCP_IT_UNTRUSTED" | field headers X-Real-IP)"
it_check 'untrusted forwarding chain is replaced' 127.0.0.1 "$(printf '%s' "$MCP_IT_UNTRUSTED" | field headers X-Forwarded-For)"
MCP_IT_SEQUENCE="$(printf '%s' "$MCP_IT_UNTRUSTED" | field sequence)"
it_check 'repeated root GET is forwarded without cache reuse' "$((MCP_IT_SEQUENCE + 1))" "$(origin / -H "Authorization: Bearer $MCP_IT_TOKEN" | field sequence)"
it_summary
