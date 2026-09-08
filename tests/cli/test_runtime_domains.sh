#!/usr/bin/env bash
# A runtime domain's endpoints are recorded, rendered and documented without
# any service being built: version folders with their own services, a second
# version from its own implementation directory, the default endpoint, a
# domain serving one version at its root, and the migration of a domain
# recorded before endpoints had records. Real nginx validates the result.
# shellcheck disable=SC2016 # nginx directives quoted literally
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false GB_NGINX_FAKE_BROTLI=false
unset GB_NGINX_FAKE_VERSION
PASS=0; FAIL=0
check() {
    local label="$1" expected="$2" actual="$3"
    if { [[ -z "$expected" && -z "$actual" ]]; } || { [[ -n "$expected" && "$actual" == *"$expected"* ]]; }; then
        printf '  ok    %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s expected %-24s got: %s\n' "$label" "$expected" "${actual:0:160}"; FAIL=$((FAIL + 1))
    fi
}

# A copy of the checkout with a second implementation of the query kind, so
# the version lookup is exercised without touching the repository.
COPY="$SB/repo"
mkdir -p "$COPY"
tar --exclude=.git --exclude=.venv-test --exclude=__pycache__ --exclude=build --exclude='*.egg-info' -C "$ROOT" -cf - . | tar -C "$COPY" -xf -
cp -a "$COPY/src/apps/query" "$COPY/src/apps/query-v3"
sed -i 's/^DEFAULT_VERSION=v2$/DEFAULT_VERSION=v3/; s/^SUPPORTED_VERSIONS=v2$/SUPPORTED_VERSIONS=v3/' "$COPY/src/apps/query-v3/manifest.conf"
export GB_REPO_DIR="$COPY"
# This shell sources the libraries (and so owns a GB_TMP that its exit
# removes); the tool runs as a child with a temporary directory of its own.
GB="$COPY/getbible.sh"
gb() { env -u GB_TMP "$GB" "$@"; }
for lib in core platform ui config registry users telegram nginx certs systemd logs access sync python docs pages endpoint; do
    # shellcheck source=/dev/null
    source "$COPY/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$COPY/src/types/runtime/type.sh"
gb_global_init
REPO="$ROOT/tests/python/fixtures/repository"
Q=query.example.test; S=search.example.test

render() {
    # render DOMAIN: the vhost of DOMAIN rendered into the sandbox's nginx tree.
    local out="$SB/render-$1"
    rm -rf -- "$out"
    gb render "$1" --out "$out" >"$out.log" 2>&1 || { echo "render $1 failed:" >&2; cat "$out.log" >&2; return 1; }
    cat "$out/sites-available/$1.conf"
}

echo "-- implementations --"
check "kinds discovered once"        "query search"            "$(rt_kinds | tr '\n' ' ' | sed 's/ $//')"
check "versions from every dir"      "v2 v3"                   "$(rt_kind_versions query | tr '\n' ' ' | sed 's/ $//')"
check "v3 has its own directory"     "query-v3"                "$(rt_implementation query v3)"
check "v2 from the base directory"   "query"                   "$(rt_implementation query v2)"
check "search knows v2 only"         "v2"                      "$(rt_kind_versions search | tr '\n' ' ' | sed 's/ $//')"
check "unknown version refused"      ""                        "$(rt_implementation query v9 || true)"

echo "-- a domain with version folders --"
type_runtime_create "$Q" query v2 "$REPO" metered ''
mkdir -p "$SB/etc/letsencrypt/live/$Q" && touch "$SB/etc/letsencrypt/live/$Q/fullchain.pem" "$SB/etc/letsencrypt/live/$Q/privkey.pem"
check "endpoint recorded"            "LAYOUT=versioned"        "$(cat "$SB/etc/getbible/endpoints/$Q/versions/v2.conf")"
check "app version recorded"         "APP_VERSION=v2"          "$(cat "$SB/etc/getbible/endpoints/$Q/versions/v2.conf")"
check "settings live with endpoint"  "WORKERS=4"               "$(cat "$SB/etc/getbible/endpoints/$Q/versions/v2.conf")"
check "default endpoint"             "DEFAULT_ENDPOINT=v2"     "$(cat "$SB/etc/getbible/endpoints/$Q/endpoint.conf")"
check "root under the version"       "$SB/opt/getbible/query/v2" "$(rt_root "$Q" v2)"
check "unit prefix carries version"  "getbible-query-v2"       "$(rt_unit_prefix "$Q" v2)"
check "socket dir carries version"   "$SB/run/getbible/query/v2" "$(rt_socket_dir "$Q" v2)"
check "env file carries version"     "runtime-v2.env"          "$(rt_env_file "$Q" v2)"
check "app log carries version"      "app/v2.log"              "$(rt_app_log "$Q" v2)"
gb pages "$Q" publish >/dev/null 2>&1
check "endpoint page"                "<h1>$Q <code>/v2/</code></h1>" "$(cat "$SB/var/www/getbible/$Q/v2/index.html")"
check "endpoint page route"          "GET https://$Q/v2/{translation}/{reference}" "$(cat "$SB/var/www/getbible/$Q/v2/index.html")"
check "endpoint openapi paths"       '"/v2/{translation}/{reference}"' "$(cat "$SB/var/www/getbible/$Q/v2/openapi.json")"
check "endpoint openapi short form"  '"/{reference}"'          "$(cat "$SB/var/www/getbible/$Q/v2/openapi.json")"
check "domain page row"              '<a href="/v2/">/v2/</a>' "$(cat "$SB/var/www/getbible/$Q/index.html")"
check "versions.json lists v2"       '"version": "v2"'         "$(cat "$SB/var/www/getbible/$Q/versions.json")"
SITE="$(render "$Q")" || exit 1
check "version folder proxied"       "location ^~ /v2/ {"      "$SITE"
check "version root proxied"         "location = /v2 {"        "$SITE"
check "page location"                "location = /v2/ {"       "$SITE"
check "page hands args to service"   'if ($args != "") { rewrite ^ /v2 last; }' "$SITE"
check "openapi location"             "location = /v2/openapi.json {" "$SITE"
check "openapi alias"                "try_files /v2/openapi.json =404;" "$SITE"
check "own socket"                   "proxy_pass http://unix:$SB/run/getbible/query/v2/gunicorn.sock:;" "$SITE"
check "no root rewrite"              ""                        "$(grep -c 'rewrite ^/(.\*)\$' <<< "$SITE" | sed 's/^0$//')"

echo "-- a second version from its own implementation --"
check "v9 refused"                   "no implementation of v9" "$(rt_check_new_endpoint "$Q" v9 v9 2>&1 || true)"
check "root refused next to v2"      "cannot become an endpoint" "$(rt_check_new_endpoint "$Q" root v3 2>&1 || true)"
check "v3 accepted"                  ""                        "$(rt_check_new_endpoint "$Q" v3 v3 2>&1 || true)"
rt_record_endpoint "$Q" v3 v3 "$REPO" ""
check "v3 recorded"                  "APP_VERSION=v3"          "$(cat "$SB/etc/getbible/endpoints/$Q/versions/v3.conf")"
check "endpoints listed"             "v2 v3"                   "$(type_runtime_endpoints "$Q" | tr '\n' ' ' | sed 's/ $//')"
check "status lists both"            "Endpoint v3 of $Q (v3, versioned layout)" "$(gb status "$Q" 2>/dev/null)"
gb pages "$Q" publish >/dev/null 2>&1
check "v3 page"                      "<code>/v3/</code>"       "$(cat "$SB/var/www/getbible/$Q/v3/index.html")"
check "v3 openapi paths"             '"/v3/{translation}/{reference}"' "$(cat "$SB/var/www/getbible/$Q/v3/openapi.json")"
check "versions.json lists v3"       '"openapi": "https://'"$Q"'/v3/openapi.json"' "$(cat "$SB/var/www/getbible/$Q/versions.json")"
check "domain page lists v3"         '<a href="/v3/">/v3/</a>' "$(cat "$SB/var/www/getbible/$Q/index.html")"
SITE="$(render "$Q")" || exit 1
check "v3 proxied"                   "location ^~ /v3/ {"      "$SITE"
check "v3 own socket"                "$SB/run/getbible/query/v3/gunicorn.sock" "$SITE"
check "short forms to default v2"    "location / {"            "$SITE"
check "default is v2"                "v2"                      "$(type_runtime_default_endpoint "$Q")"
ep_set "$Q" DEFAULT_ENDPOINT v3
SITE="$(render "$Q")" || exit 1
check "default switched to v3"       "$(sed -n '/^    location \/ {/,/^    }/p' <<< "$SITE" | grep -c 'query/v3/gunicorn.sock')" "1"
ep_set "$Q" DEFAULT_ENDPOINT v2

echo "-- a domain serving one version at its root --"
type_runtime_create "$S" search v2 "$REPO" metered kjv root
mkdir -p "$SB/etc/letsencrypt/live/$S" && touch "$SB/etc/letsencrypt/live/$S/fullchain.pem" "$SB/etc/letsencrypt/live/$S/privkey.pem"
check "root endpoint recorded"       "LABEL=root"              "$(cat "$SB/etc/getbible/endpoints/$S/versions/root.conf")"
check "root speaks v2"               "APP_VERSION=v2"          "$(cat "$SB/etc/getbible/endpoints/$S/versions/root.conf")"
check "root paths carry the label"   "$SB/opt/getbible/search/root" "$(rt_root "$S" root)"
gb pages "$S" publish >/dev/null 2>&1
check "root page at /"               "<h1>$S</h1>"             "$(cat "$SB/var/www/getbible/$S/index.html")"
check "root page routes"             "GET  https://$S/{translation}/{search string}" "$(cat "$SB/var/www/getbible/$S/index.html")"
check "root page q form"             "GET  https://$S/?q={search string}" "$(cat "$SB/var/www/getbible/$S/index.html")"
check "root openapi paths"           '"/{translation}/{search}"' "$(cat "$SB/var/www/getbible/$S/openapi.json")"
check "root openapi version path"    '"/": {'                  "$(cat "$SB/var/www/getbible/$S/openapi.json")"
check "root openapi valid"           "ok"                      "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$SB/var/www/getbible/$S/openapi.json")"
check "no versions.json for root"    ""                        "$(ls "$SB/var/www/getbible/$S/versions.json" 2>/dev/null)"
check "no folders next to root"      "remove that endpoint"    "$(rt_check_new_endpoint "$S" v2 v2 2>&1 || true)"
check "cannot remove the last"       "only endpoint"           "$(rt_remove_endpoint "$S" root 2>&1 || true)"
SITE="$(render "$S")" || exit 1
check "root rewrite to the service"  'rewrite ^/(.*)$ /v2/$1 break;' "$SITE"
check "root redirects stripped"      'proxy_redirect ~^(https?://[^/]+)?/v2(/.*)$ $1$2;' "$SITE"
check "root page hands args over"    'rewrite ^ /.gb/v2 last;' "$SITE"
check "internal hand-over prefix"    "location ^~ /.gb/ {"     "$SITE"
check "root openapi at /"            "location = /openapi.json {" "$SITE"
check "no version folder location"   ""                        "$(grep -c 'location ^~ /v2/' <<< "$SITE" | sed 's/^0$//')"
check "no domain-level page block"   ""                        "$(grep -c "The domain page, or the root endpoint's page" <<< "$SITE" | sed 's/^0$//')"

echo "-- a domain recorded before endpoints had records --"
L=legacy.example.test
gb remove "$Q" --purge >/dev/null 2>&1
ep_create "$L" runtime query
ep_set "$L" ACCESS_MODE open
ep_set "$L" VERSION v2
ep_set "$L" REPOSITORY "$REPO"
ep_set "$L" WORKERS 3
ep_set "$L" THREADS 2
ep_set "$L" DEFAULT_TRANSLATION test
ep_set "$L" DEFAULT_REFERENCE Ge1:1
ep_set "$L" PYTHON_VERSION 3.12.14
ep_set "$L" CACHE_TTL 120
check "endpoint derived from VERSION" "v2"                     "$(type_runtime_endpoints "$L")"
check "legacy layout"                "LAYOUT=legacy"           "$(cat "$SB/etc/getbible/endpoints/$L/versions/v2.conf")"
check "settings migrated"            "WORKERS=3"               "$(cat "$SB/etc/getbible/endpoints/$L/versions/v2.conf")"
check "default recorded"             "DEFAULT_ENDPOINT=v2"     "$(cat "$SB/etc/getbible/endpoints/$L/endpoint.conf")"
check "legacy root kept"             "$SB/opt/getbible/query"  "$(rt_root "$L" v2)"
check "legacy units kept"            "getbible-query"          "$(rt_unit_prefix "$L" v2)"
check "legacy env file kept"         "$SB/etc/getbible/endpoints/$L/runtime.env" "$(rt_env_file "$L" v2)"
check "legacy app log kept"          "app/app.log"             "$(rt_app_log "$L" v2)"
check "legacy socket dir kept"       "$SB/run/getbible/query"  "$(rt_socket_dir "$L" v2)"
check "migration is idempotent"      "1"                       "$(type_runtime_endpoints "$L" >/dev/null; grep -c '^LAYOUT=' "$SB/etc/getbible/endpoints/$L/versions/v2.conf")"

echo "-- nginx -t on the rendered configuration --"
if command -v nginx >/dev/null; then
    mkdir -p "$SB/etc/letsencrypt/live/$L"
    for domain in "$L" "$S"; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$SB/etc/letsencrypt/live/$domain/privkey.pem" -out "$SB/etc/letsencrypt/live/$domain/fullchain.pem" -subj "/CN=$domain" 2>/dev/null
        gb pages "$domain" publish >/dev/null 2>&1
        render "$domain" >/dev/null
        mkdir -p "$SB/etc/nginx" && cp -a "$SB/render-$domain/." "$SB/etc/nginx/"
    done
    mkdir -p "$SB/etc/nginx/logs" "$SB/etc/nginx/sites-enabled" "$SB/var/cache/nginx/getbible" "$SB/var/log/getbible/$L" "$SB/var/log/getbible/$S"
    ln -sfn "../sites-available/$L.conf" "$SB/etc/nginx/sites-enabled/$L.conf"
    ln -sfn "../sites-available/$S.conf" "$SB/etc/nginx/sites-enabled/$S.conf"
    sed -i -e 's/listen 80;/listen 127.0.0.1:18182;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18545 ssl\1;/' "$SB/etc/nginx/sites-available/$L.conf"
    sed -i -e 's/listen 80;/listen 127.0.0.1:18183;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18546 ssl\1;/' "$SB/etc/nginx/sites-available/$S.conf"
    cat > "$SB/etc/nginx/nginx-test.conf" <<EOF
pid $SB/nginx.pid;
error_log stderr warn;
events { worker_connections 16; }
http { access_log off; include /etc/nginx/mime.types; include $SB/etc/nginx/conf.d/*.conf; include $SB/etc/nginx/sites-enabled/*.conf; }
EOF
    check "nginx -t"                 "successful"              "$(nginx -t -c "$SB/etc/nginx/nginx-test.conf" -p "$SB/etc/nginx" 2>&1)"
else
    echo "  (nginx not installed; skipped)"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
