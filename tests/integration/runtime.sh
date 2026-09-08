#!/usr/bin/env bash
# Deploy the query and search endpoints into a sandbox, run their releases
# with real gunicorn on the rendered sockets, put real nginx in front, and
# hold both to their documented behaviour.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
FIXTURE="$IT_SB/fixtures/repository"
PIDS=()
cleanup() {
    local result="$?"
    (( result == 0 )) || it_failure_logs
    it_nginx_stop
    for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -QUIT "$pid" 2>/dev/null || true; done
    sleep 0.5
}
trap cleanup EXIT

it_log "sandbox $IT_SB"
install -d -m 0755 "$IT_SB/fixtures"
cp -a "$IT_ROOT/tests/python/fixtures/repository" "$FIXTURE"
chmod -R a+rX "$FIXTURE"
# query goes live with a preseeded certificate; search stays staged and
# serves through its placeholder certificate until go-live.
for kind in query search; do
    domain="$kind.example.test"
    flags=()
    [[ "$kind" != search ]] || flags=(--staged)
    "$IT_ROOT/getbible.sh" deploy runtime --domain "$domain" --kind "$kind" --repository "$FIXTURE" \
        --require-checksums false --default-translation test --default-reference Ge1:1 --warm test \
        --access metered "${flags[@]+"${flags[@]}"}" >/dev/null 2>&1 || { echo "deploy $kind failed"; exit 1; }
    if [[ "$kind" != search ]]; then
        it_selfsigned "$domain"
        "$IT_ROOT/getbible.sh" apply "$domain" >/dev/null 2>&1
    fi
done

start_gunicorn() {
    local kind="$1" release deployment env_file socket socket_dir
    release="$(readlink -f "$IT_SB/opt/getbible/$kind/current")"
    deployment="$(readlink -f "$IT_SB/opt/getbible/$kind/active")"
    env_file="$deployment/runtime.env"
    socket="$( # shellcheck source=/dev/null
        source "$env_file"; bind_name="${kind^^}_BIND"; printf '%s' "${!bind_name}"
    )"
    socket="${socket#unix:}"
    socket_dir="$(dirname "$socket")"
    mkdir -p "$socket_dir" "$IT_SB/var/log/getbible/$kind.example.test/app" "$IT_SB/var/cache/getbible/$kind/librarian"
    # The sandbox cannot create the production accounts. Run unprivileged
    # here; systemd.sh separately verifies the actual account/ACL/unit setup.
    chown -R "$IT_NGINX_USER:" "$socket_dir" "$IT_SB/var/log/getbible/$kind.example.test/app" "$IT_SB/var/cache/getbible/$kind"
    ( cd "$release"; set -a; # shellcheck source=/dev/null
      source "$env_file"; set +a
      exec runuser -u "$IT_NGINX_USER" -- "$release/.venv/bin/gunicorn" --config "$deployment/gunicorn.conf.py" --workers 1 \
          "$(grep '^WSGI=' "$IT_ROOT/src/apps/$kind/manifest.conf" | cut -d= -f2)" ) >"$IT_SB/gunicorn-$kind.log" 2>&1 &
    PIDS+=("$!")
    local waited=0
    until curl --silent --fail --max-time 2 --unix-socket "$socket" http://localhost/readyz >/dev/null 2>&1; do
        sleep 0.5; waited=$((waited + 1))
        (( waited < 60 )) || { echo "gunicorn $kind did not become ready"; tail -20 "$IT_SB/gunicorn-$kind.log"; exit 1; }
    done
}
start_gunicorn query
start_gunicorn search
it_nginx_start || exit 1

Q="query.example.test"; S="search.example.test"
echo "-- query endpoint through nginx --"
it_check "scripture 200"             "200"                       "$(it_status "$Q" /v2/test/Ge1:1)"
it_check "scripture json"            "application/json"          "$(it_header "$Q" /v2/test/Ge1:1 content-type)"
it_check "scripture body"            '"test_1_1"'                "$(it_body "$Q" /v2/test/Ge1:1)"
it_check "cache-control from app"    "max-age=300"               "$(it_header "$Q" /v2/test/Ge1:1 cache-control)"
it_check "cors from nginx"           "access-control-allow-origin: *" "$(it_header "$Q" /v2/test/Ge1:1 access-control-allow-origin)"
it_check "request id"                "x-request-id:"             "$(it_header "$Q" /v2/test/Ge1:1 x-request-id)"
it_check "cache status header"       "x-cache-status:"           "$(it_header "$Q" /v2/test/Ge1:1 x-cache-status)"
it_check "bad reference problem"     "application/problem+json"  "$(it_header "$Q" /v2/test/nonsense content-type)"
it_check "bad reference code"        '"code":"invalid_reference"' "$(it_body "$Q" /v2/test/nonsense)"
it_check "unknown translation 404"   "404"                       "$(it_status "$Q" /v2/nope/Ge1:1)"
it_check "query string rejected"     '"code":"parameters_not_accepted"' "$(it_body "$Q" '/v2/test/Ge1:1?x=1')"
it_check "short form redirects"      "301"                       "$(it_status "$Q" /Ge1:1)"
it_check "redirect location"         "location: /v2/test/Ge1:1"  "$(it_header "$Q" /Ge1:1 location)"
it_check "version root redirects"    "location: /v2/test/Ge1:1"  "$(it_header "$Q" /v2 location)"
it_check "post rejected by nginx"    "405"                       "$(it_status "$Q" /v2/test/Ge1:1 -X POST)"
it_check "docs page at root"         "text/html"                 "$(it_header "$Q" / content-type)"
it_check "docs mention route"        "/v2/{translation}/{reference}" "$(it_body "$Q" /)"
it_check "openapi served"            '"openapi":"3.1.0"'         "$(it_body "$Q" /openapi.json | tr -d ' \n')"
it_check "healthz proxied"           '{"status":"ok"}'           "$(it_body "$Q" /healthz)"
it_check "readyz proxied"            '{"status":"ready"}'        "$(it_body "$Q" /readyz)"
it_check "unknown route problem"     '"code":"not_found"'        "$(it_body "$Q" /a/b/c/d)"
it_check "app log has reference"     '"reference":"Ge1:1"'       "$(it_wait_log "$IT_SB/var/log/getbible/$Q/app/app.log" '"reference":"Ge1:1"')"
it_check "nginx log has uri"         '"uri":"/v2/test/Ge1:1?x=1"' "$(it_wait_log "$IT_SB/var/log/getbible/$Q/access.log" 'x=1')"

echo "-- search endpoint through nginx --"
it_check "search 200"                "200"                       "$(it_status "$S" /v2/test/beginning)"
it_check "search envelope"           '"kind":"search"'           "$(it_body "$S" /v2/test/beginning)"
it_check "search with filters"       '"words":"any"'             "$(it_body "$S" '/v2/test/beginning?words=any&limit=5')"
it_check "search total"              '"total":1'                 "$(it_body "$S" /v2/test/beginning)"
it_check "reference typed as search" '"kind":"reference"'        "$(it_body "$S" /v2/test/Ge1:1)"
it_check "q parameter form"          '"kind":"search"'           "$(it_body "$S" '/v2/test?q=beginning')"
it_check "translation parameter"     '"abbreviation":"test"'     "$(it_body "$S" '/v2?q=beginning&translation=test')"
it_check "no search string"          '"code":"missing_search"'   "$(it_body "$S" /v2/test)"
it_check "unknown parameter"         '"code":"unknown_parameter"' "$(it_body "$S" '/v2/test/beginning?nope=1')"
it_check "post json body"            '"kind":"search"'           "$(it_body "$S" /v2/test -X POST -H 'Content-Type: application/json' -d '{"q":"beginning","limit":2}')"
it_check "post filters on path"      '"words":"any"'             "$(it_body "$S" /v2/test/beginning -X POST -H 'Content-Type: application/json' -d '{"words":"any"}')"
it_check "post form rejected"        "415"                       "$(it_status "$S" /v2/test -X POST -H 'Content-Type: application/x-www-form-urlencoded' -d 'q=beginning')"
it_check "post not cached"           "cache-control: no-store"   "$(it_headers "$S" /v2/test -X POST -H 'Content-Type: application/json' -d '{"q":"beginning"}' | grep -i '^cache-control')"
it_check "get cached header"         "max-age=60"                "$(it_header "$S" /v2/test/beginning cache-control)"
it_check "search string redirect"    "location: /v2/test/beginning" "$(it_header "$S" /v2/beginning location)"
it_check "redirect keeps filters"    "location: /v2/test/beginning?limit=3" "$(it_header "$S" '/v2/beginning?limit=3' location)"
it_check "put rejected by nginx"     "405"                       "$(it_status "$S" /v2/test/x -X PUT)"
it_check "docs page"                 "text/html"                 "$(it_header "$S" / content-type)"
it_check "openapi served"            '"openapi":"3.1.0"'         "$(it_body "$S" /openapi.json | tr -d ' \n')"
it_check "app log has search text"   '"search":"beginning"'      "$(it_wait_log "$IT_SB/var/log/getbible/$S/app/app.log" '"search":"beginning"')"
it_check "nginx log keeps query"     'q=beginning'               "$(it_wait_log "$IT_SB/var/log/getbible/$S/access.log" 'q=beginning')"

echo "-- the staged search endpoint served through its placeholder --"
it_check "search recorded staged"    "LIVE=false"      "$(cat "$IT_SB/etc/getbible/endpoints/$S/endpoint.conf")"
it_check "search has no letsencrypt" ""                "$(ls "$IT_SB/etc/letsencrypt/live/$S" 2>/dev/null)"
it_check "search placeholder cert"   "$S"              "$(openssl s_client -connect "127.0.0.1:$IT_HTTPS_PORT" -servername "$S" </dev/null 2>/dev/null | openssl x509 -noout -subject)"
it_check "search readyz via nginx"   '{"status":"ready"}' "$(it_body "$S" /readyz)"

echo "-- release rebuild is skipped when inputs are unchanged --"
BEFORE="$(readlink -f "$IT_SB/opt/getbible/query/current")"
"$IT_ROOT/getbible.sh" apply "$Q" >/dev/null 2>&1
it_check "same release kept"         "$BEFORE"                   "$(readlink -f "$IT_SB/opt/getbible/query/current")"

it_summary
