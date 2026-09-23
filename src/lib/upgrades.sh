#!/usr/bin/env bash
# One selectable upgrade path. Planning never changes installed state or data.
[[ -n "${GB_UPGRADES_LOADED:-}" ]] && return 0
GB_UPGRADES_LOADED=1

upgrade_helper() { "$GB_PYTHON" "$GB_TOOLS/getbible-upgrades" "$@" --state "$GB_STATE/upgrades.json"; }

upgrade_effective_values() {
    local kind="$1" service="$2" key entry
    local -A defaults=()
    for entry in "${GB_GLOBAL_DEFAULTS[@]}"; do defaults["${entry%%=*}"]="${entry#*=}"; done
    if gb_is_docker; then defaults[TLS_MODE]=external; defaults[DEFAULT_DEPLOY_MODE]=staged; fi
    while IFS= read -r key; do
        case "$kind:$key" in
            management:DASHBOARD_*|management:TELEMETRY_*|management:ALERT_*|management:ADAPTIVE_*|management:STORAGE_*|management:LOG_ROTATE_*|management:TELEGRAM_*) ;;
            runtime:MEMORY_*|runtime:CACHE_*|runtime:RESOURCE_*|runtime:SHARED_*|runtime:CHAPTER_*|runtime:TRANSLATION_*|runtime:REFERENCE_*) ;;
            runtime:"${service^^}"_*|runtime:DEFAULT_"${service^^}"_*) ;;
            static:STORAGE_*|static:DEFAULT_SYNC_*|static:LOG_ROTATE_*) ;;
            *:TLS_MODE|*:TRUSTED_PROXY_CIDRS|*:PUBLIC_SCHEME|*:ORIGIN_HTTP_PORT|*:HSTS_INCLUDE_SUBDOMAINS) ;;
            *) continue ;;
        esac
        printf '%s=%s\n' "$key" "$(cfg_get "$(gb_environment_file "$key")" "$key" "${defaults[$key]:-}")"
    done < <(gb_environment_keys)
}

upgrade_source_arguments() {
    local kind="$1" part
    local -a parts=(src/lib/core.sh src/lib/config.sh src/lib/deployment.sh src/lib/systemd.sh)
    if [[ "$kind" == management ]]; then
        parts+=(src/lib/dashboard.sh src/lib/management-release.sh src/bin/getbible-management-release
            src/lib/upgrades.sh src/bin/getbible-upgrades getbible.sh src/systemd/getbible-image-update.service.tmpl
            src/nginx/dashboard.conf.tmpl src/bin/getbible-notify src/bin/getbible-logrotate-hook src/lib/logs.sh src/lib/telegram.sh)
    else
        parts+=(src/lib/endpoint.sh src/lib/transactions.sh src/lib/nginx.sh src/lib/registry.sh src/lib/pages.sh
            src/lib/docs.sh src/lib/access.sh src/nginx/endpoint-http.conf.tmpl src/nginx/http.conf.tmpl
            src/nginx/site.conf.tmpl src/nginx/snippets src/docs-site img)
        case "$kind" in
            runtime) parts+=(src/types/runtime src/lib/resources.sh src/bin/getbible-resources) ;;
            mcp) parts+=(src/types/mcp src/lib/mcp.sh src/lib/resources.sh src/bin/getbible-resources
                    src/systemd/getbible-mcp.service.tmpl src/types/runtime/templates/socket.tmpl src/nginx/mcp.conf.tmpl) ;;
            static) parts+=(src/types/static src/lib/sync.sh src/bin/getbible-sync src/bin/getbible-export-tree) ;;
        esac
    fi
    for part in "${parts[@]}"; do printf '%s\n' --source "$part"; done
}

# Compare generated documentation using the normal renderer. Custom/repository
# content remains operator-owned; no scripture file is opened or traversed.
upgrade_docs_match() {
    local domain="$1" only="${2:-}" kind label output
    kind="$(ep_get "$domain" TYPE)"
    [[ "$kind" != mcp ]] || return 0
    output="$(mktemp "$(gb_tmpdir)/upgrade-docs.XXXXXXXX")" || return 1
    while IFS= read -r label; do
        [[ -n "$label" && ( -z "$only" || "$only" == "$label" ) ]] || continue
        if [[ "$(pages_docs_source "$domain" "$label")" == generated ]]; then
            "type_${kind}_render_endpoint_docs" "$domain" "$label" "$output" || return 1
            cmp -s "$output" "$(pages_endpoint_dir "$domain" "$label")/index.html" || return 1
        fi
        if [[ "$(pages_openapi_source "$domain" "$label")" == generated ]]; then
            "type_${kind}_render_openapi" "$domain" "$label" "$output" || return 1
            cmp -s "$output" "$(pages_endpoint_dir "$domain" "$label")/openapi.json" || return 1
        fi
    done < <(pages_endpoints "$domain")
    ep_load "$domain" || return 1
    if ! pages_has_root_endpoint "$domain" && [[ "$(pages_domain_docs_source "$domain")" == generated ]]; then
        "type_${kind}_render_docs" "$output" || return 1
        cmp -s "$output" "$(ep_www_dir "$domain")/index.html" || return 1
    fi
    return 0
}

# Compare rendered static configuration, not corpus contents. This permits a
# current installation predating the per-target journal to be adopted as a no-op.
upgrade_static_matches() {
    local domain="$1" stage label unit file relative helper
    stage="$(mktemp -d "$(gb_tmpdir)/upgrade-static.XXXXXXXX")" || return 1
    for helper in getbible-sync getbible-export-tree; do
        cmp -s "$GB_TOOLS/$helper" "$GB_LIBEXEC/$helper" || return 1
    done
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        sync_render_version "$domain" "$label" "$stage" || return 1
        unit="$(sync_unit "$domain" "$label")"
        cmp -s "$stage/$unit.service" "$GB_SYSTEMD/$unit.service" || return 1
        cmp -s "$stage/$unit.timer" "$GB_SYSTEMD/$unit.timer" || return 1
    done < <(ep_versions "$domain")
    upgrade_docs_match "$domain" || return 1
    ep_load "$domain" || return 1
    nginx_render_global "$stage/nginx" && nginx_render_endpoint "$stage/nginx" || return 1
    while IFS= read -r -d '' file; do
        relative="${file#"$stage/nginx/"}"
        [[ "$relative" != .tls-* ]] || continue
        cmp -s "$file" "$GB_NGINX/$relative" || return 1
    done < <(find "$stage/nginx" -type f -print0)
}

upgrade_socket_ready() {
    [[ -n "$1" && -S "$1" ]] || return 1
    curl --silent --fail --max-time 3 --unix-socket "$1" http://localhost/readyz >/dev/null
}

# One subprocess isolates the registry/manifest globals used by each driver.
upgrade_describe() (
    local id="$1" kind domain='' label='' selected='' app='' app_hash='' generation='' release='' expected='' fingerprint='' serving=unknown matches=false value extra phase resource_values variable key
    local history_schema incoming_schema installed_schema=0 pending_reason=''
    local -a args=() sources=() row_args=()
    kind="${id%%/*}"
    if [[ "$kind" != management ]]; then
        domain="${id#*/}"; domain="${domain%%/*}"
        gb_valid_domain "$domain" && ep_exists "$domain" || return 1
        [[ "$(ep_get "$domain" ENABLED true)" == true ]] || return 1
        endpoint_source_type "$kind" || return 1
        ep_load "$domain" || return 1
        args+=(--record-file "domain=$(ep_conf "$domain")")
    fi
    mapfile -t sources < <(upgrade_source_arguments "$kind")
    args+=("${sources[@]}")
    case "$kind" in
        management)
            value="$(dashboard_release_manifest)" || return 1
            app_hash="$(printf '%s' "$value" | "$GB_PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')" || return 1
            history_schema="$(management_release schema --db "$GB_VAR/telemetry/traffic.sqlite3")" || return 1
            incoming_schema="$(management_release schema --source "$GB_REPO_DIR")" || return 1
            generation="$(management_release current)" || return 1
            if [[ -n "$generation" ]]; then
                expected="$(management_release status)" || return 1
                installed_schema="$(printf '%s' "$expected" | "$GB_PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("telemetry_schema") or 0)')" || return 1
                phase="$(printf '%s' "$expected" | "$GB_PYTHON" -c 'import json,sys; p=json.load(sys.stdin); print(p.get("phase", "pending") if p.get("integrity")=="valid" else "invalid")')" || return 1
                expected="$(printf '%s' "$expected" | "$GB_PYTHON" -c 'import json,sys; print((json.load(sys.stdin).get("release") or {}).get("fingerprint", ""))')" || return 1
                if [[ "$phase" == current && "$expected" == "$app_hash" ]]; then matches=true; fi
                if [[ "$matches" == true && "$(gb_global DASHBOARD_ENABLED false)" == true ]] && ! dashboard_route_matches; then matches=false; fi
            fi
            # Type=exec acknowledges execution, not a successful database open.
            # A restarting collector can briefly be active with unusable history.
            # Schema preparation is required even when code and settings match;
            # never hash the mutable stored schema into the desired fingerprint.
            if [[ "$history_schema" != "$incoming_schema" ]]; then
                matches=false
                pending_reason="Traffic history schema $history_schema requires preparation for schema $incoming_schema"
            fi
            if ! sd_available; then serving=offline
            elif [[ "$installed_schema" != 0 && "$history_schema" == "$installed_schema" ]] && sd_is_active getbible-telemetry.service; then
                serving=ready
                if [[ "$(gb_global DASHBOARD_ENABLED false)" == true ]] && ! dashboard_health >/dev/null 2>&1; then serving=unavailable; fi
            else serving=unavailable; fi
            ;;
        runtime)
            label="${id##*/}"
            gb_valid_endpoint_label "$label" && ep_version_exists "$domain" "$label" || return 1
            [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || return 1
            ep_version_load "$domain" "$label" || return 1
            selected="$(ep_version_get "$domain" "$label" PYTHON_VERSION)"
            if gb_is_docker && [[ "$selected" == *.*.* ]]; then selected="${selected%.*}"; fi
            selected="$(py_resolve_version "$selected")" || return 1
            app="$(rt_implementation "$EP_KIND" "$(rt_app_version "$domain" "$label")")" || return 1
            app_hash="$(py_inputs_hash "$app" "$selected")" || return 1
            py_bundle_validate "$app" "$selected" "$app_hash" || return 1
            args+=(--record-file "endpoint=$(ep_version_conf "$domain" "$label")" --override "endpoint.PYTHON_VERSION=$selected")
            generation="$(rt_active_generation "$domain" "$label")"
            release="$(py_current_release "$(rt_root "$domain" "$label")")"
            rt_manifest_load "$EP_KIND" "$(rt_app_version "$domain" "$label")" || return 1
            resources_context "$domain" "$label" || return 1
            # Effective resource choices are stable allocation values, never
            # transient memory usage or a scan of the local scripture tree.
            expected="$(rt_deployment_inputs "$domain" "$label" "$release")" || return 1
            resource_values=''
            for key in WORKERS THREADS MEMORY_HIGH MEMORY_MAX WARM_TRANSLATIONS SEARCH_MAX_CONCURRENT \
                EXPENSIVE_CONCURRENT TRANSLATION_CACHE_LIMIT SEARCH_CORPUS_LIMIT REFERENCE_CACHE_LIMIT CHAPTER_CACHE_LIMIT \
                CPU_QUOTA TASKS_MAX NOFILE MEMORY_CACHE_TTL CACHE_TTL_JITTER SHARED_CORPUS_LIMIT \
                SHARED_CORPUS_BYTES CHAPTER_CACHE_BYTES TRANSLATION_CACHE_BYTES WORKERS_MIN WORKERS_MAX; do
                variable="RES_$key"
                resource_values+="$key=${!variable};"
            done
            args+=(--value "resources=$resource_values")
            if [[ -n "$generation" && -x "$release/.venv/bin/python" && "$(py_release_inputs "$release")" == "$app_hash" \
                && "$(ep_version_get "$domain" "$label" PYTHON_VERSION)" == "$selected" \
                && -f "$generation/.inputs" && "$(cat "$generation/.inputs")" == "$expected" ]]; then matches=true; fi
            if [[ "$matches" == true ]] && ! upgrade_docs_match "$domain" "$label"; then matches=false; fi
            if ! sd_available; then serving=offline
            elif upgrade_socket_ready "$(rt_socket "$domain" "$label")"; then serving=ready
            else serving=unavailable; fi
            ;;
        mcp)
            selected="$(ep_get "$domain" MCP_PYTHON_VERSION auto)"
            if gb_is_docker; then selected="$(mcp_update_python "$selected")"; else selected="$(py_resolve_version "$selected")"; fi
            [[ -n "$selected" ]] || return 1
            app_hash="$(py_inputs_hash mcp "$selected")" || return 1
            mcp_bundle_preflight "$selected" "$app_hash" || return 1
            args+=(--override "domain.MCP_PYTHON_VERSION=$selected")
            generation="$(mcp_active "$domain")"
            release="$(py_current_release "$(mcp_root "$domain")")"
            expected="$(mcp_deployment_inputs "$domain" "$release")" || return 1
            extra="$(ep_get "$domain" MCP_ENV_FILE)"
            [[ -z "$extra" ]] || args+=(--value "environment_hash=$(gb_sha256_file "$extra")")
            if [[ -n "$generation" && -x "$release/.venv/bin/python" && "$(py_release_inputs "$release")" == "$app_hash" \
                && "$(ep_get "$domain" MCP_PYTHON_VERSION)" == "$selected" \
                && -f "$generation/.inputs" && "$(cat "$generation/.inputs")" == "$expected" ]]; then matches=true; fi
            if ! sd_available; then serving=offline
            elif [[ -n "$generation" ]] && upgrade_socket_ready "$(mcp_socket "$generation")"; then serving=ready
            else serving=unavailable; fi
            ;;
        static)
            while IFS= read -r label; do
                [[ -n "$label" ]] || continue
                args+=(--record-file "$label=$(ep_version_conf "$domain" "$label")")
            done < <(ep_versions "$domain")
            label=''
            if upgrade_static_matches "$domain"; then matches=true; fi
            generation="$(nginx_site_file "$domain")"
            [[ ! -f "$generation" ]] || generation="$(gb_sha256_file "$generation")"
            if ! sd_available; then serving=offline
            elif sd_is_active nginx.service && [[ -e "$(nginx_enabled_file "$domain")" ]]; then serving=ready
            else serving=unavailable; fi
            ;;
        *) return 1 ;;
    esac
    extra="$(upgrade_effective_values "$kind" "${EP_KIND:-}")" || return 1
    while IFS= read -r value; do [[ -z "$value" ]] || args+=(--value "$value"); done <<< "$extra"
    args+=(--value "application=$app_hash" --value "mode=$(gb_execution_mode)")
    fingerprint="$(upgrade_helper fingerprint --root "$GB_REPO_DIR" "${args[@]}")" || return 1
    row_args=(--target "$id" --kind "$kind" --domain "$domain" --label "$label" --fingerprint "$fingerprint" --generation "$generation" --serving "$serving")
    [[ -z "$pending_reason" ]] || row_args+=(--reason "$pending_reason")
    [[ "$matches" != true ]] || row_args+=(--matches)
    upgrade_helper row "${row_args[@]}"
)

upgrade_inventory() {
    local domain kind label id ordered=''
    local -a targets=(management)
    # The allocator already orders shrinking runtime domains before growth.
    # Ordering never expands the operator's selected set.
    if declare -F resources_plan >/dev/null; then ordered="$(resources_plan --format domains)" || ordered=''; fi
    while IFS= read -r domain; do
        [[ -n "$domain" && "$(ep_get "$domain" ENABLED true)" == true ]] || continue
        kind="$(ep_get "$domain" TYPE)"
        case "$kind" in
            runtime)
                while IFS= read -r label; do
                    [[ -n "$label" && "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
                    targets+=("runtime/$domain/$label")
                done < <(ep_versions "$domain") ;;
            static|mcp) targets+=("$kind/$domain") ;;
            *) gb_warn "Unsupported domain type $kind in upgrade inventory."; return 1 ;;
        esac
    done < <({ printf '%s\n' "$ordered"; ep_list; } | awk 'NF && !seen[$0]++')
    for id in "${targets[@]}"; do
        if ! upgrade_describe "$id"; then
            kind="${id%%/*}"; domain="${id#*/}"; domain="${domain%%/*}"; label="${id##*/}"
            [[ "$kind" != management ]] || domain=''
            [[ "$kind" == runtime ]] || label=''
            upgrade_helper row --target "$id" --kind "$kind" --domain "$domain" --label "$label" \
                --error 'Cannot prepare this target: inspect the reported configuration, Python bundle or management state error.' || return 1
        fi
    done
}

upgrade_plan() {
    local inventory
    inventory="$(mktemp "$(gb_tmpdir)/upgrade-inventory.XXXXXXXX")" || return 1
    upgrade_inventory > "$inventory" || return 1
    upgrade_helper plan --inventory "$inventory" --version "$(cat "$GB_REPO_DIR/VERSION")"
}

# Do not silently redeploy unselected neighbours to make a resource reduction
# fit. Preflight still accounts for live/draining generations; a required
# allocation change is reported so it can be included in the operator's scope.
upgrade_admit_scope() {
    # Account for real live/draining ceilings. Unlike resources_reconcile,
    # this does not mutate other domains to make the selected update fit.
    if ! resources_preflight "$1"; then
        gb_warn 'The selected upgrade cannot fit the current allocation and overlap. Previous workers remain serving. Review Resources > Allocation and retry after draining; no unselected domain was redeployed.'
        return 1
    fi
}

upgrade_apply_target() {
    local id="$1" force="$2" kind domain label
    # shellcheck disable=SC2034 # The sourced lifecycle implementations consume these overrides.
    local GB_LOCAL_APPLY=true GB_RESOURCE_RECONCILING=true GB_MANAGEMENT_FORCE="$force"
    kind="${id%%/*}"; domain="${id#*/}"; domain="${domain%%/*}"; label="${id##*/}"
    case "$kind" in
        management)
            gb_global_init && gb_ensure_base_groups && gb_ensure_base_dirs || return 1
            tg_install_helper && logs_render_rotation || return 1
            infrastructure_update || return 1
            if [[ "$(gb_global DASHBOARD_ENABLED false)" == true ]]; then dashboard_route_apply || return 1; fi ;;
        runtime)
            endpoint_source_type runtime || return 1
            upgrade_admit_scope "$domain" || return 1
            local RT_APPLY_LABELS=" $label " RT_ONLY_LABEL="$label" RT_FORCE_DEPLOY="$force" RT_FORCE_BUILD="$force"
            if gb_is_docker; then
                rt_update_transaction "$domain" '' "$label"
            else
                rt_update_transaction "$domain" "$(ep_version_get "$domain" "$label" PYTHON_VERSION)" "$label"
            fi ;;
        mcp)
            endpoint_source_type mcp || return 1
            upgrade_admit_scope "$domain" || return 1
            local MCP_FORCE_DEPLOY="$force"
            if gb_is_docker; then
                mcp_image_update "$domain"
            else
                mcp_cli configure "$domain"
            fi ;;
        static) endpoint_apply "$domain" ;;
        *) return 1 ;;
    esac
}

upgrade_apply_selection() {
    local plan="$1" selection="$2" force="$3" id before after fingerprint result=0 failed=0 pending state version desired detail domain reviewed
    local complete_scope="${4:-true}"
    local GB_LOCAL_APPLY=true
    before="$(gb_tmpdir)/upgrade-before.json"; after="$(gb_tmpdir)/upgrade-after.json"
    version="$(cat "$GB_REPO_DIR/VERSION")" || return 1
    state="$(update_image_state)"
    if gb_is_docker && [[ "$GB_DRY_RUN" != true ]]; then
        cfg_set "$state" DESIRED_VERSION "$version" && cfg_set "$state" STATUS updating || return 1
    fi
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ "$GB_DRY_RUN" == true ]]; then gb_log "Would upgrade $id (force=$force)."; continue; fi
        upgrade_describe "$id" > "$before" || { failed=$((failed + 1)); continue; }
        fingerprint="$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["desired_fingerprint"])' "$before")" || return 1
        reviewed="$("$GB_PYTHON" -c 'import json,sys; p=json.load(open(sys.argv[1])); print(next(r["desired_fingerprint"] for r in p["targets"] if r["id"]==sys.argv[2]))' "$plan" "$id")" || return 1
        if [[ "$fingerprint" != "$reviewed" ]]; then
            failed=$((failed + 1))
            detail='Target implementation/settings changed after plan review; refresh the plan before applying.'
            upgrade_helper record --row "$before" --outcome failed --owner "$$" --detail "$detail" || return 1
            gb_warn "$id: $detail"
            continue
        fi
        upgrade_helper record --row "$before" --outcome updating --owner "$$" || return 1
        gb_step "Upgrading $id"
        result=0; detail=''
        upgrade_apply_target "$id" "$force" || result=$?
        if ! upgrade_describe "$id" > "$after"; then
            cp "$before" "$after" || return 1
            result=1; detail='Post-update inspection failed; desired target remains pending.'
        fi
        if (( result == 0 )); then
            # Release paths may change, but desired implementation/configuration
            # must still match the intent inspected before activation.
            if [[ "$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["desired_fingerprint"])' "$after")" == "$fingerprint" ]] \
                && upgrade_helper record --row "$after" --outcome applied --owner "$$"; then
                tg_notify ok "Upgrade target applied: $id" 'The selected implementation and serving generation passed verification.'
                if [[ "$id" == runtime/* ]] && declare -F resources_plan >/dev/null && sd_available; then
                    domain="${id#*/}"; domain="${domain%%/*}"
                    resources_plan --wait-drain "$domain" || gb_warn 'Previous workers are still draining; later target admission will retain its safety limits.'
                fi
                continue
            fi
            result=1; detail='Serving code/configuration did not confirm the desired upgrade.'
        fi
        failed=$((failed + 1))
        detail="${detail:-Target upgrade failed; inspect its service or management journal. Serving availability is reported independently.}"
        upgrade_helper record --row "$after" --outcome failed --owner "$$" --detail "$detail" || return 1
        tg_notify fail "Upgrade target incomplete: $id" "$detail"
    done < "$selection"
    [[ "$GB_DRY_RUN" != true ]] || return 0
    upgrade_plan > "$plan" || return 1
    # Adopt verified pre-journal installations without redeploying them. This
    # writes only upgrade metadata; their processes and corpus are untouched.
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        upgrade_describe "$id" > "$after" || return 1
        upgrade_helper record --row "$after" --outcome verified --owner "$$" || return 1
    done < <("$GB_PYTHON" -c 'import json,sys; p=json.load(open(sys.argv[1])); print("\n".join(r["id"] for r in p["targets"] if r["status"]=="current" and r["outcome"]=="untracked"))' "$plan")
    upgrade_plan > "$plan" || return 1
    pending="$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"])' "$plan")" || return 1
    desired=current
    (( pending == 0 )) || desired=partial
    (( failed == 0 )) || desired=failed
    if gb_is_docker; then
        cfg_set "$state" UPDATED_AT "$(gb_timestamp)" && cfg_set "$state" STATUS "$desired" || return 1
        if [[ "$desired" == current ]]; then
            cfg_set "$state" APPLIED_VERSION "$version" && cfg_set "$state" LAST_ERROR '' || return 1
        else
            cfg_set "$state" LAST_ERROR "$pending target(s) remain pending; $failed selected target(s) failed. Inspect getbible update --plan." || return 1
        fi
    fi
    gb_log "Upgrade result: $desired; $pending target(s) pending; $failed selected target(s) failed."
    (( failed == 0 )) || return 1
    [[ "$complete_scope" != true || "$pending" == 0 ]]
}

upgrade_menu() {
    local plan selected id expected
    local -a items=() args=() selection=()
    plan="$(gb_tmpdir)/upgrade-menu.json"
    upgrade_plan > "$plan" || return 1
    mapfile -t items < <(upgrade_helper render --plan "$plan" --format checklist)
    (( ${#items[@]} )) || { ui_msg 'Upgrades' 'No selectable targets. Inspect getbible update --plan for blockers.'; return 0; }
    selected="$(ui_checklist 'Upgrade targets' 'Changed targets are selected. Static data sync is separate. Uncheck targets to leave them running; enter none in the plain terminal to skip everything.' "${items[@]}")" || return 0
    [[ "$selected" != none ]] || selected=''
    if [[ -z "$selected" ]]; then gb_log 'No targets selected; no upgrade was applied.'; return 0; fi
    IFS=' ' read -r -a selection <<< "$selected"
    expected="$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$plan")" || return 1
    for id in "${selection[@]}"; do [[ -z "$id" ]] || args+=(--target "$id"); done
    ui_run 'Apply selected upgrades' upgrade_cli --expected-plan "$expected" "${args[@]}"
}

upgrade_cli() {
    local plan_only=false json=false force=false retry=false interactive=false domain='' expected='' plan selection item explicit=false
    local -a requested=() args=()
    while (( $# )); do
        case "$1" in
            --plan) plan_only=true; shift ;;
            --json) json=true; shift ;;
            --force) force=true; shift ;;
            --retry) retry=true; shift ;;
            --select) interactive=true; shift ;;
            --all) shift ;;
            --target|--expected-plan)
                [[ $# -ge 2 && -n "$2" ]] || { gb_warn "$1 requires a value"; return 1; }
                if [[ "$1" == --target ]]; then requested+=("$2"); explicit=true; else expected="$2"; fi
                shift 2 ;;
            --targets)
                [[ $# -ge 2 ]] || return 1
                explicit=true
                if [[ -n "$2" ]]; then IFS=',' read -r -a requested <<< "$2"; fi
                shift 2 ;;
            --*) gb_warn "Unsupported upgrade option: $1"; return 1 ;;
            *) [[ -z "$domain" ]] && gb_valid_domain "$1" || { gb_warn 'update accepts one domain or explicit --target values'; return 1; }; domain="$1"; shift ;;
        esac
    done
    [[ -z "$domain" || "$explicit" != true ]] || { gb_warn 'Choose a domain or explicit targets, not both.'; return 1; }
    gb_require_root || return 1
    gb_environment_validate || return 1
    if [[ "$interactive" == true || ( "$plan_only" != true && "$explicit" != true && -z "$domain" && "$GB_YES" != true && -t 0 && -t 1 ) ]]; then
        upgrade_menu; return "$?"
    fi
    [[ "$plan_only" == true ]] || gb_management_lock || return "$?"
    plan="$(mktemp "$(gb_tmpdir)/upgrade-plan.XXXXXXXX")" || return 1
    upgrade_plan > "$plan" || return 1
    if [[ "$plan_only" == true ]]; then
        if [[ "$json" == true ]]; then cat "$plan"; else upgrade_helper render --plan "$plan" --format text; fi
        return 0
    fi
    args=(--plan "$plan" --domain "$domain" --expected-plan "$expected")
    [[ "$force" != true ]] || args+=(--force)
    [[ "$retry" != true ]] || args+=(--retry)
    [[ "$explicit" != true ]] || args+=(--explicit)
    for item in "${requested[@]}"; do args+=(--target "$item"); done
    selection="$(mktemp "$(gb_tmpdir)/upgrade-selection.XXXXXXXX")" || return 1
    upgrade_helper select "${args[@]}" > "$selection" || return 1
    local status=0 complete_scope=true
    [[ "$explicit" != true && -z "$domain" && "$retry" != true ]] || complete_scope=false
    if [[ "$explicit" == true && ${#requested[@]} == 0 ]]; then
        gb_log 'No targets selected; no upgrade state or services were changed.'
    else
        upgrade_apply_selection "$plan" "$selection" "$force" "$complete_scope" || status=$?
    fi
    if [[ "$json" == true ]]; then cat "$plan"; else upgrade_helper render --plan "$plan" --format text; fi
    return "$status"
}
