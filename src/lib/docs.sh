#!/usr/bin/env bash
# Documentation page (and OpenAPI document) served at every domain root.

[[ -n "${GB_DOCS_LOADED:-}" ]] && return 0
GB_DOCS_LOADED=1

docs_access_label() {
    case "$1" in
        open) printf 'open access\n' ;;
        metered) printf 'public, metered · tokens unlimited\n' ;;
        token) printf 'token required\n' ;;
    esac
}

# Render the access section for the loaded EP_* endpoint into a file.
docs_render_access() {
    local output="$1" first="$2" example="$3"
    case "$EP_ACCESS_MODE" in
        metered)
            gb_render "$GB_DOCS_SRC/access-metered.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
                "RATE_PER_SECOND=$EP_RATE_PER_SECOND" "RATE_BURST=$EP_RATE_BURST" \
                "QUOTA_HOUR=$EP_QUOTA_HOUR" "QUOTA_DAY=$EP_QUOTA_DAY" "CONN_LIMIT=$EP_CONN_LIMIT" \
                "FIRST_VERSION=$first" "EXAMPLE_PATH=$example"
            ;;
        token)
            gb_render "$GB_DOCS_SRC/access-token.html.tmpl" "$output" "DOMAIN=$EP_DOMAIN" \
                "FIRST_VERSION=$first" "EXAMPLE_PATH=$example"
            ;;
        *)
            cp "$GB_DOCS_SRC/access-open.html" "$output"
            ;;
    esac
}

# docs_render DOMAIN: write /var/www/getbible/<domain>/index.html (template
# source) or leave a custom page alone.
docs_render() {
    local domain="$1" www out
    ep_load "$domain"
    www="$(ep_www_dir "$domain")"
    gb_ensure_dir "$www" 0755
    if [[ "$EP_DOCS_SOURCE" == custom ]]; then
        [[ -f "$www/index.html" ]] || gb_warn "$domain uses a custom documentation page but $www/index.html is missing."
        return 0
    fi
    out="$(gb_tmpdir)/index.$EP_SLUG.html"
    "type_${EP_TYPE}_render_docs" "$out"
    gb_install_file "$out" "$www/index.html" 0644
}

docs_versions_rows() {
    # Static endpoints: one row per enabled version with an OpenAPI link when the tree has one.
    local domain="$1" label path openapi
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
        path="$(ep_version_path "$domain" "$label")"
        openapi="no OpenAPI document published"
        [[ -f "$path/openapi.json" ]] && openapi="<a href=\"/$label/openapi.json\">openapi.json</a>"
        printf '<tr><td><code>%s</code></td><td><code>https://%s/%s/</code></td><td>%s</td></tr>\n' "$label" "$domain" "$label" "$openapi"
    done < <(ep_versions "$domain")
}
