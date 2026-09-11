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
# The repository ships the endpoint's OpenAPI document (the static default).
printf '{"openapi":"3.1.0","info":{"title":"static fixture","version":"v2"},"paths":{}}\n' > "$REL/openapi.json"
ln -sfn "releases/v2/20260101T000000Z-abcdef1" "$IT_SB/srv/getbible/$DOMAIN/v2"
# The system favicon every domain serves; publishing it re-applies the domain,
# and the pages notice the OpenAPI document that is now in the tree.
printf '\x00\x00\x01\x00' > "$IT_SB/icon.ico"
"$IT_ROOT/getbible.sh" favicon "$IT_SB/icon.ico" >/dev/null 2>&1
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
it_check "chapter cache-control"     "max-age=2592000"  "$(it_header "$DOMAIN" /v2/kjv/1/1.json cache-control)"
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
it_check "health not cacheable"      "no-store"         "$(it_header "$DOMAIN" /healthz cache-control)"
it_check "health cors remains open" "access-control-allow-origin: *" "$(it_header "$DOMAIN" /healthz access-control-allow-origin)"
it_check "health retains security headers" "nosniff" "$(it_header "$DOMAIN" /healthz x-content-type-options)"

echo "-- conditional requests --"
CHAPTER_ETAG="$(it_header "$DOMAIN" /v2/kjv/1/1.json etag | sed 's/^[^:]*: *//')"
CHAPTER_MODIFIED="$(it_header "$DOMAIN" /v2/kjv/1/1.json last-modified | sed 's/^[^:]*: *//')"
it_check "unchanged etag gives 304" "304" "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG")"
it_check "unchanged date gives 304" "304" "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "If-Modified-Since: $CHAPTER_MODIFIED")"
it_check "304 carries cache lifetime" "max-age=2592000" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG" | grep -i '^cache-control')"
it_check "304 carries validator" "$CHAPTER_ETAG" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG" | grep -i '^etag')"
it_check "HEAD carries validator" "$CHAPTER_ETAG" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -I | grep -i '^etag')"

echo "-- pages, OpenAPI documents, favicon --"
it_check "endpoint page 200"         "200"              "$(it_status "$DOMAIN" /v2/)"
it_check "endpoint page is html"     "text/html"        "$(it_header "$DOMAIN" /v2/ content-type)"
it_check "endpoint page names itself" "<code>/v2/</code>" "$(it_body "$DOMAIN" /v2/)"
it_check "endpoint page links openapi" 'href="/v2/openapi.json"' "$(it_body "$DOMAIN" /v2/)"
it_check "version redirects to folder" "location: https://$DOMAIN/v2/" "$(it_header "$DOMAIN" /v2 location)"
it_check "openapi from the tree"     '"openapi":"3.1.0"' "$(it_body "$DOMAIN" /v2/openapi.json | tr -d ' \n')"
it_check "openapi is json"           "application/json" "$(it_header "$DOMAIN" /v2/openapi.json content-type)"
it_check "openapi cacheable"         "max-age=300"      "$(it_header "$DOMAIN" /v2/openapi.json cache-control)"
it_check "versions.json lists v2"    '"openapi": "https://'"$DOMAIN"'/v2/openapi.json"' "$(it_body "$DOMAIN" /versions.json)"
it_check "domain page links versions" 'href="/versions.json"' "$(it_body "$DOMAIN" /)"
it_check "favicon served"            "200"              "$(it_status "$DOMAIN" /favicon.ico)"
it_check "favicon type"              "image/vnd.microsoft.icon" "$(it_header "$DOMAIN" /favicon.ico content-type)"
it_check "pages link the favicon"    'href="/favicon.ico"' "$(it_body "$DOMAIN" /v2/)"
it_check "pages show the logo"       'src="/img/logo.png"' "$(it_body "$DOMAIN" /v2/)"
it_check "logo served"               "200"              "$(it_status "$DOMAIN" /img/logo.png)"
it_check "logo type"                 "image/png"        "$(it_header "$DOMAIN" /img/logo.png content-type)"
it_check "logo cacheable"            "max-age=86400"    "$(it_header "$DOMAIN" /img/logo.png cache-control)"
it_check "own favicon: no touch icon" "404"             "$(it_status "$DOMAIN" /img/icon-180.png)"
it_check "images directory hidden"   "404"              "$(it_status "$DOMAIN" /img/)"
it_check "unknown image"             "404"              "$(it_status "$DOMAIN" /img/nope.png)"

echo "-- headers --"
it_check "cors open"                 "access-control-allow-origin: *" "$(it_header "$DOMAIN" /v2/kjv/1/1.json access-control-allow-origin)"
for resource in /v2/kjv/1/1.json /v2/kjv/1/1.sha /v2/openapi.json /versions.json / /v2/ /healthz; do
    EXPOSED="$(it_header "$DOMAIN" "$resource" access-control-expose-headers)"
    it_check "cache policy exposed: $resource" "Cache-Control" "$EXPOSED"
    it_check "cache validator exposed: $resource" "ETag" "$EXPOSED"
    it_check "cache date exposed: $resource" "Last-Modified" "$EXPOSED"
    it_check "CDN cache status exposed: $resource" "CF-Cache-Status" "$EXPOSED"
done
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
it_check "unauthorized response not cacheable" "no-store" "$(it_header "$DOMAIN" /v2/kjv/1/1.json cache-control)"
it_check "conditional request still needs token" "401" "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG")"
it_check "valid token -> 200"        "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer $TOKEN")"
it_check "protected JSON is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "protected SHA is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/1/1.sha -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "protected text is not shared-cacheable" "private, no-store" "$(it_headers "$DOMAIN" /v2/kjv/readme.txt -H "Authorization: Bearer $TOKEN" | grep -i '^cache-control')"
it_check "wrong token -> 401"        "401"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "Authorization: Bearer gbwrong")"
it_check "docs still public"         "200"              "$(it_status "$DOMAIN" /)"
it_check "endpoint page still public" "200"             "$(it_status "$DOMAIN" /v2/)"
it_check "openapi still public"      "200"              "$(it_status "$DOMAIN" /v2/openapi.json)"
it_check "discovery still public"    "200"              "$(it_status "$DOMAIN" /versions.json)"
it_check "discovery alias public"    "200"              "$(it_status "$DOMAIN" /version.json)"
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
ln -s "$NEXT_REL" "$IT_SB/srv/getbible/$DOMAIN/v2.next"
flip "$IT_SB/srv/getbible/$DOMAIN/v2.next" "$IT_SB/srv/getbible/$DOMAIN/v2"
it_check "changed release invalidates old etag" "200" "$(it_status "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG")"
it_check "changed release body is current" '"rotation":"complete"' "$(it_body "$DOMAIN" /v2/kjv/1/1.json -H "If-None-Match: $CHAPTER_ETAG")"
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

echo "-- a staged endpoint serves its placeholder certificate --"
# Deployed without going live: no certificate request, no DNS change, but the
# complete TLS vhost is up so the server can be verified before the switch.
STAGED="staged.example.test"
"$IT_ROOT/getbible.sh" deploy static --domain "$STAGED" --version v2 \
    --repo "file:///nonexistent/repo.git" --extensions json,sha,txt --access open --staged >/dev/null 2>&1
it_nginx_reload
it_check "staged recorded"           "LIVE=false"       "$(cat "$IT_SB/etc/getbible/endpoints/$STAGED/endpoint.conf")"
it_check "no letsencrypt directory"  ""                 "$(ls "$IT_SB/etc/letsencrypt/live/$STAGED" 2>/dev/null)"
it_check "staged docs page"          "200"              "$(it_status "$STAGED" /)"
it_check "staged health"             '{"status":"ok"}'  "$(it_body "$STAGED" /healthz)"
it_check "placeholder certificate"   "$STAGED"          "$(openssl s_client -connect "127.0.0.1:$IT_HTTPS_PORT" -servername "$STAGED" </dev/null 2>/dev/null | openssl x509 -noout -subject)"
it_check "live endpoint unaffected"  "200"              "$(it_status "$DOMAIN" /v2/kjv/1/1.json)"

echo "-- a domain whose only endpoint is its root --"
# No version folders: the tree is served at /, the page at / comes from the
# repository (an HTML file, although .html is not a served type), and the
# OpenAPI document at /openapi.json comes from the repository too.
ROOTDOM="root.example.test"
"$IT_ROOT/getbible.sh" deploy static --domain "$ROOTDOM" --version root \
    --repo "file:///nonexistent/repo.git" --extensions json,sha,txt --access open >/dev/null 2>&1
it_selfsigned "$ROOTDOM"
"$IT_ROOT/getbible.sh" pages "$ROOTDOM" docs root repository docs/index.html >/dev/null 2>&1
RREL="$IT_SB/srv/getbible/$ROOTDOM/releases/root/20260101T000000Z-abcdef1"
mkdir -p "$RREL/kjv/1" "$RREL/docs"
cp "$REL/kjv/1/1.json" "$REL/kjv/1/1.sha" "$RREL/kjv/1/"
printf '<!doctype html><title>root</title><h1>from the repository</h1>\n' > "$RREL/docs/index.html"
printf '<h1>not served</h1>\n' > "$RREL/kjv/page.html"
printf '{"openapi":"3.1.0","info":{"title":"root fixture","version":"root"},"paths":{}}\n' > "$RREL/openapi.json"
ln -sfn "releases/root/20260101T000000Z-abcdef1" "$IT_SB/srv/getbible/$ROOTDOM/root"
chgrp -R "$IT_NGINX_USER" "$IT_SB/srv/getbible/$ROOTDOM"
chmod -R g+rX "$IT_SB/srv/getbible/$ROOTDOM"
"$IT_ROOT/getbible.sh" pages "$ROOTDOM" publish >/dev/null 2>&1
it_nginx_reload
it_check "root tree at /"            "200"              "$(it_status "$ROOTDOM" /kjv/1/1.json)"
it_check "root tree json"            "application/json" "$(it_header "$ROOTDOM" /kjv/1/1.json content-type)"
it_check "root tree sha"             "200"              "$(it_status "$ROOTDOM" /kjv/1/1.sha)"
it_check "root html not allowlisted" "404"              "$(it_status "$ROOTDOM" /kjv/page.html)"
it_check "root page from repository" "from the repository" "$(it_body "$ROOTDOM" /)"
it_check "root page is html"         "text/html"        "$(it_header "$ROOTDOM" / content-type)"
it_check "root page path not served" "404"              "$(it_status "$ROOTDOM" /docs/index.html)"
it_check "root openapi"              '"title":"rootfixture"' "$(it_body "$ROOTDOM" /openapi.json | tr -d ' \n')"
it_check "root favicon"              "200"              "$(it_status "$ROOTDOM" /favicon.ico)"
it_check "root discovery public"     "200"              "$(it_status "$ROOTDOM" /versions.json)"
it_check "root discovery uses root URL" '"url": "https://'"$ROOTDOM"'/"' "$(it_body "$ROOTDOM" /versions.json)"
it_check "root discovery has one entry" "1" "$(it_body "$ROOTDOM" /versions.json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["endpoints"]))')"
it_check "singular discovery alias" "$(it_body "$ROOTDOM" /versions.json)" "$(it_body "$ROOTDOM" /version.json)"
it_check "root unknown folder"       "404"              "$(it_status "$ROOTDOM" /v2/kjv/1/1.json)"
it_check "root dotfile hidden"       "404"              "$(it_status "$ROOTDOM" /.hidden)"
it_check "root health"               '{"status":"ok"}'  "$(it_body "$ROOTDOM" /healthz)"
it_check "root query string rejected" "400"             "$(it_status "$ROOTDOM" '/kjv/1/1.json?x=1')"

echo "-- disabled specification stays disabled --"
"$IT_ROOT/getbible.sh" pages "$ROOTDOM" openapi root none >/dev/null 2>&1
"$IT_ROOT/getbible.sh" pages "$DOMAIN" openapi v2 none >/dev/null 2>&1
it_nginx_reload
it_check "root spec none reserves 404" "404" "$(it_status "$ROOTDOM" /openapi.json)"
it_check "version spec none reserves 404" "404" "$(it_status "$DOMAIN" /v2/openapi.json)"
it_check "root discovery is empty after none" '"endpoints": []' "$(it_body "$ROOTDOM" /versions.json)"
it_summary
