#!/usr/bin/env bash
# Durable configuration transactions shared by runtime and MCP updates.
[[ -n "${GB_TRANSACTIONS_LOADED:-}" ]] && return 0
GB_TRANSACTIONS_LOADED=1

configuration_transaction_dir() { printf '%s/configuration-transactions/%s\n' "$GB_STATE" "$(gb_slug "$1")"; }

configuration_transaction_sync() {
    "$GB_PYTHON" - "$1" <<'PY'
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = list(root.rglob('*'))
manifest = root / 'paths'
if manifest.is_file():
    paths.extend(Path(value) for value in manifest.read_text().splitlines())
for path in paths:
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            os.fsync(stream.fileno())
for path in [*reversed(sorted((p for p in root.rglob('*') if p.is_dir()), key=lambda p: len(p.parts))), root, root.parent]:
    if not path.is_dir():
        continue
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

# Journal updates belong only to the outer domain transaction, never to a
# different domain that resource reconciliation happens to apply first.
configuration_transaction_phase() {
    local domain="$1" phase="$2" journal="${GB_CONFIGURATION_TRANSACTION:-}"
    [[ -n "$journal" && -f "$journal/state" ]] || return 0
    [[ "$(cfg_get "$journal/state" DOMAIN)" == "$domain" ]] || return 0
    cfg_set "$journal/state" PHASE "$phase" || return 1
    configuration_transaction_sync "$journal"
}

configuration_transaction_restore() {
    local journal="$1" which="$2" path index=0 failed=0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ -f "$journal/$which/$index" ]]; then
            gb_install_file "$journal/$which/$index" "$path" "$(stat -c %a "$journal/$which/$index")" || failed=1
        else
            failed=1
        fi
        index=$((index + 1))
    done < "$journal/paths"
    return "$failed"
}

configuration_transaction_recover() {
    local domain="$1" journal phase path status=0
    journal="$(configuration_transaction_dir "$domain")"
    [[ -f "$journal/state" ]] || return 0
    phase="$(cfg_get "$journal/state" PHASE)"
    while IFS= read -r path; do
        case "$path" in "$(ep_conf "$domain")"|"$(ep_versions_dir "$domain")/"*.conf) ;; *) gb_warn 'Invalid configuration journal path; retaining evidence.'; return 1 ;; esac
    done < "$journal/paths"
    case "$phase" in
        preparing|applying|restoring)
            configuration_transaction_restore "$journal" before || { gb_warn "Configuration recovery is incomplete for $domain; retained journal: $journal"; return 1; }
            gb_warn "Recovered the interrupted pre-switch configuration transaction for $domain."
            ;;
        switching)
            # An interrupted nginx switch is ambiguous. Complete the saved
            # intended configuration through the normal readiness/drain path,
            # rather than guessing that none of the new workers received traffic.
            configuration_transaction_restore "$journal" after || return 1
            [[ "${GB_CONTAINER_BOOTSTRAP:-false}" != true ]] || return 0
            local GB_CONFIGURATION_TRANSACTION="$journal" GB_LOCAL_APPLY=true
            EP_ORIGIN_COMMITTED=false
            endpoint_apply "$domain" || status=$?
            if (( status != 0 )) && [[ "${EP_APPLY_RECOVERY_SAFE:-true}" != true ]]; then
                gb_warn "Routing recovery is pending; retaining the intended configuration and journal: $journal"
                return 1
            fi
            if (( status != 0 )) && [[ "${EP_ORIGIN_COMMITTED:-false}" != true ]]; then
                gb_warn "Interrupted switch for $domain remains pending; its serving generations are retained. Retry this domain update."
                return 1
            fi
            ;;
        origin-committed) : ;;
        *) gb_warn "Unrecognized configuration transaction for $domain; retained journal: $journal"; return 1 ;;
    esac
    # Persist restored/committed registry bytes before forgetting recovery
    # evidence. A power failure may not turn a successful rollback into drift.
    configuration_transaction_sync "$journal" || return 1
    rm -rf -- "$journal" || return 1
    tg_notify warn "Configuration recovered: $domain" 'An interrupted configuration transaction was reconciled without resetting data.'
}

# Resolve and validate the complete desired selection before calling begin.
# All paths are internal registry records, never arbitrary operator arguments.
configuration_transaction_begin() {
    local domain="$1" path journal stage index=0
    shift
    if (( $# == 0 )); then set -- "$(ep_conf "$domain")" "$(ep_versions_dir "$domain")/"*.conf; fi
    [[ "$GB_DRY_RUN" != true ]] || { GB_CONFIGURATION_TRANSACTION=""; return 0; }
    configuration_transaction_recover "$domain" || return 1
    journal="$(configuration_transaction_dir "$domain")"
    gb_ensure_dir "${journal%/*}" 0700 || return 1
    stage="$(mktemp -d "${journal%/*}/.prepare.XXXXXXXX")" || return 1
    mkdir "$stage/before" "$stage/after" || { rm -rf -- "$stage"; return 1; }
    : > "$stage/paths"
    for path in "$@"; do
        [[ -f "$path" ]] || continue
        case "$path" in "$(ep_dir "$domain")"/*) ;; *) rm -rf -- "$stage"; gb_warn 'A configuration transaction received a non-registry path.'; return 1 ;; esac
        if [[ ! -f "$path" ]] || ! cp -pL -- "$path" "$stage/before/$index"; then rm -rf -- "$stage"; return 1; fi
        printf '%s\n' "$path" >> "$stage/paths" || { rm -rf -- "$stage"; return 1; }
        index=$((index + 1))
    done
    printf 'DOMAIN=%s\nPHASE=preparing\n' "$domain" > "$stage/state" || { rm -rf -- "$stage"; return 1; }
    configuration_transaction_sync "$stage" || { rm -rf -- "$stage"; return 1; }
    mv -T -- "$stage" "$journal" || return 1
    GB_CONFIGURATION_TRANSACTION="$journal"
    configuration_transaction_sync "$journal"
}

configuration_transaction_prepared() {
    local domain="$1" path index=0 journal="${GB_CONFIGURATION_TRANSACTION:-}"
    [[ -n "$journal" ]] || return 0
    while IFS= read -r path; do
        cp -pL -- "$path" "$journal/after/$index" || return 1
        index=$((index + 1))
    done < "$journal/paths"
    configuration_transaction_phase "$domain" applying
}

configuration_transaction_finish() {
    local status="$1" journal="${GB_CONFIGURATION_TRANSACTION:-}"
    [[ -n "$journal" ]] || return "$status"
    if (( status != 0 )) && [[ "${EP_APPLY_RECOVERY_SAFE:-true}" != true ]]; then
        gb_warn "Routing recovery is pending; retaining the intended configuration and journal: $journal"
        return 1
    fi
    if (( status != 0 )) && [[ "${EP_ORIGIN_COMMITTED:-false}" != true && "${EP_APPLY_EDGE_FAILED:-false}" != true ]]; then
        cfg_set "$journal/state" PHASE restoring || return 1
        if ! configuration_transaction_restore "$journal" before; then
            gb_warn "Saved configuration could not be fully restored; retained transaction: $journal"
            return 1
        fi
    fi
    # Persist restored/committed registry bytes before forgetting recovery
    # evidence. A power failure may not turn a successful rollback into drift.
    configuration_transaction_sync "$journal" || return 1
    rm -rf -- "$journal" || return 1
    return "$status"
}

# Callback interface retained for all existing callers. The same journal and
# recovery implementation is used by explicit and automatic update paths.
configuration_transaction_applying() {
    [[ -n "${GB_CONFIGURATION_TRANSACTION:-}" ]] || return 0
    configuration_transaction_prepared "$(cfg_get "$GB_CONFIGURATION_TRANSACTION/state" DOMAIN)"
}

configuration_transaction_committed() {
    [[ -n "${GB_CONFIGURATION_TRANSACTION:-}" ]] || return 0
    configuration_transaction_phase "$(cfg_get "$GB_CONFIGURATION_TRANSACTION/state" DOMAIN)" origin-committed
}

configuration_transaction() (
    local domain="$1" status=0 GB_CONFIGURATION_TRANSACTION=""
    local EP_ORIGIN_COMMITTED=false EP_APPLY_EDGE_FAILED=false EP_APPLY_RECOVERY_SAFE=true EP_RECOVERY_FAILED=false
    shift
    [[ "$GB_DRY_RUN" != true ]] || { gb_log "Would apply a configuration transaction for $domain."; return 0; }
    configuration_transaction_begin "$domain" || return 1
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@" || status=$?
    [[ "$EP_RECOVERY_FAILED" != true ]] || EP_APPLY_RECOVERY_SAFE=false
    configuration_transaction_finish "$status"
)
