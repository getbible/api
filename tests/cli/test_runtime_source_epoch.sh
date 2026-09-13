#!/usr/bin/env bash
# Publication refresh changes only the cache-key namespace; rejected nginx
# configuration preserves the old namespace and every runtime generation.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GB_PREFIX="$(mktemp -d)"
export GB_PREFIX GB_REPO_DIR="$ROOT"
for lib in core config registry resources nginx; do
    # shellcheck source=/dev/null
    source "$ROOT/src/lib/$lib.sh"
done
# shellcheck source=../../src/types/runtime/type.sh
source "$ROOT/src/types/runtime/type.sh"
trap 'rm -rf -- "$GB_PREFIX"; gb_cleanup' EXIT
domain=query.example.test
repository="$GB_PREFIX/scripture"
mkdir -p "$repository/release-first" "$repository/release-second" "$GB_NGINX/sites-available"
ln -s release-first "$repository/v2"
ep_create "$domain" runtime query
mkdir -p "$(ep_versions_dir "$domain")"
cfg_set "$(ep_version_conf "$domain" v2)" REPOSITORY "$repository"
cfg_set "$(ep_version_conf "$domain" v2)" APP_VERSION v2
first="$(rt_source_epoch "$domain" v2)"
site="$(nginx_site_file "$domain")"
# shellcheck disable=SC2016 # These are literal nginx variables.
printf 'server {\n    # operator marker\n    proxy_cache_key "%s:telemetry2:$scheme$request_method$host$request_uri"; # getbible-source=v2\n}\n' "$first" > "$site"
gb_ledger_record "$site"
ln -s release-second "$repository/next"
mv -Tf "$repository/next" "$repository/v2"
second="$(rt_source_epoch "$domain" v2)"
[[ "$first" != "$second" ]]
nginx_harden_token_files() { :; }
# shellcheck disable=SC2317,SC2329 # First indirect nginx callback; replaced below to exercise rollback.
nginx_test() { :; }
nginx_reload() { :; }
rt_refresh_cache_epoch "$domain" v2 "$second"
grep -Fq "proxy_cache_key \"$second:" "$site"
grep -Fq '# operator marker' "$site"
if rt_refresh_cache_epoch "$domain" v2 "$first" 2>/dev/null; then
    echo 'A source that changed during refresh must not be acknowledged' >&2
    exit 1
fi
[[ ! -d "$GB_OPT/query/v2/deployments" ]]
# Fail nginx validation for a rollback publication: the prior cache key remains.
ln -s release-first "$repository/next"
mv -Tf "$repository/next" "$repository/v2"
nginx_test() { return 1; }
if rt_refresh_cache_epoch "$domain" v2 "$first" 2>/dev/null; then
    echo 'Rejected nginx configuration must report failure' >&2
    exit 1
fi
grep -Fq "proxy_cache_key \"$second:" "$site"
printf 'Runtime publication cache epochs, acknowledgment and rollback: ok\n'
