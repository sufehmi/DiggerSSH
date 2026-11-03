#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.3.0 — SSH Tunnel Manager
#
#  Menu:
#    1) Create Tunnel   — collect connection details, open the tunnel, and
#                         register it on the server
#    2) Connect Tunnel  — two-tier: pick a SERVER, then pick a tunnel registered
#                         on that server, then connect
#    3) List tunnels
#    4) Stop a tunnel
#
#  State layout:
#    ~/.diggerssh/config              global defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/servers/*.conf      tier 1 — servers we know how to reach
#    ~/.diggerssh/tunnels/*.conf      local tunnel records
#    <server>:~/.diggerssh/*.tunnel   tier 2 — registry the server keeps itself
#
#  Uses autossh when installed, plain ssh otherwise. A bundled post-quantum
#  build in ./oqs-bin/ is preferred when present.
# ============================================================================

set -o pipefail

VERSION="1.3.0"

# ----------------------------------------------------------------- colours --
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''
fi

# -------------------------------------------------------------- state paths -
DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
SERVER_DIR="$DIGGERSH_HOME/servers"
TUNNEL_DIR="$DIGGERSH_HOME/tunnels"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
REMOTE_REGISTRY_DIR=".diggerssh"

# Defaults for the Create-Tunnel form.
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_PARAMS="-o ServerAliveInterval=30 -o ServerAliveCountMax=5"

# ------------------------------------------------------------------ output --
info() { printf '%s…%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Prompt to stderr, read the answer from stdin.
EOF_REACHED=0
ask() {
    local prompt="$1" default="${2:-}" answer=""
    printf '%s%s%s : ' "$C_DIM" "$prompt" "$C_RESET" >&2
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
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# Prefer a bundled post-quantum build sitting next to this script.
OQS_BIN_DIR=""
if [[ -z "${DIGGERSH_NO_OQS:-}" ]]; then
    _self_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -n "$_self_dir" && -x "$_self_dir/oqs-bin/ssh" ]]; then
        OQS_BIN_DIR="$_self_dir/oqs-bin"
        PATH="$OQS_BIN_DIR:$PATH"
        export PATH
    fi
    unset _self_dir
fi
SSH_BIN="$(command -v ssh 2>/dev/null || echo ssh)"
if command -v autossh >/dev/null 2>&1; then TRANSPORT="autossh"; else TRANSPORT="ssh"; fi

# ----------------------------------------------------------------- banner ---
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
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# ============================================================ tier 1: servers
server_slug() { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

list_servers() {
    local f host user port params
    for f in "$SERVER_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        host="$(grep -m1 '^HOST=' "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER=' "$f" | cut -d'=' -f2-)"
        port="$(grep -m1 '^SSH_PORT=' "$f" | cut -d'=' -f2-)"
        params="$(grep -m1 '^SSH_PARAMS=' "$f" | cut -d'=' -f2-)"
        printf '%s|%s|%s|%s|%s\n' "$(basename "$f" .conf)" "$host" "$user" "$port" "$params"
    done | sort
}

# Reads the registry the server keeps for itself. Double-quoted remote command
# so local vars expand here while \$f stays remote; </dev/null stops the child
# from eating this script's queued answers.
list_remote_tunnels() {
    local host="$1" user="$2" port="$3"
    [[ -z "$port" ]] && port="22"
    timeout 20 "$SSH_BIN" -p "$port" \
        -o BatchMode=yes -o ConnectTimeout=8 \
        "$user@$host" \
        "for f in ~/$REMOTE_REGISTRY_DIR/*.tunnel; do [ -e \"\$f\" ] || continue; echo '@@FILE@@'; cat \"\$f\"; done" \
        2>/dev/null </dev/null | awk -F= '
            function flush() {
                if (id != "") printf "%s|%s|%s|%s|%s|%s\n", id, host, user, sport, dport, label
            }
            /^@@FILE@@$/ { flush(); next }
            {
                line = $0; sub(/=.*$/, "", line)
                val  = $0; sub(/^[^=]*=/, "", val); gsub(/\r/, "", val)
                if      (line == "ID")           id = val
                else if (line == "HOST")        host = val
                else if (line == "USER")         user = val
                else if (line == "SOURCE_PORT") sport = val
                else if (line == "DEST_PORT")   dport = val
                else if (line == "SSH_PORT")   sshp = val
                else if (line == "KEY_LABEL")  label = val
                else if (line == "SSH_PARAMS") params = val
            }
            END { flush() }'
}

# ============================================================ MENU 1: create ==
create_tunnel() {
    printf '\n%s── Create Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    info "Transport: $TRANSPORT"

    printf '\n%sStep 1 — Connection details%s\n' "$C_BOLD" "$C_RESET"
    local last_host last_user
    last_host="$(cfg_get LAST_HOST "")"
    last_user="$(cfg_get LAST_USER "$(id -un 2>/dev/null || echo root)")"

    ask "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    ask "SSH Username" "$last_user"; local user="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    ask "SSH Port" "$DEFAULT_SSH_PORT"; local port="$REPLY"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"

    if [[ -z "$host" || -z "$user" ]]; then err "Host and username are required."; return 1; fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "Invalid SSH port: $port"; return 1
    fi

    printf '\n%sStep 2 — Target service%s\n' "$C_BOLD" "$C_RESET"
    ask "Destination host (as seen from the server)" "127.0.0.1"; local dhost="$REPLY"
    ask "Destination port" "$port"; local dport="$REPLY"

    printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
    printf '  Tunnel     : localhost:%s → %s:%s\n' "$port" "$dhost" "$dport"
    printf '  SSH params : %s\n' "$params"
    printf '  Transport  : %s\n' "$TRANSPORT"
    ask "Create? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && { echo; return 1; }
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$port"
    cfg_set LAST_DPORT "$dport"
    write_server_entry "$host" "$user" "$port" "$params"
    write_tunnel_record "$host" "$user" "$port" "$dport" "$params"
    ok "Tunnel saved."
    start_tunnel "$host" "$user" "$port" "$dport" "$params" || return 1
    return 0
}

write_server_entry() {
    local file="$SERVER_DIR/$(server_slug "$1" "$3").conf"
    {
        printf 'HOST=%s\n'       "$1"
        printf 'USER=%s\n'       "$2"
        printf 'SSH_PORT=%s\n'   "$3"
        printf 'SSH_PARAMS=%s\n' "$4"
        printf 'CREATED=%q\n'    "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$file"
    chmod 600 "$file" 2>/dev/null || true
}

write_tunnel_record() {
    local id; id="$(server_slug "$1" "$3")"
    local file="$TUNNEL_DIR/$id.conf"
    {
        printf 'ID=%s\n'           "$id"
        printf 'HOST=%s\n'         "$1"
        printf 'USER=%s\n'         "$2"
        printf 'SOURCE_PORT=%s\n'  "$3"
        printf 'DEST_PORT=%s\n'    "$4"
        printf 'SSH_PORT=%s\n'     "$3"
        printf 'SSH_PARAMS=%q\n'   "$5"
        printf 'CREATED=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$file"
    chmod 600 "$file" 2>/dev/null || true
}

# ============================================================ MENU 2: connect ==
connect_tunnel() {
    printf '\n%s── Connect Tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    if [[ -z "$(list_servers)" ]]; then
        warn "No tunnels registered yet — use 'Create Tunnel' first."
        return 0
    fi
    local line slug host user port params
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host user port params <<< "$line"
        local state="${C_YELLOW}stopped${C_RESET}"
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && state="${C_GREEN}running${C_RESET}"
        printf '  %s%s%s  %s:%s  [%s%s%s]\n' "$C_BOLD" "$slug" "$C_RESET" "$host" "$port" "$state" "$state" "$C_RESET"
    done < <(list_servers)
    return 0
}

# Bind locally on the same port the tunnel uses on the server.
start_tunnel() {
    local host="$1" user="$2" port="$3" dport="$4" params="$5"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
        ok "Port $port is already bound — tunnel is live."
        return 0
    fi
    # shellcheck disable=SC2086
    info "Opening $TRANSPORT tunnel: localhost:$port → $host:$dport"
    nohup "$TRANSPORT" -N -f \
        -o StrictHostKeyChecking=accept-new \
        ${params} \
        -L "${port}:127.0.0.1:${dport}" "$user@$host" >/dev/null 2>&1 < /dev/null &
    sleep 1
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
        ok "Tunnel established — localhost:$port → $host:$dport"
    else
        warn "Tunnel did not bind $port — is $host:$dport reachable?"
    fi
}

list_cmd() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_servers)"
    if [[ -z "$out" ]]; then info "Nothing registered."; return 0; fi
    printf '  %-26s %-18s %s\n' "TUNNEL" "TARGET" "STATUS"
    printf '  %-26s %-18s %s\n' "------" "------" "------"
    local line slug host user port params state
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host user port params <<< "$line"
        state="${C_YELLOW}stopped${C_RESET}"
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && state="${C_GREEN}running${C_RESET}"
        printf '  %-26s %-18s %s%s%s\n' "$slug" "${host}:${port}" "$state" "$(echo "$state" | sed 's/\x1b//g')" "$C_RESET"
    done <<< "$out"
    printf '\n'
}

stop_cmd() {
    printf '\n%s── Stop a tunnel ──%s\n' "$C_BOLD" "$C_CYAN"
    local found=0 line slug host port params
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug host _ port _ <<< "$line"
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            pkill -f "ssh.*-L ${port}:127.0.0.1" 2>/dev/null || true
            ok "Stopped $host:$port"
            found=1
        fi
    done < <(list_servers)
    (( found == 0 )) && warn "No running tunnels to stop."
}

# ------------------------------------------------------------------ menu ----
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
