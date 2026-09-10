#!/usr/bin/env bash
# Confirm reloads follow the managed master's identity, including nginx's
# configured pid file when it was started outside systemd.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CASE="$(mktemp -d)"
export CASE GB_PREFIX="$CASE" GB_REPO_DIR="$ROOT" GB_UI=none GB_YES=true
for lib in core systemd nginx; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
trap 'rm -rf -- "$CASE"; gb_cleanup' EXIT
mkdir -p "$GB_LOG"
cat > "$CASE/systemctl" <<'CTL'
#!/bin/sh
case "$1" in
    is-active) test -f "$CASE/active" ;;
    show) cat "$CASE/mainpid" ;;
    reload) echo reload >> "$CASE/calls" ;;
    start) echo start >> "$CASE/calls"; printf '4242\n' > "$CASE/mainpid" ;;
    *) exit 2 ;;
esac
CTL
cat > "$CASE/nginx" <<'NGINX'
#!/bin/sh
case "$1" in
    -T) cat "$CASE/config" ;;
    -V) printf 'configure arguments: --pid-path=%s/compiled.pid\n' "$CASE" ;;
    -s) echo signal >> "$CASE/calls"; test ! -f "$CASE/start-required" ;;
    *) exit 2 ;;
esac
NGINX
chmod 0755 "$CASE/systemctl" "$CASE/nginx"
GB_SYSTEMCTL="$CASE/systemctl"; GB_NGINX_BIN="$CASE/nginx"; GB_PREFIX=""
nginx_detect() { NG_AVAILABLE=true; }
# Real /proc ancestry and independent masters are exercised by runtime_rollback.sh.
nginx_master_matches() { [[ "$1" == 4242 ]]; }
sd_snapshot_nginx_workers() { printf 'snapshot %s\n' "$2" >> "$CASE/calls"; : > "$1"; }
sd_wait_nginx_workers_reloaded() { printf 'ready %s\n' "$4" >> "$CASE/calls"; }
pass=0
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; pass=$((pass + 1)); }

touch "$CASE/active"
printf '4242\n' > "$CASE/mainpid"
: > "$CASE/config"; : > "$CASE/calls"
nginx_reload
check test "$(cat "$CASE/calls")" = $'snapshot 4242\nreload\nready 4242'

# MainPID takes precedence; an unrelated pid file must not change the scope.
printf 'pid %s/unrelated.pid;\n' "$CASE" > "$CASE/config"
printf '9898\n' > "$CASE/unrelated.pid"
check test "$(nginx_master_pid)" = 4242

# A custom pid path survives a large nginx -T dump under pipefail. Consuming
# only the first line would SIGPIPE nginx and lose the configured path.
rm "$CASE/active"
printf '0\n' > "$CASE/mainpid"
printf '4242\n' > "$CASE/owned nginx.pid"
printf 'pid "%s/owned nginx.pid";\n' "$CASE" > "$CASE/config"
awk 'BEGIN { for (i=0; i<20000; i++) print "# configuration after the pid directive" }' >> "$CASE/config"
check test "$(nginx_master_pid)" = 4242
: > "$CASE/calls"
nginx_reload
check test "$(cat "$CASE/calls")" = $'snapshot 4242\nsignal\nready 4242'

: > "$CASE/config"
printf '4242\n' > "$CASE/compiled.pid"
check test "$(nginx_master_pid)" = 4242

# An unresolved but active nginx must never be mistaken for a first start.
printf '9898\n' > "$CASE/compiled.pid"
touch "$CASE/active"
: > "$CASE/calls"
if nginx_reload; then echo 'unidentified active nginx was reloaded' >&2; exit 1; fi
check test ! -s "$CASE/calls"

# A genuine first start snapshots no existing workers, then confirms only the
# newly started master's workers; unrelated nginx instances are excluded.
rm "$CASE/active"
touch "$CASE/start-required"
: > "$CASE/calls"
nginx_reload
check test "$(cat "$CASE/calls")" = $'snapshot 0\nsignal\nstart\nready 4242'
printf 'Nginx reload: %s assertions passed\n' "$pass"
