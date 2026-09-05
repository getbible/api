#!/usr/bin/env bash
# Terminal user interface: whiptail when a terminal is present, plain prompts
# otherwise, and fully non-interactive when GB_YES=true. Every function prints
# its answer on stdout and returns 1 when the operator cancels.

[[ -n "${GB_UI_LOADED:-}" ]] && return 0
GB_UI_LOADED=1

GB_UI="${GB_UI:-}"
GB_UI_BACKTITLE="getBible API $GB_VERSION"

ui_init() {
    if [[ -n "$GB_UI" ]]; then
        return 0
    fi
    if [[ "$GB_YES" == true ]]; then
        GB_UI=none
    elif gb_have whiptail && [[ -t 0 && -t 1 ]]; then
        GB_UI=whiptail
    else
        GB_UI=cli
    fi
}

ui_size() {
    # Print "height width" for dialogs, bounded to the terminal.
    local lines cols
    lines="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 80)"
    (( lines > 40 )) && lines=40
    (( cols > 110 )) && cols=110
    printf '%s %s\n' "$((lines - 4))" "$((cols - 4))"
}

# ui_menu TITLE TEXT TAG DESCRIPTION [TAG DESCRIPTION ...] -> selected TAG
ui_menu() {
    local title="$1" text="$2"
    shift 2
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" \
                --menu "$text" "$h" "$w" "$((h - 8))" "$@" 3>&1 1>&2 2>&3
            ;;
        cli)
            local -a tags=() descs=()
            while [[ $# -gt 0 ]]; do tags+=("$1"); descs+=("$2"); shift 2; done
            printf '\n== %s ==\n%s\n' "$title" "$text" >&2
            local i
            for i in "${!tags[@]}"; do printf '  %2d) %-18s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2; done
            printf '   0) back\n' >&2
            local answer
            read -r -p "Choice: " answer
            [[ "$answer" =~ ^[0-9]+$ ]] || return 1
            (( answer >= 1 && answer <= ${#tags[@]} )) || return 1
            printf '%s\n' "${tags[$((answer - 1))]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# ui_input TITLE PROMPT DEFAULT -> value
ui_input() {
    local title="$1" prompt="$2" default="${3:-}"
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" \
                --inputbox "$prompt" 12 "$w" "$default" 3>&1 1>&2 2>&3
            ;;
        cli)
            local answer
            read -r -p "$prompt [$default]: " answer
            printf '%s\n' "${answer:-$default}"
            ;;
        *)
            [[ -n "$default" ]] || return 1
            printf '%s\n' "$default"
            ;;
    esac
}

ui_password() {
    local title="$1" prompt="$2"
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" \
                --passwordbox "$prompt" 12 "$w" 3>&1 1>&2 2>&3
            ;;
        cli)
            local answer
            read -r -s -p "$prompt: " answer
            printf '\n' >&2
            printf '%s\n' "$answer"
            ;;
        *)
            return 1
            ;;
    esac
}

# ui_yesno TITLE QUESTION [default yes|no] -> exit status
ui_yesno() {
    local title="$1" question="$2" default="${3:-yes}"
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            local -a flags=()
            [[ "$default" == no ]] && flags+=(--defaultno)
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" "${flags[@]}" --yesno "$question" 14 "$w"
            ;;
        cli)
            local answer
            read -r -p "$question [$([[ "$default" == yes ]] && printf 'Y/n' || printf 'y/N')]: " answer
            answer="${answer:-$default}"
            [[ "${answer,,}" == y* ]]
            ;;
        *)
            [[ "$default" == yes ]]
            ;;
    esac
}

ui_msg() {
    local title="$1" text="$2"
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" --msgbox "$text" "$h" "$w"
            ;;
        *)
            printf '\n== %s ==\n%s\n\n' "$title" "$text" >&2
            ;;
    esac
}

# ui_textbox TITLE FILE: scrollable view of a file.
ui_textbox() {
    local title="$1" file="$2"
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" --scrolltext --textbox "$file" "$h" "$w"
            ;;
        *)
            printf '\n== %s ==\n' "$title" >&2
            cat -- "$file" >&2
            ;;
    esac
}

# ui_checklist TITLE TEXT TAG DESC on|off ... -> space separated tags
ui_checklist() {
    local title="$1" text="$2"
    shift 2
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w out
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            out="$(whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" --separate-output \
                --checklist "$text" "$h" "$w" "$((h - 8))" "$@" 3>&1 1>&2 2>&3)" || return 1
            printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//'
            printf '\n'
            ;;
        cli)
            local -a tags=() states=()
            while [[ $# -gt 0 ]]; do tags+=("$1"); states+=("$3"); shift 3; done
            printf '\n== %s ==\n%s\n' "$title" "$text" >&2
            local i
            for i in "${!tags[@]}"; do printf '  %s [%s]\n' "${tags[$i]}" "${states[$i]}" >&2; done
            local answer
            read -r -p "Space separated selection (empty keeps the defaults): " answer
            if [[ -z "$answer" ]]; then
                for i in "${!tags[@]}"; do [[ "${states[$i]}" == on ]] && printf '%s ' "${tags[$i]}"; done
                printf '\n'
            else
                printf '%s\n' "$answer"
            fi
            ;;
        *)
            local -a tags=() states=()
            while [[ $# -gt 0 ]]; do tags+=("$1"); states+=("$3"); shift 3; done
            local i
            for i in "${!tags[@]}"; do [[ "${states[$i]}" == on ]] && printf '%s ' "${tags[$i]}"; done
            printf '\n'
            ;;
    esac
}

# ui_radiolist TITLE TEXT TAG DESC on|off ... -> tag
ui_radiolist() {
    local title="$1" text="$2"
    shift 2
    ui_init
    case "$GB_UI" in
        whiptail)
            local size h w
            size="$(ui_size)"; h="${size% *}"; w="${size#* }"
            whiptail --backtitle "$GB_UI_BACKTITLE" --title "$title" \
                --radiolist "$text" "$h" "$w" "$((h - 8))" "$@" 3>&1 1>&2 2>&3
            ;;
        *)
            local -a tags=() descs=() states=() default=""
            while [[ $# -gt 0 ]]; do tags+=("$1"); descs+=("$2"); [[ "$3" == on ]] && default="$1"; shift 3; done
            if [[ "$GB_UI" == none ]]; then printf '%s\n' "$default"; return 0; fi
            printf '\n== %s ==\n%s\n' "$title" "$text" >&2
            local i
            for i in "${!tags[@]}"; do printf '  %-14s %s\n' "${tags[$i]}" "${descs[$i]}" >&2; done
            local answer
            read -r -p "Choice [$default]: " answer
            printf '%s\n' "${answer:-$default}"
            ;;
    esac
}

# ui_run TITLE COMMAND...: run a command, capture its output, show it afterwards.
ui_run() {
    local title="$1"
    shift
    ui_init
    local out status=0
    out="$(gb_tmpdir)/ui-run.$$.$RANDOM.log"
    if [[ "$GB_UI" == whiptail ]]; then
        printf 'Running: %s\n\n' "$title" > "$out"
        "$@" >> "$out" 2>&1 || status=$?
        printf '\nExit status: %s\n' "$status" >> "$out"
        ui_textbox "$title" "$out"
    else
        "$@" 2>&1 | tee "$out" || status=${PIPESTATUS[0]}
    fi
    return "$status"
}
