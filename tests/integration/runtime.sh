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
# query goes live with a preseeded certificate and serves /v2/; search stays
# staged, serves through its placeholder certificate until go-live, and serves
# its single version at the domain root.
for kind in query search; do
    domain="$kind.example.test"
    flags=()
    [[ "$kind" != search ]] || flags=(--staged --root)
    "$IT_ROOT/getbible.sh" deploy runtime --domain "$domain" --kind "$kind" --repository "$FIXTURE" \
        --default-translation test --default-reference Ge1:1 --warm test \
        --access metered "${flags[@]+"${flags[@]}"}" >/dev/null 2>&1 || { echo "deploy $kind failed"; exit 1; }
    if [[ "$kind" != search ]]; then
        it_selfsigned "$domain"
        "$IT_ROOT/getbible.sh" apply "$domain" >/dev/null 2>&1
    fi
done

start_gunicorn() {
    local kind="$1" label="$2" release deployment env_file socket socket_dir
    release="$(readlink -f "$IT_SB/opt/getbible/$kind/$label/current")"
    deployment="$(readlink -f "$IT_SB/opt/getbible/$kind/$label/active")"
    env_file="$deployment/runtime.env"
    socket="$( # shellcheck source=/dev/null
        source "$env_file"; bind_name="${kind^^}_BIND"; printf '%s' "${!bind_name}"
    )"
    socket="${socket#unix:}"
    socket_dir="$(dirname "$socket")"
    mkdir -p "$socket_dir" "$IT_SB/var/log/getbible/$kind.example.test/app" "$IT_SB/var/cache/getbible/$kind/$label/librarian"
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
start_gunicorn query v2
start_gunicorn search root
it_nginx_start || exit 1

Q="query.example.test"; S="search.example.test"
echo "-- query endpoint through nginx --"
it_check "scripture 200"             "200"                       "$(it_status "$Q" /v2/test/Ge1:1)"
it_check "scripture json"            "application/json"          "$(it_header "$Q" /v2/test/Ge1:1 content-type)"
it_check "scripture body"            '"test_1_1"'                "$(it_body "$Q" /v2/test/Ge1:1)"
it_check "cache-control from app"    "max-age=2592000"           "$(it_header "$Q" /v2/test/Ge1:1 cache-control)"
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
it_check "domain page lists endpoint" '<a href="/v2/">/v2/</a>'  "$(it_body "$Q" /)"
it_check "domain page shows the logo" 'src="/img/logo.png"'       "$(it_body "$Q" /)"
it_check "repository favicon served" "image/png"                  "$(it_header "$Q" /favicon.ico content-type)"
it_check "touch icon served"         "200"                        "$(it_status "$Q" /img/icon-180.png)"
it_check "endpoint page"             "text/html"                 "$(it_header "$Q" /v2/ content-type)"
it_check "endpoint page names version" "<code>/v2/</code>"       "$(it_body "$Q" /v2/)"
it_check "endpoint openapi"          '"openapi":"3.1.0"'         "$(it_body "$Q" /v2/openapi.json | tr -d ' \n')"
it_check "openapi served"            '"openapi":"3.1.0"'         "$(it_body "$Q" /openapi.json | tr -d ' \n')"
it_check "versions.json"             '"openapi": "https://'"$Q"'/v2/openapi.json"' "$(it_body "$Q" /versions.json)"
it_check "folder with args is the service" '"code":"parameters_not_accepted"' "$(it_body "$Q" '/v2/?x=1')"
it_check "healthz proxied"           '{"status":"ok"}'           "$(it_body "$Q" /healthz)"
it_check "readyz proxied"            '{"status":"ready"}'        "$(it_body "$Q" /readyz)"
it_check "folder private probe denied" "404"                     "$(it_status "$Q" /probez)"
it_check "folder probe slash denied"   "404"                     "$(it_status "$Q" /probez/)"
it_check "unknown route problem"     '"code":"not_found"'        "$(it_body "$Q" /a/b/c/d)"
it_check "app log has reference"     '"reference":"Ge1:1"'       "$(it_wait_log "$IT_SB/var/log/getbible/$Q/app/v2.log" '"reference":"Ge1:1"')"
it_check "nginx log has uri"         '"uri":"/v2/test/Ge1:1?x=1"' "$(it_wait_log "$IT_SB/var/log/getbible/$Q/access.log" '/v2/test/Ge1:1?x=1')"

echo "-- search endpoint at the domain root through nginx --"
it_check "root endpoint recorded"    "LABEL=root"                "$(cat "$IT_SB/etc/getbible/endpoints/$S/versions/root.conf")"
it_check "search 200"                "200"                       "$(it_status "$S" /test/beginning)"
it_check "search envelope"           '"kind":"search"'           "$(it_body "$S" /test/beginning)"
it_check "search with filters"       '"words":"any"'             "$(it_body "$S" '/test/beginning?words=any&limit=5')"
it_check "search total"              '"total":1'                 "$(it_body "$S" /test/beginning)"
it_check "reference typed as search" '"kind":"reference"'        "$(it_body "$S" /test/Ge1:1)"
it_check "q parameter form"          '"kind":"search"'           "$(it_body "$S" '/test?q=beginning')"
it_check "translation parameter"     '"abbreviation":"test"'     "$(it_body "$S" '/?q=beginning&translation=test')"
it_check "no search string"          '"code":"missing_search"'   "$(it_body "$S" /test)"
it_check "unknown parameter"         '"code":"unknown_parameter"' "$(it_body "$S" '/test/beginning?nope=1')"
it_check "post json body"            '"kind":"search"'           "$(it_body "$S" /test -X POST -H 'Content-Type: application/json' -d '{"q":"beginning","limit":2}')"
it_check "post to the root"          '"kind":"search"'           "$(it_body "$S" / -X POST -H 'Content-Type: application/json' -d '{"q":"beginning","translation":"test"}')"
it_check "post filters on path"      '"words":"any"'             "$(it_body "$S" /test/beginning -X POST -H 'Content-Type: application/json' -d '{"words":"any"}')"
it_check "post form rejected"        "415"                       "$(it_status "$S" /test -X POST -H 'Content-Type: application/x-www-form-urlencoded' -d 'q=beginning')"
it_check "post not cached"           "cache-control: no-store"   "$(it_headers "$S" /test -X POST -H 'Content-Type: application/json' -d '{"q":"beginning"}' | grep -i '^cache-control')"
it_check "get cached header"         "max-age=2592000"           "$(it_header "$S" /test/beginning cache-control)"
# nginx rewrites the service's Location (/v2/test/beginning) for the root and
# makes it absolute on the way.
it_check "search string redirect"    "$S/test/beginning"         "$(it_header "$S" /beginning location)"
it_check "redirect keeps filters"    "$S/test/beginning?limit=3" "$(it_header "$S" '/beginning?limit=3' location)"
it_check "redirect has no version"   ""                          "$(it_header "$S" /beginning location | grep -c '/v2/' | sed 's/^0$//')"
it_check "put rejected by nginx"     "405"                       "$(it_status "$S" /test/x -X PUT)"
it_check "root page"                 "text/html"                 "$(it_header "$S" / content-type)"
it_check "root page routes"          "https://$S/{translation}/{search string}" "$(it_body "$S" /)"
it_check "root openapi"              '"openapi":"3.1.0"'         "$(it_body "$S" /openapi.json | tr -d ' \n')"
it_check "root openapi paths"        '"/{translation}/{search}"' "$(it_body "$S" /openapi.json | tr -d ' \n')"
it_check "no version folder at root" "404"                       "$(it_status "$S" /v2/test/beginning)"
it_check "root version discovery"    'https://'"$S"'/openapi.json' "$(it_body "$S" /versions.json)"
it_check "internal prefix hidden"    "404"                       "$(it_status "$S" /.gb/v2)"
it_check "app log has search text"   '"search":"beginning"'      "$(it_wait_log "$IT_SB/var/log/getbible/$S/app/root.log" '"search":"beginning"')"
it_check "nginx log keeps query"     'q=beginning'               "$(it_wait_log "$IT_SB/var/log/getbible/$S/access.log" 'q=beginning')"

echo "-- token-only access at the domain root --"
# The service moves to a new generation (its socket changes with the access
# mode); the sandbox has no systemd, so the test starts that generation itself.
TOKEN_S="$("$IT_ROOT/getbible.sh" token "$S" add "root test" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
"$IT_ROOT/getbible.sh" access "$S" token >/dev/null 2>&1
start_gunicorn search root
it_nginx_reload
it_check "root data needs a token"   "401"                       "$(it_status "$S" /test/beginning)"
it_check "root query needs a token"  "401"                       "$(it_status "$S" '/?q=beginning&translation=test')"
it_check "root body needs a token"   "401"                       "$(it_status "$S" / -X POST -H 'Content-Type: application/json' -d '{"q":"beginning","translation":"test"}')"
it_check "root token accepted"       "200"                       "$(it_status "$S" /test/beginning -H "Authorization: Bearer $TOKEN_S")"
it_check "root token query accepted" '"kind":"search"'           "$(it_body "$S" '/?q=beginning&translation=test' -H "Authorization: Bearer $TOKEN_S")"
it_check "root page still public"    "200"                       "$(it_status "$S" /)"
it_check "root openapi still public" "200"                       "$(it_status "$S" /openapi.json)"
it_check "root health still public"  "200"                       "$(it_status "$S" /healthz)"
it_check "root ready still public"   "200"                       "$(it_status "$S" /readyz)"
it_check "root probe denied"         "404"                       "$(it_status "$S" /probez)"
it_check "root probe slash denied"   "404"                       "$(it_status "$S" /probez/)"
it_check "root token probe denied"   "404"                       "$(it_status "$S" /probez -H "Authorization: Bearer $TOKEN_S")"
"$IT_ROOT/getbible.sh" access "$S" metered >/dev/null 2>&1
start_gunicorn search root
it_nginx_reload
it_check "root metered again"        "200"                       "$(it_status "$S" /test/beginning)"

echo "-- the staged search endpoint served through its placeholder --"
it_check "search recorded staged"    "LIVE=false"      "$(cat "$IT_SB/etc/getbible/endpoints/$S/endpoint.conf")"
it_check "search has no letsencrypt" ""                "$(ls "$IT_SB/etc/letsencrypt/live/$S" 2>/dev/null)"
it_check "search placeholder cert"   "$S"              "$(openssl s_client -connect "127.0.0.1:$IT_HTTPS_PORT" -servername "$S" </dev/null 2>/dev/null | openssl x509 -noout -subject)"
it_check "search readyz via nginx"   '{"status":"ready"}' "$(it_body "$S" /readyz)"

echo "-- release rebuild is skipped when inputs are unchanged --"
BEFORE="$(readlink -f "$IT_SB/opt/getbible/query/v2/current")"
"$IT_ROOT/getbible.sh" apply "$Q" >/dev/null 2>&1
it_check "same release kept"         "$BEFORE"                   "$(readlink -f "$IT_SB/opt/getbible/query/v2/current")"
it_check "endpoint recorded"         "APP_VERSION=v2"            "$(cat "$IT_SB/etc/getbible/endpoints/$Q/versions/v2.conf")"
it_check "status per endpoint"       "Endpoint v2 of $Q (v2)"     "$("$IT_ROOT/getbible.sh" status "$Q" 2>/dev/null)"

echo "-- documentation remains public on token-only version folders --"
"$IT_ROOT/getbible.sh" access "$Q" token >/dev/null 2>&1
start_gunicorn query v2
it_nginx_reload
it_check "folder data needs a token" "401"                       "$(it_status "$Q" /v2/test/Ge1:1)"
for public_path in / /v2/ /openapi.json /v2/openapi.json /versions.json /healthz /readyz; do
    it_check "folder public $public_path" "200"                 "$(it_status "$Q" "$public_path")"
done
it_check "folder probe stays private" "404"                     "$(it_status "$Q" /probez)"

# The deployment probe is still usable on its private service socket.
search_env="$(readlink -f "$IT_SB/opt/getbible/search/root/active")/runtime.env"
search_socket="$(
    # shellcheck source=/dev/null
    source "$search_env"
    printf '%s' "${SEARCH_BIND#unix:}"
)"
it_check "private socket probe works" '{"status":"ready"}'      "$(curl --silent --fail --max-time 10 --unix-socket "$search_socket" http://localhost/probez)"

it_summary
