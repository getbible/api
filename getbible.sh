#!/usr/bin/env bash
# getbible.sh - deploy and maintain getBible API endpoints on this server.
#
#   sudo ./getbible.sh              interactive menu
#   sudo ./getbible.sh <command>    non-interactive commands (see --help)
#
# Everything this script installs is rendered from src/ and recorded, so a
# later `git pull` followed by `getbible.sh update` brings every endpoint to
# the current templates without touching hand-managed files silently.

set -Eeuo pipefail
GB_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
GB_ARGS=("$@")
GB_REPO_DIR="$(cd -- "$(dirname -- "$GB_SELF")" && pwd -P)"
export GB_REPO_DIR

for lib in core platform ui config registry users telegram nginx certs systemd logs access sync python docs endpoint; do
    # shellcheck source=/dev/null
    source "$GB_REPO_DIR/src/lib/$lib.sh"
done
for extra in analytics cloudflare update migrate doctor golive menu; do
    # shellcheck source=/dev/null
    [[ -f "$GB_REPO_DIR/src/lib/$extra.sh" ]] && source "$GB_REPO_DIR/src/lib/$extra.sh"
done

usage() {
    cat <<'USAGE'
getbible.sh - getBible API endpoint manager

Usage: getbible.sh [command] [options]
Without a command an interactive menu opens.

Endpoints
  list                                   list endpoints
  status [DOMAIN]                        show status of one or all endpoints
  deploy static --domain D --version vN --repo URL [--ref master] [--path .]
                [--extensions json,sha,txt] [--access open|metered|token]
                [--schedule daily|weekly|monthly] [--staged|--live]
  deploy runtime --domain D --kind query|search [--version v2]
                [--repository PATH] [--access MODE] [--warm kjv] [--python auto|VERSION]
                [--staged|--live]
  go-live DOMAIN [--cert auto|http|dns-cloudflare]
                                         take a staged endpoint live: certificate,
                                         Cloudflare DNS and rules, HTTPS, verification
  verify DOMAIN                          check this server end to end for a domain
  cert DOMAIN status|issue [--method M]|renew
                                         certificate details; issue one now (a staged
                                         endpoint stays staged); force a renewal
  apply DOMAIN                           re-render and re-install one endpoint
  update [DOMAIN]                        apply reviewed code and configuration
  runtime versions                       list reviewed managed Python versions
  runtime DOMAIN update [--python VERSION] update packages and managed Python
  runtime DOMAIN redeploy                 rebuild using the selected Python
  runtime DOMAIN rollback                 restore the previous healthy deployment
  runtime DOMAIN set KEY VALUE            validate and apply one runtime setting
  remove DOMAIN [--purge]                stop serving an endpoint (purge deletes data)
  version add DOMAIN vN --repo URL [--ref master] [--path .]
  version remove DOMAIN vN
  sync DOMAIN [vN] [--force]             run the synchronisation now
  access DOMAIN open|metered|token       change the access mode
  limits DOMAIN [--rate N] [--burst N] [--hour N] [--day N] [--conn N]
  token DOMAIN add LABEL [--expires YYYY-MM-DD] | list | revoke ID
  docs DOMAIN                            re-render the documentation page

Observability
  logs DOMAIN [access|error|app] [--lines N]
  logs archives DOMAIN | logs rotate
  analytics [--window today|24h|7d|30d|all] [--domain D] [--json]

Platform
  settings [deploy-mode live|staged | cert-method auto|http|dns-cloudflare | certbot-email ADDRESS]
                                         show or change the defaults used by deploy and go-live
  telegram enable|disable|test
  cloudflare ...                         see: getbible.sh cloudflare help
  migrate                                retire the legacy nginx/systemd setup
  doctor                                 check this host
  install-deps                           install nginx, certbot, python and tools
  selftest                               run the repository test suite
  render DOMAIN --out DIR                render nginx files without installing

Options: --yes (non-interactive, safe defaults), --dry-run, --help
USAGE
}

# Global flags may appear anywhere.
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --yes|-y) GB_YES=true ;;
        --dry-run) GB_DRY_RUN=true ;;
        --help|-h) usage; exit 0 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
export GB_YES GB_DRY_RUN

gb_system_init() {
    gb_require_root
    gb_management_lock || return 1
    gb_global_init
    gb_ensure_base_groups
    gb_ensure_base_dirs
    tg_install_helper
    sync_install_tools
    logs_render_rotation
}

cmd_deploy() {
    local type="${1:-}"
    shift || true
    gb_system_init
    case "$type" in
        static) endpoint_source_type static; type_static_deploy_cli "$@" ;;
        runtime) endpoint_source_type runtime; type_runtime_deploy_cli "$@" ;;
        *) gb_die "deploy needs a type: static or runtime" ;;
    esac
}

cmd_version() {
    local action="${1:-}" domain="${2:-}" label="${3:-}" repo="" ref="master" subpath="."
    shift 3 || gb_die "version add|remove DOMAIN vN"
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    [[ "$(ep_get "$domain" TYPE)" == static ]] || gb_die "$domain is not a static endpoint"
    endpoint_source_type static
    case "$action" in
        add)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --repo) repo="$2"; shift 2 ;;
                    --ref) ref="$2"; shift 2 ;;
                    --path) subpath="$2"; shift 2 ;;
                    *) gb_die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$repo" ]] || gb_die "version add needs --repo"
            type_static_add_version "$domain" "$label" "$repo" "$ref" "$subpath"
            ;;
        remove) type_static_remove_version "$domain" "$label" ;;
        *) gb_die "version add|remove DOMAIN vN" ;;
    esac
}

cmd_sync() {
    local domain="${1:-}" label="" force=false
    [[ -n "$domain" ]] || gb_die "sync DOMAIN [vN] [--force]"
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true ;;
            v[0-9]*) [[ -z "$label" ]] || gb_die "Only one version may be synced at a time"; label="$1" ;;
            *) gb_die "Unknown sync option: $1" ;;
        esac
        shift
    done
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    [[ "$(ep_get "$domain" TYPE)" == static ]] || gb_die "$domain is not a static endpoint"
    if [[ -z "$label" ]]; then
        while read -r label; do
            [[ -n "$label" ]] || continue
            if [[ "$force" == true ]]; then sync_force_now "$domain" "$label"; else sync_run_now "$domain" "$label"; fi
        done < <(ep_versions "$domain")
    else
        if [[ "$force" == true ]]; then sync_force_now "$domain" "$label"; else sync_run_now "$domain" "$label"; fi
    fi
}

cmd_runtime() {
    local domain="${1:-}" action="${2:-}"
    if [[ "$domain" == versions ]]; then py_catalog; return; fi
    [[ -n "$domain" && -n "$action" ]] || gb_die "runtime DOMAIN update|redeploy|rollback|set KEY VALUE"
    shift 2
    gb_system_init || return 1
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    [[ "$(ep_get "$domain" TYPE)" == runtime ]] || gb_die "$domain is not a runtime endpoint"
    endpoint_source_type runtime
    case "$action" in
        update) rt_update "$domain" "$@" ;;
        redeploy) [[ $# == 0 ]] || gb_die "runtime DOMAIN redeploy"; rt_redeploy "$domain" ;;
        rollback) [[ $# == 0 ]] || gb_die "runtime DOMAIN rollback"; rt_rollback "$domain" ;;
        set) [[ $# == 2 ]] || gb_die "runtime DOMAIN set KEY VALUE"; rt_set_setting "$domain" "$1" "$2" ;;
        *) gb_die "Unknown runtime action: $action" ;;
    esac
}

cmd_limits() {
    local domain="${1:-}" rate="" burst="" hour="" day="" conn=""
    [[ -n "$domain" ]] || gb_die "limits DOMAIN [--rate N] [--burst N] [--hour N] [--day N] [--conn N]"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rate) rate="$2"; shift 2 ;;
            --burst) burst="$2"; shift 2 ;;
            --hour) hour="$2"; shift 2 ;;
            --day) day="$2"; shift 2 ;;
            --conn) conn="$2"; shift 2 ;;
            *) gb_die "Unknown option: $1" ;;
        esac
    done
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    endpoint_set_limits "$domain" "$rate" "$burst" "$hour" "$day" "$conn"
}

cmd_token() {
    local domain="${1:-}" action="${2:-}"
    [[ -n "$domain" && -n "$action" ]] || gb_die "token DOMAIN add LABEL [--expires DATE] | list | revoke ID"
    shift 2
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    case "$action" in
        add)
            local label="${1:-}" expires=""
            [[ -n "$label" ]] || gb_die "token add needs a label"
            shift
            [[ "${1:-}" == --expires ]] && expires="${2:-}"
            tokens_add "$domain" "$label" "$expires"
            endpoint_apply "$domain" >/dev/null
            tg_notify info "Token issued: $domain" "Label: $label"
            ;;
        list) tokens_list "$domain" ;;
        revoke)
            tokens_revoke "$domain" "${1:?token id}"
            endpoint_apply "$domain" >/dev/null
            tg_notify warn "Token revoked: $domain" "Id: $1"
            ;;
        *) gb_die "token DOMAIN add|list|revoke" ;;
    esac
}

cmd_logs() {
    local domain="${1:-}" which="${2:-access}" lines=200
    case "$domain" in
        rotate) gb_system_init; logs_rotate_now; return ;;
        archives) logs_archives "${2:?domain}"; return ;;
        "") gb_die "logs DOMAIN [access|error|app] [--lines N]" ;;
    esac
    [[ "${3:-}" == --lines ]] && lines="${4:-200}"
    [[ "$which" == --lines ]] && { lines="${3:-200}"; which=access; }
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    case "$which" in
        access|error) logs_tail "$(ep_log_dir "$domain")/$which.log" "$lines" ;;
        app) logs_tail "$(ep_log_dir "$domain")/app/app.log" "$lines" ;;
        journal)
            ep_load "$domain"
            if [[ "$EP_TYPE" == runtime ]]; then
                endpoint_source_type runtime
                sd_journal "$(rt_live_unit "$EP_KIND").service" "$lines"
            else
                sd_journal "getbible-sync-$EP_SLUG-$(ep_versions "$domain" | head -1).service" "$lines"
            fi ;;
        *) gb_die "Unknown log: $which (access, error, app, journal)" ;;
    esac
}

cmd_golive() {
    local domain="${1:-}" method=""
    [[ -n "$domain" ]] || gb_die "go-live DOMAIN [--cert auto|http|dns-cloudflare]"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert|--method) [[ -n "${2:-}" ]] || gb_die "$1 needs auto, http or dns-cloudflare"; method="$2"; shift 2 ;;
            *) gb_die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$method" ]] || certs_valid_method "$method" || gb_die "Certificate methods: auto, http, dns-cloudflare"
    gb_system_init
    golive_interactive "$domain" "$method"
}

cmd_settings() {
    local key="${1:-}" value="${2:-}"
    case "$key" in
        "")
            printf 'deploy-mode    %s\ncert-method    %s\ncertbot-email  %s\n' \
                "$(gb_global DEFAULT_DEPLOY_MODE live)" "$(gb_global CERT_METHOD auto)" "$(gb_global CERTBOT_EMAIL)" ;;
        deploy-mode)
            [[ -n "$value" ]] || { gb_global DEFAULT_DEPLOY_MODE live; return 0; }
            [[ "$value" == live || "$value" == staged ]] || gb_die "deploy-mode is live or staged"
            gb_global_set DEFAULT_DEPLOY_MODE "$value"
            gb_log "New endpoints are $value by default." ;;
        cert-method)
            [[ -n "$value" ]] || { gb_global CERT_METHOD auto; return 0; }
            certs_valid_method "$value" || gb_die "cert-method is auto, http or dns-cloudflare"
            gb_global_set CERT_METHOD "$value"
            gb_log "Certificates are validated with: $value." ;;
        certbot-email)
            [[ -n "$value" ]] || { gb_global CERTBOT_EMAIL; return 0; }
            certs_valid_email "$value" || gb_die "Invalid email address: $value"
            gb_global_set CERTBOT_EMAIL "$value"
            gb_log "Let's Encrypt contact email set." ;;
        *) gb_die "settings [deploy-mode live|staged | cert-method auto|http|dns-cloudflare | certbot-email ADDRESS]" ;;
    esac
}

cmd_render() {
    local domain="${1:-}" out=""
    [[ "${2:-}" == --out ]] && out="${3:-}"
    [[ -n "$domain" && -n "$out" ]] || gb_die "render DOMAIN --out DIR"
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    nginx_render_global "$out"
    nginx_render_endpoint "$out"
    gb_log "Rendered $domain into $out"
}

main() {
    local command="${1:-menu}"
    [[ $# -gt 0 ]] && shift
    case "$command" in
        menu) gb_system_init; ui_init; menu_main ;;
        list) ep_list ;;
        status)
            if [[ -n "${1:-}" ]]; then endpoint_status_text "$1"; else
                while read -r d; do [[ -n "$d" ]] && ep_summary_line "$d"; done < <(ep_list); fi ;;
        deploy) cmd_deploy "$@" ;;
        go-live|golive) cmd_golive "$@" ;;
        verify) gb_require_root; golive_verify "${1:?domain}" ;;
        cert) gb_system_init; certs_cli "$@" ;;
        settings) gb_system_init; cmd_settings "$@" ;;
        apply) gb_system_init; endpoint_apply "${1:?domain}" ;;
        update) gb_system_init; if [[ -n "${1:-}" ]]; then endpoint_apply "$1"; else update_all; fi ;;
        runtime) cmd_runtime "$@" ;;
        remove)
            gb_system_init
            local purge=false; [[ "${2:-}" == --purge ]] && purge=true
            endpoint_remove "${1:?domain}" "$purge" ;;
        version) cmd_version "$@" ;;
        sync) cmd_sync "$@" ;;
        access) gb_system_init; endpoint_set_access "${1:?domain}" "${2:?mode}" ;;
        limits) cmd_limits "$@" ;;
        token) cmd_token "$@" ;;
        docs) gb_system_init; ep_load "${1:?domain}"; endpoint_source_type "$EP_TYPE"; docs_render "$1" ;;
        logs) cmd_logs "$@" ;;
        analytics) analytics_cli "$@" ;;
        telegram)
            gb_system_init
            case "${1:-}" in
                enable) tg_configure ;;
                disable) cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false; gb_log "Telegram disabled." ;;
                test) tg_test ;;
                *) gb_die "telegram enable|disable|test" ;;
            esac ;;
        cloudflare) gb_system_init; cloudflare_cli "$@" ;;
        migrate) gb_system_init; migrate_legacy ;;
        doctor) doctor_run ;;
        install-deps) gb_require_root; doctor_install_deps ;;
        selftest) "$GB_REPO_DIR/tests/run.sh" ;;
        render) cmd_render "$@" ;;
        help|--help|-h) usage ;;
        *) gb_die "Unknown command: $command (try --help)" ;;
    esac
}

main "$@"
