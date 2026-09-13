#!/usr/bin/env bash
# Image refresh selects bundled Python patches without forcing unchanged code
# to rebuild; failed preparation leaves the saved serving configuration intact.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GB_EXECUTION_MODE=docker GETBIBLE_EXECUTION_MODE=docker
for lib in core config registry python pages; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
mkdir -p "$GB_LOG"
domain=search.example.test
ep_create "$domain" runtime search
for label in v2 v3 v4; do
    cfg_set "$(ep_version_conf "$domain" "$label")" ENABLED true
    ep_version_set "$domain" "$label" PYTHON_VERSION 3.12.1
done
ep_version_set "$domain" v3 PYTHON_VERSION 3.13.1
ep_version_set "$domain" v4 ENABLED false
ep_version_set "$domain" v4 PYTHON_VERSION 3.14.1
calls="$GB_PREFIX/applied"
FAIL_APPLY=false
MISSING_FAMILY=false
py_resolve_version() {
    case "$1" in
        3.12) printf '3.12.14\n' ;;
        3.13) [[ "$MISSING_FAMILY" != true ]] && printf '3.13.11\n' ;;
        *) return 1 ;;
    esac
}
endpoint_apply() {
    [[ "$GB_LOCAL_APPLY" == true && "$RT_FORCE_BUILD" == false && "$RT_FORCE_DEPLOY" == false ]]
    [[ "$(ep_version_get "$1" v2 PYTHON_VERSION)" == 3.12.14 ]]
    [[ "$(ep_version_get "$1" v3 PYTHON_VERSION)" == 3.13.11 ]]
    [[ "$(ep_version_get "$1" v4 PYTHON_VERSION)" == 3.14.1 ]]
    printf '%s\n' "$1" >> "$calls"
    [[ "$FAIL_APPLY" != true ]]
}

# Resolve all selections first: a missing later family cannot partially update
# an earlier endpoint, and disabled endpoints need no matching bundle.
MISSING_FAMILY=true
if rt_image_update "$domain"; then echo 'missing bundled family accepted' >&2; exit 1; fi
[[ ! -e "$calls" ]]
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.1 ]]
[[ "$(ep_version_get "$domain" v3 PYTHON_VERSION)" == 3.13.1 ]]
MISSING_FAMILY=false

# The deployment transaction owns live generations; restore registry choices
# whenever that transaction cannot commit the new image successfully.
FAIL_APPLY=true
if rt_image_update "$domain"; then echo 'failed image deployment accepted' >&2; exit 1; fi
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.1 ]]
[[ "$(ep_version_get "$domain" v3 PYTHON_VERSION)" == 3.13.1 ]]
FAIL_APPLY=false
rt_image_update "$domain"
[[ "$(ep_version_get "$domain" v2 PYTHON_VERSION)" == 3.12.14 ]]
[[ "$(ep_version_get "$domain" v3 PYTHON_VERSION)" == 3.13.11 ]]
[[ -z "${GB_LOCAL_APPLY:-}" && -z "${RT_FORCE_BUILD:-}" ]]

# A repeated refresh leaves existing hashes to determine whether work is needed.
rt_image_update "$domain"
[[ "$(wc -l < "$calls")" == 3 ]]
ep_set "$domain" ENABLED false
rt_image_update "$domain"
[[ "$(wc -l < "$calls")" == 3 ]]
printf 'Runtime image update checks passed\n'
