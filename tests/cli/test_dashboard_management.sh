#!/usr/bin/env bash
# Dashboard installation, recovery and nginx security with no host mutation.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none
export GB_NGINX_FAKE_VERSION=1.26.0 GETBIBLE_EXECUTION_MODE=native
mkdir -p "$GB_PREFIX"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
GB="$ROOT/getbible.sh"
status="$(bash "$GB" dashboard status --yes)"
[[ "$status" == *'"enabled": false'* ]] || fail 'dashboard must be off by default'
[[ -f "$GB_PREFIX/etc/systemd/system/getbible-telemetry.service" ]] || fail 'always-on telemetry unit is missing'
grep -qFx 'Type=exec' "$GB_PREFIX/etc/systemd/system/getbible-telemetry.service" || fail 'collector startup must wait for its configured interpreter to execute'
[[ -f "$GB_PREFIX/etc/systemd/system/getbible-adapt.timer" ]] || fail 'adaptive timer is missing'
[[ -f "$GB_PREFIX/etc/systemd/system/getbible-storage.timer" ]] || fail 'independent storage timer is missing'
grep -qF 'OnUnitInactiveSec=30s' "$GB_PREFIX/etc/systemd/system/getbible-storage.timer" || fail 'storage accounting must refresh within the admission freshness window'
grep -qFx 'StartLimitIntervalSec=0' "$GB_PREFIX/etc/systemd/system/getbible-storage.service" || fail 'successful periodic samples must not exhaust a service start quota'
grep -qF 'TimeoutStartSec=75' "$GB_PREFIX/etc/systemd/system/getbible-storage.service" || fail 'storage sampling must have a finite deadline'
grep -qF 'MemoryMax=512M' "$GB_PREFIX/etc/systemd/system/getbible-storage.service" || fail 'storage sampling must have a finite memory limit'
[[ ! -e "$GB_PREFIX/etc/nginx/sites-enabled/getbible-dashboard.conf" ]] || fail 'disabled dashboard must not expose a vhost'
[[ -f "$GB_PREFIX/usr/local/lib/getbible/apps/dashboard/getbible_dashboard/cli.py" ]] || fail 'dashboard dependencies not installed from reviewed source'
printf '%s\n' 'test-dashboard-password-long-enough' | bash "$GB" dashboard password set --stdin --yes >/dev/null
[[ -f "$GB_PREFIX/var/lib/getbible/dashboard/auth.sqlite3" || -f "$GB_PREFIX/var/lib/getbible/dashboard/auth.sqlite" ]] || fail 'password state must persist beneath mounted state'
if bash "$GB" dashboard enable dashboard.example.test --yes > "$TEST_ROOT/failure" 2>&1; then
    fail 'dashboard activation must require Telegram'
fi

# Render through the real templates and manager settings. Native test prefixes
# deliberately skip certificate issuance, host nginx and network requests.
export GETBIBLE_TLS_MODE=external GETBIBLE_TRUSTED_PROXY_CIDRS=192.0.2.10/32
export GETBIBLE_TELEGRAM_ENABLED=true GETBIBLE_TELEGRAM_BOT_TOKEN=123456789:abcdefghijklmnopqrstuv GETBIBLE_TELEGRAM_CHAT_ID=-123456
# Substitute the notification helper in this isolated checkout's installation:
# no actual Telegram messages should be sent by this acceptance fixture.
source "$ROOT/src/lib/core.sh"
for lib in platform ui config deployment registry resources users telegram nginx certs systemd logs access sync python docs pages endpoint analytics cloudflare dashboard; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
tg_notify() { :; }
GB_SELF="$ROOT/getbible.sh"
dashboard_save_setting DASHBOARD_DOMAIN dashboard.example.test
dashboard_save_setting DASHBOARD_ENABLED true
infrastructure_environment
stage="$TEST_ROOT/render"
dashboard_render "$stage" dashboard.example.test
site="$stage/sites-available/getbible-dashboard.conf"
# Keep the nginx variable literal; it must not expand in this shell assertion.
# shellcheck disable=SC2016
grep -qF 'proxy_set_header X-GetBible-Client-IP $remote_addr;' "$site" || fail 'spoofed client IP header must be overwritten'
grep -qF 'proxy_set_header Authorization "";' "$site" || fail 'bearer credentials must be stripped'
grep -qF 'proxy_cache off;' "$site" || fail 'dashboard responses must not enter shared caches'
grep -qF 'access_log off;' "$site" || fail 'dashboard credentials must not enter request logs'
"$GB_PYTHON" - "$site" <<'PY'
from pathlib import Path
import sys
site = Path(sys.argv[1]).read_text()
proxy = site.split('    location / {', 1)[1]
assert 'add_header ' not in proxy, 'proxy responses must inherit server security headers and preserve backend cache policy'
for name in ('bad_request', 'too_large', 'unavailable'):
    error = site.split(f'location @dashboard_{name} {{', 1)[1].split('\n    }', 1)[0]
    assert 'Strict-Transport-Security' in error and 'X-Content-Type-Options' in error, 'nginx-generated errors must retain security headers'
PY
grep -qF 'set_real_ip_from 192.0.2.10/32;' "$stage/snippets/getbible/external-proxy.conf" || fail 'only configured proxy peers may supply client identities'
grep -qF 'SupplementaryGroups=getbible-dashboard getbible-notify' "$GB_PREFIX/etc/systemd/system/getbible-dashboard.service" || fail 'dashboard group isolation is missing'
grep -qF 'NoNewPrivileges=true' "$GB_PREFIX/etc/systemd/system/getbible-dashboard.service" || fail 'dashboard sandbox is missing'
gb_global_set TELEMETRY_MAX_GIB 25
grep -qFx 'GETBIBLE_TELEMETRY_MAX_GIB=25' "$GB_RUN/telemetry.env" || fail 'saved retention must reach the collector immediately'
gb_global_set STORAGE_MAX_GIB 50
grep -qFx 'GETBIBLE_STORAGE_MAX_GIB=50' "$GB_RUN/storage.env" || fail 'saved storage budget must reach the independent sampler immediately'
gb_global_set QUERY_WORKERS_MAX 6
if grep -q '^GETBIBLE_\(QUERY\|SEARCH\)_' "$GB_RUN/adaptive.env"; then
    fail 'saved resource defaults must not become authoritative deployment overrides in the controller'
fi
export GETBIBLE_QUERY_WORKERS_MAX=3 GETBIBLE_SEARCH_CPU_QUOTA=auto
infrastructure_environment
grep -qFx 'GETBIBLE_QUERY_WORKERS_MAX=3' "$GB_RUN/adaptive.env" || fail 'explicit worker bounds must reach the controller'
grep -qFx 'GETBIBLE_SEARCH_CPU_QUOTA=auto' "$GB_RUN/adaptive.env" || fail 'explicit auto policy must retain environment authority'
GETBIBLE_QUERY_WORKERS_MAX='' infrastructure_environment
if grep -q '^GETBIBLE_QUERY_WORKERS_MAX=' "$GB_RUN/adaptive.env"; then
    fail 'empty deployment resource values must restore saved or endpoint settings'
fi
unset GETBIBLE_QUERY_WORKERS_MAX GETBIBLE_SEARCH_CPU_QUOTA
infrastructure_environment
infrastructure_storage_initial_sample || fail 'enabled storage budget must be sampled before services start'
[[ -s "$GB_VAR/storage/usage.json" ]] || fail 'startup storage accounting snapshot is missing'
"$GB_PYTHON" - "$GB_VAR/storage/usage.json" "$GB_PREFIX" <<'PY'
import json
from pathlib import Path
import sys
snapshot = json.loads(Path(sys.argv[1]).read_text())
assert all(item['path'].startswith(sys.argv[2] + '/') for item in snapshot['roots']), 'test sampling must stay inside the fixture prefix'
assert snapshot['used_bytes'] > 0, 'startup sample must account for installed files'
PY
if ! GB_PYTHON=/bin/false infrastructure_storage_initial_sample > "$TEST_ROOT/sampler-failed" 2>&1; then
    fail 'auxiliary sampler failure must not take existing APIs offline'
fi
grep -qF 'Existing APIs remain available' "$TEST_ROOT/sampler-failed" || fail 'sampler failure must explain the publication safeguard'
printf 'ok: dashboard management, persisted authentication, and trusted proxy rendering\n'
