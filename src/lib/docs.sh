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
