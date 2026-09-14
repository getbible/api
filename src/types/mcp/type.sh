#!/usr/bin/env bash
# A dedicated domain serves one MCP protocol endpoint at /, without versions.
[[ -n "${GB_TYPE_MCP_LOADED:-}" ]] && return 0
GB_TYPE_MCP_LOADED=1
# shellcheck source=../../lib/mcp.sh
source "$GB_LIB/mcp.sh"
# shellcheck source=../../lib/resources.sh
source "$GB_LIB/resources.sh"

# MCP discovers all upstream API versions through the protocol itself.
type_mcp_endpoints() { :; }
type_mcp_openapi_default() { printf 'none\n'; }
type_mcp_prepare() { resources_preflight "$1" && mcp_prepare "$1"; }
type_mcp_before_switch() { mcp_before_switch "$1"; }
type_mcp_before_abort() { mcp_before_abort "$1"; }
type_mcp_abort() { mcp_abort "$1"; }
type_mcp_finish() { mcp_commit "$1" && mcp_finish "$1"; }
type_mcp_remove() { mcp_remove "$@"; }
type_mcp_status() { mcp_status "$1"; }

type_mcp_render_locations() {
    TYPE_METHODS_REGEX='GET|HEAD|POST|OPTIONS'
    TYPE_REJECT_ARGS=false
    TYPE_MAX_BODY=1m
    TYPE_PROXY_CACHE=false
    # EP_DOMAIN is loaded by the shared domain pipeline before rendering.
    # shellcheck disable=SC2153
    mcp_render_location "$EP_DOMAIN" "$1"
}

type_mcp_create() {
    local domain="$1" mode="$2" python="$3" origin="$4" file="$5"
    gb_valid_domain "$domain" || { gb_warn "Invalid domain: $domain"; return 1; }
    ep_exists "$domain" && { gb_warn "Domain already exists: $domain"; return 1; }
    access_valid_mode "$mode" || { gb_warn "Invalid access mode: $mode"; return 1; }
    python="$(py_resolve_version "$python")" || return 1
    # Validate the complete configuration before creating any registry entry.
    mcp_validate_origin "$origin" || return 1
    mcp_validate_env_file "$file" || return 1
    ep_create "$domain" mcp mcp || return 1
    ep_set "$domain" ACCESS_MODE "$mode" || return 1
    ep_set "$domain" DOCS_SOURCE none || return 1
    ep_set "$domain" FAVICON_SOURCE none || return 1
    ep_set "$domain" LOGO_SOURCE none || return 1
    ep_set "$domain" CLOUDFLARE_CACHE bypass || return 1
    ep_set "$domain" MCP_PYTHON_VERSION "$python" || return 1
    ep_set "$domain" MCP_ORIGIN "$origin" || return 1
    ep_set "$domain" MCP_ENV_FILE "$file"
}

type_mcp_deploy_cli() {
    local domain="" mode="" python=auto origin="" file=""
    while (( $# )); do
        case "$1" in
            --staged) GB_DEPLOY_MODE=staged; shift ;;
            --live) GB_DEPLOY_MODE=live; shift ;;
            --domain|--access|--python|--origin|--env-file)
                [[ $# -ge 2 ]] || { gb_warn "Missing value for $1"; return 1; }
                case "$1" in
                    --domain) domain="$2" ;; --access) mode="$2" ;;
                    --python) python="$2" ;; --origin) origin="$2" ;; --env-file) file="$2" ;;
                esac
                shift 2 ;;
            *) gb_warn "Unknown option for deploy mcp: $1"; return 1 ;;
        esac
    done
    [[ -n "$domain" ]] || { gb_warn 'deploy mcp requires --domain'; return 1; }
    mode="${mode:-$(gb_global DEFAULT_ACCESS_MODE metered)}"
    origin="${origin:-$(mcp_default_origin)}"
    type_mcp_create "$domain" "$mode" "$python" "$origin" "$file" || return 1
    type_mcp_deploy_finish "$domain"
}

type_mcp_deploy_interactive() {
    local domain mode python origin file cfmode
    ui_msg 'New MCP domain' 'One dedicated domain serves the MCP protocol at /. It covers every configured API version. This walkthrough gathers all settings before preparing the Python service and nginx. Publication and TLS follow the normal domain lifecycle.'
    domain="$(ui_input 'MCP domain' 'Dedicated domain name' 'mcp.example.org')" || return 1
    gb_valid_domain "$domain" || { ui_msg 'Invalid' 'That is not a valid domain name.'; return 1; }
    ep_exists "$domain" && { ui_msg 'Exists' "$domain is already configured."; return 1; }
    GB_DEPLOY_MODE="$(endpoint_prompt_deploy_mode "$domain")" || return 1
    mode="$(endpoint_prompt_access_mode)" || return 1
    python="$(ui_input 'MCP Python' 'Managed Python selection' auto)" || return 1
    origin="$(ui_input 'MCP origin' 'Local/private nginx origin for the configured upstream APIs' "$(mcp_default_origin)")" || return 1
    file="$(ui_input 'MCP environment' 'Optional absolute environment file for custom upstream domains' '')" || return 1
    cfmode="$(endpoint_prompt_cloudflare_mode "$domain")" || return 1
    type_mcp_create "$domain" "$mode" "$python" "$origin" "$file" || return 1
    ep_set "$domain" CLOUDFLARE_MODE "$cfmode" || return 1
    type_mcp_deploy_finish "$domain"
}

type_mcp_deploy_finish() {
    local domain="$1" conflicts
    conflicts="$(nginx_conflicts "$domain")"
    if [[ -n "$conflicts" ]]; then
        gb_warn "$domain is already declared in: $conflicts"
        ep_remove_config "$domain"
        return 1
    fi
    endpoint_apply "$domain" || return 1
    if ep_is_live "$domain"; then
        gb_log "MCP deployed at https://$domain/"
    else
        gb_log "$domain is staged. Verify it, then use 'getbible go-live $domain' when its public name should reach this server."
    fi
}

type_mcp_menu_items() {
    printf '%s\n' mcp-configure 'MCP: configure Python and upstreams' mcp-update 'MCP: update package' \
        mcp-rollback 'MCP: restore previous release' mcp-journal 'MCP: service journal'
}

type_mcp_menu_action() {
    local domain="$1" action="$2" out generation
    case "$action" in
        mcp-configure) mcp_menu "$domain" ;;
        mcp-update) ui_run "Update MCP: $domain" mcp_cli update "$domain" ;;
        mcp-rollback) ui_run "Rollback MCP: $domain" mcp_cli rollback "$domain" ;;
        mcp-journal)
            generation="$(mcp_active "$domain")"
            [[ -n "$generation" ]] || return 1
            out="$(gb_tmpdir)/mcp-journal.$$"
            sd_journal "$(mcp_unit "$domain" "$generation").service" 200 > "$out"
            ui_textbox "MCP journal: $domain" "$out" ;;
    esac
}
