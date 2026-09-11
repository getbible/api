#!/usr/bin/env bash
# Global allocation is a read-only plan until the normal runtime generation
# transaction applies it. No corpus scans, new access limits or cache wrappers.
[[ -n "${GB_RESOURCES_LOADED:-}" ]] && return 0
GB_RESOURCES_LOADED=1

resources_plan() {
    local mode=native budget key default value
    local -a args=()
    if declare -F gb_is_docker >/dev/null && gb_is_docker; then mode=docker; fi
    budget="${GETBIBLE_MEMORY_BUDGET:-$(gb_global MEMORY_BUDGET auto)}"
    args=(--mode "$mode" --budget "$budget" --registry "$GB_ENDPOINTS" --runtime-root "$GB_OPT" --systemctl "$GB_SYSTEMCTL")
    args+=(--adaptive-state "$GB_VAR/adaptive.json")
    for key in MEMORY_CACHE_TTL:2592000 CACHE_TTL_JITTER:0 QUERY_CPU_QUOTA:auto SEARCH_CPU_QUOTA:auto \
        QUERY_WORKERS_MIN:1 QUERY_WORKERS_MAX:12 SEARCH_WORKERS_MIN:1 SEARCH_WORKERS_MAX:12 \
        QUERY_THREADS_MIN:1 QUERY_THREADS_MAX:16 SEARCH_THREADS_MIN:1 SEARCH_THREADS_MAX:8 \
        QUERY_WARM_TRANSLATIONS:kjv SEARCH_WARM_TRANSLATIONS:kjv CACHE_MEMORY_PERCENT:50 \
        SHARED_CORPUS_LIMIT:256 CHAPTER_CACHE_LIMIT:100000 TRANSLATION_CACHE_LIMIT:256 REFERENCE_CACHE_LIMIT:50000 \
        QUERY_MEMORY_MIN:192M SEARCH_MEMORY_MIN:512M QUERY_MEMORY_MAX:auto SEARCH_MEMORY_MAX:auto RESOURCE_RESERVE_PERCENT:25; do
        default="${key#*:}"; key="${key%%:*}"
        value="$(gb_global "$key" "$default")"
        args+=(--policy "$key=$value")
        if declare -F gb_environment_managed >/dev/null && gb_environment_managed "$GB_GLOBAL_CONF" "$key"; then
            args+=(--authoritative "$key")
        fi
    done
    [[ "${GB_RESOURCES_BOOTSTRAP:-false}" == true ]] && args+=(--offline)
    "$GB_PYTHON" "$GB_TOOLS/getbible-resources" "${args[@]}" "$@"
}

resources_value() {
    local domain="$1" label="$2" key="$3" global_key="$4" default="$5"
    if declare -F gb_environment_managed >/dev/null && gb_environment_managed "$GB_GLOBAL_CONF" "$global_key"; then
        gb_global "$global_key" "$default"
    else
        ep_version_get "$domain" "$label" "$key" "$(gb_global "$global_key" "$default")"
    fi
}

# Preflight before directory/user/service mutation, accounting for every live
# generation (including a previous generation still draining nginx requests).
resources_preflight() {
    resources_plan --candidate-domain "$1" --format json > "$(gb_tmpdir)/resources-preflight.json"
}

# Called with EP_*, EV_* and RM_* loaded. Native defaults preserve existing
# tuning; enabled budgeting overrides only effective generation settings.
resources_context() {
    local domain="$1" label="$2" output key value prefix cpu_setting memory_bytes cache_bytes requested_workers thread_min thread_max cache_percent
    prefix="${EP_KIND^^}"
    RES_ENABLED=false
    RES_WORKERS="${EV_WORKERS:-$RM_WORKERS}"
    requested_workers="$RES_WORKERS"
    RES_THREADS="${EV_THREADS:-$RM_THREADS}"
    RES_WORKERS_MIN="$(resources_value "$domain" "$label" WORKERS_MIN "${prefix}_WORKERS_MIN" 1)"
    RES_WORKERS_MAX="$(resources_value "$domain" "$label" WORKERS_MAX "${prefix}_WORKERS_MAX" 12)"
    if [[ "$RES_WORKERS" == auto ]]; then RES_WORKERS="$RES_WORKERS_MIN"; fi
    if [[ "$RES_THREADS" == auto ]]; then RES_THREADS=4; fi
    thread_min="$(resources_value "$domain" "$label" THREADS_MIN "${prefix}_THREADS_MIN" 1)"
    thread_max="$(resources_value "$domain" "$label" THREADS_MAX "${prefix}_THREADS_MAX" 16)"
    if (( thread_min > thread_max || RES_WORKERS_MIN > RES_WORKERS_MAX )); then gb_warn "Runtime resource minimum exceeds maximum"; return 1; fi
    if (( RES_THREADS < thread_min )); then RES_THREADS="$thread_min"; fi
    if (( RES_THREADS > thread_max )); then RES_THREADS="$thread_max"; fi
    if (( RES_WORKERS < RES_WORKERS_MIN )); then RES_WORKERS="$RES_WORKERS_MIN"; fi
    if (( RES_WORKERS > RES_WORKERS_MAX )); then RES_WORKERS="$RES_WORKERS_MAX"; fi
    cpu_setting="$(resources_value "$domain" "$label" CPU_QUOTA "${prefix}_CPU_QUOTA" auto)"
    RES_CPU_QUOTA="${RM_CPU_QUOTA:-200%}"
    if [[ "$cpu_setting" != auto ]]; then RES_CPU_QUOTA="$cpu_setting"; fi
    RES_TASKS_MAX="${RM_TASKS_MAX:-128}"; RES_NOFILE="${RM_NOFILE:-4096}"
    RES_MEMORY_CACHE_TTL="$(resources_value "$domain" "$label" MEMORY_CACHE_TTL MEMORY_CACHE_TTL 2592000)"
    RES_CACHE_TTL_JITTER="$(gb_global CACHE_TTL_JITTER 0)"
    # shellcheck disable=SC2153 # RM_* are loaded from the runtime manifest.
    RES_MEMORY_HIGH="$RM_MEMORY_HIGH"
    RES_MEMORY_MAX="$(resources_value "$domain" "$label" MEMORY_MAX "${prefix}_MEMORY_MAX" auto)"
    # shellcheck disable=SC2153 # RM_MEMORY_MAX is loaded dynamically from the runtime manifest.
    [[ "$RES_MEMORY_MAX" != auto ]] || RES_MEMORY_MAX="$RM_MEMORY_MAX"
    RES_WARM_TRANSLATIONS="$(resources_value "$domain" "$label" WARM_TRANSLATIONS "${prefix}_WARM_TRANSLATIONS" kjv)"
    [[ "$RES_WARM_TRANSLATIONS" != none ]] || RES_WARM_TRANSLATIONS=""
    RES_SEARCH_MAX_CONCURRENT="$RES_THREADS"
    RES_EXPENSIVE_CONCURRENT=$(( RES_THREADS / 2 ))
    (( RES_EXPENSIVE_CONCURRENT > 0 )) || RES_EXPENSIVE_CONCURRENT=1
    RES_TRANSLATION_CACHE_LIMIT="$(resources_value "$domain" "$label" TRANSLATION_CACHE_LIMIT TRANSLATION_CACHE_LIMIT 256)"
    RES_SHARED_CORPUS_LIMIT="$(resources_value "$domain" "$label" SHARED_CORPUS_LIMIT SHARED_CORPUS_LIMIT 256)"
    RES_SEARCH_CORPUS_LIMIT="$RES_SHARED_CORPUS_LIMIT"
    RES_REFERENCE_CACHE_LIMIT="$(resources_value "$domain" "$label" REFERENCE_CACHE_LIMIT REFERENCE_CACHE_LIMIT 50000)"
    RES_CHAPTER_CACHE_LIMIT="$(resources_value "$domain" "$label" CHAPTER_CACHE_LIMIT CHAPTER_CACHE_LIMIT 100000)"
    memory_bytes="$("$GB_PYTHON" - "$RES_MEMORY_MAX" <<'PYMEM'
import re, sys
from decimal import Decimal
m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGT]?)(?:I?B)?", sys.argv[1].upper())
if not m: raise SystemExit("Invalid native runtime memory ceiling")
print(int(Decimal(m[1]) * (1024 ** ("KMGT".index(m[2]) + 1) if m[2] else 1)))
PYMEM
)" || return 1
    if [[ "$requested_workers" == auto ]]; then
        RES_WORKERS="$("$GB_PYTHON" - "$RES_CPU_QUOTA" "$RES_WORKERS_MIN" "$RES_WORKERS_MAX" "$memory_bytes" "$EP_KIND" <<'PYWORK'
import math, os, sys
capacity = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 1)
if sys.argv[1]: capacity = min(capacity, math.ceil(float(sys.argv[1].rstrip("%")) / 100))
minimum, maximum = int(sys.argv[2]), int(sys.argv[3])
floor = (128 if sys.argv[5] == "query" else 512) * 1024**2
capacity = min(capacity, maximum, int(sys.argv[4]) // floor)
if capacity < minimum: raise SystemExit("Runtime memory cannot fit its minimum worker count")
print(max(minimum, capacity))
PYWORK
)" || return 1
    fi
    RES_MEMORY_MAX="$memory_bytes"
    RES_MEMORY_HIGH=$(( memory_bytes * 85 / 100 ))
    if (( RES_TASKS_MAX < RES_WORKERS * (RES_THREADS + 5) + 32 )); then
        RES_TASKS_MAX=$(( RES_WORKERS * (RES_THREADS + 5) + 32 ))
    fi
    cache_percent="$(resources_value "$domain" "$label" CACHE_MEMORY_PERCENT CACHE_MEMORY_PERCENT 50)"
    cache_bytes=$(( memory_bytes * cache_percent / (RES_WORKERS * 100) ))
    if [[ "$EP_KIND" == query ]]; then
        RES_CHAPTER_CACHE_BYTES=$(( cache_bytes * 80 / 100 ))
        RES_TRANSLATION_CACHE_BYTES=$(( cache_bytes * 10 / 100 ))
    else
        RES_CHAPTER_CACHE_BYTES=$(( cache_bytes * 10 / 100 ))
        RES_TRANSLATION_CACHE_BYTES=$(( cache_bytes * 20 / 100 ))
    fi
    RES_SHARED_CORPUS_BYTES=$(( cache_bytes - RES_CHAPTER_CACHE_BYTES - RES_TRANSLATION_CACHE_BYTES ))
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
            show) ui_run "Runtime resource targets" resources_status || true ;;
            apply) ui_run "Apply runtime resources" resources_apply || true ;;
        esac
    done
}
