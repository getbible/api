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
    local enabled token chat key
    for key in TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
        if declare -F gb_environment_managed >/dev/null && gb_environment_managed "$GB_TELEGRAM_CONF" "$key"; then
            ui_msg "Telegram" "$key is controlled by GETBIBLE_$key. Change the deployment environment and recreate the container."
            return 1
        fi
    done
    enabled="$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED false)"
    if ui_yesno "Telegram" "Enable Telegram notifications for every endpoint on this server?" "$([[ "$enabled" == true ]] && echo yes || echo no)"; then
        token="$(ui_password "Telegram" "Bot token (leave empty to keep the stored one)")" || return 1
        chat="$(ui_input "Telegram" "Chat id" "$(cfg_get "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID)")" || return 1
        [[ -z "$token" ]] || cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_BOT_TOKEN "$token" || return 1
        cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_CHAT_ID "$chat" || return 1
        cfg_set "$GB_TELEGRAM_CONF" TELEGRAM_ENABLED true || return 1
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
    gb_ensure_dir "$GB_LIBEXEC" 0755 || return 1
    gb_install_file "$GB_TOOLS/getbible-notify" "$GB_LIBEXEC/getbible-notify" 0755 || return 1
    if gb_is_root && [[ -z "$GB_PREFIX" && "$GB_DRY_RUN" != true ]]; then
        chown "root:$GB_NOTIFY_GROUP" "$GB_TELEGRAM_CONF" || return 1
        chmod 0640 "$GB_TELEGRAM_CONF" || return 1
    fi
}
