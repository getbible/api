#!/usr/bin/env bash
# Access modes (open, metered, token), bearer tokens and the nginx snippets
# that enforce them.

[[ -n "${GB_ACCESS_LOADED:-}" ]] && return 0
GB_ACCESS_LOADED=1

GB_ACCESS_MODES=(open metered token)

access_valid_mode() { [[ "$1" == open || "$1" == metered || "$1" == token ]]; }

access_mode_description() {
    case "$1" in
        open) printf 'Open: everybody, no limits at all\n' ;;
        metered) printf 'Metered: public callers get a budget, token holders are unlimited\n' ;;
        token) printf 'Token only: a bearer token is required, token holders are unlimited\n' ;;
    esac
}

# Integer ceiling division helper for quota rates.
access_ceil_div() { printf '%s\n' "$(( ($1 + $2 - 1) / $2 ))"; }

# Render /etc/nginx/getbible/<domain>/limits.conf for the loaded EP_* endpoint.
access_render_limits() {
    local output="$1"
    case "$EP_ACCESS_MODE" in
        metered)
            {
                printf '# %s: metered access. Token holders carry an empty key and are never limited.\n' "$EP_DOMAIN"
                printf 'limit_req  zone=gb_%s_sec  burst=%s nodelay;\n' "$EP_SLUG" "$EP_RATE_BURST"
                printf 'limit_req  zone=gb_%s_hour burst=%s nodelay;\n' "$EP_SLUG" "$(access_ceil_div "$EP_QUOTA_HOUR" 4)"
                printf 'limit_req  zone=gb_%s_day  burst=%s nodelay;\n' "$EP_SLUG" "$(access_ceil_div "$EP_QUOTA_DAY" 4)"
                printf 'limit_conn gb_%s_conn %s;\n' "$EP_SLUG" "$EP_CONN_LIMIT"
            } > "$output"
            ;;
        token)
            printf '# %s: token-only access, no limits for authenticated callers.\n' "$EP_DOMAIN" > "$output"
            ;;
        *)
            printf '# %s: open access, no limits.\n' "$EP_DOMAIN" > "$output"
            ;;
    esac
}

# Render /etc/nginx/getbible/<domain>/auth.conf (included inside data locations).
access_render_auth() {
    local output="$1"
    if [[ "$EP_ACCESS_MODE" == token ]]; then
        {
            printf '# %s: a bearer token is required.\n' "$EP_DOMAIN"
            # shellcheck disable=SC2016
            printf 'if ($gb_token_id = "") {\n    return 401;\n}\n'
        } > "$output"
    else
        printf '# %s: no token required.\n' "$EP_DOMAIN" > "$output"
    fi
}

# Rates for the http-context zones: quota per hour/day expressed per minute.
access_hour_rate() { access_ceil_div "$EP_QUOTA_HOUR" 60; }
access_day_rate() { access_ceil_div "$EP_QUOTA_DAY" 1440; }

# --- tokens ------------------------------------------------------------------
tokens_cmd() { "$GB_PYTHON" "$GB_TOOLS/getbible-tokens" "$@"; }

tokens_render_map() {
    # tokens_render_map DOMAIN OUTPUT
    local domain="$1" output="$2" file
    file="$(ep_tokens_file "$domain")"
    if [[ -f "$file" ]]; then
        tokens_cmd "$file" render-map "$domain" > "$output"
    else
        : > "$output"
    fi
}

tokens_render_validity_map() {
    local domain="$1" output="$2" file
    file="$(ep_tokens_file "$domain")"
    if [[ -f "$file" ]]; then
        tokens_cmd "$file" render-validity-map "$domain" > "$output"
    else
        : > "$output"
    fi
}

tokens_list() { tokens_cmd "$(ep_tokens_file "$1")" list; }
tokens_count() {
    local file
    file="$(ep_tokens_file "$1")"
    [[ -f "$file" ]] && tokens_cmd "$file" count || printf '0\n'
}

# tokens_add DOMAIN LABEL [EXPIRES] -> prints JSON with the secret once
tokens_add() {
    local domain="$1" label="$2" expires="${3:-}" file
    gb_valid_label "$label" || gb_die "Invalid token label: $label"
    file="$(ep_tokens_file "$domain")"
    gb_ensure_dir "$(ep_dir "$domain")" 0750
    if [[ -n "$expires" ]]; then
        tokens_cmd "$file" add --label "$label" --expires "$expires"
    else
        tokens_cmd "$file" add --label "$label"
    fi
    chmod 0600 "$file" 2>/dev/null || true
}

tokens_revoke() { tokens_cmd "$(ep_tokens_file "$1")" revoke "$2"; }
