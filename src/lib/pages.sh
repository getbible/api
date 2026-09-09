#!/usr/bin/env bash
# The files a domain publishes besides its data: documentation pages, OpenAPI
# documents, the favicon and versions.json.
#
# Vocabulary: a domain is the host name (one vhost, one certificate, one
# go-live); an endpoint is one of its version folders (/v2/), or the domain
# root itself when the domain was set up without version folders (the label
# "root": domain and endpoint are then the same thing).
#
#   domain page       /                 generated | custom
#   endpoint page     /vN/              generated | custom | repository | none
#   endpoint OpenAPI  /vN/openapi.json  generated (runtime) | repository (static) | custom | none
#   favicon           /favicon.ico      default (the system favicon) | custom | none
#   logo and icons    /img/...          default (the system logo) | custom | none
#   versions.json     /versions.json    generated for every domain (lists enabled
#                                       endpoints whose OpenAPI document is present)
#
# The repository ships the icons (img/): the favicon, the logo the pages show
# at the top, the icon they show at the foot, the touch icon and the
# link-preview image. Every domain publishes them unless the operator replaced
# the favicon or the logo for every domain (Settings > Icons) or for that
# domain, or switched one off.
#
# Generated files are rewritten on every apply and update. A custom file is
# yours: it lives under /var/www/getbible/<domain>/, never inside a repository
# checkout, is never rewritten, and stays until you hand the page back to
# "generated". A repository file is served straight from the version's tree
# and follows every sync. These pages are served by their own nginx rules, so
# they load whatever file types the endpoint allows for its data.

[[ -n "${GB_PAGES_LOADED:-}" ]] && return 0
GB_PAGES_LOADED=1

GB_ROOT_LABEL=root

# The repository's icons (img/) and what each one is for.
GB_ICON_FAVICON=icon-96.png     # /favicon.ico, and the icon at the foot of every page
GB_ICON_TOUCH=icon-180.png      # apple-touch-icon (home screens, bookmarks)
GB_ICON_LARGE=icon-230.png      # the large icon browsers pick for shortcuts
GB_ICON_LOGO=logo.png           # the logo at the top of every page
GB_ICON_SOCIAL=social.png       # the image link previews show (og:image)
GB_ICONS_WITH_FAVICON=("$GB_ICON_TOUCH" "$GB_ICON_LARGE")   # published with the repository favicon
GB_ICONS_WITH_LOGO=("$GB_ICON_FAVICON" "$GB_ICON_SOCIAL")   # published with the repository logo
GB_FAVICON_TYPES_TEXT="Favicons are .ico, .png, .svg or .gif files."
GB_LOGO_TYPES_TEXT="Logos are .png, .jpg, .svg, .gif or .webp files."

pages_is_root() { [[ "$1" == "$GB_ROOT_LABEL" ]]; }
pages_prefix() { if pages_is_root "$1"; then printf '/\n'; else printf '/%s/\n' "$1"; fi; }
pages_label_text() { if pages_is_root "$1"; then printf 'the domain root\n'; else printf '%s\n' "$1"; fi; }
pages_endpoint_dir() { if pages_is_root "$2"; then ep_www_dir "$1"; else printf '%s/%s\n' "$(ep_www_dir "$1")" "$2"; fi; }
pages_docs_file() { printf '%s/index.html\n' "$(pages_endpoint_dir "$1" "$2")"; }
pages_openapi_file() { printf '%s/openapi.json\n' "$(pages_endpoint_dir "$1" "$2")"; }
pages_favicon_file() { printf '%s/favicon.ico\n' "$(ep_www_dir "$1")"; }
pages_img_dir() { printf '%s/img\n' "$(ep_www_dir "$1")"; }
pages_versions_file() { printf '%s/versions.json\n' "$(ep_www_dir "$1")"; }

pages_valid_source() { [[ "$1" =~ ^(generated|custom|repository|none)$ ]]; }
pages_valid_repo_path() { [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$1" != .* && "$1" != *..* && "$1" != */.* ]]; }

# The endpoints (version labels) of a domain, from its type.
pages_endpoints() {
    local domain="$1" type
    type="$(ep_get "$domain" TYPE)"
    endpoint_source_type "$type"
    "type_${type}_endpoints" "$domain"
}
pages_has_root_endpoint() { [[ "$(pages_endpoints "$1" | head -1)" == "$GB_ROOT_LABEL" ]]; }
pages_endpoint_exists() { pages_endpoints "$1" | grep -qx -- "$2"; }

# --- sources ------------------------------------------------------------------
pages_domain_docs_source() {
    local value
    value="$(ep_get "$1" DOCS_SOURCE generated)"
    [[ "$value" == template ]] && value=generated
    printf '%s\n' "$value"
}
pages_docs_source() { ep_version_get "$1" "$2" DOCS_SOURCE generated; }
pages_openapi_default() {
    local type
    type="$(ep_get "$1" TYPE)"
    endpoint_source_type "$type"
    "type_${type}_openapi_default"
}
pages_openapi_source() { ep_version_get "$1" "$2" OPENAPI_SOURCE "$(pages_openapi_default "$1")"; }
pages_favicon_source() { ep_get "$1" FAVICON_SOURCE default; }
pages_logo_source() { ep_get "$1" LOGO_SOURCE default; }

# --- icons: the favicon and the logo ---------------------------------------------
# System level (Settings > Icons): default is the repository's icon, custom a
# file the operator supplied (/etc/getbible/favicon.ico, /etc/getbible/logo.EXT
# named by LOGO_FILE), none switches it off. A domain follows the system
# (default), brings its own (custom) or serves none.
favicon_system_source() { gb_global FAVICON_SOURCE default; }
logo_system_source() { gb_global LOGO_SOURCE default; }

# The file the system favicon is published from, or nothing.
favicon_system_file() {
    case "$(favicon_system_source)" in
        default) printf '%s/%s\n' "$GB_IMG" "$GB_ICON_FAVICON" ;;
        custom) [[ -f "$GB_FAVICON_FILE" ]] && printf '%s\n' "$GB_FAVICON_FILE" ;;
    esac
    return 0
}
favicon_system_mime() {
    if [[ "$(favicon_system_source)" == custom ]]; then gb_global FAVICON_MIME; else pages_mime_for "$GB_ICON_FAVICON"; fi
}

# The file the system logo is published from, or nothing.
logo_system_file() {
    local name
    case "$(logo_system_source)" in
        default) printf '%s/%s\n' "$GB_IMG" "$GB_ICON_LOGO" ;;
        custom)
            name="$(gb_global LOGO_FILE)"
            [[ -n "$name" && -f "$GB_ETC/$name" ]] && printf '%s/%s\n' "$GB_ETC" "$name" ;;
    esac
    return 0
}

# Does the repository's icon apply to a domain (domain and system at default)?
pages_favicon_is_repository() { [[ "$(pages_favicon_source "$1")" == default && "$(favicon_system_source)" == default ]]; }
pages_logo_is_repository() { [[ "$(pages_logo_source "$1")" == default && "$(logo_system_source)" == default ]]; }

# pages_logo_name DOMAIN: the logo's file name under /img/, or nothing.
pages_logo_name() {
    local domain="$1"
    case "$(pages_logo_source "$domain")" in
        custom) ep_get "$domain" LOGO_FILE ;;
        default)
            case "$(logo_system_source)" in
                default) printf '%s\n' "$GB_ICON_LOGO" ;;
                custom) gb_global LOGO_FILE ;;
            esac ;;
    esac
    return 0
}
pages_img_present() { [[ -f "$(pages_img_dir "$1")/$2" ]]; }
pages_logo_active() { local name; name="$(pages_logo_name "$1")"; [[ -n "$name" ]] && pages_img_present "$1" "$name"; }
# Does the domain publish anything under /img/ (decides the nginx location)?
pages_img_active() { [[ -d "$(pages_img_dir "$1")" ]] && find "$(pages_img_dir "$1")" -mindepth 1 -maxdepth 1 -type f -print -quit | grep -q .; }

# pages_logo_ext FILE -> the extension a logo may have.
pages_logo_ext() {
    local ext="${1##*.}"
    ext="${ext,,}"
    case "$ext" in
        png|jpg|jpeg|svg|gif|webp) printf '%s\n' "$ext" ;;
        *) return 1 ;;
    esac
}

# pages_docs_location DOMAIN LABEL: the nginx root and file of an endpoint
# page, two lines, or nothing when the page answers 404.
pages_docs_location() {
    local domain="$1" label="$2"
    case "$(pages_docs_source "$domain" "$label")" in
        generated|custom)
            printf '%s\n' "$(ep_www_dir "$domain")"
            if pages_is_root "$label"; then printf '/index.html\n'; else printf '/%s/index.html\n' "$label"; fi ;;
        repository)
            printf '%s\n/%s/%s\n' "$(ep_data_dir "$domain")" "$label" "$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)" ;;
    esac
    return 0
}

pages_openapi_location() {
    local domain="$1" label="$2"
    case "$(pages_openapi_source "$domain" "$label")" in
        generated|custom)
            printf '%s\n' "$(ep_www_dir "$domain")"
            if pages_is_root "$label"; then printf '/openapi.json\n'; else printf '/%s/openapi.json\n' "$label"; fi ;;
        repository)
            printf '%s\n/%s/%s\n' "$(ep_data_dir "$domain")" "$label" "$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)" ;;
    esac
    return 0
}

# The page at /: the root endpoint's page when there are no version folders,
# otherwise the domain page.
pages_domain_docs_location() {
    local domain="$1"
    if pages_has_root_endpoint "$domain"; then
        # A runtime domain renders the location itself: a request for / with
        # a query string or a body belongs to its service, not to the page.
        [[ "$(ep_get "$domain" TYPE)" != runtime ]] || return 0
        pages_docs_location "$domain" "$GB_ROOT_LABEL"
        return 0
    fi
    case "$(pages_domain_docs_source "$domain")" in
        generated|custom) printf '%s\n/index.html\n' "$(ep_www_dir "$domain")" ;;
    esac
    return 0
}

# /openapi.json: the root endpoint's document, or for a runtime domain the
# default endpoint's (kept for clients that learnt the address before version
# folders existed). Static domains with version folders publish versions.json.
pages_domain_openapi_location() {
    local domain="$1" type default
    if pages_has_root_endpoint "$domain"; then
        pages_openapi_location "$domain" "$GB_ROOT_LABEL"
        return 0
    fi
    type="$(ep_get "$domain" TYPE)"
    [[ "$type" == runtime ]] || return 0
    endpoint_source_type runtime
    default="$(type_runtime_default_endpoint "$domain")"
    [[ -n "$default" ]] || return 0
    pages_openapi_location "$domain" "$default"
}

# Does the configured file exist right now (in the www directory, or in the
# published tree for a repository source)?
pages_file_present() {
    local domain="$1" label="$2" what="$3" source path
    if [[ "$what" == docs ]]; then source="$(pages_docs_source "$domain" "$label")"; else source="$(pages_openapi_source "$domain" "$label")"; fi
    case "$source" in
        generated|custom)
            if [[ "$what" == docs ]]; then [[ -f "$(pages_docs_file "$domain" "$label")" ]]; else [[ -f "$(pages_openapi_file "$domain" "$label")" ]]; fi ;;
        repository)
            if [[ "$what" == docs ]]; then path="$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)"; else path="$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)"; fi
            [[ -f "$(ep_version_path "$domain" "$label")/$path" ]] ;;
        *) return 1 ;;
    esac
}

pages_source_text() {
    # pages_source_text DOMAIN LABEL docs|openapi -> "source (detail)"
    local domain="$1" label="$2" what="$3" source path state
    if [[ "$what" == docs ]]; then source="$(pages_docs_source "$domain" "$label")"; else source="$(pages_openapi_source "$domain" "$label")"; fi
    case "$source" in
        none) printf 'none (answers 404)\n'; return 0 ;;
        generated) state="written by the tool" ;;
        custom) state="maintained by you" ;;
        repository)
            if [[ "$what" == docs ]]; then path="$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)"; else path="$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)"; fi
            state="from the repository: $path" ;;
    esac
    if pages_file_present "$domain" "$label" "$what"; then state="$state, present"; else state="$state, file missing"; fi
    printf '%s (%s)\n' "$source" "$state"
}

# --- publishing ----------------------------------------------------------------
pages_favicon_mime() {
    local domain="$1" mime=""
    if [[ "$(pages_favicon_source "$domain")" == custom ]]; then mime="$(ep_get "$domain" FAVICON_MIME)"; else mime="$(favicon_system_mime)"; fi
    printf '%s\n' "${mime:-image/vnd.microsoft.icon}"
}
pages_favicon_active() { [[ "$(pages_favicon_source "$1")" != none && -f "$(pages_favicon_file "$1")" ]]; }

pages_mime_for() {
    case "${1##*.}" in
        ico) printf 'image/vnd.microsoft.icon\n' ;;
        png) printf 'image/png\n' ;;
        svg) printf 'image/svg+xml\n' ;;
        gif) printf 'image/gif\n' ;;
        *) return 1 ;;
    esac
}

# Install SOURCE at TARGET when it differs, so an update that changes nothing
# rewrites nothing.
pages_install_image() {
    local source="$1" target="$2"
    if [[ ! -f "$target" ]] || ! cmp -s "$source" "$target"; then
        gb_install_file "$source" "$target" 0644 || return 1
    fi
}

pages_publish_favicon() {
    local domain="$1" target source
    target="$(pages_favicon_file "$domain")"
    case "$(pages_favicon_source "$domain")" in
        default)
            source="$(favicon_system_file)"
            if [[ -n "$source" ]]; then
                pages_install_image "$source" "$target" || return 1
            else
                [[ "$(favicon_system_source)" != custom ]] || gb_warn "The system favicon is a file of yours but $GB_FAVICON_FILE is missing; $domain serves none."
                [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$target"
            fi ;;
        custom) [[ -f "$target" ]] || gb_warn "$domain uses its own favicon but $target is missing." ;;
        none) [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$target" ;;
    esac
}

# The images under /img/: the icons that go with the repository favicon, the
# logo, and the icons that go with the repository logo. Anything else in the
# directory is a leftover of an earlier choice and is removed.
pages_publish_icons() {
    local domain="$1" dir name source file keep=" "
    dir="$(pages_img_dir "$domain")"
    if pages_favicon_is_repository "$domain"; then
        for name in "${GB_ICONS_WITH_FAVICON[@]}"; do
            pages_install_image "$GB_IMG/$name" "$dir/$name" || return 1
            keep="$keep$name "
        done
    fi
    case "$(pages_logo_source "$domain")" in
        custom)
            name="$(ep_get "$domain" LOGO_FILE)"
            if [[ -n "$name" && -f "$dir/$name" ]]; then
                keep="$keep$name "
            else
                gb_warn "$domain uses its own logo but $dir/${name:-logo} is missing; its pages show none."
            fi ;;
        default)
            source="$(logo_system_file)"
            if [[ -n "$source" ]]; then
                name="$(basename -- "$source")"
                pages_install_image "$source" "$dir/$name" || return 1
                keep="$keep$name "
                if pages_logo_is_repository "$domain"; then
                    for name in "${GB_ICONS_WITH_LOGO[@]}"; do
                        pages_install_image "$GB_IMG/$name" "$dir/$name" || return 1
                        keep="$keep$name "
                    done
                fi
            elif [[ "$(logo_system_source)" == custom ]]; then
                gb_warn "The system logo is a file of yours but it is missing under $GB_ETC; the pages of $domain show none."
            fi ;;
    esac
    [[ -d "$dir" && "$GB_DRY_RUN" != true ]] || return 0
    for file in "$dir"/*; do
        [[ -e "$file" || -L "$file" ]] || continue
        name="$(basename -- "$file")"
        [[ "$keep" == *" $name "* ]] || rm -rf -- "$file"
    done
    rmdir -- "$dir" 2>/dev/null || true
    return 0
}

# Every domain publishes discovery, including one endpoint served at its root.
pages_versions_active() { [[ -n "$(pages_endpoints "$1")" ]]; }

# The endpoints versions.json lists: those whose OpenAPI document is
# configured and present right now.
pages_versions_listed() {
    local domain="$1" label
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
        [[ "$(pages_openapi_source "$domain" "$label")" != none ]] || continue
        pages_file_present "$domain" "$label" openapi || continue
        printf '%s\n' "$label"
    done < <(pages_endpoints "$domain")
    return 0
}

# versions.json maps every listed endpoint to its OpenAPI document. It exists
# for every domain, empty when no endpoint has a document yet. No content
# validation is needed: configured repositories and operator files are trusted.
pages_publish_versions() {
    local domain="$1" target stage label version type
    target="$(pages_versions_file "$domain")"
    if ! pages_versions_active "$domain"; then
        [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$target"
        return 0
    fi
    stage="$(gb_tmpdir)/versions-$(gb_slug "$domain").json"
    type="$(ep_get "$domain" TYPE)"
    {
        while read -r label; do
            [[ -n "$label" ]] || continue
            version="$label"
            if pages_is_root "$label" && [[ "$type" == runtime ]]; then
                version="$(ep_version_get "$domain" "$label" APP_VERSION "$label")"
            fi
            printf '%s\t%s\n' "$label" "$version"
        done < <(pages_versions_listed "$domain")
    } | "$GB_PYTHON" -c '
import json, sys
domain = sys.argv[1]
endpoints = []
for line in sys.stdin:
    label, version = line.rstrip("\n").split("\t", 1)
    prefix = "/" if label == "root" else f"/{label}/"
    endpoints.append({"version": version, "url": f"https://{domain}{prefix}",
                      "openapi": f"https://{domain}{prefix}openapi.json"})
json.dump({"domain": domain, "endpoints": endpoints}, sys.stdout, indent=2)
print()' "$domain" > "$stage" || return 1
    gb_install_file "$stage" "$target" 0644
}

# pages_publish DOMAIN: write every generated file, check every custom one,
# and refresh the favicon and versions.json. Called by the endpoint pipeline
# before nginx is rendered.
pages_publish() {
    local domain="$1" type label dir out source path
    ep_load "$domain"
    type="$EP_TYPE"
    endpoint_source_type "$type"
    gb_ensure_dir "$(ep_www_dir "$domain")" 0755 || return 1
    pages_publish_favicon "$domain" || return 1
    pages_publish_icons "$domain" || return 1
    while read -r label; do
        [[ -n "$label" ]] || continue
        dir="$(pages_endpoint_dir "$domain" "$label")"
        gb_ensure_dir "$dir" 0755 || return 1
        source="$(pages_docs_source "$domain" "$label")"
        case "$source" in
            generated)
                out="$(gb_tmpdir)/page-$EP_SLUG-$label.html"
                "type_${type}_render_endpoint_docs" "$domain" "$label" "$out" || return 1
                gb_install_file "$out" "$dir/index.html" 0644 || return 1 ;;
            custom)
                [[ -f "$dir/index.html" ]] || gb_warn "The page for $domain$(pages_prefix "$label") is maintained by you but $dir/index.html is missing; it answers 404 until you provide it." ;;
            repository)
                path="$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)"
                [[ -f "$(ep_version_path "$domain" "$label")/$path" ]] || gb_log "The page for $domain$(pages_prefix "$label") comes from the repository ($path) and is not in the published tree yet; it arrives with the next sync." ;;
        esac
        source="$(pages_openapi_source "$domain" "$label")"
        case "$source" in
            generated)
                out="$(gb_tmpdir)/openapi-$EP_SLUG-$label.json"
                "type_${type}_render_openapi" "$domain" "$label" "$out" || return 1
                gb_install_file "$out" "$dir/openapi.json" 0644 || return 1 ;;
            custom)
                [[ -f "$dir/openapi.json" ]] || gb_warn "The OpenAPI document for $domain$(pages_prefix "$label") is maintained by you but $dir/openapi.json is missing." ;;
            repository)
                path="$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)"
                [[ -f "$(ep_version_path "$domain" "$label")/$path" ]] || gb_log "No OpenAPI document for $domain$(pages_prefix "$label") in the published tree ($path); it is linked once the repository ships one." ;;
        esac
    done < <(pages_endpoints "$domain")
    if ! pages_has_root_endpoint "$domain"; then
        case "$(pages_domain_docs_source "$domain")" in
            generated)
                out="$(gb_tmpdir)/index.$EP_SLUG.html"
                "type_${type}_render_docs" "$out" || return 1
                gb_install_file "$out" "$(ep_www_dir "$domain")/index.html" 0644 || return 1 ;;
            custom)
                [[ -f "$(ep_www_dir "$domain")/index.html" ]] || gb_warn "The domain page of $domain is maintained by you but $(ep_www_dir "$domain")/index.html is missing." ;;
        esac
        # A document once generated at the domain level now lives with its endpoint.
        [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$(ep_www_dir "$domain")/openapi.json"
    fi
    pages_publish_versions "$domain"
}

# --- changing sources ----------------------------------------------------------
# The page at / of a root-endpoint domain is the endpoint's own page: "domain"
# means that endpoint there, so a take-over lands in the record that publishing
# reads.
pages_resolve_label() {
    local domain="$1" label="$2"
    if [[ "$label" == domain ]] && pages_has_root_endpoint "$domain"; then printf '%s\n' "$GB_ROOT_LABEL"; else printf '%s\n' "$label"; fi
}

# pages_set_docs DOMAIN LABEL|domain SOURCE [REPO_PATH]
pages_set_docs() {
    local domain="$1" label="$2" source="$3" path="${4:-}"
    pages_valid_source "$source" || gb_die "Page sources: generated, custom, repository, none"
    label="$(pages_resolve_label "$domain" "$label")"
    if [[ "$label" == domain ]]; then
        [[ "$source" == generated || "$source" == custom ]] || gb_die "The domain page is generated or custom; repository and none apply to endpoint pages."
        ep_set "$domain" DOCS_SOURCE "$source"
        return 0
    fi
    pages_endpoint_exists "$domain" "$label" || gb_die "$domain has no endpoint $label"
    if [[ "$source" == repository ]]; then
        [[ "$(ep_get "$domain" TYPE)" == static ]] || gb_die "Only static endpoints can serve a page from their repository."
        path="${path:-$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)}"
        pages_valid_repo_path "$path" || gb_die "Invalid repository path: $path"
        ep_version_set "$domain" "$label" DOCS_REPO_PATH "$path"
    fi
    ep_version_set "$domain" "$label" DOCS_SOURCE "$source"
}

# pages_set_openapi DOMAIN LABEL SOURCE [REPO_PATH]
pages_set_openapi() {
    local domain="$1" label="$2" source="$3" path="${4:-}" type
    pages_valid_source "$source" || gb_die "OpenAPI sources: generated, repository, custom, none"
    pages_endpoint_exists "$domain" "$label" || gb_die "$domain has no endpoint $label"
    type="$(ep_get "$domain" TYPE)"
    [[ "$source" != generated || "$type" == runtime ]] || gb_die "Only runtime endpoints generate their OpenAPI document; static ones take it from the repository or from you."
    [[ "$source" != repository || "$type" == static ]] || gb_die "Only static endpoints can serve an OpenAPI document from their repository."
    if [[ "$source" == repository ]]; then
        path="${path:-$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)}"
        pages_valid_repo_path "$path" || gb_die "Invalid repository path: $path"
        ep_version_set "$domain" "$label" OPENAPI_REPO_PATH "$path"
    fi
    ep_version_set "$domain" "$label" OPENAPI_SOURCE "$source"
}

# pages_take_over DOMAIN LABEL|domain docs|openapi [FILE]: make the file yours,
# copying FILE over it when given (or, when nothing exists yet, starting from
# the generated version so you edit a complete page rather than a blank one).
pages_take_over() {
    local domain="$1" label="$2" what="$3" from="${4:-}" target out type
    type="$(ep_get "$domain" TYPE)"
    endpoint_source_type "$type"
    label="$(pages_resolve_label "$domain" "$label")"
    if [[ "$label" == domain ]]; then
        [[ "$what" == docs ]] || gb_die "The domain level has no OpenAPI document of its own; choose an endpoint."
        target="$(ep_www_dir "$domain")/index.html"
    else
        pages_endpoint_exists "$domain" "$label" || gb_die "$domain has no endpoint $label"
        if [[ "$what" == docs ]]; then target="$(pages_docs_file "$domain" "$label")"; else target="$(pages_openapi_file "$domain" "$label")"; fi
    fi
    gb_ensure_dir "$(dirname -- "$target")" 0755 || return 1
    if [[ -n "$from" ]]; then
        [[ -f "$from" ]] || gb_die "No such file: $from"
        if [[ "$what" == openapi ]]; then
            "$GB_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$from" || gb_die "$from is not valid JSON."
        fi
        gb_install_file "$from" "$target" 0644 || return 1
    elif [[ ! -f "$target" ]]; then
        out="$(gb_tmpdir)/takeover-$(gb_slug "$domain")"
        ep_load "$domain"
        if [[ "$label" == domain ]]; then
            "type_${type}_render_docs" "$out" 2>/dev/null || : > "$out"
        elif [[ "$what" == docs ]]; then
            "type_${type}_render_endpoint_docs" "$domain" "$label" "$out" 2>/dev/null || : > "$out"
        else
            "type_${type}_render_openapi" "$domain" "$label" "$out" 2>/dev/null || printf '{"openapi": "3.1.0", "info": {"title": "%s", "version": "%s"}, "paths": {}}\n' "$domain" "$label" > "$out"
        fi
        gb_install_file "$out" "$target" 0644 || return 1
    fi
    if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" custom; else pages_set_openapi "$domain" "$label" custom; fi
    printf '%s\n' "$target"
}

# Open a file in the operator's editor. Dialogs are closed at this point; the
# editor takes the terminal. Not available without a terminal.
pages_edit_file() {
    local file="$1" editor
    editor="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$editor" ]]; then
        # shellcheck disable=SC2209 # editor names, not command output
        if gb_have nano; then editor=nano; elif gb_have vi; then editor=vi; else gb_warn "No editor found; copy a file instead."; return 1; fi
    fi
    [[ -t 0 ]] || { gb_warn "No terminal for an editor; copy a file with 'from FILE' instead."; return 1; }
    "$editor" "$file"
}

# pages_set_favicon DOMAIN default|none|FILE
pages_set_favicon() {
    local domain="$1" choice="$2" mime
    case "$choice" in
        default|none) ep_set "$domain" FAVICON_SOURCE "$choice" ;;
        *)
            [[ -f "$choice" ]] || gb_die "No such file: $choice"
            mime="$(pages_mime_for "$choice")" || gb_die "$GB_FAVICON_TYPES_TEXT"
            gb_ensure_dir "$(ep_www_dir "$domain")" 0755 || return 1
            gb_install_file "$choice" "$(pages_favicon_file "$domain")" 0644 || return 1
            ep_set "$domain" FAVICON_SOURCE custom
            ep_set "$domain" FAVICON_MIME "$mime" ;;
    esac
}

# pages_set_logo DOMAIN default|none|FILE: the logo this domain's pages show
# at the top (and, scaled down, at the foot). A file of yours is kept as
# /img/logo.EXT under the domain's directory.
pages_set_logo() {
    local domain="$1" choice="$2" ext
    case "$choice" in
        default|none)
            ep_set "$domain" LOGO_SOURCE "$choice"
            ep_set "$domain" LOGO_FILE "" ;;
        *)
            [[ -f "$choice" ]] || gb_die "No such file: $choice"
            ext="$(pages_logo_ext "$choice")" || gb_die "$GB_LOGO_TYPES_TEXT"
            gb_ensure_dir "$(pages_img_dir "$domain")" 0755 || return 1
            gb_install_file "$choice" "$(pages_img_dir "$domain")/logo.$ext" 0644 || return 1
            ep_set "$domain" LOGO_SOURCE custom
            ep_set "$domain" LOGO_FILE "logo.$ext" ;;
    esac
}

# The system favicon, used by every domain that has none of its own: the
# repository's icon (default), a file of yours, or none.
favicon_set_system() {
    local file="$1" mime
    case "$file" in
        default|none)
            [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$GB_FAVICON_FILE"
            gb_global_set FAVICON_SOURCE "$file"
            gb_global_set FAVICON_MIME ""
            if [[ "$file" == none ]]; then
                gb_log "System favicon switched off; domains without their own serve none."
            else
                gb_log "System favicon: the repository's img/$GB_ICON_FAVICON; Update all domains publishes it."
            fi
            return 0 ;;
    esac
    [[ -f "$file" ]] || gb_die "No such file: $file"
    mime="$(pages_mime_for "$file")" || gb_die "$GB_FAVICON_TYPES_TEXT"
    gb_install_file "$file" "$GB_FAVICON_FILE" 0644 || return 1
    gb_global_set FAVICON_SOURCE custom
    gb_global_set FAVICON_MIME "$mime"
    gb_log "System favicon set ($mime); Update all domains publishes it."
}

# The system logo, shown by the pages of every domain that has none of its
# own: the repository's (default), a file of yours kept as
# /etc/getbible/logo.EXT, or none.
logo_set_system() {
    local file="$1" ext
    case "$file" in
        default|none)
            [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$GB_LOGO_PREFIX".*
            gb_global_set LOGO_SOURCE "$file"
            gb_global_set LOGO_FILE ""
            if [[ "$file" == none ]]; then
                gb_log "System logo switched off; pages of domains without their own show no images."
            else
                gb_log "System logo: the repository's img/$GB_ICON_LOGO; Update all domains publishes it."
            fi
            return 0 ;;
    esac
    [[ -f "$file" ]] || gb_die "No such file: $file"
    ext="$(pages_logo_ext "$file")" || gb_die "$GB_LOGO_TYPES_TEXT"
    [[ "$GB_DRY_RUN" == true ]] || rm -f -- "$GB_LOGO_PREFIX".*
    gb_install_file "$file" "$GB_LOGO_PREFIX.$ext" 0644 || return 1
    gb_global_set LOGO_SOURCE custom
    gb_global_set LOGO_FILE "logo.$ext"
    gb_log "System logo set (logo.$ext); Update all domains publishes it."
}

favicon_status_text() {
    case "$(favicon_system_source)" in
        none) printf 'System favicon: none (switched off)\n' ;;
        custom)
            if [[ -f "$GB_FAVICON_FILE" ]]; then
                printf 'System favicon: %s (%s, %s bytes)\n' "$GB_FAVICON_FILE" "$(gb_global FAVICON_MIME)" "$(stat -c %s "$GB_FAVICON_FILE")"
            else
                printf 'System favicon: %s (missing)\n' "$GB_FAVICON_FILE"
            fi ;;
        *) printf 'System favicon: the repository icon img/%s\n' "$GB_ICON_FAVICON" ;;
    esac
}

logo_status_text() {
    local name
    case "$(logo_system_source)" in
        none) printf 'System logo: none (switched off)\n' ;;
        custom)
            name="$(gb_global LOGO_FILE)"
            if [[ -n "$name" && -f "$GB_ETC/$name" ]]; then
                printf 'System logo: %s/%s (%s bytes)\n' "$GB_ETC" "$name" "$(stat -c %s "$GB_ETC/$name")"
            else
                printf 'System logo: %s/%s (missing)\n' "$GB_ETC" "${name:-logo.*}"
            fi ;;
        *) printf 'System logo: the repository icons img/%s, img/%s, img/%s\n' "$GB_ICON_LOGO" "$GB_ICON_FAVICON" "$GB_ICON_SOCIAL" ;;
    esac
}

icons_status_text() {
    favicon_status_text
    logo_status_text
}

# --- reporting -----------------------------------------------------------------
pages_status_text() {
    local domain="$1" label listed
    printf 'Pages of %s\n\n' "$domain"
    if pages_has_root_endpoint "$domain"; then
        printf '  %-28s %s\n' "Page /" "$(pages_source_text "$domain" "$GB_ROOT_LABEL" docs)"
        printf '  %-28s %s\n' "OpenAPI /openapi.json" "$(pages_source_text "$domain" "$GB_ROOT_LABEL" openapi)"
    else
        printf '  %-28s %s\n' "Domain page /" "$(pages_domain_docs_source "$domain") ($([[ -f "$(ep_www_dir "$domain")/index.html" ]] && printf present || printf 'file missing'))"
        while read -r label; do
            [[ -n "$label" ]] || continue
            printf '  %-28s %s\n' "Page /$label/" "$(pages_source_text "$domain" "$label" docs)"
            printf '  %-28s %s\n' "OpenAPI /$label/openapi.json" "$(pages_source_text "$domain" "$label" openapi)"
        done < <(pages_endpoints "$domain")
        listed="$(pages_versions_listed "$domain" | tr '\n' ' ')"
        printf '  %-28s %s\n' "versions.json" "generated, lists: ${listed:-nothing yet (no endpoint has an OpenAPI document)}"
    fi
    case "$(pages_favicon_source "$domain")" in
        default) printf '  %-28s %s\n' "Favicon /favicon.ico" "system default ($(favicon_status_text | sed 's/^System favicon: //'))" ;;
        custom) printf '  %-28s %s\n' "Favicon /favicon.ico" "this domain's own ($(ep_get "$domain" FAVICON_MIME))" ;;
        none) printf '  %-28s %s\n' "Favicon /favicon.ico" "none" ;;
    esac
    case "$(pages_logo_source "$domain")" in
        default) printf '  %-28s %s\n' "Logo on the pages" "system default ($(logo_status_text | sed 's/^System logo: //'))" ;;
        custom) printf '  %-28s %s\n' "Logo on the pages" "this domain's own (/img/$(ep_get "$domain" LOGO_FILE))" ;;
        none) printf '  %-28s %s\n' "Logo on the pages" "none" ;;
    esac
    printf '\nFiles you maintain live under %s; repository files come from the published tree.\n' "$(ep_www_dir "$domain")"
}

# --- menu ------------------------------------------------------------------------
pages_menu() {
    local domain="$1" choice label out
    while true; do
        local -a items=()
        if pages_has_root_endpoint "$domain"; then
            items+=("docs:$GB_ROOT_LABEL" "Page at /: $(pages_source_text "$domain" "$GB_ROOT_LABEL" docs)")
            items+=("openapi:$GB_ROOT_LABEL" "OpenAPI /openapi.json: $(pages_source_text "$domain" "$GB_ROOT_LABEL" openapi)")
        else
            items+=("docs:domain" "Domain page /: $(pages_domain_docs_source "$domain")")
            while read -r label; do
                [[ -n "$label" ]] || continue
                items+=("docs:$label" "Page /$label/: $(pages_source_text "$domain" "$label" docs)")
                items+=("openapi:$label" "OpenAPI /$label/openapi.json: $(pages_source_text "$domain" "$label" openapi)")
            done < <(pages_endpoints "$domain")
        fi
        items+=(favicon "Favicon: $(pages_favicon_source "$domain")")
        items+=(logo "Logo on the pages: $(pages_logo_source "$domain")")
        choice="$(ui_menu "Pages and OpenAPI: $domain" "Generated files are rewritten on every apply; a file you take over is yours until you hand it back. Choose an item." \
            "${items[@]}" show "Show all sources and files" back "Back")" || return 0
        case "$choice" in
            back) return 0 ;;
            show)
                out="$(gb_tmpdir)/pages.$$"
                pages_status_text "$domain" > "$out" 2>&1 || true
                ui_textbox "Pages: $domain" "$out" ;;
            favicon) pages_menu_favicon "$domain" ;;
            logo) pages_menu_logo "$domain" ;;
            docs:*) pages_menu_item "$domain" "${choice#docs:}" docs ;;
            openapi:*) pages_menu_item "$domain" "${choice#openapi:}" openapi ;;
        esac
    done
}

pages_menu_item() {
    local domain="$1" label="$2" what="$3" choice type path file target
    type="$(ep_get "$domain" TYPE)"
    local -a actions=()
    if [[ "$what" == docs ]]; then
        actions=(generated "Let the tool write and maintain this page" edit "Open it in an editor; from then on it is yours" file "Copy a file from this server over it; from then on it is yours")
        [[ "$label" == domain || "$type" != static ]] || actions+=(repository "Serve the page the repository ships (follows every sync)")
        [[ "$label" == domain ]] || actions+=(none "Serve nothing here (404)")
    else
        actions=()
        [[ "$type" != runtime ]] || actions+=(generated "Let the tool generate and maintain the document")
        [[ "$type" != static ]] || actions+=(repository "Serve the document the repository ships (follows every sync)")
        actions+=(edit "Open it in an editor; from then on it is yours" file "Copy a JSON file from this server over it; from then on it is yours" none "Serve nothing here (404)")
    fi
    choice="$(ui_menu "$([[ "$what" == docs ]] && printf 'Page' || printf 'OpenAPI'): $domain $([[ "$label" == domain ]] && printf '/' || pages_prefix "$label")" \
        "Now: $([[ "$label" == domain ]] && pages_domain_docs_source "$domain" || pages_source_text "$domain" "$label" "$what")" \
        "${actions[@]}" back "Back")" || return 0
    case "$choice" in
        back) return 0 ;;
        generated)
            if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" generated; else pages_set_openapi "$domain" "$label" generated; fi ;;
        none)
            if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" none; else pages_set_openapi "$domain" "$label" none; fi ;;
        repository)
            if [[ "$what" == docs ]]; then path="$(ep_version_get "$domain" "$label" DOCS_REPO_PATH index.html)"; else path="$(ep_version_get "$domain" "$label" OPENAPI_REPO_PATH openapi.json)"; fi
            path="$(ui_input "Repository file" "Path of the file inside the version's folder of the repository (exported by every sync even when its type is not otherwise served)" "$path")" || return 0
            pages_valid_repo_path "$path" || { ui_msg "Invalid" "Repository paths are relative, without leading dots or '..'."; return 0; }
            if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" repository "$path"; else pages_set_openapi "$domain" "$label" repository "$path"; fi ;;
        file)
            file="$(ui_input "Copy a file" "Path of the file on this server to copy (it becomes yours to maintain)" "")" || return 0
            [[ -f "$file" ]] || { ui_msg "Invalid" "No such file: $file"; return 0; }
            target="$(pages_take_over "$domain" "$label" "$what" "$file")" || return 0
            ui_msg "Copied" "Copied to $target. This file is now maintained by you and is never rewritten by the tool." ;;
        edit)
            target="$(pages_take_over "$domain" "$label" "$what")" || return 0
            if ! pages_edit_file "$target"; then
                ui_msg "Editor" "The editor could not be opened. The file is at $target; edit it there or copy a file over it."
            fi ;;
    esac
    endpoint_confirm_hand_edits "$domain" || return 0
    ui_run "Apply $domain" endpoint_apply "$domain" || true
    GB_OVERWRITE_HAND_EDITS=false
}

pages_menu_favicon() {
    local domain="$1" choice file
    choice="$(ui_menu "Favicon: $domain" "Now: $(pages_favicon_source "$domain").\n$(favicon_status_text) (Settings > Icons changes it for every domain)." \
        default "Use the system favicon" file "Use a file from this server for this domain only" none "Serve no favicon" back "Back")" || return 0
    case "$choice" in
        back) return 0 ;;
        default|none) pages_set_favicon "$domain" "$choice" ;;
        file)
            file="$(ui_input "Favicon" "Path of an .ico, .png, .svg or .gif file on this server" "")" || return 0
            pages_set_favicon "$domain" "$file" || return 0 ;;
    esac
    endpoint_confirm_hand_edits "$domain" || return 0
    ui_run "Apply $domain" endpoint_apply "$domain" || true
    GB_OVERWRITE_HAND_EDITS=false
}

pages_menu_logo() {
    local domain="$1" choice file
    choice="$(ui_menu "Logo: $domain" "The image at the top of this domain's generated pages (and, scaled down, at the foot). Now: $(pages_logo_source "$domain").\n$(logo_status_text) (Settings > Icons changes it for every domain)." \
        default "Use the system logo" file "Use a file from this server for this domain only" none "Show no images on the pages" back "Back")" || return 0
    case "$choice" in
        back) return 0 ;;
        default|none) pages_set_logo "$domain" "$choice" ;;
        file)
            file="$(ui_input "Logo" "Path of a .png, .jpg, .svg, .gif or .webp file on this server" "")" || return 0
            pages_set_logo "$domain" "$file" || return 0 ;;
    esac
    endpoint_confirm_hand_edits "$domain" || return 0
    ui_run "Apply $domain" endpoint_apply "$domain" || true
    GB_OVERWRITE_HAND_EDITS=false
}

# --- command line ------------------------------------------------------------------
pages_cli() {
    local domain="${1:-}" what="${2:-show}"
    [[ -n "$domain" ]] || gb_die "pages DOMAIN [show | publish | docs [ENDPOINT] ACTION | openapi ENDPOINT ACTION | favicon default|none|FILE | logo default|none|FILE]"
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    shift
    [[ $# -eq 0 ]] || shift
    [[ "$what" == show || "$what" == publish ]] || endpoint_source_type "$(ep_get "$domain" TYPE)"
    case "$what" in
        show) pages_status_text "$domain" ;;
        publish) pages_publish "$domain" ;;
        docs)
            local label=domain
            if [[ -n "${1:-}" ]] && gb_valid_endpoint_label "$1"; then label="$1"; shift; fi
            pages_cli_change "$domain" "$label" docs "$@" ;;
        openapi)
            [[ -n "${1:-}" ]] && gb_valid_endpoint_label "$1" || gb_die "pages DOMAIN openapi ENDPOINT generated|repository [PATH]|custom|none|edit|from FILE"
            local label="$1"; shift
            pages_cli_change "$domain" "$label" openapi "$@" ;;
        favicon)
            [[ -n "${1:-}" ]] || gb_die "pages DOMAIN favicon default|none|FILE"
            pages_set_favicon "$domain" "$1" && endpoint_apply "$domain" ;;
        logo)
            [[ -n "${1:-}" ]] || gb_die "pages DOMAIN logo default|none|FILE"
            pages_set_logo "$domain" "$1" && endpoint_apply "$domain" ;;
        *) gb_die "pages DOMAIN [show | publish | docs [ENDPOINT] ACTION | openapi ENDPOINT ACTION | favicon default|none|FILE | logo default|none|FILE]" ;;
    esac
}

pages_cli_change() {
    local domain="$1" label="$2" what="$3" action="${4:-}" arg="${5:-}" target
    case "$action" in
        generated|none) if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" "$action"; else pages_set_openapi "$domain" "$label" "$action"; fi ;;
        repository) if [[ "$what" == docs ]]; then pages_set_docs "$domain" "$label" repository "$arg"; else pages_set_openapi "$domain" "$label" repository "$arg"; fi ;;
        custom)
            target="$(pages_take_over "$domain" "$label" "$what")" || return 1
            gb_log "Maintained by you from now on: $target" ;;
        from)
            [[ -n "$arg" ]] || gb_die "from needs a file"
            target="$(pages_take_over "$domain" "$label" "$what" "$arg")" || return 1
            gb_log "Copied to $target; maintained by you from now on." ;;
        edit)
            target="$(pages_take_over "$domain" "$label" "$what")" || return 1
            pages_edit_file "$target" || return 1 ;;
        *) gb_die "Actions: generated, custom, none, edit, from FILE, repository [PATH]" ;;
    esac
    endpoint_apply "$domain"
}
