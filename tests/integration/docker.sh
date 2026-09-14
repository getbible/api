#!/usr/bin/env bash
# Disposable acceptance of the actual production Compose profile and image.
# Uses fixture scripture only; no Cloudflare or certificate requests are made.
set -Eeuo pipefail
trap 'printf "Docker acceptance failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
command -v docker >/dev/null
command -v haproxy >/dev/null
[[ "$(docker info --format '{{.CgroupVersion}}')" == 2 ]]
[[ "$(docker info --format '{{json .SecurityOptions}}')" != *rootless* ]]
export GETBIBLE_IMAGE_REPOSITORY="${GETBIBLE_TEST_IMAGE_REPOSITORY:-getbible-api-test}"
export GETBIBLE_IMAGE_TAG="${GETBIBLE_TEST_IMAGE_TAG:-ci}"
export GETBIBLE_MEMORY_LIMIT=4g GETBIBLE_CPU_LIMIT=2
export GETBIBLE_TLS_MODE=external GETBIBLE_TRUSTED_PROXY_CIDRS=127.0.0.1/32,172.16.0.0/12
export GETBIBLE_DEFAULT_DEPLOY_MODE=staged GETBIBLE_CLOUDFLARE_ENABLED=false
export GETBIBLE_DEFAULT_CLOUDFLARE_MODE=off GETBIBLE_TELEGRAM_ENABLED=false
export GETBIBLE_BIND_ADDRESS=127.0.0.1 GETBIBLE_ORIGIN_HTTP_PORT=80
TEST_ROOT="$(mktemp -d)"
export GETBIBLE_DATA_ROOT="$TEST_ROOT/persistent"
PROJECT="getbible-ci-$$"
PROXY_PID=""
CONTAINER=""
MCP_DOMAIN=mcp.example.test
MCP_ROOT=/opt/getbible/mcp/mcp_example_test
UPGRADE_IMAGES=()
compose() { docker compose --env-file /dev/null -p "$PROJECT" -f "$ROOT/compose.yaml" "$@"; }
container() { compose exec -T --user root getbible "$@"; }
manager() { container env GB_UI=none GB_YES=true GB_VERIFY_PUBLIC=false getbible "$@" --yes; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
GETBIBLE_HTTP_PORT="$(free_port)"
export GETBIBLE_HTTP_PORT
PROXY_PORT="$(free_port)"
cleanup() {
    result="$?"
    trap - EXIT
    if (( result != 0 )); then
        compose logs --no-color --tail 150 || true
        [[ -z "$CONTAINER" ]] || docker exec "$CONTAINER" journalctl --no-pager -n 150 || true
    fi
    [[ -z "$PROXY_PID" ]] || { kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; }
    compose down --timeout 120 || true
    (( ${#UPGRADE_IMAGES[@]} == 0 )) || docker image rm "${UPGRADE_IMAGES[@]}" || true
    # Files belong to the real service users in the image.
    if [[ "$(id -u)" == 0 ]]; then rm -rf "$TEST_ROOT"; else sudo rm -rf "$TEST_ROOT"; fi
    exit "$result"
}
trap cleanup EXIT

# Docker health measures serving APIs. The image apply job has its own durable
# result, so acceptance must also wait for it before asserting upgrade state.
wait_image_update() {
    # shellcheck disable=SC2016 # Read the persisted state inside the container.
    container bash -Eeuo pipefail -c '
        desired=$1 expected=$2 deadline=$((SECONDS + 600))
        state=/var/lib/getbible/state/image-update.conf
        while (( SECONDS < deadline )); do
            if [[ -f "$state" ]] && [[ "$(sed -n "s/^DESIRED_VERSION=//p" "$state")" == "$desired" ]]; then
                status=$(sed -n "s/^STATUS=//p" "$state")
                if [[ "$status" == "$expected" ]]; then cat "$state"; exit 0; fi
                if [[ "$status" == failed && "$expected" != failed ]]; then cat "$state"; exit 1; fi
            fi
            sleep 1
        done
        cat "$state" 2>/dev/null || true
        journalctl -u getbible-image-update.service --no-pager -n 80
        exit 1
    ' -- "$1" "${2:-current}"
}

runtime_generations() {
    # shellcheck disable=SC2016
    container bash -Eeuo pipefail -c 'for kind in query search; do
        for label in v2 v3; do
            test -L "/opt/getbible/$kind/$label/active" || continue
            readlink -f "/opt/getbible/$kind/$label/active"
            readlink -f "/opt/getbible/$kind/$label/current"
        done
    done
    readlink -f /opt/getbible/mcp/mcp_example_test/active
    readlink -f /opt/getbible/mcp/mcp_example_test/current'
}

mcp_protocol() {
    container "$MCP_ROOT/current/.venv/bin/python" /var/lib/getbible/mcp-acceptance.py "${1:-discovery}"
}

mcp_service_checks() {
    # These are the actual unit, account, socket and cgroup, not rendered text.
    # shellcheck disable=SC2016
    container bash -Eeuo pipefail -c '
        root=$1 domain=$2
        generation=$(readlink -f "$root/active")
        unit=$(cat "$generation/.unit")
        socket=$(cat "$generation/.socket")
        systemctl is-active --quiet "$unit.service" "$unit.socket"
        test "$(systemctl show -p Type --value "$unit.service")" = notify
        test "$(systemctl show -p ProtectSystem --value "$unit.service")" = strict
        test "$(systemctl show -p NoNewPrivileges --value "$unit.service")" = yes
        process=$(systemctl show -p MainPID --value "$unit.service")
        test "$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "/proc/$process/status")" = "$(id -u getbible-mcp)"
        test "$(sed -n "s/^CapEff:[[:space:]]*//p" "/proc/$process/status")" = 0000000000000000
        memory_max=$(systemctl show -p MemoryMax --value "$unit.service")
        test "$memory_max" = 268435456
        control_group=$(systemctl show -p ControlGroup --value "$unit.service")
        test "$(cat "/sys/fs/cgroup$control_group/memory.max")" = "$memory_max"
        test -S "$socket"
        test "$(stat -c %U:%G "$socket")" = getbible-mcp:www-data
        test "$(stat -c %a "$socket")" = 660
        runuser -u www-data -- test -w "$socket"
        runuser -u getbible-mcp -- test -w "/var/log/getbible/$domain/app/mcp.log"
        test "$(stat -c %U "/var/log/getbible/$domain/app/mcp.log")" = getbible-mcp
        if runuser -u getbible-mcp -- test -w "$root/current"; then exit 1; fi
        if runuser -u getbible-mcp -- test -r "/etc/getbible/endpoints/$domain/tokens.json"; then exit 1; fi
        test ! -e "/etc/getbible/endpoints/$domain/versions"
        expected=$(sed -n "s/^getbible-mcp==//p" /usr/share/getbible/api/src/apps/mcp/requirements.txt)
        "$root/current/.venv/bin/python" -c "from importlib.metadata import version; import sys; assert version(\"getbible-mcp\") == sys.argv[1]" "$expected"
        "$root/current/.venv/bin/python" -m pip check
    ' -- "$MCP_ROOT" "$MCP_DOMAIN"
}

mcp_telemetry_check() {
    local request_id="$1" tool="$2"
    container /usr/bin/python3 - "$MCP_DOMAIN" "$request_id" "$tool" <<'PY'
import json
from pathlib import Path
import sqlite3
import sys
import time

domain, request_id, tool = sys.argv[1:]
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    with sqlite3.connect("file:/var/lib/getbible/telemetry/traffic.sqlite3?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        row = db.execute("SELECT * FROM requests WHERE endpoint=? AND request_id=?",
                         (domain, request_id)).fetchone()
    if row and row["edge_json"] and row["runtime_json"]:
        edge, runtime = json.loads(row["edge_json"]), json.loads(row["runtime_json"])
        assert row["endpoint_kind"] == "mcp" and row["operation"] == tool, dict(row)
        assert row["version"] == "", dict(row)
        assert edge["request_id"] == runtime["request_id"] == request_id
        assert runtime["mcp_tool"] == tool and runtime["mcp_outcome"] == "success", runtime
        assert runtime["mcp_method"] == "tools/call", runtime
        if tool == "query_verses":
            assert runtime["upstream_service"] == "query" and runtime["upstream_api_version"] == "v2", runtime
        token_file = Path("/var/lib/getbible/mcp-ci-token.json")
        if token_file.exists():
            token = json.loads(token_file.read_text())
            assert row["token_id"] == runtime["token"] == token["id"]
            assert row["auth"] == runtime["auth_state"] == "valid"
            assert token["token"] not in row["edge_json"] + row["runtime_json"]
        print("MCP nginx and service telemetry joined:", tool, request_id)
        break
    time.sleep(0.25)
else:
    raise SystemExit("MCP request did not acquire both nginx and service telemetry")
PY
}

compose config --quiet
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
BASE_VERSION="$(container cat /usr/share/getbible/api/VERSION)"
BASE_IMAGE="$GETBIBLE_IMAGE_REPOSITORY:$GETBIBLE_IMAGE_TAG"
wait_image_update "$BASE_VERSION"
[[ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$CONTAINER")" == false ]]
[[ "$(docker inspect -f '{{.HostConfig.CgroupnsMode}}' "$CONTAINER")" == private ]]
[[ "$(container cat /proc/1/comm)" == systemd ]]
[[ "$(container getbible list)" != *example.test* ]]
container getbible --help >/dev/null
container getbible.sh --help >/dev/null
container test ! -d /usr/share/getbible/api/.git

docker cp "$ROOT/tests/python/fixtures/repository" "$CONTAINER:/srv/getbible/ci-fixture"
container bash -Eeuo pipefail -c 'chown -R root:root /srv/getbible/ci-fixture
chmod -R a+rX /srv/getbible/ci-fixture
cp -a /srv/getbible/ci-fixture/v2 /srv/getbible/ci-fixture/v3
git -C /srv/getbible/ci-fixture init --initial-branch=master
git -C /srv/getbible/ci-fixture add .
git -C /srv/getbible/ci-fixture -c user.name=Fixture -c user.email=fixture@example.test commit -m Fixture
git clone --bare /srv/getbible/ci-fixture /srv/getbible/ci-origin.git
chmod -R a+rX /srv/getbible/ci-origin.git' >/dev/null

# After fixtures are local, remove the network before endpoint deployment.
# This proves no managed Python download, pip index or remote API is needed.
docker network disconnect "${PROJECT}_default" "$CONTAINER"
for kind in query search; do
    manager deploy runtime --domain "$kind.example.test" --kind "$kind" \
        --repository /srv/getbible/ci-fixture --warm test --default-translation test \
        --default-reference Ge1:1 --access open --staged
    container curl --fail --silent -H "Host: $kind.example.test" http://127.0.0.1/readyz \
        | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "ready"'
done
manager deploy static --domain static.example.test --version v2 \
    --repo file:///srv/getbible/ci-origin.git --path v2 --access open --staged
# This local bare fixture is read by the sync account. Match ownership rather
# than disabling Git's ownership checks; production repositories use SSH.
# shellcheck disable=SC2016
container bash -Eeuo pipefail -c 'sync_user=$(sed -n "s/^SYNC_USER=//p" /etc/getbible/endpoints/static.example.test/endpoint.conf)
chown -R "$sync_user" /srv/getbible/ci-origin.git'
manager sync static.example.test v2 --force
# Install and launch the real bundled MCP service while the container has no
# network. The one upstream used below is the already running query fixture.
container sh -c 'cat > /etc/getbible/mcp-fixture.env' <<'ENV'
GETBIBLE_QUERY_V2_BASE=https://query.example.test/v2
GETBIBLE_QUERY_V3_BASE=https://query.example.test/v3
ENV
container sh -c 'cat > /var/lib/getbible/mcp-acceptance.py' <<'PY'
import asyncio
import json
from pathlib import Path
import re
import sys

import httpx2
from mcp import Client
from mcp.client.streamable_http import streamable_http_client
from mcp_types.version import LATEST_PROTOCOL_VERSION


async def main():
    request_ids = []

    async def record(response):
        if response.request.method == "POST" and response.status_code == 200:
            request_ids.append(response.headers.get("x-request-id", ""))

    headers = {"Host": "mcp.example.test"}
    token_file = Path("/var/lib/getbible/mcp-ci-token.json")
    if token_file.exists():
        headers["Authorization"] = "Bearer " + json.loads(token_file.read_text())["token"]
    # Real TCP -> nginx -> systemd socket -> Gunicorn/Uvicorn -> MCP SDK.
    async with (
        httpx2.AsyncClient(headers=headers, event_hooks={"response": [record]},
                          timeout=20, trust_env=False) as http_client,
        Client(streamable_http_client("http://127.0.0.1/", http_client=http_client,
                                      terminate_on_close=False), cache=None) as session,
    ):
        assert session.protocol_version == LATEST_PROTOCOL_VERSION
        tools = await session.list_tools()
        assert {"discover_apis", "query_verses"} <= {tool.name for tool in tools.tools}
        result = await session.call_tool("discover_apis", {"service": "query"})
        assert not result.is_error, result.content
        assert {api["version"] for api in result.structured_content["apis"]} == {"v2", "v3"}
        tool = "discover_apis"
        if sys.argv[1] == "query":
            tool = "query_verses"
            result = await session.call_tool(tool, {"translation": "test", "references": "Ge1:1", "api_version": "v2"})
            assert not result.is_error, result.content
            assert "test_1_1" in result.structured_content["data"], result.structured_content
            assert result.structured_content["source"]["url"] == "https://query.example.test/v2/test/Ge1%3A1"
        request_id = request_ids[-1]
        assert re.fullmatch(r"[0-9a-f]{32}", request_id), request_ids
    print(json.dumps({"request_id": request_id, "tool": tool}))


asyncio.run(main())
PY
manager deploy mcp --domain "$MCP_DOMAIN" --access open --origin http://127.0.0.1:80 \
    --env-file /etc/getbible/mcp-fixture.env --staged
mcp_protocol query > "$TEST_ROOT/mcp-query.json"
mcp_service_checks
mcp_telemetry_check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$TEST_ROOT/mcp-query.json")" query_verses

# Select another interpreter from this image to exercise a real immutable
# release change, then restore the previous release through the normal CLI.
MCP_FIRST_GENERATION="$(container readlink -f "$MCP_ROOT/active")"
MCP_FIRST_RELEASE="$(container readlink -f "$MCP_ROOT/current")"
MCP_FIRST_PYTHON="$(container "$MCP_ROOT/current/.venv/bin/python" -c 'import platform; print(platform.python_version())')"
# shellcheck disable=SC2016 # awk evaluates fields inside the container.
MCP_NEXT_PYTHON="$(container awk -v current="$MCP_FIRST_PYTHON" '$1 !~ /^#/ && NF && $1 != current { print $1; exit }' /usr/share/getbible/runtime/distributions.lock)"
[[ -n "$MCP_NEXT_PYTHON" ]]
manager mcp update "$MCP_DOMAIN" --python "$MCP_NEXT_PYTHON"
[[ "$(container readlink -f "$MCP_ROOT/current")" != "$MCP_FIRST_RELEASE" ]]
mcp_protocol query > /dev/null
manager mcp rollback "$MCP_DOMAIN"
[[ "$(container readlink -f "$MCP_ROOT/current")" == "$MCP_FIRST_RELEASE" ]]
[[ "$(container readlink -f "$MCP_ROOT/active")" != "$MCP_FIRST_GENERATION" ]]
mcp_protocol query > /dev/null
mcp_service_checks
container /usr/share/getbible/api/docker/healthcheck.sh
container curl --fail --silent -H 'Host: query.example.test' http://127.0.0.1/v2/test/Ge1:1 \
    | python3 -c 'import json,sys; assert "test_1_1" in json.load(sys.stdin)'
container curl --fail --silent -H 'Host: search.example.test' http://127.0.0.1/v2/test/beginning \
    | python3 -c 'import json,sys; assert json.load(sys.stdin)["query"]["kind"] == "search"'
container curl --fail --silent -H 'Host: static.example.test' http://127.0.0.1/v2/test/1/1.json >/dev/null
# shellcheck disable=SC2016 # These expressions run inside the container.
container bash -Eeuo pipefail -c 'for kind in query search; do
    generation=$(readlink -f "/opt/getbible/$kind/v2/active")
    unit="getbible-$kind-v2-$(basename "$generation").service"
    test "$(systemctl show -p ProtectSystem --value "$unit")" = strict
    test "$(systemctl show -p PrivateDevices --value "$unit")" = yes
    test "$(systemctl show -p NoNewPrivileges --value "$unit")" = yes
    memory_max=$(systemctl show -p MemoryMax --value "$unit")
    [[ "$memory_max" =~ ^[0-9]+$ && "$memory_max" -gt 0 ]]
    control_group=$(systemctl show -p ControlGroup --value "$unit")
    [[ "$control_group" == /* ]]
    test "$(cat "/sys/fs/cgroup$control_group/memory.max")" = "$memory_max"
    process=$(systemctl show -p MainPID --value "$unit")
    test "$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "/proc/$process/status")" = "$(id -u "getbible-$kind")"
    test "$(sed -n "s/^CapEff:[[:space:]]*//p" "/proc/$process/status")" = 0000000000000000
    "/opt/getbible/$kind/v2/current/.venv/bin/python" -m pip check
done'
container getbible resources --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["enabled"] and p["cgroup_limit_bytes"] == 4*1024**3 and p["budget_bytes"] <= 4*1024**3; assert len(p["endpoints"]) == 2 and p["mcp_reserve_bytes"] >= 512*1024**2'
# Write from inside the running mount namespace: systemd's private temporary
# mounts must not hide a fixture copied through Docker's archive endpoint.
container sh -c 'cat > /run/getbible/infrastructure-ci.py' < "$ROOT/tests/integration/infrastructure.py"
container env GB_CI_DISPOSABLE_HOST=1 /usr/bin/python3 /run/getbible/infrastructure-ci.py --mode docker
docker network connect "${PROJECT}_default" "$CONTAINER"

# Real HAProxy HTTP forwarding: backend address never replaces request Host.
cat > "$TEST_ROOT/haproxy.cfg" <<CONF
global
    maxconn 100
defaults
    mode http
    timeout connect 5s
    timeout client 15s
    timeout server 15s
frontend api
    bind 127.0.0.1:$PROXY_PORT
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]
    default_backend getbible
backend getbible
    server api 127.0.0.1:$GETBIBLE_HTTP_PORT
CONF
haproxy -c -f "$TEST_ROOT/haproxy.cfg"
haproxy -db -f "$TEST_ROOT/haproxy.cfg" &
PROXY_PID="$!"
request() { curl --retry 10 --retry-connrefused --retry-delay 1 --max-time 15 --silent --show-error -H "Host: $1" "http://127.0.0.1:$PROXY_PORT$2" "${@:3}"; }
request query.example.test /v2/test/Ge1:1 --fail | python3 -c 'import json,sys; assert "test_1_1" in json.load(sys.stdin)'
request search.example.test /v2/test/beginning --fail | python3 -c 'import json,sys; assert json.load(sys.stdin)["query"]["kind"] == "search"'
request static.example.test /v2/test/1/1.json --fail >/dev/null

manager token query.example.test add ci-token > "$TEST_ROOT/token.json"
TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$TEST_ROOT/token.json")"
manager access query.example.test token
[[ "$(request query.example.test /v2/test/Ge1:1 -o /dev/null -w '%{http_code}')" == 401 ]]
request query.example.test /v2/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" > /dev/null
manager token "$MCP_DOMAIN" add mcp-ci-token > "$TEST_ROOT/mcp-token.json"
container sh -c 'umask 077; cat > /var/lib/getbible/mcp-ci-token.json' < "$TEST_ROOT/mcp-token.json"
manager access "$MCP_DOMAIN" token
[[ "$(request "$MCP_DOMAIN" / -X POST -H 'Content-Type: application/json' --data '{}' \
    -D "$TEST_ROOT/mcp-denied.headers" -o /dev/null -w '%{http_code}')" == 401 ]]
python3 - "$TEST_ROOT/mcp-denied.headers" <<'PY'
from pathlib import Path
import sys
headers = Path(sys.argv[1]).read_text().lower().splitlines()
assert any(line.startswith("cache-control:") and "no-store" in line for line in headers), headers
PY
for path in /healthz /readyz; do
    request "$MCP_DOMAIN" "$path" --fail | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] in {"ok", "ready"}'
done
for path in /mcp /v2; do
    [[ "$(request "$MCP_DOMAIN" "$path" -o /dev/null -w '%{http_code}')" == 404 ]]
done
# The query fixture is now private; discovery verifies MCP's own token without
# granting it credentials for a separate upstream service.
mcp_protocol > "$TEST_ROOT/mcp-token-call.json"
mcp_telemetry_check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$TEST_ROOT/mcp-token-call.json")" discover_apis
mcp_service_checks
container /usr/local/lib/getbible/getbible-identities show > "$TEST_ROOT/identities-before.json"
container bash -Eeuo pipefail -c 'id getbible-query; id getbible-search; id getbible-mcp; id www-data
stat -Lc "%u:%g" /srv/getbible/static.example.test/v2/test/1/1.json /var/log/getbible/mcp.example.test/app/mcp.log' > "$TEST_ROOT/owners-before"
container bash -Eeuo pipefail -c 'find /var/lib/getbible -name "*.pub" -type f -exec sha256sum {} +' > "$TEST_ROOT/keys-before"
test -s "$TEST_ROOT/keys-before"
container touch /var/log/getbible/recreation-sentinel
# Preserve both the active configuration generation and immutable application
# release. Resource refresh at image startup must not redeploy either one.
runtime_generations > "$TEST_ROOT/generations-before"

# Recreate, do not merely restart: account databases and image root are fresh.
compose down --timeout 120
export GETBIBLE_MEMORY_LIMIT=3g GETBIBLE_CPU_LIMIT=1.5
export GETBIBLE_MEMORY_CACHE_TTL=604800 GETBIBLE_CACHE_MEMORY_PERCENT=35
export GETBIBLE_QUERY_CPU_QUOTA=75% GETBIBLE_SEARCH_CPU_QUOTA=125%
export GETBIBLE_TELEMETRY_RETENTION_DAYS=0 GETBIBLE_TELEMETRY_BATCH_SIZE=37
export GETBIBLE_TELEMETRY_FLUSH_SECONDS=2 GETBIBLE_TELEMETRY_METRICS_SECONDS=1 GETBIBLE_TELEMETRY_MAX_GIB=2
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
wait_image_update "$BASE_VERSION"
container /usr/local/lib/getbible/getbible-identities show > "$TEST_ROOT/identities-after.json"
container bash -Eeuo pipefail -c 'id getbible-query; id getbible-search; id getbible-mcp; id www-data
stat -Lc "%u:%g" /srv/getbible/static.example.test/v2/test/1/1.json /var/log/getbible/mcp.example.test/app/mcp.log' > "$TEST_ROOT/owners-after"
container bash -Eeuo pipefail -c 'find /var/lib/getbible -name "*.pub" -type f -exec sha256sum {} +' > "$TEST_ROOT/keys-after"
cmp "$TEST_ROOT/identities-before.json" "$TEST_ROOT/identities-after.json"
cmp "$TEST_ROOT/owners-before" "$TEST_ROOT/owners-after"
cmp "$TEST_ROOT/keys-before" "$TEST_ROOT/keys-after"
runtime_generations > "$TEST_ROOT/generations-after"
cmp "$TEST_ROOT/generations-before" "$TEST_ROOT/generations-after"
mcp_protocol > /dev/null
mcp_service_checks
container test -f /var/log/getbible/recreation-sentinel
container systemctl is-active --quiet getbible-logrotate.timer
container systemctl is-active --quiet getbible-sync-static_example_test-v2.timer
request query.example.test /v2/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" >/dev/null
[[ "$(request query.example.test /v2/test/Ge1:1 -o /dev/null -w '%{http_code}')" == 401 ]]
request search.example.test /v2/test/beginning --fail >/dev/null
request static.example.test /v2/test/1/1.json --fail >/dev/null
container sh -c 'cat > /run/getbible/infrastructure-ci.py' < "$ROOT/tests/integration/infrastructure.py"
container env GB_CI_DISPOSABLE_HOST=1 "GB_TEST_QUERY_TOKEN=$TOKEN" /usr/bin/python3 /run/getbible/infrastructure-ci.py \
    --mode docker --collector-only --recreated-resources
container /usr/share/getbible/api/docker/healthcheck.sh

# The selected image must deploy both supported API versions using local data.
# The reduced-capacity checks above cover two endpoints. Restore the original
# capacity for four endpoints and their reserved domain-update overlap.
compose down --timeout 120
export GETBIBLE_MEMORY_LIMIT=4g
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
wait_image_update "$BASE_VERSION"
docker network disconnect "${PROJECT}_default" "$CONTAINER"
for kind in query search; do
    manager version add "$kind.example.test" v3 --repository /srv/getbible/ci-fixture \
        --warm test --default-translation test --default-reference Ge1:1
done
docker network connect "${PROJECT}_default" "$CONTAINER"
request query.example.test /v3/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["test_1_1"]["verses"][0]["text"] == "In the beginning God created the heaven and the earth."'
request search.example.test /v3/test/beginning --fail \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["query"]["kind"] == "search" and data["results"]'
runtime_generations > "$TEST_ROOT/image-generations-before"
container sha256sum /srv/getbible/static.example.test/v2/test/1/1.json > "$TEST_ROOT/static-before"

# Derive disposable releases from the exact production image under acceptance.
# Changes affect generation inputs, not bundled wheel hashes. The valid image
# proves actual running services use its new template; the failed image proves
# a candidate cannot replace a serving generation or mark an update complete.
mkdir "$TEST_ROOT/image-fixture"
cp "$ROOT/tests/integration/prepare-image-fixture.sh" "$TEST_ROOT/image-fixture/"
cat > "$TEST_ROOT/image-fixture/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG TEST_VERSION
ARG TEST_FAILURE=false
COPY prepare-image-fixture.sh /tmp/prepare-image-fixture.sh
RUN bash /tmp/prepare-image-fixture.sh /usr/share/getbible/api "$TEST_VERSION" "$TEST_FAILURE" \
    && rm /tmp/prepare-image-fixture.sh
DOCKERFILE
IFS=. read -r image_major image_minor image_patch <<< "$BASE_VERSION"
FAILED_VERSION="$image_major.$image_minor.$((image_patch + 1))"
UPGRADE_VERSION="$image_major.$image_minor.$((image_patch + 2))"
for scenario in failed upgraded; do
    image="$GETBIBLE_IMAGE_REPOSITORY:acceptance-$PROJECT-$scenario"
    UPGRADE_IMAGES+=("$image")
    version="$UPGRADE_VERSION"; failure=false
    if [[ "$scenario" == failed ]]; then version="$FAILED_VERSION"; failure=true; fi
    docker build --network=none --pull=false --tag "$image" \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "TEST_VERSION=$version" \
        --build-arg "TEST_FAILURE=$failure" "$TEST_ROOT/image-fixture"
done

compose down --timeout 120
export GETBIBLE_IMAGE_TAG="acceptance-$PROJECT-failed"
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
wait_image_update "$FAILED_VERSION" failed
[[ "$(container sed -n 's/^APPLIED_VERSION=//p' /var/lib/getbible/state/image-update.conf)" == "$BASE_VERSION" ]]
runtime_generations > "$TEST_ROOT/image-generations-failed"
cmp "$TEST_ROOT/image-generations-before" "$TEST_ROOT/image-generations-failed"
request query.example.test /v3/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" >/dev/null
request search.example.test /v3/test/beginning --fail >/dev/null
mcp_protocol > /dev/null
mcp_service_checks
container /usr/share/getbible/api/docker/healthcheck.sh

# Exercise a versioned history migration with the preceding schema's actual
# table shape. Existing records and collector positions must remain usable.
container systemctl stop getbible-telemetry.service getbible-logrotate.timer getbible-logrotate.service
container /usr/bin/python3 - <<'PY'
import sqlite3
with sqlite3.connect("/var/lib/getbible/telemetry/traffic.sqlite3") as db:
    assert db.execute("SELECT count(*) FROM requests").fetchone()[0] > 0
    db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('acceptance_snapshot','preserved')")
    # Schema 1 had all of the other columns and cursor tables unchanged.
    for column in ("endpoint_kind", "referrer", "book_names"):
        db.execute(f"ALTER TABLE requests DROP COLUMN {column}")
    db.execute("PRAGMA user_version=1")
with sqlite3.connect("/var/lib/getbible/telemetry/traffic.sqlite3") as db:
    with sqlite3.connect("/var/lib/getbible/state/acceptance-history.sqlite3") as expected:
        db.backup(expected)
PY
compose down --timeout 120
export GETBIBLE_IMAGE_TAG="acceptance-$PROJECT-upgraded"
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
wait_image_update "$UPGRADE_VERSION"
[[ "$(container sed -n 's/^APPLIED_VERSION=//p' /var/lib/getbible/state/image-update.conf)" == "$UPGRADE_VERSION" ]]
runtime_generations > "$TEST_ROOT/image-generations-upgraded"
if cmp -s "$TEST_ROOT/image-generations-before" "$TEST_ROOT/image-generations-upgraded"; then
    printf 'The changed image did not replace any runtime generation.\n' >&2
    exit 1
fi
# shellcheck disable=SC2016
container bash -Eeuo pipefail -c 'for kind in query search; do
    for label in v2 v3; do
        generation=$(readlink -f "/opt/getbible/$kind/$label/active")
        unit="getbible-$kind-$label-$(basename "$generation").service"
        systemctl is-active --quiet "$unit"
        process=$(systemctl show -p MainPID --value "$unit")
        tr "\0" "\n" < "/proc/$process/environ" | grep -Fx "GETBIBLE_CI_IMAGE_RELEASE=$1"
    done
done
generation=$(readlink -f /opt/getbible/mcp/mcp_example_test/active)
unit=$(cat "$generation/.unit")
process=$(systemctl show -p MainPID --value "$unit.service")
tr "\0" "\n" < "/proc/$process/environ" | grep -Fx "GETBIBLE_CI_IMAGE_RELEASE=$1"' -- "$UPGRADE_VERSION"
mcp_protocol > "$TEST_ROOT/mcp-upgraded-call.json"
mcp_service_checks
mcp_telemetry_check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$TEST_ROOT/mcp-upgraded-call.json")" discover_apis
container /usr/bin/python3 - <<'PY'
from pathlib import Path
import json
import sqlite3
snapshots = list(Path("/var/backups/getbible/telemetry").glob("traffic-schema-1-*.sqlite3"))
assert len(snapshots) == 1, snapshots
with sqlite3.connect("file:/var/lib/getbible/state/acceptance-history.sqlite3?mode=ro", uri=True) as expected:
    expected.row_factory = sqlite3.Row
    for path, schema in ((snapshots[0], 1), (Path("/var/lib/getbible/telemetry/traffic.sqlite3"), 2)):
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
            db.row_factory = sqlite3.Row
            assert db.execute("PRAGMA user_version").fetchone()[0] == schema
            for table, key in (("requests", "id"), ("events", "id"), ("metrics", "id"),
                               ("retention", "id"), ("metadata", "key"), ("sources", "identity")):
                for row in expected.execute(f"SELECT * FROM {table}"):
                    if schema == 2 and table == "metadata" and row["key"] not in {
                        "acceptance_snapshot", "collection_started", "effective_settings", "retention_policy", "journal_cursor"
                    }:
                        # Collector status, pruning timestamps and alert state
                        # are refreshed normally once collection resumes.
                        continue
                    if schema == 2 and table == "sources" and row["closed"]:
                        # Consumed rotated spools may be retired normally.
                        continue
                    actual = db.execute(f"SELECT * FROM {table} WHERE {key}=?", (row[key],)).fetchone()
                    assert actual is not None, (path, table, row[key])
                    if schema == 2 and table == "sources":
                        # Normal collection can advance a restored position.
                        assert actual["offset"] >= row["offset"], (path, table, row[key])
                    elif schema == 2 and table == "metadata" and row["key"] == "journal_cursor":
                        previous, current = json.loads(row["value"]), json.loads(actual["value"])
                        assert current.get("stamp", 0) >= previous.get("stamp", 0)
                    elif schema == 2 and table == "requests" and (row["edge_json"] is None or row["runtime_json"] is None):
                        # An unmatched record may acquire its other producer
                        # after restart. Its existing raw record is retained.
                        for name in ("endpoint", "request_id", "edge_json", "runtime_json"):
                            if row[name] is not None:
                                assert actual[name] == row[name], (path, table, row[key], name)
                    else:
                        assert {name: actual[name] for name in row.keys()} == dict(row), (path, table, row[key])
            # An upgrade must not introduce a new history cutoff.
            cutoff = "SELECT value FROM metadata WHERE key='collection_started'"
            before, after = expected.execute(cutoff).fetchone(), db.execute(cutoff).fetchone()
            assert (tuple(before) if before else None) == (tuple(after) if after else None)
PY
for label in v2 v3; do
    request query.example.test "/$label/test/Ge1:1" --fail -H "Authorization: Bearer $TOKEN" \
        | python3 -c 'import json,sys; assert "test_1_1" in json.load(sys.stdin)'
    request search.example.test "/$label/test/beginning" --fail \
        | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["query"]["kind"] == "search" and data["results"]'
done
container sha256sum /srv/getbible/static.example.test/v2/test/1/1.json > "$TEST_ROOT/static-upgraded"
cmp "$TEST_ROOT/static-before" "$TEST_ROOT/static-upgraded"
container sh -c 'cat > /run/getbible/infrastructure-ci.py' < "$ROOT/tests/integration/infrastructure.py"
container env GB_CI_DISPOSABLE_HOST=1 "GB_TEST_QUERY_TOKEN=$TOKEN" /usr/bin/python3 /run/getbible/infrastructure-ci.py --mode docker
# Purging one dedicated domain must stop every retained service/socket while
# the versioned query/search APIs continue serving their existing fixtures.
# shellcheck disable=SC2016 # Read generation records inside the container.
container bash -Eeuo pipefail -c 'cat "$1"/deployments/*/.unit' -- "$MCP_ROOT" > "$TEST_ROOT/mcp-units"
test -s "$TEST_ROOT/mcp-units"
manager remove "$MCP_DOMAIN" --purge
# shellcheck disable=SC2016 # Check removal inside the container.
container bash -Eeuo pipefail -c 'test ! -e "$1"
test ! -e "/etc/getbible/endpoints/$2"
test ! -e "/etc/nginx/sites-available/$2.conf"
test ! -L "/etc/nginx/sites-enabled/$2.conf"
while IFS= read -r unit; do
    for suffix in service socket; do
        if systemctl is-active --quiet "$unit.$suffix"; then exit 1; fi
        if systemctl is-enabled --quiet "$unit.$suffix"; then exit 1; fi
    done
done' -- "$MCP_ROOT" "$MCP_DOMAIN" < "$TEST_ROOT/mcp-units"
request query.example.test /v3/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" > /dev/null
request search.example.test /v3/test/beginning --fail > /dev/null
container /usr/share/getbible/api/docker/healthcheck.sh
printf 'Docker acceptance passed: offline v2/v3 and MCP deployment, MCP SDK query/discovery and telemetry, service ownership, token access, rollback/removal, HAProxy routing, recreation, automatic image update, reporting history migration and failed-candidate recovery.\n'
