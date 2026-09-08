#!/usr/bin/env bash
# nginx management: host detection, rendering, staged install with backups,
# configuration test, rollback and reload. nginx is only ever reloaded.

[[ -n "${GB_NGINX_LOADED:-}" ]] && return 0
GB_NGINX_LOADED=1

NG_VERSION=""
NG_HTTP2_NATIVE=false
NG_AIO_THREADS=false
NG_IPV6=false
NG_BROTLI=false
NG_AVAILABLE=false
NG_TRANSACTION_ACTIVE=false
NG_TRANSACTION_FILES=()
NG_TRANSACTION_SETS=()

# Keep each applied stage until the endpoint passes its service health check.
# Replaying backups in reverse restores both HTTP and TLS stages correctly.
nginx_transaction_begin() {
    NG_TRANSACTION_FILES=()
    NG_TRANSACTION_SETS=()
    NG_TRANSACTION_ACTIVE=true
}

nginx_transaction_commit() {
    NG_TRANSACTION_ACTIVE=false
    NG_TRANSACTION_FILES=()
    NG_TRANSACTION_SETS=()
}

nginx_transaction_rollback() {
    local index target failed=0
    NG_TRANSACTION_ACTIVE=false
    for ((index=${#NG_TRANSACTION_FILES[@]} - 1; index>=0; index--)); do
        target="${NG_TRANSACTION_FILES[index]}"
        gb_restore_file "$target" "${NG_TRANSACTION_SETS[index]}" || failed=1
        if [[ -e "$target" ]]; then gb_ledger_record "$target"; else gb_ledger_forget "$target"; fi
    done
    nginx_harden_token_files || failed=1
    if ! nginx_test || ! nginx_reload; then failed=1; fi
    nginx_transaction_commit
    return "$failed"
}

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
    # Before 1.25.4 a worker shutting down gracefully (every reload) could
    # close connections that still had a threaded read in flight, so clients
    # saw resets whenever a cached response was being served. Keep aio off
    # on older builds; the API's files are small enough that it costs nothing.
    if [[ "$(printf '%s\n1.25.4\n' "$NG_VERSION" | sort -V | head -1)" == "1.25.4" ]]; then
        NG_AIO_THREADS=true
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

# The directory whose fullchain.pem and privkey.pem the TLS vhost uses: the
# Let's Encrypt certificate when there is one, otherwise the self-signed
# placeholder of a staged endpoint, otherwise nothing (HTTP only).
nginx_tls_cert_dir() {
    local domain="$1"
    if nginx_cert_exists "$domain"; then
        nginx_cert_dir "$domain"
    elif declare -F certs_placeholder_exists >/dev/null && certs_placeholder_exists "$domain"; then
        certs_placeholder_dir "$domain"
    fi
    return 0
}
nginx_site_file() { printf '%s/sites-available/%s.conf\n' "$GB_NGINX" "$1"; }
nginx_enabled_file() { printf '%s/sites-enabled/%s.conf\n' "$GB_NGINX" "$1"; }
nginx_ep_http_file() { printf '%s/conf.d/getbible-ep-%s.conf\n' "$GB_NGINX" "$(gb_slug "$1")"; }
nginx_ep_dir() { printf '%s/%s\n' "$GB_NGINX_GB" "$1"; }
nginx_tokens_map() { printf '%s/tokens/%s.map\n' "$GB_NGINX_GB" "$(gb_slug "$1")"; }
nginx_token_validity_map() { printf '%s/token-validity/%s.map\n' "$GB_NGINX_GB" "$(gb_slug "$1")"; }

# Render the global files into STAGE (a directory mirroring /etc/nginx).
nginx_render_global() {
    local stage="$1"
    nginx_detect || return 1
    local hsts
    hsts="$(gb_global HSTS_INCLUDE_SUBDOMAINS false)"
    install -d -m 0755 "$stage/conf.d" "$stage/snippets/getbible" "$stage/getbible/tokens" || return 1
    install -d -m 0700 "$stage/getbible/tokens" "$stage/getbible/token-validity" || return 1
    gb_render "$GB_NGINX_SRC/http.conf.tmpl" "$stage/conf.d/getbible-http.conf" "NGINX_GB_DIR=$GB_NGINX_GB" || return 1
    gb_render "$GB_NGINX_SRC/snippets/headers.conf.tmpl" "$stage/snippets/getbible/headers.conf" "HSTS_INCLUDE_SUBDOMAINS=$hsts" || return 1
    gb_render "$GB_NGINX_SRC/snippets/headers-html.conf.tmpl" "$stage/snippets/getbible/headers-html.conf" "HSTS_INCLUDE_SUBDOMAINS=$hsts" || return 1
    sed 's/"public, max-age=300"/"private, no-store"/' "$stage/snippets/getbible/headers-html.conf" > "$stage/snippets/getbible/headers-html-private.conf" || return 1
    gb_render "$GB_NGINX_SRC/snippets/acme.conf.tmpl" "$stage/snippets/getbible/acme.conf" "ACME_ROOT=$GB_ACME_ROOT" || return 1
    cp "$GB_NGINX_SRC/snippets/tls.conf" "$stage/snippets/getbible/tls.conf" || return 1
    cp "$GB_NGINX_SRC/snippets/errors.conf" "$stage/snippets/getbible/errors.conf" || return 1
    cp "$GB_NGINX_SRC/snippets/proxy.conf" "$stage/snippets/getbible/proxy.conf" || return 1
    printf '# placeholder so the tokens include always matches a file\n' > "$stage/getbible/tokens/_placeholder.map"
    printf '# placeholder so validity includes always match a file\n' > "$stage/getbible/token-validity/_placeholder.map"
    # The shared identity map and its validity data must migrate together for
    # all registered hosts, including when updating only one endpoint.
    local domain slug
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        slug="$(gb_slug "$domain")"
        tokens_render_map "$domain" "$stage/getbible/tokens/$slug.map" || return 1
        tokens_render_validity_map "$domain" "$stage/getbible/token-validity/$slug.map" || return 1
        chmod 0600 "$stage/getbible/tokens/$slug.map" "$stage/getbible/token-validity/$slug.map"
    done < <(ep_list)
}

# Render every file of one endpoint into STAGE. Requires ep_load first and the
# endpoint type module sourced (type_<TYPE>_render_locations).
nginx_render_endpoint() {
    local stage="$1"
    nginx_detect
    local slug="$EP_SLUG" domain="$EP_DOMAIN" tls=false cert_dir
    cert_dir="$(nginx_tls_cert_dir "$domain")"
    [[ -n "$cert_dir" ]] && tls=true
    [[ "${GB_FORCE_TLS:-}" == true ]] && { tls=true; cert_dir="${cert_dir:-$(nginx_cert_dir "$domain")}"; }
    install -d -m 0755 "$stage/sites-available" "$stage/conf.d" "$stage/getbible/$domain"
    install -d -m 0700 "$stage/getbible/tokens" "$stage/getbible/token-validity"

    # Type specific pieces
    local locations methods_regex="GET|HEAD|OPTIONS" reject_args=false max_body=1k proxy_cache=false
    locations="$(gb_tmpdir)/locations.$slug"
    "type_${EP_TYPE}_render_locations" "$locations" || return 1
    [[ -n "${TYPE_METHODS_REGEX:-}" ]] && methods_regex="$TYPE_METHODS_REGEX"
    [[ -n "${TYPE_REJECT_ARGS:-}" ]] && reject_args="$TYPE_REJECT_ARGS"
    [[ -n "${TYPE_MAX_BODY:-}" ]] && max_body="$TYPE_MAX_BODY"
    [[ -n "${TYPE_PROXY_CACHE:-}" ]] && proxy_cache="$TYPE_PROXY_CACHE"

    local real_ip=false origin_pulls=false
    # Cloudflare's origin-side directives follow the endpoint's mode and the
    # files they include, never the publication state: a vhost that serves
    # the name keeps them through "Stage again", while a freshly built server
    # has no ranges file yet (go-live fetches it) and stays verifiable directly.
    if [[ "$EP_CLOUDFLARE_MODE" == proxied ]]; then
        [[ -f "$GB_NGINX_GB/cloudflare-real-ip.conf" ]] && real_ip=true
        [[ "$EP_CLOUDFLARE_ORIGIN_PULLS" == true && -f "$GB_NGINX_GB/cloudflare-origin-pull-ca.pem" ]] && origin_pulls=true
    fi

    local http2_native=false http2_legacy=false
    if [[ "$NG_HTTP2_NATIVE" == true ]]; then http2_native=true; else http2_legacy=true; fi

    # The pages a domain publishes besides its data (pages.sh): where each
    # lives decides which directory nginx serves it from.
    local domain_page=false domain_page_root="" domain_page_file="" favicon=false favicon_mime=""
    local versions_json=false domain_openapi=false domain_openapi_root="" domain_openapi_file=""
    local -a page
    if declare -F pages_domain_docs_location >/dev/null; then
        mapfile -t page < <(pages_domain_docs_location "$domain")
        [[ ${#page[@]} -ne 2 ]] || { domain_page=true; domain_page_root="${page[0]}"; domain_page_file="${page[1]}"; }
        mapfile -t page < <(pages_domain_openapi_location "$domain")
        [[ ${#page[@]} -ne 2 ]] || { domain_openapi=true; domain_openapi_root="${page[0]}"; domain_openapi_file="${page[1]}"; }
        if pages_favicon_active "$domain"; then favicon=true; favicon_mime="$(pages_favicon_mime "$domain")"; fi
        if pages_versions_active "$domain"; then versions_json=true; fi
    fi

    gb_render "$GB_NGINX_SRC/site.conf.tmpl" "$stage/sites-available/$domain.conf" \
        "DOMAIN=$domain" "SLUG=$slug" "TYPE=$EP_TYPE" "KIND=$EP_KIND" "TLS=$tls" \
        "IPV6=$NG_IPV6" "HTTP2_NATIVE=$http2_native" "HTTP2_LEGACY=$http2_legacy" \
        "CERT_DIR=$cert_dir" "NGINX_GB_DIR=$GB_NGINX_GB" \
        "ORIGIN_PULLS=$origin_pulls" "REAL_IP=$real_ip" "LOG_DIR=$(ep_log_dir "$domain")" \
        "WWW_DIR=$(ep_www_dir "$domain")" "METHODS_REGEX=$methods_regex" "REJECT_ARGS=$reject_args" \
        "DOMAIN_PAGE=$domain_page" "DOMAIN_PAGE_ROOT=$domain_page_root" "DOMAIN_PAGE_FILE=$domain_page_file" \
        "FAVICON=$favicon" "FAVICON_MIME=$favicon_mime" "VERSIONS_JSON=$versions_json" \
        "DOMAIN_OPENAPI=$domain_openapi" "DOMAIN_OPENAPI_ROOT=$domain_openapi_root" "DOMAIN_OPENAPI_FILE=$domain_openapi_file" \
        "LOCATIONS=$(cat "$locations")" || return 1

    gb_render "$GB_NGINX_SRC/endpoint-http.conf.tmpl" "$stage/conf.d/getbible-ep-$slug.conf" \
        "DOMAIN=$domain" "SLUG=$slug" "RATE_PER_SECOND=$EP_RATE_PER_SECOND" \
        "HOUR_RATE=$(access_hour_rate)" "DAY_RATE=$(access_day_rate)" \
        "PROXY_CACHE=$proxy_cache" "CACHE_DIR=$GB_PREFIX/var/cache/nginx/getbible/$slug" || return 1

    gb_render "$GB_NGINX_SRC/snippets/server.conf.tmpl" "$stage/getbible/$domain/server.conf" \
        "MAX_BODY=$max_body" "BROTLI=$NG_BROTLI" "AIO_THREADS=$NG_AIO_THREADS" || return 1
    access_render_limits "$stage/getbible/$domain/limits.conf" || return 1
    access_render_auth "$stage/getbible/$domain/auth.conf" || return 1
    tokens_render_map "$domain" "$stage/getbible/tokens/$slug.map" || return 1
    tokens_render_validity_map "$domain" "$stage/getbible/token-validity/$slug.map" || return 1
    chmod 0600 "$stage/getbible/tokens/$slug.map" "$stage/getbible/token-validity/$slug.map" || return 1
    printf '%s\n' "$tls" > "$stage/.tls-$slug"
}

# --- staged installation -----------------------------------------------------
# nginx_apply_stage STAGE NAME: install every staged file with backup, then
# test nginx and reload; restore everything if validation or reload fails.
nginx_harden_token_files() {
    [[ "$GB_DRY_RUN" == true ]] && return 0
    local directory file backup_set="${1:-}"
    for directory in "$GB_NGINX_GB/tokens" "$GB_NGINX_GB/token-validity"; do
        [[ -d "$directory" ]] || continue
        chmod 0700 "$directory" || return 1
        if gb_is_root && [[ -z "$GB_PREFIX" ]]; then chown root:root "$directory" || return 1; fi
        while IFS= read -r -d '' file; do
            if [[ -n "$backup_set" && "$(stat -c '%a' "$file")" != 600 ]]; then
                gb_backup_file "$file" "$backup_set" || return 1
            fi
            chmod 0600 "$file" || return 1
            if gb_is_root && [[ -z "$GB_PREFIX" ]]; then chown root:root "$file" || return 1; fi
        done < <(find "$directory" -maxdepth 1 -type f -print0)
    done
}

nginx_apply_stage() {
    local stage="$1" name="$2"
    local backup_set changed=0 file rel target status mode failed=false
    backup_set="$(gb_new_backup_set "nginx-$name")"
    local -a installed=()
    # Repair old 0644 maps even when their contents are already up to date.
    nginx_harden_token_files "$backup_set" || return 1

    while IFS= read -r file; do
        rel="${file#"$stage"/}"
        [[ "$rel" == .tls-* ]] && continue
        target="$GB_NGINX/$rel"
        mode=0644
        [[ "$rel" == getbible/tokens/* || "$rel" == getbible/token-validity/* ]] && mode=0600
        status="$(gb_drift_status "$target" "$file")"
        case "$status" in
            unchanged) continue ;;
            hand-edited)
                if ! nginx_confirm_overwrite "$target" "$file"; then
                    gb_warn "Keeping hand-edited $target"
                    # A skipped upstream/socket file cannot be treated as a
                    # successful switch: retiring the old backend would break
                    # the route that nginx is still serving.
                    failed=true
                    break
                fi
                ;;
        esac
        gb_backup_file "$target" "$backup_set" || { failed=true; break; }
        installed+=("$target")
        gb_install_file "$file" "$target" "$mode" || { failed=true; break; }
        gb_ledger_record "$target" || { failed=true; break; }
        changed=$((changed + 1))
        gb_log "Installed $target ($status)"
    done < <(find "$stage" -type f | sort)

    nginx_harden_token_files || failed=true
    if [[ "$failed" == false ]] && (( changed == 0 )); then
        gb_log "nginx configuration already current."
        rmdir "$backup_set" 2>/dev/null || true
        return 0
    fi
    if [[ "$failed" == true ]] || ! nginx_test || ! nginx_reload; then
        gb_warn "nginx installation, validation or reload failed; restoring the previous files."
        for target in "${installed[@]}"; do
            gb_restore_file "$target" "$backup_set"
            if [[ -e "$target" ]]; then gb_ledger_record "$target"; else gb_ledger_forget "$target"; fi
        done
        nginx_harden_token_files || true
        if ! nginx_test || ! nginx_reload; then
            gb_warn "nginx recovery failed; inspect the service before retrying the deployment."
        fi
        return 1
    fi
    if [[ "$NG_TRANSACTION_ACTIVE" == true ]]; then
        for target in "${installed[@]}"; do
            NG_TRANSACTION_FILES+=("$target")
            NG_TRANSACTION_SETS+=("$backup_set")
        done
    fi
    gb_prune_backups "nginx-$name" 10
    return 0
}

nginx_confirm_overwrite() {
    local target="$1" candidate="$2" diff_file
    # The menu asks about hand edits before it captures output
    # (endpoint_confirm_hand_edits) and records the answer here.
    [[ "${GB_OVERWRITE_HAND_EDITS:-false}" == true ]] && return 0
    if [[ "$GB_YES" == true || "${GB_UI_CAPTURED:-false}" == true ]]; then
        gb_warn "$target was edited by hand; refusing to overwrite it without a dialog (choose the action from the endpoint menu, or run interactively, to decide)."
        return 1
    fi
    if [[ "$target" == "$GB_NGINX_GB/tokens/"* ]]; then
        ui_yesno "Hand-edited token map" "Overwrite $target with the generated token map? Secret values are hidden." no
        return $?
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
        "$GB_SYSTEMCTL" reload nginx || return 1
    else
        "$GB_NGINX_BIN" -s reload 2>/dev/null || "$GB_SYSTEMCTL" start nginx || return 1
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
    local -a removed=()
    for target in "$(nginx_enabled_file "$domain")" "$(nginx_site_file "$domain")" "$(nginx_ep_http_file "$domain")" "$(nginx_tokens_map "$domain")" "$(nginx_token_validity_map "$domain")"; do
        [[ -e "$target" || -L "$target" ]] || continue
        gb_backup_file "$target" "$backup_set"
        removed+=("$target")
        rm -f -- "$target"
        gb_ledger_forget "$target"
    done
    if [[ -d "$(nginx_ep_dir "$domain")" ]]; then
        cp -a -- "$(nginx_ep_dir "$domain")" "$backup_set/endpoint-dir"
        rm -rf -- "$(nginx_ep_dir "$domain")"
    fi
    if ! nginx_test || ! nginx_reload; then
        for target in "${removed[@]}"; do
            gb_restore_file "$target" "$backup_set"
            [[ -L "$target" ]] || gb_ledger_record "$target"
        done
        if [[ -d "$backup_set/endpoint-dir" ]]; then
            cp -a -- "$backup_set/endpoint-dir" "$(nginx_ep_dir "$domain")"
        fi
        nginx_harden_token_files || true
        nginx_test && nginx_reload || gb_warn "nginx recovery failed after endpoint removal."
        return 1
    fi
}
