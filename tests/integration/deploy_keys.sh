#!/usr/bin/env bash
# Real SSH authentication for separate repositories sharing one domain/user.
# Only a private loopback sshd and temporary accounts are used and cleaned up.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$(id -u)" == 0 ]] || { echo 'SSH integration requires root for temporary users.' >&2; exit 1; }
SSHD="$(command -v sshd || true)"
[[ -n "$SSHD" ]] || { echo 'SSH integration requires openssh-server.' >&2; exit 1; }
SB="$(mktemp -d)"
chmod 0755 "$SB"
SSHD_PID=""; SYNC_USER=""; REMOTE_USER=""
SYNC_CREATED=false; REMOTE_CREATED=false
cleanup() {
    local result=$?
    if (( result != 0 )); then
        for file in "$SB"/*.log; do
            [[ ! -f "$file" ]] || { printf '\n%s\n' "$file"; tail -50 "$file"; }
        done
    fi
    if [[ -n "$SSHD_PID" ]]; then
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
    fi
    [[ "$SYNC_CREATED" != true ]] || userdel "$SYNC_USER"
    [[ "$REMOTE_CREATED" != true ]] || userdel "$REMOTE_USER"
    rm -rf -- "$SB"
    exit "$result"
}
trap cleanup EXIT
assert() {
    local label="$1"; shift
    if ! "$@"; then printf 'FAIL: %s\n' "$label" >&2; exit 1; fi
    printf 'ok: %s\n' "$label"
}
export GB_PREFIX="$SB" GB_YES=true GB_UI=none GB_NGINX_FAKE_IPV6=false GB_NGINX_FAKE_VERSION=1.26.0 GB_NGINX_FAKE_BROTLI=false
DOMAIN="ssh-keys-$$.example.test"
REMOTE_USER="gb-ssh-test-$$"
REMOTE_HOME="$SB/git-server"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    print(server.getsockname()[1])
PY
)"
for endpoint in v1 v2; do
    mkdir -p "$SB/upstreams/$endpoint"
    git -C "$SB/upstreams/$endpoint" init --quiet --initial-branch=main
    printf '{"endpoint":"%s"}\n' "$endpoint" > "$SB/upstreams/$endpoint/doc.json"
    git -C "$SB/upstreams/$endpoint" add .
    git -C "$SB/upstreams/$endpoint" -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m fixture
done
"$ROOT/getbible.sh" deploy static --domain "$DOMAIN" --version v1 --ref main \
    --repo "ssh://$REMOTE_USER@127.0.0.1:$PORT/repo-v1.git" --staged > "$SB/deploy.log" 2>&1
"$ROOT/getbible.sh" version add "$DOMAIN" v2 --ref main \
    --repo "ssh://$REMOTE_USER@127.0.0.1:$PORT/repo-v2.git" >> "$SB/deploy.log" 2>&1
UNIT_V1="$SB/etc/systemd/system/getbible-sync-${DOMAIN//[.-]/_}-v1.service"
UNIT_V2="$SB/etc/systemd/system/getbible-sync-${DOMAIN//[.-]/_}-v2.service"
SYNC_USER="$(sed -n 's/^User=//p' "$UNIT_V1")"
SYNC_HOME="$(sed -n 's/^Environment=GB_SYNC_HOME=//p' "$UNIT_V1")"
SYNC_DATA="$(sed -n 's/^Environment=GB_SYNC_DATA=//p' "$UNIT_V1")"
KEY_V1="$(sed -n 's/^Environment=GB_SYNC_KEY=//p' "$UNIT_V1")"
KEY_V2="$(sed -n 's/^Environment=GB_SYNC_KEY=//p' "$UNIT_V2")"
assert 'both services use the same domain account' test "$(sed -n 's/^User=//p' "$UNIT_V2")" = "$SYNC_USER"
assert 'endpoint service identities differ' test "$KEY_V1" != "$KEY_V2"

# GB_PREFIX deliberately skips account creation. Supply the same domain
# account and file ownership for this isolated server fixture.
useradd --system --user-group --no-create-home --home-dir "$SYNC_HOME" --shell /usr/sbin/nologin "$SYNC_USER"
SYNC_CREATED=true
chown -R "$SYNC_USER:$SYNC_USER" "$SYNC_HOME" "$SYNC_DATA"
useradd --system --user-group --no-create-home --home-dir "$REMOTE_HOME" --shell /bin/bash --password '*' "$REMOTE_USER"
REMOTE_CREATED=true
mkdir -p "$REMOTE_HOME/.ssh"
chmod 0700 "$REMOTE_HOME" "$REMOTE_HOME/.ssh"
chown -R "$REMOTE_USER:$REMOTE_USER" "$REMOTE_HOME" "$SB/upstreams"

# Each accepted key may read exactly one repository. Cross-repository access
# fails even though both keys authenticate as the same SSH hosting user.
cat > "$SB/serve-repository" <<EOF
#!/bin/bash
set -eu
[[ "\$SSH_ORIGINAL_COMMAND" == "git-upload-pack '/repo-\$1.git'" ]] || exit 126
exec /usr/bin/git-upload-pack '$SB/upstreams/'"\$1"
EOF
chmod 0755 "$SB/serve-repository"
for endpoint in v1 v2; do
    if [[ "$endpoint" == v1 ]]; then key="$KEY_V1"; else key="$KEY_V2"; fi
    printf 'restrict,command="%s/serve-repository %s" %s\n' "$SB" "$endpoint" "$(cat "$key.pub")" >> "$REMOTE_HOME/.ssh/authorized_keys"
done
chmod 0600 "$REMOTE_HOME/.ssh/authorized_keys"
chown "$REMOTE_USER:$REMOTE_USER" "$REMOTE_HOME/.ssh/authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$SB/host-key"
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat "$SB/host-key.pub")" > "$SYNC_HOME/.ssh/known_hosts"
chown "$SYNC_USER:$SYNC_USER" "$SYNC_HOME/.ssh/known_hosts"
cat > "$SB/sshd.conf" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SB/host-key
PidFile $SB/sshd.pid
AuthorizedKeysFile $REMOTE_HOME/.ssh/authorized_keys
AllowUsers $REMOTE_USER
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM no
StrictModes yes
AllowTcpForwarding no
X11Forwarding no
PermitTTY no
LogLevel VERBOSE
EOF
# Socket-activated Ubuntu installations may not have started ssh.service,
# which normally creates OpenSSH's required privilege-separation directory.
install -d -m 0755 -o root -g root /run/sshd
"$SSHD" -t -f "$SB/sshd.conf"
"$SSHD" -D -e -f "$SB/sshd.conf" > "$SB/sshd.log" 2>&1 &
SSHD_PID=$!
python3 - "$PORT" <<'PY'
import socket
import sys
import time
for attempt in range(50):
    try:
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=0.2):
            break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit('private SSH server did not start')
PY

run_sync_unit() (
    local unit="$1" override_key="${2:-}" command user working_directory
    local -a environment=()
    mapfile -t environment < <(sed -n 's/^Environment=//p' "$unit")
    command="$(sed -n 's/^ExecStart=//p' "$unit")"
    user="$(sed -n 's/^User=//p' "$unit")"
    working_directory="$(sed -n 's/^WorkingDirectory=//p' "$unit")"
    # A system service defaults to /, never the operator's source checkout.
    # Change directory before dropping privileges so a private caller path
    # cannot make Git's initial directory inspection fail.
    cd -- "${working_directory:-/}" || return 1
    [[ -z "$override_key" ]] || environment+=("GB_SYNC_KEY=$override_key")
    # Execute the installed service command as its declared user, with exactly
    # its rendered environment. Notifications are disabled for this fixture.
    runuser -u "$user" -- env "${environment[@]}" GB_NOTIFY=/nonexistent-notifier "$command"
)
# Reproduce an operator or CI checkout that the sync account cannot traverse.
# All service invocations must use their own working directory independently.
PRIVATE_CHECKOUT="$SB/operator-private/checkout"
mkdir -p "$PRIVATE_CHECKOUT"
chmod 0700 "$SB/operator-private"
assert 'caller checkout is inaccessible to the sync account' runuser -u "$SYNC_USER" -- test ! -x "$PRIVATE_CHECKOUT"
cd -- "$PRIVATE_CHECKOUT"
check_repository_access() (
    local endpoint="$1" caller_directory
    caller_directory="$(pwd -P)"
    for lib in core config registry sync; do
        # shellcheck source=/dev/null
        source "$ROOT/src/lib/$lib.sh"
    done
    # Retain the sandbox's resolved registry/home paths while enabling the
    # real runuser/SSH probe against the private server and fixture accounts.
    GB_PREFIX=""
    sync_test_access "$DOMAIN" "$endpoint" > "$SB/access-$endpoint.log" 2>&1 || return 1
    [[ "$(pwd -P)" == "$caller_directory" ]]
)
assert 'v1 access probe succeeds from private checkout and preserves caller cwd' check_repository_access v1
assert 'v2 access probe succeeds from private checkout and preserves caller cwd' check_repository_access v2
run_sync_unit "$UNIT_V1" > "$SB/sync-v1.log" 2>&1
run_sync_unit "$UNIT_V2" > "$SB/sync-v2.log" 2>&1
assert 'v1 authenticates and publishes its own repository' grep -Fxq '{"endpoint":"v1"}' "$SYNC_DATA/v1/doc.json"
assert 'v2 authenticates and publishes its own repository' grep -Fxq '{"endpoint":"v2"}' "$SYNC_DATA/v2/doc.json"
BEFORE_V1="$(readlink -f "$SYNC_DATA/v1")"
BEFORE_V2="$(readlink -f "$SYNC_DATA/v2")"
if run_sync_unit "$UNIT_V2" "$KEY_V1" > "$SB/wrong-key.log" 2>&1; then
    echo 'FAIL: a repository accepted the other endpoint deploy key' >&2
    exit 1
fi
assert 'wrong key leaves v1 publication unchanged' test "$(readlink -f "$SYNC_DATA/v1")" = "$BEFORE_V1"
assert 'wrong key leaves v2 publication unchanged' test "$(readlink -f "$SYNC_DATA/v2")" = "$BEFORE_V2"
assert 'wrong key leaves v2 published bytes intact' grep -Fxq '{"endpoint":"v2"}' "$SYNC_DATA/v2/doc.json"
run_sync_unit "$UNIT_V2" > "$SB/retry.log" 2>&1
assert 'correct key can still check the unchanged repository' grep -q 'up to date' "$SB/retry.log"
assert 'service execution preserves the caller working directory' test "$(pwd -P)" = "$PRIVATE_CHECKOUT"
printf 'Real SSH endpoint identity checks passed.\n'
