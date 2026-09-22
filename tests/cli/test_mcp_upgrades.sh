#!/usr/bin/env bash
# Isolated MCP upgrade transactions; no services, network, or production paths.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
# shellcheck source=../../src/lib/mcp.sh
source "$ROOT/src/lib/mcp.sh"
GB_OPT="$T/opt"; GB_RUN="$T/run"; GB_DRY_RUN=false
MODE=docker
calls="$T/calls"
: > "$calls"
gb_warn() { printf '%s\n' "$*" >&2; }
gb_is_docker() { [[ "$MODE" == docker ]]; }
gb_slug() { printf '%s\n' "$1"; }
py_bundle_root() { printf '%s\n' "$T/bundle"; }
py_inputs_hash() { printf 'reviewed\n'; }
py_resolve_version() {
    case "$1" in 3.12|3.12.14) printf '3.12.14\n' ;; 3.13|3.13.11) printf '3.13.11\n' ;; *) return 1 ;; esac
}
[[ "$(mcp_update_python 3.12.1)" == 3.12.14 ]]
[[ "$(mcp_update_python 3.13.1)" == 3.13.11 ]]
if mcp_update_python 3.14.1; then echo 'missing family accepted' >&2; exit 1; fi
if mcp_bundle_preflight 3.12.14 reviewed; then echo 'missing bundle accepted' >&2; exit 1; fi
mkdir -p "$T/bundle/wheels/3.12.14/mcp"
printf 'package==1\n' > "$T/bundle/wheels/3.12.14/mcp/packages.requirements"
printf 'stale\n' > "$T/bundle/wheels/3.12.14/mcp/.inputs"
if mcp_bundle_preflight 3.12.14 reviewed; then echo 'stale bundle accepted' >&2; exit 1; fi
printf 'reviewed\n' > "$T/bundle/wheels/3.12.14/mcp/.inputs"
mcp_bundle_preflight 3.12.14 reviewed
MODE=native
mcp_bundle_preflight 3.13.11 reviewed
MODE=docker

# Unchanged apply must never retire the current backend.
mcp_active() { printf '%s\n' "$T/old"; }
sd_retire_after() { printf 'retire %s\n' "$1" >> "$calls"; }
mcp_reap_unselected() { :; }
tg_notify() { :; }
MCP_DOMAIN=mcp.example.test; MCP_OLD="$T/old"; MCP_CANDIDATE=""; MCP_SNAPSHOT="$T/snapshot"
mcp_finish "$MCP_DOMAIN"
[[ ! -s "$calls" ]]
MCP_CANDIDATE="$T/new"
mcp_finish "$MCP_DOMAIN"
[[ "$(grep -c '^retire ' "$calls")" == 1 ]]

# Configuration must recover even when failure preceded generation creation.
ep_conf() { printf '%s/config\n' "$T"; }
gb_restore_file() { cp "$2/config" "$1"; }
mkdir "$T/backup"
printf 'MCP_PYTHON_VERSION=3.12.1\n' > "$T/backup/config"
printf 'MCP_PYTHON_VERSION=3.12.14\n' > "$T/config"
MCP_CONFIG_BACKUP="$T/backup"; MCP_COMMITTED=false; MCP_CANDIDATE=""
mcp_abort "$MCP_DOMAIN"
cmp "$T/config" "$T/backup/config"

# Preflight occurs before configuration mutation. Rejected origins restore
# saved settings; post-commit edge failures retain the deployed settings.
ep_exists() { return 0; }
ep_get() {
    case "$2" in TYPE) printf 'mcp\n' ;; MCP_PYTHON_VERSION) cut -d= -f2 "$T/config" ;; *) printf '%s\n' "${3:-}" ;; esac
}
ep_set() { printf '%s=%s\n' "$2" "$3" > "$T/config"; }
gb_new_backup_set() { printf '%s/backup\n' "$T"; }
gb_backup_file() { cp "$1" "$2/config"; }
MODE=native
EDGE=false
endpoint_apply() { EP_APPLY_EDGE_FAILED="$EDGE"; return 1; }
printf 'MCP_PYTHON_VERSION=3.12.1\n' > "$T/config"
if mcp_cli update "$MCP_DOMAIN"; then echo 'failed deployment accepted' >&2; exit 1; fi
grep -qx 'MCP_PYTHON_VERSION=3.12.1' "$T/config"
EDGE=true
if mcp_cli update "$MCP_DOMAIN"; then echo 'edge failure accepted' >&2; exit 1; fi
grep -qx 'MCP_PYTHON_VERSION=3.12.14' "$T/config"
printf 'MCP_PYTHON_VERSION=3.13.1\n' > "$T/config"
MODE=docker
if mcp_cli update "$MCP_DOMAIN"; then echo 'missing bundle accepted' >&2; exit 1; fi
grep -qx 'MCP_PYTHON_VERSION=3.13.1' "$T/config"
printf 'MCP upgrade transaction checks passed\n'
