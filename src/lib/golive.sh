#!/usr/bin/env bash
# Going live: the moment a staged domain takes over its public name.
#
# A staged domain has everything installed (code, data, services, nginx with
# a placeholder certificate) but no Let's Encrypt certificate and no DNS
# change, so the server currently serving the name is untouched. Go-live is
# transactional: the certificate comes first; only then is the endpoint marked
# live and applied, which renders the real certificate, applies Cloudflare DNS
# and rules when the domain is Cloudflare-managed, verifies HTTPS through the
# local nginx and notifies. Until the switch nothing changes and the endpoint
# stays staged, so a failed attempt is simply repeated.

[[ -n "${GB_GOLIVE_LOADED:-}" ]] && return 0
GB_GOLIVE_LOADED=1

GOLIVE_ALLOW_UNPUBLISHED="${GOLIVE_ALLOW_UNPUBLISHED:-false}"
GOLIVE_PREFLIGHT_DONE="${GOLIVE_PREFLIGHT_DONE:-false}"
# Only deployment verification waits; these settings do not affect API requests.
GOLIVE_VERIFY_TIMEOUT="${GOLIVE_VERIFY_TIMEOUT:-60}"
GOLIVE_VERIFY_INTERVAL="${GOLIVE_VERIFY_INTERVAL:-5}"

golive_cloudflare_managed() { [[ -n "${GB_CLOUDFLARE_LOADED:-}" && "$(ep_get "$1" CLOUDFLARE_MODE off)" != off ]]; }

golive_staged_domains() {
    local domain
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        ep_is_live "$domain" || printf '%s\n' "$domain"
    done < <(ep_list)
    return 0
}

# Enabled static versions whose tree has never been published, as " v1 v2".
golive_static_unpublished() {
    local domain="$1" label
    while read -r label; do
        [[ -n "$label" ]] || continue
        [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
        [[ -d "$(ep_version_path "$domain" "$label")" ]] || printf ' %s' "$label"
    done < <(ep_versions "$domain")
    return 0
}

golive_runtime_ready() {
    local domain="$1" kind unit socket label
    endpoint_source_type runtime
    kind="$(ep_get "$domain" KIND)"
    if ! sd_available; then
        gb_log "(no systemd) runtime readiness of $domain is not checked here."
        return 0
    fi
    while read -r label; do
        [[ -n "$label" ]] || continue
        unit="$(rt_live_unit "$domain" "$label")"; socket="$(rt_socket "$domain" "$label")"
        sd_is_active "$unit.service" || { gb_warn "$unit.service is not running; re-apply $domain and check its journal before going live."; return 1; }
        sd_wait_ready "$socket" /readyz 15 || { gb_warn "$domain $label does not answer /readyz on $socket; check its journal before going live."; return 1; }
        if [[ "$kind" == search ]]; then
            sd_wait_ready "$socket" /probez 15 || { gb_warn "$domain $label does not pass its search probe; check its journal before going live."; return 1; }
        fi
    done < <(type_runtime_endpoints "$domain")
    gb_log "$domain is ready: every endpoint's service answers /readyz."
}

# golive_preflight DOMAIN METHOD: everything that must hold before the
# certificate is requested. Never prompts; golive_interactive asks first.
golive_preflight() {
    local domain="$1" method="$2" missing
    nginx_validate_proxy_settings || return 1
    if [[ "$(ep_get "$domain" TYPE)" == runtime ]]; then
        golive_runtime_ready "$domain" || return 1
    else
        missing="$(golive_static_unpublished "$domain")"
        if [[ -n "$missing" && "$GOLIVE_ALLOW_UNPUBLISHED" != true ]]; then
            gb_warn "$domain has never published version(s)$missing: run 'Sync now' (the deploy key must be authorised on the repository) so clients find data after go-live."
            return 1
        fi
    fi
    [[ -f "$(nginx_site_file "$domain")" ]] || { gb_warn "$domain has no rendered nginx site; re-apply it first."; return 1; }
    if golive_cloudflare_managed "$domain" && ! cf_enabled; then
        gb_warn "$domain is managed through Cloudflare here (mode $(ep_get "$domain" CLOUDFLARE_MODE off)) but no Cloudflare API token is stored, so its DNS could not be switched: store it under Settings > Cloudflare API token, or set the domain's Cloudflare mode to off and change DNS yourself."
        return 1
    fi
    if nginx_external_tls; then
        gb_log "External TLS: the reverse proxy must serve a valid certificate for $domain; public HTTPS is verified after activation."
        return 0
    fi
    nginx_cert_exists "$domain" && return 0
    certs_available || { gb_warn "certbot is not installed (System > Install dependencies)."; return 1; }
    if [[ "$method" == dns-cloudflare ]] && ! certs_dns_cloudflare_available; then
        gb_warn "DNS-01 needs the certbot-dns-cloudflare plugin (System > Install dependencies) and a stored Cloudflare API token (Settings > Cloudflare API token)."
        return 1
    fi
    if [[ "$method" == http ]] && golive_cloudflare_managed "$domain" && ! golive_wait_public "$domain" http; then
        # The Cloudflare records are switched only after the certificate
        # exists, so HTTP-01 can work only if the name already reaches here.
        gb_warn "$domain is managed through Cloudflare here and its DNS is switched at go-live, but HTTP-01 validation needs the name to reach this server first. Use the dns-cloudflare method (System > Install dependencies adds its plugin), or issue the certificate before going live."
        return 1
    fi
    [[ -n "$(gb_global CERTBOT_EMAIL)" ]] || { gb_warn "No Let's Encrypt contact email is set (Settings > Let's Encrypt contact email)."; return 1; }
    return 0
}

# golive_plan DOMAIN METHOD: what go-live will do, shown before confirming.
golive_plan() {
    local domain="$1" method="$2" mode ipv4="" ipv6="" pulls="" step=1
    mode="$(ep_get "$domain" CLOUDFLARE_MODE off)"
    printf 'Go live: %s (%s %s, access %s)\n\n' "$domain" "$(ep_get "$domain" TYPE)" "$(ep_get "$domain" KIND)" "$(ep_get "$domain" ACCESS_MODE)"
    if nginx_external_tls; then
        printf '  %d. Use externally managed TLS; certificate issuance and renewal belong to the reverse proxy.\n' "$step"
    elif nginx_cert_exists "$domain"; then
        printf "  %d. Keep the existing Let's Encrypt certificate (expires %s).\n" "$step" "$(certs_expiry "$domain")"
    else
        printf "  %d. Request a Let's Encrypt certificate: %s.\n" "$step" "$(certs_method_description "$method")"
    fi
    step=$((step + 1))
    if nginx_external_tls; then
        printf '  %d. Render the complete HTTP origin on port %s, validate and reload nginx.\n' "$step" "$(nginx_origin_http_port)"
    else
        printf '  %d. Render HTTPS with that certificate, validate and reload nginx.\n' "$step"
    fi
    step=$((step + 1))
    if golive_cloudflare_managed "$domain"; then
        ipv4="$(cf_public_ipv4)"; ipv6="$(cf_public_ipv6)"
        if [[ "$mode" == proxied ]]; then
            [[ "$(ep_get "$domain" CLOUDFLARE_ORIGIN_PULLS false)" == true ]] && pulls=" and authenticated origin pulls"
            printf '  %d. Prepare the hostname API rules, cache policy and real-IP ranges%s.\n' "$step" "$pulls"
            step=$((step + 1))
        fi
        printf '  %d. Point the Cloudflare DNS records (%s) at this server: %s%s\n' "$step" "$mode" "${ipv4:-no IPv4 found}" "${ipv6:+, $ipv6}"
        printf '     (Settings > Public addresses overrides the detected address).\n'
    else
        printf '  %d. Leave DNS alone: it is not managed by Cloudflare here and should be pointed at this server by the operator.\n' "$step"
    fi
    step=$((step + 1))
    printf '  %d. Confirm public routing and HTTPS, retrying for up to %s seconds; report the result.\n\n' "$step" "$GOLIVE_VERIFY_TIMEOUT"
    if nginx_external_tls; then
        printf 'The local origin is checked before DNS changes. Public HTTPS verification checks the external certificate after activation.\n'
    else
        printf 'Nothing changes until step 1 has succeeded; a failure before the switch leaves %s staged.\n' "$domain"
    fi
}

# golive_run DOMAIN [METHOD]: the switch itself. Prompts nothing: run it
# through golive_interactive, which gathers every answer first.
golive_run() {
    local domain="$1" requested="${2:-}" method cf_note="" cert_note dns_before verify_note="" cf_failed=false
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    if ep_is_live "$domain"; then
        gb_log "$domain is already live; checking its current availability."
        golive_verify "$domain"
        return $?
    fi
    method="$(certs_method "$domain" "$requested")" || return 1
    if [[ "$GOLIVE_PREFLIGHT_DONE" != true ]]; then
        golive_preflight "$domain" "$method" || { gb_warn "$domain stays staged."; return 1; }
    fi
    if nginx_external_tls; then cert_note="externally managed TLS"
    elif nginx_cert_exists "$domain"; then cert_note="its existing certificate"; else cert_note="a $method certificate"; fi
    if [[ "$GB_DRY_RUN" == true ]]; then
        if nginx_external_tls; then
            gb_log "(dry-run) would activate the HTTP origin, mark $domain live, apply the live configuration and verify public HTTPS."
        else
            gb_log "(dry-run) would issue the certificate ($method), mark $domain live, apply the live configuration and verify it."
        fi
        return 0
    fi
    gb_step "Go live: $domain"
    if ! nginx_external_tls && ! certs_obtain "$domain" "$method"; then
        gb_warn "No certificate was issued; $domain stays staged. Fix the cause and choose 'Go live' again."
        tg_notify fail "Go-live failed: $domain" "The certificate could not be issued ($method); the domain stays staged."
        return 1
    fi
    dns_before="$(ep_state_get "$domain" CLOUDFLARE_DNS_AT)"
    ep_set "$domain" LIVE true || return 1
    if ! GOLIVE_CHECK_ORIGIN=true endpoint_apply "$domain"; then
        if [[ "${EP_APPLY_EDGE_FAILED:-false}" == true ]]; then
            # The origin was committed and verified before the edge update.
            # Keep it serving while reporting the incomplete Cloudflare step.
            cf_failed=true
        else
            ep_set "$domain" LIVE false || true
            if nginx_external_tls; then
                gb_warn "Activation failed; $domain is staged again. Fix the reported origin error before retrying."
            else
                gb_warn "Activation failed; $domain is staged again. The certificate is kept for the next attempt."
            fi
            tg_notify fail "Go-live failed: $domain" "The live configuration could not be applied; the domain is staged again."
            return 1
        fi
    fi
    ep_state_set "$domain" LIVE_AT "$(gb_timestamp)"
    if golive_cloudflare_managed "$domain"; then
        # API rules are prepared before DNS switches. Record DNS separately
        # so a profile failure cannot be reported as a completed takeover.
        if [[ "$(ep_state_get "$domain" CLOUDFLARE_DNS_AT)" != "$dns_before" ]]; then
            if [[ -n "$(ep_state_get "$domain" CLOUDFLARE_ERROR)" ]]; then
                cf_failed=true
                cf_note=" Cloudflare DNS now points here, but the requested Cloudflare changes are incomplete: fix the cause, then Domain > Cloudflare > Apply."
                gb_warn "Cloudflare DNS for $domain now points here, but its update is incomplete; retry Domain > Cloudflare > Apply once the cause is fixed."
            else
                cf_note=" Cloudflare DNS now points here."
            fi
        else
            cf_failed=true
            cf_note=" Cloudflare DNS was NOT updated (the name still points where it did): fix the cause, then Domain > Cloudflare > Apply."
            gb_warn "Cloudflare DNS for $domain was not updated; apply it from Domain > Cloudflare once the cause is fixed."
        fi
    fi
    if ! golive_verify "$domain"; then
        ep_state_set "$domain" GOLIVE_VERIFICATION pending
        gb_warn "$domain remains active; verification is incomplete.$cf_note Run 'getbible.sh verify $domain' to retry. DNS caches may need more time."
        tg_notify warn "Go-live verification pending: $domain" "$domain remains active with $cert_note.$cf_note Verification did not pass; run getbible.sh verify $domain. No service was stopped."
        return 1
    fi
    if [[ "$cf_failed" == true ]]; then
        ep_state_set "$domain" GOLIVE_VERIFICATION pending
        tg_notify warn "Go-live incomplete: $domain" "Availability verification passed.$cf_note The active service was kept."
        gb_warn "$domain is serving, but go-live is incomplete.$cf_note"
        return 1
    fi
    ep_state_set "$domain" GOLIVE_VERIFICATION passed
    verify_note=" Verification passed."
    tg_notify ok "Live: $domain" "$domain is live on $(hostname -f 2>/dev/null || hostname) with $cert_note.$cf_note$verify_note"
    gb_log "$domain is live.$cf_note$verify_note"
    return 0
}

# golive_stage_again DOMAIN: stop taking over the name, for rolling back.
# The endpoint keeps serving (with its Let's Encrypt certificate when it has
# one), but no apply requests a certificate or touches Cloudflare DNS or
# rules again until it goes live once more. DNS itself is not changed here:
# point it at the server that should serve.
golive_stage_again() {
    local domain="$1"
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    if ! ep_is_live "$domain"; then
        gb_log "$domain is already staged."
        return 0
    fi
    ep_set "$domain" LIVE false || return 1
    ep_state_set "$domain" LIVE_AT "" || return 1
    ep_state_set "$domain" GOLIVE_VERIFICATION "" || return 1
    if ! endpoint_apply "$domain"; then
        gb_warn "$domain is staged again, but re-rendering failed; re-apply it."
        return 1
    fi
    tg_notify warn "Staged again: $domain" "$domain no longer takes over its name from $(hostname -f 2>/dev/null || hostname): no certificate request or Cloudflare change until it goes live again. DNS was not changed."
    gb_log "$domain is staged again. DNS was not changed; point it at the server that should serve."
}

golive_stage_again_interactive() {
    local domain="$1"
    ui_yesno "Stage again" "Stage $domain again on this server?\n\nIt keeps serving as it is, but from now on no apply requests a certificate or changes Cloudflare DNS or rules for it, so another server can take the name back. DNS itself is not changed here." no || return 0
    ui_run "Stage again: $domain" golive_stage_again "$domain" || true
}

# The menu and the command line share this: gather every answer first, then
# run the switch without prompts (whiptail captures its output). Returns 0
# when the domain verifies successfully or the operator cancels;
# 1 when go-live was refused, failed, or still awaits public verification.
golive_interactive() {
    local domain="$1" requested="${2:-}" method missing out reason status=0 explicit_http=false
    ep_exists "$domain" || gb_die "Unknown domain: $domain"
    if ep_is_live "$domain"; then
        gb_log "$domain is already live; checking its current availability."
        ui_run "Verify live domain: $domain" golive_verify "$domain"
        return $?
    fi
    GOLIVE_ALLOW_UNPUBLISHED=false
    if [[ "$(ep_get "$domain" TYPE)" == static ]]; then
        missing="$(golive_static_unpublished "$domain")"
        if [[ -n "$missing" ]]; then
            ui_yesno "Unpublished data" "Version(s)$missing of $domain have never been synced (is the deploy key authorised on the repository?). After go-live they answer 404 until the first sync succeeds.\n\nGo live anyway?" no \
                || { gb_warn "Version(s)$missing of $domain have never published; $domain stays staged. Run 'Sync now' first."; return 1; }
            GOLIVE_ALLOW_UNPUBLISHED=true
        fi
    fi
    if nginx_external_tls; then
        method=external
    elif nginx_cert_exists "$domain"; then
        # Nothing to validate: the certificate is reused.
        method=auto
    elif [[ -n "$requested" ]]; then
        method="$requested"
    else
        method="$(certs_prompt_method "$domain")" || { gb_log "Cancelled; $domain stays staged."; return 0; }
    fi
    # Choosing http by name (rather than automatic) means the operator knows
    # the name reaches this server, even when this host cannot see that.
    [[ "$method" == http ]] && explicit_http=true
    method="$(certs_method "$domain" "$method")" || return 1
    nginx_cert_exists "$domain" || certs_email_interactive || return 1
    # Readiness problems are shown as a dialog here, once; the switch itself
    # runs with its output captured.
    if ! reason="$(golive_preflight "$domain" "$method" 2>&1)"; then
        ui_msg "Not ready: $domain" "$domain stays staged.\n\n$reason"
        return 1
    fi
    # A name not managed here must already reach this server for HTTP-01.
    # Every failed validation counts against Let's Encrypt's hourly limit, so
    # ask before trying (non-interactive runs refuse).
    if [[ "$method" == http ]] && ! nginx_cert_exists "$domain" && ! golive_cloudflare_managed "$domain" && ! golive_wait_public "$domain" http; then
        if [[ "$explicit_http" == true ]]; then
            gb_warn "http://$domain/ does not seem to reach this server; trying HTTP-01 anyway because it was chosen explicitly."
        else
            ui_yesno "Name not reachable" "http://$domain/ does not seem to reach this server: DNS may still point elsewhere or may not have propagated, or this host cannot reach its own public address.\n\nLet's Encrypt validation will fail unless the name reaches here, and failed validations are limited to five per hour. Try anyway?" no \
                || { gb_warn "$domain does not seem to reach this server yet; $domain stays staged. Change DNS and try again, choose http explicitly if this host simply cannot reach its own address, or use the dns-cloudflare method."; return 1; }
        fi
    fi
    out="$(gb_tmpdir)/golive-plan.$$"
    golive_plan "$domain" "$method" > "$out"
    ui_textbox "Go live: $domain" "$out"
    ui_yesno "Go live" "Go live with $domain now?" yes || { gb_log "Cancelled; $domain stays staged."; return 0; }
    endpoint_confirm_hand_edits "$domain" || return 0
    GOLIVE_PREFLIGHT_DONE=true
    ui_run "Go live: $domain" golive_run "$domain" "$method" || status=$?
    GOLIVE_PREFLIGHT_DONE=false
    GB_OVERWRITE_HAND_EDITS=false
    return "$status"
}

# Main menu: choose a staged endpoint and take it live.
golive_menu() {
    local domain
    local -a items=()
    while read -r domain; do
        [[ -n "$domain" ]] || continue
        items+=("$domain" "$(ep_get "$domain" TYPE) $(ep_get "$domain" KIND) · certificate: $(certs_source "$domain")")
    done < <(golive_staged_domains)
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Go live" "No staged domains.\n\nDeploy a new domain and answer 'Stage it' to prepare one without taking over its name; it then appears here and under its own domain menu."; return 0; }
    domain="$(ui_menu "Go live" "Staged domains: choose the one that should take over its name now." "${items[@]}")" || return 0
    golive_interactive "$domain" || true
}

# --- verification ------------------------------------------------------------
golive_row() { printf '  %-30s %-5s %s\n' "$1" "$2" "$3"; }

# golive_probe DOMAIN PATH INSECURE -> HTTP status through 127.0.0.1:443 with
# the real host name, so DNS plays no part.
golive_probe() {
    local domain="$1" path="$2" insecure="$3" code=000 deadline remaining port=443 scheme=https
    local -a flags=()
    if nginx_external_tls; then
        port="$(nginx_origin_http_port)"; scheme=http
    elif [[ "$insecure" == true ]]; then
        flags+=(--insecure)
    fi
    # nginx reload signals its master before new workers accept connections.
    # An immediate TLS handshake can still see the staged placeholder. Retry
    # connection/TLS failures within one deadline, with the same trust policy
    # on every attempt. A live certificate is never retried with --insecure.
    deadline=$((SECONDS + 10))
    while :; do
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        code="$(curl --silent --output /dev/null --max-time "$remaining" --write-out '%{http_code}' \
            --noproxy '*' --resolve "$domain:$port:127.0.0.1" --header "Host: $domain" \
            "${flags[@]+"${flags[@]}"}" "$scheme://$domain:$port$path" 2>/dev/null || true)"
        code="${code:-000}"
        [[ "$code" == 000 ]] || break
        (( SECONDS < deadline )) || break
        sleep 1
    done
    printf '%s' "$code"
}

# Unlike HTTP-01, this marker must be served by this installation through
# public HTTPS. The firewall may handle ACME paths itself. Its random filename
# and no-store response prevent a cached health response proving the wrong
# origin. The marker is removed after every attempt.
golive_origin_identity_probe() {
    local domain="$1" timeout="${2:-10}" dir="$GB_VAR/origin-probes" token body
    [[ -z "$GB_PREFIX" ]] || return 0
    gb_have curl || return 1
    gb_ensure_dir "$dir" 0755 || return 1
    token="getbible-probe-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "$token" > "$dir/$token" || return 1
    chmod 0644 "$dir/$token" || { rm -f -- "$dir/$token"; return 1; }
    body="$(curl --silent --max-time "$timeout" --header 'Cache-Control: no-cache' \
        "https://$domain/.well-known/getbible-origin/$token" 2>/dev/null || true)"
    rm -f -- "$dir/$token"
    [[ "$body" == "$token" ]]
}

# Confirm the public route reaches this server despite resolver caches or
# incorrect DNS records. The existing ACME directory supplies a fresh
# random marker; no API requests, tokens or runtime work are involved.
golive_public_probe() {
    local domain="$1" timeout="$2" deadline="$3" code remaining
    if nginx_external_tls; then
        golive_origin_identity_probe "$domain" "$timeout" || return 1
    else
        certs_http_probe "$domain" "$timeout" || return 1
    fi
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || return 1
    (( timeout <= remaining )) || timeout="$remaining"
    code="$(curl --silent --output /dev/null --max-time "$timeout" --write-out '%{http_code}' \
        "https://$domain/healthz" 2>/dev/null || true)"
    [[ "$code" == 200 ]]
}

# A bounded propagation window, shared by pre-certificate HTTP reachability
# and post-switch HTTPS verification. It observes this server's public route;
# no single resolver can establish that every client DNS cache has expired.
golive_wait_public() {
    local domain="$1" mode="${2:-https}" deadline remaining pause timeout attempt=0
    if [[ "$mode" == http && -n "$GB_PREFIX" ]]; then
        certs_http_probe "$domain"
        return $?
    fi
    if [[ -n "$GB_PREFIX" || "${GB_VERIFY_PUBLIC:-true}" == false ]]; then
        # Prefix fixtures never contact real DNS; disposable-host integration
        # explicitly disables public checks for its .test hostnames.
        golive_row "Public route" skip "public verification disabled in this environment"
        return 0
    fi
    if ! gb_have curl; then
        golive_row "Public route" FAIL "curl is unavailable"
        return 1
    fi
    [[ "$GOLIVE_VERIFY_TIMEOUT" =~ ^[0-9]+$ && "$GOLIVE_VERIFY_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
        gb_warn "GOLIVE_VERIFY_TIMEOUT must be seconds >= 0; GOLIVE_VERIFY_INTERVAL must be seconds >= 1."
        return 1
    }
    deadline=$((SECONDS + 10#$GOLIVE_VERIFY_TIMEOUT))
    while :; do
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        timeout="$remaining"
        (( timeout <= 5 )) || timeout=5
        attempt=$((attempt + 1))
        if { [[ "$mode" == http ]] && certs_http_probe "$domain" "$timeout"; } ||
            { [[ "$mode" != http ]] && golive_public_probe "$domain" "$timeout" "$deadline"; }; then
            golive_row "Public route" ok "$domain reaches this server ($mode, attempt $attempt)"
            return 0
        fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        pause=$((10#$GOLIVE_VERIFY_INTERVAL))
        (( pause <= remaining )) || pause="$remaining"
        golive_row "Public route" WAIT "DNS/routing or $mode not ready; retry in ${pause}s (${remaining}s remaining)"
        sleep "$pause"
    done
    golive_row "Public route" WAIT "not confirmed within ${GOLIVE_VERIFY_TIMEOUT}s; service kept active"
    gb_warn "Check A/AAAA records, DNS TTL, routing and TLS, then run 'getbible.sh verify $domain'. Other clients may still use cached DNS."
    return 1
}

# golive_verify DOMAIN: an end-to-end check of this server for DOMAIN, usable
# before go-live (through the placeholder certificate) and after. Prints a
# report and returns 1 when something that must work does not.
golive_verify() {
    local domain="$1" scope="${2:-all}" failed=0 source unit socket label code path insecure=false probe_label="HTTPS probe"
    local -a paths=(/ /healthz)
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    printf 'Verification of %s on %s\n\n' "$domain" "$(hostname -f 2>/dev/null || hostname)"
    golive_row "Publication" info "$(endpoint_publication_text "$domain")"
    golive_row "Access mode" info "$EP_ACCESS_MODE, $(tokens_count "$domain") active token(s)"
    if [[ "$EP_TYPE" == runtime ]]; then
        paths+=(/readyz)
        while read -r label; do
            [[ -n "$label" ]] || continue
            unit="$(rt_live_unit "$domain" "$label")"; socket="$(rt_socket "$domain" "$label")"
            golive_row "Release $label" info "$(py_current_release "$(rt_root "$domain" "$label")")"
            if sd_available; then
                if sd_is_active "$unit.service"; then golive_row "Service $label" ok "$unit.service active"; else golive_row "Service $label" FAIL "$unit.service is not active"; failed=$((failed + 1)); fi
                if sd_wait_ready "$socket" /readyz 15; then golive_row "Readiness $label" ok "$socket answers /readyz"; else golive_row "Readiness $label" FAIL "$socket does not answer /readyz"; failed=$((failed + 1)); fi
            else
                golive_row "Service $label" skip "no systemd in this environment"
            fi
        done < <(type_runtime_endpoints "$domain")
    else
        while read -r label; do
            [[ -n "$label" ]] || continue
            [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
            if [[ -d "$(ep_version_path "$domain" "$label")" ]]; then
                golive_row "Endpoint $label" ok "published: $(readlink -f -- "$(ep_version_path "$domain" "$label")")"
            else
                golive_row "Endpoint $label" WARN "never published; run 'Sync now'"
            fi
        done < <(ep_versions "$domain")
    fi
    if [[ -f "$(nginx_site_file "$domain")" ]]; then golive_row "nginx site" ok "$(nginx_site_file "$domain")"; else golive_row "nginx site" FAIL "not rendered; re-apply the domain"; failed=$((failed + 1)); fi
    if [[ -e "$(nginx_enabled_file "$domain")" ]]; then golive_row "nginx enabled" ok "$(nginx_enabled_file "$domain")"; else golive_row "nginx enabled" FAIL "not enabled"; failed=$((failed + 1)); fi
    nginx_detect
    if [[ "$NG_AVAILABLE" == true && -z "$GB_PREFIX" ]]; then
        if "$GB_NGINX_BIN" -t >/dev/null 2>&1; then golive_row "nginx -t" ok "configuration valid"; else golive_row "nginx -t" FAIL "configuration invalid; run nginx -t"; failed=$((failed + 1)); fi
    else
        golive_row "nginx -t" skip "nginx is not available here"
    fi
    source="$(certs_source "$domain")"
    case "$source" in
        external)
            golive_row "Certificate" info "external reverse proxy; checked through public HTTPS when live"
            probe_label="HTTP origin probe" ;;
        letsencrypt) golive_row "Certificate" ok "$(certs_status_line "$domain")" ;;
        placeholder)
            if ep_is_live "$domain"; then
                golive_row "Certificate" FAIL "live domain still has a self-signed placeholder"
                failed=$((failed + 1))
            else
                golive_row "Certificate" WARN "$(certs_status_line "$domain")"; insecure=true
            fi ;;
        *) golive_row "Certificate" FAIL "none; HTTPS is not served"; failed=$((failed + 1)) ;;
    esac
    if [[ "$source" == none ]]; then
        golive_row "HTTPS probe" skip "no certificate"
    elif [[ -n "$GB_PREFIX" || "$NG_AVAILABLE" != true ]] || ! gb_have curl; then
        golive_row "$probe_label" skip "nginx is not running here"
    elif grep -q '^[[:space:]]*ssl_verify_client on;' "$(nginx_site_file "$domain")" 2>/dev/null; then
        golive_row "HTTPS probe" skip "origin pulls require Cloudflare's client certificate"
    else
        for path in "${paths[@]}"; do
            code="$(golive_probe "$domain" "$path" "$insecure")"
            if [[ "$code" == 200 ]]; then
                golive_row "GET $path" ok "200"
            else
                golive_row "GET $path" FAIL "HTTP $code (check service, certificate trust and hostname)"
                failed=$((failed + 1))
            fi
        done
    fi
    # Local readiness is checked before DNS changes. Only a live domain's
    # complete verification waits for its public route to reach this server.
    if [[ "$scope" != local && "$failed" == 0 ]] && ep_is_live "$domain"; then
        if golive_wait_public "$domain"; then
            if golive_cloudflare_managed "$domain" && [[ -n "$(ep_state_get "$domain" CLOUDFLARE_ERROR)" ]]; then
                golive_row "Cloudflare" FAIL "$(ep_state_get "$domain" CLOUDFLARE_ERROR); Domain > Cloudflare > Apply"
                failed=$((failed + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    fi
    printf '\n'
    if (( failed == 0 )); then
        if [[ "$scope" != local ]] && ep_is_live "$domain" && [[ "$(ep_state_get "$domain" GOLIVE_VERIFICATION)" == pending ]]; then
            ep_state_set "$domain" GOLIVE_VERIFICATION passed
            tg_notify ok "Verification passed: $domain" "Local readiness, public routing and HTTPS now pass. The active service was kept throughout."
        fi
        printf 'Result: everything that can be checked here passed.\n'
    else
        printf 'Result: %d check(s) failed.\n' "$failed"
    fi
    (( failed == 0 ))
}
