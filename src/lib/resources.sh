#!/usr/bin/env bash
# Global allocation is a read-only plan until the normal runtime generation
# transaction applies it. No corpus scans, new access limits or cache wrappers.
[[ -n "${GB_RESOURCES_LOADED:-}" ]] && return 0
GB_RESOURCES_LOADED=1

resources_plan() {
    local mode=native budget
    local -a args=()
    if declare -F gb_is_docker >/dev/null && gb_is_docker; then mode=docker; fi
    budget="${GETBIBLE_MEMORY_BUDGET:-$(gb_global MEMORY_BUDGET auto)}"
    args=(--mode "$mode" --budget "$budget" --registry "$GB_ENDPOINTS" --runtime-root "$GB_OPT" --systemctl "$GB_SYSTEMCTL")
    [[ "${GB_RESOURCES_BOOTSTRAP:-false}" == true ]] && args+=(--offline)
    "$GB_PYTHON" "$GB_TOOLS/getbible-resources" "${args[@]}" "$@"
}

# Preflight before directory/user/service mutation, accounting for every live
# generation (including a previous generation still draining nginx requests).
resources_preflight() {
    resources_plan --candidate-domain "$1" --format json > "$(gb_tmpdir)/resources-preflight.json"
}

# Called with EP_*, EV_* and RM_* loaded. Native defaults preserve existing
# tuning; enabled budgeting overrides only effective generation settings.
resources_context() {
    local domain="$1" label="$2" output key value
    RES_ENABLED=false
    RES_WORKERS="${EV_WORKERS:-$RM_WORKERS}"
    RES_THREADS="${EV_THREADS:-$RM_THREADS}"
    # shellcheck disable=SC2153 # RM_* are loaded from the runtime manifest.
    RES_MEMORY_HIGH="$RM_MEMORY_HIGH"
    # shellcheck disable=SC2153 # RM_* are loaded from the runtime manifest.
    RES_MEMORY_MAX="$RM_MEMORY_MAX"
    RES_WARM_TRANSLATIONS="${EV_WARM_TRANSLATIONS:-}"
    RES_SEARCH_MAX_CONCURRENT="$RES_THREADS"
    RES_EXPENSIVE_CONCURRENT=$(( RES_THREADS / 2 ))
    (( RES_EXPENSIVE_CONCURRENT > 0 )) || RES_EXPENSIVE_CONCURRENT=1
    RES_TRANSLATION_CACHE_LIMIT=4; RES_SEARCH_CORPUS_LIMIT=4
    RES_REFERENCE_CACHE_LIMIT=5000; RES_CHAPTER_CACHE_LIMIT=2048
    output="$(resources_plan --format env --select "$domain" "$label")" || return 1
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^RES_[A-Z_]+$ ]] || continue
        # No eval/source: registry data cannot become shell instructions.
        printf -v "$key" '%s' "$value"
    done <<< "$output"
}

resources_status() {
    if [[ "${1:-}" == --json ]]; then resources_plan --format json; else resources_plan --format text; fi
}

# Before the outer nginx transaction, shrink other domains when a new endpoint
# changes the global split. Their old workers drain before the new allocation
# is consumed. An empty target (after removal) also grows remaining domains.
resources_reconcile() {
    local target="${1:-}" domain domains format=changes
    [[ "${GB_RESOURCE_RECONCILING:-false}" == true || "${GB_RESOURCES_BOOTSTRAP:-false}" == true ]] && return 0
    [[ -n "$target" ]] && format=reductions
    domains="$(resources_plan --format "$format" --exclude-domain "$target")" || return 1
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        gb_step "Adapting resources for $domain before the next deployment"
        (
            # Keep the caller's transaction state and temporary directory alive.
            trap - EXIT
            GB_RESOURCE_RECONCILING=true
            endpoint_apply "$domain"
        ) || return 1
        resources_plan --wait-drain "$domain" || return 1
    done <<< "$domains"
}

resources_apply() {
    local domains domain
    local GB_RESOURCE_RECONCILING=true
    gb_require_root
    domains="$(resources_plan --format domains)" || return 1
    [[ -n "$domains" ]] || { resources_status; return 0; }
    tg_notify start "Resource allocation started" "Applying the configured memory budget through normal runtime generation transactions."
    # Each domain's transaction starts candidates, checks readiness and switches
    # nginx after validation. Admission rechecks still-draining old generations.
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        endpoint_apply "$domain" || return 1
        resources_plan --wait-drain "$domain" || return 1
    done <<< "$domains"
    resources_status
    tg_notify ok "Resource allocation complete" "Runtime generation settings now reflect the configured memory budget."
}

resources_cli() {
    case "${1:-show}" in
        show|status) shift || true; resources_status "${1:-}" ;;
        --json) resources_status --json ;;
        apply) resources_apply ;;
        *) gb_die "Usage: getbible resources [show|apply] [--json]" ;;
    esac
}

resources_menu() {
    local choice
    while true; do
        choice="$(ui_menu "Runtime resources" "Memory allocation across all enabled runtime endpoints" \
            show "Show effective resource targets" apply "Apply targets through healthy runtime generations")" || return 0
        case "$choice" in
            show) ui_run "Runtime resource targets" resources_status ;;
            apply) ui_run "Apply runtime resources" resources_apply ;;
        esac
    done
}
