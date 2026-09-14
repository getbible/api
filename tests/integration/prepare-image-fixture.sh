#!/usr/bin/env bash
# Prepare a disposable checkout for successful or rejected image updates.
set -Eeuo pipefail
[[ $# == 3 ]] || { echo 'Usage: prepare-image-fixture.sh CHECKOUT VERSION true|false' >&2; exit 2; }
checkout="$1"; version="$2"; failure="$3"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
[[ "$failure" == true || "$failure" == false ]]
templates=(
    "$checkout/src/types/runtime/templates/service.tmpl"
    "$checkout/src/systemd/getbible-mcp.service.tmpl"
)

# Check every target before changing any file. A missing or changed template
# must stop fixture preparation instead of silently leaving a healthy service.
for template in "${templates[@]}"; do
    [[ -f "$template" && "$(grep -Fxc '[Service]' "$template")" == 1 ]] || {
        printf 'Expected one [Service] section in %s\n' "$template" >&2
        exit 1
    }
done
for template in "${templates[@]}"; do
    sed -i "/^\[Service\]$/a Environment=GETBIBLE_CI_IMAGE_RELEASE=$version" "$template"
    if [[ "$failure" == true ]]; then
        sed -i '/^\[Service\]$/a ExecStartPre=/bin/false' "$template"
    fi
done
printf '%s\n' "$version" > "$checkout/VERSION"
