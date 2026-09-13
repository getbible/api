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
    assert db.execute('PRAGMA user_version').fetchone()[0] == 2
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
cat > "$GB_SYSTEMCTL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVICE_CALLS"
[[ "$1" != stop ]]
SH
cat > "$GB_LIBEXEC/getbible-telemetry" <<'PY'
import os
from pathlib import Path
Path(os.environ['RESET_MARKER']).touch()
PY
chmod +x "$GB_SYSTEMCTL" "$GB_LIBEXEC/getbible-telemetry"
sd_available() { return 0; }
sd_is_active() { return 1; }
sd_is_enabled() { return 0; }
sd_start() { "$GB_SYSTEMCTL" start "$@"; }
tg_notify() { :; }
if logs_reset_history --discard-history > "$TEST_ROOT/failed-stop" 2>&1; then
    fail 'a failed service stop must fail the reset'
fi
[[ ! -e "$RESET_MARKER" ]] || fail 'reset ran after service stop failed'
grep -qFx 'start getbible-telemetry.service' "$SERVICE_CALLS" || fail 'enabled telemetry was not recovered'
grep -qFx 'start getbible-dashboard.service' "$SERVICE_CALLS" || fail 'enabled dashboard was not recovered'
python3 - "$SERVICE_CALLS" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
for unit in ('getbible-telemetry.service', 'getbible-dashboard.service'):
    assert calls.index('reset-failed ' + unit) < calls.index('start ' + unit), 'clear restart limits before service recovery'
PY
printf 'ok: explicit telemetry reset, retained data, and service recovery\n'
