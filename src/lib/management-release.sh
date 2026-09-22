#!/usr/bin/env bash
# Immutable management code, bounded activation and compatible recovery.
[[ -n "${GB_MANAGEMENT_RELEASE_LOADED:-}" ]] && return 0
GB_MANAGEMENT_RELEASE_LOADED=1

management_release_root() { printf '%s/management\n' "$GB_OPT"; }
management_release() { "$GB_PYTHON" "$GB_TOOLS/getbible-management-release" "$@" --root "$(management_release_root)"; }
management_release_file() {
    if [[ -L "$(management_release_root)/current" || -n "${GB_MANAGEMENT_CANDIDATE:-}" ]]; then
        printf '%s/current/apps/dashboard/release.json\n' "$(management_release_root)"
    else
        printf '%s/apps/dashboard/release.json\n' "$GB_LIBEXEC"
    fi
}

dashboard_release_manifest() { management_release manifest --source "$GB_REPO_DIR"; }

management_release_prepare() {
    local current phase
    GB_MANAGEMENT_CODE_CHANGED=false
    GB_MANAGEMENT_ACTIVATED=false
    GB_MANAGEMENT_CANDIDATE=""
    [[ "$GB_DRY_RUN" != true ]] || { GB_MANAGEMENT_TEMPLATES="$GB_SRC/systemd"; return 0; }
    management_release recover --db "$GB_VAR/telemetry/traffic.sqlite3" --systemd "$GB_SYSTEMD" || return 1
    current="$(management_release current)" || return 1
    if [[ -z "$current" ]]; then
        current="$(management_release capture --libexec "$GB_LIBEXEC" --systemd "$GB_SYSTEMD")" || return 1
    fi
    # Restoration uses the persisted release. A replacement image must not
    # overwrite running-service code before its post-boot upgrade transaction.
    if [[ "${GB_CONTAINER_BOOTSTRAP:-false}" == true && -n "$current" ]]; then
        GB_MANAGEMENT_CANDIDATE="$current"
        management_release validate --candidate "$current" >/dev/null || return 1
    else
        GB_MANAGEMENT_CANDIDATE="$(management_release stage --source "$GB_REPO_DIR")" || return 1
    fi
    GB_MANAGEMENT_TEMPLATES="$GB_MANAGEMENT_CANDIDATE/templates"
    [[ "$current" == "$GB_MANAGEMENT_CANDIDATE" ]] || GB_MANAGEMENT_CODE_CHANGED=true
    phase="$(management_release status | "$GB_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("phase", "pending"))')" || return 1
    [[ "$phase" == current ]] || GB_MANAGEMENT_CODE_CHANGED=true
}

management_release_activate() {
    local helper target temporary
    [[ "$GB_DRY_RUN" != true ]] || return 0
    management_release select --candidate "$GB_MANAGEMENT_CANDIDATE" --systemd "$GB_SYSTEMD" >/dev/null || return 1
    GB_MANAGEMENT_ACTIVATED=true
    # These small launcher links are replaced atomically. The launchers resolve
    # their real path before imports, so old processes keep their own packages.
    for helper in getbible-admin-broker getbible-dashboard getbible-telemetry getbible-runtime-control getbible-adapt getbible-resources getbible-storage-guard; do
        target="$(management_release_root)/current/bin/$helper"
        temporary="$(mktemp "$GB_LIBEXEC/.management-link.XXXXXXXX")" || return 1
        rm -f -- "$temporary" || return 1
        if ! ln -s -- "$target" "$temporary" || ! mv -fT -- "$temporary" "$GB_LIBEXEC/$helper"; then
            rm -f -- "$temporary"
            return 1
        fi
    done
    # Fresh installations retain the historical inspection path. Existing
    # package directories stay untouched for pre-adoption processes.
    if [[ ! -e "$GB_LIBEXEC/apps" && ! -L "$GB_LIBEXEC/apps" ]]; then
        ln -s -- "$(management_release_root)/current/apps" "$GB_LIBEXEC/apps" || return 1
    fi
}

management_release_recover() {
    local telemetry="$1" dashboard="$2" admin="$3" restored=false
    [[ "$GB_DRY_RUN" != true && "${GB_MANAGEMENT_ACTIVATED:-false}" == true && "${GB_MANAGEMENT_CODE_CHANGED:-false}" == true ]] || return 0
    if management_release rollback --db "$GB_VAR/telemetry/traffic.sqlite3" --systemd "$GB_SYSTEMD"; then
        restored=true
        sd_daemon_reload || return 1
        infrastructure_environment || return 1
        [[ "$telemetry" != true ]] || sd_restart getbible-telemetry.service || return 1
        [[ "$dashboard" != true ]] || sd_restart getbible-dashboard.service || return 1
        # Never kill the broker while its own update job is still running.
        if [[ "$admin" == true ]]; then
            "$GB_SYSTEMCTL" kill --kill-who=main --signal=SIGUSR1 getbible-admin.service || return 1
        fi
    fi
    if [[ "$restored" != true ]]; then
        gb_warn 'Compatible management rollback is unavailable. History and public API generations are retained; inspect management release status and retry forward recovery.'
        return 1
    fi
}

infrastructure_install() {
    local unit stage python template
    GB_INFRASTRUCTURE_TELEMETRY_FAILED=false
    GB_TELEMETRY_START_FAILED=false
    GB_REPORTING_COLLECTOR_STOPPED=false
    gb_ensure_group getbible-dashboard || return 1
    gb_ensure_system_user getbible-dashboard "$GB_NGINX_USER" "$GB_VAR/dashboard" "getbible-dashboard,$GB_NOTIFY_GROUP" || return 1
    gb_ensure_dir "$GB_VAR/dashboard" 0700 getbible-dashboard:getbible-dashboard || return 1
    gb_ensure_dir "$GB_VAR/admin" 0700 root:root || return 1
    gb_ensure_dir "$GB_VAR/imports" 0750 root:root || return 1
    gb_ensure_dir "$GB_VAR/telemetry" 02750 root:getbible-dashboard || return 1
    infrastructure_reporting_permissions || return 1
    gb_ensure_dir "$GB_VAR/storage" 02770 "root:$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$GB_LOG/dashboard" 0750 root:getbible-dashboard || return 1
    gb_ensure_dir "$GB_LOG/dashboard/app" 0750 getbible-dashboard:getbible-dashboard || return 1
    gb_ensure_dir "$GB_LOG/management" 0750 root:getbible-dashboard || return 1
    gb_ensure_dir "$GB_LOG/management/app" 0750 root:getbible-dashboard || return 1
    gb_ensure_dir "$GB_LIBEXEC" 0755 || return 1
    management_release_prepare || return 1
    infrastructure_environment || return 1
    stage="$(gb_tmpdir)/infrastructure-units"
    rm -rf -- "$stage" || return 1
    gb_ensure_dir "$stage" 0755 || return 1
    python="$(command -v "$GB_PYTHON")" || return 1
    # Render everything before selecting code or touching installed units.
    for unit in getbible-prepare.service getbible-admin.service getbible-dashboard.service getbible-telemetry.service getbible-adapt.service getbible-adapt.timer getbible-storage.service getbible-storage.timer getbible-alert@.service; do
        template="$GB_MANAGEMENT_TEMPLATES/$unit.tmpl"
        [[ -f "$template" ]] || template="$GB_SRC/systemd/$unit.tmpl"
        gb_render "$template" "$stage/$unit" \
            "PYTHON=$python" "PREFIX=$GB_PREFIX" "ETC=$GB_ETC" "VAR=$GB_VAR" "LOG=$GB_LOG" "RUN=$GB_RUN" \
            "OPT=$GB_OPT" "SRV=$GB_SRV" "CACHE=$GB_CACHE" "LIBEXEC=$GB_LIBEXEC" "MANAGER=$GB_SELF" \
            "MANAGEMENT_RELEASE=${GB_MANAGEMENT_CANDIDATE:-$GB_LIBEXEC}" \
            "SYSTEMCTL=$GB_SYSTEMCTL" "NGINX_USER=$GB_NGINX_USER" "NOTIFY_GROUP=$GB_NOTIFY_GROUP" "READERS_GROUP=$GB_READERS_GROUP" || return 1
    done
    management_release_activate || return 1
    for unit in "$stage/"*; do sd_install_unit "$unit" "$(basename -- "$unit")" || return 1; done
    if gb_is_docker; then
        unit=getbible-image-update.service
        gb_render "$GB_SRC/systemd/$unit.tmpl" "$stage/$unit" "MANAGER=$GB_SELF" || return 1
        sd_install_unit "$stage/$unit" "$unit" || return 1
        sd_enable "$unit" || return 1
    fi
    sd_daemon_reload || return 1
    infrastructure_storage_initial_sample || return 1
    infrastructure_reporting_prepare || return 1
    if sd_available && [[ "$GB_DRY_RUN" != true ]]; then
        "$GB_SYSTEMCTL" reset-failed getbible-telemetry.service getbible-dashboard.service getbible-admin.service || return 1
    fi
    if ! sd_enable --now getbible-telemetry.service; then
        GB_TELEMETRY_START_FAILED=true
        gb_warn 'Telemetry could not start. Public APIs remain available; dashboard repair continues.'
    fi
    sd_enable --now getbible-adapt.timer getbible-storage.timer || return 1
    if [[ "$(gb_global DASHBOARD_ENABLED false)" == true && -n "$(dashboard_domain)" ]]; then
        sd_enable --now getbible-admin.service getbible-dashboard.service || return 1
    fi
}

infrastructure_reporting_prepare() {
    local unit status=0 output schema expected timer_active=false
    local -a stopped=()
    export GB_REPORTING_PREPARED=false
    [[ "${GB_CONTAINER_BOOTSTRAP:-false}" != true || "$GB_DRY_RUN" == true ]] || return 0
    [[ "$GB_DRY_RUN" != true ]] || return 0
    output="$(gb_tmpdir)/telemetry-prepare.json"
    schema="$(management_release schema --db "$GB_VAR/telemetry/traffic.sqlite3")" || {
        GB_INFRASTRUCTURE_TELEMETRY_FAILED=true
        return 1
    }
    expected="$("$GB_PYTHON" - "$(management_release_root)/current/manifest.json" <<'PYSCHEMA'
import json, sys
print(json.load(open(sys.argv[1]))['telemetry_schema'])
PYSCHEMA
)" || return 1
    # No migration means no service stop, backup, or duplicate restart.
    if [[ "$schema" == "$expected" ]]; then GB_REPORTING_PREPARED=true; return 0; fi
    if (( schema > expected )); then
        GB_INFRASTRUCTURE_TELEMETRY_FAILED=true
        gb_warn "History schema $schema is newer than management schema $expected; history remains untouched."
        return 1
    fi
    if sd_available; then
        for unit in getbible-logrotate.timer getbible-logrotate.service getbible-telemetry.service; do
            [[ -f "$GB_SYSTEMD/$unit" ]] || continue
            stopped+=("$unit")
            if [[ "$unit" == getbible-logrotate.timer ]] && sd_is_active "$unit"; then timer_active=true; fi
        done
        if (( ${#stopped[@]} )); then "$GB_SYSTEMCTL" stop "${stopped[@]}" || status=1; fi
        GB_REPORTING_COLLECTOR_STOPPED=true
    fi
    # Read-only dashboard connections can finish their WAL snapshots. Keep the
    # dashboard available while the collector performs its compatible migration.
    if (( status == 0 )); then
        "$GB_PYTHON" "$GB_LIBEXEC/getbible-telemetry" prepare \
            --db "$GB_VAR/telemetry/traffic.sqlite3" --backup-dir "$GB_BACKUPS/telemetry" \
            --backup-seconds "$(gb_global TELEMETRY_BACKUP_SECONDS 900)" \
            --migration-seconds "$(gb_global TELEMETRY_MIGRATION_SECONDS 900)" > "$output" || status=1
        infrastructure_reporting_permissions || status=1
    fi
    [[ "$timer_active" != true ]] || sd_start getbible-logrotate.timer || status=1
    if (( status != 0 )); then
        GB_INFRASTRUCTURE_TELEMETRY_FAILED=true
        gb_warn 'Reporting preparation failed. History is preserved; independent API upgrades may continue.'
    else
        GB_REPORTING_PREPARED=true
    fi
    return "$status"
}

infrastructure_update() {
    local telemetry_active=false dashboard_active=false admin_active=false status=0
    GB_INFRASTRUCTURE_TELEMETRY_FAILED=false
    if sd_is_active getbible-telemetry.service; then telemetry_active=true; fi
    if sd_is_active getbible-dashboard.service; then dashboard_active=true; fi
    if sd_is_active getbible-admin.service; then admin_active=true; fi
    if ! infrastructure_install; then
        management_release_recover "$telemetry_active" "$dashboard_active" "$admin_active" || true
        return 1
    fi
    [[ "$GB_DRY_RUN" != true ]] || return 0
    if [[ "${GB_MANAGEMENT_CODE_CHANGED:-false}" == true ]]; then
        # A schema migration already stopped and started the collector once.
        if [[ "$telemetry_active" == true && "${GB_REPORTING_COLLECTOR_STOPPED:-false}" != true ]] && ! sd_restart getbible-telemetry.service; then
            GB_TELEMETRY_START_FAILED=true
        fi
        [[ "$dashboard_active" != true ]] || sd_restart getbible-dashboard.service || status=1
    fi
    if [[ "$dashboard_active" == true || "$(gb_global DASHBOARD_ENABLED false)" == true ]]; then
        dashboard_wait_current || status=1
    fi
    if (( status != 0 )); then
        management_release_recover "$telemetry_active" "$dashboard_active" "$admin_active" || true
        return 1
    fi
    if [[ "$admin_active" == true && "${GB_MANAGEMENT_CODE_CHANGED:-false}" == true ]]; then
        "$GB_SYSTEMCTL" kill --kill-who=main --signal=SIGUSR1 getbible-admin.service || return 1
    fi
    if [[ "${GB_TELEMETRY_START_FAILED:-false}" == true ]]; then
        GB_INFRASTRUCTURE_TELEMETRY_FAILED=true
        management_release finish --status degraded --detail 'Collector failed; public API updates remain independent' || return 1
        [[ "${1:-}" == --dashboard ]] && return 0
        return 1
    fi
    management_release finish --status current
}
