#!/usr/bin/env bash
# Configuration durability is independent of runtime kind and failure location.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GB_PREFIX="$(mktemp -d)" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core config registry transactions; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf -- "$GB_PREFIX"' EXIT
mkdir -p "$GB_LOG"
domain=service.example.test
ep_create "$domain" runtime query
for label in v2 v3; do
    ep_version_set "$domain" "$label" ENABLED true
    ep_version_set "$domain" "$label" PYTHON_VERSION 3.12.1
done
before="$(cat "$(ep_version_conf "$domain" v2)")"
check() { "$@" || { printf 'FAILED: %s\n' "$*" >&2; exit 1; }; }
# All failure positions restore exact original bytes and clean the transaction.
apply() {
    ep_version_set "$domain" v2 PYTHON_VERSION 3.12.14 || return 1
    [[ "$failure" != prepare ]] || return 1
    configuration_transaction_applying || return 1
    [[ "$failure" != deployment ]] || return 1
    if [[ "$failure" == edge ]]; then EP_APPLY_EDGE_FAILED=true; return 1; fi
    if [[ "$failure" == committed ]]; then EP_ORIGIN_COMMITTED=true; return 1; fi
    return 0
}
for failure in prepare deployment; do
    if configuration_transaction "$domain" apply; then echo 'rejected work accepted' >&2; exit 1; fi
    check test "$(cat "$(ep_version_conf "$domain" v2)")" = "$before"
    check test ! -e "$(configuration_transaction_dir "$domain")"
done
# Once the origin committed, a later error must not restore older intent.
for failure in edge committed; do
    if configuration_transaction "$domain" apply; then echo 'edge failure hidden' >&2; exit 1; fi
    check test "$(ep_version_get "$domain" v2 PYTHON_VERSION)" = 3.12.14
    check test ! -e "$(configuration_transaction_dir "$domain")"
    ep_version_set "$domain" v2 PYTHON_VERSION 3.12.1
done
# Dry runs never call a settings writer, even if it lacks its own dry-run guard.
failure=prepare
GB_DRY_RUN=true configuration_transaction "$domain" apply
check test "$(cat "$(ep_version_conf "$domain" v2)")" = "$before"
# Simulate termination in preparation: durable original settings are restored.
configuration_transaction_begin "$domain"
ep_version_set "$domain" v2 PYTHON_VERSION 3.12.14
configuration_transaction_recover "$domain"
check test "$(cat "$(ep_version_conf "$domain" v2)")" = "$before"
# An ambiguous traffic switch must retain complete intent, not guess rollback.
configuration_transaction_begin "$domain"
ep_version_set "$domain" v2 PYTHON_VERSION 3.12.14
GB_CONFIGURATION_TRANSACTION="$(configuration_transaction_dir "$domain")" configuration_transaction_applying
configuration_transaction_recover "$domain"
check test "$(ep_version_get "$domain" v2 PYTHON_VERSION)" = 3.12.14
check test -n "$(ep_state_get "$domain" LAST_ERROR)"
# Refuse unexpected journal phases instead of discarding recovery evidence.
configuration_transaction_begin "$domain"
cfg_set "$(configuration_transaction_dir "$domain")/state" PHASE invalid
if configuration_transaction_recover "$domain"; then echo 'invalid phase accepted' >&2; exit 1; fi
check test -d "$(configuration_transaction_dir "$domain")"
printf 'Configuration transaction failure and recovery checks passed\n'
