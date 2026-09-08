#!/usr/bin/env bash
# Exercise deployment ordering and rollback with systemd replaced by a recorded
# lifecycle. Real service-user/isolation coverage lives in integration/systemd.sh.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry users systemd python pages; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
endpoint_source_type() { :; }
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
ep_version_set "$domain" v2 REQUIRE_CHECKSUMS false
ep_version_set "$domain" v2 DEFAULT_TRANSLATION test
ep_version_set "$domain" v2 DEFAULT_REFERENCE Ge1:1
root="$(rt_root "$domain" v2)"
check test "$root" = "$GB_OPT/query/v2"
check test "$(rt_unit_prefix "$domain" v2)" = getbible-query-v2
check test "$(rt_socket_dir "$domain" v2)" = "$GB_RUN/query/v2"

# Candidate preparation installs no live pointers or environment.
type_runtime_prepare "$domain"
first_candidate="${RT_CANDIDATES[v2]}"
first_release="$(cat "$first_candidate/.release")"
check test ! -L "$(py_current_link "$root")"
check test ! -e "$(rt_env_file "$domain" v2)"
check test -f "$first_candidate/runtime.env"
check test "$(stat -c %a "$first_candidate/runtime.env")" = 600
check grep -q "WorkingDirectory=$first_release" "$first_candidate/service.unit"
check grep -q -- "--config $first_candidate/gunicorn.conf.py" "$first_candidate/service.unit"
check grep -q 'KillSignal=SIGTERM' "$first_candidate/service.unit"
check grep -q 'QUERY_DEFAULT_TRANSLATION="test"' "$first_candidate/runtime.env"
check test "$(grep -c '^enable ' "$events" || true)" = 0
type_runtime_before_switch "$domain"
check grep -q "^enable $(rt_generation_unit "$domain" v2 "$first_candidate").socket" "$events"
check grep -q "^enable getbible-query-v2-" "$events"
check test "$(grep -c '^nginx-reload' "$events" || true)" = 0
record nginx-reload; RELOAD_DONE=true
type_runtime_finish "$domain"
first_generation="$(rt_active_generation "$domain" v2)"
check test "$first_generation" = "$first_candidate"
check test "$(py_current_release "$root")" = "$first_release"
check test "$(grep -c '^retire ' "$events" || true)" = 0

# Unchanged applies preserve process identity and release.
endpoint_apply "$domain"
check test "$(rt_active_generation "$domain" v2)" = "$first_generation"

# Config-only apply creates a new generation using the same immutable code.
ep_version_set "$domain" v2 DEFAULT_REFERENCE Ge1:2
type_runtime_prepare "$domain"
second_candidate="${RT_CANDIDATES[v2]}"
check test "$second_candidate" != "$first_generation"
check test "$(cat "$second_candidate/.release")" = "$first_release"
check test "$(rt_active_generation "$domain" v2)" = "$first_generation"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:1"' "$(rt_env_file "$domain" v2)"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$second_candidate/runtime.env"
check test -f "$second_candidate/version.conf"
type_runtime_before_switch "$domain"; record nginx-reload; RELOAD_DONE=true
type_runtime_finish "$domain"
check test "$(rt_previous_generation "$domain" v2)" = "$first_generation"
check test "$(rt_active_generation "$domain" v2)" = "$second_candidate"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$(rt_env_file "$domain" v2)"
check grep -q '^retire getbible-query-v2-' "$events"

# A bad candidate must retain live code, env, settings and generation.
FAIL_READY=true
if rt_set_setting "$domain" v2 DEFAULT_REFERENCE Ge1:3; then echo 'bad candidate unexpectedly accepted' >&2; exit 1; fi
FAIL_READY=false
check test "$(ep_version_get "$domain" v2 DEFAULT_REFERENCE)" = Ge1:2
check test "$(rt_active_generation "$domain" v2)" = "$second_candidate"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:2"' "$(rt_env_file "$domain" v2)"
check test "${#RT_CANDIDATES[@]}" = 0

# nginx rejection cannot activate an already-ready candidate.
FAIL_NGINX=true
if rt_set_setting "$domain" v2 DEFAULT_REFERENCE Ge1:4; then echo 'nginx rejection unexpectedly accepted' >&2; exit 1; fi
FAIL_NGINX=false
check test "$(rt_active_generation "$domain" v2)" = "$second_candidate"
check test "$(ep_version_get "$domain" v2 DEFAULT_REFERENCE)" = Ge1:2

# Invalid input is rejected before any candidate service starts.
starts="$(grep -c '^start ' "$events")"
if rt_set_setting "$domain" v2 WORKERS 0; then echo 'zero workers accepted' >&2; exit 1; fi
check test "$(ep_version_get "$domain" v2 WORKERS)" = 4
check test "$(grep -c '^start ' "$events")" = "$starts"

# Explicit update failure leaves the old release selected.
FAIL_BUILD=true
if rt_update "$domain"; then echo 'build rejection unexpectedly accepted' >&2; exit 1; fi
FAIL_BUILD=false
check test "$(py_current_release "$root")" = "$first_release"
check test "$(rt_active_generation "$domain" v2)" = "$second_candidate"

# Rollback uses the previous code and settings, preserving current security.
ep_set "$domain" ACCESS_MODE token
rt_rollback "$domain" v2
check test "$(ep_version_get "$domain" v2 DEFAULT_REFERENCE)" = Ge1:1
check test "$(ep_get "$domain" ACCESS_MODE)" = token
check test "$(py_current_release "$root")" = "$first_release"
check test "$(rt_previous_generation "$domain" v2)" = "$second_candidate"
check grep -q 'GB_ACCESS_MODE="token"' "$(rt_env_file "$domain" v2)"

# Rollback after a partial pointer commit restores exact old state.
previous="$(rt_previous_generation "$domain" v2)"
active="$(rt_active_generation "$domain" v2)"
ep_version_set "$domain" v2 DEFAULT_REFERENCE Ge1:5
type_runtime_prepare "$domain"
RT_COMMITTED=true
rt_switch_link "${RT_CANDIDATES[v2]}" "$root/active"
printf 'wrong\n' > "$(rt_env_file "$domain" v2)"
type_runtime_abort "$domain"
check test "$(rt_active_generation "$domain" v2)" = "$active"
check test "$(rt_previous_generation "$domain" v2)" = "$previous"
check grep -q 'QUERY_DEFAULT_REFERENCE="Ge1:1"' "$(rt_env_file "$domain" v2)"
# The aborted change is taken back in the record as well, so v2 is current again.
ep_version_set "$domain" v2 DEFAULT_REFERENCE Ge1:1

# A second version is its own service: own root, units, sockets, cache and
# environment file, deployed by the same transaction as the first.
mkdir -p "$GB_SRC/apps"
printf '{"value": 1}\n' > "$ROOT/tests/python/fixtures/repository/.v3-marker" 2>/dev/null || true
rm -f "$ROOT/tests/python/fixtures/repository/.v3-marker"
# Stubs called by the type module (newer shellcheck reports SC2329, older SC2317).
# shellcheck disable=SC2317,SC2329
rt_kind_versions() { printf 'v2\nv3\n'; }
# shellcheck disable=SC2317,SC2329
rt_implementation() { [[ "$2" == v2 || "$2" == v3 ]] && printf 'query\n'; }
# shellcheck disable=SC2317,SC2329
rt_manifest_load() {
    local kind="$1" key
    for key in KIND DESCRIPTION PACKAGE WSGI CHECK ENV_PREFIX DEFAULT_VERSION SUPPORTED_VERSIONS ROUTE METHODS MAX_BODY \
               CACHE_SECONDS WORKERS THREADS TIMEOUT_START TIMEOUT_STOP MEMORY_HIGH MEMORY_MAX CPU_QUOTA TASKS_MAX NOFILE WARM_TRANSLATIONS; do
        printf -v "RM_$key" '%s' ""
    done
    cfg_load "$GB_APPS/$kind/manifest.conf" RM
    RM_DIR="$kind"
}
rt_record_endpoint "$domain" v3 v3 "$ROOT/tests/python/fixtures/repository" ""
ep_version_set "$domain" v3 REQUIRE_CHECKSUMS false
ep_version_set "$domain" v3 DEFAULT_TRANSLATION test
check test "$(rt_root "$domain" v3)" = "$GB_OPT/query/v3"
check test "$(type_runtime_endpoints "$domain" | tr '\n' ' ')" = "v2 v3 "
type_runtime_prepare "$domain"
check test -z "${RT_CANDIDATES[v2]:-}"
v3_candidate="${RT_CANDIDATES[v3]}"
check grep -q 'GETBIBLE_VERSION="v3"' "$v3_candidate/runtime.env"
check grep -q "$GB_RUN/query/v3/" "$v3_candidate/runtime.env"
check grep -q "$GB_PREFIX/var/cache/getbible/query/v3/releases/" "$v3_candidate/runtime.env"
check grep -q "$(ep_log_dir "$domain")/app/v3.log" "$v3_candidate/runtime.env"
check grep -q 'CacheDirectory=getbible/query/v3' "$v3_candidate/service.unit"
type_runtime_before_switch "$domain"; record nginx-reload; RELOAD_DONE=true
type_runtime_finish "$domain"
check test "$(rt_active_generation "$domain" v3)" = "$v3_candidate"
check test "$(rt_active_generation "$domain" v2)" = "$active"
check test -f "$(rt_env_file "$domain" v3)"
check test "$(rt_live_unit "$domain" v3)" = "getbible-query-v3-$(basename "$v3_candidate")"
check test "$(type_runtime_default_endpoint "$domain")" = v2

# An update of one endpoint (a forced rebuild) leaves the other's generation alone.
v2_generation="$(rt_active_generation "$domain" v2)"
rt_update "$domain" v3 --python 3.12
check test "$(rt_active_generation "$domain" v2)" = "$v2_generation"
check test "$(rt_active_generation "$domain" v3)" != "$v3_candidate"
# The stand-in v3 goes away with its stubs: the real type module knows only v2.
rt_remove_endpoint_services "$domain" v3
rm -rf -- "$(rt_root "$domain" v3)"
ep_version_remove_config "$domain" v3
unset -f rt_kind_versions rt_implementation rt_manifest_load
unset GB_TYPE_RUNTIME_LOADED
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"

# A domain recorded before endpoints had records keeps its paths and units:
# the legacy layout. Migration retains the traditional service/configuration
# until readiness and nginx switching succeed, and keeps a usable rollback
# target afterward.
legacy_domain=search.example.test
ep_create "$legacy_domain" runtime search
ep_set "$legacy_domain" ACCESS_MODE metered
ep_set "$legacy_domain" VERSION v2
ep_set "$legacy_domain" REPOSITORY "$ROOT/tests/python/fixtures/repository"
ep_set "$legacy_domain" WORKERS 2
ep_set "$legacy_domain" THREADS 4
ep_set "$legacy_domain" WARM_TRANSLATIONS test
ep_set "$legacy_domain" REQUIRE_CHECKSUMS false
ep_set "$legacy_domain" DEFAULT_TRANSLATION test
ep_set "$legacy_domain" CACHE_TTL 60
ep_set "$legacy_domain" PYTHON_VERSION 3.12.14
legacy_release="$(py_build_release search "$legacy_domain")"
py_switch_release search "$legacy_release"
mkdir -p "$(ep_dir "$legacy_domain")"
printf 'GETBIBLE_REPOSITORY=%s\nGETBIBLE_VERSION=v2\nSEARCH_DEFAULT_TRANSLATION=test\nSEARCH_WORKERS=2\nSEARCH_THREADS=4\nGETBIBLE_REQUIRE_CHECKSUMS=false\n' \
    "$ROOT/tests/python/fixtures/repository" > "$(ep_dir "$legacy_domain")/runtime.env"
legacy_env_hash="$(gb_sha256_file "$(ep_dir "$legacy_domain")/runtime.env")"
check test "$(type_runtime_endpoints "$legacy_domain")" = v2
check test "$(rt_layout "$legacy_domain" v2)" = legacy
check test "$(rt_root "$legacy_domain" v2)" = "$GB_OPT/search"
check test "$(rt_env_file "$legacy_domain" v2)" = "$(ep_dir "$legacy_domain")/runtime.env"
check test "$(ep_version_get "$legacy_domain" v2 WORKERS)" = 2
check test "$(ep_get "$legacy_domain" DEFAULT_ENDPOINT)" = v2
check test -z "$(ep_get "$legacy_domain" VERSION)"
check test -z "$(ep_get "$legacy_domain" WORKERS)"
FAIL_PROBE=true
if endpoint_apply "$legacy_domain"; then echo 'failed search probe accepted' >&2; exit 1; fi
FAIL_PROBE=false
check test "$(gb_sha256_file "$(rt_env_file "$legacy_domain" v2)")" = "$legacy_env_hash"
check test "$(rt_live_unit "$legacy_domain" v2)" = getbible-search
check test "$(py_current_release search)" = "$legacy_release"
endpoint_apply "$legacy_domain"
check test -f "$(rt_previous_generation "$legacy_domain" v2)/.legacy-unit"
check test "$(cat "$(rt_previous_generation "$legacy_domain" v2)/.release")" = "$legacy_release"
check grep -q '^retire getbible-search$' "$events"
check grep -q '^enable getbible-search-2' "$events"
rt_rollback "$legacy_domain" v2
check test "$(ep_version_get "$legacy_domain" v2 DEFAULT_TRANSLATION)" = test
check test "$(py_current_release search)" = "$legacy_release"

# A dependency/code rebuild warms an isolated cache; retaining the old cache
# keeps a schema-changing library upgrade from damaging rollback readiness.
SOURCE_REVISION=two
rt_update "$domain" v2
updated_release="$(py_current_release "$root")"
check test "$updated_release" != "$first_release"
check test "$(rt_cache_dir "$domain" v2 "$updated_release")" != "$(rt_cache_dir "$domain" v2 "$first_release")"
check test -d "$(rt_cache_dir "$domain" v2 "$first_release")"
check grep -q "$(rt_cache_dir "$domain" v2 "$updated_release")" "$(rt_env_file "$domain" v2)"

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
