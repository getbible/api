#!/usr/bin/env bash
# Update the manager checkout, or separately apply its files to domains.

[[ -n "${GB_UPDATE_LOADED:-}" ]] && return 0
GB_UPDATE_LOADED=1

update_repo_state() {
    local dirty="" commit="unknown"
    if gb_have git && [[ -e "$GB_REPO_DIR/.git" ]]; then
        commit="$(git -C "$GB_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        dirty="$(git -C "$GB_REPO_DIR" status --porcelain 2>/dev/null | head -5 || true)"
    fi
    printf '%s\n%s\n' "$commit" "$dirty"
}

update_pull() {
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
    # Use Git's saved remote and SSH configuration, including the release key.
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
