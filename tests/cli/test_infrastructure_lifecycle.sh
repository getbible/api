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
printf 'ok: native boot preparation, effective overrides, live reload, and explicit source refresh\n'
