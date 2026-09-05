#!/usr/bin/env bash
# Retire the legacy setup: server blocks for our domains inside other nginx
# files (typically sites-available/default) and the old query service.

[[ -n "${GB_MIGRATE_LOADED:-}" ]] && return 0
GB_MIGRATE_LOADED=1

GB_LEGACY_UNITS=(query_getbible.service query-getbible.service search-getbible.service)

# Files, other than ours, declaring any registered domain.
migrate_conflicting_files() {
    local domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        nginx_conflicts "$domain"
    done < <(ep_list) | sort -u
}

migrate_legacy_units() {
    local unit
    for unit in "${GB_LEGACY_UNITS[@]}"; do
        [[ -f "$GB_SYSTEMD/$unit" || -f "$GB_PREFIX/lib/systemd/system/$unit" ]] && printf '%s\n' "$unit"
    done
    return 0
}

migrate_report() {
    local files units
    files="$(migrate_conflicting_files)"
    units="$(migrate_legacy_units)"
    printf 'Legacy nginx files declaring registered domains:\n%s\n\n' "${files:-  none}"
    printf 'Legacy service units:\n%s\n' "${units:-  none}"
}

# migrate_legacy: strip our domains out of foreign nginx files (backed up),
# stop and remove the legacy units, test and reload nginx.
migrate_legacy() {
    local files units file domains stage backup_set unit changed=false
    files="$(migrate_conflicting_files)"
    units="$(migrate_legacy_units)"
    if [[ -z "$files" && -z "$units" ]]; then
        gb_log "Nothing to migrate."
        return 0
    fi
    domains="$(ep_list | tr '\n' ' ')"
    backup_set="$(gb_new_backup_set migrate)"
    while read -r file; do
        [[ -n "$file" && -f "$file" ]] || continue
        stage="$(gb_tmpdir)/strip-$(basename "$file")"
        # shellcheck disable=SC2086
        if "$GB_PYTHON" "$GB_TOOLS/getbible-nginx-strip" "$file" $domains > "$stage"; then
            gb_backup_file "$file" "$backup_set"
            if [[ -s "$stage" ]] && grep -q '[^[:space:]]' "$stage"; then
                gb_install_file "$stage" "$file" 0644
                gb_log "Removed our server blocks from $file (backup in $backup_set)"
            else
                rm -f -- "$file"
                [[ -L "$GB_NGINX/sites-enabled/$(basename "$file")" ]] && rm -f -- "$GB_NGINX/sites-enabled/$(basename "$file")"
                gb_log "Removed $file entirely; it held nothing but our server blocks (backup in $backup_set)"
            fi
            changed=true
        fi
    done <<< "$files"
    if [[ "$changed" == true ]]; then
        if ! nginx_test; then
            gb_warn "nginx rejected the stripped configuration; restoring backups."
            while read -r file; do [[ -n "$file" ]] && gb_restore_file "$file" "$backup_set"; done <<< "$files"
            nginx_test || true
            return 1
        fi
        nginx_reload
    fi
    while read -r unit; do
        [[ -n "$unit" ]] || continue
        gb_step "Retiring $unit"
        sd_disable_now "$unit"
        [[ -f "$GB_SYSTEMD/$unit" ]] && { gb_backup_file "$GB_SYSTEMD/$unit" "$backup_set"; rm -f -- "$GB_SYSTEMD/$unit"; }
        rm -rf -- "$GB_SYSTEMD/$unit.d"
        changed=true
    done <<< "$units"
    sd_daemon_reload
    tg_notify ok "Legacy setup retired" "Old nginx server blocks and units were removed; backups in $backup_set."
    gb_log "Migration complete. The old application folders were left in place."
}

migrate_interactive() {
    local report
    report="$(gb_tmpdir)/migrate-report"
    migrate_report > "$report"
    ui_textbox "Legacy setup" "$report"
    ui_yesno "Migrate" "Remove the legacy server blocks and units listed? Backups are kept and nginx is tested before reload." no || return 0
    ui_run "Migrate" migrate_legacy
}
