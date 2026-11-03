#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.3.1 — SSH Tunnel Manager
#
#  Create Tunnel collects, in order:
#    Step 1 — Server
#        Server IP Address/Domain Name   (default: last host used)
#        SSH Username                  (default: current user)
#        SSH Port                      (default: 22)   → ssh's -p argument
#    Step 2 — Tunnel
#        Source Port                   (local bind; default: SSH port)
#        Destination Port              (default: Source Port)
#        SSH parameters                (free-form, appended to the ssh call)
#
#  The destination host is always 127.0.0.1 — the tunnel terminates on the
#  server itself, so the target is whatever listens on the server's loopback.
#
#  Resulting command:
#      ssh -p <ssh_port> <ssh_params> -L <source_port>:127.0.0.1:<dest_port> <user>@<host>
#
#  Connect Tunnel lists the registered tunnels for a server and reconnects.
# ============================================================================

set -o pipefail
VERSION="1.3.1"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''
fi

DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
SERVER_DIR="$DIGGERSH_HOME/servers"
TUNNEL_DIR="$DIGGERSH_HOME/tunnels"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
TARGET_HOST="127.0.0.1"          # fixed — the tunnel terminates on the server
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_PARAMS="-o ServerAliveInterval=30 -o ServerAliveCountMax=5"

info() { printf '%s…%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Prompt with the default shown in brackets, editable. Writes the label to
# stderr so piped scripts still capture it; sets REPLY and EOF_REACHED.
EOF_REACHED=0
ask() {
    local prompt="$1" default="${2:-}" answer=""
    if [[ -n "$default" ]]; then
        printf '%s%s%s %s[%s]%s ' "$C_DIM" "$prompt" "$C_RESET$C_BOLD" "$C_DIM" "$default" "$C_RESET" >&2
    else
        printf '%s%s%s ' "$C_DIM" "$prompt" "$C_RESET" >&2
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

# Prefer a bundled post-quantum build next to the script; fall back to system ssh.
OQS_BIN_DIR=""
if [[ -z "${DIGGERSH_NO_OQS:-}" ]]; then
    _d="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -n "$_d" && -x "$_d/oqs-bin/ssh" ]]; then OQS_BIN_DIR="$_d/oqs-bin"; PATH="$OQS_BIN_DIR:$PATH"; export PATH; fi
    unset _d
fi
SSH_BIN="$(command -v ssh 2>/dev/null || echo ssh)"
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
    mkdir -p "$DIGGERSH_HOME" "$SERVER_DIR" "$TUNNEL_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
}

# ============================================================ create =========
create_tunnel() {
    printf '\n%s── Create Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"

    local last_host last_user
    last_host="$(cfg_get LAST_HOST "")"
    last_user="$(cfg_get LAST_USER "$(id -un 2>/dev/null)")"

    printf '\n%sStep 1 — Server%s\n' "$C_BOLD" "$C_RESET"
    ask "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    ask "SSH Username" "$(id -un 2>/dev/null || echo root)"; local user="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    ask "SSH Port" "$DEFAULT_SSH_PORT"; local sshport="$REPLY"

    printf '\n%sStep 2 — Tunnel%s\n' "$C_BOLD" "$C_RESET"
    ask "Source Port (local bind)" "$sshport"; local sport="$REPLY"
    ask "Destination Port (on the server)" "$sport"; local dport="$REPLY"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"

    # Validate
    for p in "$sshport" "$sport" "$dport"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            err "Invalid port: $p"; return 1
        fi
    done
    [[ -n "$host" ]] || { err "Host is required."; return 1; }

    printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
    printf '  ssh -p %s %s -L %s:%s:%s %s@%s\n' "$sshport" "$params" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    ask "Create? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$sshport"
    cfg_set LAST_SOURCE_PORT "$sport"
    cfg_set LAST_DEST_PORT "$dport"
    cfg_set SSH_PARAMS "$params"

    write_records "$host" "$user" "$sport" "$dport" "$params"
    ok "Tunnel registered."
    start_tunnel "$sport" "$dport" "$user" "$host" "$params"
}

write_records() {
    local host="$1" user="$2" sport="$3" dport="$4" params="$5"
    local slug; slug="$(printf '%s_%s' "${host//[^a-zA-Z0-9._-]/_}" "$sport")"
    {
        printf 'HOST=%s\n'         "$host"
        printf 'USER=%s\n'         "$user"
        printf 'SOURCE_PORT=%s\n'  "$sport"
        printf 'DEST_PORT=%s\n'    "$dport"
        printf 'SSH_PORT=%s\n'     "$sport"
        printf 'SSH_PARAMS=%q\n'   "$params"
        printf 'CREATED=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$SERVER_DIR/$slug.tunnel" 2>/dev/null || true
    chmod 600 "$SERVER_DIR/$slug.tunnel" 2>/dev/null || true
}

# ============================================================ connect =========
list_servers() {
    local f host user sport dport params
    for f in "$SERVER_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        host="$(grep -m1 '^HOST='        "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='       "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='  "$f" | cut -d'=' -f2-)"
        params="$(grep -m1 '^SSH_PARAMS=' "$f" | cut -d'=' -f2-)"
        printf '%s|%s|%s|%s|%s|%s\n' "$(basename "$f" .tunnel)" "$host" "$user" "$sport" "$dport" "$params"
    done | sort
}

connect_tunnel() {
    printf '\n%s── Connect Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_servers)"
    if [[ -z "$out" ]]; then
        warn "No tunnels registered yet — use 'Create Tunnel' first."
        return 0
    fi
    printf '\n%sTunnels:%s\n' "$C_BOLD" "$C_RESET"
    local n=0 line slug host user sport dport params state
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport params <<< "$line"
        state="${C_YELLOW}stopped${C_RESET}"
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$" && state="${C_GREEN}running${C_RESET}"
        printf '  %s%d%s) %s:%s → %s:%s  [%s%s%s]\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$state" "$(echo "$state" | sed 's/\x1b//g')" "$C_RESET"
    done <<< "$out"
    local add=$((n + 1))
    printf '  %s%d%s) %s+ Create a new tunnel%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select tunnel" "1"; local sel="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 0; }
    if [[ "$sel" == "$add" ]]; then create_tunnel || true; return 0; fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > n )); then err "Invalid selection."; return 1; fi

    IFS='|' read -r slug host user sport dport params <<< "$(echo "$out" | sed -n "${sel}p")"
    start_tunnel "$sport" "$dport" "$user" "$host" "$params"
}

start_tunnel() {
    local sport="$1" dport="$2" user="$3" host="$4" params="${5:-}"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
        ok "Port $sport is already bound — tunnel is live."
        return 0
    fi
    # shellcheck disable=SC2086
    nohup "$TRANSPORT" -N -f $params \
        -o StrictHostKeyChecking=accept-new \
        -L "${sport}:127.0.0.1:${dport}" "$user@$host" >/dev/null 2>&1 < /dev/null &
    sleep 1
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
        ok "Tunnel established — localhost:$sport → $TARGET_HOST:$dport"
    else
        warn "Tunnel did not bind $sport — is $host:$dport reachable?"
    fi
}

list_cmd() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_servers)"
    [[ -z "$out" ]] && { info "Nothing registered."; return 0; }
    printf '  %-22s %-14s %-14s %s\n' "HOST" "SOURCE" "DEST" "STATUS"
    local line host user sport dport params state
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host user sport dport params <<< "$line"
        state="${C_YELLOW}stopped${C_RESET}"
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$" && state="${C_GREEN}running${C_RESET}"
        printf '  %-22s %-14s %-14s %s\n' "$host" "$sport" "$dport" "$state"
    done <<< "$out"
    printf '\n'
}

stop_cmd() {
    printf '\n%s── Stop a tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    local found=0 line host sport
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host _ sport _ <<< "$line"
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
            pkill -f "ssh.*-L ${sport}:127.0.0.1" 2>/dev/null || true
            ok "Stopped $host:$sport"; found=1
        fi
    done < <(list_servers)
    (( found == 0 )) && warn "No running tunnels to stop."
}

main_menu() {
    while true; do
        print_banner
        printf '  %s1%s) Create Tunnel\n'  "$C_GREEN" "$C_RESET"
        printf '  %s2%s) Connect Tunnel\n' "$C_GREEN" "$C_RESET"
        printf '  %s3%s) List tunnels\n'  "$C_GREEN" "$C_RESET"
        printf '  %s4%s) Stop a tunnel\n' "$C_YELLOW" "$C_RESET"
        printf '  %s0%s) Exit\n\n'        "$C_RED" "$C_RESET"
        ask "Choose an option" "1"
        [[ "$EOF_REACHED" == "1" ]] && { info "End of input — exiting."; exit 0; }
        case "$REPLY" in
            1) create_tunnel ;;
            2) connect_tunnel ;;
            3) list_cmd ;;
            4) stop_cmd ;;
            0) info "Bye."; exit 0 ;;
            *) err "Unknown option." ;;
        esac
    done
}

init_state
main_menu
