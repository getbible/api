#!/usr/bin/env bash
# Immutable release builds for runtime endpoints: one directory per build
# with its own virtual environment, switched by a symlink.

[[ -n "${GB_PYTHON_LOADED:-}" ]] && return 0
GB_PYTHON_LOADED=1

py_app_root() { printf '%s/%s\n' "$GB_OPT" "$1"; }
py_releases_dir() { printf '%s/%s/releases\n' "$GB_OPT" "$1"; }
py_current_link() { printf '%s/%s/current\n' "$GB_OPT" "$1"; }
py_current_release() { readlink -f -- "$(py_current_link "$1")" 2>/dev/null || true; }

# Hash of everything that goes into a release; a change means a rebuild.
py_inputs_hash() {
    local kind="$1"
    {
        find "$GB_APPS/common" "$GB_APPS/$kind" -type f \
            -not -path '*/build/*' -not -path '*.egg-info/*' -not -path '*/__pycache__/*' -not -name '*.pyc' \
            -not -name 'docs.html.tmpl' -not -name 'openapi.json.tmpl' -print0 | sort -z | xargs -0 sha256sum
        sha256sum "$GB_TYPES/runtime/templates/gunicorn.conf.py.tmpl"
    } | sha256sum | cut -c1-16
}

# py_build_release KIND DOMAIN -> prints the release directory
py_build_release() {
    local kind="$1" domain="$2" hash release stamp python
    hash="$(py_inputs_hash "$kind")"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    release="$(py_releases_dir "$kind")/$stamp-$hash"
    python="$GB_PYTHON"
    gb_ensure_dir "$(py_app_root "$kind")" 0755
    gb_ensure_dir "$(py_releases_dir "$kind")" 0755
    gb_step "Building release $release"
    [[ "$GB_DRY_RUN" == true ]] && { printf '%s\n' "$release"; return 0; }
    rm -rf -- "$release"
    install -d -m 0755 "$release/src"
    local app
    for app in common "$kind"; do
        install -d -m 0755 "$release/src/$app"
        tar --exclude=build --exclude='*.egg-info' --exclude=__pycache__ --exclude='*.pyc' \
            -C "$GB_APPS/$app" -cf - . | tar -C "$release/src/$app" -xf -
    done
    "$python" -m venv "$release/.venv"
    "$release/.venv/bin/python" -m pip install --quiet --upgrade pip >/dev/null
    "$release/.venv/bin/python" -m pip install --quiet --require-virtualenv --no-cache-dir \
        --requirement "$release/src/$kind/requirements.txt"
    "$release/.venv/bin/python" -m pip install --quiet --no-deps --no-build-isolation \
        "$release/src/common" "$release/src/$kind" 2>/dev/null \
        || "$release/.venv/bin/python" -m pip install --quiet --no-deps "$release/src/common" "$release/src/$kind"
    "$release/.venv/bin/python" -m pip check >/dev/null
    printf '%s\n' "$hash" > "$release/.inputs"
    rm -rf -- "$release"/src/*/build "$release"/src/*/*.egg-info
    if gb_is_root && [[ -z "$GB_PREFIX" ]]; then
        chown -R root:root "$release"
    fi
    chmod -R go-w,a+rX "$release"
    printf '%s\n' "$release"
}

py_release_inputs() { cat "$1/.inputs" 2>/dev/null || true; }

py_switch_release() {
    local kind="$1" release="$2" link
    link="$(py_current_link "$kind")"
    [[ "$GB_DRY_RUN" == true ]] && return 0
    ln -sfn "$release" "$link.tmp"
    mv -Tf "$link.tmp" "$link"
}

py_prune_releases() {
    local kind="$1" keep="${2:-3}" current dir
    local releases
    current="$(py_current_release "$kind")"
    releases="$(py_releases_dir "$kind")"
    find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | sort -r | tail -n +"$((keep + 1))" | while read -r dir; do
            [[ "$releases/$dir" == "$current" ]] && continue
            rm -rf -- "${releases:?}/${dir:?}"
            gb_log "Removed old release $dir"
        done
}
