#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.3.0 — SSH Tunnel Manager
#
#  Two-tier model:
#    Tier 1  SERVERS   — a local registry (~/.diggerssh/servers/) of SSH hosts.
#    Tier 2  TUNNELS   — each server keeps its own registry on the remote side
#                        (~/.diggerssh/ on the server), so tunnels created from
#                        any machine are visible everywhere.
#
#  "Connect Tunnel" lists servers (last entry: "+ Add new server"), then lists
#  the tunnels registered on the chosen server, then opens the tunnel using
#  the same port the tunnel uses on the server.
#
#  Uses autossh when installed, plain ssh otherwise.
# ============================================================================

set -o pipefail

VERSION="1.3.0"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''
fi

DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
SERVER_DIR="$DIGGERSH_HOME/servers"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
REMOTE_REGISTRY_DIR=".diggerssh"

DEFAULT_SSH_PORT="22"
DEFAULT_SSH_PARAMS="-o ServerAliveInterval=30 -o ServerAliveCountMax=5"

info() { printf '%s›%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Prompt to stderr; answer from stdin. EOF_REACHED distinguishes "user pressed
# Enter on an empty line" from "input ended" so menu loops exit instead of
# spinning on the default forever.
EOF_REACHED=0
ask() {
    local prompt="$1" default="${2:-}" answer
    printf '%s%s : %s' "$C_DIM" "$prompt" "$C_RESET" >&2
    if ! IFS= read -r answer; then answer=""; EOF_REACHED=1; fi
    REPLY="${answer:-$default}"
}

cfg_get() {
    local key="$1" fallback="${2:-}" val=""
    [[ -f "$CONFIG_FILE" ]] && val="$(grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)"
    printf '%s' "${val:-$fallback}"
}
cfg_set() {
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    grep -v "^$1=" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# Prefer a bundled post-quantum ssh when it sits next to the script.
OQS_BIN_DIR=""
if [[ -z "${DIGGERSH_NO_OQS:-}" ]]; then
    _d="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -n "$_d" && -x "$_d/oqs-bin/ssh" ]]; then
        OQS_BIN_DIR="$_d/oqs-bin"; PATH="$OQS_BIN_DIR:$PATH"; export PATH
    fi
    unset _d
fi
SSH_BIN="$(command -v ssh)"
if command -v autossh >/dev/null 2>&1; then TRANSPORT="autossh"; else TRANSPORT="ssh"; fi

print_banner() {
    printf '\n%s%s    ____  _                       __________ __  __%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s   / __ \\(_)___ _____ ____  _____/ ___/ ___// / / /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s  / / / / / __ `/ __ `/ _ \\/ ___/\\__ \\__ \\/ /_/ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s / /_/ / / /_/ / /_/ /  __/ /   ___/ /__/ / __ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s/_____/_/\\__, /\\__, /\\___/_/   /____/____/_/ /_/%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s        /____//____/%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   v%s  SSH tunnel manager%s\n' "$C_CYAN" "$VERSION" "$C_RESET"
    printf '\n'
}

init_state() {
    mkdir -p "$DIGGERSH_HOME" "$SERVER_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
}

# ============================================================ tier 1: servers
server_slug() { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

list_servers() {
    local f host user port params
    for f in "$SERVER_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        host="$(grep -m1 '^HOST=' "$f" | cut -d= -f2-)"
        user="$(grep -m1 '^USER=' "$f" | cut -d= -f2-)"
        port="$(grep -m1 '^SSH_PORT=' "$f" | cut -d= -f2-)"
        params="$(grep -m1 '^SSH_PARAMS=' "$f" | cut -d= -f2-)"
        printf '%s|%s|%s|%s|%s\n' "$(basename "$f" .conf)" "$host" "$user" "$port" "$params"
    done | sort
}

add_server() {
    printf '\n%s── Add New Server ──%s\n' "$C_BOLD" "$C_CYAN"
    local last_user last_host
    last_user="$(cfg_get LAST_USER "$(id -un 2>/dev/null || echo root)")"
    last_host="$(cfg_get LAST_HOST "")"

    ask "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "SSH Username" "$last_user"; local user="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "SSH Port" "$DEFAULT_SSH_PORT"; local port="$REPLY"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "Invalid port: $port"; return 1
    fi

    local file; file="$SERVER_DIR/$(server_slug "$host" "$port").conf"
    [[ -f "$file" ]] && warn "Already registered — updating in place."

    {
        printf 'HOST=%s\n'       "$host"
        printf 'USER=%s\n'       "$user"
        printf 'SSH_PORT=%s\n'   "$port"
        printf 'SSH_PARAMS=%s\n' "$params"
        printf 'CREATED=%q\n'    "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$file"
    chmod 600 "$file" 2>/dev/null || true

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$port"
    ok "Server registered: $user@$host:$port"
}

# ============================================================ tier 2: tunnels
# Reads the registry the SERVER holds at ~/.diggerssh/. The remote command is
# double-quoted so $host etc. expand locally while \$f stays remote; </dev/null
# stops the child from eating this script's queued answers.
list_remote_tunnels() {
    local host="$1" user="$2" port="$3"
    timeout 20 "$SSH_BIN" -p "$port" \
        -o BatchMode=yes -o ConnectTimeout=8 \
        "$user@$host" \
        "for f in ~/$REMOTE_REGISTRY_DIR/*.tunnel; do [ -e \"\$f\" ] || continue; echo '@@FILE@@'; cat \"\$f\"; done" \
        2>/dev/null </dev/null | awk -F= '
            function flush() { if (id!="") printf "%s|%s|%s|%s|%s\n", id, host, user, sport, label }
            /^@@FILE@@$/ { flush(); next }
            { line=$0; sub(/=.*/,"",line); val=$0; sub(/^[^=]*=/,"",val); gsub(/\r/,"",val)
              if (line=="ID") id=val
              else if (line=="HOST") host=val
              else if (line=="USER") user=val
              else if (line=="SOURCE_PORT") sport=val
              else if (line=="KEY_LABEL") label=val
              else if (line=="SSH_PARAMS") params=val }
            END { flush() }'
}

connect_tunnel() {
    printf '\n%s── Connect Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"

    if [[ "$(list_servers | grep -c .)" == "0" ]]; then
        info "No servers registered yet — adding one now."
        add_server || true
        if [[ "$(list_servers | grep -c .)" == "0" ]]; then warn "Nothing registered."; return; fi
    fi

    printf '\n%sServers:%s\n' "$C_BOLD" "$C_RESET"
    local -a srv=(); local n=0 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        srv+=("$line"); n=$((n+1))
        local s h u p
        IFS='|' read -r s h u p _ <<< "$line"
        printf '  %s%d%s) %s:%s\n' "$C_GREEN" "$n" "$C_RESET" "$h" "$p"
    done < <(list_servers)
    local add=$((n+1))
    printf '  %s%d%s) %s+ Add new server%s\n' "$C_YELLOW" "$add" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select server" "1"; local sel="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return; }
    if [[ "$sel" == "$add" ]]; then add_server || true; connect_tunnel; return; fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > n )); then err "Invalid selection."; return; fi

    local slug host user port params
    IFS='|' read -r slug host user port params <<< "${srv[sel-1]}"

    info "Reading the tunnel registry on $host ..."
    local remote; remote="$(list_remote_tunnels "$host" "$user" "$port")"
    if [[ -z "$remote" ]]; then
        warn "No tunnels registered on $host."
        return
    fi

    printf '\n%sTunnels on %s:%s\n' "$C_BOLD" "$host" "$C_RESET"
    local -a t=(); local tn=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        t+=("$line"); tn=$((tn+1))
        local tid tsport tlabel
        IFS='|' read -r tid _ _ tsport tlabel <<< "$line"
        printf '  %s%d%s) %s  %s→ :%s%s\n' "$C_GREEN" "$tn" "$C_RESET" "$tlabel" "$C_DIM" "$tsport" "$C_RESET"
    done <<< "$remote"

    ask "Select tunnel" "1"; local tsel="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return; }
    if ! [[ "$tsel" =~ ^[0-9]+$ ]] || (( tsel < 1 || tsel > tn )); then err "Invalid selection."; return; fi

    local tid thost tuser tport tlabel
    IFS='|' read -r tid thost tuser tport tlabel <<< "${t[tsel-1]}"
    open_tunnel "$thost" "$tuser" "$tport" "$tport" "$tlabel"
}

open_tunnel() {
    local host="$1" user="$2" rport="$3" lport="$4" label="${5:-tunnel}"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${lport}\$"; then
        ok "Port $lport already bound — tunnel is live."
        return 0
    fi
    info "Opening $label ($TRANSPORT): localhost:$lport → $host:$rport"
    nohup "$TRANSPORT" -N -f \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -L "${lport}:127.0.0.1:${rport}" "$user@$host" >/dev/null 2>&1 < /dev/null &
    sleep 1
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${lport}\$"; then
        ok "Tunnel established — localhost:$lport → $host:$rport"
    else
        warn "Tunnel did not bind $lport — is $host:$rport reachable?"
    fi
}

list_cmd() {
    printf '\n%s── Tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local c; c="$(list_servers | grep -c .)"
    if [[ "$c" == "0" ]]; then info "Nothing registered."; return; fi
    printf '  %-26s %-20s %s\n' "TUNNEL" "TARGET" "STATUS"
    local line slug host user port params status
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host user port params <<< "$line"
        status="stopped"
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && status="running"
        printf '  %-26s %-20s %s\n' "$slug" "${host}:${port}" "$status"
    done <<< "$(list_servers)"
}

stop_cmd() {
    printf '\n%s── Stop Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    local found=0 line slug host user port params
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host user port params <<< "$line"
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            pkill -f "ssh.*-L ${port}:127.0.0.1" 2>/dev/null || true
            ok "Stopped $host:$port"; found=1
        fi
    done < <(list_servers)
    (( found == 0 )) && warn "No running tunnels to stop."
}

main_menu() {
    while true; do
        print_banner
        printf '  %s1%s) Connect Tunnel\n' "$C_GREEN" "$C_RESET"
        printf '  %s2%s) List tunnels\n'  "$C_GREEN" "$C_RESET"
        printf '  %s3%s) Stop a tunnel\n' "$C_YELLOW" "$C_RESET"
        printf '  %s0%s) Exit\n\n'       "$C_RED" "$C_RESET"
        ask "Choose an option" "1"
        [[ "$EOF_REACHED" == "1" ]] && { info "End of input — exiting."; exit 0; }
        case "$REPLY" in
            1) connect_tunnel ;;
            2) list_cmd ;;
            3) stop_cmd ;;
            0) info "Bye."; exit 0 ;;
            *) err "Unknown option." ;;
        esac
    done
}

init_state
main_menu
