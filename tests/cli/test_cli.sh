#!/usr/bin/env bash
# Drive the command line inside a throw-away prefix: nothing here touches the
# host. System commands that need root are skipped by the prefix logic.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=true GB_NGINX_FAKE_VERSION=1.26.0 GB_NGINX_FAKE_BROTLI=false
GB="$ROOT/getbible.sh"
PASS=0; FAIL=0
check() {
    local label="$1" expected="$2" actual="$3"
    if { [[ -z "$expected" && -z "$actual" ]]; } || { [[ -n "$expected" && "$actual" == *"$expected"* ]]; }; then
        printf '  ok    %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s expected %-24s got: %s\n' "$label" "$expected" "${actual:0:160}"; FAIL=$((FAIL + 1))
    fi
}
D=static.example.test
"$GB" deploy static --domain "$D" --version v2 --repo git@github.com:getbible/v2_scripture.git --extensions json,sha,txt >/dev/null 2>&1 || { echo "deploy failed"; exit 1; }

echo "-- registry --"
check "endpoint listed"          "$D"                      "$("$GB" list)"
check "type recorded"            "TYPE=static"             "$(cat "$SB/etc/getbible/endpoints/$D/endpoint.conf")"
check "default access metered"   "ACCESS_MODE=metered"     "$(cat "$SB/etc/getbible/endpoints/$D/endpoint.conf")"
check "version recorded"         "REPO_URL=git@github.com:getbible/v2_scripture.git" "$(cat "$SB/etc/getbible/endpoints/$D/versions/v2.conf")"
check "status runs"              "Access mode : metered"   "$("$GB" status "$D" 2>/dev/null)"

echo "-- rendered files --"
SITE="$SB/etc/nginx/sites-available/$D.conf"
check "site rendered"            "server_name $D;"         "$(cat "$SITE")"
check "http only before cert"    "none"                    "$(grep -c 'listen 443' "$SITE" | sed 's/^0$/none/')"
check "ipv6 listener"            "listen [::]:80;"         "$(cat "$SITE")"
check "site enabled"             "$D.conf"                 "$(ls "$SB/etc/nginx/sites-enabled/")"
check "http conf rendered"       "log_format getbible_json" "$(cat "$SB/etc/nginx/conf.d/getbible-http.conf")"
check "zones rendered"           "rate=50r/s"              "$(cat "$SB/etc/nginx/conf.d/getbible-ep-static_example_test.conf")"
check "limits metered"           "burst=250"               "$(cat "$SB/etc/nginx/getbible/$D/limits.conf")"
check "auth open"                "no token required"       "$(cat "$SB/etc/nginx/getbible/$D/auth.conf")"
check "sync unit rendered"       "GB_SYNC_REPO=git@github.com:getbible/v2_scripture.git" "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v2.service")"
check "sync timer weekly"        "OnCalendar=weekly"       "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v2.timer")"
check "logrotate rendered"       "size 1G"                 "$(cat "$SB/etc/getbible/logrotate.conf")"
check "docs page rendered"       "<h1>$D</h1>"             "$(cat "$SB/var/www/getbible/$D/index.html")"
check "docs list version"        "https://$D/v2/"          "$(cat "$SB/var/www/getbible/$D/index.html")"
check "endpoint page rendered"   "<h1>$D <code>/v2/</code></h1>" "$(cat "$SB/var/www/getbible/$D/v2/index.html")"
check "endpoint page base url"   "https://$D/v2/path/to/document.json" "$(cat "$SB/var/www/getbible/$D/v2/index.html")"
check "versions.json empty"      '"endpoints": []'         "$(cat "$SB/var/www/getbible/$D/versions.json")"
check "no favicon without one"   ""                        "$(grep -c 'favicon' "$SB/var/www/getbible/$D/index.html" | sed 's/^0$//')"
check "openapi from repository"  "GB_SYNC_EXTRA_FILES=openapi.json" "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v2.service")"
check "sync refreshes pages"     "ExecStartPost=-+$ROOT/getbible.sh pages $D publish --yes" "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v2.service")"
check "status names endpoints"   "Endpoints   : v2"        "$("$GB" status "$D" 2>/dev/null)"
check "status lists pages"       "OpenAPI /v2/openapi.json     repository" "$("$GB" status "$D" 2>/dev/null)"
check "tools installed"          "getbible-sync"           "$(ls "$SB/usr/local/lib/getbible/")"
check "aio threads on 1.26"      "aio                threads;" "$(cat "$SB/etc/nginx/getbible/$D/server.conf")"
# Implicit parents must stay traversable whichever coreutils created them.
check "parents traversable"      "755 755 755"             "$(stat -c %a "$SB/srv/getbible" "$SB/var/www/getbible" "$SB/var/log/getbible" | tr '\n' ' ' | sed 's/ $//')"

echo "-- TLS phase --"
mkdir -p "$SB/etc/letsencrypt/live/$D" && touch "$SB/etc/letsencrypt/live/$D/fullchain.pem" "$SB/etc/letsencrypt/live/$D/privkey.pem"
"$GB" apply "$D" >/dev/null 2>&1
check "tls rendered"             "listen [::]:443 ssl;"    "$(cat "$SITE")"
check "http2 native on 1.26"     "http2 on;"               "$(cat "$SITE")"
check "version location"         "location ^~ /v2/"        "$(cat "$SITE")"
check "json extension regex"     '\.(json|txt)$'           "$(cat "$SITE")"
check "endpoint page location"   "location = /v2/ {"       "$(cat "$SITE")"
check "endpoint page file"       "try_files /v2/index.html =404;" "$(cat "$SITE")"
check "version redirect"         "return 301 /v2/;"        "$(cat "$SITE")"
check "openapi from the tree"    "try_files /v2/openapi.json =404;" "$(cat "$SITE")"
check "versions.json location"   "location = /versions.json" "$(cat "$SITE")"
check "no favicon location yet"  ""                        "$(grep -c 'location = /favicon.ico' "$SITE" | sed 's/^0$//')"

echo "-- pages, OpenAPI and favicon --"
printf '\x00\x00\x01\x00' > "$SB/icon.ico"
"$GB" favicon "$SB/icon.ico" >/dev/null 2>&1
check "system favicon recorded"  "FAVICON_MIME=image/vnd.microsoft.icon" "$(cat "$SB/etc/getbible/getbible.conf")"
check "system favicon shown"     "System favicon: $SB/etc/getbible/favicon.ico" "$("$GB" favicon 2>/dev/null)"
check "favicon published"        "same"                    "$(cmp -s "$SB/icon.ico" "$SB/var/www/getbible/$D/favicon.ico" && echo same || echo different)"
check "favicon location"         "default_type image/vnd.microsoft.icon;" "$(cat "$SITE")"
check "pages link the favicon"   '<link rel="icon" href="/favicon.ico">' "$(cat "$SB/var/www/getbible/$D/v2/index.html")"
"$GB" pages "$D" favicon none >/dev/null 2>&1
check "domain favicon none"      "FAVICON_SOURCE=none"     "$(cat "$SB/etc/getbible/endpoints/$D/endpoint.conf")"
check "favicon file removed"     ""                        "$(ls "$SB/var/www/getbible/$D/favicon.ico" 2>/dev/null)"
check "favicon location gone"    ""                        "$(grep -c 'location = /favicon.ico' "$SITE" | sed 's/^0$//')"
"$GB" pages "$D" favicon default >/dev/null 2>&1
check "domain favicon default"   "default_type image/vnd.microsoft.icon;" "$(cat "$SITE")"
"$GB" pages "$D" docs v2 custom >/dev/null 2>&1
check "page taken over"          "DOCS_SOURCE=custom"      "$(cat "$SB/etc/getbible/endpoints/$D/versions/v2.conf")"
printf '<!-- maintained by hand -->\n' >> "$SB/var/www/getbible/$D/v2/index.html"
"$GB" apply "$D" >/dev/null 2>&1
check "custom page kept"         "maintained by hand"      "$(cat "$SB/var/www/getbible/$D/v2/index.html")"
check "status says custom"       "Page /v2/                    custom (maintained by you, present)" "$("$GB" pages "$D" show 2>/dev/null)"
"$GB" pages "$D" docs v2 generated >/dev/null 2>&1
check "page handed back"         ""                        "$(grep -c 'maintained by hand' "$SB/var/www/getbible/$D/v2/index.html" | sed 's/^0$//')"
printf '<html>domain</html>\n' > "$SB/domain.html"
"$GB" pages "$D" docs from "$SB/domain.html" >/dev/null 2>&1
check "domain page copied"       "<html>domain</html>"     "$(cat "$SB/var/www/getbible/$D/index.html")"
check "domain page custom"       "DOCS_SOURCE=custom"      "$(cat "$SB/etc/getbible/endpoints/$D/endpoint.conf")"
"$GB" pages "$D" docs generated >/dev/null 2>&1
check "domain page generated"    "<h1>$D</h1>"             "$(cat "$SB/var/www/getbible/$D/index.html")"
"$GB" pages "$D" docs v2 repository docs/index.html >/dev/null 2>&1
check "repository page recorded" "DOCS_REPO_PATH=docs/index.html" "$(cat "$SB/etc/getbible/endpoints/$D/versions/v2.conf")"
check "repository page served"   "try_files /v2/docs/index.html =404;" "$(cat "$SITE")"
check "repository page exported" "GB_SYNC_EXTRA_FILES=docs/index.html,openapi.json" "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v2.service")"
"$GB" pages "$D" openapi v2 repository api/openapi.json >/dev/null 2>&1
check "openapi path recorded"    "OPENAPI_REPO_PATH=api/openapi.json" "$(cat "$SB/etc/getbible/endpoints/$D/versions/v2.conf")"
check "openapi path served"      "try_files /v2/api/openapi.json =404;" "$(cat "$SITE")"
mkdir -p "$SB/srv/getbible/$D/releases/v2/r1/api" && printf '{"openapi":"3.1.0"}\n' > "$SB/srv/getbible/$D/releases/v2/r1/api/openapi.json"
ln -sfn "releases/v2/r1" "$SB/srv/getbible/$D/v2"
"$GB" pages "$D" publish >/dev/null 2>&1
check "versions.json lists v2"   '"openapi": "https://'"$D"'/v2/openapi.json"' "$(cat "$SB/var/www/getbible/$D/versions.json")"
check "domain page links openapi" '<a href="/v2/openapi.json">openapi.json</a>' "$(cat "$SB/var/www/getbible/$D/index.html")"
"$GB" version add "$D" v3 --repo git@github.com:getbible/v3.git >/dev/null 2>&1
mkdir -p "$SB/srv/getbible/$D/releases/v3/r1"
printf '{}\n' > "$SB/srv/getbible/$D/releases/v3/r1/openapi.json"
ln -s "releases/v3/r1" "$SB/srv/getbible/$D/v3"
"$GB" pages "$D" publish >/dev/null 2>&1
check "discovery adds new version" '"version": "v3"' "$(cat "$SB/var/www/getbible/$D/versions.json")"
sed -i 's/^ENABLED=true$/ENABLED=false/' "$SB/etc/getbible/endpoints/$D/versions/v3.conf"
"$GB" pages "$D" publish >/dev/null 2>&1
check "disabled endpoint not discovered" "v2" "$(python3 -c 'import json,sys; print(",".join(x["version"] for x in json.load(open(sys.argv[1]))["endpoints"]))' "$SB/var/www/getbible/$D/versions.json")"
"$GB" version remove "$D" v3 >/dev/null 2>&1
check "discovery updates on removal" '"version": "v2"' "$(cat "$SB/var/www/getbible/$D/versions.json")"

"$GB" pages "$D" openapi v2 from "$SB/domain.html" >/dev/null 2>&1 && echo "FAIL: invalid JSON accepted as OpenAPI"
printf '{"openapi":"3.1.0","info":{"title":"mine","version":"v2"},"paths":{}}\n' > "$SB/mine.json"
"$GB" pages "$D" openapi v2 from "$SB/mine.json" >/dev/null 2>&1
check "openapi copied"           '"title":"mine"'          "$(cat "$SB/var/www/getbible/$D/v2/openapi.json")"
check "openapi custom served"    "try_files /v2/openapi.json =404;" "$(cat "$SITE")"
"$GB" pages "$D" docs v2 none >/dev/null 2>&1
check "page none: no location"   ""                        "$(grep -c 'location = /v2/ {' "$SITE" | sed 's/^0$//')"
check "page none in status"      "Page /v2/                    none (answers 404)" "$("$GB" pages "$D" show 2>/dev/null)"
"$GB" pages "$D" docs v2 generated >/dev/null 2>&1
check "static cannot generate openapi" "Only runtime endpoints" "$("$GB" pages "$D" openapi v2 generated 2>&1 || true)"
check "repository path checked"  "Invalid repository path" "$("$GB" pages "$D" docs v2 repository '../secret' 2>&1 || true)"
check "unknown page action"      "Actions:"                "$("$GB" pages "$D" docs v2 bogus 2>&1 || true)"
check "domain page not none"     "generated or custom"     "$("$GB" pages "$D" docs none 2>&1 || true)"
check "favicon type checked"     "Favicons are"            "$("$GB" pages "$D" favicon "$SB/domain.html" 2>&1 || true)"

echo "-- tokens and access --"
TOKEN_JSON="$("$GB" token "$D" add "cli test" 2>/dev/null)"
check "token created"            '"token": "gb'            "$(printf '%s' "$TOKEN_JSON" | tr -d '\n' | sed 's/"token":"/"token": "/')"
ID="$(printf '%s' "$TOKEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
check "token listed"             "$ID"                     "$("$GB" token "$D" list 2>/dev/null)"
check "token map rendered"       "\"$D Bearer gb"          "$(cat "$SB/etc/nginx/getbible/tokens/static_example_test.map")"
"$GB" access "$D" token >/dev/null 2>&1
check "token-only auth"          "return 401"              "$(cat "$SB/etc/nginx/getbible/$D/auth.conf")"
check "token-only no limits"     "no limits"               "$(cat "$SB/etc/nginx/getbible/$D/limits.conf")"
"$GB" token "$D" revoke "$ID" >/dev/null 2>&1
check "revoked token gone"       ""                        "$(cat "$SB/etc/nginx/getbible/tokens/static_example_test.map")"
check "revoked in list"          "revoked"                 "$("$GB" token "$D" list 2>/dev/null)"
"$GB" access "$D" open >/dev/null 2>&1
check "open auth"                "no token required"       "$(cat "$SB/etc/nginx/getbible/$D/auth.conf")"
"$GB" access "$D" metered >/dev/null 2>&1
"$GB" limits "$D" --rate 20 --burst 40 --hour 5000 --day 60000 --conn 30 >/dev/null 2>&1
check "limits applied"           "burst=40"                "$(cat "$SB/etc/nginx/getbible/$D/limits.conf")"
check "hour rate"                "rate=84r/m"              "$(cat "$SB/etc/nginx/conf.d/getbible-ep-static_example_test.conf")"
check "conn limit"               "gb_static_example_test_conn 30" "$(cat "$SB/etc/nginx/getbible/$D/limits.conf")"
check "invalid mode rejected"    "Invalid access mode"     "$("$GB" access "$D" bogus 2>&1 || true)"

echo "-- versions --"
"$GB" version add "$D" v1 --repo git@github.com:getbible/v1_scripture.git --ref main --path data >/dev/null 2>&1
check "second version"           "v1"                      "$("$GB" list >/dev/null; ls "$SB/etc/getbible/endpoints/$D/versions/")"
check "v1 location"              "location ^~ /v1/"        "$(cat "$SITE")"
check "v1 unit path"             "GB_SYNC_SUBPATH=data"    "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v1.service")"
"$GB" version change "$D" v1 --ref release --path files >/dev/null 2>&1
check "v1 ref changed"           "REPO_REF=release"        "$(cat "$SB/etc/getbible/endpoints/$D/versions/v1.conf")"
check "v1 path changed"          "GB_SYNC_SUBPATH=files"   "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v1.service")"
check "v1 repo kept"             "REPO_URL=git@github.com:getbible/v1_scripture.git" "$(cat "$SB/etc/getbible/endpoints/$D/versions/v1.conf")"
"$GB" version change "$D" v1 --repo deploy@git.example.test:scripture/v1.git >/dev/null 2>&1
check "custom ssh user accepted" "GB_SYNC_REPO=deploy@git.example.test:scripture/v1.git" "$(cat "$SB/etc/systemd/system/getbible-sync-static_example_test-v1.service")"
check "change needs an option"   "needs --repo"            "$("$GB" version change "$D" v1 2>&1 || true)"
check "change rejects bad url"   "Invalid repository"      "$("$GB" version change "$D" v1 --repo nope 2>&1 || true)"
"$GB" version remove "$D" v1 >/dev/null 2>&1
check "v1 removed"               ""                        "$(grep -c 'location ^~ /v1/' "$SITE" | sed 's/^0$//')"

echo "-- a domain whose only endpoint is its root --"
R=root.example.test
"$GB" deploy static --domain "$R" --version root --repo git@github.com:getbible/scripture.git --extensions json,sha,txt,html >/dev/null 2>&1 || echo "root deploy failed"
mkdir -p "$SB/etc/letsencrypt/live/$R" && touch "$SB/etc/letsencrypt/live/$R/fullchain.pem" "$SB/etc/letsencrypt/live/$R/privkey.pem"
"$GB" apply "$R" >/dev/null 2>&1
RSITE="$SB/etc/nginx/sites-available/$R.conf"
check "root endpoint recorded"   "LABEL=root"              "$(cat "$SB/etc/getbible/endpoints/$R/versions/root.conf")"
check "root tree served at /"    "location ^~ / {"         "$(cat "$RSITE")"
check "root tree directory"      "root $SB/srv/getbible/$R/root;" "$(cat "$RSITE")"
check "root regex"               '^/.+\.(json|txt)$'       "$(cat "$RSITE")"
check "root html regex"          '^/.+\.html$'             "$(cat "$RSITE")"
check "no catch-all 404"         ""                        "$(sed -n '/listen 443/,$p' "$RSITE" | grep -c '^    location / {' | sed 's/^0$//')"
check "root page at /"           "try_files /index.html =404;" "$(cat "$RSITE")"
check "root openapi at /"        "try_files /root/openapi.json =404;" "$(cat "$RSITE")"
check "root discovery location"  "location = /versions.json" "$(cat "$RSITE")"
check "root page rendered"       "<h1>$R</h1>"             "$(cat "$SB/var/www/getbible/$R/index.html")"
check "root page base url"       "https://$R/path/to/document.json" "$(cat "$SB/var/www/getbible/$R/index.html")"
check "root discovery initially empty" '"endpoints": []' "$(cat "$SB/var/www/getbible/$R/versions.json")"
check "root sync unit"           "GB_SYNC_VERSION=root"    "$(cat "$SB/etc/systemd/system/getbible-sync-root_example_test-root.service")"
check "status shows domain root" "Endpoints   : (domain root)" "$("$GB" status "$R" 2>/dev/null)"
check "overview shows root"      "endpoints: domain root"  "$("$GB" status 2>/dev/null)"
check "no folders next to root"  "remove that endpoint before adding version folders" "$("$GB" version add "$R" v1 --repo git@github.com:getbible/v1.git 2>&1 || true)"
check "no root next to folders"  "its root cannot become an endpoint" "$("$GB" version add "$D" root --repo git@github.com:getbible/v1.git 2>&1 || true)"
"$GB" pages "$R" docs root repository docs/index.html >/dev/null 2>&1
check "root repository page"     "try_files /root/docs/index.html =404;" "$(cat "$RSITE")"
"$GB" pages "$R" docs from "$SB/domain.html" >/dev/null 2>&1
check "root page taken over"     "DOCS_SOURCE=custom"      "$(cat "$SB/etc/getbible/endpoints/$R/versions/root.conf")"
check "root page not domain key" ""                        "$(grep -c '^DOCS_SOURCE=custom' "$SB/etc/getbible/endpoints/$R/endpoint.conf" | sed 's/^0$//')"
"$GB" apply "$R" >/dev/null 2>&1
check "root custom page kept"    "<html>domain</html>"     "$(cat "$SB/var/www/getbible/$R/index.html")"
"$GB" pages "$R" docs root generated >/dev/null 2>&1
"$GB" remove "$R" --purge >/dev/null 2>&1
check "root domain removed"      ""                        "$(ls "$SB/etc/nginx/sites-available/$R.conf" 2>/dev/null)"

echo "-- validation --"
check "bad domain rejected"      "Invalid domain"          "$("$GB" deploy static --domain 'bad domain' --version v2 --repo git@x:y.git 2>&1 || true)"
check "bad version rejected"     "Invalid version"         "$("$GB" deploy static --domain ok.example.test --version two --repo git@x:y.git 2>&1 || true)"
check "bad repo rejected"        "Invalid repository"      "$("$GB" deploy static --domain ok.example.test --version v2 --repo 'nope' 2>&1 || true)"
check "duplicate rejected"       "already exists"          "$("$GB" deploy static --domain "$D" --version v2 --repo git@x:y.git 2>&1 || true)"

echo "-- render and drift --"
OUT="$SB/render-out"; mkdir -p "$OUT"
"$GB" render "$D" --out "$OUT" >/dev/null 2>&1
check "render writes site"       "server_name $D;"         "$(cat "$OUT/sites-available/$D.conf")"
GB_NGINX_FAKE_VERSION=1.24.0 "$GB" render "$D" --out "$OUT" >/dev/null 2>&1
check "aio off before 1.25.4"    "aio                off;"  "$(cat "$OUT/getbible/$D/server.conf")"
BEFORE="$(find "$SB/etc/nginx" -type f -exec sha256sum {} + | sort)"
"$GB" apply "$D" >/dev/null 2>&1
AFTER="$(find "$SB/etc/nginx" -type f -exec sha256sum {} + | sort)"
check "re-apply idempotent"      "same"                    "$([[ "$BEFORE" == "$AFTER" ]] && echo same || echo different)"
echo "# hand edit" >> "$SITE"
check "hand edit kept with --yes" "hand edit"              "$("$GB" apply "$D" >/dev/null 2>&1; cat "$SITE")"
check "hand edit warned"         "edited by hand"          "$("$GB" apply "$D" 2>&1 || true)"

echo "-- removal --"
"$GB" remove "$D" --purge >/dev/null 2>&1
check "endpoint gone"            ""                        "$("$GB" list)"
check "site gone"                ""                        "$(ls "$SB/etc/nginx/sites-available/" 2>/dev/null)"
check "sync units gone"          ""                        "$(find "$SB/etc/systemd/system" -name 'getbible-sync-*' -printf '%f\n')"

echo "-- nginx -t on the rendered configuration --"
if command -v nginx >/dev/null; then
    unset GB_NGINX_FAKE_VERSION GB_NGINX_FAKE_BROTLI
    export GB_NGINX_FAKE_IPV6=false
    "$GB" deploy static --domain "$D" --version v2 --repo git@github.com:getbible/v2_scripture.git >/dev/null 2>&1
    "$GB" deploy static --domain "$R" --version root --repo git@github.com:getbible/scripture.git --extensions json,sha,txt,html >/dev/null 2>&1
    for domain in "$D" "$R"; do
        mkdir -p "$SB/etc/letsencrypt/live/$domain"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$SB/etc/letsencrypt/live/$domain/privkey.pem" -out "$SB/etc/letsencrypt/live/$domain/fullchain.pem" -subj "/CN=$domain" 2>/dev/null
    done
    "$GB" pages "$D" docs v2 repository docs/index.html >/dev/null 2>&1
    "$GB" apply "$D" >/dev/null 2>&1
    "$GB" apply "$R" >/dev/null 2>&1
    mkdir -p "$SB/etc/nginx/logs" "$SB/var/cache/nginx/getbible"
    # nginx -t binds every listener; move them to high ports so the test
    # needs no privileges.
    sed -i -e 's/listen 80;/listen 127.0.0.1:18180;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18543 ssl\1;/' "$SB/etc/nginx/sites-available/$D.conf"
    sed -i -e 's/listen 80;/listen 127.0.0.1:18181;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18544 ssl\1;/' "$SB/etc/nginx/sites-available/$R.conf"
    cat > "$SB/etc/nginx/nginx-test.conf" <<EOF
pid $SB/nginx.pid;
error_log stderr warn;
events { worker_connections 16; }
http { access_log off; include /etc/nginx/mime.types; include $SB/etc/nginx/conf.d/*.conf; include $SB/etc/nginx/sites-enabled/*.conf; }
EOF
    check "nginx -t"             "successful"              "$(nginx -t -c "$SB/etc/nginx/nginx-test.conf" -p "$SB/etc/nginx" 2>&1)"
else
    echo "  (nginx not installed; skipped)"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
