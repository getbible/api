#!/usr/bin/env bash
# The domain registry: one directory per domain under /etc/getbible/endpoints
# holding endpoint.conf (the domain), versions/<label>.conf (its endpoints),
# tokens.json, and a state directory under /var/lib/getbible/state/<domain>.
# The directory names predate the domain/endpoint vocabulary and stay as they
# are so existing installations keep working.

[[ -n "${GB_REGISTRY_LOADED:-}" ]] && return 0
GB_REGISTRY_LOADED=1

ep_dir() { printf '%s/%s\n' "$GB_ENDPOINTS" "$1"; }
ep_conf() { printf '%s/%s/endpoint.conf\n' "$GB_ENDPOINTS" "$1"; }
ep_versions_dir() { printf '%s/%s/versions\n' "$GB_ENDPOINTS" "$1"; }
ep_tokens_file() { printf '%s/%s/tokens.json\n' "$GB_ENDPOINTS" "$1"; }
ep_state_dir() { printf '%s/%s\n' "$GB_STATE" "$1"; }
ep_state_conf() { printf '%s/%s/state.conf\n' "$GB_STATE" "$1"; }
ep_log_dir() { printf '%s/%s\n' "$GB_LOG" "$1"; }
ep_data_dir() { printf '%s/%s\n' "$GB_SRV" "$1"; }
ep_www_dir() { printf '%s/%s\n' "$GB_WWW" "$1"; }

ep_exists() { [[ -f "$(ep_conf "$1")" ]]; }

ep_list() {
    [[ -d "$GB_ENDPOINTS" ]] || return 0
    find "$GB_ENDPOINTS" -mindepth 2 -maxdepth 2 -name endpoint.conf -printf '%h\n' \
        | xargs -r -n1 basename | sort
}

ep_list_by_type() {
    local type="$1" domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        [[ "$(ep_get "$domain" TYPE)" == "$type" ]] && printf '%s\n' "$domain"
    done < <(ep_list)
    return 0
}

ep_get() { cfg_get "$(ep_conf "$1")" "$2" "${3:-}"; }
ep_set() { cfg_set "$(ep_conf "$1")" "$2" "$3"; }

# ep_load DOMAIN: define EP_* variables from endpoint.conf.
ep_load() {
    local domain="$1" key
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    for key in DOMAIN SLUG TYPE KIND ACCESS_MODE RATE_PER_SECOND RATE_BURST QUOTA_HOUR QUOTA_DAY \
               CONN_LIMIT CLOUDFLARE_MODE CLOUDFLARE_CACHE CLOUDFLARE_FEATURES CLOUDFLARE_ORIGIN_PULLS DOCS_SOURCE \
               EXTENSIONS CACHE_TTL SHA_CACHE_TTL SYNC_SCHEDULE SYNC_USER DEFAULT_ENDPOINT CREATED ENABLED LIVE \
               FAVICON_SOURCE FAVICON_MIME LOGO_SOURCE LOGO_FILE; do
        printf -v "EP_$key" '%s' ""
    done
    cfg_load "$(ep_conf "$domain")" EP
    EP_SLUG="${EP_SLUG:-$(gb_slug "$domain")}"
}

# ep_create DOMAIN TYPE KIND: write a new endpoint.conf seeded from global defaults.
ep_create() {
    local domain="$1" type="$2" kind="$3" conf
    gb_valid_domain "$domain" || gb_die "Invalid domain: $domain"
    ep_exists "$domain" && gb_die "Domain already exists: $domain"
    conf="$(ep_conf "$domain")"
    gb_ensure_dir "$(ep_dir "$domain")" 0750
    cfg_set "$conf" GB_SCHEMA 1
    cfg_set "$conf" DOMAIN "$domain"
    cfg_set "$conf" SLUG "$(gb_slug "$domain")"
    cfg_set "$conf" TYPE "$type"
    cfg_set "$conf" KIND "$kind"
    cfg_set "$conf" ENABLED true
    cfg_set "$conf" LIVE "$([[ "$(ep_deploy_mode_default)" == staged ]] && printf false || printf true)"
    cfg_set "$conf" ACCESS_MODE "$(gb_global DEFAULT_ACCESS_MODE metered)"
    cfg_set "$conf" RATE_PER_SECOND "$(gb_global DEFAULT_RATE_PER_SECOND 50)"
    cfg_set "$conf" RATE_BURST "$(gb_global DEFAULT_RATE_BURST 250)"
    cfg_set "$conf" QUOTA_HOUR "$(gb_global DEFAULT_QUOTA_HOUR 10000)"
    cfg_set "$conf" QUOTA_DAY "$(gb_global DEFAULT_QUOTA_DAY 100000)"
    cfg_set "$conf" CONN_LIMIT "$(gb_global DEFAULT_CONN_LIMIT 100)"
    cfg_set "$conf" CLOUDFLARE_MODE "$(gb_global DEFAULT_CLOUDFLARE_MODE off)"
    cfg_set "$conf" CLOUDFLARE_CACHE "$(gb_global DEFAULT_CLOUDFLARE_CACHE bypass)"
    cfg_set "$conf" CLOUDFLARE_FEATURES "$(gb_global DEFAULT_CLOUDFLARE_FEATURES free)"
    cfg_set "$conf" CLOUDFLARE_ORIGIN_PULLS false
    cfg_set "$conf" DOCS_SOURCE generated
    cfg_set "$conf" FAVICON_SOURCE default
    cfg_set "$conf" LOGO_SOURCE default
    cfg_set "$conf" CREATED "$(gb_timestamp)"
    chmod 0640 "$conf" 2>/dev/null || true
    gb_ensure_dir "$(ep_state_dir "$domain")" 0750
}

ep_remove_config() {
    local domain="$1"
    rm -rf -- "${GB_ENDPOINTS:?}/$domain" "${GB_STATE:?}/$domain"
}

# --- publication ------------------------------------------------------------
# A staged endpoint has everything installed but has not taken over its public
# name: no certificate was requested and DNS was not changed. Domains
# must explicitly record their publication state.
ep_is_live() { [[ "$(ep_get "$1" LIVE false)" != false ]]; }
ep_publication() { if ep_is_live "$1"; then printf 'live\n'; else printf 'staged\n'; fi; }

# The mode for a new endpoint: the deploy walkthrough or --staged/--live sets
# GB_DEPLOY_MODE; otherwise the default from Settings applies.
ep_deploy_mode_default() {
    local mode="${GB_DEPLOY_MODE:-$(gb_global DEFAULT_DEPLOY_MODE live)}"
    if [[ "$mode" == staged ]]; then printf 'staged\n'; else printf 'live\n'; fi
}

ep_state_get() { cfg_get "$(ep_state_conf "$1")" "$2" "${3:-}"; }
ep_state_set() {
    gb_ensure_dir "$(ep_state_dir "$1")" 0750
    cfg_set "$(ep_state_conf "$1")" "$2" "$3"
}

# --- versions: the endpoints of a domain (version folders, or "root") --------
ep_versions() {
    local dir
    dir="$(ep_versions_dir "$1")"
    [[ -d "$dir" ]] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort -V
}

ep_version_conf() { printf '%s/%s.conf\n' "$(ep_versions_dir "$1")" "$2"; }
ep_version_exists() { [[ -f "$(ep_version_conf "$1" "$2")" ]]; }
ep_version_get() { cfg_get "$(ep_version_conf "$1" "$2")" "$3" "${4:-}"; }
ep_version_set() { cfg_set "$(ep_version_conf "$1" "$2")" "$3" "$4"; }

# ep_version_load DOMAIN LABEL: define EV_* variables. Static endpoints carry
# the repository keys, runtime endpoints the service settings and layout.
ep_version_load() {
    local key
    for key in LABEL ENABLED CREATED DOCS_SOURCE DOCS_REPO_PATH OPENAPI_SOURCE OPENAPI_REPO_PATH \
               REPO_URL REPO_REF SOURCE_PATH \
               APP_VERSION REPOSITORY WORKERS THREADS WARM_TRANSLATIONS DEFAULT_TRANSLATION DEFAULT_REFERENCE \
               ALLOWED_TRANSLATIONS PYTHON_VERSION CACHE_TTL; do
        printf -v "EV_$key" '%s' ""
    done
    ep_version_exists "$1" "$2" || gb_die "Unknown endpoint $2 for $1"
    cfg_load "$(ep_version_conf "$1" "$2")" EV
}

ep_version_create() {
    local domain="$1" label="$2" repo="$3" ref="$4" subpath="$5" conf
    gb_valid_endpoint_label "$label" || gb_die "Invalid version label: $label (expected v1, v2, ... or root)"
    gb_valid_repo_url "$repo" || gb_die "Invalid repository URL: $repo"
    gb_valid_subpath "$subpath" || gb_die "Invalid source path: $subpath"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]{1,120}$ ]] || gb_die "Invalid git reference: $ref"
    conf="$(ep_version_conf "$domain" "$label")"
    gb_ensure_dir "$(ep_versions_dir "$domain")" 0750
    cfg_set "$conf" LABEL "$label"
    cfg_set "$conf" REPO_URL "$repo"
    cfg_set "$conf" REPO_REF "$ref"
    cfg_set "$conf" SOURCE_PATH "$subpath"
    cfg_set "$conf" ENABLED true
    cfg_set "$conf" CREATED "$(gb_timestamp)"
    chmod 0640 "$conf" 2>/dev/null || true
}

ep_version_remove_config() { rm -f -- "$(ep_version_conf "$1" "$2")"; }

# The path nginx and the librarian read for a version: /srv/getbible/<domain>/<label>
ep_version_path() { printf '%s/%s/%s\n' "$GB_SRV" "$1" "$2"; }
ep_releases_dir() { printf '%s/%s/releases/%s\n' "$GB_SRV" "$1" "$2"; }

# --- summaries for the menu --------------------------------------------------
ep_summary_line() {
    local domain="$1"
    ep_load "$domain"
    local extra endpoints
    endpoints="$(ep_versions "$domain" | sed 's/^root$/domain root/' | tr '\n' ' ')"
    if [[ "$EP_TYPE" == mcp ]]; then
        extra="MCP at https://$domain/"
    elif [[ "$EP_TYPE" == static ]]; then
        extra="endpoints: ${endpoints:-none}"
    else
        extra="kind: $EP_KIND · endpoints: ${endpoints:-none}"
    fi
    printf '%-32s %-8s %-8s %s · %s\n' "$domain" "$EP_TYPE" "$EP_ACCESS_MODE" "$extra" "$(ep_publication "$domain")"
}

