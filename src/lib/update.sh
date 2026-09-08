#!/usr/bin/env bash
# Update every endpoint after a git pull: re-render, reinstall what changed,
# rebuild runtime releases whose inputs changed, one nginx reload.

[[ -n "${GB_UPDATE_LOADED:-}" ]] && return 0
GB_UPDATE_LOADED=1

update_repo_state() {
    local dirty="" commit="unknown"
    if gb_have git && [[ -d "$GB_REPO_DIR/.git" ]]; then
        commit="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        dirty="$(git -C "$GB_REPO_DIR" status --porcelain 2>/dev/null | head -5 || true)"
    fi
    printf '%s\n%s\n' "$commit" "$dirty"
}

update_pull() {
    gb_have git || gb_die "git is not installed."
    [[ -d "$GB_REPO_DIR/.git" ]] || gb_die "$GB_REPO_DIR is not a git checkout."
    local branch
    branch="$(git -C "$GB_REPO_DIR" rev-parse --abbrev-ref HEAD)"
    if [[ -n "$(git -C "$GB_REPO_DIR" status --porcelain)" ]]; then
        gb_die "The checkout has local modifications; commit or discard them before pulling."
    fi
    gb_step "Pulling $branch (fast-forward only)"
    git -C "$GB_REPO_DIR" pull --ff-only origin "$branch"
}

# Re-exec after pulling so the manager's functions, not just its templates,
# come from the new checkout. Retain the inherited management lock throughout.
update_pull_and_all() {
    update_pull || return 1
    gb_cleanup
    unset GB_TMP
    export GB_MANAGER_LOCKED=true
    exec "$GB_SELF" update
}

update_all() {
    local commit dirty failures=0 count=0 domain
    commit="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    dirty="$(git -C "$GB_REPO_DIR" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" && "$GB_YES" != true ]]; then
        gb_warn "The checkout has local modifications; the update will use them as they are."
    fi
    exec 8>"$GB_VAR/update.lock"
    flock -n 8 || gb_die "Another update is running."
    gb_step "Updating every domain from commit $commit"
    tg_notify start "Update started" "getbible.sh update at commit $commit on $(ep_list | wc -l) domain(s)."
    logs_render_rotation
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        count=$((count + 1))
        gb_step "Updating $domain"
        if ! endpoint_apply "$domain"; then
            failures=$((failures + 1))
            gb_warn "Update failed for $domain"
        fi
    done < <(ep_list)
    if [[ -n "${GB_CLOUDFLARE_LOADED:-}" ]]; then
        cloudflare_refresh_ips_if_enabled || true
    fi
    if (( failures == 0 )); then
        tg_notify ok "Update complete" "$count domain(s) are at commit $commit."
        gb_log "Update complete: $count domain(s) at $commit."
    else
        tg_notify fail "Update finished with failures" "$failures of $count domain(s) failed at commit $commit. Check getbible.sh status."
        gb_warn "Update finished with $failures failure(s)."
        return 1
    fi
}
