#!/usr/bin/env bash
# Documentation pages: shared pieces used by the type modules when they render
# a domain page or an endpoint page (publishing itself lives in pages.sh).

[[ -n "${GB_DOCS_LOADED:-}" ]] && return 0
GB_DOCS_LOADED=1

docs_access_label() {
    case "$1" in
        open) printf 'open access\n' ;;
        metered) printf 'public, metered · tokens unlimited\n' ;;
        token) printf 'token required\n' ;;
    esac
}

# docs_render_access OUTPUT PREFIX EXAMPLE: the access section for the loaded
# EP_* domain; PREFIX is the endpoint's path (/v2/, or / for a root endpoint).
docs_render_access() {
    local output="$1" prefix="$2" example="$3"
    case "$EP_ACCESS_MODE" in
        metered)
            gb_render "$GB_DOCS_SRC/access-metered.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
                "RATE_PER_SECOND=$EP_RATE_PER_SECOND" "RATE_BURST=$EP_RATE_BURST" \
                "QUOTA_HOUR=$EP_QUOTA_HOUR" "QUOTA_DAY=$EP_QUOTA_DAY" "CONN_LIMIT=$EP_CONN_LIMIT" \
                "PREFIX=$prefix" "EXAMPLE_PATH=$example"
            ;;
        token)
            gb_render "$GB_DOCS_SRC/access-token.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
                "PREFIX=$prefix" "EXAMPLE_PATH=$example"
            ;;
        *)
            cp "$GB_DOCS_SRC/access-open.html" "$output"
            ;;
    esac
}

# --- the icons on a page (pages.sh decides which apply) --------------------------
# docs_icon_sizes NAME: "96x96" for icon-96.png (the repository's icons are
# named after their size).
docs_icon_sizes() {
    local size="${1#icon-}"
    size="${size%%.*}"
    printf '%sx%s\n' "$size" "$size"
}

# docs_head_icons DOMAIN: the <link> and <meta> lines of a page's head: the
# favicon (with the touch icon and the large icon when it is the repository's)
# and the link-preview image. Empty for a domain that serves none.
docs_head_icons() {
    local domain="$1" name
    if pages_favicon_active "$domain"; then
        if pages_favicon_is_repository "$domain"; then
            printf '<link rel="icon" type="%s" sizes="%s" href="/favicon.ico">\n' "$(pages_favicon_mime "$domain")" "$(docs_icon_sizes "$GB_ICON_FAVICON")"
            if pages_img_present "$domain" "$GB_ICON_LARGE"; then
                printf '<link rel="icon" type="image/png" sizes="%s" href="/img/%s">\n' "$(docs_icon_sizes "$GB_ICON_LARGE")" "$GB_ICON_LARGE"
            fi
            if pages_img_present "$domain" "$GB_ICON_TOUCH"; then
                printf '<link rel="apple-touch-icon" sizes="%s" href="/img/%s">\n' "$(docs_icon_sizes "$GB_ICON_TOUCH")" "$GB_ICON_TOUCH"
            fi
        else
            printf '<link rel="icon" href="/favicon.ico">\n'
        fi
    fi
    if pages_logo_is_repository "$domain"; then
        if pages_img_present "$domain" "$GB_ICON_SOCIAL"; then
            printf '<meta property="og:image" content="https://%s/img/%s">\n' "$domain" "$GB_ICON_SOCIAL"
        fi
    elif pages_logo_active "$domain"; then
        name="$(pages_logo_name "$domain")"
        case "$name" in
            *.png|*.jpg|*.jpeg|*.gif|*.webp) printf '<meta property="og:image" content="https://%s/img/%s">\n' "$domain" "$name" ;;
        esac
    fi
    return 0
}

# docs_logo_url DOMAIN: the image at the top of a page; docs_icon_url DOMAIN:
# the one at its foot (the repository's small icon, or the domain's own logo
# scaled down). Both empty when the domain shows none.
docs_logo_url() {
    if pages_logo_active "$1"; then printf '/img/%s\n' "$(pages_logo_name "$1")"; fi
    return 0
}
docs_icon_url() {
    if pages_logo_is_repository "$1"; then
        if pages_img_present "$1" "$GB_ICON_FAVICON"; then printf '/img/%s\n' "$GB_ICON_FAVICON"; fi
    else
        docs_logo_url "$1"
    fi
    return 0
}

# docs_render DOMAIN: publish every page of a domain (see pages.sh).
docs_render() { pages_publish "$@"; }

# Static domain page: one row per endpoint with its page and OpenAPI document
# as configured (generated, yours, or from the repository).
docs_versions_rows() {
    local domain="$1" label page openapi
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
        page="no page"
        [[ "$(pages_docs_source "$domain" "$label")" == none ]] || page="<a href=\"/$label/\">/$label/</a>"
        openapi="no OpenAPI document"
        if [[ "$(pages_openapi_source "$domain" "$label")" != none ]] && pages_file_present "$domain" "$label" openapi; then
            openapi="<a href=\"/$label/openapi.json\">openapi.json</a>"
        fi
        printf '<tr><td><code>%s</code></td><td><code>https://%s/%s/</code></td><td>%s</td><td>%s</td></tr>\n' "$label" "$domain" "$label" "$page" "$openapi"
    done < <(ep_versions "$domain")
}
