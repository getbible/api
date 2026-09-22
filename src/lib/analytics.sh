#!/usr/bin/env bash
# Traffic analytics over the canonical telemetry database.

[[ -n "${GB_ANALYTICS_LOADED:-}" ]] && return 0
GB_ANALYTICS_LOADED=1

# analytics_report WINDOW [DOMAIN] [--json]
analytics_report() {
    local window="${1:-24h}" domain="${2:-}"
    shift 2 2>/dev/null || shift $# 
    local -a args=(--db "$GB_VAR/telemetry/traffic.sqlite3" --window "$window")
    [[ -n "$domain" ]] && args+=(--endpoint "$domain")
    "$GB_PYTHON" "$GB_TOOLS/getbible-analytics" "${args[@]}" "$@"
}

analytics_cli() {
    local window="24h" domain="" json=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window) window="$2"; shift 2 ;;
            --domain) domain="$2"; shift 2 ;;
            --json) json="--json"; shift ;;
            *) gb_die "Unknown option: $1 (analytics [--window today|24h|7d|30d|all] [--domain D] [--json])" ;;
        esac
    done
    if [[ -n "$json" ]]; then
        analytics_report "$window" "$domain" --json
    else
        analytics_report "$window" "$domain"
    fi
}

# Diagnostic only: no installation, database preparation or manager write lock.
capacity_cli() {
    [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || { gb_warn 'capacity [--json]'; return 1; }
    "$GB_PYTHON" "$GB_TOOLS/getbible-capacity" --db "$GB_VAR/telemetry/traffic.sqlite3" \
        --config "$GB_GLOBAL_CONF" --environment "$GB_ENVIRONMENT_CONF" "$@"
}
