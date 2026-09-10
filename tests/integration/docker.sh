#!/usr/bin/env bash
# Disposable acceptance of the actual production Compose profile and image.
# Uses fixture scripture only; no Cloudflare or certificate requests are made.
set -Eeuo pipefail
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
    # Files belong to the real service users in the image.
    if [[ "$(id -u)" == 0 ]]; then rm -rf "$TEST_ROOT"; else sudo rm -rf "$TEST_ROOT"; fi
    exit "$result"
}
trap cleanup EXIT

compose config --quiet
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
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
    test "$(systemctl show -p MemoryMax --value "$unit")" != infinity
    process=$(systemctl show -p MainPID --value "$unit")
    test "$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "/proc/$process/status")" = "$(id -u "getbible-$kind")"
    test "$(sed -n "s/^CapEff:[[:space:]]*//p" "/proc/$process/status")" = 0000000000000000
    "/opt/getbible/$kind/v2/current/.venv/bin/python" -m pip check
done'
container getbible resources --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["enabled"] and p["cgroup_limit_bytes"] == 4*1024**3 and p["budget_bytes"] <= 4*1024**3; assert len(p["endpoints"]) == 2'
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
container /usr/local/lib/getbible/getbible-identities show > "$TEST_ROOT/identities-before.json"
container bash -Eeuo pipefail -c 'id getbible-query; id getbible-search; id www-data; stat -Lc "%u:%g" /srv/getbible/static.example.test/v2/test/1/1.json' > "$TEST_ROOT/owners-before"
container bash -Eeuo pipefail -c 'find /var/lib/getbible -name "*.pub" -type f -exec sha256sum {} +' > "$TEST_ROOT/keys-before"
test -s "$TEST_ROOT/keys-before"
container touch /var/log/getbible/recreation-sentinel

# Recreate, do not merely restart: account databases and image root are fresh.
compose down --timeout 120
compose up -d --wait --wait-timeout 240
CONTAINER="$(compose ps -q getbible)"
container /usr/local/lib/getbible/getbible-identities show > "$TEST_ROOT/identities-after.json"
container bash -Eeuo pipefail -c 'id getbible-query; id getbible-search; id www-data; stat -Lc "%u:%g" /srv/getbible/static.example.test/v2/test/1/1.json' > "$TEST_ROOT/owners-after"
container bash -Eeuo pipefail -c 'find /var/lib/getbible -name "*.pub" -type f -exec sha256sum {} +' > "$TEST_ROOT/keys-after"
cmp "$TEST_ROOT/identities-before.json" "$TEST_ROOT/identities-after.json"
cmp "$TEST_ROOT/owners-before" "$TEST_ROOT/owners-after"
cmp "$TEST_ROOT/keys-before" "$TEST_ROOT/keys-after"
container test -f /var/log/getbible/recreation-sentinel
container systemctl is-active --quiet getbible-logrotate.timer
container systemctl is-active --quiet getbible-sync-static_example_test-v2.timer
request query.example.test /v2/test/Ge1:1 --fail -H "Authorization: Bearer $TOKEN" >/dev/null
[[ "$(request query.example.test /v2/test/Ge1:1 -o /dev/null -w '%{http_code}')" == 401 ]]
request search.example.test /v2/test/beginning --fail >/dev/null
request static.example.test /v2/test/1/1.json --fail >/dev/null
container /usr/share/getbible/api/docker/healthcheck.sh
printf 'Docker acceptance passed: offline deployment, systemd isolation, HAProxy routing, tokens and full recreation.\n'
