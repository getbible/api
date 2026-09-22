#!/usr/bin/env bash
# Update the manager checkout, or separately apply its files to domains.

[[ -n "${GB_UPDATE_LOADED:-}" ]] && return 0
GB_UPDATE_LOADED=1

update_image_state() { printf '%s/image-update.conf\n' "$GB_STATE"; }

update_image_status() {
    local state
    state="$(update_image_state)"
    printf 'Image release: %s; applied: %s; update: %s\n' \
        "$(cat "$GB_REPO_DIR/VERSION")" "$(cfg_get "$state" APPLIED_VERSION pending)" "$(cfg_get "$state" STATUS pending)"
    local error
    error="$(cfg_get "$state" LAST_ERROR)"
    [[ -z "$error" ]] || printf 'Update attention: %s\n' "$error"
}

update_image_failed() {
    local state="$1" version="$2" error="$3"
    cfg_set "$state" LAST_ERROR "$error" || return 1
    cfg_set "$state" UPDATED_AT "$(gb_timestamp)" || return 1
    cfg_set "$state" STATUS failed || return 1
    tg_notify fail 'Image update incomplete' "Release $version: $error Retry with getbible update after resolving the reported cause."
    gb_warn "$error Run getbible update to retry."
    return 1
}

# A replacement image reconciles the saved installation after its existing
# services start. Numbered image releases are immutable; a successful unchanged
# release needs no deployment work. Interrupted/failed updates remain retryable.
update_image() {
    gb_is_docker || { gb_warn 'Automatic image updates are only available in Docker.'; return 1; }
    [[ $# == 0 || $# == 1 && "$1" == --force ]] || { gb_warn 'image-update [--force]'; return 1; }
    local version state domain failures=0 error="" count=0
    local GB_LOCAL_APPLY=true GB_INFRASTRUCTURE_UPDATED=true
    version="$(cat "$GB_REPO_DIR/VERSION")" || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { gb_warn 'The image release number is invalid.'; return 1; }
    state="$(update_image_state)"
    if [[ "${1:-}" != --force && "$(cfg_get "$state" APPLIED_VERSION)" == "$version" && "$(cfg_get "$state" STATUS)" == current ]]; then
        gb_log "Image release $version is already applied."
        return 0
    fi
    [[ "$GB_DRY_RUN" != true ]] || { gb_log "(dry-run) would apply image release $version to the saved installation."; return 0; }
    gb_ensure_dir "$GB_STATE" 0755 || return 1
    cfg_set "$state" DESIRED_VERSION "$version" || return 1
    cfg_set "$state" STATUS updating || return 1
    cfg_set "$state" LAST_ERROR '' || return 1
    tg_notify start 'Image update started' "Applying installed image release $version. Existing API generations remain available during preparation."
    if ! gb_system_init; then
        update_image_failed "$state" "$version" 'Management initialization failed; inspect the image-update journal.'
        return 1
    fi
    if ! infrastructure_update; then
        if [[ "${GB_INFRASTRUCTURE_TELEMETRY_FAILED:-false}" != true ]]; then
            update_image_failed "$state" "$version" 'Management service update failed; inspect the image-update and telemetry journals.'
            return 1
        fi
        failures=$((failures + 1))
        error='Telemetry update failed; inspect the telemetry journal.'
    fi
    # Individual domains have independent transactions. One failed candidate
    # must not prevent the remaining saved domains from receiving the release.
    while IFS= read -r domain; do
        [[ -n "$domain" && "$(ep_get "$domain" ENABLED true)" == true ]] || continue
        count=$((count + 1))
        if [[ "$(ep_get "$domain" TYPE)" == runtime ]]; then
            if ! endpoint_source_type runtime; then
                update_image_failed "$state" "$version" 'The image runtime implementation could not be loaded.'
                return 1
            fi
            if rt_image_update "$domain"; then continue; fi
        elif [[ "$(ep_get "$domain" TYPE)" == mcp ]]; then
            endpoint_source_type mcp || return 1
            if mcp_image_update "$domain"; then continue; fi
        elif endpoint_apply "$domain"; then
            continue
        fi
        failures=$((failures + 1))
        error="${error:+$error }Update failed for $domain; its previous deployment was retained."
    done < <(ep_list)
    if sd_available; then
        if ! sd_is_active getbible-telemetry.service; then
            failures=$((failures + 1))
            error="${error:+$error }Telemetry is not running."
        fi
        if [[ "$(gb_global DASHBOARD_ENABLED false)" == true ]] && ! dashboard_wait_current; then
            failures=$((failures + 1))
            error="${error:+$error }The dashboard did not confirm its running release."
        fi
    fi
    cfg_set "$state" UPDATED_AT "$(gb_timestamp)" || return 1
    if (( failures != 0 )); then
        update_image_failed "$state" "$version" "$error"
        return 1
    fi
    cfg_set "$state" APPLIED_VERSION "$version" || return 1
    cfg_set "$state" STATUS current || return 1
    tg_notify ok 'Image update complete' "Image release $version applied to management services and $count domain(s)."
    gb_log "Image release $version is applied to management services and $count domain(s)."
}

update_system() {
    if gb_is_docker; then update_image --force; else update_all; fi
}

update_repo_state() {
    local dirty="" commit="unknown"
    if gb_have git && [[ -e "$GB_REPO_DIR/.git" ]]; then
        commit="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        dirty="$(git -C "$GB_REPO_DIR" status --porcelain 2>/dev/null | head -5 || true)"
    fi
    printf '%s\n%s\n' "$commit" "$dirty"
}

update_pull() {
    if gb_is_docker; then
        gb_warn "The Docker manager is supplied by its image. On the host run: docker compose pull && docker compose up -d"
        return 1
    fi
    gb_have git || { gb_warn "git is not installed."; return 1; }
    local root branch dirty upstream remote ref
    root="$(git -C "$GB_REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
        gb_warn "$GB_REPO_DIR is not a Git checkout. See docs/INSTALL.md to install using Git."
        return 1
    }
    [[ "$(cd -- "$root" && pwd -P)" == "$GB_REPO_DIR" ]] || {
        gb_warn "The manager must be at the root of its own Git checkout."
        return 1
    }
    branch="$(git -C "$GB_REPO_DIR" symbolic-ref --quiet --short HEAD)" || {
        gb_warn "The checkout has a detached HEAD; switch to a branch with an upstream before self-update."
        return 1
    }
    dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$GB_REPO_DIR" status --porcelain --untracked-files=all)" || return 1
    if [[ -n "$dirty" ]]; then
        gb_warn "The checkout has local modifications or untracked files; commit or move them before self-update."
        return 1
    fi
    upstream="$(git -C "$GB_REPO_DIR" for-each-ref --format='%(upstream)' "refs/heads/$branch")" || return 1
    remote="$(git -C "$GB_REPO_DIR" config --get "branch.$branch.remote")" || remote=""
    ref="$(git -C "$GB_REPO_DIR" config --get-all "branch.$branch.merge")" || ref=""
    if [[ -z "$upstream" || -z "$remote" || "$remote" == . || "$ref" != refs/heads/* || "$ref" == *$'\n'* ]]; then
        gb_warn "Branch $branch needs one remote upstream branch; configure it before self-update (see docs/UPDATING.md)."
        return 1
    fi
    if [[ "$GB_DRY_RUN" == true ]]; then
        gb_log "(dry-run) would fetch $remote $ref and fast-forward the manager checkout on $branch."
        return 0
    fi
    gb_step "Fetching manager changes from $remote $ref (fast-forward only)"
    # Use Git's saved remote and root's SSH configuration (the deploy key).
    # Explicit fetch/merge also avoids an operator's pull.rebase preference.
    git -C "$GB_REPO_DIR" fetch -- "$remote" "$ref" || return 1
    git -C "$GB_REPO_DIR" merge --ff-only FETCH_HEAD
}

update_manager() {
    local before after
    before="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if ! update_pull; then
        [[ "$GB_DRY_RUN" == true ]] || tg_notify fail "Manager update failed" "The manager checkout could not be updated. Check the command output."
        return 1
    fi
    [[ "$GB_DRY_RUN" == true ]] && return 0
    after="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD)" || return 1
    if [[ "$before" == "$after" ]]; then
        gb_log "Manager is already up to date at $after."
    else
        tg_notify ok "Manager updated" "Manager source updated from $before to $after."
        gb_log "Manager source updated from $before to $after."
    fi
    gb_log "Run getbible.sh again to use this checkout. Applying it to hosted domains is a separate update action."
}

update_domain() {
    local domain="$1" reporting_failed=0
    if [[ "${GB_INFRASTRUCTURE_UPDATED:-false}" != true ]] && ! infrastructure_update; then
        [[ "${GB_INFRASTRUCTURE_TELEMETRY_FAILED:-false}" == true ]] || return 1
        reporting_failed=1
        gb_warn 'Telemetry is unavailable; continuing the independent API update.'
    fi
    if gb_is_docker && [[ "$(ep_get "$domain" TYPE)" == runtime ]]; then
        endpoint_source_type runtime
        rt_update "$domain" || return 1
    else
        endpoint_apply "$domain" || return 1
    fi
    return "$reporting_failed"
}

update_all() {
    local commit dirty failures=0 count=0 domain reporting_failed=false
    commit="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    dirty="$(git -C "$GB_REPO_DIR" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" && "$GB_YES" != true ]]; then
        gb_warn "The checkout has local modifications; the update will use them as they are."
    fi
    exec 8>"$GB_VAR/update.lock"
    flock -n 8 || gb_die "Another update is running."
    if ! infrastructure_update; then
        [[ "${GB_INFRASTRUCTURE_TELEMETRY_FAILED:-false}" == true ]] || return 1
        reporting_failed=true
        gb_warn 'Telemetry is unavailable; continuing the independent API updates.'
    fi
    local GB_INFRASTRUCTURE_UPDATED=true
    gb_step "Updating every domain from commit $commit"
    tg_notify start "Update started" "getbible.sh update at commit $commit on $(ep_list | wc -l) domain(s)."
    logs_render_rotation
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        count=$((count + 1))
        gb_step "Updating $domain"
        if ! update_domain "$domain"; then
            failures=$((failures + 1))
            gb_warn "Update failed for $domain"
        fi
    done < <(ep_list)
    if [[ -n "${GB_CLOUDFLARE_LOADED:-}" ]]; then
        cloudflare_refresh_ips_if_enabled || true
    fi
    if (( failures == 0 )) && [[ "$reporting_failed" == false ]]; then
        tg_notify ok "Update complete" "$count domain(s) are at commit $commit."
        gb_log "Update complete: $count domain(s) at $commit."
    else
        tg_notify fail "Update finished with failures" "$failures of $count domain(s) failed at commit $commit. Telemetry unavailable: $reporting_failed. Check getbible.sh status and dashboard status."
        gb_warn "Update finished with $failures failure(s)."
        [[ "$reporting_failed" == false ]] || gb_warn 'API updates finished, but telemetry still needs attention. Check dashboard status and the getbible-telemetry.service journal.'
        return 1
    fi
}
