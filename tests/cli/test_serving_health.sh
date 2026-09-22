#!/usr/bin/env bash
# All selected service kinds are checked without coupling health to an upgrade.
# shellcheck disable=SC2329 # healthcheck_main invokes these command stand-ins.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
# shellcheck source=../../docker/healthcheck.sh
source "$ROOT/docker/healthcheck.sh"
mkdir -p "$T/run/getbible" "$T/opt/getbible/query/v2/active" "$T/opt/getbible/mcp/mcp_example_test/active"
touch "$T/run/getbible/container-initialized"
printf 'QUERY_BIND="unix:/run/query.sock"\n' > "$T/opt/getbible/query/v2/active/runtime.env"
printf '/run/mcp.sock\n' > "$T/opt/getbible/mcp/mcp_example_test/active/.socket"
printf 'DASHBOARD_ENABLED=true\nDASHBOARD_DOMAIN=dashboard.example.test\n' > "$T/run/getbible/dashboard.conf"
mkdir -p "$T/etc/getbible/endpoints/query.example.test/versions" "$T/etc/getbible/endpoints/mcp.example.test"
printf 'TYPE=runtime\nKIND=query\nENABLED=true\n' > "$T/etc/getbible/endpoints/query.example.test/endpoint.conf"
printf 'ENABLED=true\n' > "$T/etc/getbible/endpoints/query.example.test/versions/v2.conf"
printf 'TYPE=mcp\nENABLED=true\n' > "$T/etc/getbible/endpoints/mcp.example.test/endpoint.conf"
FAIL=''
curl() { printf '%s\n' "$*" >> "$T/calls"; [[ -z "$FAIL" || "$*" != *"$FAIL"* ]]; }
systemctl() { [[ "$*" == 'is-active --quiet nginx.service' ]]; }
: > "$T/calls"
healthcheck_main "$T"
[[ "$(wc -l < "$T/calls")" == 4 ]]
grep -qF -- '--unix-socket /run/mcp.sock' "$T/calls"
grep -qF 'Host: dashboard.example.test' "$T/calls"
# The existence of broken unselected candidates or failed upgrade state does
# not falsify the readiness of selected, still-serving generations.
mkdir -p "$T/opt/getbible/query/v2/deployments/rejected" "$T/var/lib/getbible/state"
printf 'STATUS=failed\n' > "$T/var/lib/getbible/state/image-update.conf"
healthcheck_main "$T"
for FAIL in query.sock mcp.sock getbible-dashboard/http.sock __getbible_health; do
    if healthcheck_main "$T"; then printf 'Failed service accepted: %s\n' "$FAIL" >&2; exit 1; fi
done
FAIL=getbible-dashboard/http.sock
printf 'DASHBOARD_ENABLED=false\n' > "$T/run/getbible/dashboard.conf"
healthcheck_main "$T"
FAIL=''
# Disabled endpoints and domains may retain failed or missing generations.
mkdir -p "$T/opt/getbible/query/v3/active"
printf 'QUERY_BIND="unix:/run/disabled.sock"\n' > "$T/opt/getbible/query/v3/active/runtime.env"
printf 'ENABLED=false\n' > "$T/etc/getbible/endpoints/query.example.test/versions/v3.conf"
FAIL=disabled.sock
healthcheck_main "$T"
printf 'TYPE=runtime\nKIND=query\nENABLED=false\n' > "$T/etc/getbible/endpoints/query.example.test/endpoint.conf"
FAIL=query.sock
healthcheck_main "$T"
printf 'TYPE=runtime\nKIND=query\nENABLED=true\n' > "$T/etc/getbible/endpoints/query.example.test/endpoint.conf"
FAIL=''
# Custom origin ports follow deployment overrides and reject invalid values.
: > "$T/calls"
GETBIBLE_ORIGIN_HTTP_PORT=8081 healthcheck_main "$T"
grep -qF 'http://127.0.0.1:8081/__getbible_health' "$T/calls"
if GETBIBLE_ORIGIN_HTTP_PORT=65536 healthcheck_main "$T"; then echo 'Invalid origin port accepted' >&2; exit 1; fi
FAIL=''
mv "$T/opt/getbible/query/v2/active/runtime.env" "$T/runtime-saved.env"
if healthcheck_main "$T"; then echo 'Missing selected runtime accepted' >&2; exit 1; fi
mv "$T/runtime-saved.env" "$T/opt/getbible/query/v2/active/runtime.env"
rm "$T/opt/getbible/mcp/mcp_example_test/active/.socket"
if healthcheck_main "$T" 2>/dev/null; then echo 'Missing selected MCP socket accepted' >&2; exit 1; fi
[[ "$(cat "$T/var/lib/getbible/state/image-update.conf")" == STATUS=failed ]]
printf 'Serving health covers selected runtimes, MCP and enabled dashboard without mutating upgrade state\n'
