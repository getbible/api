#!/usr/bin/env bash
# Deployment configuration shared by the interactive manager and systemd jobs.
[[ -n "${GB_DEPLOYMENT_LOADED:-}" ]] && return 0
GB_DEPLOYMENT_LOADED=1

gb_environment_keys() {
    local entry
    for entry in "${GB_GLOBAL_DEFAULTS[@]}"; do
        [[ "$entry" == GB_SCHEMA=* ]] || printf '%s\n' "${entry%%=*}"
    done
    printf '%s\n' CLOUDFLARE_API_TOKEN TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_HOSTNAME
}

gb_environment_file() {
    case "$1" in
        CLOUDFLARE_API_TOKEN) printf '%s\n' "$GB_CLOUDFLARE_CONF" ;;
        TELEGRAM_*) printf '%s\n' "$GB_TELEGRAM_CONF" ;;
        *) printf '%s\n' "$GB_GLOBAL_CONF" ;;
    esac
}

gb_environment_direct() {
    local key="$1" name="GETBIBLE_$1" file_name="GETBIBLE_${1}_FILE" value=""
    if [[ -n "${!file_name:-}" ]]; then
        [[ -z "${!name:-}" ]] || { gb_warn "Set $name or $file_name, not both."; return 2; }
        case "$key" in CLOUDFLARE_API_TOKEN|TELEGRAM_BOT_TOKEN) ;; *) gb_warn "$file_name is not supported."; return 2 ;; esac
        [[ -r "${!file_name}" ]] || { gb_warn "$file_name does not name a readable file."; return 2; }
        value="$(cat -- "${!file_name}")" || return 2
    elif [[ -n "${!name:-}" ]]; then
        value="${!name}"
    else
        return 1
    fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { gb_warn "$name must contain one line."; return 2; }
    printf '%s\n' "$value"
}

# cfg_get calls this only for the three configuration files we manage. The
# captured /run copy makes the same effective values available to systemd jobs
# without giving any service the container's entire environment.
gb_environment_get() {
    local file="$1" key="$2" value status
    [[ "$file" == "$GB_GLOBAL_CONF" || "$file" == "$GB_TELEGRAM_CONF" || "$file" == "$GB_CLOUDFLARE_CONF" ]] || return 1
    [[ "$file" == "$(gb_environment_file "$key")" ]] || return 1
    if value="$(gb_environment_direct "$key")"; then printf '%s\n' "$value"; return 0; else status=$?; fi
    (( status == 1 )) || return "$status"
    if gb_is_docker && [[ -f "$GB_ENVIRONMENT_CONF" ]]; then
        value="$(cfg_get_raw "$GB_ENVIRONMENT_CONF" "$key" __getbible_unset__)"
        if [[ "$value" != __getbible_unset__ ]]; then printf '%s\n' "$value"; return 0; fi
    fi
    return 1
}

gb_environment_managed() { gb_environment_get "$1" "$2" >/dev/null; }

gb_setting_validate() {
    local key="$1" value="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { gb_warn "$key must contain one line."; return 1; }
    case "$key" in
        TLS_MODE) [[ "$value" == managed || "$value" == external ]] ;;
        PUBLIC_SCHEME) [[ "$value" == https ]] ;;
        ORIGIN_HTTP_PORT) [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )) ;;
        MEMORY_BUDGET|QUERY_MEMORY_MAX|SEARCH_MEMORY_MAX) [[ "$value" =~ ^(auto|[1-9][0-9]*([kKmMgGtT]([iI]?[bB])?)?)$ ]] ;;
        QUERY_MEMORY_MIN|SEARCH_MEMORY_MIN) [[ "$value" =~ ^[1-9][0-9]*([kKmMgGtT]([iI]?[bB])?)?$ ]] ;;
        RESOURCE_RESERVE_PERCENT) [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 5 && 10#$value <= 75 )) ;;
        DEFAULT_DEPLOY_MODE) [[ "$value" == live || "$value" == staged ]] ;;
        CERT_METHOD) [[ "$value" == auto || "$value" == http || "$value" == dns-cloudflare ]] ;;
        CERTBOT_EMAIL) [[ -z "$value" ]] || certs_valid_email "$value" ;;
        DEFAULT_ACCESS_MODE) [[ "$value" == open || "$value" == metered || "$value" == token ]] ;;
        DEFAULT_CLOUDFLARE_MODE) [[ "$value" == off || "$value" == dns || "$value" == proxied ]] ;;
        DEFAULT_CLOUDFLARE_CACHE) [[ "$value" == bypass || "$value" == respect ]] ;;
        DEFAULT_CLOUDFLARE_FEATURES) [[ "$value" == free || "$value" == paid ]] ;;
        HSTS_INCLUDE_SUBDOMAINS|CLOUDFLARE_ENABLED|TELEGRAM_ENABLED|ADAPTIVE_RESOURCES|ADAPTIVE_ALLOW_IDLE_SHRINK|DASHBOARD_ENABLED) [[ "$value" == true || "$value" == false ]] ;;
        DEFAULT_SYNC_SCHEDULE) [[ "$value" == daily || "$value" == weekly || "$value" == monthly ]] ;;
        DEFAULT_EXTENSIONS) [[ "$value" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]] ;;
        DEFAULT_QUERY_WORKERS|DEFAULT_SEARCH_WORKERS)
            [[ "$value" == auto ]] || { [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 1 && 10#$value <= 64 )); } ;;
        DEFAULT_QUERY_THREADS|DEFAULT_SEARCH_THREADS|QUERY_WORKERS_MIN|QUERY_WORKERS_MAX|SEARCH_WORKERS_MIN|SEARCH_WORKERS_MAX|QUERY_THREADS_MIN|QUERY_THREADS_MAX|SEARCH_THREADS_MIN|SEARCH_THREADS_MAX)
            [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 1 && 10#$value <= 64 )) ;;
        QUERY_CPU_QUOTA|SEARCH_CPU_QUOTA)
            [[ "$value" == auto ]] || { [[ "$value" =~ ^[0-9]{1,6}(\.[0-9]{1,3})?%$ ]] && [[ "${value//[0.%]/}" =~ [1-9] ]]; } ;;
        MEMORY_CACHE_TTL|DEFAULT_QUERY_CACHE_TTL|DEFAULT_SEARCH_CACHE_TTL)
            [[ "$value" =~ ^[0-9]{1,8}$ ]] && (( 10#$value <= 31536000 )) ;;
        CACHE_TTL_JITTER) [[ "$value" =~ ^0(\.[0-9]+)?$ ]] ;;
        SHARED_CORPUS_LIMIT|TRANSLATION_CACHE_LIMIT)
            [[ "$value" =~ ^[0-9]{1,6}$ ]] && (( 10#$value >= 1 && 10#$value <= 100000 )) ;;
        CHAPTER_CACHE_LIMIT|REFERENCE_CACHE_LIMIT)
            [[ "$value" =~ ^[0-9]{1,7}$ ]] && (( 10#$value >= 1 && 10#$value <= 1000000 )) ;;
        QUERY_WARM_TRANSLATIONS|SEARCH_WARM_TRANSLATIONS) [[ -z "$value" || "$value" =~ ^[a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*$ ]] ;;
        CACHE_MEMORY_PERCENT)
            [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 5 && 10#$value <= 80 )) ;;
        ADAPTIVE_HIGH_PERCENT|ADAPTIVE_LOW_PERCENT|ALERT_CPU_PERCENT|ALERT_MEMORY_PERCENT|ALERT_DISK_PERCENT|ALERT_MEMORY_PRESSURE_PERCENT)
            [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 1 && 10#$value <= 95 )) ;;
        TELEMETRY_BATCH_SIZE)
            [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#$value <= 100000 )) ;;
        TELEMETRY_BACKUP_SECONDS|TELEMETRY_MIGRATION_SECONDS)
            [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$value <= 86400 )) ;;
        ADAPTIVE_INTERVAL|ADAPTIVE_COOLDOWN|ADAPTIVE_SUSTAINED_SAMPLES|TELEMETRY_FLUSH_SECONDS|TELEMETRY_METRICS_SECONDS)
            [[ "$value" =~ ^[1-9][0-9]{0,7}$ ]] ;;
        TELEMETRY_RETENTION_DAYS) [[ "$value" =~ ^[0-9]{1,6}$ ]] ;;
        DASHBOARD_IDLE_SECONDS) [[ "$value" =~ ^[0-9]{1,4}$ ]] && (( 10#$value >= 10 && 10#$value <= 3600 )) ;;
        TELEMETRY_MAX_GIB|TELEMETRY_SPOOL_MAX_GIB|TELEMETRY_SPOOL_ROTATE_MIB|ALERT_COOLDOWN_SECONDS|ALERT_REMINDER_SECONDS|ALERT_HOLD_SECONDS|ALERT_SYNC_GRACE_SECONDS) [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] ;;
        STORAGE_MAX_GIB) [[ "$value" =~ ^[0-9]{1,6}$ ]] ;;
        DASHBOARD_SESSION_DAYS) [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 1 && 10#$value <= 30 )) ;;
        DASHBOARD_TOKEN_SECONDS) [[ "$value" =~ ^[0-9]{1,2}$ ]] && (( 10#$value >= 10 && 10#$value <= 60 )) ;;
        DASHBOARD_DOMAIN) [[ -z "$value" ]] || gb_valid_domain "$value" ;;
        DEFAULT_RATE_PER_SECOND|DEFAULT_RATE_BURST|DEFAULT_QUOTA_HOUR|DEFAULT_QUOTA_DAY|DEFAULT_CONN_LIMIT|DEFAULT_CACHE_TTL|DEFAULT_SHA_CACHE_TTL|LOG_ROTATE_KEEP)
            [[ "$value" =~ ^[0-9]{1,9}$ ]] ;;
        LOG_ROTATE_SIZE) [[ "$value" =~ ^[1-9][0-9]*[kMG]?$ ]] ;;
        SERVER_PUBLIC_IPV4|SERVER_PUBLIC_IPV6|TRUSTED_PROXY_CIDRS)
            "$GB_PYTHON" - "$key" "$value" <<'PY'
import ipaddress
import sys
key, value = sys.argv[1:]
try:
    if not value or (key == "SERVER_PUBLIC_IPV6" and value == "none"):
        pass
    elif key == "TRUSTED_PROXY_CIDRS":
        for item in value.split(","):
            network = ipaddress.ip_network(item.strip(), strict=False)
            if network.prefixlen == 0:
                raise ValueError("proxy trust must identify the proxy network")
    else:
        address = ipaddress.ip_address(value)
        if address.version != (4 if key.endswith("4") else 6):
            raise ValueError("wrong address family")
except ValueError:
    sys.exit(1)
PY
            ;;
        *) return 0 ;;
    esac || { gb_warn "Invalid value for $key. See getbible settings environment and docs/DOCKER.md."; return 1; }
}

gb_environment_validate() {
    local key value status
    gb_execution_mode >/dev/null || return 1
    while IFS= read -r key; do
        if value="$(gb_environment_direct "$key")"; then
            gb_setting_validate "$key" "$value" || return 1
        else
            status=$?
            (( status == 1 )) || return 1
        fi
    done < <(gb_environment_keys)
}

gb_environment_capture() {
    local key value status staged
    gb_environment_validate || return 1
    gb_ensure_dir "$GB_RUN" 0755 || return 1
    staged="$(gb_tmpdir)/environment.conf"
    : > "$staged"
    chmod 0600 "$staged"
    while IFS= read -r key; do
        if value="$(gb_environment_direct "$key")"; then
            printf '%s=%s\n' "$key" "$value" >> "$staged"
        else
            status=$?
            (( status == 1 )) || return 1
        fi
    done < <(gb_environment_keys)
    gb_install_file "$staged" "$GB_ENVIRONMENT_CONF" 0600
}

gb_environment_telegram() {
    local key staged value
    gb_is_docker || return 0
    gb_ensure_dir "$GB_RUN" 0755 || return 1
    staged="$(gb_tmpdir)/telegram-effective.conf" || return 1
    : > "$staged" || return 1
    for key in TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_HOSTNAME; do
        value="$(cfg_get "$GB_TELEGRAM_CONF" "$key")" || return 1
        printf '%s=%s\n' "$key" "$value" >> "$staged" || return 1
    done
    gb_install_file "$staged" "$GB_RUN/telegram.conf" 0640 "root:$GB_NOTIFY_GROUP"
}

gb_environment_status() {
    local key value source file
    printf 'Execution mode: %s\n\n%-35s %-14s %s\n' "$(gb_execution_mode)" SETTING SOURCE VALUE
    while IFS= read -r key; do
        file="$(gb_environment_file "$key")"
        source=saved/default
        gb_environment_managed "$file" "$key" && source=environment
        value="$(cfg_get "$file" "$key")"
        case "$key" in *_TOKEN) [[ -z "$value" ]] || value='(configured; hidden)' ;; esac
        printf '%-35s %-14s %s\n' "$key" "$source" "$value"
    done < <(gb_environment_keys)
}

gb_settings_menu() {
    local key value choice
    while true; do
        choice="$(ui_menu 'Deployment settings' "Execution: $(gb_execution_mode). Environment values are shown in the configuration report and edited in Compose." \
            report 'Show effective settings and their sources' \
            edit 'Set one system setting' \
            resources 'Runtime memory budget' \
            back 'Back')" || return 0
        case "$choice" in
            report) ui_msg 'Effective configuration' "$(gb_environment_status)" ;;
            resources) resources_menu ;;
            edit)
                key="$(ui_input 'System setting' "Setting name (for example TLS_MODE, TRUSTED_PROXY_CIDRS, MEMORY_BUDGET)" '')" || continue
                if ! gb_environment_keys | grep -qxF "$key" || [[ "$(gb_environment_file "$key")" != "$GB_GLOBAL_CONF" ]]; then
                    ui_msg 'System setting' 'Choose a system key from the configuration report. Credentials have their own settings menus.'; continue
                fi
                if gb_environment_managed "$GB_GLOBAL_CONF" "$key"; then
                    ui_msg 'Environment setting' "Change GETBIBLE_$key in the deployment environment and recreate the container."; continue
                fi
                value="$(ui_input 'System setting' "$key" "$(gb_global "$key")")" || continue
                ui_run 'Save setting' gb_global_set "$key" "$value" || true
                ;;
            back) return 0 ;;
        esac
    done
}
