#!/usr/bin/env bash
# Static endpoint type: a domain serving one or more versioned trees of files
# that are synchronised from git repositories by isolated sync users.

[[ -n "${GB_TYPE_STATIC_LOADED:-}" ]] && return 0
GB_TYPE_STATIC_LOADED=1

# --- pipeline hooks ----------------------------------------------------------

# Users, directories, tools and sync units for every version.
type_static_prepare() {
    local domain="$1" label
    sync_install_tools
    tg_install_helper 2>/dev/null || true
    sync_setup_domain "$domain"
    while read -r label; do
        [[ -n "$label" ]] || continue
        sync_pin_host "$domain" "$(ep_version_get "$domain" "$label" REPO_URL)"
        sync_install_version "$domain" "$label"
    done < <(ep_versions "$domain")
}

# nginx locations: one ^~ block per enabled version plus the fallbacks.
type_static_render_locations() {
    local output="$1" label piece data_ext has_sha=false has_html=false ext
    TYPE_METHODS_REGEX="GET|HEAD|OPTIONS"
    TYPE_REJECT_ARGS=true
    TYPE_MAX_BODY=1k
    TYPE_PROXY_CACHE=false
    : > "$output"
    data_ext=""
    IFS=',' read -r -a exts <<< "$EP_EXTENSIONS"
    for ext in "${exts[@]}"; do
        ext="${ext// /}"
        [[ -n "$ext" ]] || continue
        case "$ext" in
            sha) has_sha=true ;;
            html) has_html=true ;;
            *) data_ext="${data_ext:+$data_ext|}$ext" ;;
        esac
    done
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$EP_DOMAIN" "$label" ENABLED true)" == true ]] || continue
        piece="$(gb_tmpdir)/loc-$EP_SLUG-$label"
        gb_render "$GB_TYPES/static/templates/version-locations.conf.tmpl" "$piece" \
            "DOMAIN=$EP_DOMAIN" "LABEL=$label" "DATA_DIR=$(ep_data_dir "$EP_DOMAIN")" \
            "NGINX_GB_DIR=$GB_NGINX_GB" "DATA_EXT_REGEX=$data_ext" "HAS_SHA=$has_sha" \
            "HAS_HTML=$has_html" "TOKEN_ACCESS=$([[ "$EP_ACCESS_MODE" == token ]] && printf true || printf false)" "CACHE_TTL=$EP_CACHE_TTL" "SHA_CACHE_TTL=$EP_SHA_CACHE_TTL"
        cat "$piece" >> "$output"
        printf '\n' >> "$output"
    done < <(ep_versions "$EP_DOMAIN")
    cat "$GB_TYPES/static/templates/tail-locations.conf.tmpl" >> "$output"
}

type_static_finish() { :; }

type_static_remove() {
    local domain="$1" purge="$2" label user home
    while read -r label; do
        [[ -n "$label" ]] || continue
        sync_remove_version "$domain" "$label"
    done < <(ep_versions "$domain")
    if [[ "$purge" == true ]]; then
        user="$(sync_user "$domain")"
        home="$(sync_home "$domain")"
        rm -rf -- "$(ep_data_dir "$domain")" "$home"
        if gb_user_exists "$user" && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
            userdel "$user" 2>/dev/null || true
        fi
    fi
}

type_static_status() {
    local domain="$1" label
    printf 'Sync user   : %s\n' "$(sync_user "$domain")"
    printf 'Data root   : %s\n' "$(ep_data_dir "$domain")"
    printf 'File types  : %s\n' "$(ep_get "$domain" EXTENSIONS)"
    printf 'Schedule    : %s\n' "$(ep_get "$domain" SYNC_SCHEDULE)"
    printf '\n'
    while read -r label; do
        [[ -n "$label" ]] || continue
        sync_status_text "$domain" "$label"
        printf '\n'
    done < <(ep_versions "$domain")
}

type_static_render_docs() {
    local output="$1" rows first example access no_versions=false ext_list
    rows="$(docs_versions_rows "$EP_DOMAIN")"
    first="$(ep_versions "$EP_DOMAIN" | head -1)"
    [[ -n "$rows" ]] || no_versions=true
    example="path/to/document.json"
    access="$(gb_tmpdir)/access-$EP_SLUG.html"
    docs_render_access "$access" "${first:-v1}" "$example"
    ext_list="$(printf '%s' "$EP_EXTENSIONS" | sed 's/,/, /g; s/\([a-z0-9]\+\)/<code>.\1<\/code>/g')"
    gb_render "$GB_DOCS_SRC/static.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
        "CSS=$(cat "$GB_DOCS_SRC/base.css")" "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" \
        "VERSIONS_ROWS=$rows" "NO_VERSIONS=$no_versions" "FIRST_VERSION=${first:-v1}" \
        "EXAMPLE_PATH=$example" "EXTENSIONS_LIST=$ext_list" "CACHE_TTL=$EP_CACHE_TTL" \
        "SHA_CACHE_TTL=$EP_SHA_CACHE_TTL" "ACCESS_HTML=$(cat "$access")"
}

# --- deploy ------------------------------------------------------------------

# type_static_create DOMAIN EXTENSIONS ACCESS_MODE SCHEDULE: registry only.
type_static_create() {
    local domain="$1" extensions="$2" mode="$3" schedule="$4" ext
    access_valid_mode "$mode" || gb_die "Invalid access mode: $mode"
    [[ "$schedule" =~ ^(daily|weekly|monthly)$ ]] || gb_die "Invalid schedule: $schedule (daily, weekly or monthly)"
    IFS=',' read -r -a exts <<< "$extensions"
    for ext in "${exts[@]}"; do gb_valid_extension "${ext// /}" || gb_die "Invalid file extension: $ext"; done
    ep_create "$domain" static static
    ep_set "$domain" EXTENSIONS "$extensions"
    ep_set "$domain" ACCESS_MODE "$mode"
    ep_set "$domain" SYNC_SCHEDULE "$schedule"
    ep_set "$domain" CACHE_TTL "$(gb_global DEFAULT_CACHE_TTL 3600)"
    ep_set "$domain" SHA_CACHE_TTL "$(gb_global DEFAULT_SHA_CACHE_TTL 300)"
}

# Interactive deployment of a new static endpoint.
type_static_deploy_interactive() {
    local domain label repo ref subpath extensions mode schedule selection
    domain="$(ui_input "New static endpoint" "Domain name (DNS may still point at another server; you choose when it goes live)" "")" || return 1
    gb_valid_domain "$domain" || { ui_msg "Invalid" "That is not a valid domain name."; return 1; }
    ep_exists "$domain" && { ui_msg "Exists" "$domain is already an endpoint."; return 1; }
    GB_DEPLOY_MODE="$(endpoint_prompt_deploy_mode "$domain")" || return 1
    label="$(ui_input "Version" "Version served under https://$domain/<version>/ (v1, v2, ...)" "v2")" || return 1
    gb_valid_version "$label" || { ui_msg "Invalid" "Version labels look like v1, v2, v3."; return 1; }
    repo="$(ui_input "Repository" "Git repository holding the files (ssh URL for private repositories)" "git@github.com:getbible/")" || return 1
    gb_valid_repo_url "$repo" || { ui_msg "Invalid" "That does not look like a git URL."; return 1; }
    ref="$(ui_input "Branch or tag" "Git branch or tag to publish" "master")" || return 1
    subpath="$(ui_input "Source path" "Folder inside the repository that holds this version (. for the repository root)" ".")" || return 1
    gb_valid_subpath "$subpath" || { ui_msg "Invalid" "Source paths are relative, without '..'."; return 1; }
    selection="$(ui_checklist "File types" "Which file types may be served? Everything else is never copied to the server." \
        json "JSON documents" on sha "SHA-1 checksum files" on txt "Plain text files" on html "HTML pages" off)" || return 1
    extensions="$(printf '%s' "$selection" | tr ' ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')"
    [[ -n "$extensions" ]] || { ui_msg "Invalid" "Choose at least one file type."; return 1; }
    mode="$(endpoint_prompt_access_mode)" || return 1
    schedule="$(ui_radiolist "Update check" "How often should the repository be checked for new commits?" \
        weekly "Once a week (default)" on daily "Once a day" off monthly "Once a month" off)" || return 1
    type_static_create "$domain" "$extensions" "$mode" "$schedule"
    ep_version_create "$domain" "$label" "$repo" "$ref" "$subpath"
    type_static_deploy_finish "$domain" "$label"
}

# Non-interactive deployment used by the CLI and tests.
type_static_deploy_cli() {
    local domain="" label="" repo="" ref="master" subpath="." extensions="" mode="" schedule=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) domain="$2"; shift 2 ;;
            --version) label="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            --ref) ref="$2"; shift 2 ;;
            --path) subpath="$2"; shift 2 ;;
            --extensions) extensions="$2"; shift 2 ;;
            --access) mode="$2"; shift 2 ;;
            --schedule) schedule="$2"; shift 2 ;;
            --staged) GB_DEPLOY_MODE=staged; shift ;;
            --live) GB_DEPLOY_MODE=live; shift ;;
            *) gb_die "Unknown option for deploy static: $1" ;;
        esac
    done
    [[ -n "$domain" && -n "$label" && -n "$repo" ]] || gb_die "deploy static needs --domain, --version and --repo"
    extensions="${extensions:-$(gb_global DEFAULT_EXTENSIONS json,sha,txt)}"
    mode="${mode:-$(gb_global DEFAULT_ACCESS_MODE metered)}"
    schedule="${schedule:-$(gb_global DEFAULT_SYNC_SCHEDULE weekly)}"
    gb_valid_domain "$domain" || gb_die "Invalid domain: $domain"
    gb_valid_version "$label" || gb_die "Invalid version label: $label (expected v1, v2, ...)"
    gb_valid_repo_url "$repo" || gb_die "Invalid repository URL: $repo"
    gb_valid_subpath "$subpath" || gb_die "Invalid source path: $subpath"
    type_static_create "$domain" "$extensions" "$mode" "$schedule"
    ep_version_create "$domain" "$label" "$repo" "$ref" "$subpath"
    type_static_deploy_finish "$domain" "$label"
}

type_static_deploy_finish() {
    local domain="$1" label="$2" conflicts
    conflicts="$(nginx_conflicts "$domain")"
    if [[ -n "$conflicts" ]]; then
        gb_warn "$domain is already declared in: $conflicts"
        if ! ui_yesno "Conflict" "Another nginx file already declares $domain:\n$conflicts\n\nContinue anyway? (Use the migration action to retire the old configuration.)" no; then
            ep_remove_config "$domain"
            return 1
        fi
    fi
    endpoint_apply "$domain"
    if ep_is_live "$domain"; then
        tg_notify ok "Endpoint deployed: $domain" "Static endpoint with version $label. The first sync runs once the deploy key is authorised on the repository."
    else
        tg_notify ok "Endpoint staged: $domain" "Static endpoint with version $label, prepared on $(hostname -f 2>/dev/null || hostname). Not live: no certificate or DNS change until 'Go live'."
        ui_msg "Staged" "$domain is staged on this server: synchronisation, nginx and a placeholder certificate are in place, but no certificate was requested and DNS was not changed.\n\nSync its data, verify it, and choose 'Go live' from the main menu or the endpoint menu when it should take over."
    fi
    type_static_show_key "$domain"
    if ui_yesno "First sync" "Has the deploy key been added to the repository? Run the first sync now?" no; then
        sync_run_now "$domain" "$label"
    fi
}

type_static_show_key() {
    local domain="$1" text
    text="Add this public key to the repository as a read-only deploy key (GitHub: Settings > Deploy keys; Gitea: Settings > Deploy Keys), then run 'Sync now'.

$(sync_public_key "$domain")

Sync user: $(sync_user "$domain")
Key file : $(sync_home "$domain")/.ssh/id_ed25519.pub"
    ui_msg "Deploy key for $domain" "$text"
}

# --- versions ----------------------------------------------------------------
type_static_add_version() {
    local domain="$1" label="$2" repo="$3" ref="$4" subpath="$5"
    ep_version_exists "$domain" "$label" && gb_die "Version $label already exists on $domain"
    ep_version_create "$domain" "$label" "$repo" "$ref" "$subpath"
    endpoint_apply "$domain"
    tg_notify ok "Version added: $domain $label" "Repository $repo ($ref). The timer will publish it on the next check; use 'Sync now' to publish immediately."
}

type_static_remove_version() {
    local domain="$1" label="$2"
    ep_version_exists "$domain" "$label" || gb_die "No version $label on $domain"
    sync_remove_version "$domain" "$label"
    ep_version_remove_config "$domain" "$label"
    rm -f -- "$(ep_version_path "$domain" "$label")"
    rm -rf -- "$(ep_releases_dir "$domain" "$label")"
    endpoint_apply "$domain"
    tg_notify warn "Version removed: $domain $label" "The version is no longer served and its releases were deleted."
}

# --- endpoint submenu actions ------------------------------------------------
type_static_menu_items() {
    printf '%s\n' \
        sync "Sync now (check the repositories and publish updates)" \
        force "Force a full resync of a version" \
        key "Show the deploy key" \
        versions "Manage versions" \
        access "Test repository access"
}

type_static_menu_action() {
    local domain="$1" action="$2" label
    case "$action" in
        sync)
            while read -r label; do [[ -n "$label" ]] && ui_run "Sync $domain $label" sync_run_now "$domain" "$label"; done < <(ep_versions "$domain")
            ;;
        force)
            label="$(type_static_pick_version "$domain")" || return 0
            ui_run "Resync $domain $label" sync_force_now "$domain" "$label"
            ;;
        key) type_static_show_key "$domain" ;;
        versions) type_static_versions_menu "$domain" ;;
        access)
            label="$(type_static_pick_version "$domain")" || return 0
            ui_run "Repository access" sync_test_access "$domain" "$(ep_version_get "$domain" "$label" REPO_URL)" "$(ep_version_get "$domain" "$label" REPO_REF)"
            ;;
    esac
}

type_static_pick_version() {
    local domain="$1" label
    local -a items=()
    while read -r label; do [[ -n "$label" ]] && items+=("$label" "$(ep_version_get "$domain" "$label" REPO_URL)"); done < <(ep_versions "$domain")
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Versions" "No versions configured."; return 1; }
    ui_menu "Versions of $domain" "Choose a version" "${items[@]}"
}

type_static_versions_menu() {
    local domain="$1" choice label repo ref subpath
    while true; do
        choice="$(ui_menu "Versions of $domain" "$(ep_versions "$domain" | tr '\n' ' ')" \
            add "Add a version" remove "Remove a version" status "Show version status" back "Back")" || return 0
        case "$choice" in
            add)
                label="$(ui_input "Version" "New version label (v1, v2, ...)" "")" || continue
                gb_valid_version "$label" || { ui_msg "Invalid" "Version labels look like v1, v2, v3."; continue; }
                repo="$(ui_input "Repository" "Git repository" "$(ep_version_get "$domain" "$(ep_versions "$domain" | head -1)" REPO_URL)")" || continue
                ref="$(ui_input "Branch or tag" "Git branch or tag" "master")" || continue
                subpath="$(ui_input "Source path" "Folder inside the repository (. for the root)" ".")" || continue
                ui_run "Add version" type_static_add_version "$domain" "$label" "$repo" "$ref" "$subpath"
                ;;
            remove)
                label="$(type_static_pick_version "$domain")" || continue
                ui_yesno "Remove version" "Remove $label from $domain? Its releases on disk are deleted." no || continue
                ui_run "Remove version" type_static_remove_version "$domain" "$label"
                ;;
            status)
                label="$(type_static_pick_version "$domain")" || continue
                sync_status_text "$domain" "$label" > "$(gb_tmpdir)/vstatus"
                ui_textbox "$domain $label" "$(gb_tmpdir)/vstatus"
                ;;
            back) return 0 ;;
        esac
    done
}
