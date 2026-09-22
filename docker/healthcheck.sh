#!/usr/bin/env bash
# Serving availability is independent of desired-release/upgrade completion.
set -Eeuo pipefail

healthcheck_socket() {
    local socket="$1" path="${2:-/readyz}" domain="${3:-localhost}"
    [[ "$socket" == /* && "$socket" != *$'\n'* ]] || return 1
    curl --fail --silent --show-error --noproxy '*' --max-time 3 \
        --unix-socket "$socket" --header "Host: $domain" \
        --header 'X-GetBible-Client-IP: 127.0.0.1' "http://localhost$path" >/dev/null
}

# An optional filesystem prefix supports the same disposable fixtures as the
# manager; the image always calls this without a prefix. No discovery mutates
# settings, release pointers, telemetry history or systemd state.
healthcheck_value() {
    local key="$1" file="$2" fallback="${3:-}"
    if [[ -f "$file" ]]; then
        awk -v key="$key" -v fallback="$fallback" 'index($0,key "=")==1 {value=substr($0,length(key)+2); found=1} END {print found ? value : fallback}' "$file"
    else printf '%s\n' "$fallback"; fi
}

healthcheck_main() {
    local prefix="${1:-}" environment generation socket enabled domain record type kind endpoint label slug port
    [[ -f "$prefix/run/getbible/container-initialized" ]] || return 1
    systemctl is-active --quiet nginx.service || return 1
    port="${GETBIBLE_ORIGIN_HTTP_PORT:-$(healthcheck_value ORIGIN_HTTP_PORT "$prefix/run/getbible/environment.conf" \
        "$(healthcheck_value ORIGIN_HTTP_PORT "$prefix/etc/getbible/getbible.conf" 80)")}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    curl --fail --silent --show-error --noproxy '*' --max-time 3 \
        -H 'Host: _' "http://127.0.0.1:$port/__getbible_health" >/dev/null || return 1
    # Every enabled registry entry must have its selected generation. Globbing
    # only existing environment files would hide a missing/broken active link.
    for record in "$prefix"/etc/getbible/endpoints/*/endpoint.conf; do
        [[ -f "$record" ]] || continue
        [[ "$(healthcheck_value ENABLED "$record" true)" == true ]] || continue
        type="$(healthcheck_value TYPE "$record")"
        case "$type" in
            runtime)
                kind="$(healthcheck_value KIND "$record")"
                [[ "$kind" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
                for endpoint in "${record%/*}/versions/"*.conf; do
                    [[ -f "$endpoint" ]] || continue
                    [[ "$(healthcheck_value ENABLED "$endpoint" true)" == true ]] || continue
                    label="${endpoint##*/}"; label="${label%.conf}"
                    [[ "$label" =~ ^(root|v[1-9][0-9]*)$ ]] || return 1
                    environment="$prefix/opt/getbible/$kind/$label/active/runtime.env"
                    [[ -f "$environment" ]] || return 1
                    socket="$(sed -nE 's/^[A-Z_]+_BIND="?unix:([^"[:space:]]*)"?$/\1/p' "$environment")" || return 1
                    healthcheck_socket "$socket" || return 1
                done ;;
            mcp)
                domain="${record%/*}"; domain="${domain##*/}"
                slug="$(printf '%s' "$domain" | tr -c 'a-z0-9' '_')"
                generation="$prefix/opt/getbible/mcp/$slug/active"
                [[ -f "$generation/.socket" ]] || return 1
                socket="$(cat "$generation/.socket")" || return 1
                healthcheck_socket "$socket" || return 1 ;;
            static) ;;
            *) return 1 ;;
        esac
    done
    # Disabled domains/endpoints and unregistered retained generations are not
    # serving obligations. All probes above come from enabled registry entries.
    environment="$prefix/run/getbible/dashboard.conf"
    [[ -f "$environment" ]] || return 1
    enabled="$(sed -n 's/^DASHBOARD_ENABLED=//p' "$environment")" || return 1
    if [[ "$enabled" == true ]]; then
        domain="$(sed -n 's/^DASHBOARD_DOMAIN=//p' "$environment")" || return 1
        [[ -n "$domain" ]] || return 1
        healthcheck_socket "$prefix/run/getbible-dashboard/http.sock" /health "$domain" || return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then healthcheck_main; fi
