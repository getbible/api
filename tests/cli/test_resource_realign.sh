#!/usr/bin/env bash
# Hardware planning stays read-only; reviewed apply uses live admission and
# reports partial work without hiding a failed generation transaction.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT"
for lib in core config registry resources; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
mkdir -p "$GB_ETC" "$GB_VAR" "$GB_PREFIX/proc/1" "$GB_PREFIX/proc/self" "$GB_PREFIX/cgroup" \
    "$GB_ENDPOINTS/query.example.test/versions" "$GB_ENDPOINTS/search.example.test/versions"
printf '0::/\n' > "$GB_PREFIX/proc/1/cgroup"
printf '10 9 0:2 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n' > "$GB_PREFIX/proc/self/mountinfo"
printf '4294967296\n' > "$GB_PREFIX/cgroup/memory.max"
printf '200000 100000\n' > "$GB_PREFIX/cgroup/cpu.max"
printf 'MemTotal: 8388608 kB\nMemAvailable: 3145728 kB\n' > "$GB_PREFIX/proc/meminfo"
printf 'MEMORY_BUDGET=auto\n' > "$GB_GLOBAL_CONF"
for kind in query search; do
    printf 'TYPE=runtime\nKIND=%s\nENABLED=true\n' "$kind" > "$GB_ENDPOINTS/$kind.example.test/endpoint.conf"
    printf 'ENABLED=true\nWORKERS=auto\n' > "$GB_ENDPOINTS/$kind.example.test/versions/v2.conf"
done
events="$GB_PREFIX/events"
: > "$events"
resources_plan() {
    local argument
    local -a extra=()
    [[ "${OWNED_BUDGET:-false}" != true ]] || extra+=(--authoritative MEMORY_BUDGET)
    for argument in "$@"; do
        if [[ "$argument" == --candidate-domain ]]; then
            printf 'admission\n' >> "$events"
            [[ "${BLOCK_ADMISSION:-false}" != true ]] || return 1
        fi
    done
    "$GB_PYTHON" "$GB_TOOLS/getbible-resources" --mode native --budget "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET auto)" \
        --proc-root "$GB_PREFIX/proc" --cgroup-root "$GB_PREFIX/cgroup" --registry "$GB_ENDPOINTS" \
        --runtime-root "$GB_OPT" --offline "${extra[@]}" "$@"
}
gb_require_root() { printf 'root\n' >> "$events"; }
gb_management_lock() { printf 'lock\n' >> "$events"; }
gb_global_set() { printf 'save %s=%s\n' "$1" "$2" >> "$events"; cfg_set "$GB_GLOBAL_CONF" "$1" "$2"; }
tg_notify() { printf 'notify %s\n' "$1" >> "$events"; }
endpoint_apply() {
    printf 'apply %s\n' "$1" >> "$events"
    [[ "$GB_RESOURCE_RECONCILING" == true ]]
    [[ "$1" != "${FAIL_DOMAIN:-}" ]]
}

resources_realign --json > "$GB_PREFIX/plan.json"
[[ ! -s "$events" ]]
[[ "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET)" == auto ]]
[[ ! -e "$GB_VAR/telemetry/traffic.sqlite3" ]]
GB_DRY_RUN=true resources_realign --apply --json > "$GB_PREFIX/dry-run.json"
[[ ! -s "$events" ]]
[[ "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET)" == auto ]]
plan_id="$("$GB_PYTHON" -c 'import json,sys; p=json.load(open(sys.argv[1])); assert p["ready"]; assert p["memory_budget"]["proposed"] == "2048M"; print(p["plan_id"])' "$GB_PREFIX/plan.json")"
printf 'THREADS=3\n' >> "$GB_ENDPOINTS/query.example.test/versions/v2.conf"
if resources_realign --apply --json --expected-plan "$plan_id" > "$GB_PREFIX/stale.json" 2>/dev/null; then
    printf 'stale review was accepted\n' >&2; exit 1
fi
[[ "$(cat "$events")" == root ]]
[[ "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET)" == auto ]]

: > "$events"
if BLOCK_ADMISSION=true resources_realign --apply --json > "$GB_PREFIX/blocked.json" 2>/dev/null; then
    printf 'failed live admission was ignored\n' >&2; exit 1
fi
[[ "$(cat "$events")" == $'root\nlock\nadmission' ]]
[[ "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET)" == auto ]]

: > "$events"
if OWNED_BUDGET=true resources_realign --apply --memory-budget 2G --json > "$GB_PREFIX/owned.json" 2>/dev/null; then
    printf 'environment-owned setting was overwritten\n' >&2; exit 1
fi
[[ "$(cat "$events")" == root ]]
[[ "$(cfg_get "$GB_GLOBAL_CONF" MEMORY_BUDGET)" == auto ]]

: > "$events"
if FAIL_DOMAIN=search.example.test resources_realign --apply --json > "$GB_PREFIX/partial.json" 2>/dev/null; then
    printf 'failed generation reported success\n' >&2; exit 1
fi
"$GB_PYTHON" - "$GB_PREFIX/partial.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))["application"]
assert result["status"] == "partial"
assert result["budget_saved"] is True
assert result["applied_domains"] == ["query.example.test"]
assert result["pending_domains"] == ["search.example.test"]
PY
[[ "$(cat "$events")" == $'root\nlock\nadmission\nnotify start\nsave MEMORY_BUDGET=2048M\napply query.example.test\napply search.example.test\nnotify fail' ]]

: > "$events"
resources_realign --apply --json > "$GB_PREFIX/applied.json" 2>/dev/null
"$GB_PYTHON" - "$GB_PREFIX/applied.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))["application"]
assert result["status"] == "complete"
assert result["pending_domains"] == []
PY
[[ "$(tail -n 1 "$events")" == 'notify ok' ]]
printf 'hardware realignment previews, ownership, stale plans, admission and partial apply: ok\n'
