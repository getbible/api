#!/usr/bin/env bash
# Image entry points share target planning, partial progress and no-op semantics.
# shellcheck disable=SC2329 # Upgrade callbacks are exercised indirectly.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GETBIBLE_EXECUTION_MODE=docker
for lib in core config deployment registry update; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/image" "$TEST_ROOT/generations" "$GB_LOG"
GB_REPO_DIR="$TEST_ROOT/image"
printf '1.0.0\n' > "$GB_REPO_DIR/VERSION"
ep_create query.example.test runtime query
ep_version_set query.example.test v2 ENABLED true
ep_version_set query.example.test v3 ENABLED false
ep_create api.example.test static static
ep_create mcp.example.test mcp mcp
ep_create disabled.example.test runtime search
ep_set disabled.example.test ENABLED false
calls="$TEST_ROOT/calls"; : > "$calls"
CODE=a
FAIL=''
resources_plan() { :; }
sd_available() { return 1; }
tg_notify() { :; }
upgrade_describe() {
    local id="$1" domain kind label generation='' file
    local -a flags=()
    kind="${id%%/*}"; domain="${id#*/}"; domain="${domain%%/*}"; label="${id##*/}"
    [[ "$kind" != management ]] || domain=''
    [[ "$kind" == runtime ]] || label=''
    file="$TEST_ROOT/generations/${id//\//_}"
    [[ ! -f "$file" ]] || generation="$(cat "$file")"
    [[ "$generation" != "$CODE" ]] || flags+=(--matches)
    upgrade_helper row --target "$id" --domain "$domain" --label "$label" --kind "$kind" \
        --fingerprint "$(printf '%064d' 0 | tr 0 "$CODE")" --generation "$generation" --serving ready "${flags[@]}"
}
upgrade_apply_target() {
    printf '%s\n' "$1" >> "$calls"
    [[ "$1" != "$FAIL" ]] || return 1
    printf '%s\n' "$CODE" > "$TEST_ROOT/generations/${1//\//_}"
}
update_image >/dev/null
[[ "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 1.0.0 ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == current && "$(wc -l < "$calls")" == 4 ]]
if grep -Eq 'disabled|/v3$' "$calls"; then echo 'A disabled domain or endpoint was upgraded' >&2; exit 1; fi
before="$(cat "$calls")"
update_image >/dev/null
[[ "$(cat "$calls")" == "$before" ]]
# Changing only image metadata must not restart unchanged implementation.
printf '2.0.0\n' > "$GB_REPO_DIR/VERSION"
update_image >/dev/null
[[ "$(cat "$calls")" == "$before" && "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 2.0.0 ]]
printf '3.0.0\n' > "$GB_REPO_DIR/VERSION"
CODE=b; FAIL=management; : > "$calls"
if update_image >/dev/null; then echo 'Management failure was hidden' >&2; exit 1; fi
[[ "$(cfg_get "$(update_image_state)" STATUS)" == failed && "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 2.0.0 ]]
[[ "$(wc -l < "$calls")" == 4 ]]
grep -qx 'mcp/mcp.example.test' "$calls"
grep -qx 'runtime/query.example.test/v2' "$calls"
FAIL=''; : > "$calls"
update_image >/dev/null
[[ "$(cat "$calls")" == management ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == current && "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 3.0.0 ]]
[[ -z "$(cfg_get "$(update_image_state)" LAST_ERROR)" ]]
# An interrupted global marker reconciles journalled targets, not every worker.
cfg_set "$(update_image_state)" STATUS updating
: > "$calls"
update_image --force >/dev/null
[[ ! -s "$calls" && "$(cfg_get "$(update_image_state)" STATUS)" == current ]]
before="$(sha256sum "$GB_STATE/upgrades.json" "$(update_image_state)")"
GB_DRY_RUN=true update_image --force >/dev/null
[[ ! -s "$calls" && "$before" == "$(sha256sum "$GB_STATE/upgrades.json" "$(update_image_state)")" ]]
if update_image --invalid >/dev/null 2>&1; then echo 'Invalid image option accepted' >&2; exit 1; fi
[[ -z "${GB_LOCAL_APPLY:-}" ]]
printf 'Image release selection, metadata-only no-op, disabled targets, independent failures and retries passed\n'
