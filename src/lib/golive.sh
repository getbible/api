#!/usr/bin/env bash
# Going live: the moment a staged endpoint takes over its public name.
#
# A staged endpoint has everything installed (code, data, services, nginx with
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
    local domain="$1" kind unit socket
    endpoint_source_type runtime
    kind="$(ep_get "$domain" KIND)"; unit="$(rt_live_unit "$kind")"; socket="$(rt_socket "$kind")"
    if ! sd_available; then
        gb_log "(no systemd) runtime readiness of $domain is not checked here."
        return 0
    fi
    sd_is_active "$unit.service" || { gb_warn "$unit.service is not running; re-apply $domain and check its journal before going live."; return 1; }
    sd_wait_ready "$socket" /readyz 15 || { gb_warn "$domain does not answer /readyz on $socket; check its journal before going live."; return 1; }
    if [[ "$kind" == search ]]; then
        sd_wait_ready "$socket" /probez 15 || { gb_warn "$domain does not pass its search probe; check its journal before going live."; return 1; }
    fi
    gb_log "$domain is ready: $unit.service answers /readyz."
}

# golive_preflight DOMAIN METHOD: everything that must hold before the
# certificate is requested. Never prompts; golive_interactive asks first.
golive_preflight() {
    local domain="$1" method="$2" missing
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
        gb_warn "$domain is managed through Cloudflare here (mode $(ep_get "$domain" CLOUDFLARE_MODE off)) but no Cloudflare API token is stored, so its DNS could not be switched: store it under Settings > Cloudflare API token, or set the endpoint's Cloudflare mode to off and change DNS yourself."
        return 1
    fi
    nginx_cert_exists "$domain" && return 0
    certs_available || { gb_warn "certbot is not installed (System > Install dependencies)."; return 1; }
    if [[ "$method" == dns-cloudflare ]] && ! certs_dns_cloudflare_available; then
        gb_warn "DNS-01 needs the certbot-dns-cloudflare plugin (System > Install dependencies) and a stored Cloudflare API token (Settings > Cloudflare API token)."
        return 1
    fi
    if [[ "$method" == http ]] && golive_cloudflare_managed "$domain" && ! certs_http_probe "$domain"; then
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
    if nginx_cert_exists "$domain"; then
        printf "  %d. Keep the existing Let's Encrypt certificate (expires %s).\n" "$step" "$(certs_expiry "$domain")"
    else
        printf "  %d. Request a Let's Encrypt certificate: %s.\n" "$step" "$(certs_method_description "$method")"
    fi
    step=$((step + 1))
    printf '  %d. Render HTTPS with that certificate, validate and reload nginx.\n' "$step"
    step=$((step + 1))
    if golive_cloudflare_managed "$domain"; then
        ipv4="$(cf_public_ipv4)"; ipv6="$(cf_public_ipv6)"
        printf '  %d. Point the Cloudflare DNS records (%s) at this server: %s%s\n' "$step" "$mode" "${ipv4:-no IPv4 found}" "${ipv6:+, $ipv6}"
        printf '     (Settings > Public addresses overrides the detected address).\n'
        if [[ "$mode" == proxied ]]; then
            [[ "$(ep_get "$domain" CLOUDFLARE_ORIGIN_PULLS false)" == true ]] && pulls=" and require authenticated origin pulls"
            printf '     Apply the API-safe rules and real-IP ranges%s.\n' "$pulls"
        fi
    else
        printf '  %d. Leave DNS alone: it is not managed by Cloudflare here and must already point at this server.\n' "$step"
    fi
    step=$((step + 1))
    printf '  %d. Verify through the local nginx and report on Telegram.\n\n' "$step"
    printf 'Nothing changes until step 1 has succeeded; a failed attempt leaves %s staged.\n' "$domain"
}

# golive_run DOMAIN [METHOD]: the switch itself. Prompts nothing: run it
# through golive_interactive, which gathers every answer first.
golive_run() {
    local domain="$1" requested="${2:-}" method cf_note="" cert_note dns_before verify_note=""
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    if ep_is_live "$domain"; then
        gb_log "$domain is already live."
        return 0
    fi
    method="$(certs_method "$domain" "$requested")" || return 1
    if [[ "$GOLIVE_PREFLIGHT_DONE" != true ]]; then
        golive_preflight "$domain" "$method" || { gb_warn "$domain stays staged."; return 1; }
    fi
    if nginx_cert_exists "$domain"; then cert_note="its existing certificate"; else cert_note="a $method certificate"; fi
    if [[ "$GB_DRY_RUN" == true ]]; then
        gb_log "(dry-run) would issue the certificate ($method), mark $domain live, apply the live configuration and verify it."
        return 0
    fi
    gb_step "Go live: $domain"
    if ! certs_obtain "$domain" "$method"; then
        gb_warn "No certificate was issued; $domain stays staged. Fix the cause and choose 'Go live' again."
        tg_notify fail "Go-live failed: $domain" "The certificate could not be issued ($method); the endpoint stays staged."
        return 1
    fi
    dns_before="$(ep_state_get "$domain" CLOUDFLARE_DNS_AT)"
    ep_set "$domain" LIVE true || return 1
    if ! endpoint_apply "$domain"; then
        ep_set "$domain" LIVE false || true
        gb_warn "Activation failed; $domain is staged again. The certificate is kept for the next attempt."
        tg_notify fail "Go-live failed: $domain" "The live configuration could not be applied; the endpoint is staged again."
        return 1
    fi
    ep_state_set "$domain" LIVE_AT "$(gb_timestamp)"
    if golive_cloudflare_managed "$domain"; then
        # The DNS step is recorded separately from the rules that follow it,
        # so the report says exactly which of the two happened.
        if [[ "$(ep_state_get "$domain" CLOUDFLARE_DNS_AT)" != "$dns_before" ]]; then
            if [[ -n "$(ep_state_get "$domain" CLOUDFLARE_ERROR)" ]]; then
                cf_note=" Cloudflare DNS now points here, but the rules, address ranges or origin CA were not applied: fix the cause, then Endpoint > Cloudflare > Apply."
                gb_warn "Cloudflare DNS for $domain now points here, but the rules were not applied; apply them from Endpoint > Cloudflare once the cause is fixed."
            else
                cf_note=" Cloudflare DNS now points here."
            fi
        else
            cf_note=" Cloudflare DNS was NOT updated (the name still points where it did): fix the cause, then Endpoint > Cloudflare > Apply."
            gb_warn "Cloudflare DNS for $domain was not updated; apply it from Endpoint > Cloudflare once the cause is fixed."
        fi
    fi
    if golive_verify "$domain"; then
        verify_note=" Verification passed."
    else
        verify_note=" Verification reported problems; see the report on the server."
        gb_warn "Verification reported problems for $domain; review the report above."
    fi
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
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    if ! ep_is_live "$domain"; then
        gb_log "$domain is already staged."
        return 0
    fi
    ep_set "$domain" LIVE false || return 1
    ep_state_set "$domain" LIVE_AT "" || return 1
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
# when the endpoint went live, was live already, or the operator cancelled;
# 1 when go-live was refused or failed.
golive_interactive() {
    local domain="$1" requested="${2:-}" method missing out reason status=0 explicit_http=false
    ep_exists "$domain" || gb_die "Unknown endpoint: $domain"
    if ep_is_live "$domain"; then
        ui_msg "Go live" "$domain is already live."
        return 0
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
    if nginx_cert_exists "$domain"; then
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
    if [[ "$method" == http ]] && ! nginx_cert_exists "$domain" && ! golive_cloudflare_managed "$domain" && ! certs_http_probe "$domain"; then
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
    [[ ${#items[@]} -gt 0 ]] || { ui_msg "Go live" "No staged endpoints.\n\nDeploy a new endpoint and answer 'Stage it' to prepare one without taking over its name; it then appears here and under its own endpoint menu."; return 0; }
    domain="$(ui_menu "Go live" "Staged endpoints: choose the one that should take over its name now." "${items[@]}")" || return 0
    golive_interactive "$domain" || true
}

# --- verification ------------------------------------------------------------
golive_row() { printf '  %-30s %-5s %s\n' "$1" "$2" "$3"; }

# golive_probe DOMAIN PATH INSECURE -> HTTP status through 127.0.0.1:443 with
# the real host name, so DNS plays no part.
golive_probe() {
    local domain="$1" path="$2" insecure="$3"
    local -a flags=()
    [[ "$insecure" == true ]] && flags+=(--insecure)
    # curl prints 000 itself when no response arrived.
    curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' \
        --resolve "$domain:443:127.0.0.1" "${flags[@]+"${flags[@]}"}" "https://$domain$path" 2>/dev/null || true
}

# golive_verify DOMAIN: an end-to-end check of this server for DOMAIN, usable
# before go-live (through the placeholder certificate) and after. Prints a
# report and returns 1 when something that must work does not.
golive_verify() {
    local domain="$1" failed=0 source kind unit socket label code path insecure=false note=""
    local -a paths=(/ /healthz)
    ep_load "$domain"
    endpoint_source_type "$EP_TYPE"
    printf 'Verification of %s on %s\n\n' "$domain" "$(hostname -f 2>/dev/null || hostname)"
    golive_row "Publication" info "$(endpoint_publication_text "$domain")"
    golive_row "Access mode" info "$EP_ACCESS_MODE, $(tokens_count "$domain") active token(s)"
    if [[ "$EP_TYPE" == runtime ]]; then
        kind="$EP_KIND"; unit="$(rt_live_unit "$kind")"; socket="$(rt_socket "$kind")"
        paths+=(/readyz)
        golive_row "Release" info "$(py_current_release "$kind")"
        if sd_available; then
            if sd_is_active "$unit.service"; then golive_row "Service" ok "$unit.service active"; else golive_row "Service" FAIL "$unit.service is not active"; failed=$((failed + 1)); fi
            if sd_wait_ready "$socket" /readyz 15; then golive_row "Readiness" ok "$socket answers /readyz"; else golive_row "Readiness" FAIL "$socket does not answer /readyz"; failed=$((failed + 1)); fi
        else
            golive_row "Service" skip "no systemd in this environment"
        fi
    else
        while read -r label; do
            [[ -n "$label" ]] || continue
            [[ "$(ep_version_get "$domain" "$label" ENABLED true)" == true ]] || continue
            if [[ -d "$(ep_version_path "$domain" "$label")" ]]; then
                golive_row "Version $label" ok "published: $(readlink -f -- "$(ep_version_path "$domain" "$label")")"
            else
                golive_row "Version $label" WARN "never published; run 'Sync now'"
            fi
        done < <(ep_versions "$domain")
    fi
    if [[ -f "$(nginx_site_file "$domain")" ]]; then golive_row "nginx site" ok "$(nginx_site_file "$domain")"; else golive_row "nginx site" FAIL "not rendered; re-apply the endpoint"; failed=$((failed + 1)); fi
    if [[ -e "$(nginx_enabled_file "$domain")" ]]; then golive_row "nginx enabled" ok "$(nginx_enabled_file "$domain")"; else golive_row "nginx enabled" FAIL "not enabled"; failed=$((failed + 1)); fi
    nginx_detect
    if [[ "$NG_AVAILABLE" == true && -z "$GB_PREFIX" ]]; then
        if "$GB_NGINX_BIN" -t >/dev/null 2>&1; then golive_row "nginx -t" ok "configuration valid"; else golive_row "nginx -t" FAIL "configuration invalid; run nginx -t"; failed=$((failed + 1)); fi
    else
        golive_row "nginx -t" skip "nginx is not available here"
    fi
    source="$(certs_source "$domain")"
    case "$source" in
        letsencrypt) golive_row "Certificate" ok "$(certs_status_line "$domain")" ;;
        placeholder) golive_row "Certificate" WARN "$(certs_status_line "$domain")"; insecure=true ;;
        *) golive_row "Certificate" FAIL "none; HTTPS is not served"; failed=$((failed + 1)) ;;
    esac
    if [[ "$source" == none ]]; then
        golive_row "HTTPS probe" skip "no certificate"
    elif [[ -n "$GB_PREFIX" || "$NG_AVAILABLE" != true ]] || ! gb_have curl; then
        golive_row "HTTPS probe" skip "nginx is not running here"
    elif grep -q '^[[:space:]]*ssl_verify_client on;' "$(nginx_site_file "$domain")" 2>/dev/null; then
        golive_row "HTTPS probe" skip "origin pulls require Cloudflare's client certificate"
    else
        for path in "${paths[@]}"; do
            code="$(golive_probe "$domain" "$path" "$insecure")"
            note=""
            if [[ "$code" == 000 && "$insecure" == false ]]; then
                # A certificate this host does not trust (a preseeded test
                # certificate, say) is reported rather than hidden.
                code="$(golive_probe "$domain" "$path" true)"
                note=" (certificate not trusted by this host)"
            fi
            if [[ "$code" == 200 ]]; then golive_row "GET $path" ok "200$note"; else golive_row "GET $path" FAIL "HTTP $code$note"; failed=$((failed + 1)); fi
        done
    fi
    # Informational only: this reaches whichever server the public name
    # resolves to right now. GB_VERIFY_PUBLIC=false skips it (tests).
    if ep_is_live "$domain" && [[ -z "$GB_PREFIX" && "${GB_VERIFY_PUBLIC:-true}" == true ]] && gb_have curl; then
        code="$(curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' "https://$domain/healthz" 2>/dev/null || true)"
        golive_row "Public https://$domain/healthz" info "HTTP $code (whichever server DNS resolves to right now)"
    fi
    printf '\n'
    if (( failed == 0 )); then
        printf 'Result: everything that can be checked here passed.\n'
    else
        printf 'Result: %d check(s) failed.\n' "$failed"
    fi
    (( failed == 0 ))
}
