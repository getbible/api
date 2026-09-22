#!/usr/bin/env bash
# Update the manager checkout, or separately apply its files to domains.

[[ -n "${GB_UPDATE_LOADED:-}" ]] && return 0
GB_UPDATE_LOADED=1
# shellcheck source=upgrades.sh
source "${GB_LIB:-$(dirname -- "${BASH_SOURCE[0]}")}/upgrades.sh"

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

# The same planner/target transactions serve image, CLI, menu and dashboard.
# An image's --force means reconcile an already applied image, not rebuild
# every unchanged service. Operators use `update --force` to redeploy explicitly.
update_image() {
    gb_is_docker || { gb_warn 'Automatic image updates are only available in Docker.'; return 1; }
    [[ $# == 0 || ( $# == 1 && "$1" == --force ) ]] || { gb_warn 'image-update [--force]'; return 1; }
    local GB_YES=true
    upgrade_cli --all
}

update_system() { upgrade_cli "$@"; }

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

update_domain() { upgrade_cli "$1"; }
update_all() { upgrade_cli --all "$@"; }
