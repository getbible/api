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
    if [[ "$actual" == *"$expected"* ]]; then printf '  ok    %s\n' "$label"; PASS=$((PASS + 1)); else printf '  FAIL  %-48s expected %-24s got: %s\n' "$label" "$expected" "${actual:0:160}"; FAIL=$((FAIL + 1)); fi
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
check "tools installed"          "getbible-sync"           "$(ls "$SB/usr/local/lib/getbible/")"

echo "-- TLS phase --"
mkdir -p "$SB/etc/letsencrypt/live/$D" && touch "$SB/etc/letsencrypt/live/$D/fullchain.pem" "$SB/etc/letsencrypt/live/$D/privkey.pem"
"$GB" apply "$D" >/dev/null 2>&1
check "tls rendered"             "listen [::]:443 ssl;"    "$(cat "$SITE")"
check "http2 native on 1.26"     "http2 on;"               "$(cat "$SITE")"
check "version location"         "location ^~ /v2/"        "$(cat "$SITE")"
check "json extension regex"     '\.(json|txt)$'           "$(cat "$SITE")"

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
"$GB" version remove "$D" v1 >/dev/null 2>&1
check "v1 removed"               ""                        "$(grep -c 'location ^~ /v1/' "$SITE" | sed 's/^0$//')"

echo "-- validation --"
check "bad domain rejected"      "Invalid domain"          "$("$GB" deploy static --domain 'bad domain' --version v2 --repo git@x:y.git 2>&1 || true)"
check "bad version rejected"     "Invalid version"         "$("$GB" deploy static --domain ok.example.test --version two --repo git@x:y.git 2>&1 || true)"
check "bad repo rejected"        "Invalid repository"      "$("$GB" deploy static --domain ok.example.test --version v2 --repo 'nope' 2>&1 || true)"
check "duplicate rejected"       "already exists"          "$("$GB" deploy static --domain "$D" --version v2 --repo git@x:y.git 2>&1 || true)"

echo "-- render and drift --"
OUT="$SB/render-out"; mkdir -p "$OUT"
"$GB" render "$D" --out "$OUT" >/dev/null 2>&1
check "render writes site"       "server_name $D;"         "$(cat "$OUT/sites-available/$D.conf")"
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
    mkdir -p "$SB/etc/letsencrypt/live/$D"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$SB/etc/letsencrypt/live/$D/privkey.pem" -out "$SB/etc/letsencrypt/live/$D/fullchain.pem" -subj "/CN=$D" 2>/dev/null
    "$GB" apply "$D" >/dev/null 2>&1
    mkdir -p "$SB/etc/nginx/logs" "$SB/var/cache/nginx/getbible"
    # nginx -t binds every listener; move them to high ports so the test
    # needs no privileges.
    sed -i -e 's/listen 80;/listen 127.0.0.1:18180;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18543 ssl\1;/' "$SB/etc/nginx/sites-available/$D.conf"
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
