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
rt_socket() { printf '%s/%s/gunicorn.sock\n' "$GB_RUN" "$1"; }
rt_env_file() { printf '%s/runtime.env\n' "$(ep_dir "$1")"; }
rt_cache_dir() { printf '%s/%s/librarian\n' "$GB_CACHE" "$1"; }
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
}

# --- pipeline hooks ----------------------------------------------------------
type_runtime_prepare() {
    local domain="$1" kind user unit release current inputs
    ep_load "$domain"
    kind="$EP_KIND"
    rt_manifest_load "$kind"
    user="$(rt_user "$kind")"
    unit="$(rt_unit "$kind")"
    gb_ensure_base_groups
    gb_ensure_system_user "$user" "$user" /nonexistent "$GB_READERS_GROUP"
    gb_ensure_dir "$GB_CACHE/$kind" 0750 "$user:$user"
    gb_ensure_dir "$(rt_cache_dir "$domain" >/dev/null; printf '%s/%s/librarian' "$GB_CACHE" "$kind")" 0750 "$user:$user"
    gb_ensure_dir "$(ep_log_dir "$domain")/app" 0750 "$user:$user"
    gb_ensure_dir "$GB_PREFIX/var/cache/nginx/getbible" 0755
    rt_check_repository "$domain"

    # Release: rebuild only when the inputs changed.
    current="$(py_current_release "$kind")"
    inputs="$(py_inputs_hash "$kind")"
    if [[ -z "$current" || "$(py_release_inputs "$current")" != "$inputs" ]]; then
        release="$(py_build_release "$kind" "$domain")"
    else
        release="$current"
        gb_log "Release $release is current."
    fi
    RT_RELEASE="$release"
    RT_PREVIOUS="$current"

    rt_render_env "$domain" "$release"
    rt_render_units "$domain" "$release"
    rt_render_gunicorn "$domain" "$release"
    rt_activate "$domain" "$release"
}

rt_check_repository() {
    local domain="$1" root
    root="$EP_REPOSITORY"
    [[ "$root" == /* ]] || return 0
    if [[ ! -d "$root/$EP_VERSION" ]]; then
        gb_warn "Scripture mirror $root/$EP_VERSION does not exist yet; the service will report not ready until it is synced."
    fi
}

rt_render_env() {
    local domain="$1" release="$2" stage is_query=false is_search=false expensive
    stage="$(gb_tmpdir)/runtime.env.$EP_SLUG"
    [[ "$EP_KIND" == query ]] && is_query=true
    [[ "$EP_KIND" == search ]] && is_search=true
    expensive=$(( EP_THREADS / 2 )); (( expensive < 1 )) && expensive=1
    local require="${EP_REQUIRE_CHECKSUMS:-true}"
    gb_render "$GB_TYPES/runtime/templates/env.tmpl" "$stage" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "REPOSITORY=$EP_REPOSITORY" "VERSION=$EP_VERSION" \
        "CACHE_DIR=$GB_CACHE/$EP_KIND/librarian" "CACHE_TTL_SECONDS=900" "REQUIRE_CHECKSUMS=$require" \
        "APP_LOG=$(rt_app_log "$domain")" "ENV_PREFIX=$RM_ENV_PREFIX" \
        "DEFAULT_TRANSLATION=${EP_DEFAULT_TRANSLATION:-kjv}" "ALLOWED_TRANSLATIONS=$EP_ALLOWED_TRANSLATIONS" \
        "CACHE_SECONDS=${EP_CACHE_TTL:-$RM_CACHE_SECONDS}" "WORKERS=${EP_WORKERS:-$RM_WORKERS}" \
        "THREADS=${EP_THREADS:-$RM_THREADS}" "WARM_TRANSLATIONS=$EP_WARM_TRANSLATIONS" \
        "SOCKET=$(rt_socket "$EP_KIND")" "IS_QUERY=$is_query" "IS_SEARCH=$is_search" \
        "DEFAULT_REFERENCE=${EP_DEFAULT_REFERENCE:-Mat7:7}" "EXPENSIVE_CONCURRENT=$expensive" "EXTRA_ENV="
    gb_install_file "$stage" "$(rt_env_file "$domain")" 0600
    gb_ledger_record "$(rt_env_file "$domain")"
}

rt_render_gunicorn() {
    local domain="$1" release="$2" stage timeout
    stage="$(gb_tmpdir)/gunicorn.$EP_SLUG.py"
    timeout=60
    [[ "$EP_KIND" == search ]] && timeout=30
    gb_render "$GB_TYPES/runtime/templates/gunicorn.conf.py.tmpl" "$stage" \
        "KIND=$EP_KIND" "ENV_PREFIX=$RM_ENV_PREFIX" "SOCKET=$(rt_socket "$EP_KIND")" \
        "WORKERS=${EP_WORKERS:-$RM_WORKERS}" "THREADS=${EP_THREADS:-$RM_THREADS}" \
        "WORKER_TIMEOUT=$timeout" "PACKAGE=$RM_PACKAGE"
    [[ "$GB_DRY_RUN" == true ]] && return 0
    if [[ ! -f "$release/gunicorn.conf.py" ]] || ! cmp -s "$stage" "$release/gunicorn.conf.py"; then
        install -m 0644 "$stage" "$release/gunicorn.conf.py"
        RT_RESTART_NEEDED=true
    fi
}

rt_render_units() {
    local domain="$1" release="$2" unit user stage
    unit="$(rt_unit "$EP_KIND")"
    user="$(rt_user "$EP_KIND")"
    SD_UNITS_CHANGED=false
    stage="$(gb_tmpdir)/$unit"
    gb_render "$GB_TYPES/runtime/templates/socket.tmpl" "$stage.socket" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "SOCKET=$(rt_socket "$EP_KIND")" "USER=$user" "NGINX_USER=$GB_NGINX_USER"
    gb_render "$GB_TYPES/runtime/templates/service.tmpl" "$stage.service" \
        "KIND=$EP_KIND" "DOMAIN=$domain" "UNIT=$unit" "USER=$user" "READERS_GROUP=$GB_READERS_GROUP" \
        "RELEASE=$(py_current_link "$EP_KIND")" "ENV_FILE=$(rt_env_file "$domain")" \
        "CHECK=$RM_CHECK" "WSGI=$RM_WSGI" "TIMEOUT_START=$RM_TIMEOUT_START" "TIMEOUT_STOP=$RM_TIMEOUT_STOP"
    gb_render "$GB_TYPES/runtime/templates/limits.conf.tmpl" "$stage.limits" \
        "KIND=$EP_KIND" "MEMORY_HIGH=$RM_MEMORY_HIGH" "MEMORY_MAX=$RM_MEMORY_MAX" \
        "CPU_QUOTA=$RM_CPU_QUOTA" "TASKS_MAX=$RM_TASKS_MAX" "NOFILE=$RM_NOFILE"
    sd_install_unit "$stage.socket" "$unit.socket"
    sd_install_unit "$stage.service" "$unit.service"
    sd_install_dropin "$stage.limits" "$unit.service" "10-limits.conf"
    [[ "$SD_UNITS_CHANGED" == true ]] && RT_RESTART_NEEDED=true
    sd_daemon_reload
}

# Switch to the release, (re)start the service behind its socket, wait for
# readiness, and fall back to the previous release when it does not come up.
rt_activate() {
    local domain="$1" release="$2" unit socket previous
    unit="$(rt_unit "$EP_KIND")"
    socket="$(rt_socket "$EP_KIND")"
    previous="${RT_PREVIOUS:-}"
    local env_changed=false
    [[ "$(gb_ledger_get "$(rt_env_file "$domain")")" != "$(gb_sha256_file "$(rt_env_file "$domain")" 2>/dev/null)" ]] && env_changed=true
    py_switch_release "$EP_KIND" "$release"
    sd_enable "$unit.socket" "$unit.service"
    sd_start "$unit.socket"
    if ! sd_available; then
        gb_log "(no systemd) release $release selected; service not started."
        return 0
    fi
    if [[ "$release" != "$previous" || "${RT_RESTART_NEEDED:-false}" == true || "$env_changed" == true ]] || ! sd_is_active "$unit.service"; then
        gb_step "Starting $unit.service"
        if ! sd_restart "$unit.service" || ! sd_wait_ready "$socket" /readyz "$RM_TIMEOUT_START"; then
            gb_warn "$unit.service did not become ready."
            sd_journal "$unit.service" 40 | tail -40 || true
            if [[ -n "$previous" && "$previous" != "$release" && -d "$previous" ]]; then
                gb_warn "Rolling back to $previous"
                py_switch_release "$EP_KIND" "$previous"
                sd_restart "$unit.service" || true
                tg_notify fail "Runtime rollback: $domain" "The new release failed its readiness check; the previous release is back in service."
            else
                tg_notify fail "Runtime failed: $domain" "$unit.service did not become ready. See: journalctl -u $unit"
            fi
            return 1
        fi
        gb_log "$unit.service is ready."
        if [[ "$release" != "$previous" ]]; then
            tg_notify ok "Runtime release live: $domain" "$EP_KIND at $(basename "$release")."
        fi
    else
        gb_log "$unit.service already running the current release."
    fi
    py_prune_releases "$EP_KIND" 3
    RT_RESTART_NEEDED=false
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
        "DOMAIN=$EP_DOMAIN" "SLUG=$EP_SLUG" "SOCKET=$(rt_socket "$EP_KIND")" \
        "WWW_DIR=$(ep_www_dir "$EP_DOMAIN")" "NGINX_GB_DIR=$GB_NGINX_GB" \
        "CACHE_TTL=${EP_CACHE_TTL:-$RM_CACHE_SECONDS}"
}

type_runtime_finish() { :; }

type_runtime_remove() {
    local domain="$1" purge="$2" kind unit user
    kind="$(ep_get "$domain" KIND)"
    unit="$(rt_unit "$kind")"
    user="$(rt_user "$kind")"
    sd_remove_unit "$unit.service"
    sd_remove_unit "$unit.socket"
    sd_daemon_reload
    rm -f -- "$(rt_env_file "$domain")"
    if [[ "$purge" == true ]]; then
        rm -rf -- "$(py_app_root "$kind")" "${GB_CACHE:?}/${kind:?}" "$GB_PREFIX/var/cache/nginx/getbible/$(gb_slug "$domain")"
        if gb_user_exists "$user" && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
            userdel "$user" 2>/dev/null || true
        fi
    fi
}

type_runtime_status() {
    local domain="$1" kind unit socket
    kind="$(ep_get "$domain" KIND)"
    unit="$(rt_unit "$kind")"
    socket="$(rt_socket "$kind")"
    printf 'Kind        : %s (%s)\n' "$kind" "$(ep_get "$domain" VERSION)"
    printf 'Service     : %s (%s)\n' "$unit.service" "$(sd_status_line "$unit.service")"
    printf 'Socket      : %s (%s)\n' "$socket" "$(sd_status_line "$unit.socket")"
    printf 'Release     : %s\n' "$(py_current_release "$kind")"
    printf 'Repository  : %s (%s)\n' "$(ep_get "$domain" REPOSITORY)" "$(ep_get "$domain" VERSION)"
    printf 'Workers     : %s x %s threads; warm: %s\n' "$(ep_get "$domain" WORKERS)" "$(ep_get "$domain" THREADS)" "$(ep_get "$domain" WARM_TRANSLATIONS "-")"
    printf 'Cache dir   : %s (%s)\n' "$GB_CACHE/$kind" "$(du -sh "$GB_CACHE/$kind" 2>/dev/null | cut -f1)"
    if [[ -S "$socket" ]]; then
        printf 'Liveness    : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/healthz 2>/dev/null || echo unreachable)"
        printf 'Readiness   : %s\n' "$(curl --silent --max-time 5 --unix-socket "$socket" http://localhost/readyz 2>/dev/null || echo unreachable)"
    fi
    if sd_available; then
        "$GB_SYSTEMCTL" show "$unit.service" --no-pager --property=MainPID,ActiveEnterTimestamp,MemoryCurrent,TasksCurrent,NRestarts 2>/dev/null | sed 's/^/  /'
    fi
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
    local domain="" kind="" version="" repository="" mode="" warm="" checksums=true default_translation="" default_reference=""
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
    domain="$(ui_input "New runtime endpoint" "Domain name for the $kind endpoint (DNS must point here)" "$kind.getbible.net")" || return 1
    gb_valid_domain "$domain" || { ui_msg "Invalid" "That is not a valid domain name."; return 1; }
    ep_exists "$domain" && { ui_msg "Exists" "$domain is already an endpoint."; return 1; }
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
    endpoint_apply "$domain"
    tg_notify ok "Endpoint deployed: $domain" "Runtime $(ep_get "$domain" KIND) endpoint, version $(ep_get "$domain" VERSION)."
}

# --- endpoint submenu --------------------------------------------------------
type_runtime_menu_items() {
    printf '%s\n' \
        restart "Restart the service" \
        journal "Service journal (last 200 lines)" \
        rebuild "Rebuild the release from the current code" \
        settings "Workers, threads, warm-up and translation settings"
}

type_runtime_menu_action() {
    local domain="$1" action="$2" kind out
    kind="$(ep_get "$domain" KIND)"
    case "$action" in
        restart) ui_run "Restart $domain" bash -c "source '$GB_LIB/systemd.sh'; sd_restart '$(rt_unit "$kind").service'" ;;
        journal)
            out="$(gb_tmpdir)/journal.$$"
            sd_journal "$(rt_unit "$kind").service" 200 > "$out"
            ui_textbox "Journal: $domain" "$out" ;;
        rebuild)
            rm -f -- "$(py_current_link "$kind")"
            ui_run "Rebuild $domain" endpoint_apply "$domain" ;;
        settings) rt_settings_menu "$domain" ;;
    esac
}

rt_settings_menu() {
    local domain="$1" key label value
    for key in WORKERS:"Gunicorn workers" THREADS:"Threads per worker" WARM_TRANSLATIONS:"Translations to warm at start (comma separated, search only)" \
               DEFAULT_TRANSLATION:"Default translation" DEFAULT_REFERENCE:"Default reference (query only)" \
               ALLOWED_TRANSLATIONS:"Allowed translations (comma separated, empty for all)" REPOSITORY:"Scripture files folder" \
               REQUIRE_CHECKSUMS:"Require .sha checksums for every file (true/false)"; do
        label="${key#*:}"
        key="${key%%:*}"
        value="$(ui_input "$domain" "$label" "$(ep_get "$domain" "$key")")" || return 0
        ep_set "$domain" "$key" "$value"
    done
    ui_run "Apply $domain" endpoint_apply "$domain"
}
