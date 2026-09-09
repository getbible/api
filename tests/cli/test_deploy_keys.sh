#!/usr/bin/env bash
# Distinct repository identities under one domain and endpoint menu routing.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SB="$(mktemp -d)"
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false GB_NGINX_FAKE_VERSION=1.26.0 GB_NGINX_FAKE_BROTLI=false
GB="$ROOT/getbible.sh"
cli() { env -u GB_TMP "$GB" "$@"; }
for lib in core config registry users systemd telegram sync; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf "$SB"' EXIT

assert() {
    local label="$1"; shift
    if ! "$@"; then printf 'FAIL: %s\n' "$label" >&2; exit 1; fi
    printf 'ok: %s\n' "$label"
}
unit() { printf '%s/%s.service\n' "$GB_SYSTEMD" "$(sync_unit "$1" "$2")"; }
active_unit_key() { sed -n 's/^Environment=GB_SYNC_KEY=//p' "$(unit "$1" "$2")"; }
key_material() { ssh-keygen -y -f "$1"; }

D=keys.example.test
cli deploy static --domain "$D" --version v1 --repo git@github.com:getbible/v1_scripture.git --staged >/dev/null 2>&1
cli version add "$D" v2 --repo git@github.com:getbible/v2_scripture.git >/dev/null 2>&1
K1="$(sync_endpoint_key "$D" v1)"
K2="$(sync_endpoint_key "$D" v2)"
P1="$(key_material "$K1")"
P2="$(key_material "$K2")"
assert 'same-domain repositories have different private key paths' test "$K1" != "$K2"
assert 'same-domain repositories have different public keys' test "$P1" != "$P2"
assert 'v1 service selects its own key' test "$(active_unit_key "$D" v1)" = "$K1"
assert 'v2 service selects its own key' test "$(active_unit_key "$D" v2)" = "$K2"
assert 'versions keep one domain sync user' test "$(sed -n 's/^User=//p' "$(unit "$D" v1)")" = "$(sed -n 's/^User=//p' "$(unit "$D" v2)")"
assert 'both endpoints share the nginx domain' grep -q "server_name $D;" "$SB/etc/nginx/sites-available/$D.conf"
assert 'v1 nginx route remains available' grep -q 'location \^~ /v1/' "$SB/etc/nginx/sites-available/$D.conf"
assert 'v2 nginx route remains available' grep -q 'location \^~ /v2/' "$SB/etc/nginx/sites-available/$D.conf"
assert 'private key permissions' test "$(stat -c %a "$K1")" = 600
assert 'private key directory permissions' test "$(stat -c %a "$(dirname "$K1")")" = 700
assert 'deploy-key prints the selected endpoint public key' grep -Fq "$P2" <<< "$(cli deploy-key "$D" v2 2>&1)"
assert 'deploy-key rejects an unknown endpoint' test "$(cli deploy-key "$D" v9 >/dev/null 2>&1; echo $?)" != 0
assert 'deploy-key requires an endpoint on a multi-endpoint domain' test "$(cli deploy-key "$D" >/dev/null 2>&1; echo $?)" != 0

cli apply "$D" >/dev/null 2>&1
assert 'reapply retains v1 key material' test "$(key_material "$K1")" = "$P1"
assert 'reapply retains v2 key material' test "$(key_material "$K2")" = "$P2"
cli version change "$D" v1 --ref release --path data >/dev/null 2>&1
assert 'ref and export path changes retain repository key' test "$(active_unit_key "$D" v1)" = "$K1"
assert 'ref change retains key material' test "$(key_material "$K1")" = "$P1"
cli version change "$D" v1 --repo git@github.com:getbible/replacement.git >/dev/null 2>&1
K1_NEW="$(sync_endpoint_key "$D" v1)"
assert 'repository change selects a new key path' test "$K1_NEW" != "$K1"
assert 'repository change generates a new public key' test "$(key_material "$K1_NEW")" != "$P1"
assert 'repository change updates only its service identity' test "$(active_unit_key "$D" v1)" = "$K1_NEW"
assert 'repository change leaves sibling identity intact' test "$(active_unit_key "$D" v2)" = "$K2"
assert 'repository change preserves sibling key material' test "$(key_material "$K2")" = "$P2"

# A missing public half can be recovered without changing the deploy key.
rm "$K2.pub"
cli deploy-key "$D" v2 >/dev/null 2>&1
assert 'showing key recovers a missing public half' test "$(key_material "$K2")" = "$P2"
assert 'recovered public half matches the private identity' grep -Fq "$P2" "$K2.pub"
assert 'repo-access rejects an unknown endpoint' test "$(cli repo-access "$D" v9 >/dev/null 2>&1; echo $?)" != 0
assert 'prefix access test never claims credentials were verified' test "$(cli repo-access "$D" v2 >/dev/null 2>&1; echo $?)" != 0

# Exercise the menu's actual endpoint selection and dispatch, substituting only
# dialog responses and remote operations. The queue lives on disk because menu
# selection runs in command substitutions.
# shellcheck source=../../src/lib/endpoint.sh
source "$ROOT/src/lib/endpoint.sh"
# shellcheck source=../../src/lib/pages.sh
source "$ROOT/src/lib/pages.sh"
# shellcheck source=../../src/types/static/type.sh
source "$ROOT/src/types/static/type.sh"
ui_menu() {
    local choice
    printf '%s\n' "$@" >> "$SB/dialogs"
    IFS= read -r choice < "$SB/choices" || return 1
    sed '1d' "$SB/choices" > "$SB/choices.next"
    mv "$SB/choices.next" "$SB/choices"
    [[ "$choice" != cancel ]] || return 1
    printf '%s\n' "$choice"
}
ui_msg() { printf '%s\n' "$@" >> "$SB/messages"; }
ui_run() { shift; "$@"; }
ACCESS_RESULT=0
sync_test_access() {
    printf 'access:%s:%s:%s\n' "$1" "$2" "$(sync_key_file "$1" "$2")" >> "$SB/actions"
    return "$ACCESS_RESULT"
}
sync_run_now() { printf 'sync:%s:%s\n' "$1" "$2" >> "$SB/actions"; }
sync_force_now() { printf 'force:%s:%s\n' "$1" "$2" >> "$SB/actions"; }
: > "$SB/actions"
printf 'v2\nshow\ntest\nsync\nback\n' > "$SB/choices"
type_static_menu_action "$D" key
assert 'key menu identifies the selected endpoint repository' grep -Fq 'Repository: git@github.com:getbible/v2_scripture.git' "$SB/dialogs"
assert 'key dialog displays selected endpoint public key' grep -Fq "$P2" "$SB/messages"
assert 'key menu tests the selected endpoint identity' grep -Fxq "access:$D:v2:$K2" "$SB/actions"
assert 'key menu syncs the selected endpoint' grep -Fxq "sync:$D:v2" "$SB/actions"
assert 'key menu does not operate on a sibling' test "$(wc -l < "$SB/actions" | tr -d ' ')" = 2

: > "$SB/actions"
printf 'v1\n' > "$SB/choices"
type_static_menu_action "$D" repoaccess
assert 'domain repository-access menu uses the selected endpoint key' grep -Fxq "access:$D:v1:$K1_NEW" "$SB/actions"
printf 'v1\n' > "$SB/choices"
type_static_menu_action "$D" force
assert 'force menu targets the selected endpoint' grep -Fxq "force:$D:v1" "$SB/actions"

: > "$SB/messages"
printf 'key\nv1\nshow\nback\nback\n' > "$SB/choices"
type_static_versions_menu "$D"
assert 'versions menu offers the same endpoint key workflow' grep -Fq "$(key_material "$K1_NEW")" "$SB/messages"

: > "$SB/actions"
printf 'cancel\n' > "$SB/choices"
type_static_menu_action "$D" key
assert 'canceling endpoint choice performs no action' test ! -s "$SB/actions"
ACCESS_RESULT=1
printf 'v2\ntest\nshow\nback\n' > "$SB/choices"
type_static_menu_action "$D" key
assert 'failed access test returns to the key menu' test ! -s "$SB/choices"

# The endpoint forms must gather every answer before changing a repository or
# generating its identity; canceling any field must leave the domain intact.
ui_input() {
    local answer
    printf '%s\n' "$@" >> "$SB/input-dialogs"
    IFS= read -r answer < "$SB/answers" || return 1
    sed '1d' "$SB/answers" > "$SB/answers.next"
    mv "$SB/answers.next" "$SB/answers"
    [[ "$answer" != cancel ]] || return 1
    printf '%s\n' "$answer"
}
endpoint_confirm_hand_edits() { return 0; }
type_static_add_version() { printf 'add:%s:%s:%s:%s:%s\n' "$@" >> "$SB/actions"; }
type_static_change_version() { printf 'change:%s:%s:%s:%s:%s\n' "$@" >> "$SB/actions"; }
: > "$SB/actions"
printf 'add\nback\n' > "$SB/choices"
printf 'v3\ncancel\n' > "$SB/answers"
type_static_versions_menu "$D"
assert 'canceling a new repository performs no deployment' test ! -s "$SB/actions"
assert 'canceling a new repository creates no endpoint' test ! -f "$(ep_version_conf "$D" v3)"
printf 'add\nback\n' > "$SB/choices"
printf 'v3\ngit@github.com:getbible/v3.git\nmain\ndata\n' > "$SB/answers"
type_static_versions_menu "$D"
assert 'add form forwards its own endpoint repository and source' grep -Fxq "add:$D:v3:git@github.com:getbible/v3.git:main:data" "$SB/actions"

: > "$SB/actions"
printf 'change\nv2\nback\n' > "$SB/choices"
printf 'git@github.com:getbible/v2-other.git\nmain\ncancel\n' > "$SB/answers"
type_static_versions_menu "$D"
assert 'canceling the final source field performs no repository change' test ! -s "$SB/actions"
assert 'canceled edit preserves endpoint identity' test "$(active_unit_key "$D" v2)" = "$K2"
printf 'change\nv2\nback\n' > "$SB/choices"
printf 'git@github.com:getbible/v2-other.git\nmain\nfiles\n' > "$SB/answers"
type_static_versions_menu "$D"
assert 'change form forwards the selected endpoint and complete source' grep -Fxq "change:$D:v2:git@github.com:getbible/v2-other.git:main:files" "$SB/actions"

# Use the real ui_run, message/textbox functions and endpoint actions here.
# A nested whiptail dialog would draw into ui_run's redirected log and wait
# invisibly for input. The dialog stub rejects that condition explicitly.
unset GB_UI_LOADED GB_TYPE_STATIC_LOADED
# shellcheck source=../../src/lib/ui.sh
source "$ROOT/src/lib/ui.sh"
# shellcheck source=../../src/types/static/type.sh
source "$ROOT/src/types/static/type.sh"
GB_UI=whiptail
ui_size() { printf '20 76\n'; }
endpoint_apply() { printf 'apply:%s\n' "$1" >> "$SB/actions"; }
whiptail() {
    if [[ "$GB_UI_CAPTURED" == true ]]; then
        printf 'Unexpected dialog while output is captured\n' >&2
        return 1
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --textbox)
                printf 'textbox\n' > "$SB/dialog-kind"
                cp "$2" "$SB/last-dialog"
                return 0 ;;
            --msgbox)
                printf 'msgbox\n' > "$SB/dialog-kind"
                printf '%s\n' "$2" > "$SB/last-dialog"
                return 0 ;;
        esac
        shift
    done
    return 1
}
assert 'captured add completes without an invisible nested dialog' ui_run 'Add endpoint' \
    type_static_add_version "$D" v7 git@github.com:getbible/v7.git main .
K7="$(sync_endpoint_key "$D" v7)"
assert 'add result appears in the operation textbox' test "$(cat "$SB/dialog-kind")" = textbox
assert 'add result includes its endpoint public key' grep -Fq "$(key_material "$K7")" "$SB/last-dialog"
assert 'add result identifies the repository to authorize' grep -Fq 'Repository: git@github.com:getbible/v7.git' "$SB/last-dialog"
assert 'captured add restores dialog state' test "$GB_UI_CAPTURED" = false
assert 'captured repository change completes without a nested dialog' ui_run 'Change endpoint' \
    type_static_change_version "$D" v7 git@github.com:getbible/v7-other.git main .
K7_NEW="$(sync_endpoint_key "$D" v7)"
assert 'change result includes the replacement repository public key' grep -Fq "$(key_material "$K7_NEW")" "$SB/last-dialog"
assert 'change result identifies the replacement repository' grep -Fq 'Repository: git@github.com:getbible/v7-other.git' "$SB/last-dialog"
assert 'standalone key display still opens a visible dialog' type_static_show_key "$D" v7
assert 'standalone key display uses the message dialog' test "$(cat "$SB/dialog-kind")" = msgbox
assert 'standalone key display contains the correct public key' grep -Fq "$(key_material "$K7_NEW")" "$SB/last-dialog"

echo 'deploy key tests passed'
