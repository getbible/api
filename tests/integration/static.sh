#!/usr/bin/env bash
# Boot real nginx from a sandbox deployment of a static endpoint and hold it
# to the promises the documentation makes.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
cleanup() {
    local result="$?"
    (( result == 0 )) || it_failure_logs
    it_nginx_stop
}
trap cleanup EXIT

DOMAIN="static.example.test"
it_log "sandbox $IT_SB"

# Deploy without certbot (HTTP only), then add a self-signed certificate and re-apply.
"$IT_ROOT/getbible.sh" deploy static --domain "$DOMAIN" --version v2 \
    --repo "file:///nonexistent/repo.git" --extensions json,sha,txt --access metered >/dev/null 2>&1
it_selfsigned "$DOMAIN"
"$IT_ROOT/getbible.sh" apply "$DOMAIN" >/dev/null 2>&1

# A fake release, published the way the sync engine does it.
REL="$IT_SB/srv/getbible/$DOMAIN/releases/v2/20260101T000000Z-abcdef1"
mkdir -p "$REL/kjv/1"
python3 -c 'import json; print(json.dumps({"book":1,"chapter":1,"verses":[{"verse":i,"text":"In the beginning God created the heaven and the earth. "*3} for i in range(1,32)]}))' > "$REL/kjv/1/1.json"
sha1sum "$REL/kjv/1/1.json" | cut -d' ' -f1 > "$REL/kjv/1/1.sha"
printf 'hello\n' > "$REL/kjv/readme.txt"
printf '<script>alert(1)</script>\n' > "$REL/kjv/evil.html"
printf 'secret\n' > "$REL/.hidden"
ln -sfn "releases/v2/20260101T000000Z-abcdef1" "$IT_SB/srv/getbible/$DOMAIN/v2"
# GB_PREFIX intentionally skips host account/group creation. Give this test
# fixture the equivalent reader-group access used by real static deployments.
chgrp -R "$IT_NGINX_USER" "$IT_SB/srv/getbible/$DOMAIN"
chmod -R g+rX "$IT_SB/srv/getbible/$DOMAIN"
runuser -u "$IT_NGINX_USER" -- test -r "$REL/kjv/1/1.json" \
    || { it_log "$IT_NGINX_USER cannot read the fixture release; check directory modes under $IT_SB/srv"; exit 1; }

# Tokens: one active token for the exemption test.
TOKEN="$("$IT_ROOT/getbible.sh" token "$DOMAIN" add "integration test" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"

it_nginx_start || exit 1

echo "-- documents --"
it_check "chapter json 200"          "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json)"
it_check "chapter content type"      "application/json" "$(it_header "$DOMAIN" /v2/kjv/1/1.json content-type)"
it_check "chapter cache-control"     "max-age=3600"     "$(it_header "$DOMAIN" /v2/kjv/1/1.json cache-control)"
it_check "chapter etag"              'etag: "'          "$(it_header "$DOMAIN" /v2/kjv/1/1.json etag)"
it_check "sha served as text"        "text/plain"       "$(it_header "$DOMAIN" /v2/kjv/1/1.sha content-type)"
it_check "sha cache-control"         "max-age=300"      "$(it_header "$DOMAIN" /v2/kjv/1/1.sha cache-control)"
it_check "txt served"                "200"              "$(it_status "$DOMAIN" /v2/kjv/readme.txt)"
it_check "html not allowlisted"      "404"              "$(it_status "$DOMAIN" /v2/kjv/evil.html)"
it_check "dotfile hidden"            "404"              "$(it_status "$DOMAIN" /v2/.hidden)"
it_check "directory not listed"      "404"              "$(it_status "$DOMAIN" /v2/kjv/)"
it_check "unknown version"           "404"              "$(it_status "$DOMAIN" /v9/kjv/1/1.json)"
it_check "docs page at root"         "200"              "$(it_status "$DOMAIN" /)"
it_check "docs page is html"         "text/html"        "$(it_header "$DOMAIN" / content-type)"
it_check "docs csp"                  "style-src"        "$(it_header "$DOMAIN" / content-security-policy)"
it_check "health"                    '{"status":"ok"}'  "$(it_body "$DOMAIN" /healthz)"

echo "-- headers --"
it_check "cors open"                 "access-control-allow-origin: *" "$(it_header "$DOMAIN" /v2/kjv/1/1.json access-control-allow-origin)"
it_check "nosniff"                   "nosniff"          "$(it_header "$DOMAIN" /v2/kjv/1/1.json x-content-type-options)"
it_check "csp locked"                "default-src 'none'" "$(it_header "$DOMAIN" /v2/kjv/1/1.json content-security-policy)"
it_check "hsts"                      "max-age=31536000" "$(it_header "$DOMAIN" /v2/kjv/1/1.json strict-transport-security)"
it_check "request id"                "x-request-id:"    "$(it_header "$DOMAIN" /v2/kjv/1/1.json x-request-id)"
it_check "server version hidden"     "server: nginx"    "$(it_header "$DOMAIN" /v2/kjv/1/1.json server)"
it_check "gzip on request"           "content-encoding: gzip" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -H 'Accept-Encoding: gzip' | grep -i '^content-encoding')"

echo "-- errors are problem documents --"
it_check "404 problem type"          "application/problem+json" "$(it_header "$DOMAIN" /v2/kjv/9/9.json content-type)"
it_check "404 problem body"          '"code":"not_found"' "$(it_body "$DOMAIN" /v2/kjv/9/9.json)"
it_check "query string rejected"     "400"              "$(it_status "$DOMAIN" '/v2/kjv/1/1.json?x=1')"
it_check "400 problem body"          '"code":"bad_request"' "$(it_body "$DOMAIN" '/v2/kjv/1/1.json?x=1')"
it_check "post rejected"             "405"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -X POST)"
it_check "405 problem body"          '"code":"method_not_allowed"' "$(it_body "$DOMAIN" /v2/kjv/1/1.json -X POST)"
it_check "preflight 204"             "204"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -X OPTIONS -H 'Origin: https://example.org' -H 'Access-Control-Request-Method: GET')"
it_check "preflight cors"            "access-control-allow-origin: *" "$(it_curl "$DOMAIN" /v2/kjv/1/1.json -X OPTIONS | grep -i '^access-control-allow-origin' | tr -d '\r')"

echo "-- metered access --"
"$IT_ROOT/getbible.sh" limits "$DOMAIN" --rate 5 --burst 10 --hour 60 --day 1000000 >/dev/null 2>&1
it_nginx_reload
it_check "limits rendered"           "burst=10"         "$(cat "$IT_SB/etc/nginx/getbible/$DOMAIN/limits.conf")"
for _ in $(seq 1 40); do it_status "$DOMAIN" /v2/kjv/1/1.json >/dev/null; done
it_check "burst exhausted -> 429"    "429"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json)"
it_check "429 problem body"          '"code":"rate_limited"' "$(it_body "$DOMAIN" /v2/kjv/1/1.json)"
it_check "429 retry-after"           "retry-after"      "$(it_header "$DOMAIN" /v2/kjv/1/1.json retry-after)"
it_check "token holder unlimited"    "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer $TOKEN")"
it_check "token id logged"           '"token":"tk_'     "$(it_wait_log "$IT_SB/var/log/getbible/$DOMAIN/access.log" '"token":"tk_')"
it_check "log has full uri"          '"uri":"/v2/kjv/1/1.json"' "$(tail -1 "$IT_SB/var/log/getbible/$DOMAIN/access.log")"

echo "-- token-only access --"
"$IT_ROOT/getbible.sh" access "$DOMAIN" token >/dev/null 2>&1
it_nginx_reload
it_check "no token -> 401"           "401"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json)"
it_check "401 www-authenticate"      "bearer"           "$(it_header "$DOMAIN" /v2/kjv/1/1.json www-authenticate)"
it_check "401 problem body"          '"code":"unauthorized"' "$(it_body "$DOMAIN" /v2/kjv/1/1.json)"
it_check "valid token -> 200"        "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer $TOKEN")"
it_check "protected JSON is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "protected SHA is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/1/1.sha -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "protected text is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/readme.txt -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "wrong token -> 401"        "401"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer gbwrong")"
it_check "docs still public"         "200"              "$(it_status "$DOMAIN" /)"
it_check "preflight still public"    "204"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -X OPTIONS)"

echo "-- open access --"
"$IT_ROOT/getbible.sh" access "$DOMAIN" open >/dev/null 2>&1
it_nginx_reload
for _ in $(seq 1 40); do it_status "$DOMAIN" /v2/kjv/1/1.json >/dev/null; done
it_check "open: no limits"           "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json)"

echo "-- live static rotation --"
# Keep requests flowing while exchanging complete releases. Every response
# must remain valid; a 404/5xx or a partial JSON document fails the test.
NEXT_REL="$IT_SB/srv/getbible/$DOMAIN/releases/v2/20260102T000000Z-abcdef2"
cp -a "$REL" "$NEXT_REL"
printf '{"rotation":"complete"}\n' > "$NEXT_REL/kjv/1/1.json"
MASTER_BEFORE="$(cat "$IT_SB/run/nginx.pid")"
(
    for _ in $(seq 1 50); do
        curl --silent --show-error --fail --insecure --noproxy '*' --max-time 5 \
            --resolve "$DOMAIN:$IT_HTTPS_PORT:127.0.0.1" \
            "https://$DOMAIN:$IT_HTTPS_PORT/v2/kjv/1/1.json" | python3 -c 'import json,sys; json.load(sys.stdin)' || exit 1
    done
) > "$IT_SB/rotation-probe.log" 2>&1 &
PROBE_PID="$!"
flip() { python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2"; }
for _ in $(seq 1 15); do
    ln -s "$NEXT_REL" "$IT_SB/srv/getbible/$DOMAIN/v2.next"
    flip "$IT_SB/srv/getbible/$DOMAIN/v2.next" "$IT_SB/srv/getbible/$DOMAIN/v2"
    ln -s "$REL" "$IT_SB/srv/getbible/$DOMAIN/v2.next"
    flip "$IT_SB/srv/getbible/$DOMAIN/v2.next" "$IT_SB/srv/getbible/$DOMAIN/v2"
done
if wait "$PROBE_PID"; then PROBE_RESULT=ok; else PROBE_RESULT="$(cat "$IT_SB/rotation-probe.log")"; fi
it_check "all requests valid during rotation" "ok" "$PROBE_RESULT"
it_check "rotation preserves nginx master" "$MASTER_BEFORE" "$(cat "$IT_SB/run/nginx.pid")"

echo "-- idempotent re-apply --"
BEFORE="$(find "$IT_SB/etc/nginx" -type f -exec sha256sum {} + | sort)"
"$IT_ROOT/getbible.sh" apply "$DOMAIN" >/dev/null 2>&1
AFTER="$(find "$IT_SB/etc/nginx" -type f -exec sha256sum {} + | sort)"
it_check "second apply changes nothing" "same" "$([[ "$BEFORE" == "$AFTER" ]] && echo same || echo different)"

it_summary
