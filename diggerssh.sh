#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.3.3 — SSH Tunnel Manager
#
#  Main menu:
#    1) Create Tunnel to Server
#    2) Connect Tunnel (to a server's Port)
#    3) List tunnels
#    4) Stop a tunnel
#    0) Exit
#
#  "Connect Tunnel (to a server's Port)" opens a submenu listing every
#  configured tunnel, followed by "+ Add new server" and a final "Exit" that
#  returns to the main menu. With no tunnels configured the submenu shows
#  only those two entries.
#
#  State layout:
#    ~/.diggerssh/config           defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/tunnels/*.tunnel one file per tunnel
#
#  The -L target host is fixed at 127.0.0.1: the tunnel terminates on the
#  server, so its destination is whatever listens on that server's loopback.
# ============================================================================

set -o pipefail
VERSION="1.3.3"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''
fi

DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
TUNNEL_DIR="$DIGGERSH_HOME/tunnels"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
TARGET_HOST="127.0.0.1"
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_PARAMS="-o ServerAliveInterval=30 -o ServerAliveCountMax=5"

info() { printf '%s…%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

EOF_REACHED=0
ask() {
    local prompt="$1" default="${2:-}" answer=""
    if [[ -n "$default" ]]; then
        printf '%s%s%s %s[%s]%s: ' "$C_DIM" "$prompt" "$C_RESET$C_BOLD" "$C_DIM" "$default" "$C_RESET" >&2
    else
        printf '%s%s%s: ' "$C_DIM" "$prompt" "$C_RESET" >&2
    fi
    if ! IFS= read -r answer; then answer=""; EOF_REACHED=1; fi
    REPLY="${answer:-$default}"
}

cfg_get() {
    local key="$1" fallback="${2:-}" val=""
    [[ -f "$CONFIG_FILE" ]] && val="$(grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2-)"
    printf '%s' "${val:-$fallback}"
}
cfg_set() {
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    grep -v "^$1=" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

if [[ -z "${DIGGERSH_NO_OQS:-}" ]]; then
    _d="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -n "$_d" && -x "$_d/oqs-bin/ssh" ]]; then PATH="$_d/oqs-bin:$PATH"; export PATH; fi
    unset _d
fi
command -v autossh >/dev/null 2>&1 && TRANSPORT="autossh" || TRANSPORT="ssh"

print_banner() {
    printf '\n'
    printf '%s%s    ____  _                       __________ __  __%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s   / __ \\(_)___ _____ ____  _____/ ___/ ___// / / /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s  / / / / / __ `/ __ `/ _ \\/ ___/\\__ \\__ \\/ /_/ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s / /_/ / / /_/ / /_/ /  __/ /   ___/ /__/ / __ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s/_____/_/\\__, /\\__, /\\___/_/   /____/____/_/ /_/%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s        /____//____/%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   v%s  SSH tunnel manager%s\n' "$C_CYAN" "$VERSION" "$C_RESET"
    printf '\n'
}

init_state() {
    mkdir -p "$DIGGERSH_HOME" "$TUNNEL_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
}

is_running() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$"; }

# ============================================================ the tunnel list
list_tunnel_records() {
    local f
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        local host user sport dport params status
        host="$(grep -m1 '^HOST='          "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='   "$f" | cut -d'=' -f2-)"
        params="$(grep -m1 '^SSH_PARAMS=' "$f" | cut -d'=' -f2-)"
        if is_running "$sport"; then status="${C_GREEN}running${C_RESET}"; else status="${C_YELLOW}stopped${C_RESET}"; fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$(basename "$f" .tunnel)" "$host" "$user" "$sport" "$dport" "$params" "$status"
    done | sort
}

# ============================================================ 1) Create ========
# "Create Tunnel to Server" — the provisioning form. Saves the tunnel record
# and opens it.
create_tunnel() {
    printf '\n%s── Create Tunnel to Server ──%s\n' "$C_BOLD" "$C_CYAN"
    local last_host last_user
    last_host="$(cfg_get LAST_HOST "")"
    last_user="$(cfg_get LAST_USER "$(id -un 2>/dev/null)")"

    printf '\n%sStep 1 — Server%s\n' "$C_BOLD" "$C_RESET"
    ask "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "SSH Username" "$last_user"; local user="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "SSH Port" "$DEFAULT_SSH_PORT"; local sshport="$REPLY"

    printf '\n%sStep 2 — Tunnel%s\n' "$C_BOLD" "$C_RESET"
    ask "Source Port (local bind)" "$sshport"; local sport="$REPLY"
    ask "Destination Port (on the server)" "$sport"; local dport="$REPLY"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"

    for p in "$sshport" "$sport" "$dport"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then err "Invalid port: $p"; return 1; fi
    done
    [[ -n "$host" ]] || { err "Host is required."; return 1; }

    printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
    printf '  ssh -p %s %s -L %s:%s:%s %s@%s\n' "$sport" "$params" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    ask "Save? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$sport"
    cfg_set LAST_SOURCE_PORT "$sport"
    cfg_set LAST_DEST_PORT "$dport"
    save_tunnel "$host" "$user" "$sport" "$dport" "$params"
    ok "Tunnel saved."
    open_tunnel "$sport" "$dport" "$user" "$host" "$params"
}

save_tunnel() {
    local host="$1" user="$2" sport="$3" dport="$4" params="$5"
    local slug; slug="$(printf '%s_%s' "${host//[^a-zA-Z0-9._-]/_}" "$sport")"
    {
        printf 'HOST=%s\n'        "$host"
        printf 'USER=%s\n'        "$user"
        printf 'SOURCE_PORT=%s\n' "$sport"
        printf 'DEST_PORT=%s\n'   "$dport"
        printf 'SSH_PARAMS=%s\n'  "$params"
        printf 'CREATED=%q\n'     "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TUNNEL_DIR/$sport.tunnel"
    chmod 600 "$TUNNEL_DIR/$sport.tunnel" 2>/dev/null || true
}

# ============================================================ 2) Connect =======
# "Connect Tunnel (to a server's Port)" — lists the configured tunnels, then
# "+ Add new server", then "Exit". Choosing a tunnel opens it; choosing
# "+ Add new server" runs the provisioning form; "Exit" returns to the main
# menu.
connect_tunnel() {
    while true; do
        print_banner
        printf '%s── Connect Tunnel (to a server'"'"'s Port) ──%s\n' "$C_BOLD" "$C_CYAN"
        local out; out="$(list_tunnel_records)"
        local n=0
        if [[ -n "$out" ]]; then
            local line slug host user sport dport params status
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                n=$((n + 1))
                IFS='|' read -r slug host user sport dport params status <<< "$line"
                printf '  %s%2d%s) %s  %s:%s → %s:%s  [%srunning%s]\n' \
                    "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$C_DIM" "$C_RESET"
            done <<< "$out"
        fi
        printf '  %s%2d%s) %s+ Add new server%s\n' "$C_CYAN" "$((n + 1))" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '  %s%2d%s) %sExit%s\n\n'          "$C_RED"   "0"        "$C_RESET" "$C_DIM" "$C_RESET"

        ask "Select" "1"
        [[ "$EOF_REACHED" == "1" ]] && { echo; return 0; }
        case "$REPLY" in
            0) return 0 ;;
            "$((n + 1))") provisioning_submenu ;;
        esac
        if [[ "$REPLY" != "0" && "$REPLY" != "$((n + 1))" ]]; then
            if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= n )); then
                local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
                local rhost rus rspot rdpar rpar
                IFS='|' read -r _ rhost rus rsport rdport rparams <<< "$out"
                open_tunnel "$rsport" "$rdport" "$rus" "$rhost" "$rparams"
            else
                err "Invalid selection."
            fi
        fi
    done
}

# The provisioning form reached from inside the Connect submenu.
provisioning_submenu() {
    create_tunnel
}

# ============================================================ 3) List ==========
list_cmd() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_tunnel_records)"
    if [[ -z "$out" ]]; then info "No tunnels registered."; return 0; fi
    printf '  %-4s %-16s %-10s %-10s %-10s %s\n' "#" "HOST" "SOURCE" "DEST" "STATUS" "TRANSPORT"
    printf '  %-4s %-16s %-10s %-10s %-10s %s\n' "---" "----" "------" "----" "------" "---------"
    local n=0 line slug host user sport dport params status
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport params status <<< "$line"
        printf '  %-4s %-16s %-10s %-10s %-10s %s\n' "$n" "$host" "$sport" "$dport" "$status" "$TRANSPORT"
    done <<< "$out"
    printf '\n'
}

# ============================================================ 4) Stop ==========
stop_cmd() {
    printf '\n%s── Stop a tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_tunnel_records)"
    if [[ -z "$out" ]]; then info "No tunnels registered."; return 0; fi
    local n=0 line slug host user sport dport params status
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport params status <<< "$line"
        printf '  %s%2d%s) %s:%s → %s:%s  %s%s%s\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$status" "" "$C_RESET"
    done <<< "$out"
    printf '  %s%2d%s) %sExit%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"
    ask "Select" "1"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 0; }
    [[ "$REPLY" == "0" ]] && return 0
    if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || (( REPLY < 1 || REPLY > n )); then err "Invalid selection."; return 1; fi
    local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
    local rhost rus rsport rdport rparams
    IFS='|' read -r _ rhost rus rsport rdport rparams <<< "$rec"
    if ! is_running "$rsport"; then warn "Tunnel $rsport is not running."; return 0; fi
    pkill -f "ssh.*-L ${rsport}:${TARGET_HOST}:${rdport}" 2>/dev/null || true
    sleep 1
    is_running "$rsport" && warn "Port $rsport still bound." || ok "Tunnel $rsport stopped."
}

open_tunnel() {
    local sport="$1" dport="$2" user="$3" host="$4" params="${5:-}"
    if is_running "$sport"; then ok "Tunnel $sport is already running."; return 0; fi
    # shellcheck disable=SC2086
    nohup "$TRANSPORT" -N -f $params \
        -o StrictHostKeyChecking=accept-new \
        -L "${sport}:${TARGET_HOST}:${dport}" "$user@$host" >/dev/null 2>&1 < /dev/null &
    sleep 1
    if is_running "$sport"; then
        ok "Tunnel established — localhost:$sport → $TARGET_HOST:$dport"
    else
        warn "Tunnel did not bind $sport — is $host:$dport reachable?"
    fi
}

main_menu() {
    while true; do
        print_banner
        printf '  %s1%s) Create Tunnel to Server\n'           "$C_GREEN" "$C_RESET"
        printf '  %s2%s) Connect Tunnel (to a server'"'"'s Port)\n' "$C_GREEN" "$C_RESET"
        printf '  %s3%s) List tunnels\n'                   "$C_GREEN" "$C_RESET"
        printf '  %s4%s) Stop a tunnel\n'                 "$C_YELLOW" "$C_RESET"
        printf '  %s0%s) Exit\n\n'                       "$C_RED" "$C_RESET"
        ask "Choose an option" "1"
        [[ "$EOF_REACHED" == "1" ]] && { info "End of input — exiting."; exit 0; }
        case "$REPLY" in
            1) create_tunnel; return ;;
            2) connect_tunnel; return ;;
            3) list_cmd ;;
            4) stop_cmd ;;
            0) info "Bye."; exit 0 ;;
            *) err "Unknown option." ;;
        esac
    done
}

init_state
main_menu
