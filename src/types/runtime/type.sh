#!/usr/bin/env bash
# Runtime domain type: librarian-based services (query or search) built into
# immutable releases, run by gunicorn as their own user behind systemd
# sockets, proxied and cached by nginx.
#
# A runtime domain serves one endpoint per version (v2, v3, ...): each is its
# own service with its own releases, deployment generations, sockets and
# settings, all behind the one vhost. A domain may instead serve a single
# version at its root (the endpoint label "root"). Which versions exist is
# declared by the kind's implementations under src/apps: src/apps/<kind>/ for
# the versions its manifest supports, src/apps/<kind>-<version>/ when a
# version needs code of its own.

[[ -n "${GB_TYPE_RUNTIME_LOADED:-}" ]] && return 0
GB_TYPE_RUNTIME_LOADED=1

# --- kinds and their implementations -----------------------------------------
rt_manifest_files() { find "$GB_APPS" -mindepth 2 -maxdepth 2 -name manifest.conf | sort; }

rt_kinds() {
    local file
    while read -r file; do
        [[ -n "$file" ]] || continue
        cfg_get "$file" KIND
    done < <(rt_manifest_files) | grep -v '^$' | sort -u
    return 0
}

# rt_kind_versions KIND: every version an implementation of KIND supports.
rt_kind_versions() {
    local kind="$1" file
    while read -r file; do
        [[ -n "$file" ]] || continue
        [[ "$(cfg_get "$file" KIND)" == "$kind" ]] || continue
        cfg_get "$file" SUPPORTED_VERSIONS | tr ',' '\n'
    done < <(rt_manifest_files) | tr -d ' ' | grep -v '^$' | sort -Vu
    return 0
}

# rt_implementation KIND VERSION: the src/apps directory implementing VERSION.
rt_implementation() {
    local kind="$1" version="$2" dir
    for dir in "$kind-$version" "$kind"; do
        [[ -f "$GB_APPS/$dir/manifest.conf" ]] || continue
        [[ "$(cfg_get "$GB_APPS/$dir/manifest.conf" KIND)" == "$kind" ]] || continue
        [[ " $(cfg_get "$GB_APPS/$dir/manifest.conf" SUPPORTED_VERSIONS | tr ',' ' ') " == *" $version "* ]] || continue
        printf '%s\n' "$dir"
        return 0
    done
    return 1
}

# rt_manifest_load KIND [VERSION]: define RM_* from the manifest of the
# implementation that serves VERSION (RM_DIR is its directory); without a
# version, from the kind's base manifest src/apps/<kind>/manifest.conf.
rt_manifest_load() {
    local kind="$1" version="${2:-}" dir key
    if [[ -n "$version" ]]; then
        dir="$(rt_implementation "$kind" "$version")" || gb_die "No implementation of the $kind service supports version $version (supported: $(rt_kind_versions "$kind" | tr '\n' ' '))"
    else
        dir="$kind"
        [[ -f "$GB_APPS/$dir/manifest.conf" ]] || gb_die "Unknown runtime kind: $kind"
    fi
    for key in KIND DESCRIPTION PACKAGE WSGI CHECK ENV_PREFIX DEFAULT_VERSION SUPPORTED_VERSIONS ROUTE METHODS MAX_BODY \
               CACHE_SECONDS WORKERS THREADS TIMEOUT_START TIMEOUT_STOP MEMORY_HIGH MEMORY_MAX CPU_QUOTA TASKS_MAX NOFILE WARM_TRANSLATIONS; do
        printf -v "RM_$key" '%s' ""
    done
    cfg_load "$GB_APPS/$dir/manifest.conf" RM
    [[ "$RM_KIND" == "$kind" ]] || gb_die "Manifest of $dir declares KIND=$RM_KIND"
    RM_DIR="$dir"
}

rt_user() { printf 'getbible-%s\n' "$1"; }

rt_kind_deployed_on() {
    # Print the domain already using KIND, if any (one domain per kind).
    local kind="$1" domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        [[ "$(ep_get "$domain" KIND)" == "$kind" ]] && printf '%s\n' "$domain"
    done < <(ep_list_by_type runtime)
    return 0
}

# --- endpoints: the versions of a runtime domain ------------------------------
# Every endpoint has its own record and immutable APP_VERSION (the version
# implemented, which can differ from the label only for a root endpoint).
# Releases, generations, sockets, caches and units always carry its label.
RT_VERSION_SETTINGS=(REPOSITORY WORKERS THREADS WARM_TRANSLATIONS DEFAULT_TRANSLATION DEFAULT_REFERENCE ALLOWED_TRANSLATIONS PYTHON_VERSION CACHE_TTL)

type_runtime_endpoints() { ep_versions "$1"; }

# Runtime endpoints generate their OpenAPI document from the kind's template.
type_runtime_openapi_default() { printf 'generated\n'; }

# The endpoint that answers /, the short forms, /healthz, /readyz and the
# compatibility alias /openapi.json.
type_runtime_default_endpoint() {
    local domain="$1" default
    default="$(ep_get "$domain" DEFAULT_ENDPOINT)"
    if [[ -n "$default" ]] && ep_version_exists "$domain" "$default"; then
        printf '%s\n' "$default"
    else
        type_runtime_endpoints "$domain" | head -1
    fi
}

rt_app_version() { ep_version_get "$1" "$2" APP_VERSION "$2"; }

# rt_root DOMAIN LABEL: the directory with the endpoint's releases/,
# deployments/, current, active and previous.
rt_root() {
    local kind
    kind="$(ep_get "$1" KIND)"
    printf '%s/%s/%s\n' "$GB_OPT" "$kind" "$2"
}
rt_unit_prefix() {
    local kind
    kind="$(ep_get "$1" KIND)"
    printf 'getbible-%s-%s\n' "$kind" "$2"
}
rt_socket_dir() {
    local kind
    kind="$(ep_get "$1" KIND)"
    printf '%s/%s/%s\n' "$GB_RUN" "$kind" "$2"
}
# Relative to /var/cache, the form systemd's CacheDirectory= takes.
rt_cache_subdir() {
    local kind
    kind="$(ep_get "$1" KIND)"
    printf 'getbible/%s/%s\n' "$kind" "$2"
}
rt_cache_root() { printf '%s/var/cache/%s\n' "$GB_PREFIX" "$(rt_cache_subdir "$1" "$2")"; }
rt_env_file() {
    printf '%s/runtime-%s.env\n' "$(ep_dir "$1")" "$2"
}
rt_app_log() {
    printf '%s/app/%s.log\n' "$(ep_log_dir "$1")" "$2"
}
# rt_cache_dir DOMAIN LABEL RELEASE: the librarian cache of one release.
rt_cache_dir() { printf '%s/releases/%s/librarian\n' "$(rt_cache_root "$1" "$2")" "$(basename -- "$3")"; }

# --- deployment generations --------------------------------------------------
# A generation owns its environment and service configuration. Code releases
# can be reused, but live configuration is never rewritten underneath a process.
rt_deployments_dir() { printf '%s/deployments\n' "$(rt_root "$1" "$2")"; }
rt_active_generation() { local p; p="$(rt_root "$1" "$2")/active"; [[ -L "$p" ]] && readlink -f -- "$p" || true; }
rt_previous_generation() { local p; p="$(rt_root "$1" "$2")/previous"; [[ -L "$p" ]] && readlink -f -- "$p" || true; }
# rt_generation_unit DOMAIN LABEL GENERATION
rt_generation_unit() {
    printf '%s-%s\n' "$(rt_unit_prefix "$1" "$2")" "$(basename -- "$3")"
}
rt_generation_socket() { printf '%s/%s.sock\n' "$(rt_socket_dir "$1" "$2")" "$(basename -- "$3")"; }
rt_live_unit() {
    local active
    active="$(rt_active_generation "$1" "$2")"
    if [[ -n "$active" ]]; then rt_generation_unit "$1" "$2" "$active"; else rt_unit_prefix "$1" "$2"; fi
}
rt_socket() {
    local active
    active="$(rt_active_generation "$1" "$2")"
    if [[ -n "$active" ]]; then rt_generation_socket "$1" "$2" "$active"; else printf '%s/gunicorn.sock\n' "$(rt_socket_dir "$1" "$2")"; fi
}
rt_switch_link() { gb_switch_link "$1" "$2"; }

# The apply transaction of one domain: every enabled endpoint prepares a
# candidate (or finds itself current); nginx switches to all candidates in
# one reload; then every candidate is committed, or every one is removed.
declare -gA RT_CANDIDATES=() RT_OLD_GENERATIONS=() RT_OLD_RELEASES=() RT_OLD_UNITS=() RT_OLD_SOCKETS=()
RT_LABELS=()
RT_DOMAIN=""
RT_COMMITTED=false

# rt_proxy_socket DOMAIN LABEL: the socket nginx routes to; a candidate's
# while this apply is switching to it.
rt_proxy_socket() {
    if [[ "${RT_DOMAIN:-}" == "$1" && -n "${RT_CANDIDATES[$2]:-}" ]]; then
        rt_generation_socket "$1" "$2" "${RT_CANDIDATES[$2]}"
    else
        rt_socket "$1" "$2"
    fi
}

# rt_validate_settings DOMAIN LABEL
rt_validate_settings() {
    local domain="$1" label="$2" key value
    for key in WORKERS THREADS; do
        value="$(ep_version_get "$domain" "$label" "$key")"
        if ! [[ "$value" =~ ^[1-9][0-9]?$ ]] || (( 10#$value > 64 )); then
            gb_warn "$key of $domain $label must be between 1 and 64"; return 1
        fi
    done
    for key in WARM_TRANSLATIONS ALLOWED_TRANSLATIONS; do
        value="$(ep_version_get "$domain" "$label" "$key")"
        [[ -z "$value" || "$value" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || { gb_warn "Invalid $key of $domain $label"; return 1; }
    done
    value="$(ep_version_get "$domain" "$label" DEFAULT_TRANSLATION kjv)"
    gb_valid_translation "$value" || { gb_warn "Invalid default translation of $domain $label"; return 1; }
    value="$(ep_version_get "$domain" "$label" REPOSITORY)"
    rt_validate_repository "$value" "$(rt_app_version "$domain" "$label")" || return 1
    value="$(ep_version_get "$domain" "$label" CACHE_TTL 300)"
    [[ "$value" =~ ^[0-9]{1,7}$ ]] || { gb_warn "CACHE_TTL of $domain $label must be a nonnegative integer"; return 1; }
    gb_valid_version "$(rt_app_version "$domain" "$label")" || { gb_warn "APP_VERSION of $domain $label must be v1, v2, ..."; return 1; }
}

# rt_deployment_inputs DOMAIN LABEL RELEASE: everything a generation depends on.
rt_deployment_inputs() {
    local domain="$1" label="$2" release="$3" key
    {
        printf '%s\n' "$release"
        printf 'APP_VERSION=%s\nACCESS_MODE=%s\n' "$(rt_app_version "$domain" "$label")" "$(ep_get "$domain" ACCESS_MODE)"
        for key in "${RT_VERSION_SETTINGS[@]}"; do
            printf '%s=%s\n' "$key" "$(ep_version_get "$domain" "$label" "$key")"
        done
        sha256sum "$GB_TYPES/runtime/type.sh" "$GB_TYPES/runtime/templates/"*.tmpl "$GB_APPS/$RM_DIR/manifest.conf"
    } | sha256sum | cut -d' ' -f1
}

# Convert raw registry values to quoted systemd EnvironmentFile entries.
# Backslashes and double quotes must be escaped; dollar signs are literal in
# systemd environment files. Control characters are rejected before rendering.
rt_quote_env() {
    local source="$1" target="$2" line key value
    : > "$target" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && { printf '%s\n' "$line" >> "$target"; continue; }
        key="${line%%=*}"; value="${line#*=}"
        [[ "$value" != *$'\r'* ]] || { gb_warn "Environment values cannot contain carriage returns"; return 1; }
        value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
        printf '%s="%s"\n' "$key" "$value" >> "$target" || return 1
    done < "$source"
    chmod 0600 "$target"
}

# --- pipeline hooks ----------------------------------------------------------
type_runtime_prepare() {
    local domain="$1" kind user label
    # Transaction-local state, cleared for every domain apply.
    RT_DOMAIN="$domain"; RT_COMMITTED=false; RT_LABELS=()
    RT_CANDIDATES=(); RT_OLD_GENERATIONS=(); RT_OLD_RELEASES=(); RT_OLD_UNITS=(); RT_OLD_SOCKETS=()
    ep_load "$domain"
    kind="$EP_KIND"
    rt_manifest_load "$kind"
    user="$(rt_user "$kind")"
    gb_ensure_base_groups || return 1
    gb_ensure_system_user "$user" "$user" /nonexistent "$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$GB_CACHE/$kind" 0750 "$user:$user" || return 1
    gb_ensure_dir "$(ep_log_dir "$domain")/app" 0750 "$user:$user" || return 1
    # The cache tree is traversed by the nginx worker account; repair the
    # parents explicitly so an earlier umask-restricted creation cannot linger.
    gb_ensure_dir "$GB_PREFIX/var/cache/nginx" 0755 || return 1
    gb_ensure_dir "$GB_PREFIX/var/cache/nginx/getbible" 0755 || return 1
    # nginx -t runs as root. Pre-create each owned cache tree so its worker
    # account can read and populate cache files on every supported distro.
    gb_ensure_dir "$GB_PREFIX/var/cache/nginx/getbible/$EP_SLUG" 0750 "$GB_NGINX_USER:$GB_NGINX_USER" || return 1
    if [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
        chown -R "$GB_NGINX_USER:$GB_NGINX_USER" "$GB_PREFIX/var/cache/nginx/getbible/$EP_SLUG" || return 1
    fi
    RT_STATE_BACKUP="$(mktemp -d "$(gb_tmpdir)/runtime-state.XXXXXX")" || return 1
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
        RT_LABELS+=("$label")
        rt_prepare_endpoint "$domain" "$label" || return 1
    done < <(ep_versions "$domain")
    [[ ${#RT_LABELS[@]} -gt 0 ]] || { gb_warn "$domain has no enabled endpoint."; return 1; }
}

# Does a force flag (rebuild, redeploy, rollback) apply to LABEL? RT_ONLY_LABEL
# narrows it to one endpoint; empty means every endpoint of the domain.
rt_forced() { [[ "${1:-false}" == true && ( -z "${RT_ONLY_LABEL:-}" || "$RT_ONLY_LABEL" == "$2" ) ]]; }

# rt_prepare_endpoint DOMAIN LABEL: build or reuse the release, then prepare
# and start a candidate generation unless the active one is already current.
rt_prepare_endpoint() {
    local domain="$1" label="$2" kind user root current release inputs active generation target
    kind="$EP_KIND"; user="$(rt_user "$kind")"; root="$(rt_root "$domain" "$label")"
    ep_version_load "$domain" "$label"
    rt_validate_settings "$domain" "$label" || return 1
    rt_manifest_load "$kind" "$(rt_app_version "$domain" "$label")"
    gb_ensure_dir "$(rt_cache_root "$domain" "$label")" 0750 "$user:$user" || return 1
    gb_ensure_dir "$(rt_cache_root "$domain" "$label")/releases" 0750 "$user:$user" || return 1
    gb_ensure_dir "$root" 0755 || return 1
    gb_ensure_dir "$(rt_deployments_dir "$domain" "$label")" 0755 || return 1
    current="$(py_current_release "$root")"
    [[ -d "$current" ]] || current=""
    if [[ -z "$EV_PYTHON_VERSION" ]]; then
        if [[ -f "$current/.python-version" ]]; then
            ep_version_set "$domain" "$label" PYTHON_VERSION "$(cat "$current/.python-version")" || return 1
        else
            ep_version_set "$domain" "$label" PYTHON_VERSION "$(py_resolve_version)" || return 1
        fi
        EV_PYTHON_VERSION="$(ep_version_get "$domain" "$label" PYTHON_VERSION)"
    fi
    active="$(rt_active_generation "$domain" "$label")"
    RT_OLD_GENERATIONS[$label]="$active"; RT_OLD_RELEASES[$label]="$current"
    RT_OLD_UNITS[$label]="$(rt_live_unit "$domain" "$label")"; RT_OLD_SOCKETS[$label]="$(rt_socket "$domain" "$label")"
    for target in "$root/active" "$root/previous" "$(py_current_link "$root")" "$(rt_env_file "$domain" "$label")"; do
        gb_backup_file "$target" "$RT_STATE_BACKUP/$label" || return 1
    done

    if [[ -n "${RT_ROLLBACK_SOURCE:-}" ]] && rt_forced true "$label"; then
        [[ -f "$RT_ROLLBACK_SOURCE/.release" ]] || { gb_warn "Rollback generation is incomplete"; return 1; }
        release="$(cat "$RT_ROLLBACK_SOURCE/.release")"
        [[ -x "$release/.venv/bin/python" ]] || { gb_warn "Rollback release is missing: $release"; return 1; }
    else
        inputs="$(py_inputs_hash "$RM_DIR" "$EV_PYTHON_VERSION")" || return 1
        if rt_forced "${RT_FORCE_BUILD:-false}" "$label" || [[ ! -d "$current" || "$(py_release_inputs "$current")" != "$inputs" ]]; then
            release="$(py_build_release "$root" "$domain $label" "$EV_PYTHON_VERSION" "$RM_DIR")" || return 1
        else
            release="$current"
            gb_log "Release $release is current."
        fi
    fi
    if [[ "$GB_DRY_RUN" != true ]]; then
        gb_ensure_dir "$(dirname -- "$(rt_cache_dir "$domain" "$label" "$release")")" 0750 "$user:$user" || return 1
        gb_ensure_dir "$(rt_cache_dir "$domain" "$label" "$release")" 0750 "$user:$user" || return 1
    fi
    inputs="$(rt_deployment_inputs "$domain" "$label" "$release")" || return 1
    if ! rt_forced "${RT_FORCE_DEPLOY:-false}" "$label" && [[ -n "$active" && -f "$active/.inputs" && "$(cat "$active/.inputs")" == "$inputs" ]]; then
        if ! sd_available || sd_is_active "$(rt_generation_unit "$domain" "$label" "$active").service"; then
            gb_log "Runtime generation $(basename "$active") of $domain $label is current."
            return 0
        fi
    fi
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would prepare a runtime generation for $domain $label"; return 0; }
    generation="$(mktemp -d "$(rt_deployments_dir "$domain" "$label")/$(date -u +%Y%m%dT%H%M%S)-XXXXXX")" || return 1
    chmod 0755 "$generation" || return 1
    RT_CANDIDATES[$label]="$generation"
    printf '%s\n' "$release" > "$generation/.release" || return 1
    printf '%s\n' "$inputs" > "$generation/.inputs" || return 1
    gb_install_file "$(ep_conf "$domain")" "$generation/endpoint.conf" 0600 || return 1
    gb_install_file "$(ep_version_conf "$domain" "$label")" "$generation/version.conf" 0600 || return 1
    rt_render_env "$domain" "$label" "$generation" || return 1
    rt_render_gunicorn "$domain" "$label" "$generation" || return 1
    rt_render_units "$domain" "$label" "$generation" "$release" || return 1
    rt_activate "$domain" "$label" "$generation"
}

# A cheap setup check: the published version directory must already exist.
# Repository content is trusted; do not scan, parse or hash the scripture tree.
rt_validate_repository() {
    local root="$1" version="$2"
    [[ "$root" == /* ]] || { gb_warn "Scripture repository must be an absolute local path; remote API URLs are not supported: $root"; return 1; }
    [[ -d "$root/$version" && -r "$root/$version" && -x "$root/$version" ]] || {
        gb_warn "Local scripture folder $root/$version is unavailable. Sync the static endpoint first, then choose its data root."
        return 1
    }
}

# Retain the old helper for callers; validation happens before release work.
rt_check_repository() {
    rt_validate_repository "$(ep_version_get "$1" "$2" REPOSITORY)" "$(rt_app_version "$1" "$2")"
}

# The render functions take DOMAIN LABEL GENERATION and rely on EP_* (the
# domain), EV_* (the endpoint) and RM_* (its implementation) being loaded.
rt_render_env() {
    local domain="$1" label="$2" generation="$3" stage is_query=false is_search=false expensive release threads
    stage="$(gb_tmpdir)/runtime.env.$EP_SLUG.$label"
    release="$(cat "$generation/.release")" || return 1
    [[ "$EP_KIND" == query ]] && is_query=true
    [[ "$EP_KIND" == search ]] && is_search=true
    threads="${EV_THREADS:-$RM_THREADS}"
    expensive=$(( threads / 2 )); (( expensive < 1 )) && expensive=1
    gb_render "$GB_TYPES/runtime/templates/env.tmpl" "$stage" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "LABEL=$label" "REPOSITORY=$EV_REPOSITORY" "VERSION=$(rt_app_version "$domain" "$label")" \
        "CACHE_DIR=$(rt_cache_dir "$domain" "$label" "$release")" "CACHE_TTL_SECONDS=900" \
        "APP_LOG=$(rt_app_log "$domain" "$label")" "ENV_PREFIX=$RM_ENV_PREFIX" "ACCESS_MODE=$EP_ACCESS_MODE" \
        "DEFAULT_TRANSLATION=${EV_DEFAULT_TRANSLATION:-kjv}" "ALLOWED_TRANSLATIONS=$EV_ALLOWED_TRANSLATIONS" \
        "CACHE_SECONDS=${EV_CACHE_TTL:-$RM_CACHE_SECONDS}" "WORKERS=${EV_WORKERS:-$RM_WORKERS}" \
        "THREADS=$threads" "WARM_TRANSLATIONS=$EV_WARM_TRANSLATIONS" \
        "SOCKET=$(rt_generation_socket "$domain" "$label" "$generation")" "IS_QUERY=$is_query" "IS_SEARCH=$is_search" \
        "DEFAULT_REFERENCE=${EV_DEFAULT_REFERENCE:-Mat7:7}" "EXPENSIVE_CONCURRENT=$expensive" "EXTRA_ENV=" || return 1
    rt_quote_env "$stage" "$generation/runtime.env"
}

rt_render_gunicorn() {
    local domain="$1" label="$2" generation="$3" timeout=60
    [[ "$EP_KIND" == search ]] && timeout=30
    gb_render "$GB_TYPES/runtime/templates/gunicorn.conf.py.tmpl" "$generation/gunicorn.conf.py" \
        "KIND=$EP_KIND" "ENV_PREFIX=$RM_ENV_PREFIX" "SOCKET=$(rt_generation_socket "$domain" "$label" "$generation")" \
        "WORKERS=${EV_WORKERS:-$RM_WORKERS}" "THREADS=${EV_THREADS:-$RM_THREADS}" \
        "WORKER_TIMEOUT=$timeout" "PACKAGE=$RM_PACKAGE" || return 1
    chmod 0644 "$generation/gunicorn.conf.py"
}

rt_render_units() {
    local domain="$1" label="$2" generation="$3" release="$4" unit user
    unit="$(rt_generation_unit "$domain" "$label" "$generation")"
    user="$(rt_user "$EP_KIND")"
    SD_UNITS_CHANGED=false
    gb_render "$GB_TYPES/runtime/templates/socket.tmpl" "$generation/socket.unit" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "LABEL=$label" "SOCKET=$(rt_generation_socket "$domain" "$label" "$generation")" \
        "USER=$user" "NGINX_USER=$GB_NGINX_USER" || return 1
    gb_render "$GB_TYPES/runtime/templates/service.tmpl" "$generation/service.unit" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "LABEL=$label" "PREFIX=$(pages_prefix "$label")" "UNIT=$unit" "USER=$user" \
        "READERS_GROUP=$GB_READERS_GROUP" "RELEASE=$release" "GENERATION=$generation" "ENV_FILE=$generation/runtime.env" \
        "CHECK=$RM_CHECK" "WSGI=$RM_WSGI" "TIMEOUT_START=$RM_TIMEOUT_START" "TIMEOUT_STOP=$RM_TIMEOUT_STOP" \
        "CACHE_SUBDIR=$(rt_cache_subdir "$domain" "$label")" "LOGS_SUBDIR=getbible/$domain/app" || return 1
    gb_render "$GB_TYPES/runtime/templates/limits.conf.tmpl" "$generation/limits.conf" \
        "KIND=$EP_KIND" "MEMORY_HIGH=$RM_MEMORY_HIGH" "MEMORY_MAX=$RM_MEMORY_MAX" \
        "CPU_QUOTA=$RM_CPU_QUOTA" "TASKS_MAX=$RM_TASKS_MAX" "NOFILE=$RM_NOFILE" || return 1
    sd_install_unit "$generation/socket.unit" "$unit.socket" || return 1
    sd_install_unit "$generation/service.unit" "$unit.service" || return 1
    sd_install_dropin "$generation/limits.conf" "$unit.service" "10-limits.conf" || return 1
    sd_daemon_reload
}

# Start a candidate on its own socket. The live process, symlink and nginx
# configuration remain unchanged until the caller successfully reloads nginx.
rt_activate() {
    local domain="$1" label="$2" generation="$3" unit socket
    unit="$(rt_generation_unit "$domain" "$label" "$generation")"
    socket="$(rt_generation_socket "$domain" "$label" "$generation")"
    if ! sd_available; then
        gb_log "(no systemd) prepared $generation; readiness is not checked in this sandbox."
        return 0
    fi
    gb_step "Starting candidate $unit.service"
    if ! sd_start "$unit.socket" || ! sd_start "$unit.service" || ! sd_wait_ready "$socket" /readyz "$RM_TIMEOUT_START" \
        || { [[ "$EP_KIND" == search ]] && ! sd_wait_ready "$socket" /probez "$RM_TIMEOUT_START"; }; then
        gb_warn "$unit.service did not become ready; the live service has not been replaced."
        sd_journal "$unit.service" 40 | tail -40 || true
        return 1
    fi
    gb_log "Candidate $unit.service is ready; awaiting nginx activation."
}

rt_token_required() { if [[ "$EP_ACCESS_MODE" == token ]]; then printf 'true\n'; else printf 'false\n'; fi; }

# rt_render_proxy_body DOMAIN LABEL OUTPUT [PROXY_PATH]: the directives that
# hand a request to the endpoint's service (used by every location that
# proxies to it). PROXY_PATH is the URI proxy_pass sends instead of the
# request's own: for a root endpoint, the version plus the raw request URI.
rt_render_proxy_body() {
    local domain="$1" label="$2" output="$3" proxy_path="${4:-}"
    rt_manifest_load "$EP_KIND" "$(rt_app_version "$domain" "$label")"
    gb_render "$GB_TYPES/runtime/templates/proxy-body.conf.tmpl" "$output" \
        "DOMAIN=$domain" "SLUG=$EP_SLUG" "SOCKET=$(rt_proxy_socket "$domain" "$label")" "NGINX_GB_DIR=$GB_NGINX_GB" \
        "CACHE_TTL=$(ep_version_get "$domain" "$label" CACHE_TTL "$RM_CACHE_SECONDS")" "TOKEN_ACCESS=$(rt_token_required)" \
        "PROXY_PATH=$proxy_path"
}

# nginx locations for a runtime domain: for every endpoint its page, OpenAPI
# document and the proxy to its own service; then health and the fallback
# (the short forms, or the whole tree for a root endpoint) to the default
# endpoint's service.
type_runtime_render_locations() {
    local output="$1" label piece proxy default root_endpoint=false is_root proxy_path
    local -a page openapi
    rt_manifest_load "$EP_KIND"
    TYPE_METHODS_REGEX="$RM_METHODS"
    TYPE_REJECT_ARGS=false
    TYPE_MAX_BODY="$RM_MAX_BODY"
    TYPE_PROXY_CACHE=true
    : > "$output"
    # shellcheck disable=SC2153 # EP_DOMAIN is loaded by the domain registry.
    default="$(type_runtime_default_endpoint "$EP_DOMAIN")"
    [[ -n "$default" ]] || { gb_warn "$EP_DOMAIN has no endpoint to route to."; return 1; }
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$EP_DOMAIN" "$label" ENABLED true)" == true ]] || continue
        is_root=false
        if pages_is_root "$label"; then is_root=true; fi
        mapfile -t page < <(pages_docs_location "$EP_DOMAIN" "$label")
        mapfile -t openapi < <(pages_openapi_location "$EP_DOMAIN" "$label")
        proxy="$(gb_tmpdir)/rt-proxy-$EP_SLUG-$label"
        rt_render_proxy_body "$EP_DOMAIN" "$label" "$proxy" || return 1
        piece="$(gb_tmpdir)/rt-loc-$EP_SLUG-$label"
        gb_render "$GB_TYPES/runtime/templates/endpoint-locations.conf.tmpl" "$piece" \
            "DOMAIN=$EP_DOMAIN" "VERSION=$label" "IS_ROOT=$is_root" "DOCS_ROOT=${page[0]:-}" "DOCS_FILE=${page[1]:-}" \
            "OPENAPI_ROOT=${openapi[0]:-}" "OPENAPI_FILE=${openapi[1]:-}" "PROXY_BODY=$(cat "$proxy")" || return 1
        cat "$piece" >> "$output"
    done < <(type_runtime_endpoints "$EP_DOMAIN")
    proxy_path=""
    if pages_is_root "$default"; then
        root_endpoint=true
        # shellcheck disable=SC2016 # an nginx variable, expanded by nginx
        proxy_path="/$(rt_app_version "$EP_DOMAIN" "$default")"'$request_uri'
    fi
    mapfile -t page < <(pages_docs_location "$EP_DOMAIN" "$default")
    proxy="$(gb_tmpdir)/rt-proxy-$EP_SLUG-default"
    rt_render_proxy_body "$EP_DOMAIN" "$default" "$proxy" "$proxy_path" || return 1
    piece="$(gb_tmpdir)/rt-loc-$EP_SLUG"
    gb_render "$GB_TYPES/runtime/templates/locations.conf.tmpl" "$piece" \
        "DOMAIN=$EP_DOMAIN" "SOCKET=$(rt_proxy_socket "$EP_DOMAIN" "$default")" "ROOT_ENDPOINT=$root_endpoint" \
        "APP_VERSION=$(rt_app_version "$EP_DOMAIN" "$default")" "ROOT_DOCS_ROOT=${page[0]:-}" "ROOT_DOCS_FILE=${page[1]:-}" \
        "PROXY_BODY=$(cat "$proxy")" || return 1
    cat "$piece" >> "$output"
}

type_runtime_before_switch() {
    local domain="$1" label unit generation
    [[ "${RT_DOMAIN:-}" == "$domain" && "$GB_DRY_RUN" != true ]] || return 0
    RT_NGINX_SNAPSHOT="$RT_STATE_BACKUP/nginx-workers"
    [[ -f "$RT_NGINX_SNAPSHOT" ]] || sd_snapshot_nginx_workers "$RT_NGINX_SNAPSHOT" || return 1
    for label in "${RT_LABELS[@]}"; do
        generation="${RT_CANDIDATES[$label]:-}"
        [[ -n "$generation" ]] || continue
        # The snapshot must outlive this run: the retirement of the old
        # service waits for these exact nginx workers to exit.
        gb_install_file "$RT_NGINX_SNAPSHOT" "$generation/nginx-workers" 0600 || return 1
        # Before nginx can persist a route to this socket, the healthy
        # candidate must be enabled for boot. A power loss between reload
        # and pointer commit can then recover either old or new routing.
        unit="$(rt_generation_unit "$domain" "$label" "$generation")"
        sd_enable "$unit.socket" "$unit.service" || return 1
    done
}

# Called only after every nginx validation/reload succeeded. The old runtime
# stays enabled until its healthy replacement has been durably selected.
type_runtime_finish() {
    local domain="$1" label generation kind unit release root
    [[ "${RT_DOMAIN:-}" == "$domain" ]] || return 0
    kind="$(ep_get "$domain" KIND)"
    if [[ ${#RT_CANDIDATES[@]} -eq 0 ]]; then
        [[ "$GB_DRY_RUN" == true ]] || rt_reap_unselected "$domain"
        return 0
    fi
    RT_COMMITTED=true
    # First every endpoint's pointers and environment: a failure here aborts
    # with every old service still enabled and running, so the caller can
    # restore the old routing and state of all of them.
    for label in "${RT_LABELS[@]}"; do
        generation="${RT_CANDIDATES[$label]:-}"
        [[ -n "$generation" ]] || continue
        root="$(rt_root "$domain" "$label")"
        unit="$(rt_generation_unit "$domain" "$label" "$generation")"
        release="$(cat "$generation/.release")" || return 1
        sd_enable "$unit.socket" "$unit.service" || return 1
        [[ -z "${RT_OLD_GENERATIONS[$label]:-}" ]] || rt_switch_link "${RT_OLD_GENERATIONS[$label]}" "$root/previous" || return 1
        py_switch_release "$root" "$release" || return 1
        gb_install_file "$generation/runtime.env" "$(rt_env_file "$domain" "$label")" 0600 || return 1
        rt_switch_link "$generation" "$root/active" || return 1
        gb_ledger_record "$(rt_env_file "$domain" "$label")" || return 1
    done
    # Then, with everything selected, retire the old services and prune.
    for label in "${RT_LABELS[@]}"; do
        generation="${RT_CANDIDATES[$label]:-}"
        [[ -n "$generation" ]] || continue
        release="$(cat "$generation/.release")" || return 1
        if [[ -n "${RT_OLD_RELEASES[$label]:-}" ]]; then
            # Old nginx workers may still issue upstream requests after reload.
            # Keep their backend alive until those exact processes have exited.
            sd_retire_after "${RT_OLD_UNITS[$label]}" "$generation/nginx-workers" || gb_warn "Old generation of $domain $label remains running; check the service journal before retiring it manually."
        fi
        tg_notify ok "Runtime release live: $domain $label" "$kind generation $(basename "$generation"), release $(basename "$release")."
        rt_prune_generations "$domain" "$label"
    done
    rt_reap_unselected "$domain"
    RT_CANDIDATES=()
    return 0
}

# An interrupted CLI may leave a candidate running but unselected. Collect it
# only after a later successful nginx reload, with that reload's drain gate.
rt_reap_unselected() {
    local domain="$1" label active previous generation unit
    [[ -n "${RT_NGINX_SNAPSHOT:-}" && -f "$RT_NGINX_SNAPSHOT" ]] || return 0
    while read -r label; do
        [[ -n "$label" ]] || continue
        active="$(rt_active_generation "$domain" "$label")"; previous="$(rt_previous_generation "$domain" "$label")"
        while IFS= read -r generation; do
            [[ "$generation" == "$active" || "$generation" == "$previous" ]] && continue
            unit="$(rt_generation_unit "$domain" "$label" "$generation")"
            if sd_is_active "$unit.service"; then
                sd_retire_after "$unit" "$RT_NGINX_SNAPSHOT" || gb_warn "Retaining unselected $unit until its requests can drain."
            fi
        done < <(find "$(rt_deployments_dir "$domain" "$label")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    done < <(ep_versions "$domain")
    return 0
}

# The caller restores nginx before aborting if it had already switched traffic.
type_runtime_abort() {
    local domain="$1" label generation root unit target recovered=true
    [[ "${RT_DOMAIN:-}" == "$domain" ]] || return 0
    for label in "${RT_LABELS[@]}"; do
        root="$(rt_root "$domain" "$label")"
        if [[ "${RT_COMMITTED:-false}" == true ]]; then
            for target in "$root/active" "$root/previous" "$(py_current_link "$root")" "$(rt_env_file "$domain" "$label")"; do
                gb_restore_file "$target" "$RT_STATE_BACKUP/$label" || recovered=false
            done
        fi
        generation="${RT_CANDIDATES[$label]:-}"
        if [[ -n "$generation" ]]; then
            unit="$(rt_generation_unit "$domain" "$label" "$generation")"
            sd_remove_unit "$unit.service"
            sd_remove_unit "$unit.socket"
            rm -rf -- "$generation"
        fi
    done
    sd_daemon_reload || recovered=false
    for label in "${RT_LABELS[@]}"; do
        if [[ -n "${RT_OLD_RELEASES[$label]:-}" ]] && sd_available; then
            if ! sd_wait_ready "${RT_OLD_SOCKETS[$label]}" /readyz 15; then
                recovered=false
                gb_warn "Previous runtime of $domain $label is not ready; manual recovery is required."
            fi
        fi
    done
    RT_CANDIDATES=(); RT_COMMITTED=false
    if [[ "$recovered" == true ]]; then
        tg_notify fail "Runtime deployment rejected: $domain" "The candidates were removed; the previous runtime and configuration remain selected."
    else
        tg_notify fail "Runtime recovery needs attention: $domain" "The previous service did not pass recovery verification. Inspect its journal."
    fi
    [[ "$recovered" == true ]]
}

rt_prune_generations() {
    local domain="$1" label="$2" generation active previous unit cache root
    root="$(rt_root "$domain" "$label")"
    active="$(rt_active_generation "$domain" "$label")"; previous="$(rt_previous_generation "$domain" "$label")"
    while IFS= read -r generation; do
        [[ "$generation" == "$active" || "$generation" == "$previous" ]] && continue
        unit="$(rt_generation_unit "$domain" "$label" "$generation")"
        # A still-draining service must retain its interpreter and config.
        sd_is_active "$unit.service" && continue
        sd_remove_unit "$unit.service"
        sd_remove_unit "$unit.socket"
        rm -rf -- "$generation"
    done < <(find "$(rt_deployments_dir "$domain" "$label")" -mindepth 1 -maxdepth 1 -type d -mmin +2 2>/dev/null)
    py_prune_releases "$root" 3
    while IFS= read -r cache; do
        [[ -d "$(py_releases_dir "$root")/$(basename -- "$cache")" ]] || rm -rf -- "$cache"
    done < <(find "$(rt_cache_root "$domain" "$label")/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# rt_remove_endpoint_services DOMAIN LABEL: stop and forget every generation
# of one endpoint and its environment file.
rt_remove_endpoint_services() {
    local domain="$1" label="$2" generation unit
    while IFS= read -r generation; do
        unit="$(rt_generation_unit "$domain" "$label" "$generation")"
        sd_remove_unit "$unit.service"; sd_remove_unit "$unit.socket"
    done < <(find "$(rt_deployments_dir "$domain" "$label")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    rm -f -- "$(rt_env_file "$domain" "$label")"
}

type_runtime_remove() {
    local domain="$1" purge="$2" kind user label
    kind="$(ep_get "$domain" KIND)"; user="$(rt_user "$kind")"
    while read -r label; do
        [[ -n "$label" ]] || continue
        rt_remove_endpoint_services "$domain" "$label"
    done < <(ep_versions "$domain")
    sd_daemon_reload
    if [[ "$purge" == true ]]; then
        rm -rf -- "${GB_OPT:?}/${kind:?}" "${GB_CACHE:?}/${kind:?}" "$GB_PREFIX/var/cache/nginx/getbible/$(gb_slug "$domain")"
        if gb_user_exists "$user" && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then userdel "$user" 2>/dev/null || true; fi
    fi
}

type_runtime_status() {
    local domain="$1" kind label unit socket release root default
    kind="$(ep_get "$domain" KIND)"
    default="$(type_runtime_default_endpoint "$domain")"
    printf 'Kind        : %s (versions available: %s)\n' "$kind" "$(rt_kind_versions "$kind" | tr '\n' ' ')"
    printf 'Default     : %s (answers /, the short forms, /healthz and /readyz)\n' "$(pages_label_text "$default")"
    printf 'Cache root  : %s\n' "$GB_CACHE/$kind"
    while read -r label; do
        [[ -n "$label" ]] || continue
        root="$(rt_root "$domain" "$label")"; unit="$(rt_live_unit "$domain" "$label")"; socket="$(rt_socket "$domain" "$label")"; release="$(py_current_release "$root")"
        printf '\nEndpoint %s of %s (%s)\n' "$(pages_label_text "$label")" "$domain" "$(rt_app_version "$domain" "$label")"
        printf '  Service   : %s (%s)\n' "$unit.service" "$(sd_status_line "$unit.service")"
        printf '  Socket    : %s (%s)\n' "$socket" "$(sd_status_line "$unit.socket")"
        printf '  Generation: %s\n' "$(rt_active_generation "$domain" "$label")"
        printf '  Rollback  : %s\n' "$(rt_previous_generation "$domain" "$label")"
        printf '  Release   : %s\n' "$release"
        printf '  Python    : %s\n' "$(cat "$release/.python-version" 2>/dev/null || echo unavailable)"
        printf '  Repository: %s (%s)\n' "$(ep_version_get "$domain" "$label" REPOSITORY)" "$(rt_app_version "$domain" "$label")"
        printf '  Workers   : %s x %s threads; warm: %s\n' "$(ep_version_get "$domain" "$label" WORKERS)" "$(ep_version_get "$domain" "$label" THREADS)" "$(ep_version_get "$domain" "$label" WARM_TRANSLATIONS "-")"
        printf '  App log   : %s\n' "$(rt_app_log "$domain" "$label")"
        if [[ -S "$socket" ]]; then
            printf '  Liveness  : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/healthz 2>/dev/null | ui_health_text || echo unreachable)"
            printf '  Readiness : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/readyz 2>/dev/null | ui_health_text || echo unreachable)"
        fi
        if sd_available; then "$GB_SYSTEMCTL" show "$unit.service" --no-pager --property=MainPID,ActiveEnterTimestamp,MemoryCurrent,TasksCurrent,NRestarts 2>/dev/null | ui_service_text; fi
    done < <(type_runtime_endpoints "$domain")
}

# --- pages (pages.sh hooks) --------------------------------------------------
# rt_example_path DOMAIN LABEL: the example request below the endpoint's prefix.
rt_example_path() {
    local translation
    translation="$(ep_version_get "$1" "$2" DEFAULT_TRANSLATION kjv)"
    if [[ "$(ep_get "$1" KIND)" == search ]]; then printf '%s/faith%%20hope\n' "$translation"; else printf '%s/John3:16\n' "$translation"; fi
}

# type_runtime_render_endpoint_docs DOMAIN LABEL OUTPUT: the implementation's
# page for one endpoint (EP_* loaded by the caller).
type_runtime_render_endpoint_docs() {
    local domain="$1" label="$2" output="$3" access favicon=false openapi_url="" prefix is_root=false version version_path
    ep_version_load "$domain" "$label"
    version="$(rt_app_version "$domain" "$label")"
    rt_manifest_load "$EP_KIND" "$version"
    prefix="$(pages_prefix "$label")"
    version_path="${prefix%/}"; [[ -n "$version_path" ]] || version_path=/
    if pages_is_root "$label"; then is_root=true; fi
    access="$(gb_tmpdir)/access-$EP_SLUG-$label.html"
    docs_render_access "$access" "$prefix" "$(rt_example_path "$domain" "$label")"
    if pages_favicon_active "$domain"; then favicon=true; fi
    [[ "$(pages_openapi_source "$domain" "$label")" == none ]] || openapi_url="${prefix}openapi.json"
    gb_render "$GB_APPS/$RM_DIR/docs.html.tmpl" "$output" "DOMAIN=$domain" \
        "CSS=$(cat "$GB_DOCS_SRC/base.css")" "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" \
        "VERSION=$version" "PREFIX=$prefix" "VERSION_PATH=$version_path" "IS_ROOT=$is_root" "DEFAULT_TRANSLATION=${EV_DEFAULT_TRANSLATION:-kjv}" \
        "DEFAULT_REFERENCE=${EV_DEFAULT_REFERENCE:-Mat7:7}" "ACCESS_HTML=$(cat "$access")" \
        "CACHE_SECONDS=${EV_CACHE_TTL:-$RM_CACHE_SECONDS}" "TOKEN_REQUIRED=$(rt_token_required)" \
        "FAVICON=$favicon" "OPENAPI_URL=$openapi_url" \
        "HEAD_ICONS=$(docs_head_icons "$domain")" "LOGO_URL=$(docs_logo_url "$domain")" "ICON_URL=$(docs_icon_url "$domain")"
}

# type_runtime_render_openapi DOMAIN LABEL OUTPUT: the implementation's OpenAPI
# document for one endpoint, checked to be valid JSON before it is published.
type_runtime_render_openapi() {
    local domain="$1" label="$2" output="$3" version prefix version_path
    ep_version_load "$domain" "$label"
    version="$(rt_app_version "$domain" "$label")"
    rt_manifest_load "$EP_KIND" "$version"
    prefix="$(pages_prefix "$label")"
    version_path="${prefix%/}"; [[ -n "$version_path" ]] || version_path=/
    gb_render "$GB_APPS/$RM_DIR/openapi.json.tmpl" "$output" "DOMAIN=$domain" "VERSION=$version" "PREFIX=$prefix" \
        "VERSION_PATH=$version_path" "IS_ROOT=$(pages_is_root "$label" && printf true || printf false)" \
        "DEFAULT_TRANSLATION=${EV_DEFAULT_TRANSLATION:-kjv}" "DEFAULT_REFERENCE=${EV_DEFAULT_REFERENCE:-Mat7:7}" \
        "TOKEN_REQUIRED=$(rt_token_required)" || return 1
    "$GB_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$output" || { gb_warn "The rendered OpenAPI document for $domain $label is not valid JSON."; return 1; }
}

# One table row per endpoint for the domain page.
rt_endpoint_rows() {
    local domain="$1" label route page openapi
    while read -r label; do
        [[ -n "$label" ]] || continue
        rt_manifest_load "$EP_KIND" "$(rt_app_version "$domain" "$label")"
        route="${RM_ROUTE//\{version\}/$label}"
        page="no page"
        [[ "$(pages_docs_source "$domain" "$label")" == none ]] || page="<a href=\"/$label/\">/$label/</a>"
        openapi="no OpenAPI document"
        if [[ "$(pages_openapi_source "$domain" "$label")" != none ]] && pages_file_present "$domain" "$label" openapi; then
            openapi="<a href=\"/$label/openapi.json\">openapi.json</a>"
        fi
        printf '<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$label" "$route" "$page" "$openapi"
    done < <(type_runtime_endpoints "$domain")
    return 0
}

# The domain page of a runtime domain: one row per endpoint (version).
type_runtime_render_docs() {
    local output="$1" access favicon=false default
    rt_manifest_load "$EP_KIND"
    default="$(type_runtime_default_endpoint "$EP_DOMAIN")"
    access="$(gb_tmpdir)/access-$EP_SLUG.html"
    docs_render_access "$access" "$(pages_prefix "$default")" "$(rt_example_path "$EP_DOMAIN" "$default")"
    if pages_favicon_active "$EP_DOMAIN"; then favicon=true; fi
    gb_render "$GB_DOCS_SRC/runtime.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" "KIND=$EP_KIND" \
        "DESCRIPTION=$RM_DESCRIPTION" "CSS=$(cat "$GB_DOCS_SRC/base.css")" \
        "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" "ENDPOINT_ROWS=$(rt_endpoint_rows "$EP_DOMAIN")" \
        "EXAMPLE_PATH=${default}/$(rt_example_path "$EP_DOMAIN" "$default")" "ACCESS_HTML=$(cat "$access")" "FAVICON=$favicon" \
        "HEAD_ICONS=$(docs_head_icons "$EP_DOMAIN")" "LOGO_URL=$(docs_logo_url "$EP_DOMAIN")" "ICON_URL=$(docs_icon_url "$EP_DOMAIN")"
}

# --- registry: domains and endpoints ------------------------------------------
# rt_record_endpoint DOMAIN LABEL VERSION REPOSITORY WARM [PYTHON]: write the
# endpoint's record with the implementation's defaults (versioned layout).
rt_record_endpoint() {
    local domain="$1" label="$2" version="$3" repository="$4" warm="$5" python="${6:-}" conf
    rt_manifest_load "$(ep_get "$domain" KIND)" "$version"
    rt_validate_repository "$repository" "$version" || return 1
    conf="$(ep_version_conf "$domain" "$label")"
    gb_ensure_dir "$(ep_versions_dir "$domain")" 0750 || return 1
    cfg_set "$conf" LABEL "$label"
    cfg_set "$conf" ENABLED true
    cfg_set "$conf" CREATED "$(gb_timestamp)"
    cfg_set "$conf" APP_VERSION "$version"
    cfg_set "$conf" REPOSITORY "$repository"
    cfg_set "$conf" WORKERS "$RM_WORKERS"
    cfg_set "$conf" THREADS "$RM_THREADS"
    cfg_set "$conf" WARM_TRANSLATIONS "$warm"
    cfg_set "$conf" DEFAULT_TRANSLATION kjv
    cfg_set "$conf" DEFAULT_REFERENCE "Mat7:7"
    cfg_set "$conf" ALLOWED_TRANSLATIONS ""
    cfg_set "$conf" CACHE_TTL "$RM_CACHE_SECONDS"
    cfg_set "$conf" PYTHON_VERSION "$(py_resolve_version "${python:-auto}")"
    chmod 0640 "$conf" 2>/dev/null || true
}

# rt_check_new_endpoint DOMAIN LABEL VERSION: may VERSION be added as LABEL?
rt_check_new_endpoint() {
    local domain="$1" label="$2" version="$3" kind existing
    kind="$(ep_get "$domain" KIND)"
    gb_valid_endpoint_label "$label" || { gb_warn "Invalid endpoint label: $label (v1, v2, ... or root)"; return 1; }
    gb_valid_version "$version" || { gb_warn "Invalid version: $version"; return 1; }
    rt_implementation "$kind" "$version" >/dev/null || { gb_warn "The $kind service has no implementation of $version (available: $(rt_kind_versions "$kind" | tr '\n' ' '))"; return 1; }
    pages_is_root "$label" || [[ "$label" == "$version" ]] || { gb_warn "A version folder is named after its version ($version), or root."; return 1; }
    existing="$(ep_versions "$domain" | tr '\n' ' ')"; existing="${existing% }"
    [[ -n "$existing" ]] || return 0
    ep_version_exists "$domain" "$label" && { gb_warn "$domain already has the endpoint $label."; return 1; }
    if pages_is_root "$label"; then
        gb_warn "$domain already serves version folders ($existing); its root cannot become an endpoint as well."; return 1
    elif [[ "$existing" == "$GB_ROOT_LABEL" ]]; then
        gb_warn "$domain serves its only endpoint at the domain root; remove that endpoint before adding version folders."; return 1
    fi
}

# type_runtime_create DOMAIN KIND VERSION REPOSITORY ACCESS WARM [LABEL] [PYTHON]
type_runtime_create() {
    local domain="$1" kind="$2" version="$3" repository="$4" mode="$5" warm="$6" label="${7:-$3}" python="${8:-}" existing
    rt_manifest_load "$kind"
    access_valid_mode "$mode" || gb_die "Invalid access mode: $mode"
    gb_valid_version "$version" || gb_die "Invalid version: $version"
    rt_implementation "$kind" "$version" >/dev/null || gb_die "The $kind service has no implementation of $version (available: $(rt_kind_versions "$kind" | tr '\n' ' '))"
    gb_valid_endpoint_label "$label" || gb_die "Invalid endpoint label: $label"
    existing="$(rt_kind_deployed_on "$kind")"
    [[ -z "$existing" ]] || gb_die "The $kind service is already deployed on $existing (one domain per kind; add versions to it instead)."
    rt_validate_repository "$repository" "$version" || return 1
    if [[ -n "$warm" ]]; then
        [[ "$warm" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || gb_die "Invalid warm-up translation list: $warm"
    fi
    ep_create "$domain" runtime "$kind"
    ep_set "$domain" ACCESS_MODE "$mode"
    ep_set "$domain" DEFAULT_ENDPOINT "$label"
    rt_record_endpoint "$domain" "$label" "$version" "$repository" "$warm" "$python"
}

# rt_add_endpoint DOMAIN VERSION REPOSITORY WARM PYTHON DEFAULT_TRANSLATION DEFAULT_REFERENCE
rt_add_endpoint() {
    local domain="$1" version="$2" repository="$3" warm="$4" python="$5" translation="$6" reference="$7"
    rt_check_new_endpoint "$domain" "$version" "$version" || return 1
    [[ -n "$repository" ]] || repository="$(rt_default_repository "$version")"
    [[ -n "$repository" ]] || repository="$(ep_version_get "$domain" "$(type_runtime_default_endpoint "$domain")" REPOSITORY)"
    rt_validate_repository "$repository" "$version" || return 1
    [[ -z "$warm" || "$warm" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || { gb_warn "Invalid warm-up translation list: $warm"; return 1; }
    [[ -z "$translation" ]] || gb_valid_translation "$translation" || { gb_warn "Invalid default translation: $translation"; return 1; }
    rt_manifest_load "$(ep_get "$domain" KIND)" "$version"
    [[ -n "$warm" ]] || warm="$RM_WARM_TRANSLATIONS"
    rt_record_endpoint "$domain" "$version" "$version" "$repository" "$warm" "$python" || return 1
    [[ -z "$translation" ]] || ep_version_set "$domain" "$version" DEFAULT_TRANSLATION "$translation"
    [[ -z "$reference" ]] || ep_version_set "$domain" "$version" DEFAULT_REFERENCE "$reference"
    if ! endpoint_apply "$domain"; then
        gb_warn "The new endpoint could not be deployed; its record stays so you can fix the cause and re-apply, or remove it."
        return 1
    fi
    tg_notify ok "Endpoint added: $domain $version" "The $(ep_get "$domain" KIND) service now also serves https://$domain/$version/."
}

# rt_remove_endpoint DOMAIN LABEL: take the endpoint out of nginx first
# (disabled, it renders no locations), then stop its service and delete its
# releases, cache, pages and record.
rt_remove_endpoint() {
    local domain="$1" label="$2" remaining root default
    ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label"; return 1; }
    remaining="$(ep_versions "$domain" | grep -vx -- "$label" | head -1)"
    [[ -n "$remaining" ]] || { gb_warn "$label is the only endpoint of $domain; remove the domain instead."; return 1; }
    root="$(rt_root "$domain" "$label")"
    default="$(ep_get "$domain" DEFAULT_ENDPOINT)"
    ep_version_set "$domain" "$label" ENABLED false
    [[ "$default" != "$label" ]] || ep_set "$domain" DEFAULT_ENDPOINT "$remaining"
    if ! endpoint_apply "$domain"; then
        ep_version_set "$domain" "$label" ENABLED true
        ep_set "$domain" DEFAULT_ENDPOINT "$default"
        gb_warn "nginx could not be switched away from $label; the endpoint stays."
        return 1
    fi
    # No request reaches the service any more; take it down and clean up.
    rt_remove_endpoint_services "$domain" "$label"
    sd_daemon_reload
    rm -rf -- "$root"
    rm -rf -- "$(rt_cache_root "$domain" "$label")"
    rm -rf -- "$(pages_endpoint_dir "$domain" "$label")"
    ep_version_remove_config "$domain" "$label"
    pages_publish "$domain" || gb_warn "The domain's pages could not be refreshed; re-apply $domain."
    tg_notify warn "Endpoint removed: $domain $label" "Its service, releases and cache were deleted; $(ep_get "$domain" DEFAULT_ENDPOINT) is the default endpoint."
}

# rt_set_default DOMAIN LABEL: the endpoint that answers / and the short forms.
rt_set_default() {
    local domain="$1" label="$2"
    ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label"; return 1; }
    ep_set "$domain" DEFAULT_ENDPOINT "$label"
    endpoint_apply "$domain" || return 1
    tg_notify info "Default endpoint: $domain" "$label now answers / and the short forms."
}

# rt_resolve_label DOMAIN [LABEL]: LABEL when given and existing; the only
# endpoint when the domain has one; otherwise an explanation and failure.
rt_resolve_label() {
    local domain="$1" label="${2:-}" count
    if [[ -n "$label" ]]; then
        ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label (endpoints: $(ep_versions "$domain" | tr '\n' ' '))"; return 1; }
        printf '%s\n' "$label"
        return 0
    fi
    count="$(type_runtime_endpoints "$domain" | grep -c .)"
    if (( count == 1 )); then ep_versions "$domain"; return 0; fi
    gb_warn "$domain has several endpoints ($(ep_versions "$domain" | tr '\n' ' ')); name one."
    return 1
}

# --- deploy ------------------------------------------------------------------
type_runtime_deploy_cli() {
    local domain="" kind="" version="" repository="" mode="" warm="" default_translation="" default_reference="" python="" label=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --kind) kind="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --root) label="$GB_ROOT_LABEL"; shift ;;
            --repository) repository="$2"; shift 2 ;;
            --access) mode="$2"; shift 2 ;;
            --warm) warm="$2"; shift 2 ;;
            --default-translation) default_translation="$2"; shift 2 ;;
            --default-reference) default_reference="$2"; shift 2 ;;
            --python) python="$2"; shift 2 ;;
            --staged) GB_DEPLOY_MODE=staged; shift ;;
            --live) GB_DEPLOY_MODE=live; shift ;;
            *) gb_die "Unknown option for deploy runtime: $1" ;;
        esac
    done
    [[ -n "$domain" && -n "$kind" ]] || gb_die "deploy runtime needs --domain and --kind"
    gb_valid_domain "$domain" || gb_die "Invalid domain: $domain"
    rt_manifest_load "$kind"
    version="${version:-$RM_DEFAULT_VERSION}"
    [[ -n "$label" ]] || label="$version"
    mode="${mode:-$(gb_global DEFAULT_ACCESS_MODE metered)}"
    [[ -n "$warm" ]] || warm="$RM_WARM_TRANSLATIONS"
    [[ -n "$repository" ]] || repository="$(rt_default_repository "$version")"
    [[ -n "$repository" ]] || gb_die "No synced local static endpoint provides $version; sync it first or pass --repository PATH containing $version/"
    [[ -z "$python" ]] || python="$(py_resolve_version "$python")"
    type_runtime_create "$domain" "$kind" "$version" "$repository" "$mode" "$warm" "$label" "$python" || return 1
    if [[ -n "$default_translation" ]]; then
        gb_valid_translation "$default_translation" || gb_die "Invalid default translation: $default_translation"
        ep_version_set "$domain" "$label" DEFAULT_TRANSLATION "$default_translation"
    fi
    [[ -n "$default_reference" ]] && ep_version_set "$domain" "$label" DEFAULT_REFERENCE "$default_reference"
    type_runtime_deploy_finish "$domain"
}

# Available local roots from the registry. Follow the published path, not a
# release directory, so the librarian sees each successful static sync.
# Root endpoints qualify when their published tree contains VERSION/.
rt_repository_candidates() {
    local version="$1" domain label root
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        [[ "$(ep_get "$domain" ENABLED true)" == true ]] || continue
        for label in "$version" "$GB_ROOT_LABEL"; do
            ep_version_exists "$domain" "$label" || continue
            [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
            if [[ "$label" == "$GB_ROOT_LABEL" ]]; then
                root="$(ep_version_path "$domain" "$label")"
            else
                root="$(ep_data_dir "$domain")"
            fi
            if rt_validate_repository "$root" "$version" 2>/dev/null; then
                printf '%s\t%s (%s)\n' "$root" "$domain" "$(pages_label_text "$label")"
            fi
        done
    done < <(ep_list_by_type static)
}

rt_default_repository() {
    local root description
    while IFS=$'\t' read -r root description; do
        [[ -n "$root" ]] || continue
        printf '%s\n' "$root"
        return 0
    done < <(rt_repository_candidates "$1")
    return 0
}

# All menu entry points use the same picker and availability check.
rt_select_repository() {
    local version="$1" current="${2:-}" root description choice current_listed=false
    local -a items=()
    while IFS=$'\t' read -r root description; do
        [[ -n "$root" ]] || continue
        items+=("$root" "$description · reads $root/$version")
        [[ "$root" != "$current" ]] || current_listed=true
    done < <(rt_repository_candidates "$version")
    if [[ -n "$current" && "$current_listed" == false ]] && rt_validate_repository "$current" "$version" 2>/dev/null; then
        items=("$current" "Current folder · reads $current/$version" "${items[@]}")
    fi
    items+=(manual "Choose another existing local folder")
    choice="$(ui_menu "Local scripture for $version" "Select the root containing $version/. Only synced, available local folders can be used. If none are listed, sync a static endpoint first or enter an existing local root." "${items[@]}")" || return 1
    if [[ "$choice" == manual ]]; then
        root="$(ui_input "Local scripture folder" "Absolute local root containing $version/. The folder must already exist; remote API URLs cannot be used." "$current")" || return 1
    else
        root="$choice"
    fi
    if ! rt_validate_repository "$root" "$version"; then
        ui_msg "Local scripture unavailable" "Cannot set up this runtime endpoint until $version/ exists below the selected local root. Sync the static endpoint first, then try again."
        return 1
    fi
    printf '%s\n' "$root"
}

type_runtime_deploy_interactive() {
    local domain kind version repository mode warm cfmode label
    local -a kinds=()
    ui_msg "New runtime domain" "This walkthrough asks for: the service (query or search), the domain, whether to go live now or stage the domain, the API version to serve (its first endpoint) and whether it lives at https://domain/<version>/ or at the domain root, the folder holding the scripture files (a static domain's data root), the access mode$(cf_enabled 2>/dev/null && printf ', the Cloudflare mode' || true) and, for search, the translations to warm up.\n\nIt then installs managed Python, builds the release (a few minutes on first use), starts the service, which must pass readiness, routes nginx to it and publishes its pages. Cancel at any question to stop without changes."
    while read -r kind; do
        [[ -n "$kind" ]] || continue
        rt_manifest_load "$kind"
        kinds+=("$kind" "$RM_DESCRIPTION")
    done < <(rt_kinds)
    kind="$(ui_menu "Runtime domain" "Which service?" "${kinds[@]}")" || return 1
    rt_manifest_load "$kind"
    domain="$(ui_input "New runtime domain" "Domain name for the $kind service (DNS may still point at another server; you choose when it goes live)" "$kind.getbible.net")" || return 1
    gb_valid_domain "$domain" || { ui_msg "Invalid" "That is not a valid domain name."; return 1; }
    ep_exists "$domain" && { ui_msg "Exists" "$domain is already set up on this server."; return 1; }
    [[ -z "$(rt_kind_deployed_on "$kind")" ]] || { ui_msg "Deployed" "The $kind service already runs on $(rt_kind_deployed_on "$kind"). Add further versions to that domain (Domain > Endpoints) rather than deploying a second domain."; return 1; }
    GB_DEPLOY_MODE="$(endpoint_prompt_deploy_mode "$domain")" || return 1
    version="$(ui_input "Version" "API version to serve (available for $kind: $(rt_kind_versions "$kind" | tr '\n' ' '))" "$RM_DEFAULT_VERSION")" || return 1
    rt_implementation "$kind" "$version" >/dev/null || { ui_msg "Invalid" "The $kind service has no implementation of $version. Available: $(rt_kind_versions "$kind" | tr '\n' ' ')"; return 1; }
    label="$version"
    if ui_yesno "Domain root" "Serve $version at the domain root, https://$domain/{translation}/..., instead of under https://$domain/$version/?\n\nA domain serving its root cannot add other versions later; version folders can." no; then
        label="$GB_ROOT_LABEL"
    fi
    repository="$(rt_select_repository "$version")" || return 1
    mode="$(endpoint_prompt_access_mode)" || return 1
    warm="$RM_WARM_TRANSLATIONS"
    if [[ "$kind" == search ]]; then
        warm="$(ui_input "Warm-up" "Translations to index at start (comma separated)" "$warm")" || return 1
    fi
    cfmode="$(endpoint_prompt_cloudflare_mode "$domain")" || return 1
    type_runtime_create "$domain" "$kind" "$version" "$repository" "$mode" "$warm" "$label" || return 1
    ep_set "$domain" CLOUDFLARE_MODE "$cfmode"
    type_runtime_deploy_finish "$domain"
}

type_runtime_deploy_finish() {
    local domain="$1" conflicts label
    label="$(type_runtime_default_endpoint "$domain")"
    conflicts="$(nginx_conflicts "$domain")"
    if [[ -n "$conflicts" ]]; then
        gb_warn "$domain is already declared in: $conflicts"
        if ! ui_yesno "Conflict" "Another nginx file already declares $domain:\n$conflicts\n\nContinue anyway? Resolve the conflicting server block before applying this domain." no; then
            ep_remove_config "$domain"
            return 1
        fi
    fi
    endpoint_apply "$domain" || return 1
    if ep_is_live "$domain"; then
        tg_notify ok "Domain deployed: $domain" "Runtime $(ep_get "$domain" KIND) domain, endpoint $(pages_label_text "$label") ($(rt_app_version "$domain" "$label"))."
        if ! nginx_cert_exists "$domain"; then
            ui_msg "No certificate yet" "$domain is live but has no Let's Encrypt certificate, so it answers HTTP only (challenges are served, everything else redirects to HTTPS). Once DNS reaches this server, choose Domain > Certificate > Issue."
        fi
    else
        tg_notify ok "Domain staged: $domain" "Runtime $(ep_get "$domain" KIND) domain, endpoint $(pages_label_text "$label") ($(rt_app_version "$domain" "$label")), prepared on $(hostname -f 2>/dev/null || hostname). Not live: no certificate or DNS change until 'Go live'."
        ui_msg "Staged" "$domain is staged on this server: the service runs and passed readiness, nginx routes to it with a placeholder certificate, but no certificate was requested and DNS was not changed.\n\nVerify it, and choose 'Go live' from the main menu or the domain menu when it should take over."
    fi
}

# --- maintenance ------------------------------------------------------------
# Restart uses the same candidate/readiness/switch transaction as a code update.
# Never remove the current symlink to force a rebuild.
rt_redeploy() {
    local domain="$1"
    local RT_FORCE_DEPLOY=true RT_ONLY_LABEL=""
    endpoint_apply "$domain"
}
rt_restart() { rt_redeploy "$1"; }

# rt_update DOMAIN [LABEL] [--python VERSION]: adopt the latest catalog patch
# of the selected Python family (or the given selection) and rebuild the
# release of one endpoint, or of every endpoint. Ordinary apply retains the
# selected exact interpreter version.
rt_update() {
    local domain="$1" label="" selector="" configured resolved backup status=0
    local -a labels=()
    shift
    if [[ -n "${1:-}" ]] && gb_valid_endpoint_label "$1"; then label="$1"; shift; fi
    if [[ $# -gt 0 ]]; then
        [[ $# -eq 2 && "$1" == --python ]] || { gb_warn "runtime update accepts [ENDPOINT] [--python VERSION]"; return 1; }
        selector="$2"
    fi
    if [[ -n "$label" ]]; then
        ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label"; return 1; }
        labels=("$label")
    else
        mapfile -t labels < <(type_runtime_endpoints "$domain")
    fi
    backup="$(mktemp -d "$(gb_tmpdir)/runtime-update.XXXXXX")" || return 1
    cp -a -- "$(ep_versions_dir "$domain")/." "$backup/" || return 1
    for label in "${labels[@]}"; do
        configured="$(ep_version_get "$domain" "$label" PYTHON_VERSION)"
        if [[ -n "$selector" ]]; then resolved="$selector"
        elif [[ "$configured" == *.*.* ]]; then resolved="${configured%.*}"
        else resolved="$configured"; fi
        resolved="$(py_resolve_version "$resolved")" || return 1
        ep_version_set "$domain" "$label" PYTHON_VERSION "$resolved" || return 1
    done
    local RT_FORCE_BUILD=true RT_FORCE_DEPLOY=true RT_ONLY_LABEL=""
    [[ ${#labels[@]} -ne 1 ]] || RT_ONLY_LABEL="${labels[0]}"
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then
        for label in "${labels[@]}"; do gb_install_file "$backup/$label.conf" "$(ep_version_conf "$domain" "$label")" 0640 || return 1; done
    fi
    rm -rf -- "$backup"
    return "$status"
}

rt_setting_allowed() {
    case "$1" in
        WORKERS|THREADS|WARM_TRANSLATIONS|DEFAULT_TRANSLATION|DEFAULT_REFERENCE|ALLOWED_TRANSLATIONS|REPOSITORY|CACHE_TTL) return 0 ;;
        *) gb_warn "Unsupported runtime setting: $1"; return 1 ;;
    esac
}

# rt_set_setting DOMAIN LABEL KEY VALUE
rt_set_setting() {
    local domain="$1" label="$2" key="$3" value="$4" backup status=0 conf
    rt_setting_allowed "$key" || return 1
    ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label"; return 1; }
    conf="$(ep_version_conf "$domain" "$label")"
    backup="$(mktemp "$(gb_tmpdir)/runtime-settings.XXXXXX")" || return 1
    cp -p -- "$conf" "$backup" || return 1
    ep_version_set "$domain" "$label" "$key" "$value" || return 1
    if ! rt_validate_settings "$domain" "$label"; then
        gb_install_file "$backup" "$conf" 0640 || return 1
        rm -f -- "$backup"; return 1
    fi
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$conf" 0640 || return 1; fi
    rm -f -- "$backup"
    return "$status"
}

# rt_rollback DOMAIN LABEL: the previous generation's code and settings,
# keeping the domain's current authentication, quotas and tokens.
rt_rollback() {
    local domain="$1" label="$2" previous backup key value status=0 conf source
    ep_version_exists "$domain" "$label" || { gb_warn "$domain has no endpoint $label"; return 1; }
    previous="$(rt_previous_generation "$domain" "$label")"
    [[ -n "$previous" && -f "$previous/version.conf" ]] || { gb_warn "No retained runtime deployment of $domain $label to roll back to"; return 1; }
    conf="$(ep_version_conf "$domain" "$label")"
    backup="$(mktemp "$(gb_tmpdir)/runtime-rollback.XXXXXX")" || return 1
    cp -p -- "$conf" "$backup" || return 1
    source="$previous/version.conf"
    for key in "${RT_VERSION_SETTINGS[@]}"; do
        value="$(cfg_get "$source" "$key" __missing__)"
        [[ "$value" != __missing__ ]] || continue
        ep_version_set "$domain" "$label" "$key" "$value" || return 1
    done
    local RT_ROLLBACK_SOURCE="$previous" RT_FORCE_DEPLOY=true RT_ONLY_LABEL="$label"
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$conf" 0640 || return 1; fi
    rm -f -- "$backup"
    return "$status"
}

# --- domain menu --------------------------------------------------------------
type_runtime_menu_items() {
    printf '%s\n' \
        restart "Gracefully redeploy the current releases" \
        journal "Service journal (last 200 lines)" \
        rebuild "Update application and pinned Python dependencies" \
        python "Choose Python version and update an endpoint" \
        rollback "Restore an endpoint's previous release and settings" \
        settings "Workers, threads, warm-up and translation settings" \
        versions "Endpoints: add or remove a version, choose the default"
}

# rt_pick_endpoint DOMAIN: the only endpoint, or the operator's choice.
rt_pick_endpoint() {
    local domain="$1" label
    local -a items=()
    while read -r label; do [[ -n "$label" ]] && items+=("$label" "$(pages_label_text "$label"), $(rt_app_version "$domain" "$label")"); done < <(type_runtime_endpoints "$domain")
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Endpoints" "No endpoints configured."; return 1; }
    if [[ ${#items[@]} -eq 2 ]]; then printf '%s\n' "${items[0]}"; return 0; fi
    ui_menu "Endpoints of $domain" "Choose an endpoint" "${items[@]}"
}

type_runtime_menu_action() {
    local domain="$1" action="$2" out selector label
    case "$action" in
        restart) ui_run "Redeploy $domain" rt_redeploy "$domain" ;;
        journal)
            label="$(rt_pick_endpoint "$domain")" || return 0
            out="$(gb_tmpdir)/journal.$$"
            sd_journal "$(rt_live_unit "$domain" "$label").service" 200 > "$out"
            ui_textbox "Journal: $domain $label" "$out" ;;
        rebuild) ui_run "Update $domain" rt_update "$domain" ;;
        python)
            label="$(rt_pick_endpoint "$domain")" || return 0
            selector="$(ui_input "Python for $domain $label" "Managed Python version (3.12, 3.13, 3.14 or a catalog patch)" "$(ep_version_get "$domain" "$label" PYTHON_VERSION)")" || return 0
            ui_run "Update Python for $domain $label" rt_update "$domain" "$label" --python "$selector" ;;
        rollback)
            label="$(rt_pick_endpoint "$domain")" || return 0
            ui_run "Rollback $domain $label" rt_rollback "$domain" "$label" ;;
        settings)
            label="$(rt_pick_endpoint "$domain")" || return 0
            rt_settings_menu "$domain" "$label" ;;
        versions) rt_versions_menu "$domain" ;;
    esac
}

rt_settings_menu() {
    local domain="$1" label="$2" key text value backup stage status=0 conf
    conf="$(ep_version_conf "$domain" "$label")"
    backup="$(mktemp "$(gb_tmpdir)/runtime-settings-backup.XXXXXX")" || return 1
    stage="$(mktemp "$(gb_tmpdir)/runtime-settings-new.XXXXXX")" || return 1
    cp -p -- "$conf" "$backup" || return 1
    cp -p -- "$backup" "$stage" || return 1
    for key in WORKERS:"Gunicorn workers" THREADS:"Threads per worker" WARM_TRANSLATIONS:"Translations to warm at start (comma separated, search only)" \
               DEFAULT_TRANSLATION:"Default translation" DEFAULT_REFERENCE:"Default reference (query only)" \
               ALLOWED_TRANSLATIONS:"Allowed translations (comma separated, empty for all)"; do
        text="${key#*:}"; key="${key%%:*}"
        value="$(ui_input "$domain $label" "$text" "$(cfg_get "$stage" "$key")")" || { rm -f -- "$backup" "$stage"; return 0; }
        cfg_set "$stage" "$key" "$value" || return 1
    done
    value="$(rt_select_repository "$(rt_app_version "$domain" "$label")" "$(cfg_get "$stage" REPOSITORY)")" || { rm -f -- "$backup" "$stage"; return 0; }
    cfg_set "$stage" REPOSITORY "$value" || return 1
    gb_install_file "$stage" "$conf" 0640 || return 1
    if ! rt_validate_settings "$domain" "$label"; then
        gb_install_file "$backup" "$conf" 0640 || return 1
        ui_msg "Invalid settings" "The settings were not applied. Check the reported validation error."
        return 1
    fi
    ui_run "Apply $domain" endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$conf" 0640 || return 1; fi
    rm -f -- "$backup" "$stage"
    return "$status"
}

rt_versions_menu() {
    local domain="$1" choice label version repository warm kind default
    kind="$(ep_get "$domain" KIND)"
    while true; do
        default="$(type_runtime_default_endpoint "$domain")"
        choice="$(ui_menu "Endpoints of $domain" "Endpoints: $(type_runtime_endpoints "$domain" | sed "s/^$GB_ROOT_LABEL\$/the domain root/" | tr '\n' ' ')· default: $default · versions the $kind service can serve: $(rt_kind_versions "$kind" | tr '\n' ' ')" \
            add "Add a version (a new endpoint with its own service)" \
            default "Choose the default endpoint (answers / and the short forms)" \
            remove "Remove an endpoint (stops its service, deletes its releases)" \
            back "Back")" || return 0
        case "$choice" in
            add)
                if pages_has_root_endpoint "$domain"; then
                    ui_msg "Domain root" "$domain serves its only endpoint at the domain root (https://$domain/). Other versions cannot be added next to it."
                    continue
                fi
                version="$(ui_input "Version" "Version to add (available: $(rt_kind_versions "$kind" | tr '\n' ' '); already served: $(ep_versions "$domain" | tr '\n' ' '))" "")" || continue
                if ! rt_check_new_endpoint "$domain" "$version" "$version" 2>/dev/null; then
                    ui_msg "Invalid" "$version cannot be added: it is not a version the $kind service implements, or $domain already serves it."
                    continue
                fi
                repository="$(rt_select_repository "$version" "$(ep_version_get "$domain" "$default" REPOSITORY)")" || continue
                warm=""
                if [[ "$kind" == search ]]; then
                    rt_manifest_load "$kind" "$version"
                    warm="$(ui_input "Warm-up" "Translations to index at start (comma separated)" "$RM_WARM_TRANSLATIONS")" || continue
                fi
                ui_run "Add endpoint $version" rt_add_endpoint "$domain" "$version" "$repository" "$warm" "" "" "" || true
                ;;
            default)
                label="$(rt_pick_endpoint "$domain")" || continue
                endpoint_confirm_hand_edits "$domain" || continue
                ui_run "Default endpoint" rt_set_default "$domain" "$label" || true
                GB_OVERWRITE_HAND_EDITS=false
                ;;
            remove)
                label="$(rt_pick_endpoint "$domain")" || continue
                ui_yesno "Remove endpoint" "Remove $(pages_label_text "$label") from $domain? Its service is stopped and its releases and cache are deleted." no || continue
                ui_run "Remove endpoint" rt_remove_endpoint "$domain" "$label" || true
                ;;
            back) return 0 ;;
        esac
    done
}
