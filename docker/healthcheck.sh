#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f /run/getbible/container-initialized ]]
systemctl is-active --quiet nginx.service
curl --fail --silent --show-error --noproxy '*' --max-time 3 \
    -H 'Host: _' http://127.0.0.1/__getbible_health >/dev/null
# Check only the selected generations. Failed upgrade candidates must not
# mark a healthy, serving previous generation as an unhealthy container.
shopt -s nullglob
for environment in /opt/getbible/*/*/active/runtime.env; do
    # Runtime environment files use systemd's double-quoted assignment form.
    socket="$(sed -nE 's/^[A-Z_]+_BIND="?unix:([^"[:space:]]*)"?$/\1/p' "$environment")"
    [[ -n "$socket" ]]
    curl --fail --silent --show-error --noproxy '*' --max-time 3 \
        --unix-socket "$socket" http://localhost/readyz >/dev/null
done
