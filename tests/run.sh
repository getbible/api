#!/usr/bin/env bash
# The test suite. Lint, Python unit tests and sandboxed CLI tests always run;
# integration tests (real nginx and gunicorn) run with --all when nginx is
# installed and the caller is root.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
ALL=false
[[ "${1:-}" == --all ]] && ALL=true
FAILED=0
step() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'FAILED: %s\n' "$*"; FAILED=$((FAILED + 1)); }

step "syntax"
for f in getbible.sh src/lib/*.sh src/types/*/type.sh src/bin/getbible-sync src/bin/getbible-notify src/bin/getbible-logrotate-hook src/bin/getbible-runtime-retire tests/run.sh tests/cli/*.sh tests/integration/*.sh; do
    bash -n "$f" || fail "bash -n $f"
done
python3 -m py_compile src/bin/getbible-render src/bin/getbible-tokens src/bin/getbible-verify-tree src/bin/getbible-analytics src/bin/getbible-cloudflare src/bin/getbible-nginx-strip || fail "py_compile tools"
find src/apps -name '*.py' -not -path '*/build/*' -print0 | xargs -0 python3 -m py_compile || fail "py_compile apps"

step "shellcheck"
if command -v shellcheck >/dev/null; then
    shellcheck -x -s bash getbible.sh src/lib/*.sh src/types/*/type.sh src/bin/getbible-sync src/bin/getbible-notify src/bin/getbible-logrotate-hook src/bin/getbible-runtime-retire tests/run.sh tests/cli/*.sh tests/integration/*.sh || fail "shellcheck"
else
    if [[ "${CI:-false}" == true ]]; then fail "shellcheck is required in CI"; else echo "shellcheck not installed; skipped"; fi
fi

step "runtime kinds carry every required file"
# An implementation directory is src/apps/<kind> or src/apps/<kind>-<version>;
# its manifest names the kind and the Python package.
for manifest in src/apps/*/manifest.conf; do
    dir="$(basename "$(dirname "$manifest")")"
    kind="$(sed -n 's/^KIND=//p' "$manifest")"
    package="$(sed -n 's/^PACKAGE=//p' "$manifest")"
    [[ "$dir" == "$kind" || "$dir" == "$kind"-v[0-9]* ]] || fail "src/apps/$dir must be named after its kind ($kind), optionally with -vN"
    [[ -n "$package" ]] || fail "$manifest declares no PACKAGE"
    for required in pyproject.toml requirements.txt manifest.conf openapi.json.tmpl docs.html.tmpl "$package/app.py" "$package/config.py" "$package/wsgi.py" "$package/check.py"; do
        [[ -e "src/apps/$dir/$required" ]] || fail "src/apps/$dir/$required is missing"
    done
    [[ -e "tests/python/test_${dir//-/_}_app.py" ]] || fail "tests/python/test_${dir//-/_}_app.py is missing"
done
echo "ok"

step "python unit tests"
VENV="${GB_TEST_VENV:-$ROOT/.venv-test}"
if [[ ! -x "$VENV/bin/python" ]]; then
    echo "creating $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --upgrade pip
fi
if [[ "$("$VENV/bin/python" -c 'import sys; print(sys.version_info[:2])')" != "$(python3 -c 'import sys; print(sys.version_info[:2])')" ]]; then
    printf 'The test virtual environment uses another Python version; choose a fresh GB_TEST_VENV.\n' >&2
    exit 1
fi
# Install both kinds on every invocation: cached virtual environments must
# follow changes to the pinned dependencies instead of silently staying stale.
"$VENV/bin/python" -m pip install --quiet --requirement src/apps/query/requirements.txt --requirement src/apps/search/requirements.txt
"$VENV/bin/python" -m pip install --quiet --no-deps --force-reinstall src/apps/common src/apps/query src/apps/search
"$VENV/bin/python" -m pip check || fail "python dependency compatibility"
rm -rf src/apps/*/build src/apps/*/*.egg-info
"$VENV/bin/python" -m unittest discover -s tests/python -t . -v 2>&1 | tail -50 || fail "python unit tests"

step "command line tests (sandbox prefix)"
for script in tests/cli/test_*.sh; do
    bash "$script" || fail "cli tests: $script"
done

if [[ "$ALL" == true ]]; then
    step "integration"
    if command -v nginx >/dev/null && [[ "$(id -u)" -eq 0 ]]; then
        bash tests/integration/static.sh || fail "integration static"
        bash tests/integration/runtime.sh || fail "integration runtime"
    else
        fail "--all requires nginx and root; integration tests were not run"
    fi
fi

printf '\n'
if (( FAILED == 0 )); then
    echo "ALL TESTS PASSED"
else
    echo "$FAILED test group(s) failed"
    exit 1
fi
