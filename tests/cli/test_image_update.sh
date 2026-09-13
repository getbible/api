#!/usr/bin/env bash
# A replacement image is applied once; failed/interrupted work remains retryable.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GETBIBLE_EXECUTION_MODE=docker
for lib in core config registry update; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/image" "$GB_LOG"
GB_REPO_DIR="$TEST_ROOT/image"
printf '1.0.0\n' > "$GB_REPO_DIR/VERSION"
ep_create query.example.test runtime query
ep_create api.example.test static static
ep_create disabled.example.test runtime search
ep_set disabled.example.test ENABLED false
calls="$TEST_ROOT/calls"
: > "$calls"
fail_runtime=false
fail_infrastructure=false
gb_system_init() { printf 'init\n' >> "$calls"; }
infrastructure_update() { printf 'infrastructure\n' >> "$calls"; [[ "$fail_infrastructure" == false ]]; }
endpoint_source_type() { :; }
rt_image_update() {
    [[ "$GB_LOCAL_APPLY" == true ]]
    printf 'runtime %s\n' "$1" >> "$calls"
    [[ "$fail_runtime" == false ]]
}
endpoint_apply() { [[ "$GB_LOCAL_APPLY" == true ]]; printf 'static %s\n' "$1" >> "$calls"; }
tg_notify() { :; }
sd_available() { return 1; }

update_image
[[ "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 1.0.0 ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == current ]]
grep -qx 'runtime query.example.test' "$calls"
grep -qx 'static api.example.test' "$calls"
if grep -q disabled "$calls"; then echo 'Disabled domain was updated' >&2; exit 1; fi
before="$(cat "$calls")"
update_image
[[ "$(cat "$calls")" == "$before" ]]

printf '2.0.0\n' > "$GB_REPO_DIR/VERSION"
fail_runtime=true
: > "$calls"
if update_image; then echo 'Incomplete update recorded as successful' >&2; exit 1; fi
[[ "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 1.0.0 ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == failed ]]
grep -qx 'static api.example.test' "$calls"
fail_runtime=false
update_image
[[ "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == 2.0.0 ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == current ]]
[[ -z "$(cfg_get "$(update_image_state)" LAST_ERROR)" ]]

# Interrupted attempts and explicit operator retries perform reconciliation.
cfg_set "$(update_image_state)" STATUS updating
: > "$calls"
update_image
[[ -s "$calls" ]]
: > "$calls"
update_image --force
[[ -s "$calls" ]]
fail_infrastructure=true
: > "$calls"
if update_image --force; then echo 'Management failure was hidden' >&2; exit 1; fi
[[ "$(cfg_get "$(update_image_state)" STATUS)" == failed ]]
if grep -Eq '^(runtime|static) ' "$calls"; then echo 'Endpoints changed after essential installation failure' >&2; exit 1; fi
fail_infrastructure=false

before="$(cat "$(update_image_state)")"
: > "$calls"
GB_DRY_RUN=true update_image --force
[[ ! -s "$calls" && "$(cat "$(update_image_state)")" == "$before" ]]
[[ -z "${GB_LOCAL_APPLY:-}" ]]
status_text="$(update_image_status)"
[[ "$status_text" == *'applied: 2.0.0; update: failed'* ]]
printf 'Image release reconciliation checks passed\n'
