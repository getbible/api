#!/usr/bin/env bash
# Staged deployments and go-live inside a throw-away prefix. certbot is
# replaced by a recorder that answers `plugins` and "issues" certificates, so
# every certificate request can be asserted without touching Let's Encrypt.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false GB_NGINX_FAKE_VERSION=1.26.0 GB_NGINX_FAKE_BROTLI=false
GB="$ROOT/getbible.sh"
PASS=0; FAIL=0
check() {
    local label="$1" expected="$2" actual="$3"
    if { [[ -z "$expected" && -z "$actual" ]]; } || { [[ -n "$expected" && "$actual" == *"$expected"* ]]; }; then
        printf '  ok    %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s expected %-24s got: %s\n' "$label" "$expected" "${actual:0:200}"; FAIL=$((FAIL + 1))
    fi
}

mkdir -p "$SB/bin"
cat > "$SB/bin/certbot" <<'CERTBOT'
#!/usr/bin/env bash
# Records its arguments; creates the live directory unless told to fail.
printf '%s\n' "$*" >> "$CERTBOT_LOG"
if [[ "${1:-}" == plugins ]]; then printf '* webroot\n* dns-cloudflare\n'; exit 0; fi
[[ ! -f "$CERTBOT_FAIL_FILE" ]] || exit 1
domain=""
while (($#)); do
    if [[ "$1" == -d ]]; then domain="$2"; fi
    shift
done
mkdir -p "$CERTBOT_LIVE/$domain"
printf 'certificate\n' > "$CERTBOT_LIVE/$domain/fullchain.pem"
printf 'key\n' > "$CERTBOT_LIVE/$domain/privkey.pem"
CERTBOT
chmod +x "$SB/bin/certbot"
# The same stand-in without the DNS plugin.
sed 's/\* dns-cloudflare\\n//' "$SB/bin/certbot" > "$SB/bin/certbot-noplugin"
chmod +x "$SB/bin/certbot-noplugin"
export GB_CERTBOT="$SB/bin/certbot" CERTBOT_LOG="$SB/certbot.log" CERTBOT_FAIL_FILE="$SB/certbot.fail" CERTBOT_LIVE="$SB/etc/letsencrypt/live"
: > "$CERTBOT_LOG"
conf() { cat "$SB/etc/getbible/endpoints/$1/endpoint.conf"; }
placeholder() { if [[ -d "$PLACEHOLDERS/$1" ]]; then printf 'present'; fi; }
certonly_runs() { grep -c '^certonly' "$CERTBOT_LOG" || true; }
site() { cat "$SB/etc/nginx/sites-available/$1.conf"; }
PLACEHOLDERS="$SB/etc/getbible/placeholder-certs"

D=staged.example.test
echo "-- staged deployment --"
"$GB" deploy static --domain "$D" --version v2 --repo git@github.com:getbible/v2_scripture.git --extensions json,sha,txt --staged >/dev/null 2>&1 || { echo "staged deploy failed"; exit 1; }
check "recorded as staged"        "LIVE=false"                  "$(conf "$D")"
check "overview shows staged"     "staged"                      "$("$GB" status 2>/dev/null)"
check "status shows publication"  "Publication : staged"        "$("$GB" status "$D" 2>/dev/null)"
check "placeholder certificate"   "BEGIN CERTIFICATE"           "$(cat "$PLACEHOLDERS/$D/fullchain.pem")"
check "placeholder key private"   "600"                         "$(stat -c %a "$PLACEHOLDERS/$D/privkey.pem")"
check "placeholder dir private"   "700"                         "$(stat -c %a "$PLACEHOLDERS/$D")"
check "placeholder names domain"  "DNS:$D"                      "$(openssl x509 -in "$PLACEHOLDERS/$D/fullchain.pem" -noout -text 2>/dev/null)"
check "tls vhost rendered"        "listen 443 ssl"              "$(site "$D")"
check "vhost uses placeholder"    "placeholder-certs/$D/fullchain.pem" "$(site "$D")"
check "acme snippet kept"         "snippets/getbible/acme.conf" "$(site "$D")"
check "certbot not called"        ""                            "$(cat "$CERTBOT_LOG")"
check "certificate line"          "self-signed placeholder"     "$("$GB" status "$D" 2>/dev/null)"
check "cert status"               "placeholder"                 "$("$GB" cert "$D" status 2>/dev/null)"
check "verify reports staged"     "Publication"                 "$("$GB" verify "$D" 2>&1 || true)"
check "verify passes in sandbox"  "passed"                      "$("$GB" verify "$D" 2>&1 || true)"
check "re-apply stays staged"     "is staged: no certificate"   "$("$GB" apply "$D" 2>&1 || true)"
check "re-apply keeps LIVE=false" "LIVE=false"                  "$(conf "$D")"

echo "-- staged endpoints never touch Cloudflare --"
# Keep the go-live plan hermetic: the public address comes from settings.
sed -i 's/^SERVER_PUBLIC_IPV4=.*/SERVER_PUBLIC_IPV4=203.0.113.10/' "$SB/etc/getbible/getbible.conf"
"$GB" cloudflare mode "$D" proxied >/dev/null 2>&1 || true
check "mode recorded"             "CLOUDFLARE_MODE=proxied"     "$(conf "$D")"
check "no real-ip include staged" ""                            "$(grep -c cloudflare-real-ip "$SB/etc/nginx/sites-available/$D.conf" | sed 's/^0$//')"
check "cloudflare apply deferred" "applied when it goes live"   "$("$GB" cloudflare apply "$D" 2>&1 || true)"

echo "-- go-live refusals leave the endpoint staged --"
check "unpublished data refused"  "never published"             "$("$GB" go-live "$D" 2>&1 || true)"
mkdir -p "$SB/srv/getbible/$D/releases/v2/stamp" && ln -sfn "releases/v2/stamp" "$SB/srv/getbible/$D/v2"
check "contact email required"    "contact email"               "$("$GB" go-live "$D" --cert http 2>&1 || true)"
"$GB" settings certbot-email ops@example.test >/dev/null 2>&1
check "email stored"              "CERTBOT_EMAIL=ops@example.test" "$(cat "$SB/etc/getbible/getbible.conf")"
check "invalid email rejected"    "Invalid email"               "$("$GB" settings certbot-email nope 2>&1 || true)"
check "managed domain needs token" "Cloudflare API token"       "$("$GB" go-live "$D" --cert http 2>&1 || true)"
check "empty --cert rejected"     "needs auto, http or dns-cloudflare" "$("$GB" go-live "$D" --cert 2>&1 || true)"
check "auto is http without token" "Next issue  : http"         "$("$GB" cert "$D" status 2>/dev/null)"
printf 'CLOUDFLARE_API_TOKEN=cf-test-token\n' > "$SB/etc/getbible/cloudflare.conf"
check "auto is dns-01 when managed" "Next issue  : dns-cloudflare" "$("$GB" cert "$D" status 2>/dev/null)"
check "http via cloudflare refused" "needs the name to reach this server" "$(GB_FAKE_HTTP_PROBE=1 "$GB" go-live "$D" --cert http 2>&1 || true)"
check "still staged"              "LIVE=false"                  "$(conf "$D")"
check "certbot never issued"      "0"                           "$(certonly_runs)"
check "plan names the address"    "203.0.113.10"                "$(GB_FAKE_HTTP_PROBE=0 "$GB" go-live "$D" --cert http --dry-run 2>&1 || true)"
check "dry run kept placeholder"  "present"                     "$(placeholder "$D")"
"$GB" cloudflare mode "$D" off >/dev/null 2>&1 || true
check "auto is http when unmanaged" "Next issue  : http"        "$("$GB" cert "$D" status 2>/dev/null)"
touch "$CERTBOT_FAIL_FILE"
check "certbot failure reported"  "stays staged"                "$("$GB" go-live "$D" --cert http 2>&1 || true)"
check "webroot arguments"         "certonly --webroot -w $SB/var/www/letsencrypt -d $D --non-interactive --agree-tos --email ops@example.test" "$(cat "$CERTBOT_LOG")"
check "LIVE still false"          "LIVE=false"                  "$(conf "$D")"
check "placeholder kept"          "fullchain.pem"               "$(ls "$PLACEHOLDERS/$D/")"
check "vhost still placeholder"   "placeholder-certs/$D"        "$(site "$D")"
rm -f "$CERTBOT_FAIL_FILE"; : > "$CERTBOT_LOG"
check "dry run changes nothing"   "(dry-run) would issue"       "$("$GB" go-live "$D" --cert http --dry-run 2>&1 || true)"
check "dry run kept staged"       "LIVE=false"                  "$(conf "$D")"
check "dry run ran no certbot"    "0"                           "$(certonly_runs)"

echo "-- go-live with DNS-01 through Cloudflare --"
"$GB" settings cert-method auto >/dev/null 2>&1
check "settings listed"           "cert-method    auto"         "$("$GB" settings 2>/dev/null)"
check "dns-01 without plugin"     "certbot-dns-cloudflare plugin" "$(GB_CERTBOT="$SB/bin/certbot-noplugin" "$GB" go-live "$D" --cert dns-cloudflare 2>&1 || true)"
OUT="$("$GB" go-live "$D" --cert dns-cloudflare 2>&1 || true)"
check "plan shown"                "Request a Let's Encrypt certificate: DNS-01" "$OUT"
check "went live"                 "$D is live"                  "$OUT"
check "dns-cloudflare arguments"  "certonly --dns-cloudflare --dns-cloudflare-credentials $SB/etc/getbible/certbot-cloudflare.ini --dns-cloudflare-propagation-seconds 30 -d $D" "$(cat "$CERTBOT_LOG")"
check "credentials written"       "dns_cloudflare_api_token = cf-test-token" "$(cat "$SB/etc/getbible/certbot-cloudflare.ini")"
check "credentials private"       "600"                         "$(stat -c %a "$SB/etc/getbible/certbot-cloudflare.ini")"
check "now live"                  "LIVE=true"                   "$(conf "$D")"
check "vhost uses letsencrypt"    "letsencrypt/live/$D/fullchain.pem" "$(site "$D")"
check "placeholder removed"       ""                            "$(ls "$PLACEHOLDERS/" 2>/dev/null)"
check "live in status"            "Publication : live since"    "$("$GB" status "$D" 2>/dev/null)"
check "live_at recorded"          "LIVE_AT="                    "$(cat "$SB/var/lib/getbible/state/$D/state.conf")"
check "go-live idempotent"        "already live"                "$("$GB" go-live "$D" 2>&1 || true)"
check "verification ran"          "Verification of $D"          "$OUT"

echo "-- default deploy mode from settings --"
"$GB" settings deploy-mode staged >/dev/null 2>&1
D2=second.example.test
"$GB" deploy static --domain "$D2" --version v1 --repo git@github.com:getbible/v1_scripture.git >/dev/null 2>&1
check "default staged"            "LIVE=false"                  "$(conf "$D2")"
: > "$CERTBOT_LOG"
D3=third.example.test
"$GB" deploy static --domain "$D3" --version v1 --repo git@github.com:getbible/v1_scripture.git --live >/dev/null 2>&1
check "--live overrides default"  "LIVE=true"                   "$(conf "$D3")"
check "live deploy requests cert" "-d $D3"                      "$(cat "$CERTBOT_LOG")"
check "live deploy no placeholder" ""                           "$(placeholder "$D3")"
"$GB" settings deploy-mode live >/dev/null 2>&1
check "invalid deploy mode"       "live or staged"              "$("$GB" settings deploy-mode maybe 2>&1 || true)"
check "invalid cert method"       "auto, http or dns-cloudflare" "$("$GB" settings cert-method carrier-pigeon 2>&1 || true)"

echo "-- endpoints without a LIVE key are live --"
sed -i '/^LIVE=/d' "$SB/etc/getbible/endpoints/$D2/endpoint.conf"
check "missing key means live"    "Publication : live"          "$("$GB" status "$D2" 2>/dev/null)"
"$GB" apply "$D2" >/dev/null 2>&1 || true
check "live apply drops placeholder" ""                         "$(placeholder "$D2")"
check "live apply used certbot"   "-d $D2"                      "$(cat "$CERTBOT_LOG")"

echo "-- certificate issued while staged --"
D4=fourth.example.test
"$GB" deploy static --domain "$D4" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
: > "$CERTBOT_LOG"
"$GB" cert "$D4" issue --method http >/dev/null 2>&1 || true
check "issue used http"           "certonly --webroot"          "$(cat "$CERTBOT_LOG")"
check "issue keeps staged"        "LIVE=false"                  "$(conf "$D4")"
check "staged vhost real cert"    "letsencrypt/live/$D4"        "$(site "$D4")"
check "cert status letsencrypt"   "Let's Encrypt"               "$("$GB" cert "$D4" status 2>/dev/null)"
check "issue idempotent"          "already has"                 "$("$GB" cert "$D4" issue 2>&1 || true)"
mkdir -p "$SB/srv/getbible/$D4/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D4/v1"
: > "$CERTBOT_LOG"
check "go-live keeps certificate" "Keep the existing Let's Encrypt certificate" "$("$GB" go-live "$D4" 2>&1 || true)"
check "no new certbot run"        "0"                           "$(certonly_runs)"
check "fourth is live"            "LIVE=true"                   "$(conf "$D4")"
check "placeholder cleaned"       ""                            "$(placeholder "$D4")"

echo "-- removal cleans up --"
D5=fifth.example.test
"$GB" deploy static --domain "$D5" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
check "fifth has placeholder"     "present"                     "$(placeholder "$D5")"
"$GB" remove "$D5" --purge >/dev/null 2>&1
check "removal drops placeholder" ""                            "$(placeholder "$D5")"
check "removal drops registry"    ""                            "$("$GB" list | grep "$D5" || true)"

echo "-- certbot command lines --"
# shellcheck source=../../src/lib/core.sh
GB_REPO_DIR="$ROOT" source "$ROOT/src/lib/core.sh"
# core.sh installs its own EXIT trap; keep removing the sandbox as well.
trap 'rm -rf "$SB"; gb_cleanup' EXIT
# shellcheck source=../../src/lib/config.sh
source "$ROOT/src/lib/config.sh"
# shellcheck source=../../src/lib/certs.sh
source "$ROOT/src/lib/certs.sh"
check "http argv"                 "--webroot"                   "$(certs_certbot_args a.example.test http a@b.c | tr '\n' ' ')"
check "dns argv"                  "--dns-cloudflare-credentials $GB_CERTBOT_CLOUDFLARE_INI" "$(certs_certbot_args a.example.test dns-cloudflare a@b.c | tr '\n' ' ')"
check "argv keeps email"          "--email a@b.c --keep-until-expiring" "$(certs_certbot_args a.example.test http a@b.c | tr '\n' ' ')"
check "unknown method rejected"   ""                            "$(certs_certbot_args a.example.test carrier-pigeon a@b.c 2>/dev/null || true)"
check "method validation"         "no"                          "$(certs_valid_method magic && echo yes || echo no)"

echo "-- nginx -t on a staged vhost --"
if command -v nginx >/dev/null; then
    unset GB_NGINX_FAKE_VERSION GB_NGINX_FAKE_BROTLI
    export GB_NGINX_FAKE_IPV6=false
    D6=sixth.example.test
    "$GB" deploy static --domain "$D6" --version v2 --repo git@github.com:getbible/v2_scripture.git --staged >/dev/null 2>&1
    mkdir -p "$SB/etc/nginx/logs" "$SB/var/cache/nginx/getbible"
    sed -i -e 's/listen 80;/listen 127.0.0.1:18280;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18643 ssl\1;/' "$SB/etc/nginx/sites-available/$D6.conf"
    for other in "$D" "$D2" "$D3" "$D4"; do rm -f "$SB/etc/nginx/sites-enabled/$other.conf"; done
    cat > "$SB/etc/nginx/nginx-test.conf" <<EOF
pid $SB/nginx.pid;
error_log stderr warn;
events { worker_connections 16; }
http { access_log off; include /etc/nginx/mime.types; include $SB/etc/nginx/conf.d/*.conf; include $SB/etc/nginx/sites-enabled/*.conf; }
EOF
    check "nginx -t accepts placeholder" "successful"           "$(nginx -t -c "$SB/etc/nginx/nginx-test.conf" -p "$SB/etc/nginx" 2>&1)"
else
    echo "  (nginx not installed; skipped)"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
