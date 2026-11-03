#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.3.5 — SSH Tunnel Manager
#
#  Each tunnel is recorded with the PID of the process that holds it, so
#  status checks and "Stop" act on a known process rather than pattern-
#  matching the process table (which can match the tool's own shell).
#
#  State layout:
#    ~/.diggerssh/config           defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/tunnels/<id>.tunnel   tunnel record
#    ~/.diggerssh/tunnels/<id>.pid      PID of the live tunnel process
#
#  The -L target host is fixed at 127.0.0.1: the tunnel terminates on the
#  server, so its destination is whatever listens on that server's loopback.
# ============================================================================

set -o pipefail
VERSION="1.3.5"

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

# A tunnel counts as running only when its recorded PID is alive AND the port
# is bound. Pattern-matching the process table alone is unreliable: it can
# match the shell hosting this script.
status_of() {
    local sport="$1" pidfile="$TUNNEL_DIR/$2.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null \
       && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
        printf '%s' "running"
    else
        printf '%s' "stopped"
    fi
}

print_banner() {
    printf '\n'
    printf '%s%s    ____  _                       __________ __  __%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s   / __ \\(_)___ _____ ____  _____/ ___/ ___// / / /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s  / / / / / __ `/ __ `/ _ \\/ ___/\\__ \\__ \\/ /_/ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s / /_/ / / /_/ /  __/ /   ___/ /__/ / __ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
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

# ============================================================ records ========
# One file per tunnel: <host>_<port>.tunnel holding KEY=value pairs.
record_path() { printf '%s/%s.tunnel' "$TUNNEL_DIR" "$(slug_of "$1" "$2")"; }
slug_of()    { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

list_records() {
    local f
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        local host user sport dport params status
        host="$(grep -m1 '^HOST='          "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='   "$f" | cut -d'=' -f2-)"
        params="$(grep -m1 '^SSH_PARAMS=' "$f" | cut -d'=' -f2-)"
        status="$(status_of "$sport" "$(basename "$f" .tunnel)")"
        printf '%s|%s|%s|%s|%s|%s\n' "$(basename "$f" .tunnel)" "$host" "$user" "$sport" "$dport" "$status"
    done | sort
}

save_record() {
    local host="$1" user="$2" sport="$3" dport="$4" params="$5"
    local slug; slug="$(slug_of "$host" "$sport")"
    {
        printf 'ID=%s\n'           "$slug"
        printf 'HOST=%s\n'         "$host"
        printf 'USER=%s\n'         "$user"
        printf 'SOURCE_PORT=%s\n'  "$sport"
        printf 'DEST_PORT=%s\n'    "$dport"
        printf 'SSH_PARAMS=%s\n'   "$params"
        printf 'CREATED=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TUNNEL_DIR/$slug.tunnel"
    chmod 600 "$TUNNEL_DIR/$slug.tunnel" 2>/dev/null || true
}

# ============================================================ submenu ========
submenu() {
    local title="$1" action="$2"
    while true; do
        print_banner
        printf '%s── %s ──%s\n' "$C_BOLD" "$title" "$C_RESET"
        local out; out="$(list_records)"
        local n=0 line slug host user sport dport status
        if [[ -n "$out" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                n=$((n + 1))
                IFS='|' read -r slug host user sport dport status <<< "$line"
                printf '  %s%2d%s) %s:%s → %s:%s  %s%s%s\n' \
                    "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$status" "" "$C_RESET"
            done <<< "$out"
        fi
        local add=$((n + 1))
        printf '  %s%2d%s) %s+ Add new server%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '  %s%2d%s) %sExit to main menu%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"

        ask "Select" "1"
        [[ "$EOF_REACHED" == "1" ]] && { echo; return 0; }
        if [[ "$REPLY" == "0" ]]; then return 0; fi
        if [[ "$REPLY" == "$add" ]]; then "$action" "__new__"; return 0; fi
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= n )); then
            "$action" "$REPLY"
            return 0
        fi
        err "Invalid selection."
    done
}

# ============================================================ actions =========
act_create() {
    if [[ "$1" == "__new__" ]]; then provisioning_form; return; fi
    local out; out="$(list_records)"
    local rec; rec="$(printf '%s\n' "$out" | sed -n "${1}p")"
    local slug host user sport dport
    IFS='|' read -r slug host user sport dport _ <<< "$rec"
    open_tunnel "$host" "$user" "$sport" "$dport" ""
}

act_connect() { act_create "$@"; }
act_list()    { if [[ "$1" == "__new__" ]]; then provisioning_form; fi; }

act_stop() {
    if [[ "$1" == "__new__" ]]; then provisioning_form; return; fi
    local out; out="$(list_records)"
    local rec; rec="$(printf '%s\n' "$out" | sed -n "${1}p")"
    local slug host user sport dport
    IFS='|' read -r slug host user sport dport _ <<< "$rec"
    local pidfile="$TUNNEL_DIR/$slug.pid"
    if [[ ! -f "$pidfile" ]]; then
        warn "Tunnel $slug has no recorded PID — it was not started by this tool."
        return 0
    fi
    local pid; pid="$(cat "$pidfile")"
    if ! kill -0 "$pid" 2>/dev/null; then
        warn "Recorded process $pid is no longer alive."
        rm -f "$pidfile"
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    ok "Tunnel $slug stopped."
}

# ============================================================ provisioning ===
provisioning_form() {
    printf '\n%s── Add New Server ──%s\n' "$C_BOLD" "$C_CYAN"
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
    save_record "$host" "$user" "$sport" "$dport" "$params"
    ok "Tunnel saved."
    open_tunnel "$host" "$user" "$sport" "$dport" "$params"
}

open_tunnel() {
    local host="$1" user="$2" sport="$3" dport="$4" params="${5:-$DEFAULT_SSH_PARAMS}"
    local slug; slug="$(slug_of "$host" "$sport")"
    local pidfile="$TUNNEL_DIR/$slug.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        ok "Tunnel $slug is already running (pid $(cat "$pidfile"))."
        return 0
    fi
    # shellcheck disable=SC2086
    nohup "$TRANSPORT" -N -f $params \
        -o StrictHostKeyChecking=accept-new \
        -L "${sport}:${TARGET_HOST}:${dport}" "$user@$host" > "$TUNNEL_DIR/$slug.log" 2>&1 < /dev/null &
    local pid=$!
    sleep 1
    printf '%s\n' "$pid" > "$pidfile"
    ok "Tunnel started (pid $pid) — localhost:$sport → $TARGET_HOST:$dport"
}

# ------------------------------------------------------------------ menu ----
main_menu() {
    while true; do
        print_banner
        printf '  %s1%s) Create Tunnel to Server\n'              "$C_GREEN" "$C_RESET"
        printf '  %s2%s) Connect Tunnel (to a server'"'"'s Port)\n' "$C_GREEN" "$C_RESET"
        printf '  %s3%s) List tunnels\n'                       "$C_GREEN" "$C_RESET"
        printf '  %s4%s) Stop a tunnel\n'                     "$C_YELLOW" "$C_RESET"
        printf '  %s0%s) Exit\n\n'                            "$C_RED"   "$C_RESET"
        ask "Choose an option" "1"
        [[ "$EOF_REACHED" == "1" ]] && { info "End of input — exiting."; exit 0; }
        case "$REPLY" in
            1) submenu "Create Tunnel to Server" act_create ;;
            2) submenu "Connect Tunnel (to a server's Port)" act_connect ;;
            3) submenu "List tunnels" act_list ;;
            4) submenu "Stop a tunnel" act_stop ;;
            0) info "Bye."; exit 0 ;;
            *) err "Unknown option." ;;
        esac
    done
}

init_state
main_menu
