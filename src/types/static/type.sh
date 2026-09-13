#!/usr/bin/env bash
# Static domain type: a domain serving one or more trees of files that are
# synchronised from git repositories by isolated sync users. Each tree is an
# endpoint: a version folder (/v2/), or the domain root itself when the domain
# was set up without version folders (the label "root").

[[ -n "${GB_TYPE_STATIC_LOADED:-}" ]] && return 0
GB_TYPE_STATIC_LOADED=1

# --- pipeline hooks ----------------------------------------------------------

# Users, directories, tools and sync units for every version.
type_static_prepare() {
    local domain="$1" label
    sync_install_tools || return 1
    tg_install_helper 2>/dev/null || true
    sync_setup_domain "$domain" || return 1
    while read -r label; do
        [[ -n "$label" ]] || continue
        sync_setup_version "$domain" "$label" || return 1
        if [[ "${GB_LOCAL_APPLY:-false}" != true ]]; then
            sync_pin_host "$domain" "$(ep_version_get "$domain" "$label" REPO_URL)" || return 1
        fi
        sync_install_version "$domain" "$label" || return 1
    done < <(ep_versions "$domain")
}

# nginx locations: for every enabled endpoint the exact locations of its page
# and OpenAPI document, then one ^~ block for its tree, then the fallbacks. A
# root endpoint's tree is served at / and its page and document come from the
# domain-level blocks of the vhost.
type_static_render_locations() {
    local output="$1" label piece data_ext has_sha=false has_html=false ext prefix tree_root is_root root_endpoint=false
    local -a exts page openapi
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
        prefix="$(pages_prefix "$label")"
        tree_root="$(ep_data_dir "$EP_DOMAIN")"
        is_root=false
        if pages_is_root "$label"; then is_root=true; root_endpoint=true; tree_root="$tree_root/$label"; fi
        mapfile -t page < <(pages_docs_location "$EP_DOMAIN" "$label")
        mapfile -t openapi < <(pages_openapi_location "$EP_DOMAIN" "$label")
        piece="$(gb_tmpdir)/loc-$EP_SLUG-$label"
        gb_render "$GB_TYPES/static/templates/version-locations.conf.tmpl" "$piece" \
            "DOMAIN=$EP_DOMAIN" "LABEL=$label" "PREFIX=$prefix" "TREE_ROOT=$tree_root" "IS_ROOT=$is_root" \
            "DOCS_ROOT=${page[0]:-}" "DOCS_FILE=${page[1]:-}" "OPENAPI_ROOT=${openapi[0]:-}" "OPENAPI_FILE=${openapi[1]:-}" \
            "NGINX_GB_DIR=$GB_NGINX_GB" "DATA_EXT_REGEX=$data_ext" "HAS_SHA=$has_sha" \
            "HAS_HTML=$has_html" "TOKEN_ACCESS=$([[ "$EP_ACCESS_MODE" == token ]] && printf true || printf false)" "CACHE_TTL=$EP_CACHE_TTL" "SHA_CACHE_TTL=$EP_SHA_CACHE_TTL"
        cat "$piece" >> "$output"
        printf '\n' >> "$output"
    done < <(ep_versions "$EP_DOMAIN")
    piece="$(gb_tmpdir)/loc-$EP_SLUG-tail"
    gb_render "$GB_TYPES/static/templates/tail-locations.conf.tmpl" "$piece" "ROOT_ENDPOINT=$root_endpoint"
    cat "$piece" >> "$output"
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
            if userdel "$user" 2>/dev/null; then gb_identity_forget_user "$user"; fi
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

# --- pages hooks (pages.sh) --------------------------------------------------
# The endpoints of a static domain are its version folders, or "root".
type_static_endpoints() { ep_versions "$1"; }

# A static endpoint's OpenAPI document comes from its repository unless told otherwise.
type_static_openapi_default() { printf 'repository\n'; }

type_static_render_openapi() {
    gb_warn "Static endpoints do not generate OpenAPI documents; $1$(pages_prefix "$2") takes its document from the repository or from you."
    return 1
}

type_static_extensions_html() { printf '%s' "$EP_EXTENSIONS" | sed 's/,/, /g; s/\([a-z0-9]\+\)/<code>.\1<\/code>/g'; }

# type_static_render_endpoint_docs DOMAIN LABEL OUTPUT: the generated page of
# one endpoint (EP_* loaded by the caller).
type_static_render_endpoint_docs() {
    local domain="$1" label="$2" output="$3" prefix example access openapi_url="" favicon=false is_root=false
    prefix="$(pages_prefix "$label")"
    if pages_is_root "$label"; then is_root=true; fi
    example="path/to/document.json"
    access="$(gb_tmpdir)/access-$EP_SLUG-$label.html"
    docs_render_access "$access" "$prefix" "$example"
    if [[ "$(pages_openapi_source "$domain" "$label")" != none ]] && pages_file_present "$domain" "$label" openapi; then
        openapi_url="${prefix}openapi.json"
    fi
    if pages_favicon_active "$domain"; then favicon=true; fi
    gb_render "$GB_DOCS_SRC/static-endpoint.html.tmpl" "$output" "DOMAIN=$domain" "PREFIX=$prefix" \
        "LABEL=$label" "IS_ROOT=$is_root" "FAVICON=$favicon" "CSS=$(cat "$GB_DOCS_SRC/base.css")" \
        "HEAD_ICONS=$(docs_head_icons "$domain")" "LOGO_URL=$(docs_logo_url "$domain")" "ICON_URL=$(docs_icon_url "$domain")" \
        "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" "EXAMPLE_PATH=$example" \
        "OPENAPI_URL=$openapi_url" "EXTENSIONS_LIST=$(type_static_extensions_html)" \
        "CACHE_TTL=$EP_CACHE_TTL" "SHA_CACHE_TTL=$EP_SHA_CACHE_TTL" "ACCESS_HTML=$(cat "$access")"
}

# type_static_check_label DOMAIN LABEL: version folders and a root endpoint
# never share a domain.
type_static_check_label() {
    local domain="$1" label="$2" existing
    gb_valid_endpoint_label "$label" || { gb_warn "Invalid version label: $label (v1, v2, ... or root)"; return 1; }
    existing="$(ep_versions "$domain" | tr '\n' ' ')"
    existing="${existing% }"
    [[ -n "$existing" ]] || return 0
    if pages_is_root "$label"; then
        gb_warn "$domain already serves version folders ($existing); its root cannot become an endpoint as well."
        return 1
    elif [[ "$existing" == "$GB_ROOT_LABEL" ]]; then
        gb_warn "$domain serves its only endpoint at the domain root; remove that endpoint before adding version folders."
        return 1
    fi
}

# The domain page: one row per endpoint. A root-endpoint domain has no
# separate domain page (pages.sh serves the endpoint's page at /).
type_static_render_docs() {
    local output="$1" rows first example access no_versions=false favicon=false versions_json=false
    rows="$(docs_versions_rows "$EP_DOMAIN")"
    first="$(ep_versions "$EP_DOMAIN" | head -1)"
    [[ -n "$rows" ]] || no_versions=true
    example="path/to/document.json"
    access="$(gb_tmpdir)/access-$EP_SLUG.html"
    docs_render_access "$access" "/${first:-v1}/" "$example"
    if pages_favicon_active "$EP_DOMAIN"; then favicon=true; fi
    if pages_versions_active "$EP_DOMAIN"; then versions_json=true; fi
    gb_render "$GB_DOCS_SRC/static.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
        "CSS=$(cat "$GB_DOCS_SRC/base.css")" "ACCESS_MODE_LABEL=$(docs_access_label "$EP_ACCESS_MODE")" \
        "VERSIONS_ROWS=$rows" "NO_VERSIONS=$no_versions" "FIRST_VERSION=${first:-v1}" \
        "EXAMPLE_PATH=$example" "EXTENSIONS_LIST=$(type_static_extensions_html)" "CACHE_TTL=$EP_CACHE_TTL" \
        "SHA_CACHE_TTL=$EP_SHA_CACHE_TTL" "ACCESS_HTML=$(cat "$access")" "FAVICON=$favicon" "VERSIONS_JSON=$versions_json" \
        "HEAD_ICONS=$(docs_head_icons "$EP_DOMAIN")" "LOGO_URL=$(docs_logo_url "$EP_DOMAIN")" "ICON_URL=$(docs_icon_url "$EP_DOMAIN")"
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
    local domain label repo ref subpath extensions mode schedule selection cfmode
    ui_msg "New static domain" "This walkthrough asks for: the domain, its first endpoint (a version folder such as v2, or the domain root), the git repository, branch and folder, the file types to serve, the access mode, the check schedule$(cf_enabled 2>/dev/null && printf ', the Cloudflare mode' || true), and whether to go live now or stage the domain.\n\nIt then creates the sync user and its deploy key, installs the timers, nginx and the documentation pages, and shows the public key to add to the repository. Cancel at any question to stop without changes."
    domain="$(ui_input "New static domain" "Domain name (DNS may still point at another server; you choose when it goes live)" "")" || return 1
    gb_valid_domain "$domain" || { ui_msg "Invalid" "That is not a valid domain name."; return 1; }
    ep_exists "$domain" && { ui_msg "Exists" "$domain is already set up on this server."; return 1; }
    GB_DEPLOY_MODE="$(endpoint_prompt_deploy_mode "$domain")" || return 1
    label="$(ui_input "First endpoint" "Version folder served under https://$domain/<version>/ (v1, v2, ...).\n\nLeave it empty when this domain serves a single endpoint at its root, https://$domain/, without version folders." "v2")" || return 1
    label="${label// /}"
    [[ -n "$label" ]] || label="$GB_ROOT_LABEL"
    gb_valid_endpoint_label "$label" || { ui_msg "Invalid" "Version labels look like v1, v2, v3; leave the field empty for the domain root."; return 1; }
    repo="$(ui_input "Repository" "Git repository holding the files, as an SSH URL for private repositories: git@github.com:owner/repo.git. The user before @ is the host's SSH user (always git on GitHub, GitLab and Gitea), not your account; this endpoint's deploy key is the identity. Self-hosted with another user or port: ssh://user@host:port/path/repo.git. Public repositories may use https://." "git@github.com:getbible/")" || return 1
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
    cfmode="$(endpoint_prompt_cloudflare_mode "$domain")" || return 1
    type_static_create "$domain" "$extensions" "$mode" "$schedule"
    ep_set "$domain" CLOUDFLARE_MODE "$cfmode"
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
    gb_valid_endpoint_label "$label" || gb_die "Invalid version label: $label (expected v1, v2, ... or root for a domain without version folders)"
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
        if ! ui_yesno "Conflict" "Another nginx file already declares $domain:\n$conflicts\n\nContinue anyway? (Resolve the conflicting configuration before applying this domain.)" no; then
            ep_remove_config "$domain"
            return 1
        fi
    fi
    endpoint_apply "$domain" || return 1
    if ep_is_live "$domain"; then
        tg_notify ok "Domain deployed: $domain" "Static domain with endpoint $(pages_label_text "$label"). The first sync runs once the deploy key is authorised on the repository."
        if ! nginx_cert_exists "$domain"; then
            ui_msg "HTTPS pending" "$domain has no certificate yet. Port 80 serves challenges and redirects to HTTPS; API traffic needs a certificate. Choose Domain > Certificate > Issue once DNS reaches this server."
        fi
    else
        tg_notify ok "Domain staged: $domain" "Static domain with endpoint $(pages_label_text "$label"), prepared on $(hostname -f 2>/dev/null || hostname). Not live: no certificate or DNS change until 'Go live'."
        ui_msg "Staged" "$domain is staged on this server: synchronisation, nginx, its pages and a placeholder certificate are in place, but no certificate was requested and DNS was not changed.\n\nSync its data, verify it, and choose 'Go live' from the main menu or the domain menu when it should take over."
    fi
    type_static_show_key "$domain" "$label"
    if ui_yesno "First sync" "Has the deploy key been added to the repository? Run the first sync now?" no; then
        sync_run_now "$domain" "$label"
    fi
}

type_static_show_key() {
    local domain="$1" label="$2" text
    sync_setup_domain "$domain" || return 1
    sync_setup_version "$domain" "$label" || return 1
    text="Endpoint: $domain $(pages_label_text "$label")
Repository: $(ep_version_get "$domain" "$label" REPO_URL)

Add this endpoint's public key to this repository as a read-only deploy key (GitHub: Settings > Deploy keys; Gitea: Settings > Deploy Keys). Every endpoint has its own key; never register another endpoint's key here. The SSH hostname and user in the repository URL stay unchanged (git@github.com on GitHub).

$(sync_public_key "$domain" "$label")

Key file: $(sync_endpoint_key "$domain" "$label").pub

After registration, test access and run 'Sync now' for this endpoint."
    if [[ "${GB_UI_CAPTURED:-false}" == true ]]; then
        # Add/change actions run inside ui_run. Include the key in its result
        # textbox rather than opening a dialog while output is redirected.
        printf '\n== Deploy key: %s %s ==\n%s\n\n' "$domain" "$label" "$text"
    else
        ui_msg "Deploy key: $domain $label" "$text"
    fi
}

# --- versions ----------------------------------------------------------------
type_static_add_version() {
    local domain="$1" label="$2" repo="$3" ref="$4" subpath="$5"
    ep_version_exists "$domain" "$label" && gb_die "Version $label already exists on $domain"
    type_static_check_label "$domain" "$label" || return 1
    ep_version_create "$domain" "$label" "$repo" "$ref" "$subpath"
    endpoint_apply "$domain" || return 1
    tg_notify ok "Endpoint added: $domain $label" "Repository $repo ($ref). The timer will publish it on the next check; use 'Sync now' to publish immediately."
    type_static_show_key "$domain" "$label"
}

# type_static_change_version DOMAIN LABEL REPO REF SUBPATH: point an existing
# version at another repository, branch or folder without losing its
# releases. Empty values keep the current ones; the next sync applies it.
type_static_change_version() {
    local domain="$1" label="$2" repo="$3" ref="$4" subpath="$5" old_repo
    ep_version_exists "$domain" "$label" || gb_die "No version $label on $domain"
    old_repo="$(ep_version_get "$domain" "$label" REPO_URL)"
    repo="${repo:-$(ep_version_get "$domain" "$label" REPO_URL)}"
    ref="${ref:-$(ep_version_get "$domain" "$label" REPO_REF)}"
    subpath="${subpath:-$(ep_version_get "$domain" "$label" SOURCE_PATH)}"
    gb_valid_repo_url "$repo" || gb_die "Invalid repository URL: $repo"
    gb_valid_subpath "$subpath" || gb_die "Invalid source path: $subpath"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]{1,120}$ ]] || gb_die "Invalid git reference: $ref"
    ep_version_set "$domain" "$label" REPO_URL "$repo"
    ep_version_set "$domain" "$label" REPO_REF "$ref"
    ep_version_set "$domain" "$label" SOURCE_PATH "$subpath"
    endpoint_apply "$domain" || return 1
    tg_notify info "Endpoint source changed: $domain $label" "Repository $repo ($ref), folder $subpath. The next sync publishes from there; use 'Sync now' to do it at once."
    if [[ "$repo" != "$old_repo" ]]; then type_static_show_key "$domain" "$label"; fi
}

type_static_remove_version() {
    local domain="$1" label="$2"
    ep_version_exists "$domain" "$label" || gb_die "No version $label on $domain"
    sync_remove_version "$domain" "$label"
    ep_version_remove_config "$domain" "$label"
    rm -f -- "$(ep_version_path "$domain" "$label")"
    rm -rf -- "$(ep_releases_dir "$domain" "$label")"
    endpoint_apply "$domain" || return 1
    tg_notify warn "Endpoint removed: $domain $label" "The endpoint is no longer served and its releases were deleted."
}

# --- endpoint submenu actions ------------------------------------------------
type_static_menu_items() {
    printf '%s\n' \
        sync "Sync now (check the repositories and publish updates)" \
        force "Force a full resync of a version" \
        key "Deployment keys: choose an endpoint" \
        versions "Endpoints: add, change or remove version folders" \
        filetypes "File types served (json, sha, txt, html)" \
        repoaccess "Test repository access (deploy key and branch)"
}

type_static_ext_state() { [[ ",$1," == *",$2,"* ]] && printf 'on\n' || printf 'off\n'; }

# type_static_set_extensions DOMAIN LIST: change the served file types; the
# next sync exports them and nginx serves them.
type_static_set_extensions() {
    local domain="$1" extensions="$2" ext
    IFS=',' read -r -a exts <<< "$extensions"
    [[ ${#exts[@]} -gt 0 ]] || gb_die "Choose at least one file type."
    for ext in "${exts[@]}"; do gb_valid_extension "${ext// /}" || gb_die "Invalid file extension: $ext"; done
    ep_set "$domain" EXTENSIONS "$extensions"
    endpoint_apply "$domain" || return 1
    tg_notify info "File types changed: $domain" "Now served: $extensions. The next sync exports them."
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
        key)
            label="$(type_static_pick_version "$domain")" || return 0
            type_static_key_menu "$domain" "$label"
            ;;
        versions) type_static_versions_menu "$domain" ;;
        filetypes)
            local selection extensions current
            current="$(ep_get "$domain" EXTENSIONS)"
            selection="$(ui_checklist "File types" "Which file types may be served? Others are never copied to the server. The change is applied to nginx now and to the files at the next sync." \
                json "JSON documents" "$(type_static_ext_state "$current" json)" \
                sha "SHA-1 checksum files" "$(type_static_ext_state "$current" sha)" \
                txt "Plain text files" "$(type_static_ext_state "$current" txt)" \
                html "HTML pages" "$(type_static_ext_state "$current" html)")" || return 0
            extensions="$(printf '%s' "$selection" | tr ' ' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')"
            [[ -n "$extensions" ]] || { ui_msg "Invalid" "Choose at least one file type."; return 0; }
            endpoint_confirm_hand_edits "$domain" || return 0
            ui_run "File types for $domain" type_static_set_extensions "$domain" "$extensions" || true
            GB_OVERWRITE_HAND_EDITS=false
            ;;
        repoaccess)
            label="$(type_static_pick_version "$domain")" || return 0
            ui_run "Repository access: $domain $label" sync_test_access "$domain" "$label" || true
            ;;
    esac
}

# Endpoint-specific key actions; choose the endpoint before showing any key
# or checking access. The menu always names the repository being authorised.
type_static_key_menu() {
    local domain="$1" label="$2" choice
    while true; do
        choice="$(ui_menu "Deployment key: $domain $label" \
            "Repository: $(ep_version_get "$domain" "$label" REPO_URL)" \
            show "Show this endpoint's public key" \
            test "Test repository access with the active key" \
            sync "Sync this endpoint now" \
            back "Back")" || return 0
        case "$choice" in
            show) type_static_show_key "$domain" "$label" || true ;;
            test) ui_run "Repository access: $domain $label" sync_test_access "$domain" "$label" || true ;;
            sync) ui_run "Sync $domain $label" sync_run_now "$domain" "$label" || true ;;
            back) return 0 ;;
        esac
    done
}

type_static_pick_version() {
    local domain="$1" label
    local -a items=()
    while read -r label; do [[ -n "$label" ]] && items+=("$label" "$(ep_version_get "$domain" "$label" REPO_URL)"); done < <(ep_versions "$domain")
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Endpoints" "No endpoints configured."; return 1; }
    ui_menu "Endpoints of $domain" "Choose an endpoint (root is the domain root)" "${items[@]}"
}

type_static_versions_menu() {
    local domain="$1" choice label repo ref subpath
    while true; do
        choice="$(ui_menu "Endpoints of $domain" "Endpoints: $(ep_versions "$domain" | sed "s/^$GB_ROOT_LABEL\$/the domain root/" | tr '\n' ' ')" \
            add "Add a version folder" \
            change "Change an endpoint's repository, branch or folder (keeps its releases)" \
            remove "Remove an endpoint" \
            status "Show an endpoint's sync status" \
            key "Manage an endpoint's deployment key and repository access" \
            back "Back")" || return 0
        case "$choice" in
            add)
                if pages_has_root_endpoint "$domain"; then
                    ui_msg "Domain root" "$domain serves its only endpoint at the domain root (https://$domain/). Version folders cannot be added next to it; remove that endpoint first if the domain should switch to version folders."
                    continue
                fi
                label="$(ui_input "Version folder" "New version folder (v1, v2, ...), served under https://$domain/<version>/" "")" || continue
                gb_valid_version "$label" || { ui_msg "Invalid" "Version labels look like v1, v2, v3."; continue; }
                ep_version_exists "$domain" "$label" && { ui_msg "Exists" "$domain already has $label."; continue; }
                repo="$(ui_input "Repository" "Git repository for this endpoint. It gets its own deploy key, even when other endpoints use the same host." "git@github.com:getbible/")" || continue
                ref="$(ui_input "Branch or tag" "Git branch or tag" "master")" || continue
                subpath="$(ui_input "Source path" "Folder inside the repository (. for the root)" ".")" || continue
                ui_run "Add endpoint" type_static_add_version "$domain" "$label" "$repo" "$ref" "$subpath" || true
                ;;
            change)
                label="$(type_static_pick_version "$domain")" || continue
                repo="$(ui_input "Repository" "Git repository (SSH URL; the user before @ is the host's SSH user, the deploy key is the identity)" "$(ep_version_get "$domain" "$label" REPO_URL)")" || continue
                gb_valid_repo_url "$repo" || { ui_msg "Invalid" "That does not look like a git URL."; continue; }
                ref="$(ui_input "Branch or tag" "Git branch or tag" "$(ep_version_get "$domain" "$label" REPO_REF)")" || continue
                subpath="$(ui_input "Source path" "Folder inside the repository (. for the root)" "$(ep_version_get "$domain" "$label" SOURCE_PATH)")" || continue
                gb_valid_subpath "$subpath" || { ui_msg "Invalid" "Source paths are relative, without '..'."; continue; }
                endpoint_confirm_hand_edits "$domain" || continue
                ui_run "Change endpoint source" type_static_change_version "$domain" "$label" "$repo" "$ref" "$subpath" || true
                GB_OVERWRITE_HAND_EDITS=false
                ;;
            remove)
                label="$(type_static_pick_version "$domain")" || continue
                ui_yesno "Remove endpoint" "Remove $(pages_label_text "$label") from $domain? Its releases on disk are deleted." no || continue
                ui_run "Remove endpoint" type_static_remove_version "$domain" "$label" || true
                ;;
            status)
                label="$(type_static_pick_version "$domain")" || continue
                sync_status_text "$domain" "$label" > "$(gb_tmpdir)/vstatus"
                ui_textbox "$domain $label" "$(gb_tmpdir)/vstatus"
                ;;
            key)
                label="$(type_static_pick_version "$domain")" || continue
                type_static_key_menu "$domain" "$label"
                ;;
            back) return 0 ;;
        esac
    done
}
