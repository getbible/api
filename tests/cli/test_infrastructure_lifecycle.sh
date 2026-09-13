#!/usr/bin/env bash
# Native reboot recovery, live settings, and explicit reviewed source updates.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none
export GETBIBLE_EXECUTION_MODE=native GB_NGINX_FAKE_VERSION=1.26.0
mkdir -p "$GB_PREFIX"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# A normal installation writes durable defaults outside the source checkout.
bash "$ROOT/getbible.sh" dashboard status --yes >/dev/null
source "$ROOT/src/lib/core.sh"
trap 'gb_cleanup; rm -rf "$TEST_ROOT"' EXIT
for lib in platform ui config deployment registry resources users telegram nginx certs systemd logs access sync python docs pages endpoint dashboard; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
GB_SELF="$ROOT/getbible.sh"
tg_notify() { :; }
for unit in telemetry dashboard admin adapt storage; do
    grep -qFx 'Requires=getbible-prepare.service' "$GB_SYSTEMD/getbible-$unit.service" || fail "$unit must require preparation"
    grep -qFx 'After=getbible-prepare.service' "$GB_SYSTEMD/getbible-$unit.service" || fail "$unit must wait for preparation"
done
grep -qFx 'ProtectSystem=strict' "$GB_SYSTEMD/getbible-prepare.service" || fail 'preparation must have a read-only filesystem'
grep -qFx 'RuntimeDirectoryPreserve=yes' "$GB_SYSTEMD/getbible-prepare.service" || fail 'preparation must preserve runtime snapshots'
grep -qFx 'Wants=getbible-admin.service' "$GB_SYSTEMD/getbible-dashboard.service" || fail 'dashboard must survive broker replacement'

# Exercise the installed adaptive executable, including its sibling planner,
# without configured endpoints or external systemctl/manager operations.
"$GB_PYTHON" "$GB_LIBEXEC/getbible-adapt" --once --config "$GB_GLOBAL_CONF" \
    --environment "$GB_ENVIRONMENT_CONF" --state "$GB_VAR/adaptive.json" \
    --registry "$GB_ENDPOINTS" --runtime-root "$GB_OPT" --cache-root "$GB_CACHE" \
    > "$TEST_ROOT/adaptive-result.json"
"$GB_PYTHON" - "$TEST_ROOT/adaptive-result.json" <<'PYRESULT'
import json
import sys
with open(sys.argv[1]) as stream:
    assert json.load(stream)["status"] == "sampled"
PYRESULT

persisted="$(sha256sum "$GB_GLOBAL_CONF" "$GB_TELEGRAM_CONF")"
# A complete command-generated native override must survive first service start.
GETBIBLE_TELEMETRY_MAX_GIB=9 infrastructure_environment
grep -qFx 'GETBIBLE_TELEMETRY_MAX_GIB=9' "$GB_RUN/telemetry.env" || fail 'native override was not rendered'
before="$(sha256sum "$GB_RUN"/*.conf "$GB_RUN"/*.env)"
infrastructure_prepare
grep -qFx 'GETBIBLE_TELEMETRY_MAX_GIB=9' "$GB_RUN/telemetry.env" || fail 'preparation lost a native override'
[[ "$(sha256sum "$GB_RUN"/*.conf "$GB_RUN"/*.env)" == "$before" ]] || fail 'preparation replaced a complete native override'
# A reboot loses /run, not /etc. Reconstruct without the manager lock or services.
rm -f "$GB_RUN"/*.conf "$GB_RUN"/*.env
env -u GB_TMP bash "$ROOT/getbible.sh" infrastructure-prepare --yes
for file in dashboard.conf telemetry.env adaptive.env storage.env telegram.conf; do
    [[ -s "$GB_RUN/$file" ]] || fail "reboot failed to regenerate $file"
done
[[ "$(sha256sum "$GB_GLOBAL_CONF" "$GB_TELEGRAM_CONF")" == "$persisted" ]] || fail 'preparation mutated persistent configuration'
# A clean systemd child in Docker consumes captured overrides, not host defaults.
GETBIBLE_MEMORY_CACHE_TTL=4321 GETBIBLE_TELEMETRY_MAX_GIB=7 gb_environment_capture
rm "$GB_RUN/telemetry.env"
env -i PATH="$PATH" GB_PREFIX="$GB_PREFIX" GB_UI=none GETBIBLE_EXECUTION_MODE=docker bash "$ROOT/getbible.sh" infrastructure-prepare --yes
grep -qFx 'GETBIBLE_TELEMETRY_MAX_GIB=7' "$GB_RUN/telemetry.env" || fail 'Docker capture was ignored in a clean child'
rm "$GB_ENVIRONMENT_CONF"
infrastructure_environment

# Record service actions: unchanged snapshots never reload, and preparation
# never signals services. Telegram writes on native hosts refresh immediately.
export SERVICE_ACTIONS="$TEST_ROOT/actions"
GB_SYSTEMCTL="$TEST_ROOT/systemctl"
cat > "$GB_SYSTEMCTL" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVICE_ACTIONS"
MOCK
chmod +x "$GB_SYSTEMCTL"
sd_is_active() { return 0; }
: > "$SERVICE_ACTIONS"
infrastructure_environment
[[ ! -s "$SERVICE_ACTIONS" ]] || fail 'unchanged settings reloaded the dashboard'
cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID -98765
grep -qFx 'TELEGRAM_CHAT_ID=-98765' "$GB_RUN/telegram.conf" || fail 'native Telegram effective settings are stale'
[[ "$(cat "$SERVICE_ACTIONS")" == 'reload getbible-dashboard.service' ]] || fail 'Telegram change must reload the dashboard once'
: > "$SERVICE_ACTIONS"
gb_global_set STORAGE_MAX_GIB 0
[[ ! -s "$SERVICE_ACTIONS" ]] || fail 'unrelated settings reloaded the dashboard'
gb_global_set DASHBOARD_IDLE_SECONDS 90
[[ "$(cat "$SERVICE_ACTIONS")" == 'reload getbible-dashboard.service' ]] || fail 'dashboard setting change must reload the dashboard'
: > "$SERVICE_ACTIONS"
rm "$GB_RUN/dashboard.conf"
infrastructure_prepare
[[ ! -s "$SERVICE_ACTIONS" ]] || fail 'boot preparation invoked systemctl'
GB_CONTAINER_BOOTSTRAP=true GETBIBLE_DASHBOARD_IDLE_SECONDS=120 infrastructure_environment
[[ ! -s "$SERVICE_ACTIONS" ]] || fail 'container bootstrap invoked systemctl'

# Ordinary commands retain installed implementation. Explicit update replaces
# reviewed helpers and restarts active readers, deferring the broker itself.
printf '# stale installed source marker\n' >> "$GB_LIBEXEC/getbible-telemetry"
infrastructure_ensure
grep -qF 'stale installed source marker' "$GB_LIBEXEC/getbible-telemetry" || fail 'ordinary command replaced installed infrastructure code'
persisted="$(sha256sum "$GB_GLOBAL_CONF" "$GB_TELEGRAM_CONF")"
# Prefix mode deliberately disables real systemd calls; record those lifecycle
# helpers while still exercising the complete source/unit installation path.
sd_restart() { printf 'restart %s\n' "$*" >> "$SERVICE_ACTIONS"; }
: > "$SERVICE_ACTIONS"
infrastructure_update
cmp "$GB_TOOLS/getbible-telemetry" "$GB_LIBEXEC/getbible-telemetry" || fail 'explicit update did not refresh installed sources'
for action in 'restart getbible-telemetry.service' 'restart getbible-dashboard.service' 'kill --kill-who=main --signal=SIGUSR1 getbible-admin.service'; do
    grep -qFx -- "$action" "$SERVICE_ACTIONS" || fail "missing lifecycle action: $action"
done
[[ "$(sha256sum "$GB_GLOBAL_CONF" "$GB_TELEGRAM_CONF")" == "$persisted" ]] || fail 'explicit infrastructure update mutated saved configuration'

# Deployment metadata distinguishes copied source from the running process.
dashboard_release_manifest > "$TEST_ROOT/source-release.json"
cmp "$TEST_ROOT/source-release.json" "$GB_LIBEXEC/apps/dashboard/release.json" || fail 'installed release marker does not match reviewed manager source'
# shellcheck disable=SC2317,SC2329 # Indirect dashboard_status hook; codes differ across ShellCheck versions.
dashboard_health() {
    printf '{"release":%s}\n' "$(cat "$GB_LIBEXEC/apps/dashboard/release.json")"
}
dashboard_status > "$TEST_ROOT/current-status.json"
"$GB_PYTHON" - "$TEST_ROOT/current-status.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
assert status['running_latest'] is True
assert status['manager_release'] == status['installed_release'] == status['serving_release']
PY
dashboard_health() { printf '{"release":{"version":"0.0.0","revision":"old","fingerprint":"old"}}\n'; }
dashboard_status > "$TEST_ROOT/stale-status.json"
"$GB_PYTHON" - "$TEST_ROOT/stale-status.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
assert status['running_latest'] is False
assert status['serving_release']['revision'] == 'old'
assert status['manager_release'] == status['installed_release']
PY

# Reporting services recover independently. A collector startup error cannot
# prevent an operator from replacing the dashboard backend to diagnose it.
sd_available() { return 0; }
sd_enable() {
    local IFS=' '
    printf 'enable %s\n' "$*" >> "$SERVICE_ACTIONS"
    [[ "$*" != *getbible-telemetry.service* ]]
}
: > "$SERVICE_ACTIONS"
if infrastructure_update > "$TEST_ROOT/reporting-failure" 2>&1; then
    fail 'full infrastructure update must report a failed collector'
fi
[[ "$GB_INFRASTRUCTURE_TELEMETRY_FAILED" == true ]] || fail 'collector-only failure must allow unrelated API deployment to proceed'
grep -qFx 'restart getbible-dashboard.service' "$SERVICE_ACTIONS" || fail 'collector failure prevented dashboard recovery'
"$GB_PYTHON" - "$SERVICE_ACTIONS" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
reset = 'reset-failed getbible-telemetry.service getbible-dashboard.service getbible-admin.service'
assert calls.index(reset) < calls.index('enable --now getbible-telemetry.service')
PY
infrastructure_update --dashboard > "$TEST_ROOT/dashboard-recovery" 2>&1 || fail 'dashboard update was blocked by unrelated collector failure'
(
    # shellcheck disable=SC2317,SC2329 # Indirect infrastructure_update hook; codes differ across ShellCheck versions.
    infrastructure_install() { GB_TELEMETRY_START_FAILED=true; return 1; }
    if infrastructure_update; then fail 'essential installation failure must fail the update'; fi
    [[ "$GB_INFRASTRUCTURE_TELEMETRY_FAILED" == false ]] || fail 'essential installation failure was incorrectly treated as collector-only failure'
)

# Dashboard apply/update must use the code-replacement path, not only SIGHUP.
dashboard_require_telegram() { :; }
nginx_conflicts() { :; }
dashboard_render() { mkdir -p "$1/sites-available"; : > "$1/sites-available/getbible-dashboard.conf"; }
nginx_apply_stage() { return 0; }
gb_global_set DASHBOARD_DOMAIN dashboard.example.test
: > "$SERVICE_ACTIONS"
dashboard_cli update
grep -qFx 'restart getbible-dashboard.service' "$SERVICE_ACTIONS" || fail 'dashboard update did not replace the running backend'

# Image application runs after the restored nginx service, never inside the
# pre-systemd bootstrap path. The release marker decides whether it has work.
: > "$SERVICE_ACTIONS"
GB_CONTAINER_BOOTSTRAP=true GETBIBLE_EXECUTION_MODE=docker infrastructure_install > "$TEST_ROOT/image-bootstrap" 2>&1
image_unit="$GB_SYSTEMD/getbible-image-update.service"
grep -qFx "ExecStart=$GB_SELF image-update --yes" "$image_unit" || fail 'container bootstrap did not install the image apply job'
grep -qFx 'After=local-fs.target nginx.service getbible-prepare.service' "$image_unit" || fail 'image apply must run after the restored API frontend'
grep -qFx 'WantedBy=multi-user.target' "$image_unit" || fail 'image apply must be part of normal container startup'
grep -qFx 'enable getbible-image-update.service' "$SERVICE_ACTIONS" || fail 'container bootstrap did not schedule image application'
if grep -q '^stop ' "$SERVICE_ACTIONS"; then fail 'container bootstrap performed blocking reporting preparation before restoring APIs'; fi
printf 'ok: native boot preparation, effective overrides, live reload, and explicit source refresh\n'
