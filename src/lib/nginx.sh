#!/usr/bin/env bash
# nginx management: host detection, rendering, staged install with backups,
# configuration test, rollback and reload. nginx is only ever reloaded.

[[ -n "${GB_NGINX_LOADED:-}" ]] && return 0
GB_NGINX_LOADED=1

NG_VERSION=""
NG_HTTP2_NATIVE=false
NG_IPV6=false
NG_BROTLI=false
NG_AVAILABLE=false

nginx_detect() {
    [[ -n "$NG_VERSION" ]] && return 0
    if gb_have "$GB_NGINX_BIN"; then
        NG_AVAILABLE=true
        NG_VERSION="$("$GB_NGINX_BIN" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if "$GB_NGINX_BIN" -V 2>&1 | grep -q brotli || ls /usr/lib/nginx/modules/ngx_http_brotli_static_module.so >/dev/null 2>&1; then
            NG_BROTLI=true
        fi
    fi
    NG_VERSION="${GB_NGINX_FAKE_VERSION:-${NG_VERSION:-1.24.0}}"
    if [[ "$(printf '%s\n1.25.1\n' "$NG_VERSION" | sort -V | head -1)" == "1.25.1" ]]; then
        NG_HTTP2_NATIVE=true
    fi
    if [[ -n "${GB_NGINX_FAKE_IPV6:-}" ]]; then
        NG_IPV6="$GB_NGINX_FAKE_IPV6"
    elif [[ -f /proc/net/if_inet6 ]] && grep -qv '^00000000000000000000000000000001' /proc/net/if_inet6 2>/dev/null; then
        NG_IPV6=true
    fi
    [[ -n "${GB_NGINX_FAKE_BROTLI:-}" ]] && NG_BROTLI="$GB_NGINX_FAKE_BROTLI"
    return 0
}

nginx_cert_dir() { printf '%s/live/%s\n' "$GB_LETSENCRYPT" "$1"; }
nginx_cert_exists() { [[ -f "$(nginx_cert_dir "$1")/fullchain.pem" && -f "$(nginx_cert_dir "$1")/privkey.pem" ]]; }
nginx_site_file() { printf '%s/sites-available/%s.conf\n' "$GB_NGINX" "$1"; }
nginx_enabled_file() { printf '%s/sites-enabled/%s.conf\n' "$GB_NGINX" "$1"; }
nginx_ep_http_file() { printf '%s/conf.d/getbible-ep-%s.conf\n' "$GB_NGINX" "$(gb_slug "$1")"; }
nginx_ep_dir() { printf '%s/%s\n' "$GB_NGINX_GB" "$1"; }
nginx_tokens_map() { printf '%s/tokens/%s.map\n' "$GB_NGINX_GB" "$(gb_slug "$1")"; }

# Render the global files into STAGE (a directory mirroring /etc/nginx).
nginx_render_global() {
    local stage="$1"
    nginx_detect
    local hsts
    hsts="$(gb_global HSTS_INCLUDE_SUBDOMAINS false)"
    install -d -m 0755 "$stage/conf.d" "$stage/snippets/getbible" "$stage/getbible/tokens"
    gb_render "$GB_NGINX_SRC/http.conf.tmpl" "$stage/conf.d/getbible-http.conf" "NGINX_GB_DIR=$GB_NGINX_GB"
    gb_render "$GB_NGINX_SRC/snippets/headers.conf.tmpl" "$stage/snippets/getbible/headers.conf" "HSTS_INCLUDE_SUBDOMAINS=$hsts"
    gb_render "$GB_NGINX_SRC/snippets/headers-html.conf.tmpl" "$stage/snippets/getbible/headers-html.conf" "HSTS_INCLUDE_SUBDOMAINS=$hsts"
    gb_render "$GB_NGINX_SRC/snippets/acme.conf.tmpl" "$stage/snippets/getbible/acme.conf" "ACME_ROOT=$GB_ACME_ROOT"
    cp "$GB_NGINX_SRC/snippets/tls.conf" "$stage/snippets/getbible/tls.conf"
    cp "$GB_NGINX_SRC/snippets/errors.conf" "$stage/snippets/getbible/errors.conf"
    cp "$GB_NGINX_SRC/snippets/proxy.conf" "$stage/snippets/getbible/proxy.conf"
    printf '# placeholder so the tokens include always matches a file\n' > "$stage/getbible/tokens/_placeholder.map"
}

# Render every file of one endpoint into STAGE. Requires ep_load first and the
# endpoint type module sourced (type_<TYPE>_render_locations).
nginx_render_endpoint() {
    local stage="$1"
    nginx_detect
    local slug="$EP_SLUG" domain="$EP_DOMAIN" tls=false
    nginx_cert_exists "$domain" && tls=true
    [[ "${GB_FORCE_TLS:-}" == true ]] && tls=true
    install -d -m 0755 "$stage/sites-available" "$stage/conf.d" "$stage/getbible/$domain" "$stage/getbible/tokens"

    # Type specific pieces
    local locations methods_regex="GET|HEAD|OPTIONS" reject_args=false max_body=1k proxy_cache=false
    locations="$(gb_tmpdir)/locations.$slug"
    "type_${EP_TYPE}_render_locations" "$locations"
    [[ -n "${TYPE_METHODS_REGEX:-}" ]] && methods_regex="$TYPE_METHODS_REGEX"
    [[ -n "${TYPE_REJECT_ARGS:-}" ]] && reject_args="$TYPE_REJECT_ARGS"
    [[ -n "${TYPE_MAX_BODY:-}" ]] && max_body="$TYPE_MAX_BODY"
    [[ -n "${TYPE_PROXY_CACHE:-}" ]] && proxy_cache="$TYPE_PROXY_CACHE"

    local real_ip=false origin_pulls=false
    if [[ "$EP_CLOUDFLARE_MODE" == proxied ]]; then
        real_ip=true
        [[ "$EP_CLOUDFLARE_ORIGIN_PULLS" == true ]] && origin_pulls=true
    fi

    local http2_native=false http2_legacy=false
    if [[ "$NG_HTTP2_NATIVE" == true ]]; then http2_native=true; else http2_legacy=true; fi

    gb_render "$GB_NGINX_SRC/site.conf.tmpl" "$stage/sites-available/$domain.conf" \
        "DOMAIN=$domain" "SLUG=$slug" "TYPE=$EP_TYPE" "KIND=$EP_KIND" "TLS=$tls" \
        "IPV6=$NG_IPV6" "HTTP2_NATIVE=$http2_native" "HTTP2_LEGACY=$http2_legacy" \
        "CERT_DIR=$(nginx_cert_dir "$domain")" "NGINX_GB_DIR=$GB_NGINX_GB" \
        "ORIGIN_PULLS=$origin_pulls" "REAL_IP=$real_ip" "LOG_DIR=$(ep_log_dir "$domain")" \
        "WWW_DIR=$(ep_www_dir "$domain")" "METHODS_REGEX=$methods_regex" "REJECT_ARGS=$reject_args" \
        "LOCATIONS=$(cat "$locations")"

    gb_render "$GB_NGINX_SRC/endpoint-http.conf.tmpl" "$stage/conf.d/getbible-ep-$slug.conf" \
        "DOMAIN=$domain" "SLUG=$slug" "RATE_PER_SECOND=$EP_RATE_PER_SECOND" \
        "HOUR_RATE=$(access_hour_rate)" "DAY_RATE=$(access_day_rate)" \
        "PROXY_CACHE=$proxy_cache" "CACHE_DIR=$GB_PREFIX/var/cache/nginx/getbible/$slug"

    gb_render "$GB_NGINX_SRC/snippets/server.conf.tmpl" "$stage/getbible/$domain/server.conf" \
        "MAX_BODY=$max_body" "BROTLI=$NG_BROTLI"
    access_render_limits "$stage/getbible/$domain/limits.conf"
    access_render_auth "$stage/getbible/$domain/auth.conf"
    tokens_render_map "$domain" "$stage/getbible/tokens/$slug.map"
    printf '%s\n' "$tls" > "$stage/.tls-$slug"
}

# --- staged installation -----------------------------------------------------
# nginx_apply_stage STAGE NAME: install every staged file with backup, then
# test nginx and reload; restore everything if the test fails.
nginx_apply_stage() {
    local stage="$1" name="$2"
    local backup_set changed=0 file rel target status
    backup_set="$(gb_new_backup_set "nginx-$name")"
    local -a installed=()

    while IFS= read -r file; do
        rel="${file#"$stage"/}"
        [[ "$rel" == .tls-* ]] && continue
        target="$GB_NGINX/$rel"
        status="$(gb_drift_status "$target" "$file")"
        case "$status" in
            unchanged) continue ;;
            hand-edited)
                if ! nginx_confirm_overwrite "$target" "$file"; then
                    gb_warn "Keeping hand-edited $target"
                    continue
                fi
                ;;
        esac
        gb_backup_file "$target" "$backup_set"
        gb_install_file "$file" "$target" 0644
        gb_ledger_record "$target"
        installed+=("$target")
        changed=$((changed + 1))
        gb_log "Installed $target ($status)"
    done < <(find "$stage" -type f | sort)

    if (( changed == 0 )); then
        gb_log "nginx configuration already current."
        rmdir "$backup_set" 2>/dev/null || true
        return 0
    fi
    if ! nginx_test; then
        gb_warn "nginx rejected the configuration; restoring the previous files."
        for target in "${installed[@]}"; do
            gb_restore_file "$target" "$backup_set"
            if [[ -e "$target" ]]; then gb_ledger_record "$target"; else gb_ledger_forget "$target"; fi
        done
        nginx_test || true
        return 1
    fi
    nginx_reload
    gb_prune_backups "nginx-$name" 10
    return 0
}

nginx_confirm_overwrite() {
    local target="$1" candidate="$2" diff_file
    if [[ "$GB_YES" == true ]]; then
        gb_warn "$target was edited by hand; refusing to overwrite it non-interactively (run interactively to decide)."
        return 1
    fi
    diff_file="$(gb_tmpdir)/diff.$$"
    { printf 'The installed file differs from what getbible.sh last wrote.\n\n--- installed\n+++ new\n'; diff -u "$target" "$candidate" || true; } > "$diff_file"
    ui_textbox "Hand-edited: $target" "$diff_file"
    ui_yesno "Hand-edited file" "Overwrite $target with the freshly rendered version?" no
}

nginx_test() {
    nginx_detect
    if [[ "$NG_AVAILABLE" != true ]]; then
        gb_warn "nginx is not installed; configuration test skipped."
        return 0
    fi
    [[ -n "$GB_PREFIX" ]] && { gb_log "(prefix) nginx -t skipped"; return 0; }
    "$GB_NGINX_BIN" -t
}

nginx_reload() {
    nginx_detect
    [[ "$NG_AVAILABLE" == true && -z "$GB_PREFIX" ]] || return 0
    [[ "$GB_DRY_RUN" == true ]] && return 0
    if "$GB_SYSTEMCTL" is-active --quiet nginx 2>/dev/null; then
        "$GB_SYSTEMCTL" reload nginx
    else
        "$GB_NGINX_BIN" -s reload 2>/dev/null || "$GB_SYSTEMCTL" start nginx
    fi
    gb_log "nginx reloaded."
}

nginx_enable_site() {
    local domain="$1"
    gb_ensure_dir "$GB_NGINX/sites-enabled" 0755
    [[ "$GB_DRY_RUN" == true ]] && return 0
    ln -sfn "$(nginx_site_file "$domain")" "$(nginx_enabled_file "$domain")"
}

# Other files declaring the same server_name would shadow ours.
nginx_conflicts() {
    local domain="$1"
    nginx_detect
    [[ "$NG_AVAILABLE" == true && -z "$GB_PREFIX" ]] || return 0
    "$GB_NGINX_BIN" -T 2>/dev/null | awk -v d="$domain" '
        /^# configuration file / { file=$4 }
        /^[[:space:]]*server_name[[:space:]]/ {
            for (i = 2; i <= NF; i++) { gsub(";", "", $i); if ($i == d) print file }
        }' | sort -u | grep -v "/sites-enabled/$domain.conf\|/sites-available/$domain.conf" || true
}

nginx_remove_endpoint() {
    local domain="$1" slug backup_set
    slug="$(gb_slug "$domain")"
    backup_set="$(gb_new_backup_set "nginx-remove-$slug")"
    local target
    for target in "$(nginx_enabled_file "$domain")" "$(nginx_site_file "$domain")" "$(nginx_ep_http_file "$domain")" "$(nginx_tokens_map "$domain")"; do
        [[ -e "$target" || -L "$target" ]] || continue
        gb_backup_file "$target" "$backup_set"
        rm -f -- "$target"
        gb_ledger_forget "$target"
    done
    if [[ -d "$(nginx_ep_dir "$domain")" ]]; then
        cp -a -- "$(nginx_ep_dir "$domain")" "$backup_set/endpoint-dir"
        rm -rf -- "$(nginx_ep_dir "$domain")"
    fi
    nginx_test && nginx_reload
}
