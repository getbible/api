#!/usr/bin/env bash
# Telegram notifications: one bot, one chat, every subsystem on the server.

[[ -n "${GB_TELEGRAM_LOADED:-}" ]] && return 0
GB_TELEGRAM_LOADED=1

tg_enabled() { [[ "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)" == true ]]; }

# tg_notify LEVEL TITLE BODY  (LEVEL: info|start|ok|warn|fail)
tg_notify() {
    local level="$1" title="$2" body="${3:-}"
    if [[ -x "$GB_LIBEXEC/getbible-notify" ]]; then
        "$GB_LIBEXEC/getbible-notify" "$level" "$title" "$body" || true
    else
        GB_TELEGRAM_CONF="$GB_TELEGRAM_CONF" "$GB_TOOLS/getbible-notify" "$level" "$title" "$body" || true
    fi
}

tg_configure() {
    local enabled token chat
    enabled="$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)"
    if ui_yesno "Telegram" "Enable Telegram notifications for every endpoint on this server?" "$([[ "$enabled" == true ]] && echo yes || echo no)"; then
        token="$(ui_password "Telegram" "Bot token (leave empty to keep the stored one)")" || return 1
        [[ -n "$token" ]] && cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_BOT_TOKEN "$token"
        chat="$(ui_input "Telegram" "Chat id" "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID)")" || return 1
        cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID "$chat"
        cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED true
        tg_install_helper
        tg_notify ok "Telegram connected" "Notifications are enabled on $(hostname -f 2>/dev/null || hostname)."
        ui_msg "Telegram" "Telegram notifications are enabled. A test message was sent."
    else
        cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false
        ui_msg "Telegram" "Telegram notifications are disabled."
    fi
}

tg_test() {
    tg_enabled || { ui_msg "Telegram" "Telegram is not enabled."; return 0; }
    tg_notify info "Test message" "getbible.sh test from $(hostname -f 2>/dev/null || hostname)."
    ui_msg "Telegram" "Test message sent."
}

# The helper is installed system-wide so timers and hooks running as other
# users can notify. The configuration file is readable by the notify group.
tg_install_helper() {
    gb_ensure_dir "$GB_LIBEXEC" 0755
    gb_install_file "$GB_TOOLS/getbible-notify" "$GB_LIBEXEC/getbible-notify" 0755
    if gb_is_root && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
        chown "root:$GB_NOTIFY_GROUP" "$GB_TELEGRAM_CONF"
        chmod 0640 "$GB_TELEGRAM_CONF"
    fi
}
