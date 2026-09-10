#!/usr/bin/env bash
# Offline artifact dispatch and final-path release regressions. Real wheel
# installation/import checks run during image construction and its acceptance
# test; this fixture proves deployment never selects a network/source builder.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_EXECUTION_MODE=docker GETBIBLE_EXECUTION_MODE=docker
export GB_RUNTIME_BUNDLE="$TEST_ROOT/bundle" BUNDLE_CALLS="$TEST_ROOT/interpreter-calls"
# shellcheck source=../../src/lib/core.sh
source "$ROOT/src/lib/core.sh"
# shellcheck source=../../src/lib/python.sh
source "$ROOT/src/lib/python.sh"
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; }

platform_detect
row="$(awk -v arch="$PLATFORM_ARCH" '$1 == "3.12.14" && $2 == arch {print; exit}' "$GB_SRC/python/distributions.lock")"
IFS=' ' read -r version arch build digest url <<< "$row"
identity="cpython-$version-$build-$arch-${digest:0:16}"
distribution="$GB_RUNTIME_BUNDLE/python/$identity"
wheels="$GB_RUNTIME_BUNDLE/wheels/$version/query"
mkdir -p "$distribution/bin" "$wheels" "$TEST_ROOT/bin"
printf '%s\n' "$row" > "$GB_RUNTIME_BUNDLE/distributions.lock"
printf '%s\n' "$row" > "$distribution/.distribution"
cat > "$distribution/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf '%s: %s\n' "$0" "$*" >> "$BUNDLE_CALLS"
if [[ "$*" == *'-m venv '* ]]; then
    target="${!#}"
    mkdir -p "$target/bin"
    cp "$0" "$target/bin/python"
    chmod 0755 "$target/bin/python"
elif [[ "$*" == *'-m pip '*' install '* ]]; then
    [[ "$*" == *'--no-index'* && "$*" == *'--only-binary=:all:'* && "$*" == *'--require-hashes'* ]] || exit 61
    [[ "$*" != *'--no-build-isolation'* ]] || exit 62
elif [[ "$*" == *'-m pip freeze'* ]]; then
    printf 'getbible==2.0.0\n'
fi
PYTHON
chmod 0755 "$distribution/bin/python3"
cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf 'NETWORK ATTEMPT\n' >> "$BUNDLE_CALLS"
exit 99
CURL
chmod 0755 "$TEST_ROOT/bin/curl"
export PATH="$TEST_ROOT/bin:$PATH"
printf 'getbible==2.0.0 --hash=sha256:%064d\n' 0 > "$wheels/packages.requirements"
py_inputs_hash query "$version" > "$wheels/.inputs"

check test "$(py_resolve_version auto)" = "$version"
check test "$(py_resolve_version 3.12)" = "$version"
if (py_resolve_version 3.14) >/dev/null 2>&1; then echo 'Unavailable image Python accepted' >&2; exit 1; fi
check test "$(py_catalog | tail -n1 | awk '{print $1}')" = "$version"

endpoint_root="$GB_OPT/query/v2"
release="$(py_build_release "$endpoint_root" query.example.test 3.12 query)"
check test -x "$release/.venv/bin/python"
check test -x "$GB_OPT/python/$identity/bin/python3"
check test "$(cat "$release/.python-distribution")" = "$row"
check cmp "$wheels/packages.requirements" "$release/.bundled-requirements"
check test "$(cat "$release/.inputs")" = "$(py_inputs_hash query "$version")"
check grep -Fq -- "-m venv $release/.venv" "$BUNDLE_CALLS"
check grep -Fq -- '--no-index --find-links' "$BUNDLE_CALLS"
if grep -q 'NETWORK ATTEMPT' "$BUNDLE_CALLS"; then echo 'Docker deployment attempted network download' >&2; exit 1; fi

# An incomplete or stale image payload must leave the current release intact.
py_switch_release "$endpoint_root" "$release"
printf 'stale\n' > "$wheels/.inputs"
if (py_build_release "$endpoint_root" query.example.test 3.12 query) >/dev/null 2>&1; then
    echo 'Stale bundle inputs accepted' >&2; exit 1
fi
check test "$(py_current_release "$endpoint_root")" = "$release"
check test "$(find "$(py_releases_dir "$endpoint_root")" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1

# Retained runtime identities survive a newer image dropping an old catalog
# row. Old generations still run, and rollback needs no image download.
printf '# this newer image no longer advertises the old exact patch\n' > "$GB_RUNTIME_BUNDLE/distributions.lock"
check test "$(py_resolve_version "$version")" = "$version"
check test "$(py_managed_install "$version")" = "$GB_OPT/python/$identity/bin/python3"
check test -x "$release/.venv/bin/python"
printf 'Offline runtime artifact regressions passed\n'
