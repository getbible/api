#!/usr/bin/env bash
# Detect host capabilities without coupling application Python to distro Python.

[[ -n "${GB_PLATFORM_LOADED:-}" ]] && return 0
GB_PLATFORM_LOADED=1

platform_detect() {
    local key value os_release="${GB_OS_RELEASE:-/etc/os-release}"
    PLATFORM_OS="$(uname -s)"
    PLATFORM_ARCH="$(uname -m)"
    PLATFORM_ID=unknown
    PLATFORM_VERSION=unknown
    PLATFORM_NAME="$PLATFORM_OS"
    # /etc/os-release is data, not shell code. Do not source an override file.
    if [[ -r "$os_release" ]]; then
        while IFS='=' read -r key value; do
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            case "$key" in
                ID) PLATFORM_ID="$value" ;;
                VERSION_ID) PLATFORM_VERSION="$value" ;;
                PRETTY_NAME) PLATFORM_NAME="$value" ;;
            esac
        done < "$os_release"
    fi
    case "$PLATFORM_ARCH" in
        amd64) PLATFORM_ARCH=x86_64 ;;
        arm64) PLATFORM_ARCH=aarch64 ;;
    esac
    PLATFORM_LIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    PLATFORM_PACKAGE_MANAGER=manual
    command -v apt-get >/dev/null 2>&1 && PLATFORM_PACKAGE_MANAGER=apt
    return 0
}

platform_default_python() {
    platform_detect
    case "$PLATFORM_ID:$PLATFORM_VERSION" in
        ubuntu:22.04|ubuntu:24.04) printf '3.12\n' ;;
        *) printf '3.14\n' ;;
    esac
}

platform_require_runtime() {
    platform_detect
    [[ "$PLATFORM_OS" == Linux ]] || gb_die "Runtime deployment requires Linux; detected $PLATFORM_OS."
    case "$PLATFORM_ARCH" in
        x86_64|aarch64) ;;
        *) gb_die "No reviewed managed CPython distribution for architecture $PLATFORM_ARCH." ;;
    esac
    [[ "$PLATFORM_LIBC" == 'glibc '* ]] || gb_die "Managed runtimes require glibc Linux; detected ${PLATFORM_LIBC:-unknown libc}."
    local libc_version="${PLATFORM_LIBC#glibc }"
    [[ "$(printf '%s\n' 2.28 "$libc_version" | sort -V | head -n1)" == 2.28 ]] \
        || gb_die "Managed runtimes need glibc 2.28 or newer; detected $libc_version."
}

platform_report() {
    platform_detect
    printf '%s (%s %s), %s, %s; package installation: %s\n' \
        "$PLATFORM_NAME" "$PLATFORM_ID" "$PLATFORM_VERSION" "$PLATFORM_ARCH" \
        "${PLATFORM_LIBC:-unknown libc}" "$PLATFORM_PACKAGE_MANAGER"
}
