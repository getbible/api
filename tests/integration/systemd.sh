#!/usr/bin/env bash
# Production deployment acceptance test. This changes real /etc, /opt, /srv
# and systemd state and may run ONLY on a fresh disposable Linux VM.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "${GB_CI_DISPOSABLE_HOST:-}" == 1 && "$(id -u)" == 0 && -d /run/systemd/system ]] || {
    echo 'Requires root, systemd, and GB_CI_DISPOSABLE_HOST=1 on a disposable VM.' >&2
    exit 1
}
[[ ! -d /etc/getbible/endpoints && ! -d /opt/getbible/query && ! -d /opt/getbible/search && ! -e /srv/getbible-ci ]] || {
    echo 'Refusing to run on a host with an existing getBible deployment.' >&2
    exit 1
}
unset GB_PREFIX GB_SYSTEMCTL GB_NGINX_BIN GB_NGINX_FAKE_VERSION GB_NGINX_FAKE_IPV6
export GB_YES=true GB_UI=none NO_PROXY='*' no_proxy='*' GB_VERIFY_PUBLIC=false
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
GB="$ROOT/getbible.sh"
Q=query.ci.example.test
S=search.ci.example.test
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
        for diagnostic in /var/log/nginx/error.log /var/log/getbible/*/error.log /var/log/getbible/*/app/app.log; do
            [[ -f "$diagnostic" ]] || continue
            printf '\nFailure diagnostic: %s\n' "$diagnostic"
            tail -80 "$diagnostic" || true
        done
        [[ ! -f "$PROBE_LOG" ]] || tail -30 "$PROBE_LOG"
    fi
    "$GB" remove "$Q" --purge >/dev/null 2>&1 || true
    "$GB" remove "$S" --purge >/dev/null 2>&1 || true
    rm -rf /srv/getbible-ci "/etc/getbible/placeholder-certs/$S"
    exit "$result"
}
trap cleanup EXIT

request() {
    local domain="$1" path="$2"
    curl --fail-with-body --silent --show-error --insecure --noproxy '*' --max-time 10 \
        --resolve "$domain:443:127.0.0.1" "https://$domain$path"
}

deployment() { readlink -f "/opt/getbible/$1/active"; }
unit() { printf 'getbible-%s-%s.service\n' "$1" "$(basename "$(deployment "$1")")"; }
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
        -out "/etc/letsencrypt/live/$1/fullchain.pem" -subj "/CN=$1" 2>/dev/null
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
            --require-checksums false --default-translation test --default-reference Ge1:1 --warm test --access open
    else
        "$GB" deploy runtime --domain "$domain" --kind "$kind" --repository /srv/getbible-ci/repository \
            --require-checksums false --default-translation test --default-reference Ge1:1 --warm test --access open --staged
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
    check "$kind code is read-only to its account" no "$(runuser -u "getbible-$kind" -- test -w "/opt/getbible/$kind/current" && echo yes || echo no)"
    check "$kind cannot read token configuration" no "$(runuser -u "getbible-$kind" -- test -r /etc/getbible/getbible.conf && echo yes || echo no)"
    release="$(readlink -f "/opt/getbible/$kind/current")"
    base_python="$("$release/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
    [[ "$base_python" == /opt/getbible/* ]] || { echo "Runtime depends on host Python: $base_python" >&2; exit 1; }
    check "$kind pinned dependencies consistent" 'No broken requirements found.' "$("$release/.venv/bin/python" -m pip check)"
done
request "$Q" /v2/test/Ge1:1 | /usr/bin/python3 -c 'import json,sys; assert "test_1_1" in json.load(sys.stdin)'
request "$S" /v2/test/beginning | /usr/bin/python3 -c 'import json,sys; payload=json.load(sys.stdin); assert payload["query"]["kind"] == "search", payload'

NGINX_PID="$(systemctl show --property=MainPID --value nginx)"
OLD_DEPLOYMENT="$(deployment query)"
OLD_PID="$(main_pid query)"
OLD_RELEASE="$(readlink -f /opt/getbible/query/current)"

"$GB" apply "$Q"
check 'idempotent apply preserves process' "$OLD_PID" "$(main_pid query)"
check 'idempotent apply preserves deployment' "$OLD_DEPLOYMENT" "$(deployment query)"

start_probe
"$GB" runtime "$Q" set DEFAULT_REFERENCE Ge1:2
stop_probe
NEW_DEPLOYMENT="$(deployment query)"
[[ "$NEW_DEPLOYMENT" != "$OLD_DEPLOYMENT" ]] || { echo 'Configuration update reused the active generation.' >&2; exit 1; }
check 'configuration update reuses immutable code' "$OLD_RELEASE" "$(readlink -f /opt/getbible/query/current)"
check 'old configuration retained for rollback' Ge1:1 "$(env_value "$OLD_DEPLOYMENT/runtime.env" QUERY_DEFAULT_REFERENCE)"
check 'new service reads updated configuration' QUERY_DEFAULT_REFERENCE=Ge1:2 "$(tr '\0' '\n' < "/proc/$(main_pid query)/environ" | grep '^QUERY_DEFAULT_REFERENCE=')"

# A bad application preflight must never displace the healthy generation.
install -d -m 0755 /srv/getbible-ci/broken-checkout
tar --exclude=.git --exclude=.venv-test --exclude=__pycache__ --exclude=build \
    -C "$ROOT" -cf - . | tar -C /srv/getbible-ci/broken-checkout -xf -
printf 'raise RuntimeError("intentional CI candidate startup failure")\n' \
    > /srv/getbible-ci/broken-checkout/src/apps/query/getbible_query_api/check.py
ACTIVE_PID="$(main_pid query)"
start_probe
if /srv/getbible-ci/broken-checkout/getbible.sh apply "$Q"; then
    echo 'A broken candidate was accepted.' >&2
    exit 1
fi
stop_probe
check 'failed upgrade preserves active generation' "$NEW_DEPLOYMENT" "$(deployment query)"
check 'failed upgrade preserves active process' "$ACTIVE_PID" "$(main_pid query)"
check 'failed upgrade preserves active code' "$OLD_RELEASE" "$(readlink -f /opt/getbible/query/current)"
check 'failed upgrade preserves configuration' Ge1:2 "$(env_value "$(deployment query)/runtime.env" QUERY_DEFAULT_REFERENCE)"

start_probe
"$GB" runtime "$Q" rollback
stop_probe
check 'rollback restores original configuration' QUERY_DEFAULT_REFERENCE=Ge1:1 "$(tr '\0' '\n' < "/proc/$(main_pid query)/environ" | grep '^QUERY_DEFAULT_REFERENCE=')"
check 'all deployments preserve nginx master' "$NGINX_PID" "$(systemctl show --property=MainPID --value nginx)"
check 'query ready after rollback' '{"status":"ready"}' "$(request "$Q" /readyz | tr -d '\n')"
printf '\n== %d production deployment checks passed ==\n' "$PASS"
