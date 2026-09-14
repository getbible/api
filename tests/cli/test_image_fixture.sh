#!/usr/bin/env bash
# The actual image-update fixture must affect every rendered service equally.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
templates=(src/types/runtime/templates/service.tmpl src/systemd/getbible-mcp.service.tmpl)
version="$(cat "$ROOT/VERSION")"

copy_templates() {
    local destination="$1" template
    mkdir -p "$destination"
    cp "$ROOT/VERSION" "$destination/"
    for template in "${templates[@]}"; do
        mkdir -p "$destination/$(dirname "$template")"
        cp "$ROOT/$template" "$destination/$template"
    done
}

for failure in false true; do
    checkout="$TEST_ROOT/$failure"
    copy_templates "$checkout"
    bash "$ROOT/tests/integration/prepare-image-fixture.sh" "$checkout" "$version" "$failure"
    [[ "$(cat "$checkout/VERSION")" == "$version" ]]
    for template in "${templates[@]}"; do
        for extra_env in '' /etc/getbible/mcp.env; do
            arguments=("EXTRA_ENV=$extra_env" RELEASE=/opt/getbible/test-release CHECK=test_api.check)
            "$ROOT/src/bin/getbible-render" "$ROOT/$template" "${arguments[@]}" > "$TEST_ROOT/original.unit"
            "$ROOT/src/bin/getbible-render" "$checkout/$template" "${arguments[@]}" > "$TEST_ROOT/candidate.unit"
            [[ "$(grep -Fxc "Environment=GETBIBLE_CI_IMAGE_RELEASE=$version" "$TEST_ROOT/candidate.unit")" == 1 ]]
            if [[ "$failure" == true ]]; then
                [[ "$(grep -Fxc 'ExecStartPre=/bin/false' "$TEST_ROOT/candidate.unit")" == 1 ]]
                [[ "$(sed -n '/^ExecStartPre=/{p;q;}' "$TEST_ROOT/candidate.unit")" == 'ExecStartPre=/bin/false' ]]
            else
                if grep -Fxq 'ExecStartPre=/bin/false' "$TEST_ROOT/candidate.unit"; then exit 1; fi
            fi
            # Original startup checks, application command and isolation all
            # remain byte-for-byte intact in both template branches.
            sed '/^Environment=GETBIBLE_CI_IMAGE_RELEASE=/d; /^ExecStartPre=\/bin\/false$/d' \
                "$TEST_ROOT/candidate.unit" > "$TEST_ROOT/preserved.unit"
            cmp "$TEST_ROOT/original.unit" "$TEST_ROOT/preserved.unit"
        done
    done
done

# An unsupported template must reject the whole fixture before mutation.
checkout="$TEST_ROOT/incomplete"
copy_templates "$checkout"
sed -i '/^\[Service\]$/d' "$checkout/${templates[1]}"
if bash "$ROOT/tests/integration/prepare-image-fixture.sh" "$checkout" "$version" true 2>/dev/null; then
    echo 'Incomplete service fixture was accepted.' >&2
    exit 1
fi
cmp "$ROOT/${templates[0]}" "$checkout/${templates[0]}"
cmp "$ROOT/VERSION" "$checkout/VERSION"
printf 'Image update fixtures preserve service contracts and reject every intended candidate: ok\n'
