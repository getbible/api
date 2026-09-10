#!/usr/bin/env bash
# Reconciliation runs before the outer transaction and preserves its globals.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT"
for lib in core config registry resources; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
events="$GB_PREFIX/events"
: > "$events"
EP_DOMAIN=outer.example.test
resources_plan() {
    case "${1:-}/${2:-}" in
        '--format/reductions') [[ "$3" == --exclude-domain && "$4" == outer.example.test ]]; printf 'query.example.test\n' ;;
        '--wait-drain/query.example.test') printf 'drain\n' >> "$events" ;;
        *) printf 'Unexpected planner call: %s\n' "$*" >&2; return 1 ;;
    esac
}
endpoint_apply() {
    [[ "$GB_RESOURCE_RECONCILING" == true ]]
    resources_reconcile "$1" # recursion guard must avoid another plan/apply
    EP_DOMAIN="$1"
    printf 'apply %s\n' "$1" >> "$events"
}
resources_reconcile outer.example.test
[[ "$EP_DOMAIN" == outer.example.test ]]
[[ -d "$GB_TMP" ]]
[[ "$(cat "$events")" == $'apply query.example.test\ndrain' ]]
printf 'resource reconciliation preserves caller state and drains before continuing: ok\n'
