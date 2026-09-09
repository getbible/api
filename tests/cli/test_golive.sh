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
args=" $* "
domain=""
while (($#)); do
    if [[ "$1" == -d ]]; then domain="$2"; fi
    shift
done
mkdir -p "$CERTBOT_LIVE/$domain" "$CERTBOT_LIVE/../renewal"
printf 'certificate\n' > "$CERTBOT_LIVE/$domain/fullchain.pem"
printf 'key\n' > "$CERTBOT_LIVE/$domain/privkey.pem"
# Simulate a file changing under the tool between its checks and the switch.
[[ -z "${CERTBOT_TAMPER:-}" ]] || echo "# hand edit" >> "$CERTBOT_TAMPER"
if [[ "$args" == *" --dns-cloudflare "* ]]; then
    printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$CERTBOT_INI" > "$CERTBOT_LIVE/../renewal/$domain.conf"
else
    printf '[renewalparams]\nauthenticator = webroot\nwebroot_path = %s,\n' "$CERTBOT_WEBROOT" > "$CERTBOT_LIVE/../renewal/$domain.conf"
fi
CERTBOT
chmod +x "$SB/bin/certbot"
# The same stand-in without the DNS plugin.
sed 's/\* dns-cloudflare\\n//' "$SB/bin/certbot" > "$SB/bin/certbot-noplugin"
chmod +x "$SB/bin/certbot-noplugin"
export GB_CERTBOT="$SB/bin/certbot" CERTBOT_LOG="$SB/certbot.log" CERTBOT_FAIL_FILE="$SB/certbot.fail" CERTBOT_LIVE="$SB/etc/letsencrypt/live"
export CERTBOT_INI="$SB/etc/getbible/certbot-cloudflare.ini" CERTBOT_WEBROOT="$SB/var/www/letsencrypt"
: > "$CERTBOT_LOG"
# A Cloudflare helper stand-in: GB_PYTHON runs every tool, so the wrapper
# answers for getbible-cloudflare and hands everything else to python3.
cat > "$SB/bin/python-cf" <<'PYCF'
#!/usr/bin/env bash
if [[ "${1:-}" == */getbible-cloudflare ]]; then
    shift
    # Human-readable output is a global option before the operation name.
    [[ "${1:-}" != --human ]] || shift
    printf '%s\n' "$*" >> "$CF_LOG"
    [[ -z "${CF_FAIL:-}" || "$1" != "$CF_FAIL" ]] || exit 1
    case "$1" in
        ips) printf '{"ipv4":["203.0.113.0/24"],"ipv6":["2001:db8::/32"]}\n' ;;
        origin-ca) printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' ;;
        *) printf '{}\n' ;;
    esac
    exit 0
fi
exec /usr/bin/env python3 "$@"
PYCF
chmod +x "$SB/bin/python-cf"
export CF_LOG="$SB/cloudflare.log"
: > "$CF_LOG"
conf() { cat "$SB/etc/getbible/endpoints/$1/endpoint.conf"; }
placeholder() { if [[ -d "$PLACEHOLDERS/$1" ]]; then printf 'present'; fi; }
certonly_runs() { grep -c '^certonly' "$CERTBOT_LOG" || true; }
site() { cat "$SB/etc/nginx/sites-available/$1.conf"; }
PLACEHOLDERS="$SB/etc/getbible/placeholder-certs"

D=staged.example.test
echo "-- staged deployment --"
"$GB" deploy static --domain "$D" --version v2 --repo git@github.com:getbible/v2_scripture.git --extensions json,sha,txt --staged >/dev/null 2>&1 || { echo "staged deploy failed"; exit 1; }
check "recorded as staged"        "LIVE=false"                  "$(conf "$D")"
check "overview shows staged"     "endpoints: v2  · staged"      "$("$GB" status 2>/dev/null)"
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
VERIFY="$("$GB" verify "$D" 2>&1 || true)"
check "verify reports staged"     "Publication                    info  staged" "$VERIFY"
check "verify shows placeholder"  "Certificate                    WARN  self-signed placeholder" "$VERIFY"
check "verify skips probes here"  "HTTPS probe                    skip" "$VERIFY"
check "verify skips nginx -t"     "nginx -t                       skip" "$VERIFY"
check "verify passes in sandbox"  "everything that can be checked here passed" "$VERIFY"
check "re-apply stays staged"     "is staged: no certificate"   "$("$GB" apply "$D" 2>&1 || true)"
check "re-apply keeps LIVE=false" "LIVE=false"                  "$(conf "$D")"

echo "-- staged endpoints never touch Cloudflare --"
# Keep the go-live plan hermetic: the public address comes from settings.
"$GB" settings public-ipv4 203.0.113.10 >/dev/null 2>&1
grep -q '^SERVER_PUBLIC_IPV4=203.0.113.10$' "$SB/etc/getbible/getbible.conf" || { echo "public address not pinned"; exit 1; }
check "invalid ipv4 rejected"     "Invalid IPv4"                "$("$GB" settings public-ipv4 nope 2>&1 || true)"
check "settings show address"     "public-ipv4    203.0.113.10" "$("$GB" settings 2>/dev/null)"
"$GB" cloudflare mode "$D" proxied >/dev/null 2>&1 || true
check "mode recorded"             "CLOUDFLARE_MODE=proxied"     "$(conf "$D")"
check "status shows cache, pulls" "proxied (edge cache bypass, origin pulls false)" "$("$GB" status "$D" 2>/dev/null)"
check "no real-ip include staged" ""                            "$(grep -c cloudflare-real-ip "$SB/etc/nginx/sites-available/$D.conf" | sed 's/^0$//')"
check "cloudflare apply deferred" "applied when it goes live"   "$("$GB" cloudflare apply "$D" 2>&1 || true)"
# Positive control: once the ranges file exists the include is rendered,
# staged or not, so "Stage again" never strips it from a serving vhost.
mkdir -p "$SB/render-before" "$SB/render-after"
"$GB" render "$D" --out "$SB/render-before" >/dev/null 2>&1
check "render without ranges: no include" ""                    "$(grep -c cloudflare-real-ip "$SB/render-before/sites-available/$D.conf" | sed 's/^0$//')"
printf 'set_real_ip_from 203.0.113.0/24;\n' > "$SB/etc/nginx/getbible/cloudflare-real-ip.conf"
"$GB" render "$D" --out "$SB/render-after" >/dev/null 2>&1
check "render with ranges: include" "cloudflare-real-ip.conf"   "$(cat "$SB/render-after/sites-available/$D.conf")"
rm -f "$SB/etc/nginx/getbible/cloudflare-real-ip.conf"

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
check "renew needs a certificate" "issue one first"             "$("$GB" cert "$D" renew 2>&1 || true)"
check "renew failure is not fatal" ""                           "$("$GB" cert "$D" renew 2>&1 | grep -c 'ERROR' | sed 's/^0$//')"
"$GB" settings cert-method http >/dev/null 2>&1
check "settings http wins for auto" "certificate: HTTP-01"      "$("$GB" go-live "$D" --dry-run 2>&1 || true)"
"$GB" settings cert-method auto >/dev/null 2>&1
touch "$CERTBOT_FAIL_FILE"
check "certbot failure reported"  "No certificate was issued"   "$("$GB" go-live "$D" --cert http 2>&1 || true)"
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
check "renewal method recorded"   "renewal method dns-cloudflare" "$("$GB" cert "$D" status 2>/dev/null)"
check "doctor accepts renewals"   ""                            "$("$GB" doctor 2>/dev/null | grep -c 'DNS-01 renewals' | sed 's/^0$//')"
mv "$SB/etc/getbible/certbot-cloudflare.ini" "$SB/certbot-cloudflare.ini.away"
check "doctor warns missing ini"  "WARN   missing credentials file or plugin for: $D" "$("$GB" doctor 2>/dev/null)"
mv "$SB/certbot-cloudflare.ini.away" "$SB/etc/getbible/certbot-cloudflare.ini"
printf '[renewalparams]\nauthenticator = unsupported\n' > "$SB/etc/letsencrypt/renewal/$D.conf"
check "doctor warns authenticator drift" "WARN   unexpected or missing authenticator for: $D" "$("$GB" doctor 2>/dev/null)"
printf '[renewalparams]\nauthenticator = webroot\nwebroot_path = %s-unserved,\n' "$CERTBOT_WEBROOT" > "$SB/etc/letsencrypt/renewal/$D.conf"
check "doctor warns changed challenge root" "is missing or changed for: $D" "$("$GB" doctor 2>/dev/null)"
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$CERTBOT_INI" > "$SB/etc/letsencrypt/renewal/$D.conf"

echo "-- stage again, for rolling back --"
"$GB" stage "$D" >/dev/null 2>&1
check "staged again"              "LIVE=false"                  "$(conf "$D")"
check "live_at cleared"           ""                            "$(grep '^LIVE_AT=.' "$SB/var/lib/getbible/state/$D/state.conf" || true)"
check "still serves letsencrypt"  "letsencrypt/live/$D"         "$(site "$D")"
check "stage again idempotent"    "already staged"              "$("$GB" stage "$D" 2>&1 || true)"
check "go-live keeps certificate" "Keep the existing"           "$("$GB" go-live "$D" 2>&1 || true)"
check "live once more"            "LIVE=true"                   "$(conf "$D")"

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

echo "-- certificate issued while staged --"
D4=fourth.example.test
"$GB" deploy static --domain "$D4" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
: > "$CERTBOT_LOG"
"$GB" cert "$D4" issue --method http >/dev/null 2>&1 || true
check "issue used http"           "certonly --webroot"          "$(cat "$CERTBOT_LOG")"
check "issue keeps staged"        "LIVE=false"                  "$(conf "$D4")"
check "staged vhost real cert"    "letsencrypt/live/$D4"        "$(site "$D4")"
check "cert status letsencrypt"   "Let's Encrypt"               "$("$GB" cert "$D4" status 2>/dev/null)"
check "renewal method http"       "renewal method http"         "$("$GB" cert "$D4" status 2>/dev/null)"
check "issue idempotent"          "already has"                 "$("$GB" cert "$D4" issue 2>&1 || true)"
mkdir -p "$SB/srv/getbible/$D4/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D4/v1"
: > "$CERTBOT_LOG"
check "go-live keeps certificate" "Keep the existing Let's Encrypt certificate" "$("$GB" go-live "$D4" 2>&1 || true)"
check "no new certbot run"        "0"                           "$(certonly_runs)"
check "fourth is live"            "LIVE=true"                   "$(conf "$D4")"
check "placeholder cleaned"       ""                            "$(placeholder "$D4")"

echo "-- renewal hook failures block success and retry reuses the certificate --"
DH=hook-failure.example.test
"$GB" deploy static --domain "$DH" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
HOOK_DIR="$SB/etc/letsencrypt/renewal-hooks/deploy"
HOOK="$HOOK_DIR/getbible-reload-nginx.sh"
mv "$HOOK_DIR" "$SB/renewal-hooks.saved"
printf 'blocked directory\n' > "$HOOK_DIR"
: > "$CERTBOT_LOG"
HOOK_STATUS=0
"$GB" cert "$DH" issue --method http > "$SB/hook-failure.out" 2>&1 || HOOK_STATUS=$?
check "new certificate requires renewal hook" "1" "$HOOK_STATUS"
check "hook failure identifies renewal setup" "certificate renewal hook" "$(cat "$SB/hook-failure.out")"
check "issued certificate retained after hook failure" "certificate" "$(cat "$CERTBOT_LIVE/$DH/fullchain.pem")"
check "failed issuance keeps staged vhost" "placeholder-certs/$DH" "$(site "$DH")"
HOOK_STATUS=0
"$GB" cert "$DH" issue --method http > "$SB/hook-reuse-failure.out" 2>&1 || HOOK_STATUS=$?
check "certificate reuse also requires renewal hook" "1" "$HOOK_STATUS"
check "reuse failure does not request another certificate" "1" "$(certonly_runs)"
HOOK_STATUS=0
"$GB" cert "$DH" renew > "$SB/hook-renew-failure.out" 2>&1 || HOOK_STATUS=$?
check "manual renewal requires its hook" "1" "$HOOK_STATUS"
check "blocked hook prevents certbot renewal" "" "$(grep '^renew ' "$CERTBOT_LOG" || true)"
HOOK_STATUS=0
"$GB" apply "$DH" > "$SB/hook-apply-failure.out" 2>&1 || HOOK_STATUS=$?
check "ordinary apply reports hook failure" "1" "$HOOK_STATUS"
check "failed apply keeps staged vhost" "placeholder-certs/$DH" "$(site "$DH")"
rm -f "$HOOK_DIR"
mv "$SB/renewal-hooks.saved" "$HOOK_DIR"
"$GB" cert "$DH" issue --method http >/dev/null 2>&1
check "retry adopts the saved certificate" "letsencrypt/live/$DH" "$(site "$DH")"
check "retry avoids duplicate issuance" "1" "$(certonly_runs)"
rm -f "$HOOK"
"$GB" apply "$DH" >/dev/null 2>&1
check "ordinary apply repairs missing renewal hook" "755" "$(stat -c %a "$HOOK")"

echo "-- activation failure after the certificate returns to staged --"
D7=seventh.example.test
"$GB" deploy static --domain "$D7" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
mkdir -p "$SB/srv/getbible/$D7/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D7/v1"
: > "$CERTBOT_LOG"
echo "# hand edit" >> "$SB/etc/nginx/sites-available/$D7.conf"
check "hand edits stop go-live early" "were kept; nothing was applied" "$("$GB" go-live "$D7" --cert http 2>&1 || true)"
check "no certificate for kept edits" "0"                       "$(certonly_runs)"
sed -i '/^# hand edit$/d' "$SB/etc/nginx/sites-available/$D7.conf"
check "activation failure reported" "staged again"              "$(CERTBOT_TAMPER="$SB/etc/nginx/sites-available/$D7.conf" "$GB" go-live "$D7" --cert http 2>&1 || true)"
check "certificate was issued"    "1"                           "$(certonly_runs)"
check "certificate kept"          "certificate"                 "$(cat "$SB/etc/letsencrypt/live/$D7/fullchain.pem")"
check "back to staged"            "LIVE=false"                  "$(conf "$D7")"
check "placeholder kept on failure" "present"                   "$(placeholder "$D7")"
check "no live_at"                ""                            "$(grep '^LIVE_AT=.' "$SB/var/lib/getbible/state/$D7/state.conf" || true)"
check "hand edit kept"            "# hand edit"                 "$(site "$D7")"

echo "-- an unreachable name is refused before certbot --"
D11=eleventh.example.test
"$GB" deploy static --domain "$D11" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
mkdir -p "$SB/srv/getbible/$D11/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D11/v1"
: > "$CERTBOT_LOG"
check "unreachable name refused"  "does not seem to reach this server" "$(GB_FAKE_HTTP_PROBE=1 "$GB" go-live "$D11" 2>&1 || true)"
check "no certbot for unreachable" "0"                          "$(certonly_runs)"
check "eleventh still staged"     "LIVE=false"                  "$(conf "$D11")"
check "explicit http tries anyway" "trying HTTP-01 anyway"       "$(GB_FAKE_HTTP_PROBE=1 "$GB" go-live "$D11" --cert http 2>&1 || true)"
check "explicit http went live"   "LIVE=true"                   "$(conf "$D11")"

echo "-- go-live of a Cloudflare-managed endpoint --"
export GB_PYTHON="$SB/bin/python-cf"
D8=eighth.example.test
"$GB" deploy static --domain "$D8" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
mkdir -p "$SB/srv/getbible/$D8/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D8/v1"
"$GB" cloudflare mode "$D8" proxied >/dev/null 2>&1 || true
check "staged mode change is local" ""                          "$(cat "$CF_LOG")"
: > "$CERTBOT_LOG"
check "origin files fetch failure aborts" "address ranges or origin CA could not be fetched" "$(CF_FAIL=ips "$GB" go-live "$D8" --cert dns-cloudflare 2>&1 || true)"
check "eighth back to staged"     "LIVE=false"                  "$(conf "$D8")"
check "no dns change on abort"    ""                            "$(grep -c '^dns ' "$CF_LOG" | sed 's/^0$//')"
: > "$CF_LOG"
RULES_STATUS=0
CF_FAIL=host-rules "$GB" go-live "$D8" > "$SB/rules-failure.out" 2>&1 || RULES_STATUS=$?
OUT="$(cat "$SB/rules-failure.out")"
check "rules failure makes go-live unsuccessful" "1" "$RULES_STATUS"
check "rules failure retains pending verification" "GOLIVE_VERIFICATION=pending" "$(cat "$SB/var/lib/getbible/state/$D8/state.conf")"
check "eighth is live"            "LIVE=true"                   "$(conf "$D8")"
check "ranges fetched first"      "ips"                         "$(head -1 "$CF_LOG")"
check "dns switched to address"   "dns $D8 --proxied true --ipv4 203.0.113.10" "$(cat "$CF_LOG")"
check "dns switch recorded"       "CLOUDFLARE_DNS_AT="          "$(cat "$SB/var/lib/getbible/state/$D8/state.conf")"
check "rules failure reported"    "DNS now points here, but the rules" "$OUT"
check "live vhost has real-ip"    "cloudflare-real-ip.conf"     "$(site "$D8")"
check "real-ip file rendered"     "set_real_ip_from 203.0.113.0/24;" "$(cat "$SB/etc/nginx/getbible/cloudflare-real-ip.conf")"
D9=ninth.example.test
"$GB" deploy static --domain "$D9" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
mkdir -p "$SB/srv/getbible/$D9/releases/v1/stamp" && ln -sfn "releases/v1/stamp" "$SB/srv/getbible/$D9/v1"
"$GB" cloudflare mode "$D9" dns >/dev/null 2>&1 || true
: > "$CF_LOG"
OUT="$("$GB" go-live "$D9" 2>&1 || true)"
check "ninth is live"             "LIVE=true"                   "$(conf "$D9")"
check "grey-cloud dns switched"   "dns $D9 --proxied false --ipv4 203.0.113.10" "$(cat "$CF_LOG")"
check "dns success reported"      "Cloudflare DNS now points here." "$OUT"
check "telegram carries verify"   "Verification passed"         "$OUT"
unset GB_PYTHON

echo "-- verify counts every failure --"
D10=tenth.example.test
"$GB" deploy static --domain "$D10" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
rm -f "$SB/etc/nginx/sites-available/$D10.conf" "$SB/etc/nginx/sites-enabled/$D10.conf"
check "two failures counted"      "2 check(s) failed"           "$("$GB" verify "$D10" 2>&1 || true)"
check "verify exit status"        "1"                           "$("$GB" verify "$D10" >/dev/null 2>&1; echo $?)"

echo "-- file types of a static endpoint --"
"$GB" filetypes "$D" json,txt >/dev/null 2>&1
check "file types recorded"       "EXTENSIONS=json,txt"         "$(conf "$D")"
check "file types rendered"       '\.(json|txt)$'               "$(site "$D")"
check "sha location dropped"      ""                            "$(grep -c '\.sha' "$SB/etc/nginx/sites-available/$D.conf" | sed 's/^0$//')"
check "sync unit follows"         "GB_SYNC_EXTENSIONS=json,txt" "$(cat "$SB/etc/systemd/system/getbible-sync-staged_example_test-v2.service")"
check "bad file type rejected"    "Invalid file extension"      "$("$GB" filetypes "$D" 'json,../x' 2>&1 || true)"
"$GB" filetypes "$D" json,sha,txt >/dev/null 2>&1

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

echo "-- plugin detection consumes all output under pipefail --"
(
    # More than a pipe buffer makes early-reader exit deterministic.
    certs_plugins() { printf '* dns-cloudflare\n%65536s\n' ""; }
    status=0
    certs_dns_cloudflare_installed || status=$?
    printf 'available_exit=%s\n' "$status"
    certs_plugins() { printf '* webroot\n'; }
    status=0
    certs_dns_cloudflare_installed || status=$?
    printf 'absent_exit=%s\n' "$status"
    certs_plugins() { printf '* dns-cloudflare\n'; return 1; }
    status=0
    certs_dns_cloudflare_installed || status=$?
    printf 'failed_query_exit=%s\n' "$status"
) > "$SB/plugin-detection.out" 2>&1
check "large plugin list does not cause a false negative" "available_exit=0" "$(cat "$SB/plugin-detection.out")"
check "missing DNS plugin remains unavailable" "absent_exit=1" "$(cat "$SB/plugin-detection.out")"
check "failed plugin query remains unavailable" "failed_query_exit=1" "$(cat "$SB/plugin-detection.out")"
# shellcheck source=../../src/lib/ui.sh
source "$ROOT/src/lib/ui.sh"
# shellcheck source=../../src/lib/nginx.sh
source "$ROOT/src/lib/nginx.sh"
check "captured: no overwrite dialog" "refusing to overwrite it without a dialog" "$(GB_YES=false GB_UI=whiptail GB_UI_CAPTURED=true nginx_confirm_overwrite /x/target /x/candidate 2>&1 || true)"

echo "-- token rotation reports broken renewal credentials --"
# shellcheck disable=SC2030
(
    # shellcheck source=../../src/lib/cloudflare.sh
    source "$ROOT/src/lib/cloudflare.sh"
    GB_CLOUDFLARE_CONF="$SB/token-rotation.conf"
    ui_password() { printf 'rotated-fixture-token\n'; }
    ui_msg() { printf '%s\n' "$2"; }
    tg_notify() { :; }
    certs_cloudflare_credentials_write() { return 1; }
    cf_human() { printf 'verification reached\n' > "$SB/token-rotation-verified"; }
    status=0
    cloudflare_configure || status=$?
    printf 'rotation_exit=%s\n' "$status"
) > "$SB/token-rotation.out" 2>&1
check "token rotation propagates renewal credential failure" "rotation_exit=1" "$(cat "$SB/token-rotation.out")"
check "token rotation failure offers recovery" "save the token again before certificate renewal" "$(cat "$SB/token-rotation.out")"
check "incomplete credentials never report verified" "" "$(cat "$SB/token-rotation-verified" 2>/dev/null || true)"
check "captured: refuses"         "1"                           "$(GB_YES=false GB_UI=whiptail GB_UI_CAPTURED=true nginx_confirm_overwrite /x/target /x/candidate >/dev/null 2>&1; echo $?)"
check "confirmed edits pass"      "0"                           "$(GB_OVERWRITE_HAND_EDITS=true nginx_confirm_overwrite /x/target /x/candidate >/dev/null 2>&1; echo $?)"
check "captured: no email prompt" "No Let's Encrypt contact email is set" "$(GB_UI_CAPTURED=true GB_GLOBAL_CONF=/nonexistent certs_email 2>&1 || true)"
check "stand-in outside sandbox ignored" "no"                   "$(GB_CERTBOT=/usr/bin/true certs_can_run && echo yes || echo no)"
check "stand-in inside sandbox runs" "yes"                      "$(GB_CERTBOT="$SB/bin/certbot" certs_can_run && echo yes || echo no)"

echo "-- failed verification never reports successful go-live --"
# Overrides are deliberately local to this isolated regression fixture.
# shellcheck disable=SC2030
(
    # shellcheck source=../../src/lib/golive.sh
    source "$ROOT/src/lib/golive.sh"
    fixture_live=false
    GB_DRY_RUN=false
    GOLIVE_PREFLIGHT_DONE=true
    ep_exists() { return 0; }
    ep_is_live() { [[ "$fixture_live" == true ]]; }
    ep_set() { [[ "$2" != LIVE ]] || fixture_live="$3"; }
    ep_state_get() { :; }
    ep_state_set() { printf 'state %s=%s\n' "$2" "$3"; }
    nginx_cert_exists() { return 0; }
    certs_method() { printf 'http\n'; }
    certs_obtain() { return 0; }
    endpoint_apply() { [[ "$GOLIVE_CHECK_ORIGIN" == true ]]; }
    golive_cloudflare_managed() { return 1; }
    golive_verify() { printf 'verification failed\n'; return 1; }
    tg_notify() { printf 'notification %s: %s\n' "$1" "$2"; }
    status=0
    golive_run pending.example.test || status=$?
    printf 'exit=%s live=%s\n' "$status" "$fixture_live"
    status=0
    golive_run pending.example.test || status=$?
    printf 'retry_exit=%s\n' "$status"
) > "$SB/golive-failed.out" 2>&1
OUT="$(cat "$SB/golive-failed.out")"
check "failed verify returns nonzero and preserves active service" "exit=1 live=true" "$OUT"
check "failure notification is pending" "notification warn: Go-live verification pending" "$OUT"
check "failure never sends success notification" "" "$(grep '^notification ok:' "$SB/golive-failed.out" || true)"
check "pending state recorded" "state GOLIVE_VERIFICATION=pending" "$OUT"
check "already live retry actually verifies" "retry_exit=1" "$OUT"

echo "-- live TLS cannot fall back to an untrusted certificate --"
: > "$SB/golive-test-site"
# Overrides are deliberately local to this isolated regression fixture.
# shellcheck disable=SC2030
(
    # shellcheck source=../../src/lib/golive.sh
    source "$ROOT/src/lib/golive.sh"
    GB_PREFIX=""
    GB_NGINX_BIN=true
    fixture_source=letsencrypt
    ep_load() { EP_TYPE=static; EP_ACCESS_MODE=open; }
    endpoint_source_type() { :; }
    endpoint_publication_text() { printf 'fixture\n'; }
    tokens_count() { printf '0\n'; }
    ep_versions() { :; }
    nginx_site_file() { printf '%s\n' "$SB/golive-test-site"; }
    nginx_enabled_file() { printf '%s\n' "$SB/golive-test-site"; }
    nginx_detect() { NG_AVAILABLE=true; }
    certs_source() { printf '%s\n' "$fixture_source"; }
    certs_status_line() { printf 'fixture certificate\n'; }
    ep_is_live() { [[ "$fixture_source" == letsencrypt ]]; }
    golive_probe() {
        printf '%s\n' "$3" >> "$SB/probe-trust.log"
        if [[ "$3" == true ]]; then printf '200'; else printf '000'; fi
    }
    status=0
    golive_verify tls.example.test local || status=$?
    printf 'live_tls_exit=%s\n' "$status"
    fixture_source=placeholder
    status=0
    golive_verify tls.example.test local || status=$?
    printf 'staged_tls_exit=%s\n' "$status"
) > "$SB/golive-tls.out" 2>&1
OUT="$(cat "$SB/golive-tls.out")"
check "untrusted live certificate fails verification" "live_tls_exit=1" "$OUT"
check "staged placeholder remains testable" "staged_tls_exit=0" "$OUT"
check "live requests never retry insecurely" $'false\nfalse\ntrue\ntrue' "$(cat "$SB/probe-trust.log")"

echo "-- local TLS waits for reloaded nginx within one deadline --"
# Overrides are deliberately local to this isolated regression fixture.
# shellcheck disable=SC2030
(
    # shellcheck source=../../src/lib/golive.sh
    source "$ROOT/src/lib/golive.sh"
    # The clock advances only between attempts: no network or real sleeps.
    SECONDS=0
    sleep() { SECONDS=$((SECONDS + $1)); }
    : > "$SB/local-probe-attempts"
    curl() {
        local timeout="" insecure=false
        while (($#)); do
            case "$1" in
                --max-time) timeout="$2"; shift ;;
                --insecure) insecure=true ;;
            esac
            shift
        done
        printf '%s %s\n' "$timeout" "$insecure" >> "$SB/local-probe-attempts"
        if [[ "$(wc -l < "$SB/local-probe-attempts")" -lt 3 ]]; then
            printf '000'; return 60
        fi
        printf '200'
    }
    golive_probe tls.example.test /readyz false > "$SB/local-probe-status"
    printf 'delayed_status=%s elapsed=%s attempts=%s;\n' "$(cat "$SB/local-probe-status")" "$SECONDS" "$(wc -l < "$SB/local-probe-attempts")"
    printf 'delayed_limits=%s\n' "$(cut -d' ' -f1 "$SB/local-probe-attempts" | tr '\n' ',')"
    printf 'insecure_attempts=%s\n' "$(grep -c ' true$' "$SB/local-probe-attempts" || true)"

    SECONDS=0
    : > "$SB/local-probe-attempts"
    curl() {
        { printf '%q ' "$@"; printf '\n'; } >> "$SB/local-probe-attempts"
        printf '000'; return 60
    }
    golive_probe invalid-tls.example.test /readyz false > "$SB/local-probe-status"
    printf 'permanent_status=%s elapsed=%s attempts=%s;\n' "$(cat "$SB/local-probe-status")" "$SECONDS" "$(wc -l < "$SB/local-probe-attempts")"
    printf 'last_attempt=%s\n' "$(tail -1 "$SB/local-probe-attempts")"
    printf 'insecure_attempts=%s\n' "$(grep -c -- --insecure "$SB/local-probe-attempts" || true)"

    SECONDS=0
    curl() { printf '404'; }
    golive_probe missing.example.test /readyz false > "$SB/local-probe-status"
    printf 'http_status=%s elapsed=%s\n' "$(cat "$SB/local-probe-status")" "$SECONDS"
) > "$SB/golive-local-retry.out" 2>&1
OUT="$(cat "$SB/golive-local-retry.out")"
check "local TLS succeeds after nginx finishes reloading" "delayed_status=200 elapsed=2 attempts=3;" "$OUT"
check "each connection uses the remaining deadline" "delayed_limits=10,9,8," "$OUT"
check "permanent TLS failure stops at the deadline" "permanent_status=000 elapsed=10 attempts=10;" "$OUT"
check "last connection cannot exceed the remaining second" "--max-time 1 --write-out" "$OUT"
check "local retries keep full TLS validation" "" "$(grep -E '^insecure_attempts=[1-9]' "$SB/golive-local-retry.out" || true)"
check "an actual HTTP failure is reported immediately" "http_status=404 elapsed=0" "$OUT"

echo "-- public propagation waits, then verifies HTTPS --"
# Overrides are deliberately local to this isolated regression fixture.
# shellcheck disable=SC2030
(
    # shellcheck source=../../src/lib/golive.sh
    source "$ROOT/src/lib/golive.sh"
    GB_PREFIX=""
    GB_VERIFY_PUBLIC=true
    GOLIVE_VERIFY_TIMEOUT=6
    GOLIVE_VERIFY_INTERVAL=1
    probe_count=0
    # Deterministic time and requests: no real DNS, network or sleeps.
    SECONDS=0
    sleep() { SECONDS=$((SECONDS + $1)); }
    certs_http_probe() { probe_count=$((probe_count + 1)); (( probe_count >= 2 )); }
    curl() { printf '200'; }
    status=0
    golive_wait_public propagation.example.test || status=$?
    printf 'propagation_exit=%s attempts=%s\n' "$status" "$probe_count"

    GOLIVE_VERIFY_TIMEOUT=3
    certs_http_probe() { return 1; }
    status=0
    golive_wait_public wrong-origin.example.test || status=$?
    printf 'wrong_origin_exit=%s\n' "$status"

    certs_http_probe() { return 0; }
    curl() { printf '000'; }
    status=0
    golive_wait_public invalid-tls.example.test || status=$?
    printf 'public_tls_exit=%s\n' "$status"
) > "$SB/golive-propagation.out" 2>&1
OUT="$(cat "$SB/golive-propagation.out")"
check "propagation is retried successfully" "propagation_exit=0 attempts=2" "$OUT"
check "waiting is visible to the operator" "retry in 1s" "$OUT"
check "wrong origin cannot satisfy server identity" "wrong_origin_exit=1" "$OUT"
check "public TLS failure stays unsuccessful" "public_tls_exit=1" "$OUT"
check "timeout provides a retry command" "getbible.sh verify wrong-origin.example.test" "$OUT"

echo "-- nginx -t on a staged vhost --"
if command -v nginx >/dev/null; then
    unset GB_NGINX_FAKE_VERSION
    # This isolated config does not load optional distro modules.
    export GB_NGINX_FAKE_BROTLI=false
    export GB_NGINX_FAKE_IPV6=false
    D6=sixth.example.test
    "$GB" deploy static --domain "$D6" --version v2 --repo git@github.com:getbible/v2_scripture.git --staged >/dev/null 2>&1
    mkdir -p "$SB/etc/nginx/logs" "$SB/var/cache/nginx/getbible"
    sed -i -e 's/listen 80;/listen 127.0.0.1:18280;/' -e 's/listen 443 ssl\(.*\);/listen 127.0.0.1:18643 ssl\1;/' "$SB/etc/nginx/sites-available/$D6.conf"
    find "$SB/etc/nginx/sites-enabled" -name '*.conf' ! -name "$D6.conf" -delete
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
