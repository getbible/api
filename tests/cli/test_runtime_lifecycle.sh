#!/usr/bin/env bash
# Exercise deployment ordering and rollback with systemd replaced by a recorded
# lifecycle. Real service-user/isolation coverage lives in integration/systemd.sh.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry users systemd python; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
mkdir -p "$GB_LOG"
events="$GB_PREFIX/events"; : > "$events"
FAIL_READY=false; FAIL_PROBE=false; FAIL_NGINX=false; FAIL_BUILD=false; RELOAD_DONE=false
SOURCE_REVISION=one
record() { printf '%s\n' "$*" >> "$events"; }
tg_notify() { record "notify $*"; }
access_valid_mode() { [[ "$1" == open || "$1" == metered || "$1" == token ]]; }
gb_ensure_base_groups() { :; }
gb_ensure_system_user() { :; }
py_resolve_version() { printf '%s\n' 3.12.14; }
py_inputs_hash() { printf '%s\n' "$SOURCE_REVISION"; }
py_build_release() {
    [[ "$FAIL_BUILD" == false ]] || return 1
    local release
    mkdir -p "$(py_releases_dir "$1")"
    release="$(mktemp -d "$(py_releases_dir "$1")/release.XXXXXX")"
    mkdir -p "$release/.venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$release/.venv/bin/python"
    chmod 0755 "$release/.venv/bin/python"
    printf '%s\n' "$SOURCE_REVISION" > "$release/.inputs"
    printf '%s\n' 3.12.14 > "$release/.python-version"
    record "build $release"
    printf '%s\n' "$release"
}
sd_available() { return 0; }
sd_daemon_reload() { record daemon-reload; }
sd_enable() { record "enable $*"; }
sd_start() { record "start $*"; }
sd_is_active() { return 0; }
sd_disable_now() { record "disable $*"; }
sd_journal() { :; }
sd_wait_ready() {
    record "ready $1 $2"
    [[ "$FAIL_PROBE" == false || "$2" != /probez ]] || return 1
    [[ "$FAIL_READY" == false || "$1" == "${RT_OLD_SOCKET:-}" ]]
}
sd_retire_after() {
    [[ "$RELOAD_DONE" == true ]] || { echo 'retired before nginx reload' >&2; return 1; }
    [[ -f "$2" ]] || return 1
    record "retire $1"
}
endpoint_apply() {
    local domain="$1"
    RELOAD_DONE=false
    if ! type_runtime_prepare "$domain"; then type_runtime_abort "$domain"; return 1; fi
    type_runtime_before_switch "$domain" || return 1
    if [[ "$FAIL_NGINX" == true ]]; then type_runtime_abort "$domain"; return 1; fi
    record nginx-reload; RELOAD_DONE=true
    type_runtime_finish "$domain"
}
pass=0
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; pass=$((pass + 1)); }
domain=query.example.test
type_runtime_create "$domain" query v2 "$ROOT/tests/python/fixtures/repository" metered ''
ep_set "$domain" REQUIRE_CHECKSUMS false
ep_set "$domain" DEFAULT_TRANSLATION test
ep_set "$domain" DEFAULT_REFERENCE Ge1:1

# Candidate preparation installs no live pointers or environment.
type_runtime_prepare "$domain"
first_candidate="$RT_CANDIDATE"
first_release="$(cat "$first_candidate/.release")"
check test ! -L "$(py_current_link query)"
check test ! -e "$(rt_env_file "$domain")"
check test -f "$first_candidate/runtime.env"
check test "$(stat -c %a "$first_candidate/runtime.env")" = 600
check grep -q "WorkingDirectory=$first_release" "$first_candidate/service.unit"
check grep -q -- "--config $first_candidate/gunicorn.conf.py" "$first_candidate/service.unit"
check grep -q 'KillSignal=SIGTERM' "$first_candidate/service.unit"
check grep -q 'QUERY_DEFAULT_TRANSLATION="test"' "$first_candidate/runtime.env"
check test "$(grep -c '^enable ' "$events" || true)" = 0
type_runtime_before_switch "$domain"
check grep -q "^enable $(rt_generation_unit query "$first_candidate").socket" "$events"
check test "$(grep -c '^nginx-reload' "$events" || true)" = 0
record nginx-reload; RELOAD_DONE=true
type_runtime_finish "$domain"
first_generation="$(rt_active_generation query)"
check test "$first_generation" = "$first_candidate"
check test "$(py_current_release query)" = "$first_release"
check test "$(grep -c '^retire ' "$events" || true)" = 0

# Unchanged applies preserve process identity and release.
endpoint_apply "$domain"
check test "$(rt_active_generation query)" = "$first_generation"

# Config-only apply creates a new generation using the same immutable code.
ep_set "$domain" DEFAULT_REFERENCE Ge1:2
type_runtime_prepare "$domain"
second_candidate="$RT_CANDIDATE"
check test "$second_candidate" != "$first_generation"
check test "$(cat "$second_candidate/.release")" = "$first_release"
check test "$(rt_active_generation query)" = "$first_generation"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:1"' "$(rt_env_file "$domain")"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$second_candidate/runtime.env"
type_runtime_before_switch "$domain"; record nginx-reload; RELOAD_DONE=true
type_runtime_finish "$domain"
check test "$(rt_previous_generation query)" = "$first_generation"
check test "$(rt_active_generation query)" = "$second_candidate"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$(rt_env_file "$domain")"
check grep -q '^retire getbible-query-' "$events"

# A bad candidate must retain live code, env, settings and generation.
FAIL_READY=true
if rt_set_setting "$domain" DEFAULT_REFERENCE Ge1:3; then echo 'bad candidate unexpectedly accepted' >&2; exit 1; fi
FAIL_READY=false
check test "$(ep_get "$domain" DEFAULT_REFERENCE)" = Ge1:2
check test "$(rt_active_generation query)" = "$second_candidate"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$(rt_env_file "$domain")"
check test -z "$RT_CANDIDATE"

# nginx rejection cannot activate an already-ready candidate.
FAIL_NGINX=true
if rt_set_setting "$domain" DEFAULT_REFERENCE Ge1:4; then echo 'nginx rejection unexpectedly accepted' >&2; exit 1; fi
FAIL_NGINX=false
check test "$(rt_active_generation query)" = "$second_candidate"
check test "$(ep_get "$domain" DEFAULT_REFERENCE)" = Ge1:2

# Invalid input is rejected before any candidate service starts.
starts="$(grep -c '^start ' "$events")"
if rt_set_setting "$domain" WORKERS 0; then echo 'zero workers accepted' >&2; exit 1; fi
check test "$(ep_get "$domain" WORKERS)" = 4
check test "$(grep -c '^start ' "$events")" = "$starts"

# Explicit update failure leaves the old release selected.
FAIL_BUILD=true
if rt_update "$domain"; then echo 'build rejection unexpectedly accepted' >&2; exit 1; fi
FAIL_BUILD=false
check test "$(py_current_release query)" = "$first_release"
check test "$(rt_active_generation query)" = "$second_candidate"

# Rollback uses the previous code and settings, preserving current security.
ep_set "$domain" ACCESS_MODE token
rt_rollback "$domain"
check test "$(ep_get "$domain" DEFAULT_REFERENCE)" = Ge1:1
check test "$(ep_get "$domain" ACCESS_MODE)" = token
check test "$(py_current_release query)" = "$first_release"
check test "$(rt_previous_generation query)" = "$second_candidate"
check grep -q 'GB_ACCESS_MODE="token"' "$(rt_env_file "$domain")"

# Rollback after a partial pointer commit restores exact old state.
previous="$(rt_previous_generation query)"
active="$(rt_active_generation query)"
ep_set "$domain" DEFAULT_REFERENCE Ge1:5
type_runtime_prepare "$domain"
RT_COMMITTED=true
rt_switch_link "$RT_CANDIDATE" "$(py_app_root query)/active"
printf 'wrong\n' > "$(rt_env_file "$domain")"
type_runtime_abort "$domain"
check test "$(rt_active_generation query)" = "$active"
check test "$(rt_previous_generation query)" = "$previous"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:1"' "$(rt_env_file "$domain")"

# Migration retains the traditional service/configuration until readiness and
# nginx switching succeed, and keeps a usable rollback target afterward.
legacy_domain=search.example.test
type_runtime_create "$legacy_domain" search v2 "$ROOT/tests/python/fixtures/repository" metered test
ep_set "$legacy_domain" REQUIRE_CHECKSUMS false
ep_set "$legacy_domain" DEFAULT_TRANSLATION test
legacy_release="$(py_build_release search "$legacy_domain")"
py_switch_release search "$legacy_release"
printf 'GETBIBLE_REPOSITORY=%s\nGETBIBLE_VERSION=v2\nSEARCH_DEFAULT_TRANSLATION=test\nSEARCH_WORKERS=2\nSEARCH_THREADS=4\nGETBIBLE_REQUIRE_CHECKSUMS=false\n' \
    "$ROOT/tests/python/fixtures/repository" > "$(rt_env_file "$legacy_domain")"
legacy_env_hash="$(gb_sha256_file "$(rt_env_file "$legacy_domain")")"
FAIL_PROBE=true
if endpoint_apply "$legacy_domain"; then echo 'failed search probe accepted' >&2; exit 1; fi
FAIL_PROBE=false
check test "$(gb_sha256_file "$(rt_env_file "$legacy_domain")")" = "$legacy_env_hash"
check test "$(rt_live_unit search)" = getbible-search
check test "$(py_current_release search)" = "$legacy_release"
endpoint_apply "$legacy_domain"
check test -f "$(rt_previous_generation search)/.legacy-unit"
check test "$(cat "$(rt_previous_generation search)/.release")" = "$legacy_release"
check grep -q '^retire getbible-search$' "$events"
rt_rollback "$legacy_domain"
check test "$(ep_get "$legacy_domain" DEFAULT_TRANSLATION)" = test
check test "$(py_current_release search)" = "$legacy_release"

# Retirement is sensitive to PID identity, not just PID existence.
printf '%s 0\n' "$$" > "$GB_PREFIX/drain-snapshot"
cat > "$GB_PREFIX/fake-systemctl" <<'CTL'
#!/bin/sh
printf '%s\n' "$*" > "$RETIRE_CALL"
CTL
chmod 0755 "$GB_PREFIX/fake-systemctl"
export RETIRE_CALL="$GB_PREFIX/retired"
"$ROOT/src/bin/getbible-runtime-retire" "$GB_PREFIX/fake-systemctl" getbible-query-old "$GB_PREFIX/drain-snapshot"
check grep -q '^stop getbible-query-old.socket getbible-query-old.service$' "$RETIRE_CALL"
rm -f -- "$RETIRE_CALL"
sleep 0.5 &
worker_pid=$!
if [[ -r "/proc/$worker_pid/stat" ]]; then
    worker_stat="$(cat "/proc/$worker_pid/stat")"
    IFS=' ' read -r -a worker_fields <<< "${worker_stat##*) }"
    printf '%s %s\n' "$worker_pid" "${worker_fields[19]}" > "$GB_PREFIX/drain-live"
    "$ROOT/src/bin/getbible-runtime-retire" "$GB_PREFIX/fake-systemctl" getbible-query-20260101T120000-AbCd12 "$GB_PREFIX/drain-live" &
    retire_pid=$!
    sleep 0.1
    check test ! -f "$RETIRE_CALL"
    wait "$worker_pid"
    wait "$retire_pid"
    check test -f "$RETIRE_CALL"
else
    wait "$worker_pid"
    [[ "${CI:-false}" != true ]] || { echo 'CI must expose child process identities in /proc' >&2; exit 1; }
    echo 'Live /proc drain assertion skipped: this sandbox hides child process identities.'
fi
printf 'Runtime lifecycle: %s assertions passed\n' "$pass"
