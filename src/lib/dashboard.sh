#!/usr/bin/env bash
# Shared infrastructure and the private dashboard's CLI/menu integration.
[[ -n "${GB_DASHBOARD_LOADED:-}" ]] && return 0
GB_DASHBOARD_LOADED=1
# shellcheck source=management-release.sh
source "$GB_LIB/management-release.sh"

dashboard_config() { printf '%s/dashboard.conf\n' "$GB_RUN"; }
dashboard_domain() { gb_global DASHBOARD_DOMAIN; }

# Identify the reviewed source independently of a running Python process. The
# service captures this marker at startup, so a configuration reload cannot
# claim that newly copied application code is already running.

dashboard_health() {
    curl --silent --show-error --fail --max-time 3 \
        --unix-socket "$GB_PREFIX/run/getbible-dashboard/http.sock" \
        --header "Host: $(dashboard_domain)" --header 'X-GetBible-Client-IP: 127.0.0.1' \
        http://localhost/health
}

dashboard_wait_current() {
    [[ "$GB_DRY_RUN" != true && -z "$GB_PREFIX" ]] || return 0
    local response deadline=$((SECONDS + 20))
    response="$(gb_tmpdir)/dashboard-health.json"
    while (( SECONDS < deadline )); do
        if dashboard_health > "$response" 2>/dev/null && "$GB_PYTHON" - "$(management_release_file)" "$response" <<'PY'
import json
from pathlib import Path
import sys
try:
    installed, response = (json.loads(Path(path).read_text()) for path in sys.argv[1:])
    raise SystemExit(0 if installed == response.get("release") else 1)
except (OSError, ValueError):
    raise SystemExit(1)
PY
        then return 0; fi
        sleep 1
    done
    gb_warn 'The dashboard did not confirm the installed release. Check getbible dashboard status and journalctl -u getbible-dashboard.service.'
    return 1
}

dashboard_status() {
    local status source serving
    status="$(gb_tmpdir)/dashboard-status.json"
    source="$(gb_tmpdir)/dashboard-source.json"
    serving="$(gb_tmpdir)/dashboard-serving.json"
    dashboard_auth_cli status > "$status" || return 1
    dashboard_release_manifest > "$source" || return 1
    dashboard_health > "$serving" 2>/dev/null || : > "$serving"
    "$GB_PYTHON" - "$status" "$source" "$(management_release_file)" "$serving" \
        "$(sd_status_line getbible-dashboard.service)" "$(sd_status_line getbible-telemetry.service)" <<'PY'
import json
from pathlib import Path
import sys
def read(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
status, source, installed, health = (read(path) for path in sys.argv[1:5])
serving = health.get("release") or {}
status.update(manager_release=source, installed_release=installed or None,
              serving_release=serving or None,
              running_latest=bool(serving and source.get("fingerprint") == installed.get("fingerprint") == serving.get("fingerprint")),
              dashboard_service=sys.argv[5], telemetry_service=sys.argv[6])
print(json.dumps(status, indent=2))
PY
}

dashboard_save_setting() {
    if gb_environment_managed "$GB_GLOBAL_CONF" "$1"; then
        [[ "$(gb_global "$1")" == "$2" ]] && return 0
        gb_warn "$1 is controlled by GETBIBLE_$1. Change the deployment environment."
        return 1
    fi
    gb_global_set "$1" "$2"
}

# All writers share a lock independent of the long-running manager lock. The
# boot preparation path must never wait for a deployment which is starting it.
infrastructure_environment() (
    local lock_fd file complete=true before after
    gb_ensure_dir "$GB_RUN" 0755 || return 1
    exec {lock_fd}>"$GB_RUN/effective-settings.lock" || return 1
    flock "$lock_fd" || return 1
    if [[ "${1:-}" == --if-missing ]]; then
        for file in dashboard.conf telemetry.env adaptive.env storage.env telegram.conf; do
            [[ -f "$GB_RUN/$file" ]] || complete=false
        done
        [[ "$complete" != true ]] || return 0
    fi
    before="$(infrastructure_dashboard_fingerprint)"
    infrastructure_environment_write || return 1
    after="$(infrastructure_dashboard_fingerprint)"
    if [[ "$before" != "$after" && "${GB_PREPARING_INFRASTRUCTURE:-false}" != true \
        && "${GB_CONTAINER_BOOTSTRAP:-false}" != true && "$GB_DRY_RUN" != true ]] \
        && sd_is_active getbible-dashboard.service; then
        "$GB_SYSTEMCTL" reload getbible-dashboard.service || return 1
    fi
)

infrastructure_dashboard_fingerprint() {
    local file
    for file in dashboard.conf telegram.conf; do
        if [[ -f "$GB_RUN/$file" ]]; then gb_sha256_file "$GB_RUN/$file"; else printf 'missing\n'; fi
    done
}

infrastructure_prepare() {
    local GB_PREPARING_INFRASTRUCTURE=true
    # /etc holds saved settings; Docker's entrypoint additionally captures its
    # authoritative overrides before systemd starts. A complete snapshot may
    # contain direct native command overrides and must remain untouched.
    infrastructure_environment --if-missing
}

infrastructure_environment_write() {
    local key stage telegram default
    gb_ensure_dir "$GB_RUN" 0755 || return 1
    stage="$(gb_tmpdir)/dashboard.conf"
    : > "$stage"
    for key in DASHBOARD_ENABLED DASHBOARD_DOMAIN DASHBOARD_SESSION_DAYS DASHBOARD_IDLE_SECONDS DASHBOARD_TOKEN_SECONDS; do
        case "$key" in
            DASHBOARD_ENABLED) default=false ;;
            DASHBOARD_DOMAIN) default='' ;;
            DASHBOARD_SESSION_DAYS) default=30 ;;
            *) default=60 ;;
        esac
        printf '%s=%s\n' "$key" "$(gb_global "$key" "$default")" >> "$stage"
    done
    printf 'TELEMETRY_DB=%s/telemetry/traffic.sqlite3\nBROKER_SOCKET=%s/run/getbible-admin/broker.sock\nTELEGRAM_CONF=%s/telegram.conf\n' "$GB_VAR" "$GB_PREFIX" "$GB_RUN" >> "$stage"
    printf 'DASHBOARD_RELEASE_FILE=%s\n' "$(management_release_file)" >> "$stage"
    gb_install_file "$stage" "$(dashboard_config)" 0640 root:getbible-dashboard || return 1
    for stage in telemetry adaptive; do
        : > "$(gb_tmpdir)/$stage.env"
        while IFS= read -r key; do
            case "$stage:$key" in
                telemetry:TELEMETRY_*|telemetry:ALERT_*|adaptive:ADAPTIVE_*|adaptive:MEMORY_BUDGET)
                    printf 'GETBIBLE_%s=%s\n' "$key" "$(gb_global "$key")" >> "$(gb_tmpdir)/$stage.env" ;;
                adaptive:QUERY_*|adaptive:SEARCH_*)
                    # The controller reads saved global defaults itself.
                    # Forward only explicit deployment overrides; exporting
                    # defaults would incorrectly replace endpoint settings in
                    # the controller's subsequent resources apply command.
                    if gb_environment_managed "$GB_GLOBAL_CONF" "$key"; then
                        printf 'GETBIBLE_%s=%s\n' "$key" "$(gb_global "$key")" >> "$(gb_tmpdir)/$stage.env"
                    fi ;;
            esac
        done < <(gb_environment_keys)
        printf 'GB_TELEGRAM_CONF=%s/telegram.conf\n' "$GB_RUN" >> "$(gb_tmpdir)/$stage.env"
        gb_install_file "$(gb_tmpdir)/$stage.env" "$GB_RUN/$stage.env" 0640 root:getbible-dashboard || return 1
    done
    printf 'GETBIBLE_STORAGE_MAX_GIB=%s\n' "$(gb_global STORAGE_MAX_GIB 0)" > "$(gb_tmpdir)/storage.env"
    gb_install_file "$(gb_tmpdir)/storage.env" "$GB_RUN/storage.env" 0640 "root:$GB_READERS_GROUP" || return 1
    # Native and container services use the same readable effective snapshot;
    # the original configuration remains root controlled under /etc/getbible.
    telegram="$(gb_tmpdir)/dashboard-telegram.conf"
    : > "$telegram"
    for key in TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_HOSTNAME; do
        printf '%s=%s\n' "$key" "$(cfg_get "$GB_TELEGRAM_CONF" "$key")" >> "$telegram"
    done
    gb_install_file "$telegram" "$GB_RUN/telegram.conf" 0640 "root:$GB_NOTIFY_GROUP"
}



infrastructure_reporting_permissions() {
    local file
    [[ "$GB_DRY_RUN" != true && -z "$GB_PREFIX" ]] || return 0
    # Only the managed SQLite files need repair; never traverse API data or
    # replace database contents. Existing sidecars predate a repaired setgid dir.
    for file in "$GB_VAR/telemetry/traffic.sqlite3" "$GB_VAR/telemetry/traffic.sqlite3-wal" "$GB_VAR/telemetry/traffic.sqlite3-shm"; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        chown root:getbible-dashboard "$file" || [[ ! -e "$file" ]] || return 1
        chmod 0640 "$file" || [[ ! -e "$file" ]] || return 1
    done
}

infrastructure_storage_initial_sample() {
    local root
    local -a args=(sample --config "$GB_GLOBAL_CONF" --environment "$GB_RUN/storage.env" --state "$GB_VAR/storage")
    [[ "$GB_DRY_RUN" != true ]] || return 0
    if [[ -n "$GB_PREFIX" ]]; then
        for root in "$GB_SRV" "$GB_OPT" "$GB_CACHE" "$GB_PREFIX/var/cache/nginx/getbible" "$GB_LOG" "$GB_VAR" "$GB_BACKUPS" "$GB_WWW" "$GB_ETC"; do
            args+=(--root "$root")
        done
    elif sd_available; then
        # Native systemd enforces the sampler's own finite resource limits.
        if ! sd_start getbible-storage.service; then
            gb_warn 'Initial storage accounting failed. Existing APIs remain available; new budgeted publications wait for a fresh sample.'
        fi
        return
    fi
    # Container first boot has no running systemd yet. Finish the bounded local
    # snapshot before any static service can request storage admission.
    if ! timeout --kill-after=5s 75s prlimit --as=536870912 --cpu=60:65 -- "$GB_PYTHON" "$GB_LIBEXEC/getbible-storage-guard" "${args[@]}" >/dev/null; then
        gb_warn 'Initial storage accounting failed. Existing APIs remain available; new budgeted publications wait for a fresh sample.'
        tg_notify fail 'Initial storage accounting failed' 'Existing APIs remain available. New publications with a storage budget wait for the independent sampler to recover.'
    fi
    return 0
}

# Called by ordinary commands only to initialize a missing installation. Boot
# explicitly refreshes effective settings/identities without a DNS/TLS action.
infrastructure_ensure() {
    if [[ ! -f "$GB_SYSTEMD/getbible-prepare.service" || ! -f "$GB_SYSTEMD/getbible-telemetry.service" || ! -f "$GB_SYSTEMD/getbible-storage.timer" || "${GB_CONTAINER_BOOTSTRAP:-false}" == true ]]; then
        infrastructure_install
    else
        infrastructure_environment
    fi
}

# Applying a reviewed manager release refreshes installed code even when its
# units already exist. Ordinary commands only refresh effective configuration.

dashboard_require_telegram() {
    [[ "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)" == true \
        && -n "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_BOT_TOKEN)" \
        && -n "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID)" ]] || {
        gb_warn 'Configure and enable Telegram before enabling the dashboard. Authentication fails closed if delivery is unavailable.'
        return 1
    }
}

dashboard_auth_cli() {
    local helper="$GB_LIBEXEC/getbible-dashboard"
    [[ -x "$helper" ]] || helper="$GB_TOOLS/getbible-dashboard"
    local -a command=(env "GETBIBLE_DASHBOARD_AUDIT_SPOOL=$GB_LOG/dashboard/app/dashboard.log" "$GB_PYTHON" "$helper" --config "$(dashboard_config)" --state-dir "$GB_VAR/dashboard")
    if [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
        runuser -u getbible-dashboard -- "${command[@]}" "$@"
    elif [[ "$GB_DRY_RUN" != true ]]; then
        "${command[@]}" "$@"
    fi
}

dashboard_render() {
    local stage="$1" domain="$2" external=false real_ip=false cert_dir=""
    gb_valid_domain "$domain" || { gb_warn 'Invalid dashboard domain.'; return 1; }
    nginx_validate_proxy_settings || return 1
    nginx_render_global "$stage" || return 1
    if nginx_external_tls; then
        external=true
    else
        nginx_cert_exists "$domain" || { gb_warn "A certificate is required for $domain before dashboard activation."; return 1; }
        cert_dir="$(nginx_cert_dir "$domain")"
        [[ ! -f "$(cf_real_ip_file)" ]] || real_ip=true
    fi
    gb_ensure_dir "$stage/sites-available" 0755 || return 1
    gb_render "$GB_NGINX_SRC/dashboard.conf.tmpl" "$stage/sites-available/getbible-dashboard.conf" \
        "DOMAIN=$domain" "EXTERNAL_TLS=$external" "HTTP_PORT=$(nginx_origin_http_port)" \
        "CERT_DIR=$cert_dir" "REAL_IP=$real_ip" "NGINX_GB=$GB_NGINX_GB" "LOG=$GB_LOG" \
        "SOCKET=$GB_PREFIX/run/getbible-dashboard/http.sock"
}

# Container recreation restores the saved local vhost only. This runs before
# systemd starts, so it never reloads nginx, issues TLS or takes over public DNS.
dashboard_restore_route() {
    local domain stage link
    link="$GB_NGINX/sites-enabled/getbible-dashboard.conf"
    if [[ "$(gb_global DASHBOARD_ENABLED false)" != true ]]; then
        [[ "$GB_DRY_RUN" == true ]] || rm -f "$link"
        if [[ "${GB_CONTAINER_BOOTSTRAP:-false}" == true && -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
            "$GB_SYSTEMCTL" --root=/ disable getbible-dashboard.service >/dev/null 2>&1 || return 1
        fi
        return 0
    fi
    dashboard_require_telegram || return 1
    domain="$(dashboard_domain)"
    ep_exists "$domain" && { gb_warn 'The dashboard hostname conflicts with a configured API domain.'; return 1; }
    stage="$(gb_tmpdir)/dashboard-restore"
    dashboard_render "$stage" "$domain" || return 1
    [[ "$GB_DRY_RUN" != true ]] || return 0
    gb_ensure_dir "$GB_NGINX/sites-available" 0755 || return 1
    gb_ensure_dir "$GB_NGINX/sites-enabled" 0755 || return 1
    gb_install_file "$stage/sites-available/getbible-dashboard.conf" "$GB_NGINX/sites-available/getbible-dashboard.conf" 0644 || return 1
    gb_ledger_record "$GB_NGINX/sites-available/getbible-dashboard.conf" || return 1
    ln -sfn "$GB_NGINX/sites-available/getbible-dashboard.conf" "$link"
}

# Reuse the exact production renderer for eligibility without changing routing.
dashboard_route_matches() {
    local domain="${1:-$(dashboard_domain)}" stage file relative
    stage="$(mktemp -d "$(gb_tmpdir)/dashboard-route-check.XXXXXXXX")" || return 1
    dashboard_render "$stage" "$domain" || return 1
    [[ -L "$GB_NGINX/sites-enabled/getbible-dashboard.conf" && "$(readlink "$GB_NGINX/sites-enabled/getbible-dashboard.conf")" == "$GB_NGINX/sites-available/getbible-dashboard.conf" ]] || return 1
    while IFS= read -r -d '' file; do
        relative="${file#"$stage/"}"
        [[ "$relative" != .tls-* ]] || continue
        cmp -s "$file" "$GB_NGINX/$relative" || return 1
    done < <(find "$stage" -type f -print0)
}

# Only changed routing is installed. Backend release activation is a separate
# transaction; an nginx failure retains the prior route and remains retryable.
dashboard_route_apply() {
    local domain="${1:-$(dashboard_domain)}" stage link old="" conflicts
    dashboard_require_telegram || return 1
    gb_valid_domain "$domain" || { gb_warn 'Set a valid dashboard domain.'; return 1; }
    ep_exists "$domain" && { gb_warn 'The dashboard requires its own hostname, separate from API domains.'; return 1; }
    conflicts="$(nginx_conflicts "$domain" | grep -v '/getbible-dashboard.conf' || true)"
    [[ -z "$conflicts" ]] || { gb_warn "The dashboard hostname is already served by another nginx configuration: $conflicts"; return 1; }
    if dashboard_route_matches "$domain"; then return 0; fi
    stage="$(gb_tmpdir)/dashboard-nginx"
    dashboard_render "$stage" "$domain" || return 1
    link="$GB_NGINX/sites-enabled/getbible-dashboard.conf"
    [[ ! -L "$link" ]] || old="$(readlink "$link")"
    gb_ensure_dir "$GB_NGINX/sites-enabled" 0755 || return 1
    [[ "$GB_DRY_RUN" != true ]] || { gb_log '(dry-run) dashboard route rendered'; return 0; }
    ln -sfn "$GB_NGINX/sites-available/getbible-dashboard.conf" "$link" || return 1
    if ! nginx_apply_stage "$stage" dashboard; then
        if [[ -n "$old" ]]; then ln -sfn "$old" "$link"; else rm -f "$link"; fi
        nginx_test && nginx_reload || true
        return 1
    fi
}

dashboard_apply() {
    local domain="${1:-$(dashboard_domain)}"
    dashboard_require_telegram || return 1
    gb_valid_domain "$domain" || { gb_warn 'Set a valid dashboard domain.'; return 1; }
    ep_exists "$domain" && { gb_warn 'The dashboard requires its own hostname, separate from API domains.'; return 1; }
    infrastructure_update --dashboard || return 1
    sd_enable --now getbible-admin.service getbible-dashboard.service || return 1
    dashboard_route_apply "$domain" || return 1
    dashboard_wait_current || return 1
    tg_notify ok 'Dashboard configured' "The private dashboard is served at https://$domain."
}

dashboard_enable() {
    local domain="${1:-$(dashboard_domain)}" previous_domain previous_enabled method="${2:-auto}" key desired
    gb_valid_domain "$domain" || { gb_warn 'dashboard enable needs a valid hostname.'; return 1; }
    ep_exists "$domain" && { gb_warn 'The dashboard requires a separate hostname from API domains.'; return 1; }
    dashboard_require_telegram || return 1
    for key in DASHBOARD_DOMAIN DASHBOARD_ENABLED; do
        desired=true; [[ "$key" != DASHBOARD_DOMAIN ]] || desired="$domain"
        if gb_environment_managed "$GB_GLOBAL_CONF" "$key" && [[ "$(gb_global "$key")" != "$desired" ]]; then
            gb_warn "$key is controlled by GETBIBLE_$key. Change the deployment environment."
            return 1
        fi
    done
    previous_domain="$(dashboard_domain)"; previous_enabled="$(gb_global DASHBOARD_ENABLED false)"
    if ! nginx_external_tls && [[ "$(gb_global DEFAULT_CLOUDFLARE_MODE off)" == proxied ]]; then
        cloudflare_refresh_ips || return 1
    fi
    if ! nginx_external_tls && ! nginx_cert_exists "$domain"; then
        certs_obtain "$domain" "$method" || return 1
    fi
    dashboard_save_setting DASHBOARD_DOMAIN "$domain" || return 1
    dashboard_save_setting DASHBOARD_ENABLED true || return 1
    if ! dashboard_apply "$domain"; then
        dashboard_save_setting DASHBOARD_DOMAIN "$previous_domain" || true
        dashboard_save_setting DASHBOARD_ENABLED "$previous_enabled" || true
        infrastructure_environment || true
        return 1
    fi
    dashboard_cloudflare_apply "$domain" || return 1
    gb_log "Dashboard ready at https://$domain. Set its password with: getbible dashboard password set"
}

# Explicit activation may manage only this hostname. Dashboard data always
# bypasses edge caches; startup restoration never invokes this function.
dashboard_cloudflare_apply() {
    local domain="$1" mode ipv4 ipv6 proxied=false
    mode="$(gb_global DEFAULT_CLOUDFLARE_MODE off)"
    [[ "$mode" != off ]] || return 0
    cf_enabled || { gb_warn 'Configure Cloudflare before applying its managed dashboard hostname.'; return 1; }
    ipv4="$(cf_public_ipv4)"; ipv6="$(cf_public_ipv6)"
    if cf_external_origin && [[ -z "$ipv4" && ( -z "$ipv6" || "$ipv6" == none ) ]]; then
        gb_warn 'Set an explicit firewall WAN address before managing dashboard DNS.'
        return 1
    fi
    if [[ "$mode" == proxied ]]; then
        proxied=true
        cf_human protect-access "$domain" >&2 || return 1
        cf_human host-rules "$domain" --cache bypass --security api --features "$(gb_global DEFAULT_CLOUDFLARE_FEATURES free)" >&2 || return 1
    fi
    local -a args=(dns "$domain" --proxied "$proxied")
    [[ -z "$ipv4" ]] || args+=(--ipv4 "$ipv4")
    [[ -z "$ipv6" ]] || args+=(--ipv6 "$ipv6")
    cf_human "${args[@]}" >&2 || return 1
    tg_notify info 'Dashboard DNS configured' "Hostname: $domain. Shared caching is disabled."
}

dashboard_disable() {
    local link="$GB_NGINX/sites-enabled/getbible-dashboard.conf" previous=""
    [[ ! -L "$link" ]] || previous="$(readlink "$link")"
    [[ "$GB_DRY_RUN" != true ]] || { gb_log '(dry-run) would disable dashboard'; return 0; }
    if gb_environment_managed "$GB_GLOBAL_CONF" DASHBOARD_ENABLED && [[ "$(gb_global DASHBOARD_ENABLED)" != false ]]; then
        gb_warn 'Change GETBIBLE_DASHBOARD_ENABLED in the deployment environment before disabling the dashboard.'
        return 1
    fi
    rm -f "$link"
    if ! nginx_test || ! nginx_reload; then
        [[ -z "$previous" ]] || ln -sfn "$previous" "$link"
        nginx_test && nginx_reload || true
        return 1
    fi
    dashboard_save_setting DASHBOARD_ENABLED false || return 1
    infrastructure_environment || return 1
    sd_disable_now getbible-dashboard.service
    # The job broker remains alive until its queued actions have completed.
    tg_notify info 'Dashboard disabled' 'Dashboard sessions remain revocable from the CLI.'
}

# Noninteractive credential forms use stdin so secrets never appear in process
# arguments. The ordinary menu keeps its existing secure password dialogs.
dashboard_telegram_configure() {
    local token="" chat="" key
    [[ $# == 3 && "$1" == --chat && "$3" == --token-stdin ]] || { gb_warn 'telegram configure --chat CHAT --token-stdin'; return 1; }
    chat="$2"
    [[ "$chat" =~ ^-?[0-9]+$ || "$chat" =~ ^@[A-Za-z0-9_]+$ ]] || { gb_warn 'Invalid Telegram chat identifier.'; return 1; }
    IFS= read -r token || [[ -n "$token" ]] || return 1
    [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { gb_warn 'Invalid Telegram bot token.'; return 1; }
    for key in TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
        gb_environment_managed "$GB_TELEGRAM_CONF" "$key" && { gb_warn "$key is controlled by the deployment environment."; return 1; }
    done
    cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_BOT_TOKEN "$token" || return 1
    cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID "$chat" || return 1
    cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED true || return 1
    unset token
    tg_install_helper || return 1
    infrastructure_environment || return 1
    tg_notify ok 'Telegram configured' 'Notification and dashboard authentication delivery settings changed.'
}

dashboard_cloudflare_token() {
    local token=""
    gb_environment_managed "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN && { gb_warn 'CLOUDFLARE_API_TOKEN is controlled by the deployment environment.'; return 1; }
    IFS= read -r token || [[ -n "$token" ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { gb_warn 'Invalid Cloudflare API token format.'; return 1; }
    cfg_set "$GB_CLOUDFLARE_CONF" CLOUDFLARE_API_TOKEN "$token" || return 1
    chmod 0600 "$GB_CLOUDFLARE_CONF" || return 1
    unset token
    if ! cf_external_tls; then certs_cloudflare_credentials_write || return 1; fi
    cf_human verify || return 1
    gb_global_set CLOUDFLARE_ENABLED true || return 1
    tg_notify info 'Cloudflare credentials changed' 'The configured API token was updated and verified.'
}

dashboard_password_set() {
    local mode="${1:-set}" input="${2:-}" password confirmation
    case "$mode" in
        reset)
            password="$("$GB_PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')" || return 1 ;;
        set)
            if [[ "$input" == --stdin ]]; then
                IFS= read -r password || [[ -n "${password:-}" ]] || return 1
            else
                password="$(ui_password 'Dashboard password' 'New dashboard password (at least 16 characters)')" || return 1
                confirmation="$(ui_password 'Dashboard password' 'Repeat the new password')" || return 1
                [[ "$password" == "$confirmation" ]] || { gb_warn 'Passwords do not match.'; return 1; }
            fi ;;
        *) gb_warn 'dashboard password set [--stdin] | reset'; return 1 ;;
    esac
    [[ ${#password} -ge 16 ]] || { gb_warn 'Use at least 16 characters for the dashboard password.'; return 1; }
    printf '%s\n' "$password" | dashboard_auth_cli password-set || return 1
    [[ "$mode" != reset ]] || printf 'New dashboard password (shown once): %s\n' "$password"
    unset password confirmation
    tg_notify warn 'Dashboard password changed' 'Existing dashboard sessions and pending authentication challenges were revoked.'
}

dashboard_cli() {
    local action="${1:-status}" sub="${2:-}"
    [[ $# == 0 ]] || shift
    case "$action" in
        status) dashboard_status ;;
        enable)
            [[ $# -le 1 || $# == 3 && "$2" == --cert ]] || { gb_warn 'dashboard enable DOMAIN [--cert auto|http|dns-cloudflare]'; return 1; }
            dashboard_enable "${1:-$(dashboard_domain)}" "${3:-auto}" ;;
        apply|update) dashboard_apply ;;
        disable) dashboard_disable ;;
        password) dashboard_password_set "${1:-set}" "${2:-}" ;;
        sessions)
            if [[ "$sub" == revoke ]]; then
                dashboard_auth_cli revoke-session "${2:?session id or all}" || return 1
                tg_notify warn 'Dashboard session revoked' "Session: $2"
            else dashboard_auth_cli sessions; fi ;;
        blocks) dashboard_auth_cli blocks ;;
        unblock)
            dashboard_auth_cli unblock "${1:?IP address}" || return 1
            tg_notify info 'Dashboard address unblocked' "Address: $1" ;;
        *) gb_warn 'dashboard status|enable DOMAIN|apply|update|disable|password set [--stdin]|password reset|sessions [revoke ID|all]|blocks|unblock IP'; return 1 ;;
    esac
}

menu_dashboard() {
    local choice value output
    while true; do
        choice="$(ui_menu 'Management dashboard' "Domain: $(dashboard_domain)\nEnabled: $(gb_global DASHBOARD_ENABLED false)\nPassword and Telegram are required. Unblocking is only available here or through the CLI." \
            status 'Show installed and running release' enable 'Set domain and enable' update 'Update dashboard to installed manager release' apply 'Apply dashboard configuration' disable 'Disable dashboard domain' \
            password 'Set a password and revoke sessions' reset 'Generate a new password and revoke sessions' \
            sessions 'List sessions' revoke 'Revoke a session or all sessions' blocks 'List blocked addresses' unblock 'Unblock an address' back 'Back')" || return 0
        case "$choice" in
            back) return 0 ;;
            enable)
                value="$(ui_input 'Dashboard domain' 'Separate dashboard hostname (TLS terminator must serve HTTPS)' "$(dashboard_domain)")" || continue
                ui_run 'Enable dashboard' dashboard_enable "$value" || true ;;
            apply|update) ui_run 'Update dashboard' dashboard_apply || true ;;
            disable) ui_run 'Dashboard' dashboard_disable || true ;;
            password) dashboard_password_set set || true ;;
            reset)
                ui_yesno 'Reset password' 'Generate a new password and revoke all dashboard sessions?' no || continue
                output="$(gb_tmpdir)/dashboard-reset"
                dashboard_password_set reset > "$output" || continue
                chmod 0600 "$output"; ui_textbox 'New password (shown once)' "$output"; rm -f "$output" ;;
            revoke)
                value="$(ui_input 'Revoke dashboard sessions' 'Session id, or all' '')" || continue
                ui_run 'Revoke session' dashboard_cli sessions revoke "$value" || true ;;
            unblock)
                value="$(ui_input 'Unblock dashboard address' 'IP address' '')" || continue
                ui_run 'Unblock address' dashboard_cli unblock "$value" || true ;;
            status|sessions|blocks)
                output="$(gb_tmpdir)/dashboard-$choice"
                dashboard_cli "$choice" > "$output" 2>&1 || true
                ui_textbox 'Dashboard' "$output" ;;
        esac
    done
}
