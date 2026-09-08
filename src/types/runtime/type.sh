#!/usr/bin/env bash
# Runtime endpoint type: a librarian-based service (query or search) built
# into an immutable release, run by gunicorn as its own user behind a
# systemd socket, proxied and cached by nginx.

[[ -n "${GB_TYPE_RUNTIME_LOADED:-}" ]] && return 0
GB_TYPE_RUNTIME_LOADED=1

# --- manifests ---------------------------------------------------------------
rt_kinds() {
    find "$GB_APPS" -mindepth 2 -maxdepth 2 -name manifest.conf -printf '%h\n' | xargs -r -n1 basename | sort
}

# rt_manifest_load KIND: define RM_* variables.
rt_manifest_load() {
    local kind="$1" key
    [[ -f "$GB_APPS/$kind/manifest.conf" ]] || gb_die "Unknown runtime kind: $kind"
    for key in KIND DESCRIPTION PACKAGE WSGI CHECK ENV_PREFIX DEFAULT_VERSION SUPPORTED_VERSIONS METHODS MAX_BODY \
               CACHE_SECONDS WORKERS THREADS TIMEOUT_START TIMEOUT_STOP MEMORY_HIGH MEMORY_MAX CPU_QUOTA TASKS_MAX NOFILE WARM_TRANSLATIONS; do
        printf -v "RM_$key" '%s' ""
    done
    cfg_load "$GB_APPS/$kind/manifest.conf" RM
    [[ "$RM_KIND" == "$kind" ]] || gb_die "Manifest of $kind declares KIND=$RM_KIND"
}

rt_unit() { printf 'getbible-%s\n' "$1"; }
rt_user() { printf 'getbible-%s\n' "$1"; }
rt_env_file() { printf '%s/runtime.env\n' "$(ep_dir "$1")"; }
rt_cache_dir() { printf '%s/%s/releases/%s/librarian\n' "$GB_CACHE" "$1" "$(basename -- "$2")"; }
rt_app_log() { printf '%s/app/app.log\n' "$(ep_log_dir "$1")"; }

rt_kind_deployed_on() {
    # Print the domain already using KIND, if any.
    local kind="$1" domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        [[ "$(ep_get "$domain" KIND)" == "$kind" ]] && printf '%s\n' "$domain"
    done < <(ep_list_by_type runtime)
    return 0
}

# --- registry ----------------------------------------------------------------
# type_runtime_create DOMAIN KIND VERSION REPOSITORY ACCESS WARM
type_runtime_create() {
    local domain="$1" kind="$2" version="$3" repository="$4" mode="$5" warm="$6" existing
    rt_manifest_load "$kind"
    access_valid_mode "$mode" || gb_die "Invalid access mode: $mode"
    gb_valid_version "$version" || gb_die "Invalid version: $version"
    [[ " ${RM_SUPPORTED_VERSIONS//,/ } " == *" $version "* ]] || gb_die "The $kind endpoint supports versions: $RM_SUPPORTED_VERSIONS (asked for $version)"
    existing="$(rt_kind_deployed_on "$kind")"
    [[ -z "$existing" ]] || gb_die "The $kind endpoint is already deployed on $existing (one per server)."
    [[ "$repository" == /* || "$repository" == http://* || "$repository" == https://* ]] || gb_die "Repository must be an absolute path or a URL: $repository"
    if [[ -n "$warm" ]]; then
        [[ "$warm" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || gb_die "Invalid warm-up translation list: $warm"
    fi
    ep_create "$domain" runtime "$kind"
    ep_set "$domain" ACCESS_MODE "$mode"
    ep_set "$domain" VERSION "$version"
    ep_set "$domain" REPOSITORY "$repository"
    ep_set "$domain" WORKERS "$RM_WORKERS"
    ep_set "$domain" THREADS "$RM_THREADS"
    ep_set "$domain" WARM_TRANSLATIONS "$warm"
    ep_set "$domain" DEFAULT_TRANSLATION kjv
    ep_set "$domain" DEFAULT_REFERENCE "Mat7:7"
    ep_set "$domain" ALLOWED_TRANSLATIONS ""
    ep_set "$domain" CACHE_TTL "$RM_CACHE_SECONDS"
    ep_set "$domain" PYTHON_VERSION "$(py_resolve_version)"
}

# --- deployment generations --------------------------------------------------
# A generation owns its environment and service configuration. Code releases
# can be reused, but live configuration is never rewritten underneath a process.
rt_deployments_dir() { printf '%s/deployments\n' "$(py_app_root "$1")"; }
rt_active_generation() { local p; p="$(py_app_root "$1")/active"; [[ -L "$p" ]] && readlink -f -- "$p" || true; }
rt_previous_generation() { local p; p="$(py_app_root "$1")/previous"; [[ -L "$p" ]] && readlink -f -- "$p" || true; }
rt_generation_unit() {
    if [[ -f "$2/.legacy-unit" ]]; then cat "$2/.legacy-unit"; else printf 'getbible-%s-%s\n' "$1" "$(basename -- "$2")"; fi
}
rt_generation_socket() { printf '%s/%s/%s.sock\n' "$GB_RUN" "$1" "$(basename -- "$2")"; }
rt_live_unit() {
    local active
    active="$(rt_active_generation "$1")"
    if [[ -n "$active" ]]; then rt_generation_unit "$1" "$active"; else rt_unit "$1"; fi
}
rt_socket() {
    local active
    active="$(rt_active_generation "$1")"
    if [[ -n "$active" ]]; then rt_generation_socket "$1" "$active"; else printf '%s/%s/gunicorn.sock\n' "$GB_RUN" "$1"; fi
}
rt_proxy_socket() {
    # shellcheck disable=SC2153 # EP_DOMAIN is loaded by the endpoint registry.
    if [[ -n "${RT_CANDIDATE:-}" && "${RT_DOMAIN:-}" == "$EP_DOMAIN" ]]; then
        rt_generation_socket "$EP_KIND" "$RT_CANDIDATE"
    else
        rt_socket "$EP_KIND"
    fi
}
rt_switch_link() { gb_switch_link "$1" "$2"; }

# Preserve the last traditional single-service installation as a rollback
# target when migrating to isolated generations. Reconstruct runtime settings
# from its actual environment, since the registry may already contain edits.
rt_capture_legacy_generation() {
    local domain="$1" kind="$2" release="$3" generation key env_key value
    [[ -f "$(rt_env_file "$domain")" && -d "$release" ]] || return 0
    generation="$(mktemp -d "$(rt_deployments_dir "$kind")/legacy-XXXXXX")" || return 1
    chmod 0755 "$generation" || return 1
    printf '%s\n' "$release" > "$generation/.release" || return 1
    printf '%s\n' "$(rt_unit "$kind")" > "$generation/.legacy-unit" || return 1
    gb_install_file "$(rt_env_file "$domain")" "$generation/runtime.env" 0600 || return 1
    gb_install_file "$(ep_conf "$domain")" "$generation/endpoint.conf" 0600 || return 1
    for key in REPOSITORY VERSION REQUIRE_CHECKSUMS DEFAULT_TRANSLATION DEFAULT_REFERENCE ALLOWED_TRANSLATIONS WORKERS THREADS WARM_TRANSLATIONS; do
        case "$key" in
            REPOSITORY|VERSION|REQUIRE_CHECKSUMS) env_key="GETBIBLE_$key" ;;
            DEFAULT_REFERENCE) env_key=QUERY_DEFAULT_REFERENCE ;;
            *) env_key="${RM_ENV_PREFIX}_$key" ;;
        esac
        value="$(cfg_get "$generation/runtime.env" "$env_key" __missing__)"
        [[ "$value" == __missing__ ]] || cfg_set "$generation/endpoint.conf" "$key" "$value" || return 1
    done
    printf '%s\n' "$generation"
}

rt_validate_settings() {
    local domain="$1" key value
    for key in WORKERS THREADS; do
        value="$(ep_get "$domain" "$key")"
        if ! [[ "$value" =~ ^[1-9][0-9]?$ ]] || (( 10#$value > 64 )); then
            gb_warn "$key must be between 1 and 64"; return 1
        fi
    done
    for key in WARM_TRANSLATIONS ALLOWED_TRANSLATIONS; do
        value="$(ep_get "$domain" "$key")"
        [[ -z "$value" || "$value" =~ ^[a-z0-9_-]+(,[a-z0-9_-]+)*$ ]] || { gb_warn "Invalid $key"; return 1; }
    done
    value="$(ep_get "$domain" DEFAULT_TRANSLATION kjv)"
    gb_valid_translation "$value" || { gb_warn "Invalid default translation"; return 1; }
    value="$(ep_get "$domain" REQUIRE_CHECKSUMS true)"
    [[ "$value" == true || "$value" == false ]] || { gb_warn "REQUIRE_CHECKSUMS must be true or false"; return 1; }
    value="$(ep_get "$domain" REPOSITORY)"
    [[ "$value" == /* || "$value" == https://* || "$value" == http://* ]] || { gb_warn "Repository must be an absolute path or URL"; return 1; }
    value="$(ep_get "$domain" CACHE_TTL 300)"
    [[ "$value" =~ ^[0-9]{1,7}$ ]] || { gb_warn "CACHE_TTL must be a nonnegative integer"; return 1; }
}

rt_deployment_inputs() {
    local domain="$1" release="$2" key
    {
        printf '%s\n' "$release"
        for key in REPOSITORY VERSION WORKERS THREADS WARM_TRANSLATIONS DEFAULT_TRANSLATION DEFAULT_REFERENCE ALLOWED_TRANSLATIONS REQUIRE_CHECKSUMS CACHE_TTL ACCESS_MODE; do
            printf '%s=%s\n' "$key" "$(ep_get "$domain" "$key")"
        done
        sha256sum "$GB_TYPES/runtime/type.sh" "$GB_TYPES/runtime/templates/"*.tmpl "$GB_APPS/$EP_KIND/manifest.conf"
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
    local domain="$1" kind user current release inputs active generation target
    # These are transaction-local globals, cleared for every endpoint apply.
    RT_DOMAIN="$domain"; RT_CANDIDATE=""; RT_OLD_GENERATION=""; RT_OLD_RELEASE=""; RT_COMMITTED=false
    ep_load "$domain"
    rt_validate_settings "$domain" || return 1
    kind="$EP_KIND"
    rt_manifest_load "$kind"
    user="$(rt_user "$kind")"
    gb_ensure_base_groups || return 1
    gb_ensure_system_user "$user" "$user" /nonexistent "$GB_READERS_GROUP" || return 1
    gb_ensure_dir "$GB_CACHE/$kind" 0750 "$user:$user" || return 1
    gb_ensure_dir "$GB_CACHE/$kind/releases" 0750 "$user:$user" || return 1
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
    gb_ensure_dir "$(rt_deployments_dir "$kind")" 0755 || return 1
    rt_check_repository "$domain"
    current="$(py_current_release "$kind")"
    [[ -d "$current" ]] || current=""
    if [[ -z "$(ep_get "$domain" PYTHON_VERSION)" ]]; then
        if [[ -f "$current/.python-version" ]]; then
            ep_set "$domain" PYTHON_VERSION "$(cat "$current/.python-version")" || return 1
        else
            ep_set "$domain" PYTHON_VERSION "$(py_resolve_version)" || return 1
        fi
    fi
    active="$(rt_active_generation "$kind")"
    RT_OLD_GENERATION="$active"; RT_OLD_RELEASE="$current"
    RT_OLD_UNIT="$(rt_live_unit "$kind")"; RT_OLD_SOCKET="$(rt_socket "$kind")"
    if [[ -z "$active" && -n "$current" && "$GB_DRY_RUN" != true ]]; then
        RT_OLD_GENERATION="$(rt_capture_legacy_generation "$domain" "$kind" "$current")" || return 1
    fi
    RT_STATE_BACKUP="$(mktemp -d "$(gb_tmpdir)/runtime-state.XXXXXX")" || return 1
    for target in "$(py_app_root "$kind")/active" "$(py_app_root "$kind")/previous" "$(py_current_link "$kind")" "$(rt_env_file "$domain")"; do
        gb_backup_file "$target" "$RT_STATE_BACKUP" || return 1
    done

    if [[ -n "${RT_ROLLBACK_SOURCE:-}" ]]; then
        [[ -f "$RT_ROLLBACK_SOURCE/.release" ]] || { gb_warn "Rollback generation is incomplete"; return 1; }
        release="$(cat "$RT_ROLLBACK_SOURCE/.release")"
        [[ -x "$release/.venv/bin/python" ]] || { gb_warn "Rollback release is missing: $release"; return 1; }
    else
        inputs="$(py_inputs_hash "$kind" "$(ep_get "$domain" PYTHON_VERSION)")" || return 1
        if [[ "${RT_FORCE_BUILD:-false}" == true || ! -d "$current" || "$(py_release_inputs "$current")" != "$inputs" ]]; then
            release="$(py_build_release "$kind" "$domain" "$(ep_get "$domain" PYTHON_VERSION)")" || return 1
        else
            release="$current"
            gb_log "Release $release is current."
        fi
    fi
    if [[ "$GB_DRY_RUN" != true ]]; then
        gb_ensure_dir "$(dirname -- "$(rt_cache_dir "$kind" "$release")")" 0750 "$user:$user" || return 1
        gb_ensure_dir "$(rt_cache_dir "$kind" "$release")" 0750 "$user:$user" || return 1
    fi
    inputs="$(rt_deployment_inputs "$domain" "$release")" || return 1
    if [[ "${RT_FORCE_DEPLOY:-false}" != true && -n "$active" && -f "$active/.inputs" && "$(cat "$active/.inputs")" == "$inputs" ]]; then
        if ! sd_available || sd_is_active "$(rt_generation_unit "$kind" "$active").service"; then
            gb_log "Runtime generation $(basename "$active") is current."
            return 0
        fi
    fi
    [[ "$GB_DRY_RUN" == true ]] && { gb_log "(dry-run) would prepare a runtime generation for $domain"; return 0; }
    generation="$(mktemp -d "$(rt_deployments_dir "$kind")/$(date -u +%Y%m%dT%H%M%S)-XXXXXX")" || return 1
    chmod 0755 "$generation" || return 1
    RT_CANDIDATE="$generation"
    printf '%s\n' "$release" > "$generation/.release" || return 1
    printf '%s\n' "$inputs" > "$generation/.inputs" || return 1
    gb_install_file "$(ep_conf "$domain")" "$generation/endpoint.conf" 0600 || return 1
    rt_render_env "$domain" "$generation" || return 1
    rt_render_gunicorn "$domain" "$generation" || return 1
    rt_render_units "$domain" "$generation" "$release" || return 1
    rt_activate "$domain" "$generation"
}

rt_check_repository() {
    local domain="$1" root
    root="$(ep_get "$domain" REPOSITORY)"
    [[ "$root" == /* ]] || return 0
    [[ -d "$root/$EP_VERSION" ]] || gb_warn "Scripture mirror $root/$EP_VERSION is missing; readiness will prevent this deployment from replacing a healthy service."
}

rt_render_env() {
    local domain="$1" generation="$2" stage is_query=false is_search=false expensive release
    stage="$(gb_tmpdir)/runtime.env.$EP_SLUG"
    release="$(cat "$generation/.release")" || return 1
    [[ "$EP_KIND" == query ]] && is_query=true
    [[ "$EP_KIND" == search ]] && is_search=true
    expensive=$(( EP_THREADS / 2 )); (( expensive < 1 )) && expensive=1
    gb_render "$GB_TYPES/runtime/templates/env.tmpl" "$stage" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "REPOSITORY=$EP_REPOSITORY" "VERSION=$EP_VERSION" \
        "CACHE_DIR=$(rt_cache_dir "$EP_KIND" "$release")" "CACHE_TTL_SECONDS=900" "REQUIRE_CHECKSUMS=${EP_REQUIRE_CHECKSUMS:-true}" \
        "APP_LOG=$(rt_app_log "$domain")" "ENV_PREFIX=$RM_ENV_PREFIX" "ACCESS_MODE=$EP_ACCESS_MODE" \
        "DEFAULT_TRANSLATION=${EP_DEFAULT_TRANSLATION:-kjv}" "ALLOWED_TRANSLATIONS=$EP_ALLOWED_TRANSLATIONS" \
        "CACHE_SECONDS=${EP_CACHE_TTL:-$RM_CACHE_SECONDS}" "WORKERS=${EP_WORKERS:-$RM_WORKERS}" \
        "THREADS=${EP_THREADS:-$RM_THREADS}" "WARM_TRANSLATIONS=$EP_WARM_TRANSLATIONS" \
        "SOCKET=$(rt_generation_socket "$EP_KIND" "$generation")" "IS_QUERY=$is_query" "IS_SEARCH=$is_search" \
        "DEFAULT_REFERENCE=${EP_DEFAULT_REFERENCE:-Mat7:7}" "EXPENSIVE_CONCURRENT=$expensive" "EXTRA_ENV=" || return 1
    rt_quote_env "$stage" "$generation/runtime.env"
}

rt_render_gunicorn() {
    local domain="$1" generation="$2" timeout=60
    [[ "$EP_KIND" == search ]] && timeout=30
    gb_render "$GB_TYPES/runtime/templates/gunicorn.conf.py.tmpl" "$generation/gunicorn.conf.py" \
        "KIND=$EP_KIND" "ENV_PREFIX=$RM_ENV_PREFIX" "SOCKET=$(rt_generation_socket "$EP_KIND" "$generation")" \
        "WORKERS=${EP_WORKERS:-$RM_WORKERS}" "THREADS=${EP_THREADS:-$RM_THREADS}" \
        "WORKER_TIMEOUT=$timeout" "PACKAGE=$RM_PACKAGE" || return 1
    chmod 0644 "$generation/gunicorn.conf.py"
}

rt_render_units() {
    local domain="$1" generation="$2" release="$3" unit user
    unit="$(rt_generation_unit "$EP_KIND" "$generation")"
    user="$(rt_user "$EP_KIND")"
    SD_UNITS_CHANGED=false
    gb_render "$GB_TYPES/runtime/templates/socket.tmpl" "$generation/socket.unit" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "SOCKET=$(rt_generation_socket "$EP_KIND" "$generation")" "USER=$user" "NGINX_USER=$GB_NGINX_USER" || return 1
    gb_render "$GB_TYPES/runtime/templates/service.tmpl" "$generation/service.unit" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "UNIT=$unit" "USER=$user" "READERS_GROUP=$GB_READERS_GROUP" \
        "RELEASE=$release" "GENERATION=$generation" "ENV_FILE=$generation/runtime.env" \
        "CHECK=$RM_CHECK" "WSGI=$RM_WSGI" "TIMEOUT_START=$RM_TIMEOUT_START" "TIMEOUT_STOP=$RM_TIMEOUT_STOP" || return 1
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
    local domain="$1" generation="$2" unit socket
    unit="$(rt_generation_unit "$EP_KIND" "$generation")"
    socket="$(rt_generation_socket "$EP_KIND" "$generation")"
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

# nginx locations for a runtime endpoint.
type_runtime_render_locations() {
    local output="$1"
    rt_manifest_load "$EP_KIND"
    TYPE_METHODS_REGEX="$RM_METHODS"
    TYPE_REJECT_ARGS=false
    TYPE_MAX_BODY="$RM_MAX_BODY"
    TYPE_PROXY_CACHE=true
    gb_render "$GB_TYPES/runtime/templates/locations.conf.tmpl" "$output" \
        "DOMAIN=$EP_DOMAIN" "SLUG=$EP_SLUG" "SOCKET=$(rt_proxy_socket)" \
        "WWW_DIR=$(ep_www_dir "$EP_DOMAIN")" "NGINX_GB_DIR=$GB_NGINX_GB" \
        "CACHE_TTL=${EP_CACHE_TTL:-$RM_CACHE_SECONDS}" "TOKEN_ACCESS=$([[ "$EP_ACCESS_MODE" == token ]] && echo true || echo false)"
}

type_runtime_before_switch() {
    local domain="$1" unit
    [[ "${RT_DOMAIN:-}" == "$domain" && "$GB_DRY_RUN" != true ]] || return 0
    RT_NGINX_SNAPSHOT="${RT_CANDIDATE:-$RT_STATE_BACKUP}/nginx-workers"
    [[ -f "$RT_NGINX_SNAPSHOT" ]] || sd_snapshot_nginx_workers "$RT_NGINX_SNAPSHOT" || return 1
    if [[ -n "${RT_CANDIDATE:-}" ]]; then
        # Before nginx can persist a route to this socket, the healthy
        # candidate must be enabled for boot. A power loss between reload
        # and pointer commit can then recover either old or new routing.
        unit="$(rt_generation_unit "$EP_KIND" "$RT_CANDIDATE")"
        sd_enable "$unit.socket" "$unit.service" || return 1
    fi
}

# Called only after every nginx validation/reload succeeded. The old runtime
# stays enabled until its healthy replacement has been durably selected.
type_runtime_finish() {
    local domain="$1" generation="${RT_CANDIDATE:-}" kind unit release root
    [[ "${RT_DOMAIN:-}" == "$domain" ]] || return 0
    if [[ -z "$generation" ]]; then
        [[ "$GB_DRY_RUN" == true ]] || rt_reap_unselected "$domain"
        return 0
    fi
    kind="$(ep_get "$domain" KIND)"; root="$(py_app_root "$kind")"
    unit="$(rt_generation_unit "$kind" "$generation")"
    release="$(cat "$generation/.release")" || return 1
    sd_enable "$unit.socket" "$unit.service" || return 1
    RT_COMMITTED=true
    [[ -z "${RT_OLD_GENERATION:-}" ]] || rt_switch_link "$RT_OLD_GENERATION" "$root/previous" || return 1
    py_switch_release "$kind" "$release" || return 1
    gb_install_file "$generation/runtime.env" "$(rt_env_file "$domain")" 0600 || return 1
    rt_switch_link "$generation" "$root/active" || return 1
    gb_ledger_record "$(rt_env_file "$domain")" || return 1
    if [[ -n "${RT_OLD_RELEASE:-}" ]]; then
        # Old nginx workers may still issue upstream requests after reload.
        # Keep their backend alive until those exact processes have exited.
        sd_retire_after "$RT_OLD_UNIT" "$generation/nginx-workers" || gb_warn "Old generation remains running; check the service journal before retiring it manually."
    fi
    tg_notify ok "Runtime release live: $domain" "$kind generation $(basename "$generation"), release $(basename "$release")."
    rt_prune_generations "$kind"
    rt_reap_unselected "$domain"
    RT_CANDIDATE=""
    return 0
}

# An interrupted CLI may leave a candidate running but unselected. Collect it
# only after a later successful nginx reload, with that reload's drain gate.
rt_reap_unselected() {
    local domain="$1" kind active previous generation unit
    [[ -n "${RT_NGINX_SNAPSHOT:-}" && -f "$RT_NGINX_SNAPSHOT" ]] || return 0
    kind="$(ep_get "$domain" KIND)"
    active="$(rt_active_generation "$kind")"; previous="$(rt_previous_generation "$kind")"
    while IFS= read -r generation; do
        [[ "$generation" == "$active" || "$generation" == "$previous" ]] && continue
        unit="$(rt_generation_unit "$kind" "$generation")"
        if sd_is_active "$unit.service"; then
            sd_retire_after "$unit" "$RT_NGINX_SNAPSHOT" || gb_warn "Retaining unselected $unit until its requests can drain."
        fi
    done < <(find "$(rt_deployments_dir "$kind")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# The caller restores nginx before aborting if it had already switched traffic.
type_runtime_abort() {
    local domain="$1" generation="${RT_CANDIDATE:-}" kind root unit target recovered=true
    [[ "${RT_DOMAIN:-}" == "$domain" ]] || return 0
    kind="$(ep_get "$domain" KIND)"; root="$(py_app_root "$kind")"
    if [[ "${RT_COMMITTED:-false}" == true ]]; then
        for target in "$root/active" "$root/previous" "$(py_current_link "$kind")" "$(rt_env_file "$domain")"; do
            gb_restore_file "$target" "$RT_STATE_BACKUP" || recovered=false
        done
    fi
    if [[ -n "$generation" ]]; then
        unit="$(rt_generation_unit "$kind" "$generation")"
        sd_remove_unit "$unit.service"
        sd_remove_unit "$unit.socket"
        sd_daemon_reload || recovered=false
        rm -rf -- "$generation"
    fi
    if [[ -n "${RT_OLD_RELEASE:-}" ]] && sd_available; then
        if ! sd_wait_ready "$RT_OLD_SOCKET" /readyz 15; then
            recovered=false
            gb_warn "Previous runtime is not ready; manual recovery is required."
        fi
    fi
    RT_CANDIDATE=""; RT_COMMITTED=false
    if [[ "$recovered" == true ]]; then
        tg_notify fail "Runtime deployment rejected: $domain" "The candidate was removed; the previous runtime and configuration remain selected."
    else
        tg_notify fail "Runtime recovery needs attention: $domain" "The previous service did not pass recovery verification. Inspect its journal."
    fi
    [[ "$recovered" == true ]]
}

rt_prune_generations() {
    local kind="$1" generation active previous unit cache
    active="$(rt_active_generation "$kind")"; previous="$(rt_previous_generation "$kind")"
    while IFS= read -r generation; do
        [[ "$generation" == "$active" || "$generation" == "$previous" ]] && continue
        unit="$(rt_generation_unit "$kind" "$generation")"
        # A still-draining service must retain its interpreter and config.
        sd_is_active "$unit.service" && continue
        sd_remove_unit "$unit.service"
        sd_remove_unit "$unit.socket"
        rm -rf -- "$generation"
    done < <(find "$(rt_deployments_dir "$kind")" -mindepth 1 -maxdepth 1 -type d -mmin +2 2>/dev/null)
    py_prune_releases "$kind" 3
    while IFS= read -r cache; do
        [[ -d "$(py_releases_dir "$kind")/$(basename -- "$cache")" ]] || rm -rf -- "$cache"
    done < <(find "$GB_CACHE/$kind/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

type_runtime_remove() {
    local domain="$1" purge="$2" kind user generation unit
    kind="$(ep_get "$domain" KIND)"; user="$(rt_user "$kind")"
    while IFS= read -r generation; do
        unit="$(rt_generation_unit "$kind" "$generation")"
        sd_remove_unit "$unit.service"; sd_remove_unit "$unit.socket"
    done < <(find "$(rt_deployments_dir "$kind")" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    sd_remove_unit "$(rt_unit "$kind").service"; sd_remove_unit "$(rt_unit "$kind").socket"
    sd_daemon_reload
    rm -f -- "$(rt_env_file "$domain")"
    if [[ "$purge" == true ]]; then
        rm -rf -- "$(py_app_root "$kind")" "${GB_CACHE:?}/${kind:?}" "$GB_PREFIX/var/cache/nginx/getbible/$(gb_slug "$domain")"
        if gb_user_exists "$user" && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then userdel "$user" 2>/dev/null || true; fi
    fi
}

type_runtime_status() {
    local domain="$1" kind unit socket release
    kind="$(ep_get "$domain" KIND)"; unit="$(rt_live_unit "$kind")"; socket="$(rt_socket "$kind")"; release="$(py_current_release "$kind")"
    printf 'Kind        : %s (%s)\n' "$kind" "$(ep_get "$domain" VERSION)"
    printf 'Service     : %s (%s)\n' "$unit.service" "$(sd_status_line "$unit.service")"
    printf 'Socket      : %s (%s)\n' "$socket" "$(sd_status_line "$unit.socket")"
    printf 'Generation  : %s\n' "$(rt_active_generation "$kind")"
    printf 'Rollback    : %s\n' "$(rt_previous_generation "$kind")"
    printf 'Release     : %s\n' "$release"
    printf 'Python      : %s\n' "$(cat "$release/.python-version" 2>/dev/null || echo legacy-system-python)"
    printf 'Repository  : %s (%s)\n' "$(ep_get "$domain" REPOSITORY)" "$(ep_get "$domain" VERSION)"
    printf 'Workers     : %s x %s threads; warm: %s\n' "$(ep_get "$domain" WORKERS)" "$(ep_get "$domain" THREADS)" "$(ep_get "$domain" WARM_TRANSLATIONS "-")"
    printf 'Cache dir   : %s\n' "$GB_CACHE/$kind"
    if [[ -S "$socket" ]]; then
        printf 'Liveness    : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/healthz 2>/dev/null || echo unreachable)"
        printf 'Readiness   : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/readyz 2>/dev/null || echo unreachable)"
    fi
    if sd_available; then "$GB_SYSTEMCTL" show "$unit.service" --no-pager --property=MainPID,ActiveEnterTimestamp,MemoryCurrent,TasksCurrent,NRestarts 2>/dev/null | sed 's/^/  /'; fi
}

type_runtime_render_docs() {
    local output="$1" www access first example openapi
    rt_manifest_load "$EP_KIND"
    www="$(ep_www_dir "$EP_DOMAIN")"
    access="$(gb_tmpdir)/access-$EP_SLUG.html"
    example="$EP_VERSION/${EP_DEFAULT_TRANSLATION:-kjv}/$([[ "$EP_KIND" == search ]] && printf 'faith%%20hope' || printf 'John3:16')"
    docs_render_access "$access" "$EP_VERSION" "${example#*/}"
    gb_render "$GB_APPS/$EP_KIND/docs.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
        "CSS=$(cat "$GB_DOCS_SRC/base.css")" "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" \
        "VERSION=$EP_VERSION" "DEFAULT_TRANSLATION=${EP_DEFAULT_TRANSLATION:-kjv}" \
        "DEFAULT_REFERENCE=${EP_DEFAULT_REFERENCE:-Mat7:7}" "ACCESS_HTML=$(cat "$access")" \
        "CACHE_SECONDS=${EP_CACHE_TTL:-$RM_CACHE_SECONDS}" "TOKEN_REQUIRED=$([[ "$EP_ACCESS_MODE" == token ]] && echo true || echo false)"
    openapi="$(gb_tmpdir)/openapi-$EP_SLUG.json"
    gb_render "$GB_APPS/$EP_KIND/openapi.json.tmpl" "$openapi" "DOMAIN=$EP_DOMAIN" "VERSION=$EP_VERSION" \
        "DEFAULT_TRANSLATION=${EP_DEFAULT_TRANSLATION:-kjv}" "DEFAULT_REFERENCE=${EP_DEFAULT_REFERENCE:-Mat7:7}" \
        "TOKEN_REQUIRED=$([[ "$EP_ACCESS_MODE" == token ]] && echo true || echo false)"
    "$GB_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$openapi" || gb_die "Rendered OpenAPI document for $EP_DOMAIN is not valid JSON."
    gb_ensure_dir "$www" 0755
    gb_install_file "$openapi" "$www/openapi.json" 0644
}

# --- deploy ------------------------------------------------------------------
type_runtime_deploy_cli() {
    local domain="" kind="" version="" repository="" mode="" warm="" checksums=true default_translation="" default_reference="" python=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --kind) kind="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --repository) repository="$2"; shift 2 ;;
            --access) mode="$2"; shift 2 ;;
            --warm) warm="$2"; shift 2 ;;
            --require-checksums) checksums="$2"; shift 2 ;;
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
    mode="${mode:-$(gb_global DEFAULT_ACCESS_MODE metered)}"
    [[ -n "$warm" ]] || warm="$RM_WARM_TRANSLATIONS"
    [[ -n "$repository" ]] || repository="$(rt_default_repository "$version")"
    [[ -n "$repository" ]] || gb_die "No static endpoint provides version $version; pass --repository PATH"
    type_runtime_create "$domain" "$kind" "$version" "$repository" "$mode" "$warm"
    [[ "$checksums" == false ]] && ep_set "$domain" REQUIRE_CHECKSUMS false
    if [[ -n "$default_translation" ]]; then
        gb_valid_translation "$default_translation" || gb_die "Invalid default translation: $default_translation"
        ep_set "$domain" DEFAULT_TRANSLATION "$default_translation"
    fi
    [[ -n "$default_reference" ]] && ep_set "$domain" DEFAULT_REFERENCE "$default_reference"
    [[ -z "$python" ]] || ep_set "$domain" PYTHON_VERSION "$(py_resolve_version "$python")"
    type_runtime_deploy_finish "$domain"
}

# The data root of the first static endpoint that serves VERSION.
rt_default_repository() {
    local version="$1" domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        if ep_version_exists "$domain" "$version"; then
            ep_data_dir "$domain"
            return 0
        fi
    done < <(ep_list_by_type static)
    return 0
}

type_runtime_deploy_interactive() {
    local domain kind version repository mode warm choice
    local -a kinds=()
    while read -r kind; do
        [[ -n "$kind" ]] || continue
        rt_manifest_load "$kind"
        kinds+=("$kind" "$RM_DESCRIPTION")
    done < <(rt_kinds)
    kind="$(ui_menu "Runtime endpoint" "Which service?" "${kinds[@]}")" || return 1
    rt_manifest_load "$kind"
    domain="$(ui_input "New runtime endpoint" "Domain name for the $kind endpoint (DNS may still point at another server; you choose when it goes live)" "$kind.getbible.net")" || return 1
    gb_valid_domain "$domain" || { ui_msg "Invalid" "That is not a valid domain name."; return 1; }
    ep_exists "$domain" && { ui_msg "Exists" "$domain is already an endpoint."; return 1; }
    GB_DEPLOY_MODE="$(endpoint_prompt_deploy_mode "$domain")" || return 1
    version="$(ui_input "Version" "API version to serve (supported: $RM_SUPPORTED_VERSIONS)" "$RM_DEFAULT_VERSION")" || return 1
    repository="$(rt_default_repository "$version")"
    repository="$(ui_input "Scripture files" "Folder holding the Bible files (must contain $version/), usually a static endpoint's data root" "${repository:-$GB_SRV/api.getbible.net}")" || return 1
    mode="$(endpoint_prompt_access_mode)" || return 1
    warm="$RM_WARM_TRANSLATIONS"
    if [[ "$kind" == search ]]; then
        warm="$(ui_input "Warm-up" "Translations to index at start (comma separated)" "$warm")" || return 1
    fi
    type_runtime_create "$domain" "$kind" "$version" "$repository" "$mode" "$warm"
    type_runtime_deploy_finish "$domain"
}

type_runtime_deploy_finish() {
    local domain="$1" conflicts
    conflicts="$(nginx_conflicts "$domain")"
    if [[ -n "$conflicts" ]]; then
        gb_warn "$domain is already declared in: $conflicts"
        if ! ui_yesno "Conflict" "Another nginx file already declares $domain:\n$conflicts\n\nContinue anyway? (Use the migration action to retire the old configuration.)" no; then
            ep_remove_config "$domain"
            return 1
        fi
    fi
    endpoint_apply "$domain" || return 1
    if ep_is_live "$domain"; then
        tg_notify ok "Endpoint deployed: $domain" "Runtime $(ep_get "$domain" KIND) endpoint, version $(ep_get "$domain" VERSION)."
    else
        tg_notify ok "Endpoint staged: $domain" "Runtime $(ep_get "$domain" KIND) endpoint, version $(ep_get "$domain" VERSION), prepared on $(hostname -f 2>/dev/null || hostname). Not live: no certificate or DNS change until 'Go live'."
        ui_msg "Staged" "$domain is staged on this server: the service runs and passed readiness, nginx routes to it with a placeholder certificate, but no certificate was requested and DNS was not changed.\n\nVerify it, and choose 'Go live' from the main menu or the endpoint menu when it should take over."
    fi
}

# Restart uses the same candidate/readiness/switch transaction as a code update.
# Never remove the current symlink to force a rebuild.
rt_redeploy() {
    local domain="$1"
    local RT_FORCE_DEPLOY=true
    endpoint_apply "$domain"
}
rt_restart() { rt_redeploy "$1"; }

# Explicit update adopts the latest catalog patch for this endpoint's selected
# Python family. Ordinary apply retains the selected exact interpreter version.
rt_update() {
    local domain="$1" selector="" configured backup status=0
    shift
    if [[ $# -gt 0 ]]; then
        [[ $# -eq 2 && "$1" == --python ]] || { gb_warn "runtime update accepts [--python VERSION]"; return 1; }
        selector="$2"
    fi
    configured="$(ep_get "$domain" PYTHON_VERSION)"
    if [[ -z "$selector" ]]; then
        if [[ "$configured" == *.*.* ]]; then selector="${configured%.*}"; else selector="$configured"; fi
    fi
    selector="$(py_resolve_version "$selector")" || return 1
    backup="$(mktemp "$(gb_tmpdir)/runtime-update.XXXXXX")" || return 1
    cp -p -- "$(ep_conf "$domain")" "$backup" || return 1
    ep_set "$domain" PYTHON_VERSION "$selector" || return 1
    local RT_FORCE_BUILD=true RT_FORCE_DEPLOY=true
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1; fi
    rm -f -- "$backup"
    return "$status"
}

rt_setting_allowed() {
    case "$1" in
        WORKERS|THREADS|WARM_TRANSLATIONS|DEFAULT_TRANSLATION|DEFAULT_REFERENCE|ALLOWED_TRANSLATIONS|REPOSITORY|REQUIRE_CHECKSUMS|CACHE_TTL) return 0 ;;
        *) gb_warn "Unsupported runtime setting: $1"; return 1 ;;
    esac
}

rt_set_setting() {
    local domain="$1" key="$2" value="$3" backup status=0
    rt_setting_allowed "$key" || return 1
    backup="$(mktemp "$(gb_tmpdir)/runtime-settings.XXXXXX")" || return 1
    cp -p -- "$(ep_conf "$domain")" "$backup" || return 1
    ep_set "$domain" "$key" "$value" || return 1
    if ! rt_validate_settings "$domain"; then
        gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1
        rm -f -- "$backup"; return 1
    fi
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1; fi
    rm -f -- "$backup"
    return "$status"
}

rt_rollback() {
    local domain="$1" kind previous backup key status=0
    kind="$(ep_get "$domain" KIND)"; previous="$(rt_previous_generation "$kind")"
    [[ -n "$previous" && -f "$previous/endpoint.conf" ]] || { gb_warn "No retained runtime deployment to roll back to"; return 1; }
    backup="$(mktemp "$(gb_tmpdir)/runtime-rollback.XXXXXX")" || return 1
    cp -p -- "$(ep_conf "$domain")" "$backup" || return 1
    # Keep current authentication, quotas and tokens. Restore only the runtime
    # settings associated with the previous code/interpreter release.
    for key in PYTHON_VERSION VERSION REPOSITORY WORKERS THREADS WARM_TRANSLATIONS DEFAULT_TRANSLATION DEFAULT_REFERENCE ALLOWED_TRANSLATIONS REQUIRE_CHECKSUMS CACHE_TTL; do
        ep_set "$domain" "$key" "$(cfg_get "$previous/endpoint.conf" "$key")" || return 1
    done
    local RT_ROLLBACK_SOURCE="$previous" RT_FORCE_DEPLOY=true
    endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1; fi
    rm -f -- "$backup"
    return "$status"
}

# --- endpoint submenu --------------------------------------------------------
type_runtime_menu_items() {
    printf '%s\n' \
        restart "Gracefully redeploy the current release" \
        journal "Service journal (last 200 lines)" \
        rebuild "Update application and pinned Python dependencies" \
        python "Choose Python version and update runtime" \
        rollback "Restore the previous runtime release and settings" \
        settings "Workers, threads, warm-up and translation settings"
}

type_runtime_menu_action() {
    local domain="$1" action="$2" kind out selector
    kind="$(ep_get "$domain" KIND)"
    case "$action" in
        restart) ui_run "Redeploy $domain" rt_redeploy "$domain" ;;
        journal)
            out="$(gb_tmpdir)/journal.$$"
            sd_journal "$(rt_live_unit "$kind").service" 200 > "$out"
            ui_textbox "Journal: $domain" "$out" ;;
        rebuild) ui_run "Update $domain" rt_update "$domain" ;;
        python)
            selector="$(ui_input "Python for $domain" "Managed Python version (3.12, 3.13, 3.14 or a catalog patch)" "$(ep_get "$domain" PYTHON_VERSION)")" || return 0
            ui_run "Update Python for $domain" rt_update "$domain" --python "$selector" ;;
        rollback) ui_run "Rollback $domain" rt_rollback "$domain" ;;
        settings) rt_settings_menu "$domain" ;;
    esac
}

rt_settings_menu() {
    local domain="$1" key label value backup stage status=0
    backup="$(mktemp "$(gb_tmpdir)/runtime-settings-backup.XXXXXX")" || return 1
    stage="$(mktemp "$(gb_tmpdir)/runtime-settings-new.XXXXXX")" || return 1
    cp -p -- "$(ep_conf "$domain")" "$backup" || return 1
    cp -p -- "$backup" "$stage" || return 1
    for key in WORKERS:"Gunicorn workers" THREADS:"Threads per worker" WARM_TRANSLATIONS:"Translations to warm at start (comma separated, search only)" \
               DEFAULT_TRANSLATION:"Default translation" DEFAULT_REFERENCE:"Default reference (query only)" \
               ALLOWED_TRANSLATIONS:"Allowed translations (comma separated, empty for all)" REPOSITORY:"Scripture files folder" \
               REQUIRE_CHECKSUMS:"Require .sha checksums for every file (true/false)"; do
        label="${key#*:}"; key="${key%%:*}"
        value="$(ui_input "$domain" "$label" "$(cfg_get "$stage" "$key")")" || { rm -f -- "$backup" "$stage"; return 0; }
        cfg_set "$stage" "$key" "$value" || return 1
    done
    gb_install_file "$stage" "$(ep_conf "$domain")" 0640 || return 1
    if ! rt_validate_settings "$domain"; then
        gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1
        ui_msg "Invalid settings" "The settings were not applied. Check the reported validation error."
        return 1
    fi
    ui_run "Apply $domain" endpoint_apply "$domain" || status=$?
    if (( status != 0 )); then gb_install_file "$backup" "$(ep_conf "$domain")" 0640 || return 1; fi
    rm -f -- "$backup" "$stage"
    return "$status"
}
