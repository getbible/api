#!/usr/bin/env bash
# Managed-interpreter safety and host-detection regressions, no network needed.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT"
# shellcheck source=../../src/lib/core.sh
source "$ROOT/src/lib/core.sh"
# shellcheck source=../../src/lib/python.sh
source "$ROOT/src/lib/python.sh"
trap 'rm -rf -- "$TEST_ROOT"; gb_cleanup' EXIT
assert_eq() { [[ "$1" == "$2" ]] || { printf 'FAIL: %s (got %s, expected %s)\n' "$3" "$1" "$2" >&2; exit 1; }; }

export GB_OS_RELEASE="$TEST_ROOT/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$GB_OS_RELEASE"
assert_eq "$(platform_default_python)" 3.12 'Ubuntu 24 selects the reviewed 3.12 family'
assert_eq "$(py_resolve_version auto)" 3.12.14 'family resolves to exact reviewed patch'
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$GB_OS_RELEASE"
assert_eq "$(py_resolve_version auto)" 3.14.7 'Ubuntu 26 selects reviewed Python 3.14'
printf 'ID=debian\nVERSION_ID="13"\n' > "$GB_OS_RELEASE"
assert_eq "$(py_resolve_version auto)" 3.14.7 'other glibc Linux is not coupled to system Python'
assert_eq "$(py_resolve_version 3.13)" 3.13.15 'explicit family works on another distro'
assert_eq "$(py_resolve_version 3.12.14)" 3.12.14 'exact selection survives OS change'
if (py_resolve_version 3.15) >/dev/null 2>&1; then echo 'FAIL: unreviewed Python accepted' >&2; exit 1; fi
if (py_resolve_version 3.14.999) >/dev/null 2>&1; then echo 'FAIL: nonexistent patch accepted' >&2; exit 1; fi
# Deliberately hostile data must never be executed.
# shellcheck disable=SC2016
printf 'ID=ubuntu\nVERSION_ID="$(touch %s/unsafe)"\n' "$TEST_ROOT" > "$GB_OS_RELEASE"
platform_detect
[[ ! -e "$TEST_ROOT/unsafe" ]] || { echo 'FAIL: os-release executed as code'; exit 1; }

# Hashing must distinguish Python changes, and remain independent of checkout path.
HASH_312="$(py_inputs_hash query 3.12)"
HASH_314="$(py_inputs_hash query 3.14)"
[[ "$HASH_312" != "$HASH_314" ]] || { echo 'FAIL: Python version missing from release hash'; exit 1; }
cp -a "$GB_SRC" "$TEST_ROOT/moved-src"
ORIGINAL_SRC="$GB_SRC"
GB_SRC="$TEST_ROOT/moved-src"
assert_eq "$(py_inputs_hash query 3.12)" "$HASH_312" 'checkout location does not invalidate release'
printf '\n# build tool update\n' >> "$GB_SRC/python/build-requirements.txt"
[[ "$(py_inputs_hash query 3.12)" != "$HASH_312" ]] || { echo 'FAIL: build tooling absent from inputs'; exit 1; }
GB_SRC="$ORIGINAL_SRC"

# Failed downloads/checksums cannot become an installed interpreter. Use a small
# signed-off fixture row and a PATH-level download stub, never disable hashing.
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/archive/python/bin"
cat > "$TEST_ROOT/archive/python/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exit 0
PYTHON
chmod +x "$TEST_ROOT/archive/python/bin/python3"
tar -czf "$TEST_ROOT/fixture.tar.gz" -C "$TEST_ROOT/archive" python
FIXTURE_HASH="$(gb_sha256_file "$TEST_ROOT/fixture.tar.gz")"
export TEST_ROOT
cat > "$TEST_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf 'download\n' >> "$TEST_ROOT/downloads"
while (($#)); do
    if [[ "$1" == --output ]]; then cp "$TEST_ROOT/fixture.tar.gz" "$2"; exit 0; fi
    shift
done
exit 1
CURL
chmod +x "$TEST_ROOT/bin/curl"
export PATH="$TEST_ROOT/bin:$PATH"
py_distribution() { printf '3.14.7 x86_64 20260901 %s https://github.com/astral-sh/python-build-standalone/releases/download/20260901/fixture.tar.gz\n' "$FIXTURE_HASH"; }
SAVED_HASH="$FIXTURE_HASH"
FIXTURE_HASH="$(printf '%064d' 0)"
if (py_managed_install 3.14) >/dev/null 2>&1; then echo 'FAIL: bad checksum installed'; exit 1; fi
[[ -z "$(find "$(py_managed_root)" -mindepth 1 -maxdepth 1 -type d -print)" ]] || { echo 'FAIL: failed install left staging directories'; exit 1; }
FIXTURE_HASH="$SAVED_HASH"
MANAGED="$(py_managed_install 3.14)"
[[ "$MANAGED" == "$GB_OPT/python/"*/bin/python3 && -x "$MANAGED" ]] || { echo 'FAIL: interpreter not owned by application'; exit 1; }
DOWNLOADS="$(wc -l < "$TEST_ROOT/downloads")"
assert_eq "$(py_managed_install 3.14)" "$MANAGED" 'same distribution reused'
assert_eq "$(wc -l < "$TEST_ROOT/downloads")" "$DOWNLOADS" 'reuse does not download or update'
[[ -s "${MANAGED%/bin/python3}/.distribution" ]] || { echo 'FAIL: distribution identity not recorded'; exit 1; }

# An exact deployed patch remains available if a later checkout drops it from
# its download catalog; no host fallback or surprise family upgrade occurs.
GB_SRC="$TEST_ROOT/moved-src"
sed -i '/^3\.14\.7 /d' "$GB_SRC/python/distributions.lock"
assert_eq "$(py_resolve_version 3.14.7)" 3.14.7 'retired catalog entry resolves from installed provenance'
GB_SRC="$ORIGINAL_SRC"

# The fixture interpreter cannot create a real venv. This intentional build
# failure must propagate even in an if/command-substitution context and remove
# only the incomplete candidate, leaving the serving symlink unchanged.
mkdir -p "$(py_releases_dir query)/serving"
ln -s "$(py_releases_dir query)/serving" "$(py_current_link query)"
if candidate="$(py_build_release query query.example.test 3.14 2>/dev/null)"; then
    echo 'FAIL: incomplete virtual environment was accepted' >&2
    exit 1
fi
assert_eq "$(py_current_release query)" "$(py_releases_dir query)/serving" 'failed build preserves live release'
assert_eq "$(find "$(py_releases_dir query)" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" serving 'failed release is removed'
rm -f "$(py_current_link query)"
rm -rf "$(py_releases_dir query)/serving"

# Retention must preserve code belonging to retained deployment generations.
for number in 01 02 03 04 05; do mkdir -p "$(py_releases_dir query)/$number"; done
mkdir -p "$(py_app_root query)/deployments/rollback"
printf '%s\n' "$(py_releases_dir query)/01" > "$(py_app_root query)/deployments/rollback/.release"
ln -s "$(py_releases_dir query)/02" "$(py_current_link query)"
py_prune_releases query 1
[[ -d "$(py_releases_dir query)/01" && -d "$(py_releases_dir query)/02" && -d "$(py_releases_dir query)/05" ]] || { echo 'FAIL: protected release removed'; exit 1; }
[[ ! -d "$(py_releases_dir query)/03" && ! -d "$(py_releases_dir query)/04" ]] || { echo 'FAIL: unused releases retained'; exit 1; }
printf 'Managed Python and platform regressions passed\n'
