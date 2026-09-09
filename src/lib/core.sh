#!/usr/bin/env bash
# Core helpers shared by every getbible.sh library: paths, logging, privilege
# handling, temporary files, small validators. Sourced, never executed.
#
# Every absolute path is prefixed with GB_PREFIX so the whole tool can be
# exercised against a throw-away root in tests. Every external command that
# changes system state is wrapped so tests can stub it through PATH.

[[ -n "${GB_CORE_LOADED:-}" ]] && return 0
GB_CORE_LOADED=1

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

GB_VERSION="1.0.0"

# --- locations ---------------------------------------------------------------
GB_PREFIX="${GB_PREFIX:-}"
GB_REPO_DIR="${GB_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
GB_SRC="$GB_REPO_DIR/src"
GB_LIB="$GB_SRC/lib"
GB_TYPES="$GB_SRC/types"
GB_APPS="$GB_SRC/apps"
GB_TOOLS="$GB_SRC/bin"
GB_NGINX_SRC="$GB_SRC/nginx"
GB_DOCS_SRC="$GB_SRC/docs-site"
# The icons every domain serves unless the operator replaces them (pages.sh).
GB_IMG="$GB_REPO_DIR/img"

GB_ETC="$GB_PREFIX/etc/getbible"
GB_ENDPOINTS="$GB_ETC/endpoints"
GB_GLOBAL_CONF="$GB_ETC/getbible.conf"
GB_TELEGRAM_CONF="$GB_ETC/telegram.conf"
GB_CLOUDFLARE_CONF="$GB_ETC/cloudflare.conf"
GB_LOGROTATE_CONF="$GB_ETC/logrotate.conf"
GB_VAR="$GB_PREFIX/var/lib/getbible"
GB_STATE="$GB_VAR/state"
GB_LEDGER="$GB_VAR/ledger"
GB_BACKUPS="$GB_PREFIX/var/backups/getbible"
GB_LOG="$GB_PREFIX/var/log/getbible"
GB_SRV="$GB_PREFIX/srv/getbible"
GB_OPT="$GB_PREFIX/opt/getbible"
GB_WWW="$GB_PREFIX/var/www/getbible"
GB_CACHE="$GB_PREFIX/var/cache/getbible"
GB_RUN="$GB_PREFIX/run/getbible"
GB_NGINX="$GB_PREFIX/etc/nginx"
GB_NGINX_GB="$GB_NGINX/getbible"
GB_SYSTEMD="$GB_PREFIX/etc/systemd/system"
GB_LETSENCRYPT="$GB_PREFIX/etc/letsencrypt"
GB_PLACEHOLDER_CERTS="$GB_ETC/placeholder-certs"
GB_FAVICON_FILE="$GB_ETC/favicon.ico"
GB_LOGO_PREFIX="$GB_ETC/logo"
GB_CERTBOT_CLOUDFLARE_INI="$GB_ETC/certbot-cloudflare.ini"
GB_ACME_ROOT="$GB_PREFIX/var/www/letsencrypt"
GB_BIN="$GB_PREFIX/usr/local/bin"
GB_LIBEXEC="$GB_PREFIX/usr/local/lib/getbible"

GB_READERS_GROUP="getbible-readers"
GB_NOTIFY_GROUP="getbible-notify"
GB_NGINX_USER="${GB_NGINX_USER:-www-data}"

# --- wrapped commands (tests override through PATH or these variables) ------
GB_SYSTEMCTL="${GB_SYSTEMCTL:-systemctl}"
GB_NGINX_BIN="${GB_NGINX_BIN:-nginx}"
GB_CERTBOT="${GB_CERTBOT:-certbot}"
GB_PYTHON="${GB_PYTHON:-python3}"

GB_YES="${GB_YES:-false}"        # non-interactive: accept defaults, abort on questions
GB_DRY_RUN="${GB_DRY_RUN:-false}" # render and report, write nothing outside temp

# --- output ------------------------------------------------------------------
gb_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Log lines go to stderr so functions can return data on stdout.
gb_log() {
    local line
    line="[$(gb_timestamp)] $*"
    printf '%s\n' "$line" >&2
    if [[ -d "$GB_LOG" && -w "$GB_LOG" ]]; then
        printf '%s\n' "$line" >> "$GB_LOG/getbible.log" 2>/dev/null || true
    fi
}

gb_warn() { gb_log "WARNING: $*"; }

gb_die() {
    gb_log "ERROR: $*"
    exit 1
}

gb_step() { gb_log "==> $*"; }

# --- privileges --------------------------------------------------------------
gb_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Re-execute the running script under sudo, keeping the variables the tool
# needs. Only called for actions that write outside the checkout.
gb_require_root() {
    gb_is_root && return 0
    [[ -n "$GB_PREFIX" ]] && return 0   # test prefix: everything is user-owned
    command -v sudo >/dev/null || gb_die "This action needs root and sudo is not installed."
    gb_log "Re-running under sudo."
    exec sudo --preserve-env=GB_PREFIX,GB_YES,GB_DRY_RUN,GB_UI,TERM -- "$GB_SELF" "${GB_ARGS[@]}"
}

# --- temporary files ---------------------------------------------------------
# Created once by the main process so subshells can use it freely; removed
# when the main process exits.
GB_TMP="${GB_TMP:-$(mktemp -d)}"
export GB_TMP
gb_tmpdir() { printf '%s\n' "$GB_TMP"; }

gb_cleanup() {
    [[ -n "$GB_TMP" && -d "$GB_TMP" ]] && rm -rf -- "$GB_TMP"
    return 0
}
trap 'gb_cleanup' EXIT

# --- validators --------------------------------------------------------------
GB_RE_DOMAIN='^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?)+$'
gb_valid_domain() { [[ "$1" =~ $GB_RE_DOMAIN ]]; }
gb_valid_version() { [[ "$1" =~ ^v[1-9][0-9]{0,2}$ ]]; }
# An endpoint is a version folder (v2) or the domain root itself ("root").
gb_valid_endpoint_label() { [[ "$1" == root ]] || gb_valid_version "$1"; }
gb_valid_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
gb_valid_extension() { [[ "$1" =~ ^[a-z0-9]{1,10}$ ]]; }
gb_valid_translation() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,29}$ ]]; }
GB_RE_LABEL='^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$'
gb_valid_label() { [[ "$1" =~ $GB_RE_LABEL ]]; }
# SSH URLs carry the host's SSH user (git on GitHub, GitLab and Gitea; anything
# on a self-hosted server); the deploy key, not an account, is the identity.
GB_RE_REPO_URL='^([A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+|ssh://[A-Za-z0-9@.:/_-]+|https://[A-Za-z0-9./_-]+|file:///[A-Za-z0-9./_-]+)$'
gb_valid_repo_url() { [[ "$1" =~ $GB_RE_REPO_URL ]]; }
GB_RE_SUBPATH='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
gb_valid_subpath() { [[ "$1" == "." ]] || { [[ "$1" =~ $GB_RE_SUBPATH ]] && [[ "$1" != *..* ]]; }; }

# nginx variable and file safe identifier for a domain: api.getbible.net -> api_getbible_net
gb_slug() { printf '%s\n' "$1" | tr -c 'a-z0-9\n' '_'; }

# Short, unique, username-safe identifier (max 32 chars): first label + hash.
gb_short_slug() {
    local domain="$1" first hash
    first="${domain%%.*}"
    first="${first//[^a-z0-9]/}"
    first="${first:0:14}"
    hash="$(printf '%s' "$domain" | sha256sum | cut -c1-4)"
    printf '%s-%s\n' "$first" "$hash"
}

gb_sha256_file() { sha256sum -- "$1" | cut -d' ' -f1; }

# --- file helpers ------------------------------------------------------------
# Install a rendered file atomically with owner/mode; records nothing itself.
gb_install_file() {
    local source="$1" target="$2" mode="${3:-0644}" owner="${4:-root:root}"
    local dir
    dir="$(dirname -- "$target")"
    [[ -d "$dir" ]] || gb_ensure_dir "$dir" 0755 || return 1
    if [[ "$GB_DRY_RUN" == true ]]; then
        gb_log "(dry-run) would install $target"
        return 0
    fi
    install -m "$mode" -- "$source" "$target.gb-tmp" || return 1
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$owner" -- "$target.gb-tmp" || return 1
    fi
    mv -f -- "$target.gb-tmp" "$target"
}

# Create DIR with MODE and OWNER. Missing ancestors are created one by one at
# 0755, never implicitly: GNU install ignores the umask for implicit parents
# while the Rust coreutils shipped by Ubuntu 26.04 apply it, which under this
# tool's umask 027 left /srv/getbible or /var/cache/nginx at 0750 and locked
# the nginx account out of every file below them.
gb_ensure_dir() {
    local dir="$1" mode="${2:-0755}" owner="${3:-root:root}" parent
    if [[ ! -d "$dir" ]]; then
        parent="$(dirname -- "$dir")"
        [[ -d "$parent" ]] || gb_ensure_dir "$parent" 0755 root:root || return 1
        install -d -m "$mode" -- "$dir" || return 1
    fi
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown "$owner" -- "$dir" || return 1
        chmod "$mode" -- "$dir" || return 1
    fi
}

gb_backup_file() {
    # Copy an existing file into the current backup set; missing files get a marker.
    local target="$1" set_dir="$2" key
    key="$(printf '%s' "$target" | tr '/' '_')"
    gb_ensure_dir "$set_dir" 0700
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a -- "$target" "$set_dir/$key"
    else
        : > "$set_dir/$key.missing"
    fi
}

gb_restore_file() {
    local target="$1" set_dir="$2" key
    key="$(printf '%s' "$target" | tr '/' '_')"
    if [[ -e "$set_dir/$key.missing" ]]; then
        rm -f -- "$target"
    elif [[ -e "$set_dir/$key" || -L "$set_dir/$key" ]]; then
        rm -f -- "$target"
        cp -a -- "$set_dir/$key" "$target"
    fi
}

gb_new_backup_set() {
    local name="$1" dir
    gb_ensure_dir "$GB_BACKUPS" 0700 || return 1
    dir="$(mktemp -d "$GB_BACKUPS/$name-$(date -u +%Y%m%dT%H%M%S%N)-XXXXXX")" || return 1
    printf '%s\n' "$dir"
}

# Every management command shares one lock. Static synchronizers have their
# own per-version locks and continue to serve/publish independently.
gb_management_lock() {
    if [[ "${GB_MANAGER_LOCKED:-false}" == true && "$(readlink /proc/self/fd/7 2>/dev/null || true)" == "$GB_VAR/manage.lock" ]]; then
        return 0
    fi
    gb_ensure_dir "$GB_VAR" 0755 || return 1
    exec 7>"$GB_VAR/manage.lock" || return 1
    flock -n 7 || { gb_warn "Another endpoint management command is running."; return 1; }
    GB_MANAGER_LOCKED=true
}

gb_prune_backups() {
    # Keep the newest N backup sets for a name.
    local name="$1" keep="${2:-10}"
    [[ -d "$GB_BACKUPS" ]] || return 0
    find "$GB_BACKUPS" -mindepth 1 -maxdepth 1 -type d -name "$name-*" -printf '%f\n' \
        | sort -r | tail -n +"$((keep + 1))" | while read -r old; do
            rm -rf -- "${GB_BACKUPS:?}/$old"
        done
}

# Render a template through getbible-render into a file.
gb_render() {
    local template="$1" output="$2"
    shift 2
    "$GB_PYTHON" "$GB_TOOLS/getbible-render" "$template" "$@" > "$output"
}

gb_have() { command -v "$1" >/dev/null 2>&1; }

# Point LINK at TARGET atomically: a fresh symlink is renamed over the old
# one with rename(2). mv -T cannot be relied on for this step because the Rust
# coreutils follow the existing link into its directory and refuse the move.
gb_switch_link() {
    local target="$1" link="$2"
    ln -sfn -- "$target" "$link.new" || return 1
    "$GB_PYTHON" -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$link.new" "$link" \
        || { rm -f -- "$link.new"; return 1; }
}

# Ledger: remember the hash of every file this tool installed so update can
# tell an untouched file from a hand edit.
gb_ledger_record() {
    local target="$1" key
    [[ "$GB_DRY_RUN" == true ]] && return 0
    gb_ensure_dir "$GB_LEDGER" 0700
    key="$(printf '%s' "$target" | tr '/' '_')"
    gb_sha256_file "$target" > "$GB_LEDGER/$key"
}

gb_ledger_get() {
    local target="$1" key
    key="$(printf '%s' "$target" | tr '/' '_')"
    [[ -f "$GB_LEDGER/$key" ]] && cat "$GB_LEDGER/$key" || true
}

gb_ledger_forget() {
    local target="$1" key
    key="$(printf '%s' "$target" | tr '/' '_')"
    rm -f -- "$GB_LEDGER/$key"
}

# Classify an installed file against its ledger entry and a freshly rendered
# candidate: prints unchanged | planned | hand-edited | new
gb_drift_status() {
    local target="$1" candidate="$2" recorded current wanted
    wanted="$(gb_sha256_file "$candidate")"
    if [[ ! -e "$target" ]]; then
        printf 'new\n'
        return 0
    fi
    current="$(gb_sha256_file "$target")"
    recorded="$(gb_ledger_get "$target")"
    if [[ "$current" == "$wanted" ]]; then
        printf 'unchanged\n'
    elif [[ -n "$recorded" && "$recorded" != "$current" ]]; then
        printf 'hand-edited\n'
    else
        printf 'planned\n'
    fi
}
