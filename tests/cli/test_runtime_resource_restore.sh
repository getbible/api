#!/usr/bin/env bash
# Container recreation changes only stopped services' resource allocation;
# the saved application, data/access settings and rollback stay unchanged.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GETBIBLE_EXECUTION_MODE=docker
export GETBIBLE_MEMORY_BUDGET=auto
for lib in core config registry python; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; }

# Hosted CI can run directly on a VM with no finite Docker cgroup. Supply a
# real cgroup-v2 fixture to the actual planner instead of depending on the
# runner's memory.max, CPU quota or membership path.
RESTORE_REAL_PYTHON="$(command -v "$GB_PYTHON")"
export RESTORE_REAL_PYTHON
export RESTORE_PROC_ROOT="$TEST_ROOT/proc" RESTORE_CGROUP_ROOT="$TEST_ROOT/cgroup"
mkdir -p "$RESTORE_PROC_ROOT/1" "$RESTORE_PROC_ROOT/self" "$RESTORE_CGROUP_ROOT/system.slice/getbible.scope"
printf '0::/system.slice/getbible.scope\n' > "$RESTORE_PROC_ROOT/self/cgroup"
printf '0::/\n' > "$RESTORE_PROC_ROOT/1/cgroup"
printf '10 9 0:2 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n' > "$RESTORE_PROC_ROOT/self/mountinfo"
printf '4294967296\n' > "$RESTORE_CGROUP_ROOT/memory.max"
printf '200000 100000\n' > "$RESTORE_CGROUP_ROOT/cpu.max"
printf 'max\n' > "$RESTORE_CGROUP_ROOT/system.slice/memory.max"
printf 'max\n' > "$RESTORE_CGROUP_ROOT/system.slice/getbible.scope/memory.max"
cat > "$TEST_ROOT/python-fixture" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == */getbible-resources ]]; then
    exec "$RESTORE_REAL_PYTHON" "$@" --proc-root "$RESTORE_PROC_ROOT" --cgroup-root "$RESTORE_CGROUP_ROOT"
fi
exec "$RESTORE_REAL_PYTHON" "$@"
PYTHON
chmod 0755 "$TEST_ROOT/python-fixture"
GB_PYTHON="$TEST_ROOT/python-fixture"
domain=query.example.test
ep_create "$domain" runtime query
ep_set "$domain" ACCESS_MODE token
version_conf="$(ep_version_conf "$domain" v2)"
mkdir -p "$(ep_versions_dir "$domain")"
for entry in LABEL=v2 APP_VERSION=v2 ENABLED=true WORKERS=4 THREADS=4 WARM_TRANSLATIONS=kjv CACHE_TTL=300; do
    cfg_set "$version_conf" "${entry%%=*}" "${entry#*=}"
done
root="$(rt_root "$domain" v2)"
release="$root/releases/retained"
active="$root/deployments/active-saved"
previous="$root/deployments/previous-saved"
mkdir -p "$release/.venv/bin" "$release/src/query" "$active" "$previous"
cp "$ROOT/src/apps/query/manifest.conf" "$release/src/query/manifest.conf"
printf '#!/bin/sh\nexit 0\n' > "$release/.venv/bin/python"
chmod 0755 "$release/.venv/bin/python"
printf '%s\n' "$release" > "$active/.release"
cat > "$active/runtime.env" <<'ENV'
# Saved generation configuration is deliberately different from image defaults.
GETBIBLE_REPOSITORY="/srv/retained-scripture"
GETBIBLE_VERSION="v2"
GB_ACCESS_MODE="token"
QUERY_DEFAULT_REFERENCE="Ge1:7"
QUERY_WORKERS="4"
QUERY_THREADS="4"
QUERY_WARM_TRANSLATIONS="kjv"
QUERY_BIND="unix:/run/getbible/retained.sock"
OPERATOR_VALUE="literal $value and \"quotes\""
ENV
cat > "$active/limits.conf" <<'LIMITS'
[Service]
MemoryHigh=7G
MemoryMax=9G
MemorySwapMax=0
CPUQuota=200%
TasksMax=64
LIMITS
printf '# retained gunicorn configuration\n' > "$active/gunicorn.conf.py"
chmod 0600 "$active/runtime.env"
cp -a "$active/." "$previous/"
ln -s "$active" "$root/active"
ln -s "$previous" "$root/previous"
ln -s "$release" "$root/current"
unit="$(rt_generation_unit "$domain" v2 "$active")"
mkdir -p "$GB_SYSTEMD/$unit.service.d"
cp "$active/limits.conf" "$GB_SYSTEMD/$unit.service.d/10-limits.conf"
cp "$active/runtime.env" "$TEST_ROOT/original.env"
previous_hash="$(gb_sha256_file "$previous/runtime.env")"
gunicorn_hash="$(gb_sha256_file "$active/gunicorn.conf.py")"
if rt_restore_resource_settings 2>/dev/null; then echo 'Runtime restore accepted outside initialization' >&2; exit 1; fi
check cmp "$TEST_ROOT/original.env" "$active/runtime.env"

export GB_RESOURCES_BOOTSTRAP=true
resources_plan --format json > "$TEST_ROOT/resource-plan.json"
check "$GB_PYTHON" - "$TEST_ROOT/resource-plan.json" <<'PYTHON'
import json
import sys
with open(sys.argv[1]) as stream:
    plan = json.load(stream)
assert plan["budget_bytes"] == 4 * 1024**3, plan
assert plan["cgroup_limit_bytes"] == 4 * 1024**3, plan
assert plan["source"] == "cgroup", plan
assert (plan["steady_runtime_bytes"] + plan["candidate_reserve_bytes"]
        + plan["infrastructure_reserve_bytes"]) <= plan["budget_bytes"], plan
PYTHON
# Prove that initialization uses the retained release's manifest, not a new
# image implementation that may have different defaults or supported versions.
GB_APPS="$TEST_ROOT/no-new-app-sources"
rt_restore_resource_settings
check grep -Fq 'GETBIBLE_REPOSITORY="/srv/retained-scripture"' "$active/runtime.env"
check grep -Fq 'GB_ACCESS_MODE="token"' "$active/runtime.env"
check grep -Fq 'QUERY_DEFAULT_REFERENCE="Ge1:7"' "$active/runtime.env"
check grep -Fq 'QUERY_BIND="unix:/run/getbible/retained.sock"' "$active/runtime.env"
# shellcheck disable=SC2016 # The saved literal must not be expanded as shell code.
check grep -Fq 'OPERATOR_VALUE="literal $value and \"quotes\""' "$active/runtime.env"
check grep -Fq 'GETBIBLE_TRANSLATION_CACHE_LIMIT=' "$active/runtime.env"
check test "$(stat -c %a "$active/runtime.env")" = 600
check test "$(cfg_get "$active/limits.conf" MemoryMax)" != 9G
check grep -Fxq 'CPUQuota=' "$active/limits.conf"
check grep -Fq 'MemorySwapMax=0' "$active/limits.conf"
check cmp "$active/limits.conf" "$GB_SYSTEMD/$unit.service.d/10-limits.conf"
check cmp "$active/runtime.env" "$(rt_env_file "$domain" v2)"
check test "$(gb_sha256_file "$previous/runtime.env")" = "$previous_hash"
check test "$(gb_sha256_file "$active/gunicorn.conf.py")" = "$gunicorn_hash"
check test "$(py_current_release "$root")" = "$release"
check test "$(rt_previous_generation "$domain" v2)" = "$previous"
check test "$(ep_version_get "$domain" v2 WORKERS)" = 4
restored_hash="$(gb_sha256_file "$active/runtime.env")"
rt_restore_resource_settings
check test "$(gb_sha256_file "$active/runtime.env")" = "$restored_hash"
printf 'Runtime resource restoration regressions passed\n'
