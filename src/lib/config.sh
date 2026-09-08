#!/usr/bin/env bash
# KEY=value configuration files. Values are stored raw on one line, read back
# without word splitting, never sourced. Every write is atomic.

[[ -n "${GB_CONFIG_LOADED:-}" ]] && return 0
GB_CONFIG_LOADED=1

cfg_valid_key() { [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

# cfg_get FILE KEY [DEFAULT]
cfg_get() {
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

# cfg_set FILE KEY VALUE
cfg_set() {
    local file="$1" key="$2" value="$3"
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
    mv -f -- "$tmp" "$file"
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
    "DEFAULT_ACCESS_MODE=metered"
    "DEFAULT_RATE_PER_SECOND=50"
    "DEFAULT_RATE_BURST=250"
    "DEFAULT_QUOTA_HOUR=10000"
    "DEFAULT_QUOTA_DAY=100000"
    "DEFAULT_CONN_LIMIT=100"
    "DEFAULT_CACHE_TTL=3600"
    "DEFAULT_SHA_CACHE_TTL=300"
    "DEFAULT_SYNC_SCHEDULE=weekly"
    "DEFAULT_EXTENSIONS=json,sha,txt"
    "LOG_ROTATE_SIZE=1G"
    "LOG_ROTATE_KEEP=30"
    "HSTS_INCLUDE_SUBDOMAINS=false"
    "CLOUDFLARE_ENABLED=false"
    "SERVER_PUBLIC_IPV4="
    "SERVER_PUBLIC_IPV6="
)

gb_global_init() {
    gb_ensure_dir "$GB_ETC" 0750
    local entry key
    for entry in "${GB_GLOBAL_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        if [[ -z "$(cfg_get "$GB_GLOBAL_CONF" "$key" "__unset__")" || "$(cfg_get "$GB_GLOBAL_CONF" "$key" "__unset__")" == "__unset__" ]]; then
            cfg_set "$GB_GLOBAL_CONF" "$key" "${entry#*=}"
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
gb_global_set() { cfg_set "$GB_GLOBAL_CONF" "$1" "$2"; }
