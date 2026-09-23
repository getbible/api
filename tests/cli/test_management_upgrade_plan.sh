#!/usr/bin/env bash
# Read-only eligibility must not race the collector's Type=exec startup.
# shellcheck disable=SC2329 # Deliberate service probe substitutions.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
export GB_PREFIX="$TEST_ROOT/root" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
export GETBIBLE_EXECUTION_MODE=native GB_NGINX_FAKE_VERSION=1.26.0
for lib in core config deployment registry resources users telegram nginx certs systemd logs access sync python docs pages endpoint dashboard update; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'gb_cleanup; rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$GB_LOG" "$GB_VAR/telemetry" "$GB_SYSTEMD"
candidate="$(management_release stage --source "$ROOT")"
management_release select --candidate "$candidate" --systemd "$GB_SYSTEMD" > /dev/null
management_release finish --status current
# The exact service state that previously hid required preparation. No real
# service is running and no service action is allowed during plan inspection.
sd_available() { return 0; }
sd_is_active() { return 0; }
dashboard_health() { printf '{"status":"ok"}\n'; }
dashboard_route_matches() { return 0; }
telemetry_db="$GB_VAR/telemetry/traffic.sqlite3"
row="$TEST_ROOT/row.json"
plan="$TEST_ROOT/plan.json"
schema="$(management_release schema --source "$ROOT")"
create_history() {
    "$GB_PYTHON" - "$telemetry_db" "$ROOT" "$1" <<'PY'
from contextlib import closing
from pathlib import Path
import sqlite3, sys
path, source, schema = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
path.unlink(missing_ok=True)
with closing(sqlite3.connect(path)) as db, db:
    db.executescript((source / f'src/apps/telemetry/getbible_telemetry/schemas/{schema}.sql').read_text())
    db.execute(f'PRAGMA user_version={schema}')
    db.execute("INSERT OR REPLACE INTO metadata VALUES('planning-sentinel', 'preserved')")
PY
}
assert_plan() {
    upgrade_describe management > "$row"
    upgrade_helper plan --inventory "$row" > "$plan"
    "$GB_PYTHON" - "$plan" "$1" "$2" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
row, = plan['targets']
assert row['status'] == sys.argv[2], row
assert row['serving'] == sys.argv[3], row
assert row['eligible'] == (row['status'] == 'pending'), row
PY
}
create_history "$schema"
assert_plan current ready
fingerprint="$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["desired_fingerprint"])' "$row")"
# Actual prior-schema shape; unchanged code and a transient active collector
# must not hide a migration in either native or image plans.
create_history 1
before="$(sha256sum "$telemetry_db" "$(management_release_root)/state.json")"
for mode in native docker; do
    GETBIBLE_EXECUTION_MODE="$mode" assert_plan pending unavailable
    [[ "$(upgrade_helper select --plan "$plan" --format ids)" == management ]]
    grep -q 'Traffic history schema 1 requires preparation' "$plan"
done
[[ "$before" == "$(sha256sum "$telemetry_db" "$(management_release_root)/state.json")" ]]
[[ ! -e "$GB_STATE/upgrades.json" && ! -e "$GB_BACKUPS/telemetry" ]]
# The existing explicit migration path backs up and preserves old history.
# Preparation must not change the desired code/configuration fingerprint.
"$GB_PYTHON" "$GB_TOOLS/getbible-telemetry" prepare --db "$telemetry_db" \
    --backup-dir "$GB_BACKUPS/telemetry" > "$TEST_ROOT/prepared.json"
assert_plan current ready
[[ "$fingerprint" == "$("$GB_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["desired_fingerprint"])' "$row")" ]]
"$GB_PYTHON" - "$telemetry_db" "$TEST_ROOT/prepared.json" "$schema" <<'PY'
from contextlib import closing
from pathlib import Path
import json, sqlite3, sys
result = json.load(open(sys.argv[2]))
assert result['prepared'] == 'migrated' and result['history_reset'] is False, result
with closing(sqlite3.connect(sys.argv[1])) as db:
    assert db.execute('PRAGMA user_version').fetchone()[0] == int(sys.argv[3])
    assert db.execute("SELECT value FROM metadata WHERE key='planning-sentinel'").fetchone()[0] == 'preserved'
with closing(sqlite3.connect(Path(result['backup']).as_uri() + '?mode=ro', uri=True)) as db:
    assert db.execute('PRAGMA user_version').fetchone()[0] == 1
    assert db.execute("SELECT value FROM metadata WHERE key='planning-sentinel'").fetchone()[0] == 'preserved'
PY
# Read-only missing/newer history checks never create or rewrite a database.
rm "$telemetry_db"
assert_plan pending unavailable
[[ ! -e "$telemetry_db" ]]
create_history "$schema"
"$GB_PYTHON" - "$telemetry_db" "$schema" <<'PY'
from contextlib import closing
import sqlite3, sys
with closing(sqlite3.connect(sys.argv[1])) as db, db:
    db.execute(f'PRAGMA user_version={int(sys.argv[2]) + 1}')
PY
before="$(sha256sum "$telemetry_db")"
assert_plan pending unavailable
[[ "$before" == "$(sha256sum "$telemetry_db")" ]]
printf 'Schema-aware management selection, read-only plans, migration backup and unchanged-code reuse: ok\n'
