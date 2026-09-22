#!/usr/bin/env bash
# Exercise the real selection/journal controller with deterministic targets.
# shellcheck disable=SC2329 # Deliberate driver substitutions called indirectly.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GB_PYTHON="${GB_PYTHON:-python3}" GETBIBLE_EXECUTION_MODE=docker
for lib in core config deployment registry update; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$GB_LOG" "$TEST_ROOT/targets"
calls="$TEST_ROOT/calls"
: > "$calls"
tg_notify() { :; }
IDS=(management runtime/query.example.test/v2 runtime/query.example.test/v3 mcp/mcp.example.test static/api.example.test)
FAIL=''; CHANGE_DURING_APPLY=''; BLOCK=''
for id in "${IDS[@]}"; do printf 'old\n' > "$TEST_ROOT/targets/${id//\//_}"; done
# Independent desired and serving values let failures retain known-good workers.
DESIRED=a
upgrade_describe() {
    local id="$1" kind domain label generation
    local -a flags=()
    kind="${id%%/*}"; domain="${id#*/}"; domain="${domain%%/*}"; label="${id##*/}"
    [[ "$kind" != management ]] || domain=''
    [[ "$kind" == runtime ]] || label=''
    generation="$(cat "$TEST_ROOT/targets/${id//\//_}")"
    [[ "$generation" != "$DESIRED" ]] || flags+=(--matches)
    [[ "$id" != "$BLOCK" ]] || flags+=(--error 'Required offline bundle is absent')
    upgrade_helper row --target "$id" --kind "$kind" --domain "$domain" --label "$label" \
        --fingerprint "$(printf '%064d' 0 | tr 0 "$DESIRED")" --generation "$generation" --serving ready "${flags[@]}"
}
upgrade_inventory() { local id; for id in "${IDS[@]}"; do upgrade_describe "$id"; done; }
upgrade_apply_target() {
    local id="$1"
    printf '%s force=%s\n' "$id" "$2" >> "$calls"
    [[ "$id" != "$FAIL" ]] || return 1
    printf '%s\n' "$DESIRED" > "$TEST_ROOT/targets/${id//\//_}"
    [[ "$id" != "$CHANGE_DURING_APPLY" ]] || DESIRED=c
    return 0
}
# Read-only planning does not initialize global settings or any upgrade journal.
upgrade_cli --plan --json > "$TEST_ROOT/plan.json"
[[ ! -e "$GB_STATE/upgrades.json" && ! -e "$GB_GLOBAL_CONF" && ! -s "$calls" ]]
upgrade_cli --targets '' --json > "$TEST_ROOT/empty.json"
[[ ! -e "$GB_STATE/upgrades.json" && ! -e "$(update_image_state)" && ! -s "$calls" ]]
if upgrade_cli --target invalid.example.test --json > /dev/null 2>&1; then exit 1; fi
[[ ! -s "$calls" && ! -e "$GB_STATE/upgrades.json" ]]
# A selected endpoint does not apply the dashboard, its sibling, MCP or static.
upgrade_cli --target runtime/query.example.test/v2 --json > "$TEST_ROOT/selected.json"
[[ "$(cat "$calls")" == 'runtime/query.example.test/v2 force=false' ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == partial ]]
[[ -z "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" ]]
"$GB_PYTHON" - "$TEST_ROOT/selected.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['pending'] == 4, plan
assert next(r for r in plan['targets'] if r['id'].endswith('/v2'))['status'] == 'current'
PY
# Every remaining changed target applies once, then all-mode is a true service no-op.
upgrade_cli --all --json > "$TEST_ROOT/all.json"
[[ "$(cfg_get "$(update_image_state)" STATUS)" == current ]]
[[ "$(cfg_get "$(update_image_state)" APPLIED_VERSION)" == "$(cat "$ROOT/VERSION")" ]]
[[ "$(wc -l < "$calls")" == 5 ]]
update_image --force >/dev/null
[[ "$(wc -l < "$calls")" == 5 ]]
# Force is explicit for CLI callers; only the named target is redeployed.
upgrade_cli --target mcp/mcp.example.test --force --json > /dev/null
[[ "$(tail -1 "$calls")" == 'mcp/mcp.example.test force=true' ]]
[[ "$(wc -l < "$calls")" == 6 ]]
# Plans are guarded under the management lock; stale choices never apply.
plan_id="$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$TEST_ROOT/all.json")"
DESIRED=b
if upgrade_cli --target management --expected-plan "$plan_id" --json > /dev/null 2>&1; then exit 1; fi
[[ "$(wc -l < "$calls")" == 6 ]]
# A reporting target failure does not block independent public API targets.
FAIL=management
if upgrade_cli --all --json > "$TEST_ROOT/failed.json"; then exit 1; fi
[[ "$(wc -l < "$calls")" == 11 ]]
[[ "$(cfg_get "$(update_image_state)" STATUS)" == failed ]]
"$GB_PYTHON" - "$TEST_ROOT/failed.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p['pending'] == 1 and p['targets'][0]['outcome'] == 'failed', p
assert all(r['serving'] == 'ready' for r in p['targets']), p
PY
FAIL=''
upgrade_cli --retry --json >/dev/null
[[ "$(wc -l < "$calls")" == 12 && "$(tail -1 "$calls")" == 'management force=false' ]]
# Preparation errors remain pending rather than yielding a false global success.
BLOCK=static/api.example.test
if upgrade_cli --all --json > /dev/null; then exit 1; fi
[[ "$(cfg_get "$(update_image_state)" STATUS)" == partial && "$(wc -l < "$calls")" == 12 ]]
BLOCK=''
# Dry runs and an empty explicit subset leave both journal and service state untouched.
before="$(sha256sum "$GB_STATE/upgrades.json" "$(update_image_state)")"
GB_DRY_RUN=true upgrade_cli --all --force --json > /dev/null
upgrade_cli --targets '' --json >/dev/null
[[ "$before" == "$(sha256sum "$GB_STATE/upgrades.json" "$(update_image_state)")" && "$(wc -l < "$calls")" == 12 ]]
# Code/configuration changing during the operation is not silently blessed.
CHANGE_DURING_APPLY=management
if upgrade_cli --target management --force --json > "$TEST_ROOT/raced.json"; then exit 1; fi
[[ "$(cfg_get "$(update_image_state)" STATUS)" == failed ]]
printf 'Selective upgrade, no-op, retry, partial-state and fault checks passed\n'
