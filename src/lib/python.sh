#!/usr/bin/env bash
# Immutable managed CPython distributions and endpoint release builds.
# Neither interpreter, stdlib nor packages refer to the host Python install.

[[ -n "${GB_PYTHON_LOADED:-}" ]] && return 0
GB_PYTHON_LOADED=1
# shellcheck source=platform.sh
source "${GB_LIB:-$(dirname -- "${BASH_SOURCE[0]}")}/platform.sh"

py_app_root() { printf '%s/%s\n' "$GB_OPT" "$1"; }
py_releases_dir() { printf '%s/%s/releases\n' "$GB_OPT" "$1"; }
py_current_link() { printf '%s/%s/current\n' "$GB_OPT" "$1"; }
py_current_release() { readlink -f -- "$(py_current_link "$1")" 2>/dev/null || true; }
py_distributions_file() { printf '%s/python/distributions.lock\n' "$GB_SRC"; }

py_catalog() {
    printf 'VERSION    ARCH       BUILD\n'
    awk '$1 !~ /^#/ && NF {printf "%-10s %-10s %s\n", $1, $2, $3}' "$(py_distributions_file)"
}

# A deployed exact patch remains usable after a catalog refresh removes its
# download entry. Its application-owned provenance stays with the interpreter.
py_installed_distribution() {
    local version="$1" record
    platform_detect
    for record in "$(py_managed_root)"/cpython-"$version"-*-"$PLATFORM_ARCH"-*/.distribution; do
        [[ -f "$record" ]] || continue
        awk -v version="$version" -v arch="$PLATFORM_ARCH" '$1 == version && $2 == arch {print; exit}' "$record"
        return 0
    done
}

# Resolve a reviewed family/exact patch, never query a changing upstream index.
py_resolve_version() {
    local requested="${1:-auto}" resolved
    [[ "$requested" == auto ]] && requested="$(platform_default_python)"
    [[ "$requested" =~ ^3\.(12|13|14)(\.[0-9]+)?$ ]] \
        || gb_die "Python must be auto, 3.12, 3.13, 3.14, or an exact reviewed patch."
    resolved="$(awk -v wanted="$requested" '$1 !~ /^#/ && ($1 == wanted || index($1, wanted ".") == 1) {print $1}' "$(py_distributions_file)" | sort -Vu | tail -n1)"
    if [[ -z "$resolved" && "$requested" =~ ^3\.(12|13|14)\.[0-9]+$ && -n "$(py_installed_distribution "$requested")" ]]; then
        resolved="$requested"
    fi
    [[ -n "$resolved" ]] || gb_die "Python $requested is not in src/python/distributions.lock; update the reviewed catalog first."
    printf '%s\n' "$resolved"
}

# Complete row: VERSION ARCH BUILD SHA256 URL. The checksum is the immutable
# runtime identity, including upstream rebuilds of the same Python patch.
py_distribution() {
    local version
    version="$(py_resolve_version "${1:-auto}")" || return 1
    platform_require_runtime
    local row
    row="$(awk -v version="$version" -v arch="$PLATFORM_ARCH" '$1 == version && $2 == arch {print; exit}' "$(py_distributions_file)")"
    [[ -n "$row" ]] || row="$(py_installed_distribution "$version")"
    [[ -n "$row" ]] || gb_die "No reviewed Python $version distribution for $PLATFORM_ARCH."
    printf '%s\n' "$row"
}

py_managed_root() { printf '%s/python\n' "$GB_OPT"; }

py_verify_interpreter() {
    local root="$1" version="$2"
    "$root/bin/python3" -I -c '
import bz2, ctypes, encodings, lzma, pathlib, sqlite3, ssl, sys, venv
root = pathlib.Path(sys.argv[1]).resolve()
assert sys.version.split()[0] == sys.argv[2], sys.version
for path in (sys.executable, sys.prefix, sys.base_prefix, encodings.__file__):
    assert pathlib.Path(path).resolve().is_relative_to(root), path
' "$root" "$version"
}

# Installs only into a new, unreferenced directory. An already installed
# distribution is read-only to service users and is never upgraded in place.
py_managed_install() (
    local row version arch build digest url identity target stage='' archive lock_fd
    row="$(py_distribution "${1:-auto}")" || exit 1
    IFS=' ' read -r version arch build digest url <<< "$row"
    [[ "$digest" =~ ^[a-f0-9]{64}$ && "$build" =~ ^[0-9]{8}$ ]] || gb_die "Malformed reviewed Python distribution."
    [[ "$url" == https://github.com/astral-sh/python-build-standalone/releases/download/* ]] \
        || gb_die "Managed Python must come from the reviewed standalone release source."
    identity="cpython-$version-$build-$arch-${digest:0:16}"
    target="$(py_managed_root)/$identity"
    [[ "$GB_DRY_RUN" == true ]] && { printf '%s/bin/python3\n' "$target"; exit 0; }
    gb_ensure_dir "$(py_managed_root)" 0755
    exec {lock_fd}> "$(py_managed_root)/.install.lock"
    flock -x "$lock_fd" || exit 1
    if [[ -d "$target" ]]; then
        [[ -x "$target/bin/python3" && "$(cat "$target/.distribution" 2>/dev/null)" == "$row" ]] \
            || gb_die "Incomplete managed Python installation: $target. Existing runtimes have not been changed."
        py_verify_interpreter "$target" "$version" || exit 1
        printf '%s/bin/python3\n' "$target"
        exit 0
    fi
    stage="$(mktemp -d "$(py_managed_root)/.install.XXXXXXXX")" || exit 1
    trap '[[ -z "$stage" ]] || rm -rf -- "$stage"' EXIT
    archive="$stage/python.tar.gz"
    gb_step "Installing managed CPython $version ($arch, build $build)"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 900 --retry 3 --output "$archive" "$url" || exit 1
    [[ "$(gb_sha256_file "$archive")" == "$digest" ]] || gb_die "Managed Python checksum mismatch; refusing to extract $url."
    mkdir "$stage/tree" || exit 1
    tar -xzf "$archive" --strip-components=1 --no-same-owner -C "$stage/tree" || exit 1
    # Verify the executable and its stdlib before publishing the installation.
    py_verify_interpreter "$stage/tree" "$version" || exit 1
    printf '%s\n' "$row" > "$stage/tree/.distribution" || exit 1
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown -R root:root "$stage/tree" || exit 1
    fi
    chmod -R go-w,a+rX "$stage/tree" || exit 1
    mv -T -- "$stage/tree" "$target" || exit 1
    # Standalone Python is relocatable; prove that its stdlib still resolves
    # beneath the final owned path before allowing a release to reference it.
    py_verify_interpreter "$target" "$version" || { rm -rf -- "$target"; exit 1; }
    printf '%s/bin/python3\n' "$target"
)

# Hash all release inputs by relative name, so moving/updating the manager
# checkout does not cause a rebuild. Interpreter/build tooling are inputs too.
py_inputs_hash() {
    local kind="$1" distribution
    distribution="$(py_distribution "${2:-auto}")" || return 1
    {
        printf '%s\n' "$distribution"
        (
            cd "$GB_SRC" || exit 1
            find "apps/common" "apps/$kind" -type f \
                -not -path '*/build/*' -not -path '*.egg-info/*' -not -path '*/__pycache__/*' -not -name '*.pyc' \
                -not -name 'docs.html.tmpl' -not -name 'openapi.json.tmpl' -print0 | sort -z | xargs -0 sha256sum
            sha256sum python/build-requirements.txt lib/python.sh
        )
    } | sha256sum | cut -c1-16
}

# py_build_release KIND DOMAIN [PYTHON_VERSION] -> new release directory.
# Build in its final path so venv shebangs survive activation; this directory
# remains unreachable from serving symlinks until the caller verifies it.
py_build_release() (
    local kind="$1" domain="$2" requested="${3:-auto}" hash release='' stamp python version app complete=false
    hash="$(py_inputs_hash "$kind" "$requested")" || exit 1
    version="$(py_resolve_version "$requested")" || exit 1
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ "$GB_DRY_RUN" == true ]]; then
        printf '%s/%s-%s-preview\n' "$(py_releases_dir "$kind")" "$stamp" "$hash"
        exit 0
    fi
    python="$(py_managed_install "$version")" || exit 1
    gb_ensure_dir "$(py_app_root "$kind")" 0755
    gb_ensure_dir "$(py_releases_dir "$kind")" 0755
    release="$(mktemp -d "$(py_releases_dir "$kind")/$stamp-$hash-XXXXXXXX")" || exit 1
    trap '[[ "$complete" == true || -z "$release" ]] || rm -rf -- "$release"' EXIT
    gb_step "Building $domain release $release with managed Python $version"
    install -d -m 0755 "$release/src" || exit 1
    for app in common "$kind"; do
        install -d -m 0755 "$release/src/$app" || exit 1
        tar --exclude=build --exclude='*.egg-info' --exclude=__pycache__ --exclude='*.pyc' \
            -C "$GB_APPS/$app" -cf - . | tar -C "$release/src/$app" -xf - || exit 1
    done
    "$python" -I -m venv "$release/.venv" || exit 1
    "$release/.venv/bin/python" -I -c '
import encodings, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
assert pathlib.Path(sys.base_prefix).resolve() == root
assert pathlib.Path(encodings.__file__).resolve().is_relative_to(root)
' "$(dirname "$(dirname "$python")")" || exit 1
    "$release/.venv/bin/python" -I -m pip --disable-pip-version-check install --quiet --no-cache-dir \
        --require-virtualenv --only-binary=:all: --no-deps --require-hashes \
        --requirement "$GB_SRC/python/build-requirements.txt" >&2 || exit 1
    "$release/.venv/bin/python" -I -m pip --disable-pip-version-check install --quiet --require-virtualenv --no-cache-dir \
        --only-binary=:all: --requirement "$release/src/$kind/requirements.txt" >&2 || exit 1
    "$release/.venv/bin/python" -I -m pip --disable-pip-version-check install --quiet --require-virtualenv \
        --no-deps --no-build-isolation "$release/src/common" "$release/src/$kind" >&2 || exit 1
    "$release/.venv/bin/python" -I -m pip check >&2 || exit 1
    "$release/.venv/bin/python" -I -m pip freeze --all > "$release/packages.lock" || exit 1
    printf '%s\n' "$hash" > "$release/.inputs" || exit 1
    printf '%s\n' "$version" > "$release/.python-version" || exit 1
    cp "$(dirname "$(dirname "$python")")/.distribution" "$release/.python-distribution" || exit 1
    rm -rf -- "$release"/src/*/build "$release"/src/*/*.egg-info
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown -R root:root "$release" || exit 1
    fi
    chmod -R go-w,a+rX "$release" || exit 1
    complete=true
    printf '%s\n' "$release"
)

py_release_inputs() { cat "$1/.inputs" 2>/dev/null || true; }

py_switch_release() {
    local kind="$1" release="$2" link
    link="$(py_current_link "$kind")"
    [[ "$GB_DRY_RUN" == true ]] && return 0
    gb_switch_link "$release" "$link"
}

py_prune_releases() {
    local kind="$1" keep="${2:-3}" current dir reference protected releases
    current="$(py_current_release "$kind")"
    releases="$(py_releases_dir "$kind")"
    [[ "$GB_DRY_RUN" == true ]] && return 0
    [[ -d "$releases" ]] || return 0
    find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | sort -r | tail -n +"$((keep + 1))" | while read -r dir; do
            [[ "$releases/$dir" == "$current" ]] && continue
            protected=false
            for reference in "$(py_app_root "$kind")"/deployments/*/.release; do
                [[ -f "$reference" ]] || continue
                if [[ "$(cat "$reference")" == "$releases/$dir" ]]; then protected=true; break; fi
            done
            [[ "$protected" == true ]] && continue
            rm -rf -- "${releases:?}/${dir:?}"
            gb_log "Removed old release $dir"
        done
}
