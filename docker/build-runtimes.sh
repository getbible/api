#!/usr/bin/env bash
# Build the complete offline runtime payload while constructing the image.
# This is never run at container startup or by an endpoint deployment.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export GB_REPO_DIR="$ROOT" GB_EXECUTION_MODE=native GETBIBLE_EXECUTION_MODE=native
# shellcheck source=../src/lib/core.sh
source "$ROOT/src/lib/core.sh"
# shellcheck source=../src/lib/config.sh
source "$ROOT/src/lib/config.sh"
# shellcheck source=../src/lib/python.sh
source "$ROOT/src/lib/python.sh"

bundle="${1:-/usr/share/getbible/runtime}"
[[ "$bundle" == /* && "$bundle" != / ]] || gb_die "Runtime bundle must be an absolute directory."
[[ ! -e "$bundle/distributions.lock" ]] || gb_die "Runtime bundle already exists: $bundle"
install -d -m 0755 "$bundle" "$bundle/python" "$bundle/wheels"
build_root="$(mktemp -d "$bundle/.build.XXXXXXXX")"
trap 'rm -rf -- "$build_root"; gb_cleanup' EXIT
GB_OPT="$build_root/managed"
declare -a selections=() versions=()
IFS=', ' read -r -a selections <<< "${GETBIBLE_IMAGE_PYTHONS:-3.12 3.13 3.14}"
[[ ${#selections[@]} -gt 0 ]] || gb_die "GETBIBLE_IMAGE_PYTHONS must select at least one reviewed Python version."
for selection in "${selections[@]}"; do
    versions+=("$(py_resolve_version "$selection")")
done
mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -Vu)
: > "$bundle/distributions.lock"

for version in "${versions[@]}"; do
    python="$(py_managed_install "$version")"
    distribution_root="${python%/bin/python3}"
    identity="$(basename -- "$distribution_root")"
    cp -a -- "$distribution_root" "$bundle/python/$identity"
    cat "$distribution_root/.distribution" >> "$bundle/distributions.lock"
    build_env="$build_root/build-$version"
    "$python" -I -m venv "$build_env"
    "$build_env/bin/python" -I -m pip --isolated --disable-pip-version-check install --quiet \
        --no-cache-dir --only-binary=:all: --no-deps --require-hashes \
        --requirement "$GB_SRC/python/build-requirements.txt"
    for manifest in "$GB_APPS"/*/manifest.conf; do
        app="$(basename -- "$(dirname -- "$manifest")")"
        package="$(cfg_get "$manifest" PACKAGE)"
        [[ "$package" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || gb_die "Invalid runtime package in $manifest"
        wheels="$bundle/wheels/$version/$app"
        install -d -m 0755 "$wheels"
        gb_step "Building offline wheels for $app on CPython $version"
        "$build_env/bin/python" -I -m pip --isolated --disable-pip-version-check download --quiet \
            --no-cache-dir --only-binary=:all: --no-deps --require-hashes \
            --dest "$wheels" --requirement "$GB_SRC/python/build-requirements.txt"
        "$build_env/bin/python" -I -m pip --isolated --disable-pip-version-check download --quiet \
            --no-cache-dir --only-binary=:all: --no-deps \
            --dest "$wheels" --requirement "$GB_APPS/$app/requirements.txt"
        # Installing the complete pinned set also supplies the packaging
        # dependency of wheel; local project builds cannot fetch build tools.
        "$build_env/bin/python" -I -m pip --isolated --disable-pip-version-check install --quiet \
            --no-cache-dir --no-index --find-links "$wheels" --only-binary=:all: \
            --requirement "$GB_APPS/$app/requirements.txt"
        "$build_env/bin/python" -I -m pip --isolated --disable-pip-version-check wheel --quiet \
            --no-cache-dir --no-index --no-deps --no-build-isolation \
            --wheel-dir "$wheels" "$GB_APPS/common" "$GB_APPS/$app"
        # Lock every wheel, including the two application packages, by its
        # actual build artifact digest. No deployment index access is needed.
        "$build_env/bin/python" -I - "$wheels" <<'PY'
from email.parser import BytesParser
import hashlib
from pathlib import Path
import re
import sys
import zipfile

root = Path(sys.argv[1])
entries = {}
for wheel in sorted(root.glob("*.whl")):
    with zipfile.ZipFile(wheel) as archive:
        metadata = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
        if len(metadata) != 1:
            raise SystemExit(f"Invalid wheel metadata: {wheel.name}")
        fields = BytesParser().parsebytes(archive.read(metadata[0]))
    name, version = fields["Name"], fields["Version"]
    normalized = re.sub(r"[-_.]+", "-", name).lower()
    if normalized in entries:
        raise SystemExit(f"Duplicate distribution in wheel bundle: {name}")
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    entries[normalized] = f"{name}=={version} --hash=sha256:{digest}\n"
if not entries:
    raise SystemExit("The runtime wheel bundle is empty")
(root / "packages.requirements").write_text("".join(entries[key] for key in sorted(entries)))
PY
        py_inputs_hash "$app" "$version" > "$wheels/.inputs"
        # A fresh environment proves completeness without accidentally using
        # packages already present in the image-build environment.
        verify_env="$build_root/verify-$version-$app"
        "$python" -I -m venv "$verify_env"
        "$verify_env/bin/python" -I -m pip --isolated --disable-pip-version-check install --quiet \
            --no-cache-dir --no-index --find-links "$wheels" --only-binary=:all: \
            --require-hashes --requirement "$wheels/packages.requirements"
        "$verify_env/bin/python" -I -m pip check
        "$verify_env/bin/python" -I -c 'import importlib, sys; import getbible, gunicorn; importlib.import_module(sys.argv[1] + ".app")' "$package"
        rm -rf -- "$verify_env" "$GB_APPS/$app/build" "$GB_APPS/common/build"
        find "$GB_APPS/$app" "$GB_APPS/common" -maxdepth 1 -type d -name '*.egg-info' -exec rm -rf -- {} +
    done
    rm -rf -- "$build_env"
done
chmod -R go-w,a+rX "$bundle"
gb_log "Offline runtime payload prepared for Python $(printf '%s ' "${versions[@]}")"
