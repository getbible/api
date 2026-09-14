#!/usr/bin/env bash
# Production deployment acceptance test. This changes real /etc, /opt, /srv
# and systemd state and may run ONLY on a fresh disposable Linux VM.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "${GB_CI_DISPOSABLE_HOST:-}" == 1 && "$(id -u)" == 0 && -d /run/systemd/system ]] || {
    echo 'Requires root, systemd, and GB_CI_DISPOSABLE_HOST=1 on a disposable VM.' >&2
    exit 1
}
[[ ! -d /etc/getbible/endpoints && ! -d /opt/getbible/query && ! -d /opt/getbible/search && ! -d /opt/getbible/mcp && ! -e /srv/getbible-ci ]] || {
    echo 'Refusing to run on a host with an existing getBible deployment.' >&2
    exit 1
}
unset GB_PREFIX GB_SYSTEMCTL GB_NGINX_BIN GB_NGINX_FAKE_VERSION GB_NGINX_FAKE_IPV6
export GB_YES=true GB_UI=none NO_PROXY='*' no_proxy='*' GB_VERIFY_PUBLIC=false
# Live fixtures have an explicit CA trust bundle; production never retries
# untrusted certificates with --insecure.
export CURL_CA_BUNDLE=/srv/getbible-ci/ca-bundle.crt
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
GB="$ROOT/getbible.sh"
Q=query.ci.example.test
S=search.ci.example.test
M=mcp.ci.example.test
MCP_UPSTREAM_PID=""
MCP_TOKEN=""
MCP_PROTOCOL=2026-07-28
MCP_ROOT=/opt/getbible/mcp/mcp_ci_example_test
PROBE_PID=""
PROBE_STOP=/srv/getbible-ci/probe.stop
PROBE_LOG=/srv/getbible-ci/probe.log
PASS=0

check() {
    local label="$1" expected="$2" actual="$3"
    [[ "$actual" == "$expected" ]] || {
        printf 'FAIL: %s; expected %s, got %s\n' "$label" "$expected" "$actual" >&2
        return 1
    }
    PASS=$((PASS + 1))
    printf 'ok: %s\n' "$label"
}

cleanup() {
    local result="$?"
    trap - EXIT
    [[ -z "$PROBE_PID" ]] || { touch "$PROBE_STOP"; wait "$PROBE_PID" || true; }
    if (( result != 0 )); then
        journalctl -u 'getbible-*' --no-pager -n 200 || true
        for diagnostic in /var/log/nginx/error.log /var/log/getbible/*/error.log /var/log/getbible/*/app/*.log; do
            [[ -f "$diagnostic" ]] || continue
            printf '\nFailure diagnostic: %s\n' "$diagnostic"
            tail -80 "$diagnostic" || true
        done
        [[ ! -f "$PROBE_LOG" ]] || tail -30 "$PROBE_LOG"
    fi
    "$GB" remove "$Q" --purge >/dev/null 2>&1 || true
    "$GB" remove "$S" --purge >/dev/null 2>&1 || true
    "$GB" remove "$M" --purge >/dev/null 2>&1 || true
    [[ -z "$MCP_UPSTREAM_PID" ]] || { kill "$MCP_UPSTREAM_PID" 2>/dev/null || true; wait "$MCP_UPSTREAM_PID" 2>/dev/null || true; }
    rm -rf /srv/getbible-ci "/etc/getbible/placeholder-certs/$S" \
        "/etc/letsencrypt/live/$Q" "/etc/letsencrypt/live/$S" "/etc/letsencrypt/live/$M"
    rmdir /etc/getbible/endpoints 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT

request() {
    local domain="$1" path="$2"
    shift 2
    local -a flags=()
    [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || flags+=(--insecure)
    curl --fail-with-body --silent --show-error "${flags[@]}" --noproxy '*' --max-time 10 \
        --resolve "$domain:443:127.0.0.1" "$@" "https://$domain$path"
}

deployment() { readlink -f "/opt/getbible/$1/v2/active"; }
unit() { printf 'getbible-%s-v2-%s.service\n' "$1" "$(basename "$(deployment "$1")")"; }
main_pid() { systemctl show --property=MainPID --value "$(unit "$1")"; }
env_value() (
    # shellcheck source=/dev/null
    source "$1"
    printf '%s\n' "${!2}"
)

start_probe() {
    rm -f "$PROBE_STOP"
    : > "$PROBE_LOG"
    (
        while [[ ! -e "$PROBE_STOP" ]]; do
            request "$Q" /v2/test/Ge1:1 >/dev/null || { echo 'FAIL: query unavailable'; exit 1; }
            request "$S" /v2/test/beginning >/dev/null || { echo 'FAIL: search unavailable'; exit 1; }
            if [[ -L "$MCP_ROOT/active" ]]; then request "$M" /readyz >/dev/null || { echo 'FAIL: MCP unavailable'; exit 1; }; fi
            echo ok
            sleep 0.1
        done
    ) >> "$PROBE_LOG" 2>&1 &
    PROBE_PID="$!"
}

stop_probe() {
    touch "$PROBE_STOP"
    local failed=0
    wait "$PROBE_PID" || failed=1
    PROBE_PID=""
    check 'all requests succeed throughout change' 0 "$failed"
    [[ "$(wc -l < "$PROBE_LOG")" -gt 0 ]]
}

install -d -m 0755 /srv/getbible-ci
cp -a "$ROOT/tests/python/fixtures/repository" /srv/getbible-ci/repository
chmod -R a+rX /srv/getbible-ci/repository

preseed_certificate() {
    install -d -m 0700 "/etc/letsencrypt/live/$1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "/etc/letsencrypt/live/$1/privkey.pem" \
        -out "/etc/letsencrypt/live/$1/fullchain.pem" -subj "/CN=$1" \
        -addext "subjectAltName=DNS:$1" 2>/dev/null
    cat "/etc/letsencrypt/live/$1/fullchain.pem" >> "$CURL_CA_BUNDLE"
}
contains() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }

# query goes live at once with a preseeded certificate, so deployment never
# invokes ACME for a test domain. search is staged first: it serves through
# its placeholder certificate, is verified, and goes live once a certificate
# exists, all against real systemd and nginx.
for kind in query search; do
    domain="$kind.ci.example.test"
    if [[ "$kind" == query ]]; then
        preseed_certificate "$domain"
        "$GB" deploy runtime --domain "$domain" --kind "$kind" --repository /srv/getbible-ci/repository \
            --default-translation test --default-reference Ge1:1 --warm test --access open
    else
        "$GB" deploy runtime --domain "$domain" --kind "$kind" --repository /srv/getbible-ci/repository \
            --default-translation test --default-reference Ge1:1 --warm test --access open --staged
        check "$kind recorded staged" LIVE=false "$(grep '^LIVE=' "/etc/getbible/endpoints/$domain/endpoint.conf")"
        check "$kind serves its placeholder certificate" yes "$(contains "$domain" "$(openssl s_client -connect 127.0.0.1:443 -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -subject)")"
        check "$kind staged ready through nginx" '{"status":"ready"}' "$(request "$domain" /readyz | tr -d '\n')"
        VERIFY="$("$GB" verify "$domain")"
        check "$kind verify sees the placeholder" yes "$(contains 'Certificate                    WARN  self-signed placeholder' "$VERIFY")"
        check "$kind verify probes readiness" yes "$(contains 'GET /readyz                    ok' "$VERIFY")"
        check "$kind verify passes" yes "$(contains 'everything that can be checked here passed' "$VERIFY")"
        preseed_certificate "$domain"
        "$GB" go-live "$domain"
        check "$kind live after go-live" LIVE=true "$(grep '^LIVE=' "/etc/getbible/endpoints/$domain/endpoint.conf")"
        check "$kind placeholder removed" no "$(contains yes "$([[ -d "/etc/getbible/placeholder-certs/$domain" ]] && echo yes || echo no)")"
        check "$kind serves the certificate" yes "$(contains "/etc/letsencrypt/live/$domain/fullchain.pem" "$(cat "/etc/nginx/sites-available/$domain.conf")")"
        VERIFY="$("$GB" verify "$domain")"
        check "$kind verify after go-live" yes "$(contains 'GET /readyz                    ok' "$VERIFY")"
    fi
    check "$kind ready through nginx" '{"status":"ready"}' "$(request "$domain" /readyz | tr -d '\n')"
    check "$kind runs as the production account" "$(id -u "getbible-$kind")" "$(ps -o uid= -p "$(main_pid "$kind")" | tr -d ' ')"
    check "$kind systemd isolation enabled" strict "$(systemctl show --property=ProtectSystem --value "$(unit "$kind")")"
    check "$kind code is read-only to its account" no "$(runuser -u "getbible-$kind" -- test -w "/opt/getbible/$kind/v2/current" && echo yes || echo no)"
    check "$kind cannot read token configuration" no "$(runuser -u "getbible-$kind" -- test -r /etc/getbible/getbible.conf && echo yes || echo no)"
    release="$(readlink -f "/opt/getbible/$kind/v2/current")"
    base_python="$("$release/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
    [[ "$base_python" == /opt/getbible/* ]] || { echo "Runtime depends on host Python: $base_python" >&2; exit 1; }
    check "$kind pinned dependencies consistent" 'No broken requirements found.' "$("$release/.venv/bin/python" -m pip check)"
done
request "$Q" /v2/test/Ge1:1 | /usr/bin/python3 -c 'import json,sys; assert "test_1_1" in json.load(sys.stdin)'
request "$S" /v2/test/beginning | /usr/bin/python3 -c 'import json,sys; payload=json.load(sys.stdin); assert payload["query"]["kind"] == "search", payload'

# The real MCP ASGI service reads one local fixture upstream. Its response is
# copied from the already verified query service, with no public API access.
# The native query fixture uses a self-signed certificate; this explicit HTTP
# fixture avoids altering certifi or weakening production TLS verification.
request "$Q" /v2/test/Ge1:1 > /srv/getbible-ci/mcp-query.json
cat > /srv/getbible-ci/mcp-upstream.py <<'PYMCPUPSTREAM'
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import unquote

class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        if unquote(self.path) != "/v2/test/Ge1:1" or self.headers.get("Host") != "query.ci.example.test":
            self.send_error(404)
            return
        data = Path("/srv/getbible-ci/mcp-query.json").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *_args):
        pass

HTTPServer(("127.0.0.1", 18982), Upstream).serve_forever()
PYMCPUPSTREAM
/usr/bin/python3 /srv/getbible-ci/mcp-upstream.py > /srv/getbible-ci/mcp-upstream.log 2>&1 &
MCP_UPSTREAM_PID=$!
MCP_DEADLINE=$((SECONDS + 15))
until curl --silent --fail --max-time 2 -H "Host: $Q" http://127.0.0.1:18982/v2/test/Ge1:1 >/dev/null; do
    (( SECONDS < MCP_DEADLINE )) || { echo 'Local MCP fixture did not start.' >&2; exit 1; }
    sleep .2
done
printf 'GETBIBLE_QUERY_V2_BASE=https://%s/v2\n' "$Q" > /srv/getbible-ci/mcp.env
chmod 0600 /srv/getbible-ci/mcp.env
preseed_certificate "$M"
"$GB" deploy mcp --domain "$M" --access open --origin http://127.0.0.1:18982 --env-file /srv/getbible-ci/mcp.env
mcp_deployment() { readlink -f "$MCP_ROOT/active"; }
mcp_unit() { printf '%s.service\n' "$(cat "$(mcp_deployment)/.unit")"; }
mcp_pid() { systemctl show --property=MainPID --value "$(mcp_unit)"; }
mcp_rpc() {
    local id="$1" method="$2" params="$3" body
    local -a auth=() routing=()
    if [[ "$method" == tools/call ]]; then
        routing=(-H "MCP-Name: $(printf '%s' "$params" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')")
    fi
    [[ -z "$MCP_TOKEN" ]] || auth=(-H "Authorization: Bearer $MCP_TOKEN")
    body="$(/usr/bin/python3 -c 'import json,sys; params=json.loads(sys.argv[3]); params["_meta"]={"io.modelcontextprotocol/protocolVersion":sys.argv[4],"io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"NativeAcceptance","version":"1.0"}}; print(json.dumps({"jsonrpc":"2.0","id":int(sys.argv[1]),"method":sys.argv[2],"params":params}))' "$id" "$method" "$params" "$MCP_PROTOCOL")"
    request "$M" / -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H "MCP-Protocol-Version: $MCP_PROTOCOL" -H "MCP-Method: $method" "${auth[@]}" "${routing[@]}" \
        -D /srv/getbible-ci/mcp-response.headers --data "$body"
}
MCP_DISCOVERY="$(mcp_rpc 1 server/discover '{}')"
printf '%s' "$MCP_DISCOVERY" | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert "error" not in p and sys.argv[1] in p["result"]["supportedVersions"],p' "$MCP_PROTOCOL"
mcp_rpc 2 tools/list '{}' | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert "query_verses" in {t["name"] for t in p["result"]["tools"]},p'
MCP_QUERY='{"name":"query_verses","arguments":{"translation":"test","references":"Ge1:1","api_version":"v2"}}'
mcp_rpc 3 tools/call "$MCP_QUERY" | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert not p.get("error") and not p["result"].get("isError"),p; assert "test_1_1" in json.dumps(p),p'
check 'MCP has no version records' no "$([[ -d "/etc/getbible/endpoints/$M/versions" ]] && echo yes || echo no)"
check 'MCP uses actual production account' "$(id -u getbible-mcp)" "$(ps -o uid= -p "$(mcp_pid)" | tr -d ' ')"
check 'MCP systemd readiness notification completed' active "$(systemctl is-active "$(mcp_unit)")"
check 'MCP systemd isolation enabled' strict "$(systemctl show --property=ProtectSystem --value "$(mcp_unit)")"
check 'MCP code is read-only to its account' no "$(runuser -u getbible-mcp -- test -w "$MCP_ROOT/current" && echo yes || echo no)"
check 'MCP spool directory belongs to its account' getbible-mcp:getbible-mcp "$(stat -c '%U:%G' "/var/log/getbible/$M/app")"
check 'MCP request spool belongs to its account' getbible-mcp:getbible-mcp "$(stat -c '%U:%G' "/var/log/getbible/$M/app/mcp.log")"
check 'MCP request spool is private to service/root' 640 "$(stat -c '%a' "/var/log/getbible/$M/app/mcp.log")"
check 'MCP spool remains writable inside its account' yes "$(runuser -u getbible-mcp -- test -w "/var/log/getbible/$M/app/mcp.log" && echo yes || echo no)"
MCP_RELEASE="$(readlink -f "$MCP_ROOT/current")"
check 'MCP and common package dependencies are complete' 'No broken requirements found.' "$("$MCP_RELEASE/.venv/bin/python" -m pip check)"
"$MCP_RELEASE/.venv/bin/python" -c 'import getbible_api_common.logging, getbible_mcp_api.app, uvicorn_worker'
MCP_TOKEN="$("$GB" token "$M" add 'native MCP fixture' | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
check 'MCP cannot read token registry' no "$(runuser -u getbible-mcp -- test -r "/etc/getbible/endpoints/$M/tokens.json" && echo yes || echo no)"
"$GB" access "$M" token
check 'MCP root keeps token access policy' 401 "$(curl --silent --show-error --noproxy '*' --max-time 10 --resolve "$M:443:127.0.0.1" -X POST -d '{}' -o /dev/null -w '%{http_code}' "https://$M/")"
mcp_rpc 4 tools/call "$MCP_QUERY" > /srv/getbible-ci/mcp-call.json
/usr/bin/python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); assert not p.get("error") and not p["result"].get("isError"),p' /srv/getbible-ci/mcp-call.json
MCP_REQUEST_ID="$(sed -n 's/^[Xx]-[Rr]equest-[Ii][Dd]: *//p' /srv/getbible-ci/mcp-response.headers | tr -d '\r' | tail -1)"
[[ "$MCP_REQUEST_ID" =~ ^[0-9a-f]{32}$ ]]
/usr/bin/python3 - "$M" "$MCP_REQUEST_ID" <<'PYMCPTELEMETRY'
import json, sqlite3, sys, time
for _ in range(180):
    with sqlite3.connect("file:/var/lib/getbible/telemetry/traffic.sqlite3?mode=ro", uri=True, timeout=5) as db:
        rows = db.execute("SELECT endpoint_kind,edge_json,runtime_json FROM requests WHERE endpoint=? AND request_id=?", sys.argv[1:]).fetchall()
    if rows and rows[0][1] and rows[0][2]:
        assert len(rows) == 1 and rows[0][0] == "mcp", rows
        edge, runtime = json.loads(rows[0][1]), json.loads(rows[0][2])
        assert edge["auth_state"] == "valid", edge
        assert runtime["mcp_tool"] == "query_verses" and runtime["mcp_outcome"] == "success", runtime
        assert runtime["upstream_service"] == "query" and runtime["upstream_api_version"] == "v2", runtime
        print("ok: MCP request collected once with edge, protocol, token and upstream facts")
        break
    time.sleep(.25)
else:
    raise AssertionError("MCP request was not joined by the actual telemetry collector")
PYMCPTELEMETRY
# Stopping only the service proves that the managed socket activates its real
# Gunicorn process again; the public nginx route remains unchanged.
MCP_OLD_PID="$(mcp_pid)"
systemctl stop "$(mcp_unit)"
mcp_rpc 5 server/discover '{}' | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert "result" in p and not p.get("error"),p'
[[ "$(mcp_pid)" != "$MCP_OLD_PID" ]]
check 'MCP restarts through socket activation' active "$(systemctl is-active "$(mcp_unit)")"
MCP_OLD_GENERATION="$(mcp_deployment)"
MCP_OLD_UNIT="$(mcp_unit)"
"$GB" mcp update "$M"
[[ "$(mcp_deployment)" != "$MCP_OLD_GENERATION" ]]
mcp_rpc 6 tools/call "$MCP_QUERY" | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert not p.get("error") and not p["result"].get("isError"),p'
MCP_DEADLINE=$((SECONDS + 60))
while systemctl is-active --quiet "$MCP_OLD_UNIT"; do
    (( SECONDS < MCP_DEADLINE )) || { echo 'Previous MCP worker did not retire after nginx drain.' >&2; exit 1; }
    sleep .2
done
"$GB" mcp rollback "$M"
check 'MCP rollback restores retained code' "$MCP_RELEASE" "$(readlink -f "$MCP_ROOT/current")"
mcp_rpc 7 tools/list '{}' | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["result"]["tools"],p'

NGINX_PID="$(systemctl show --property=MainPID --value nginx)"
OLD_DEPLOYMENT="$(deployment query)"
OLD_PID="$(main_pid query)"
OLD_RELEASE="$(readlink -f /opt/getbible/query/v2/current)"

"$GB" apply "$Q"
check 'idempotent apply preserves process' "$OLD_PID" "$(main_pid query)"
check 'idempotent apply preserves deployment' "$OLD_DEPLOYMENT" "$(deployment query)"

start_probe
"$GB" runtime "$Q" set DEFAULT_REFERENCE Ge1:2
stop_probe
NEW_DEPLOYMENT="$(deployment query)"
[[ "$NEW_DEPLOYMENT" != "$OLD_DEPLOYMENT" ]] || { echo 'Configuration update reused the active generation.' >&2; exit 1; }
check 'configuration update reuses immutable code' "$OLD_RELEASE" "$(readlink -f /opt/getbible/query/v2/current)"
check 'old configuration retained for rollback' Ge1:1 "$(env_value "$OLD_DEPLOYMENT/runtime.env" QUERY_DEFAULT_REFERENCE)"
check 'new service reads updated configuration' QUERY_DEFAULT_REFERENCE=Ge1:2 "$(tr '\0' '\n' < "/proc/$(main_pid query)/environ" | grep '^QUERY_DEFAULT_REFERENCE=')"

# The same rejected-update fixture used by Docker must preserve serving
# generations under real systemd before any image is built.
install -d -m 0755 /srv/getbible-ci/broken-checkout
tar --exclude=.git --exclude=.venv-test --exclude=__pycache__ --exclude=build \
    -C "$ROOT" -cf - . | tar -C /srv/getbible-ci/broken-checkout -xf -
bash "$ROOT/tests/integration/prepare-image-fixture.sh" \
    /srv/getbible-ci/broken-checkout "$(cat "$ROOT/VERSION")" true
ACTIVE_PID="$(main_pid query)"
start_probe
if /srv/getbible-ci/broken-checkout/getbible.sh apply "$Q"; then
    echo 'A broken candidate was accepted.' >&2
    exit 1
fi
stop_probe
check 'failed upgrade preserves active generation' "$NEW_DEPLOYMENT" "$(deployment query)"
check 'failed upgrade preserves active process' "$ACTIVE_PID" "$(main_pid query)"
check 'failed upgrade preserves active code' "$OLD_RELEASE" "$(readlink -f /opt/getbible/query/v2/current)"
check 'failed upgrade preserves configuration' Ge1:2 "$(env_value "$(deployment query)/runtime.env" QUERY_DEFAULT_REFERENCE)"

MCP_RETAINED_GENERATION="$(mcp_deployment)"
MCP_RETAINED_PID="$(mcp_pid)"
if /srv/getbible-ci/broken-checkout/getbible.sh mcp update "$M"; then
    echo 'A broken MCP candidate was accepted.' >&2
    exit 1
fi
check 'failed MCP upgrade preserves serving generation' "$MCP_RETAINED_GENERATION" "$(mcp_deployment)"
check 'failed MCP upgrade preserves serving process' "$MCP_RETAINED_PID" "$(mcp_pid)"
mcp_rpc 8 server/discover '{}' | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin); assert "result" in p and not p.get("error"),p'

start_probe
"$GB" runtime "$Q" rollback
stop_probe
check 'rollback restores original configuration' QUERY_DEFAULT_REFERENCE=Ge1:1 "$(tr '\0' '\n' < "/proc/$(main_pid query)/environ" | grep '^QUERY_DEFAULT_REFERENCE=')"
check 'all deployments preserve nginx master' "$NGINX_PID" "$(systemctl show --property=MainPID --value nginx)"
check 'query ready after rollback' '{"status":"ready"}' "$(request "$Q" /readyz | tr -d '\n')"

# Exercise certbot's installed deploy hook with a newly issued fixture
# certificate. No ACME request or public DNS is needed; nginx must serve the
# replacement through its existing master while both applications stay healthy.
check 'automatic certificate renewal timer enabled' enabled "$(systemctl is-enabled certbot.timer)"
check 'automatic certificate renewal timer active' active "$(systemctl is-active certbot.timer)"
RENEWAL_HOOK=/etc/letsencrypt/renewal-hooks/deploy/getbible-reload-nginx.sh
check 'certificate renewal deploy hook executable' yes "$([[ -x "$RENEWAL_HOOK" ]] && echo yes || echo no)"
served_certificate_serial() {
    timeout 3 openssl s_client -connect 127.0.0.1:443 -servername "$1" \
        -verify_hostname "$1" -verify_return_error -CAfile "$CURL_CA_BUNDLE" \
        </dev/null 2>/dev/null | openssl x509 -noout -serial
}
OLD_CERT_SERIAL="$(openssl x509 -in "/etc/letsencrypt/live/$Q/fullchain.pem" -noout -serial)"
check 'query serves original verified certificate' "$OLD_CERT_SERIAL" "$(served_certificate_serial "$Q")"
preseed_certificate "$Q"
NEW_CERT_SERIAL="$(openssl x509 -in "/etc/letsencrypt/live/$Q/fullchain.pem" -noout -serial)"
[[ "$NEW_CERT_SERIAL" != "$OLD_CERT_SERIAL" ]] || { echo 'Renewal fixture reused the original certificate.' >&2; exit 1; }
start_probe
RENEWED_DOMAINS="$Q" RENEWED_LINEAGE="/etc/letsencrypt/live/$Q" "$RENEWAL_HOOK"
RENEWAL_DEADLINE=$((SECONDS + 15))
SERVED_CERT_SERIAL=""
while (( SECONDS < RENEWAL_DEADLINE )); do
    SERVED_CERT_SERIAL="$(served_certificate_serial "$Q" 2>/dev/null)" || SERVED_CERT_SERIAL=""
    [[ "$SERVED_CERT_SERIAL" == "$NEW_CERT_SERIAL" ]] && break
    sleep 0.2
done
check 'nginx serves renewed verified certificate' "$NEW_CERT_SERIAL" "$SERVED_CERT_SERIAL"
stop_probe
check 'certificate renewal preserves nginx master' "$NGINX_PID" "$(systemctl show --property=MainPID --value nginx)"
check 'query ready after certificate renewal' '{"status":"ready"}' "$(request "$Q" /readyz | tr -d '\n')"
check 'search ready after certificate renewal' '{"status":"ready"}' "$(request "$S" /readyz | tr -d '\n')"
/usr/bin/python3 "$ROOT/tests/integration/infrastructure.py" --mode native --manager "$GB"
"$GB" remove "$M" --purge
check 'MCP removal deletes domain registry' no "$([[ -e "/etc/getbible/endpoints/$M" ]] && echo yes || echo no)"
check 'MCP removal retires every managed service' '' "$(systemctl list-units --type=service --state=active --no-legend 'getbible-mcp-*' | tr -d '[:space:]')"
check 'MCP purge removes its runtime tree' no "$([[ -e "$MCP_ROOT" ]] && echo yes || echo no)"
check 'MCP removal preserves nginx master' "$NGINX_PID" "$(systemctl show --property=MainPID --value nginx)"

printf '\n== %d production deployment checks passed ==\n' "$PASS"

