#!/usr/bin/env bash
# Durable configuration transactions. The manager lock serializes writers;
# public workers never read these journals or wait for configuration changes.
[[ -n "${GB_TRANSACTIONS_LOADED:-}" ]] && return 0
GB_TRANSACTIONS_LOADED=1

configuration_transaction_dir() { printf '%s/configuration-transactions/%s\n' "$GB_STATE" "$(gb_slug "$1")"; }

# An interrupted settings write is rolled back. Once the complete desired
# configuration reached deployment, preserve it for reconciliation: nginx may
# already be routing to a candidate, even if the active pointer was not saved.
# Never guess that this second case is an applied or rolled-back deployment.
configuration_transaction_recover() {
    local domain="$1" directory phase file
    [[ "$GB_DRY_RUN" != true ]] || return 0
    directory="$(configuration_transaction_dir "$domain")"
    [[ -d "$directory" ]] || return 0
    phase="$(cfg_get "$directory/state" PHASE preparing)"
    if [[ "$phase" == preparing ]]; then
        while IFS= read -r file; do
            [[ "$file" == "$(ep_conf "$domain")" || "$file" == "$(ep_versions_dir "$domain")/"*.conf ]] || {
                gb_warn "Invalid saved configuration transaction for $domain; nothing was restored."
                return 1
            }
            configuration_transaction_restore_file "$file" "$directory/files" || return 1
        done < "$directory/paths"
        gb_warn "Restored interrupted configuration preparation for $domain."
    elif [[ "$phase" == applying || "$phase" == recovery-required ]]; then
        ep_state_set "$domain" LAST_ERROR 'Interrupted configuration deployment; desired settings retained for reconciliation.' || return 1
        gb_warn "$domain has an interrupted deployment; its complete desired settings will be reconciled."
    elif [[ "$phase" != committed ]]; then
        gb_warn "Unknown configuration transaction phase for $domain; journal retained."
        return 1
    fi
    rm -rf -- "$directory" || return 1
    configuration_transaction_sync "$directory"
}

configuration_transaction_begin() {
    local domain="$1" directory stage file
    [[ "$GB_DRY_RUN" != true ]] || return 0
    configuration_transaction_recover "$domain" || return 1
    directory="$(configuration_transaction_dir "$domain")"
    gb_ensure_dir "${directory%/*}" 0700 || return 1
    stage="$(mktemp -d "${directory}.prepare.XXXXXXXX")" || return 1
    : > "$stage/paths" || return 1
    for file in "$(ep_conf "$domain")" "$(ep_versions_dir "$domain")/"*.conf; do
        [[ -f "$file" ]] || continue
        if ! gb_backup_file "$file" "$stage/files"; then rm -rf -- "$stage"; return 1; fi
        printf '%s\n' "$file" >> "$stage/paths" || return 1
    done
    cfg_set "$stage/state" PHASE preparing || return 1
    cfg_set "$stage/state" DOMAIN "$domain" || return 1
    configuration_transaction_sync "$stage" || return 1
    mv -T -- "$stage" "$directory" || return 1
    configuration_transaction_sync "$directory"
}

configuration_transaction_applying() {
    [[ "$GB_DRY_RUN" != true && -n "${GB_CONFIGURATION_TRANSACTION:-}" ]] || return 0
    cfg_set "$GB_CONFIGURATION_TRANSACTION/state" PHASE applying && configuration_transaction_sync "$GB_CONFIGURATION_TRANSACTION"
}

configuration_transaction_committed() {
    [[ -n "${GB_CONFIGURATION_TRANSACTION:-}" && "$GB_DRY_RUN" != true ]] || return 0
    cfg_set "$GB_CONFIGURATION_TRANSACTION/state" PHASE committed && configuration_transaction_sync "$GB_CONFIGURATION_TRANSACTION"
}

configuration_transaction_restore() {
    local directory="$1" file
    while IFS= read -r file; do
        configuration_transaction_restore_file "$file" "$directory/files" || return 1
    done < "$directory/paths"
    configuration_transaction_sync "$directory"
}

# Run a callback which writes settings, marks applying, then uses endpoint_apply.
# A subshell contains traps/transaction state, not a second implementation of
# deployment. The callback must check all writes, including under `if`/`!`.
configuration_transaction() (
    local domain="$1" status=0
    shift
    if [[ "$GB_DRY_RUN" == true ]]; then gb_log "(dry-run) would apply a configuration transaction for $domain"; return 0; fi
    configuration_transaction_begin "$domain" || return 1
    local GB_CONFIGURATION_TRANSACTION
    GB_CONFIGURATION_TRANSACTION="$(configuration_transaction_dir "$domain")"
    local EP_ORIGIN_COMMITTED=false EP_APPLY_EDGE_FAILED=false EP_RECOVERY_FAILED=false
    # An unexpected termination deliberately leaves a durable journal. The
    # next operation restores pre-deployment writes or retries complete intent.
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if "$@"; then status=0; else status=$?; fi
    if (( status == 0 )) || [[ "$EP_ORIGIN_COMMITTED" == true || "$EP_APPLY_EDGE_FAILED" == true ]]; then
        configuration_transaction_committed || return 1
        rm -rf -- "$GB_CONFIGURATION_TRANSACTION" || return 1
        configuration_transaction_sync "$GB_CONFIGURATION_TRANSACTION" || return 1
    elif [[ "$EP_RECOVERY_FAILED" == true ]]; then
        cfg_set "$GB_CONFIGURATION_TRANSACTION/state" PHASE recovery-required || return 1
        configuration_transaction_sync "$GB_CONFIGURATION_TRANSACTION" || return 1
        gb_warn "Routing recovery for $domain is incomplete; retaining desired settings and recovery journal."
    else
        if ! configuration_transaction_restore "$GB_CONFIGURATION_TRANSACTION"; then
            gb_warn "Configuration recovery for $domain failed; its journal is retained."
            return 1
        fi
        rm -rf -- "$GB_CONFIGURATION_TRANSACTION" || return 1
        configuration_transaction_sync "$GB_CONFIGURATION_TRANSACTION" || return 1
    fi
    return "$status"
)

# Persist the small journal (not application data) before entering deployment.
configuration_transaction_sync() {
    "$GB_PYTHON" - "$1" <<'PYFSYNC'
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = list(root.rglob("*"))
manifest = root / "paths"
if manifest.is_file():
    paths.extend(Path(value) for value in manifest.read_text().splitlines())
parents = {root / "files", root, root.parent}
for path in paths:
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as stream:
            os.fsync(stream.fileno())
        parents.add(path.parent)
for path in parents:
    if path.is_dir():
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
PYFSYNC
}

configuration_transaction_restore_file() {
    local file="$1" backup="$2" key temporary
    key="$(printf '%s' "$file" | tr '/' '_')"
    if [[ -f "$backup/$key.missing" ]]; then rm -f -- "$file"; return; fi
    [[ -f "$backup/$key" && ! -L "$backup/$key" ]] || return 1
    temporary="$(mktemp "${file}.restore.XXXXXXXX")" || return 1
    if ! cp -p -- "$backup/$key" "$temporary" || ! mv -fT -- "$temporary" "$file"; then
        rm -f -- "$temporary"
        return 1
    fi
}
