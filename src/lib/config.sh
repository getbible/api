#!/usr/bin/env bash
# KEY=value configuration files. Values are stored raw on one line, read back
# without word splitting, never sourced. Every write is atomic.

[[ -n "${GB_CONFIG_LOADED:-}" ]] && return 0
GB_CONFIG_LOADED=1

cfg_valid_key() { [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

# cfg_get FILE KEY [DEFAULT]
cfg_get_raw() {
    local file="$1" key="$2" default="${3:-}" line value=""
    local found=false
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "$key="* ]] || continue
            value="${line#"$key"=}"
            found=true
        done < "$file"
    fi
    if [[ "$found" == true ]]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default"
    fi
}

cfg_get() {
    local status
    if declare -F gb_environment_get >/dev/null; then
        if gb_environment_get "$1" "$2"; then return 0; else status=$?; fi
        (( status == 1 )) || return "$status"
    fi
    cfg_get_raw "$@"
}

# cfg_set FILE KEY VALUE
cfg_set() {
    local file="$1" key="$2" value="$3" status
    if [[ "${GB_CONFIG_INITIALIZING:-false}" != true ]] && declare -F gb_environment_managed >/dev/null; then
        if gb_environment_managed "$file" "$key"; then
            gb_warn "$key is controlled by GETBIBLE_$key; change the deployment environment and recreate the container."
            return 1
        else
            status=$?
            (( status == 1 )) || return "$status"
        fi
    fi
    cfg_valid_key "$key" || gb_die "Invalid configuration key: $key"
    [[ "$value" != *$'\n'* ]] || gb_die "Configuration values cannot contain newlines ($key)."
    local dir tmp replaced=false line
    dir="$(dirname -- "$file")"
    [[ -d "$dir" ]] || gb_ensure_dir "$dir" 0750 || gb_die "Cannot create $dir"
    tmp="$file.tmp.$$"
    : > "$tmp"
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$key="* ]]; then
                if [[ "$replaced" == false ]]; then
                    printf '%s=%s\n' "$key" "$value" >> "$tmp"
                    replaced=true
                fi
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
        chmod --reference="$file" "$tmp" 2>/dev/null || true
    else
        chmod 0640 "$tmp"
    fi
    [[ "$replaced" == true ]] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv -f -- "$tmp" "$file" || return 1
    if [[ "${GB_CONFIG_INITIALIZING:-false}" != true && "$file" == "$GB_TELEGRAM_CONF" ]] && declare -F gb_environment_telegram >/dev/null; then
        gb_environment_telegram || return 1
    fi
}

cfg_delete() {
    local file="$1" key="$2" tmp line
    [[ -f "$file" ]] || return 0
    tmp="$file.tmp.$$"
    : > "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] && continue
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file"
}

# cfg_load FILE PREFIX: define PREFIX_KEY shell variables for every entry.
cfg_load() {
    local file="$1" prefix="$2" line key value
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        cfg_valid_key "$key" || continue
        printf -v "${prefix}_${key}" '%s' "$value"
    done < "$file"
}

cfg_keys() {
    local file="$1" line key
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        key="${line%%=*}"
        cfg_valid_key "$key" && printf '%s\n' "$key"
    done < "$file"
}

# --- global configuration ----------------------------------------------------
GB_GLOBAL_DEFAULTS=(
    "GB_SCHEMA=1"
    "CERTBOT_EMAIL="
    "CERT_METHOD=auto"
    "DEFAULT_DEPLOY_MODE=live"
    "FAVICON_SOURCE=default"
    "FAVICON_MIME="
    "LOGO_SOURCE=default"
    "LOGO_FILE="
    "DEFAULT_ACCESS_MODE=metered"
    "DEFAULT_RATE_PER_SECOND=50"
    "DEFAULT_RATE_BURST=250"
    "DEFAULT_QUOTA_HOUR=10000"
    "DEFAULT_QUOTA_DAY=100000"
    "DEFAULT_CONN_LIMIT=100"
    "DEFAULT_CACHE_TTL=2592000"
    "DEFAULT_SHA_CACHE_TTL=300"
    "DEFAULT_SYNC_SCHEDULE=monthly"
    "DEFAULT_EXTENSIONS=json,sha,txt"
    "LOG_ROTATE_SIZE=1G"
    "LOG_ROTATE_KEEP=30"
    "HSTS_INCLUDE_SUBDOMAINS=false"
    "CLOUDFLARE_ENABLED=false"
    "SERVER_PUBLIC_IPV4="
    "SERVER_PUBLIC_IPV6="
    "TLS_MODE=managed"
    "TRUSTED_PROXY_CIDRS="
    "PUBLIC_SCHEME=https"
    "ORIGIN_HTTP_PORT=80"
    "MEMORY_BUDGET=auto"
    "DEFAULT_CLOUDFLARE_MODE=off"
    "DEFAULT_CLOUDFLARE_CACHE=bypass"
    "DEFAULT_CLOUDFLARE_FEATURES=free"
    "DEFAULT_QUERY_CACHE_TTL=2592000"
    "DEFAULT_SEARCH_CACHE_TTL=2592000"
    "DEFAULT_QUERY_WORKERS=auto"
    "DEFAULT_QUERY_THREADS=4"
    "DEFAULT_SEARCH_WORKERS=auto"
    "DEFAULT_SEARCH_THREADS=4"
    "MEMORY_CACHE_TTL=2592000"
    "CACHE_TTL_JITTER=0"
    "QUERY_MEMORY_MIN=192M"
    "SEARCH_MEMORY_MIN=512M"
    "QUERY_MEMORY_MAX=auto"
    "SEARCH_MEMORY_MAX=auto"
    "RESOURCE_RESERVE_PERCENT=25"
    "QUERY_CPU_QUOTA=auto"
    "SEARCH_CPU_QUOTA=auto"
    "QUERY_WORKERS_MIN=1"
    "QUERY_WORKERS_MAX=12"
    "SEARCH_WORKERS_MIN=1"
    "SEARCH_WORKERS_MAX=12"
    "QUERY_THREADS_MIN=1"
    "QUERY_THREADS_MAX=16"
    "SEARCH_THREADS_MIN=1"
    "SEARCH_THREADS_MAX=8"
    "QUERY_WARM_TRANSLATIONS=kjv"
    "SEARCH_WARM_TRANSLATIONS=kjv"
    "CACHE_MEMORY_PERCENT=50"
    "SHARED_CORPUS_LIMIT=256"
    "CHAPTER_CACHE_LIMIT=100000"
    "TRANSLATION_CACHE_LIMIT=256"
    "REFERENCE_CACHE_LIMIT=50000"
    "ADAPTIVE_RESOURCES=true"
    "ADAPTIVE_INTERVAL=15"
    "ADAPTIVE_COOLDOWN=300"
    "ADAPTIVE_HIGH_PERCENT=80"
    "ADAPTIVE_LOW_PERCENT=20"
    "ADAPTIVE_SUSTAINED_SAMPLES=4"
    "TELEMETRY_ENABLED=true"
    "TELEMETRY_MAX_GIB=10"
    "TELEMETRY_RETENTION_DAYS=180"
    "TELEMETRY_BATCH_SIZE=1000"
    "TELEMETRY_FLUSH_SECONDS=1"
    "TELEMETRY_METRICS_SECONDS=5"
    "DASHBOARD_DOMAIN="
    "DASHBOARD_ENABLED=false"
    "DASHBOARD_SESSION_DAYS=30"
    "DASHBOARD_IDLE_SECONDS=60"
    "DASHBOARD_TOKEN_SECONDS=60"
    "STORAGE_MAX_GIB=0"
    "ADAPTIVE_ALLOW_IDLE_SHRINK=false"
    "ALERT_SYNC_GRACE_SECONDS=3600"
    "TELEMETRY_SPOOL_MAX_GIB=1"
    "TELEMETRY_SPOOL_ROTATE_MIB=16"
    "ALERT_COOLDOWN_SECONDS=900"
    "ALERT_HOLD_SECONDS=60"
    "ALERT_CPU_PERCENT=95"
    "ALERT_MEMORY_PERCENT=90"
    "ALERT_DISK_PERCENT=90"
    "ALERT_MEMORY_PRESSURE_PERCENT=10"
)

gb_global_init() {
    local GB_CONFIG_INITIALIZING=true
    gb_ensure_dir "$GB_ETC" 0750
    local entry key
    # Before the repository shipped its own icons, a favicon under /etc was
    # the only system favicon: such a file stays the operator's choice.
    if [[ "$(cfg_get "$GB_GLOBAL_CONF" FAVICON_SOURCE "__unset__")" == "__unset__" && -f "$GB_FAVICON_FILE" ]]; then
        cfg_set "$GB_GLOBAL_CONF" FAVICON_SOURCE custom
    fi
    for entry in "${GB_GLOBAL_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        if [[ "$(cfg_get_raw "$GB_GLOBAL_CONF" "$key" "__unset__")" == "__unset__" ]]; then
            local value="${entry#*=}"
            if gb_is_docker; then
                case "$key" in
                    TLS_MODE) value=external ;;
                    DEFAULT_CLOUDFLARE_MODE) value=proxied ;;
                    DEFAULT_CLOUDFLARE_CACHE) value=respect ;;
                    DEFAULT_DEPLOY_MODE) value=staged ;;
                esac
            fi
            cfg_set "$GB_GLOBAL_CONF" "$key" "$value"
        fi
    done
    chmod 0640 "$GB_GLOBAL_CONF" 2>/dev/null || true
    if [[ ! -f "$GB_TELEGRAM_CONF" ]]; then
        cfg_set "$GB_TELEGRAM_CONF" "TELEGRAM_ENABLED" "false"
        cfg_set "$GB_TELEGRAM_CONF" "TELEGRAM_BOT_TOKEN" ""
        cfg_set "$GB_TELEGRAM_CONF" "TELEGRAM_CHAT_ID" ""
        cfg_set "$GB_TELEGRAM_CONF" "TELEGRAM_HOSTNAME" "$(hostname -f 2>/dev/null || hostname)"
    fi
    if [[ ! -f "$GB_CLOUDFLARE_CONF" ]]; then
        cfg_set "$GB_CLOUDFLARE_CONF" "CLOUDFLARE_API_TOKEN" ""
        chmod 0600 "$GB_CLOUDFLARE_CONF" 2>/dev/null || true
    fi
}

gb_global() { cfg_get "$GB_GLOBAL_CONF" "$1" "${2:-}"; }
gb_global_set() {
    if declare -F gb_setting_validate >/dev/null; then gb_setting_validate "$1" "$2" || return 1; fi
    if [[ "$1" == MEMORY_BUDGET ]] && declare -F resources_plan >/dev/null; then
        resources_plan --budget "$2" --format json >/dev/null || return 1
    fi
    cfg_set "$GB_GLOBAL_CONF" "$1" "$2" || return 1
    # Existing services read their own effective snapshots. Refresh after the
    # write, so a CLI/menu change is visible without an unrelated later command.
    if [[ "${GB_CONFIG_INITIALIZING:-false}" != true && "${GB_REFRESHING_SERVICE_SETTINGS:-false}" != true \
        && -n "${GB_SYSTEMD:-}" && -f "$GB_SYSTEMD/getbible-telemetry.service" ]] \
        && declare -F infrastructure_environment >/dev/null; then
        local GB_REFRESHING_SERVICE_SETTINGS=true
        if ! infrastructure_environment; then
            gb_warn "$1 was saved, but effective service settings could not be refreshed. Correct the reported error and apply the setting again."
            if declare -F tg_notify >/dev/null; then tg_notify fail 'Service settings refresh failed' "$1 was saved; running services may still have the previous value."; fi
            return 1
        fi
    fi
    if declare -F tg_notify >/dev/null; then tg_notify info "Setting changed" "$1 was updated."; fi
}
