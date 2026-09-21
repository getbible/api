#!/usr/bin/env bash
# Explicit reset clears canonical history without replaying it or touching API data.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none
export GB_NGINX_FAKE_VERSION=1.26.0 GETBIBLE_EXECUTION_MODE=native
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$GB_PREFIX"
bash "$ROOT/getbible.sh" dashboard status --yes >/dev/null
database="$GB_PREFIX/var/lib/getbible/telemetry/traffic.sqlite3"
python3 - "$ROOT" "$database" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / 'src/apps/telemetry'))
from getbible_telemetry import TelemetryStore
with TelemetryStore(sys.argv[2]) as store:
    with store.db:
        store.append({'time': 100, 'request_id': 'before-reset', 'uri': '/v2/kjv/1/1.json', 'status': 200},
                     endpoint='bible.example.test', source='edge', record_key='before-reset')
        store.db.execute("INSERT INTO metadata(key,value) VALUES('journal_cursor','\"retained-cursor\"')")
        store.db.execute('PRAGMA user_version=1')
PY
mkdir -p "$GB_PREFIX/var/log/getbible/bible.example.test" "$GB_PREFIX/srv/getbible/bible.example.test/v2"
printf 'raw log retained\n' > "$GB_PREFIX/var/log/getbible/bible.example.test/access.log"
printf 'published API data\n' > "$GB_PREFIX/srv/getbible/bible.example.test/v2/translations.json"
if bash "$ROOT/getbible.sh" logs reset --yes > "$TEST_ROOT/missing-flag" 2>&1; then
    fail 'reset must require explicit discard-history acknowledgement'
fi
python3 - "$database" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute('SELECT count(*) FROM requests').fetchone()[0] == 1
PY
bash "$ROOT/getbible.sh" logs reset --discard-history --yes > "$TEST_ROOT/reset"
python3 - "$database" <<'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute('PRAGMA user_version').fetchone()[0] == 3
    assert db.execute('SELECT count(*) FROM requests').fetchone()[0] == 0
    assert json.loads(db.execute("SELECT value FROM metadata WHERE key='journal_cursor'").fetchone()[0]) == 'retained-cursor'
    assert json.loads(db.execute("SELECT value FROM metadata WHERE key='collection_started'").fetchone()[0]) > 100
PY
[[ "$(cat "$GB_PREFIX/var/log/getbible/bible.example.test/access.log")" == 'raw log retained' ]] || fail 'raw logs changed'
[[ "$(cat "$GB_PREFIX/srv/getbible/bible.example.test/v2/translations.json")" == 'published API data' ]] || fail 'API data changed'
grep -qF -- "--registry $GB_PREFIX/etc/getbible/endpoints --data-root $GB_PREFIX/srv/getbible" \
    "$GB_PREFIX/etc/systemd/system/getbible-telemetry.service" || fail 'collector must read the local configured registry and data'

# A failure to stop services must prevent reset, while recovering services
# which were enabled before this command (including an old failed collector).
source "$ROOT/src/lib/core.sh"
source "$ROOT/src/lib/logs.sh"
GB_SYSTEMCTL="$TEST_ROOT/systemctl"
GB_LIBEXEC="$TEST_ROOT/helpers"
mkdir -p "$GB_LIBEXEC"
export RESET_MARKER="$TEST_ROOT/helper-ran" SERVICE_CALLS="$TEST_ROOT/service-calls"
export STOP_FAIL=true RESET_EXIT=0 ROTATION_STATE=
cat > "$GB_SYSTEMCTL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVICE_CALLS"
if [[ "$1" == show ]]; then printf '%s\n' "$ROTATION_STATE"; fi
[[ "$1" != stop || "$STOP_FAIL" != true ]]
SH
cat > "$GB_LIBEXEC/getbible-telemetry" <<'PY'
import os
from pathlib import Path
Path(os.environ['RESET_MARKER']).touch()
with Path(os.environ['SERVICE_CALLS']).open('a') as calls:
    calls.write('reset-helper\n')
raise SystemExit(int(os.environ['RESET_EXIT']))
PY
chmod +x "$GB_SYSTEMCTL" "$GB_LIBEXEC/getbible-telemetry"
sd_available() { return 0; }
sd_is_active() { [[ "$1" == getbible-logrotate.timer || "$1" == getbible-logrotate.service ]]; }
sd_is_enabled() { return 0; }
sd_start() { "$GB_SYSTEMCTL" start "$@"; }
tg_notify() { :; }
if logs_reset_history --discard-history > "$TEST_ROOT/failed-stop" 2>&1; then
    fail 'a failed service stop must fail the reset'
fi
[[ ! -e "$RESET_MARKER" ]] || fail 'reset ran after service stop failed'
grep -qFx 'start getbible-telemetry.service' "$SERVICE_CALLS" || fail 'enabled telemetry was not recovered'
grep -qFx 'start getbible-dashboard.service' "$SERVICE_CALLS" || fail 'enabled dashboard was not recovered'
grep -qFx 'start getbible-logrotate.timer' "$SERVICE_CALLS" || fail 'active rotation timer was not recovered'
grep -qFx 'start getbible-logrotate.service' "$SERVICE_CALLS" || fail 'active rotation service was not recovered'
python3 - "$SERVICE_CALLS" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
for unit in ('getbible-telemetry.service', 'getbible-dashboard.service', 'getbible-logrotate.service', 'getbible-logrotate.timer'):
    assert calls.index('reset-failed ' + unit) < calls.index('start ' + unit), 'clear restart limits before service recovery'
assert calls.index('stop getbible-logrotate.timer') < calls.index('stop getbible-logrotate.service getbible-telemetry.service getbible-dashboard.service')
PY

# A helper failure still restores the reader, collector and active timer.
: > "$SERVICE_CALLS"
export STOP_FAIL=false RESET_EXIT=7
sd_is_active() { [[ "$1" == getbible-logrotate.timer ]]; }
status=0
logs_reset_history --discard-history > "$TEST_ROOT/failed-reset" 2>&1 || status=$?
[[ "$status" -eq 7 ]] || fail 'reset helper failure status was lost'
[[ -e "$RESET_MARKER" ]] || fail 'reset helper was not attempted'
for unit in getbible-telemetry.service getbible-dashboard.service getbible-logrotate.timer; do
    grep -qFx "start $unit" "$SERVICE_CALLS" || fail "$unit was not restored after a reset failure"
done
if grep -qFx 'start getbible-logrotate.service' "$SERVICE_CALLS"; then fail 'inactive rotation service was started'; fi

# Enabled but inactive scheduling stays stopped; completed reset precedes recovery.
: > "$SERVICE_CALLS"
export RESET_EXIT=0
sd_is_active() { return 1; }
logs_reset_history --discard-history > "$TEST_ROOT/successful-reset" 2>&1
python3 - "$SERVICE_CALLS" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
reset = calls.index('reset-helper')
assert calls.index('stop getbible-logrotate.timer') < reset
assert calls.index('stop getbible-logrotate.service getbible-telemetry.service getbible-dashboard.service') < reset
for unit in ('getbible-telemetry.service', 'getbible-dashboard.service'):
    assert reset < calls.index('start ' + unit)
assert 'start getbible-logrotate.timer' not in calls
assert 'start getbible-logrotate.service' not in calls
PY

# systemd reports a running oneshot as activating, rather than active.
: > "$SERVICE_CALLS"
export ROTATION_STATE=activating
logs_reset_history --discard-history > "$TEST_ROOT/running-rotation" 2>&1
grep -qFx 'start getbible-logrotate.service' "$SERVICE_CALLS" || fail 'running oneshot rotation was not restored'
printf 'ok: explicit telemetry reset, retained data, and service recovery\n'
