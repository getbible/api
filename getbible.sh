#!/usr/bin/env bash
# getbible.sh - deploy and maintain getBible API domains on this server.
#
#   sudo ./getbible.sh              interactive menu
#   sudo ./getbible.sh <command>    non-interactive commands (see --help)
#
# Everything this script installs is rendered from src/ and recorded, so a
# later `git pull` followed by `getbible.sh update` brings every domain to
# the current templates without touching hand-managed files silently.

set -Eeuo pipefail
GB_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
GB_ARGS=("$@")
GB_REPO_DIR="$(cd -- "$(dirname -- "$GB_SELF")" && pwd -P)"
export GB_REPO_DIR

for lib in core platform ui config registry users telegram nginx certs systemd logs access sync python docs pages endpoint; do
    # shellcheck source=/dev/null
    source "$GB_REPO_DIR/src/lib/$lib.sh"
done
for extra in analytics cloudflare update migrate doctor golive menu; do
    # shellcheck source=/dev/null
    [[ -f "$GB_REPO_DIR/src/lib/$extra.sh" ]] && source "$GB_REPO_DIR/src/lib/$extra.sh"
done

usage() {
    cat <<'USAGE'
getbible.sh - getBible API domain manager

Usage: getbible.sh [command] [options]
Without a command an interactive menu opens.

A domain is a host name: one vhost, one certificate, one go-live. Its
endpoints are its version folders (https://D/v2/), or the domain root itself
when it was set up without version folders (the label "root").

Domains
  list                                   list domains
  status [DOMAIN]                        show status of one or all domains
  deploy static --domain D --version vN|root --repo URL [--ref master] [--path .]
                [--extensions json,sha,txt] [--access open|metered|token]
                [--schedule daily|weekly|monthly] [--staged|--live]
  deploy runtime --domain D --kind query|search [--version v2] [--root]
                [--repository PATH] [--access MODE] [--warm kjv] [--python auto|VERSION]
                [--staged|--live]      (--root serves the version at https://D/ instead of /v2/)
  go-live DOMAIN [--cert auto|http|dns-cloudflare]
                                         take a staged domain live: certificate,
                                         Cloudflare DNS and rules, HTTPS, verification
  verify DOMAIN                          check this server end to end for a domain
  stage DOMAIN                           stage a live domain again (stop taking over its
                                         name; DNS is not changed), for rolling back
  cert DOMAIN status|issue [--method M]|renew
                                         certificate details; issue one now (a staged
                                         domain stays staged); force a renewal
  apply DOMAIN                           re-render and re-install one domain
  update [DOMAIN]                        apply reviewed code and configuration
  runtime versions                       list reviewed managed Python versions
  runtime DOMAIN [ENDPOINT] update [--python VERSION]
                                         update packages and managed Python (every endpoint,
                                         or the named one)
  runtime DOMAIN redeploy                 redeploy every endpoint's current release
  runtime DOMAIN [ENDPOINT] rollback      restore an endpoint's previous healthy deployment
  runtime DOMAIN [ENDPOINT] set KEY VALUE validate and apply one endpoint setting
                                         (ENDPOINT may be left out when the domain has one)
  remove DOMAIN [--purge]                stop serving a domain (purge deletes data)
  filetypes DOMAIN json,sha,txt          change the file types a static domain serves
  version add DOMAIN vN --repo URL [--ref master] [--path .]
                                         add a version folder (an endpoint) to a static domain
  version add DOMAIN vN [--repository PATH] [--warm LIST] [--python V]
                                         add a version to a runtime domain: its own service
  version change DOMAIN vN|root [--repo URL] [--ref REF] [--path P]
                                         point a static endpoint elsewhere, keeping its releases
  version default DOMAIN vN              the runtime endpoint that answers / and the short forms
  version remove DOMAIN vN|root
  sync DOMAIN [vN|root] [--force]        publish the trusted repository's current files
  access DOMAIN open|metered|token       change the access mode
  limits DOMAIN [--rate N] [--burst N] [--hour N] [--day N] [--conn N]
  token DOMAIN add LABEL [--expires YYYY-MM-DD] | list | revoke ID

Pages and OpenAPI (every domain page, endpoint page and document is public)
  pages DOMAIN [show]                    where each page, OpenAPI document, the favicon and
                                         the logo come from, and whether the file is present
  pages DOMAIN docs [ENDPOINT] generated|custom|edit|from FILE|repository [PATH]|none
                                         the domain page (no ENDPOINT) or an endpoint page:
                                         let the tool write it, take it over (custom, edit,
                                         from a file on this server), serve the repository's
                                         file (static; PATH inside the version folder), or 404
  pages DOMAIN openapi ENDPOINT generated|repository [PATH]|custom|edit|from FILE|none
                                         the endpoint's OpenAPI document (generated: runtime
                                         only; repository: static only)
  pages DOMAIN favicon default|none|FILE this domain's favicon (default: the system favicon)
  pages DOMAIN logo default|none|FILE    the logo on this domain's pages (default: the system logo)
  pages DOMAIN publish                   rewrite the generated pages, icons and versions.json
  icons                                  show the favicon and logo every domain serves by default
  favicon [FILE|default|none]            show or set that favicon (default: the repository's
                                         img/icon-96.png; FILE: .ico, .png, .svg or .gif)
  logo [FILE|default|none]               show or set that logo (default: the repository's
                                         img/logo.png; FILE: .png, .jpg, .svg, .gif or .webp)
  docs DOMAIN                            same as pages DOMAIN publish

Observability
  logs DOMAIN [access|error|app|journal] [ENDPOINT] [--lines N]
  logs archives DOMAIN | logs rotate
  analytics [--window today|24h|7d|30d|all] [--domain D] [--json]

Platform
  self-update                            pull the manager script and supporting files
                                         from this checkout's Git upstream (no domain apply)
  settings [deploy-mode live|staged | cert-method auto|http|dns-cloudflare | certbot-email ADDRESS
           | public-ipv4 [ADDRESS] | public-ipv6 [ADDRESS]]
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
    shift 3 || gb_die "version add|change|remove|default DOMAIN vN|root"
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    if [[ "$(ep_get "$domain" TYPE)" == runtime ]]; then
        cmd_runtime_version "$action" "$domain" "$label" "$@"
        return
    fi
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
        change)
            repo=""; ref=""; subpath=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --repo) repo="${2:?repository URL}"; shift 2 ;;
                    --ref) ref="${2:?git reference}"; shift 2 ;;
                    --path) subpath="${2:?source path}"; shift 2 ;;
                    *) gb_die "Unknown option: $1" ;;
                esac
            done
            [[ -n "$repo$ref$subpath" ]] || gb_die "version change needs --repo, --ref or --path"
            type_static_change_version "$domain" "$label" "$repo" "$ref" "$subpath"
            ;;
        remove) type_static_remove_version "$domain" "$label" ;;
        *) gb_die "version add|change|remove DOMAIN vN|root (static domains)" ;;
    esac
}

# The endpoints of a runtime domain: one service per version.
cmd_runtime_version() {
    local action="$1" domain="$2" label="$3" repository="" warm="" python="" translation="" reference="" checksums=""
    shift 3
    endpoint_source_type runtime
    case "$action" in
        add)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --repository) repository="${2:?path}"; shift 2 ;;
                    --warm) warm="${2:?translations}"; shift 2 ;;
                    --python) python="${2:?version}"; shift 2 ;;
                    --default-translation) translation="${2:?translation}"; shift 2 ;;
                    --default-reference) reference="${2:?reference}"; shift 2 ;;
                    --require-checksums) checksums="${2:?true or false}"; shift 2 ;;
                    *) gb_die "Unknown option: $1" ;;
                esac
            done
            rt_add_endpoint "$domain" "$label" "$repository" "$warm" "$python" "$translation" "$reference" "$checksums" ;;
        remove) rt_remove_endpoint "$domain" "$label" ;;
        default) rt_set_default "$domain" "$label" ;;
        *) gb_die "version add DOMAIN vN [--repository PATH] [--warm LIST] [--python V] | remove DOMAIN vN | default DOMAIN vN (runtime domains)" ;;
    esac
}

cmd_sync() {
    local domain="${1:-}" label="" force=false
    [[ -n "$domain" ]] || gb_die "sync DOMAIN [vN|root] [--force]"
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true ;;
            v[0-9]*|root) [[ -z "$label" ]] || gb_die "Only one endpoint may be synced at a time"; label="$1" ;;
            *) gb_die "Unknown sync option: $1" ;;
        esac
        shift
    done
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    [[ "$(ep_get "$domain" TYPE)" == static ]] || gb_die "$domain is not a static domain"
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
    local domain="${1:-}" action="${2:-}" label=""
    if [[ "$domain" == versions ]]; then py_catalog; return; fi
    [[ -n "$domain" && -n "$action" ]] || gb_die "runtime DOMAIN [ENDPOINT] update|redeploy|rollback|set KEY VALUE"
    shift 2
    gb_system_init || return 1
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    [[ "$(ep_get "$domain" TYPE)" == runtime ]] || gb_die "$domain is not a runtime domain"
    endpoint_source_type runtime
    # An endpoint may be named before the action: runtime D v2 rollback.
    if gb_valid_endpoint_label "$action"; then
        label="$action"; action="${1:-}"; shift || true
        [[ -n "$action" ]] || gb_die "runtime DOMAIN ENDPOINT update|rollback|set KEY VALUE"
    fi
    case "$action" in
        update) rt_update "$domain" ${label:+"$label"} "$@" ;;
        redeploy) [[ $# == 0 && -z "$label" ]] || gb_die "runtime DOMAIN redeploy (every endpoint)"; rt_redeploy "$domain" ;;
        rollback)
            [[ $# == 0 ]] || gb_die "runtime DOMAIN [ENDPOINT] rollback"
            label="$(rt_resolve_label "$domain" "$label")" || exit 1
            rt_rollback "$domain" "$label" ;;
        set)
            [[ $# == 2 ]] || gb_die "runtime DOMAIN [ENDPOINT] set KEY VALUE"
            label="$(rt_resolve_label "$domain" "$label")" || exit 1
            rt_set_setting "$domain" "$label" "$1" "$2" ;;
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
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    endpoint_set_limits "$domain" "$rate" "$burst" "$hour" "$day" "$conn"
}

cmd_token() {
    local domain="${1:-}" action="${2:-}"
    [[ -n "$domain" && -n "$action" ]] || gb_die "token DOMAIN add LABEL [--expires DATE] | list | revoke ID"
    shift 2
    gb_system_init
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
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
    local domain="${1:-}" which="${2:-access}" lines=200 label=""
    case "$domain" in
        rotate) gb_system_init; logs_rotate_now; return ;;
        archives) logs_archives "${2:?domain}"; return ;;
        "") gb_die "logs DOMAIN [access|error|app|journal] [ENDPOINT] [--lines N]" ;;
    esac
    shift; [[ $# -eq 0 ]] || shift
    if [[ -n "${1:-}" ]] && gb_valid_endpoint_label "$1"; then label="$1"; shift; fi
    [[ "${1:-}" == --lines ]] && lines="${2:-200}"
    [[ "$which" == --lines ]] && { lines="${1:-200}"; which=access; }
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    case "$which" in
        access|error) logs_tail "$(ep_log_dir "$domain")/$which.log" "$lines" ;;
        app)
            [[ "$EP_TYPE" == runtime ]] || gb_die "$domain is a static domain; it has no application log."
            for label in $(if [[ -n "$label" ]]; then printf '%s\n' "$label"; else type_runtime_endpoints "$domain"; fi); do
                printf '== %s %s: %s ==\n' "$domain" "$label" "$(rt_app_log "$domain" "$label")"
                logs_tail "$(rt_app_log "$domain" "$label")" "$lines"
            done ;;
        journal)
            if [[ "$EP_TYPE" == runtime ]]; then
                for label in $(if [[ -n "$label" ]]; then printf '%s\n' "$label"; else type_runtime_endpoints "$domain"; fi); do
                    printf '== %s %s ==\n' "$domain" "$label"
                    sd_journal "$(rt_live_unit "$domain" "$label").service" "$lines"
                done
            else
                sd_journal "getbible-sync-$EP_SLUG-${label:-$(ep_versions "$domain" | head -1)}.service" "$lines"
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
            printf 'deploy-mode    %s\ncert-method    %s\ncertbot-email  %s\npublic-ipv4    %s\npublic-ipv6    %s\n' \
                "$(gb_global DEFAULT_DEPLOY_MODE live)" "$(gb_global CERT_METHOD auto)" "$(gb_global CERTBOT_EMAIL)" \
                "$(gb_global SERVER_PUBLIC_IPV4)" "$(gb_global SERVER_PUBLIC_IPV6)" ;;
        public-ipv4)
            [[ $# -ge 2 ]] || { gb_global SERVER_PUBLIC_IPV4; return 0; }
            [[ -z "$value" || "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || gb_die "Invalid IPv4 address: $value"
            gb_global_set SERVER_PUBLIC_IPV4 "$value"
            gb_log "Public IPv4 for DNS records: ${value:-detected automatically}." ;;
        public-ipv6)
            [[ $# -ge 2 ]] || { gb_global SERVER_PUBLIC_IPV6; return 0; }
            [[ -z "$value" || "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" == *:* ]] || gb_die "Invalid IPv6 address: $value"
            gb_global_set SERVER_PUBLIC_IPV6 "$value"
            gb_log "Public IPv6 for DNS records: ${value:-detected automatically}." ;;
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
        *) gb_die "settings [deploy-mode live|staged | cert-method auto|http|dns-cloudflare | certbot-email ADDRESS | public-ipv4 [ADDRESS] | public-ipv6 [ADDRESS]]" ;;
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
        stage) gb_system_init; golive_stage_again "${1:?domain}" ;;
        cert) gb_system_init; certs_cli "$@" ;;
        settings) gb_system_init; cmd_settings "$@" ;;
        apply) gb_system_init; endpoint_apply "${1:?domain}" ;;
        update) gb_system_init; if [[ -n "${1:-}" ]]; then endpoint_apply "$1"; else update_all; fi ;;
        self-update)
            [[ $# == 0 ]] || gb_die "self-update takes no arguments (use --dry-run to preview)."
            gb_require_root
            if [[ "$GB_DRY_RUN" != true ]]; then gb_management_lock || return 1; fi
            update_manager ;;
        runtime) cmd_runtime "$@" ;;
        remove)
            gb_system_init
            local purge=false; [[ "${2:-}" == --purge ]] && purge=true
            endpoint_remove "${1:?domain}" "$purge" ;;
        version) cmd_version "$@" ;;
        filetypes)
            gb_system_init
            ep_exists "${1:-}" || gb_die "filetypes DOMAIN json,sha,txt"
            [[ "$(ep_get "$1" TYPE)" == static ]] || gb_die "$1 is not a static domain"
            endpoint_source_type static
            type_static_set_extensions "$1" "${2:?file types}" ;;
        sync) cmd_sync "$@" ;;
        access) gb_system_init; endpoint_set_access "${1:?domain}" "${2:?mode}" ;;
        limits) cmd_limits "$@" ;;
        token) cmd_token "$@" ;;
        pages)
            # "publish" is what the sync units run after every successful sync:
            # it only rewrites generated files, so it takes no management lock.
            if [[ "${2:-}" == publish ]]; then gb_require_root; else gb_system_init; fi
            pages_cli "$@" ;;
        icons) gb_system_init; icons_status_text ;;
        favicon)
            gb_system_init
            if [[ -z "${1:-}" ]]; then favicon_status_text; else favicon_set_system "$1" && endpoint_apply_all; fi ;;
        logo)
            gb_system_init
            if [[ -z "${1:-}" ]]; then logo_status_text; else logo_set_system "$1" && endpoint_apply_all; fi ;;
        docs) gb_require_root; pages_cli "${1:?domain}" publish ;;
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
