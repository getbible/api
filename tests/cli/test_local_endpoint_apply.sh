#!/usr/bin/env bash
# Exercise the real static preparation and shared apply pipeline with external
# services denied: an image applies local code without fetching authoritative data.
# shellcheck disable=SC2317,SC2329 # Test doubles are called by sourced functions.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
export GB_PREFIX="$SB" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry users systemd python pages sync endpoint; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/static/type.sh
source "$ROOT/src/types/static/type.sh"
trap 'gb_cleanup; rm -rf -- "$SB"' EXIT
mkdir -p "$GB_LOG"
domain=static.example.test
ep_create "$domain" static static
ep_version_create "$domain" v2 git@example.test:bible.git main .
ep_set "$domain" CLOUDFLARE_MODE proxied
ep_set "$domain" LIVE true
GB_CLOUDFLARE_LOADED=1
published="$(ep_data_dir "$domain")/releases/v2/source"
mkdir -p "$published"
printf 'authoritative source bytes\n' > "$published/scripture.json"
ln -s releases/v2/source "$(ep_version_path "$domain" v2)"
source_bytes="$(cat "$published/scripture.json")"
source_target="$(readlink "$(ep_version_path "$domain" v2)")"
route="$SB/served-route"
printf 'original route\n' > "$route"
events="$SB/events"
: > "$events"
TLS_OWNER=external
CERT_PRESENT=false
FAIL_RELOAD=false
record() { printf '%s\n' "$*" >> "$events"; }
remote_forbidden() { record "FORBIDDEN $*"; return 99; }
tg_notify() { :; }
tg_install_helper() { :; }
sync_pin_host() { remote_forbidden ssh; }
cloudflare_protect_access() { remote_forbidden edge-protect; }
cloudflare_ensure_origin_files() { remote_forbidden edge-download; }
cloudflare_apply() { remote_forbidden edge-apply; }
certs_obtain() { remote_forbidden certificate; }
certs_install_hook() { record certificate-hook; }
certs_placeholder_ensure() { record placeholder; }
certs_placeholder_remove() { record remove-placeholder; }
logs_ensure_endpoint_dir() { :; }
nginx_validate_proxy_settings() { :; }
nginx_external_tls() { [[ "$TLS_OWNER" == external ]]; }
nginx_cert_exists() { [[ "$CERT_PRESENT" == true ]]; }
nginx_enabled_file() { printf '%s\n' "$route"; }
nginx_transaction_begin() { record begin; cp -- "$route" "$SB/route-backup"; }
nginx_transaction_commit() { record commit; }
nginx_transaction_rollback() { record rollback; cp -- "$SB/route-backup" "$route"; }
nginx_render_global() { mkdir -p "$1"; }
nginx_render_endpoint() { printf 'updated local route\n' > "$1/route"; }
nginx_enable_site() { record enable-route; }
nginx_apply_stage() {
    record reload
    [[ "$FAIL_RELOAD" != true ]] || return 1
    cp -- "$1/route" "$route"
}
pages_publish() { record pages; }
sd_daemon_reload() { record daemon-reload; }
sd_enable() { local IFS=' '; record "enable $*"; }
sd_disable_now() { local IFS=' '; record "disable $*"; }

GB_LOCAL_APPLY=true endpoint_apply "$domain"
grep -qFx 'updated local route' "$route"
grep -qFx "enable $(sync_unit "$domain" v2).timer" "$events"
if grep -Eq 'FORBIDDEN|enable --now' "$events"; then
    echo 'Local image application initiated an external operation' >&2; exit 1
fi
[[ "$(cat "$published/scripture.json")" == "$source_bytes" ]]
[[ "$(readlink "$(ep_version_path "$domain" v2)")" == "$source_target" ]]
[[ "$(ep_get "$domain" LIVE)" == true ]]

# A missing saved managed certificate cannot downgrade a live site's routing.
TLS_OWNER=managed
: > "$events"
before="$(cat "$route")"
if GB_LOCAL_APPLY=true endpoint_apply "$domain"; then
    echo 'Missing saved certificate was accepted for local apply' >&2; exit 1
fi
[[ ! -s "$events" && "$(cat "$route")" == "$before" ]]

# Staged configuration remains staged; nginx rejection restores the old route.
TLS_OWNER=external
ep_set "$domain" LIVE false
GB_LOCAL_APPLY=true endpoint_apply "$domain"
[[ "$(ep_get "$domain" LIVE)" == false ]]
FAIL_RELOAD=true
if GB_LOCAL_APPLY=true endpoint_apply "$domain"; then
    echo 'Failed local nginx transaction was accepted' >&2; exit 1
fi
grep -qFx rollback "$events"
[[ "$(cat "$route")" == "$before" ]]
[[ "$(cat "$published/scripture.json")" == "$source_bytes" ]]
[[ "$(readlink "$(ep_version_path "$domain" v2)")" == "$source_target" ]]
if grep -Eq 'FORBIDDEN|enable --now' "$events"; then exit 1; fi
# Normal operator application still starts the configured synchronization timer.
: > "$events"
sync_install_version "$domain" v2
grep -qFx "enable --now $(sync_unit "$domain" v2).timer" "$events"
printf 'Local endpoint application checks passed\n'
