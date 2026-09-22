#!/usr/bin/env bash
# Exercise the real self-update CLI against local repositories. Server helpers
# are stubs so these tests require neither root, nginx nor network access.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME='Update test' GIT_AUTHOR_EMAIL='update@example.test'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
CASE=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ ! -f "${OUTPUT:-}" ]] || cat "$OUTPUT" >&2
    exit 1
}

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

fixture() {
    CASE=$((CASE + 1))
    export GB_TEST_CASE="$T/case-$CASE"
    export GB_TEST_EVENTS="$GB_TEST_CASE/events"
    REMOTE="$GB_TEST_CASE/remote.git"
    SEED="$GB_TEST_CASE/seed"
    CHECKOUT="$GB_TEST_CASE/checkout"
    OUTPUT="$GB_TEST_CASE/output"
    mkdir -p "$SEED/src/lib"
    : > "$GB_TEST_EVENTS"
    git init -q --bare "$REMOTE"
    git init -q "$SEED"
    git -C "$SEED" checkout -q -b release
    cp "$ROOT/getbible.sh" "$SEED/getbible.sh"
    cp "$ROOT/src/lib/update.sh" "$SEED/src/lib/update.sh"
    cp "$ROOT/src/lib/upgrades.sh" "$SEED/src/lib/upgrades.sh"
    chmod +x "$SEED/getbible.sh"
    local lib
    for lib in platform ui config deployment registry resources users telegram nginx certs systemd logs access sync python docs pages endpoint; do
        : > "$SEED/src/lib/$lib.sh"
    done
    cat > "$SEED/src/lib/core.sh" <<'CORE'
GB_TEST_VERSION=old
GB_YES="${GB_YES:-false}"
GB_DRY_RUN="${GB_DRY_RUN:-false}"
GB_VAR="$GB_TEST_CASE/state"
GB_TMP="${GB_TMP:-$(mktemp -d "$GB_TEST_CASE/tmp.XXXXXX")}"
export GB_TMP
printf 'source:%s\n' "$GB_TEST_VERSION" >> "$GB_TEST_EVENTS"
gb_cleanup() { [[ ! -d "${GB_TMP:-}" ]] || rm -rf -- "$GB_TMP"; }
trap 'gb_cleanup' EXIT
gb_have() { command -v "$1" >/dev/null 2>&1; }
gb_log() { printf '%s\n' "$*" >&2; }
gb_step() { gb_log "$@"; }
gb_warn() { gb_log "$@"; }
gb_die() { gb_log "$@"; exit 1; }
gb_require_root() { :; }
gb_is_docker() { return 1; }
gb_environment_validate() { :; }
gb_environment_telegram() { :; }
gb_valid_domain() { [[ "$1" == api.example.test ]]; }
gb_management_lock() {
    printf 'lock\n' >> "$GB_TEST_EVENTS"
    mkdir -p "$GB_VAR"
    exec 7>"$GB_VAR/manage.lock"
    GB_MANAGER_LOCKED=true
}
test_server_action() { printf 'server:%s\n' "$*" >> "$GB_TEST_EVENTS"; }
gb_global_init() { test_server_action global-init; }
gb_ensure_base_groups() { test_server_action groups; }
gb_ensure_base_dirs() { test_server_action directories; }
tg_install_helper() { test_server_action telegram-helper; }
sync_install_tools() { test_server_action sync-tools; }
logs_render_rotation() { test_server_action log-rotation; }
infrastructure_ensure() { test_server_action infrastructure; }
infrastructure_update() { test_server_action infrastructure-update; }
tg_notify() { printf 'notify:%s\n' "$*" >> "$GB_TEST_EVENTS"; }
ep_exists() { [[ "$1" == api.example.test ]]; }
endpoint_apply() { printf 'apply:%s\n' "$1" >> "$GB_TEST_EVENTS"; }
CORE
    # Only deployment is replaced here; pull/manager helpers remain real.
    cat > "$SEED/src/lib/menu.sh" <<'MENU'
upgrade_cli() { printf 'apply:%s\n' "${1:-all}" >> "$GB_TEST_EVENTS"; }
MENU
    printf 'initial\n' > "$SEED/tracked.txt"
    git -C "$SEED" add .
    git -C "$SEED" commit -qm initial
    git -C "$SEED" remote add origin "$REMOTE"
    git -C "$SEED" push -q origin release
    git clone -q --branch release "$REMOTE" "$CHECKOUT"
    # Neither the remote name nor the local branch matches an assumed default.
    git -C "$CHECKOUT" remote rename origin deployment
    git -C "$CHECKOUT" branch -m installed
    BEFORE="$(git -C "$CHECKOUT" rev-parse HEAD)"
}

publish_update() {
    # Changing a sourced library also detects an unwanted re-exec after pulling.
    sed 's/GB_TEST_VERSION=old/GB_TEST_VERSION=new/' "$SEED/src/lib/core.sh" > "$SEED/src/lib/core.sh.new"
    mv "$SEED/src/lib/core.sh.new" "$SEED/src/lib/core.sh"
    printf 'new source\n' > "$SEED/tracked.txt"
    git -C "$SEED" add .
    git -C "$SEED" commit -qm 'new manager source'
    git -C "$SEED" push -q origin release
    AFTER="$(git -C "$SEED" rev-parse HEAD)"
}

run_cli() {
    : > "$GB_TEST_EVENTS"
    bash "$CHECKOUT/getbible.sh" "$@" > "$OUTPUT" 2>&1
}

assert_source_only() {
    if grep -Eq '^(server|apply):' "$GB_TEST_EVENTS"; then
        fail 'self-update invoked server installation or domain deployment'
    fi
    assert_eq "$(grep -c '^source:' "$GB_TEST_EVENTS")" 1 'self-update must not re-exec'
}

reject_update() {
    local before
    before="$(git -C "$CHECKOUT" rev-parse HEAD)"
    if run_cli self-update "$@"; then fail 'unsafe self-update succeeded'; fi
    assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$before" 'refused update changed HEAD'
    assert_source_only
}

run_menu() {
    : > "$GB_TEST_EVENTS"
    GB_REPO_DIR="$(cd -- "$CHECKOUT" && pwd -P)" GB_DRY_RUN="${1:-false}" bash -s -- "$ROOT/src/lib/menu.sh" > "$OUTPUT" 2>&1 <<'MENU_TEST'
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$GB_REPO_DIR/src/lib/core.sh"
# shellcheck source=/dev/null
source "$GB_REPO_DIR/src/lib/update.sh"
# shellcheck source=/dev/null
source "$1"
menu_check_tools() { :; }
menu_overview() { printf 'test manager\n'; }
menu_endpoints() { printf 'menu:continued\n' >> "$GB_TEST_EVENTS"; }
ui_menu() {
    local count
    printf 'menu:prompt\n' >> "$GB_TEST_EVENTS"
    count="$(grep -c '^menu:prompt$' "$GB_TEST_EVENTS")"
    case "$count" in
        1) printf 'self-update\n' ;;
        2) printf 'domains\n' ;;
        *) printf 'exit\n' ;;
    esac
}
ui_run() {
    printf 'menu:run:%s\n' "$*" >> "$GB_TEST_EVENTS"
    shift
    "$@"
}
menu_main
MENU_TEST
}

fixture
publish_update
git -C "$CHECKOUT" config pull.rebase true
run_cli --yes self-update || fail 'fast-forward self-update failed'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AFTER" 'tracked upstream was not pulled'
assert_eq "$(cat "$CHECKOUT/tracked.txt")" 'new source' 'checkout contents were not updated'
assert_eq "$(git -C "$CHECKOUT" symbolic-ref --short HEAD)" installed 'local branch changed'
assert_eq "$(git -C "$CHECKOUT" rev-parse --abbrev-ref '@{upstream}')" deployment/release 'upstream changed'
assert_source_only
assert_eq "$(grep '^source:' "$GB_TEST_EVENTS")" source:old 'old invocation restarted after pulling'
run_cli self-update || fail 'already-current checkout should succeed'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AFTER" 'no-op update changed HEAD'
assert_source_only

fixture
publish_update
printf 'operator edit\n' >> "$CHECKOUT/tracked.txt"
reject_update
grep -q 'operator edit' "$CHECKOUT/tracked.txt" || fail 'dirty content was discarded'
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'dirty checkout contacted the remote'

fixture
publish_update
printf 'operator file\n' > "$CHECKOUT/untracked.txt"
reject_update
assert_eq "$(cat "$CHECKOUT/untracked.txt")" 'operator file' 'untracked file changed'
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'untracked checkout contacted the remote'

fixture
publish_update
git -C "$CHECKOUT" checkout -q --detach
reject_update
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'detached checkout contacted the remote'

fixture
publish_update
git -C "$CHECKOUT" branch --unset-upstream
reject_update
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'checkout without an upstream contacted the remote'

fixture
publish_update
printf 'local change\n' > "$CHECKOUT/local.txt"
git -C "$CHECKOUT" add local.txt
git -C "$CHECKOUT" commit -qm 'local manager change'
reject_update
assert_eq "$(cat "$CHECKOUT/local.txt")" 'local change' 'divergent local commit changed'
[[ ! -e "$CHECKOUT/.git/MERGE_HEAD" ]] || fail 'divergent update left an in-progress merge'

fixture
git -C "$CHECKOUT" remote set-url deployment "$GB_TEST_CASE/missing.git"
reject_update

fixture
publish_update
# Even fetching is a mutation: a dry-run must leave refs and FETCH_HEAD alone.
REMOTE_BEFORE="$(git -C "$CHECKOUT" rev-parse deployment/release)"
git -C "$CHECKOUT" remote set-url deployment "$GB_TEST_CASE/missing.git"
run_cli self-update --dry-run --yes || fail 'dry-run tried to contact an unavailable remote'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$BEFORE" 'dry-run changed HEAD'
assert_eq "$(git -C "$CHECKOUT" rev-parse deployment/release)" "$REMOTE_BEFORE" 'dry-run fetched refs'
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'dry-run created FETCH_HEAD'
if grep -qx lock "$GB_TEST_EVENTS"; then fail 'dry-run acquired the management lock'; fi
assert_source_only
grep -Eqi 'dry.run|would' "$OUTPUT" || fail 'dry-run did not explain the planned update'

fixture
publish_update
# An SSH command supplied by the operator must remain effective. The fake SSH
# transport serves the bare repository locally, without an actual SSH server.
SSH_HELPER="$GB_TEST_CASE/ssh"
export GB_TEST_REMOTE="$REMOTE"
cat > "$SSH_HELPER" <<'SSH'
#!/usr/bin/env bash
case "$*" in
    *git-upload-pack*)
        printf 'ssh:configured-key\n' >> "$GB_TEST_EVENTS"
        exec git-upload-pack "$GB_TEST_REMOTE"
        ;;
    *) exit 0 ;;
esac
SSH
chmod +x "$SSH_HELPER"
git -C "$CHECKOUT" remote set-url deployment ssh://git@fixture/manager.git
git -C "$CHECKOUT" config core.sshCommand "$SSH_HELPER"
run_cli self-update || fail 'self-update did not use configured SSH transport'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AFTER" 'SSH update did not fast-forward'
assert_eq "$(git -C "$CHECKOUT" remote get-url deployment)" ssh://git@fixture/manager.git 'SSH remote changed'
assert_eq "$(git -C "$CHECKOUT" config core.sshCommand)" "$SSH_HELPER" 'SSH key configuration changed'
grep -qx 'ssh:configured-key' "$GB_TEST_EVENTS" || fail 'operator SSH command was bypassed'
assert_source_only

fixture
MAIN_CHECKOUT="$CHECKOUT"
git -C "$CHECKOUT" worktree add -q -b linked "$GB_TEST_CASE/worktree" deployment/release
git -C "$CHECKOUT" branch --set-upstream-to=deployment/release linked >/dev/null
CHECKOUT="$GB_TEST_CASE/worktree"
[[ -f "$CHECKOUT/.git" ]] || fail 'worktree fixture does not have a .git file'
publish_update
run_cli self-update || fail 'linked worktree self-update failed'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AFTER" 'linked worktree was not updated'
assert_eq "$(git -C "$MAIN_CHECKOUT" rev-parse HEAD)" "$BEFORE" 'linked update changed the main checkout'
assert_source_only

fixture
reject_update api.example.test
reject_update --pull
reject_update --unknown

fixture
mv "$CHECKOUT/.git" "$GB_TEST_CASE/saved-git"
if run_cli self-update; then fail 'archive installation was treated as a Git checkout'; fi
assert_source_only

fixture
# A nested manager must not accidentally update an unrelated parent checkout.
mkdir "$CHECKOUT/nested"
cp "$CHECKOUT/getbible.sh" "$CHECKOUT/nested/getbible.sh"
cp -R "$CHECKOUT/src" "$CHECKOUT/nested/src"
git -C "$CHECKOUT" add nested
git -C "$CHECKOUT" commit -qm 'nested manager copy'
CHECKOUT="$CHECKOUT/nested"
reject_update

fixture
git -C "$CHECKOUT" remote set-url deployment "$GB_TEST_CASE/missing.git"
run_cli update api.example.test || fail 'existing domain update failed'
if grep -q '^server:' "$GB_TEST_EVENTS"; then fail 'target dispatch performed installation before shared planning'; fi
grep -qx 'apply:api.example.test' "$GB_TEST_EVENTS" || fail 'domain update did not apply the domain'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$BEFORE" 'domain update unexpectedly pulled source'
run_cli update || fail 'existing all-domain update failed'
grep -qx 'apply:all' "$GB_TEST_EVENTS" || fail 'update did not apply all domains'
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'existing update unexpectedly fetched source'

fixture
publish_update
run_menu || fail 'menu self-update failed'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$AFTER" 'menu did not update manager source'
assert_eq "$(grep -c '^menu:prompt$' "$GB_TEST_EVENTS")" 1 'successful update reopened the stale menu'
if grep -qx 'menu:continued' "$GB_TEST_EVENTS"; then fail 'successful update continued with stale menu functions'; fi
grep -qx 'menu:run:Update manager script update_manager' "$GB_TEST_EVENTS" || fail 'menu bypassed the shared manager update helper'
assert_source_only

fixture
git -C "$CHECKOUT" remote set-url deployment "$GB_TEST_CASE/missing.git"
run_menu || fail 'menu did not recover from an update failure'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$BEFORE" 'failed menu update changed HEAD'
grep -qx 'menu:continued' "$GB_TEST_EVENTS" || fail 'failed update unexpectedly closed the menu'
assert_source_only

fixture
publish_update
run_menu true || fail 'menu dry-run failed'
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$BEFORE" 'menu dry-run changed HEAD'
[[ ! -e "$CHECKOUT/.git/FETCH_HEAD" ]] || fail 'menu dry-run fetched source'
grep -qx 'menu:continued' "$GB_TEST_EVENTS" || fail 'dry-run unexpectedly closed the menu'
assert_source_only

printf 'ok: source-only self-update, tracked upstream, SSH, worktrees, menu, refusals and dry-run\n'

# Native and image update entry points now delegate to the same planner. The
# target isolation, partial completion and failure cases are exercised against
# the real journal in test_upgrade_selection.sh and test_image_update.sh.
# shellcheck disable=SC2317,SC2329 # Sourced update hooks.
(
    source "$ROOT/src/lib/update.sh"
    upgrade_cli() { printf '%s\n' "$*" >> "$T/planner-calls"; return "$planner_status"; }
    planner_status=0
    : > "$T/planner-calls"
    update_domain api.example.test
    update_all --retry
    assert_eq "$(cat "$T/planner-calls")" $'api.example.test\n--all --retry' 'native entry points bypassed the shared planner'
    planner_status=7
    if update_domain api.example.test; then fail 'domain wrapper hid planner failure'; fi
    if update_all; then fail 'all-target wrapper hid planner failure'; fi
)
printf 'ok: native update commands share selection, no-op and failure transactions\n'
