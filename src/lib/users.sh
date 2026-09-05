#!/usr/bin/env bash
# System users, groups, directories and access control lists.

[[ -n "${GB_USERS_LOADED:-}" ]] && return 0
GB_USERS_LOADED=1

gb_group_exists() { getent group "$1" >/dev/null 2>&1; }
gb_user_exists() { getent passwd "$1" >/dev/null 2>&1; }

gb_ensure_group() {
    local group="$1"
    gb_group_exists "$group" && return 0
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would create group $group"; return 0; }
    [[ -n "$GB_PREFIX" ]] && return 0
    groupadd --system "$group"
    gb_log "Created group $group"
}

# gb_ensure_system_user NAME PRIMARY_GROUP HOME [extra groups csv]
gb_ensure_system_user() {
    local name="$1" group="$2" home="$3" extra="${4:-}"
    gb_ensure_group "$group"
    if ! gb_user_exists "$name"; then
        [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would create user $name"; return 0; }
        [[ -n "$GB_PREFIX" ]] && return 0
        useradd --system --gid "$group" --home-dir "$home" --no-create-home \
            --shell /usr/sbin/nologin "$name"
        gb_log "Created system user $name"
    fi
    if [[ -n "$extra" && -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
        usermod -a -G "$extra" "$name"
    fi
}

gb_user_in_group() {
    local user="$1" group="$2"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
}

# Everything that serves or reads endpoint data belongs to the readers group.
gb_ensure_base_groups() {
    gb_ensure_group "$GB_READERS_GROUP"
    gb_ensure_group "$GB_NOTIFY_GROUP"
    if [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]] && gb_user_exists "$GB_NGINX_USER"; then
        gb_user_in_group "$GB_NGINX_USER" "$GB_READERS_GROUP" || usermod -a -G "$GB_READERS_GROUP" "$GB_NGINX_USER"
    fi
}

gb_ensure_base_dirs() {
    gb_ensure_dir "$GB_ETC" 0750
    gb_ensure_dir "$GB_ENDPOINTS" 0750
    gb_ensure_dir "$GB_VAR" 0755
    gb_ensure_dir "$GB_STATE" 0750
    gb_ensure_dir "$GB_LEDGER" 0700
    gb_ensure_dir "$GB_BACKUPS" 0700
    gb_ensure_dir "$GB_LOG" 0755
    gb_ensure_dir "$GB_SRV" 0755
    gb_ensure_dir "$GB_OPT" 0755
    gb_ensure_dir "$GB_WWW" 0755
    gb_ensure_dir "$GB_CACHE" 0755
    gb_ensure_dir "$GB_LIBEXEC" 0755
    gb_ensure_dir "$GB_ACME_ROOT" 0755
    gb_ensure_dir "$GB_NGINX_GB" 0755
    gb_ensure_dir "$GB_NGINX_GB/tokens" 0755
    gb_ensure_dir "$GB_NGINX/snippets/getbible" 0755
}
