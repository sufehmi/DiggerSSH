#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.4.1 — SSH Tunnel Manager
#
#  Main menu
#    1) Create Tunnel to Server
#    2) Connect Tunnel (to a server's Port)
#    3) List tunnels
#    4) Stop a tunnel
#    0) Exit
#
#  Process ownership
#  ------------------
#  autossh forks a child ssh, and with -f the supervisor exits at once, so a
#  PID captured from $! is either the wrong process or already dead. Instead
#  of trusting a recorded PID, the tunnel's owner is discovered from the
#  kernel: ss -ltnp names the PID holding the listening socket. That is the
#  single source of truth for both status and stopping, so the three views
#  can never disagree.
#
#  Address families
#  ----------------
#  A port can be free on one loopback family and taken on the other. "Is
#  port N in use" is therefore answered per family, and a tunnel is bound
#  when ssh holds it on EITHER family. Refusing to start because the IPv4
#  side is occupied by an unrelated process would block a tunnel that can
#  perfectly well bind [::1].
#
#  State layout
#    ~/.diggerssh/config                 defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/tunnels/<id>.tunnel    the tunnel record
#    ~/.diggerssh/tunnels/<id>.log       the tunnel's output
#
#  The -L target host is fixed at 127.0.0.1: the tunnel terminates on the
#  server, so its destination is whatever listens on that server's loopback.
# ============================================================================

set -o pipefail
VERSION="1.4.1"

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

# ============================================================ ownership =======
# PIDs holding a listening socket on $1, per address. ss prints the local
# address in column 4, e.g. "127.0.0.1:44641" or "[::1]:44641".
socket_owner_pids() {
    local port="$1"
    ss -ltnp 2>/dev/null \
      | awk -v p="$port" '$4 ~ (":" p "$")' \
      | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# The PID of the ssh/autossh process holding this port, if any. Other
# processes (an unrelated daemon, say) do not count: they are not tunnels.
tunnel_pid() {
    local port="$1" pid comm
    for pid in $(socket_owner_pids "$port"); do
        [[ -n "$pid" && -r "/proc/$pid/comm" ]] || continue
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        case "$comm" in
            ssh|autossh) printf '%s' "$pid"; return 0 ;;
        esac
    done
    return 1
}

# The address family a listener on $1 uses: "ipv4", "ipv6", or "" if free.
# A port may be free on one family and busy on the other, so this is asked
# per family rather than as a single "is it in use" question.
family_in_use() {
    local port="$1" family="$2" addr
    case "$family" in
        ipv4) addr="127.0.0.1:${port}" ;;
        ipv6) addr="[::1]:${port}" ;;
        *) return 1 ;;
    esac
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qxF "$addr"
}

# True when the port is taken on both loopback families.
port_fully_taken() {
    family_in_use "$1" ipv4 && family_in_use "$1" ipv6
}

status_text() {
    local port="$1"
    if tunnel_pid "$port" >/dev/null 2>&1; then
        printf '%srunning%s' "$C_GREEN" "$C_RESET"
    else
        printf '%sstopped%s' "$C_YELLOW" "$C_RESET"
    fi
}

# ============================================================ records ========
slug_of() { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

list_records() {
    local f
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        local slug host user sport dport
        slug="$(basename "$f" .tunnel)"
        host="$(grep -m1 '^HOST='          "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='   "$f" | cut -d'=' -f2-)"
        printf '%s|%s|%s|%s|%s\n' "$slug" "$host" "$user" "$sport" "$dport"
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
    local title="$1" mode="$2"     # mode: open | stop
    local out; out="$(list_records)"
    local total; total="$(printf '%s\n' "$out" | grep -c . || true)"

    printf '\n%s── %s ──%s\n' "$C_BOLD" "$title" "$C_RESET"
    local n=0 line slug host user sport dport
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport <<< "$line"
        printf '  %s%2d%s) %s:%s → %s:%s  %s\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$(status_text "$sport")"
    done <<< "$out"

    local add=$((n + 1))
    printf '  %s%2d%s) %s+ Add new server%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s%2d%s) %sExit to main menu%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select" "1"
    [[ "$EOF_REACHED" == "1" ]] && return 0
    if [[ "$REPLY" == "0" ]]; then return 0; fi
    if [[ "$REPLY" == "$add" ]]; then provisioning_form; return 0; fi
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= total )); then
        local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
        local rslug rhost ruser rsport rdport
        IFS='|' read -r rslug rhost ruser rsport rdport <<< "$rec"
        if [[ "$mode" == "stop" ]]; then
            stop_tunnel "$rslug" "$rhost" "$rsport" "$rdport"
        else
            open_tunnel "$rslug" "$rhost" "$ruser" "$rsport" "$rdport"
        fi
        return 0
    fi
    err "Invalid selection."
    return 0
}

# ============================================================ actions =========
open_tunnel() {
    local slug="$1" host="$2" user="$3" sport="$4" dport="$5"
    local params; params="$(grep -m1 '^SSH_PARAMS=' "$TUNNEL_DIR/$slug.tunnel" 2>/dev/null | cut -d'=' -f2-)"

    # Already up? Say so, and report the process that holds it.
    local pid
    if pid="$(tunnel_pid "$sport")"; then
        ok "Tunnel $slug is already running (pid $pid)."
        return 0
    fi

    # Blocked only when BOTH loopback families are taken. One free family is
    # enough for ssh to bind.
    if port_fully_taken "$sport"; then
        local other; other="$(socket_owner_pids "$sport" | head -1)"
        warn "Port $sport is held on both IPv4 and IPv6 by another process (pid ${other:-unknown})."
        return 1
    fi
    # ssh binds BOTH loopback families for -L and aborts if either fails, so
    # bind the free family explicitly.
    local bindaddr
    if family_in_use "$sport" ipv4; then
        bindaddr="[::1]"
        warn "127.0.0.1:$sport is held by another process — binding [::1]:$sport instead."
    elif family_in_use "$sport" ipv6; then
        bindaddr="127.0.0.1"
        warn "[::1]:$sport is held by another process — binding 127.0.0.1:$sport instead."
    else
        bindaddr=""     # both free — let ssh pick
    fi

    # shellcheck disable=SC2086
    nohup "$TRANSPORT" -N $params \
        -o StrictHostKeyChecking=accept-new \
        -L "${bindaddr:+$bindaddr:}${sport}:${TARGET_HOST}:${dport}" "$user@$host" \
        > "$TUNNEL_DIR/$slug.log" 2>&1 < /dev/null &
    sleep 2

    if pid="$(tunnel_pid "$sport")"; then
        ok "Tunnel started (pid $pid) — localhost:$sport → $TARGET_HOST:$dport"
    else
        err "Tunnel did not come up. Log:"
        [[ -f "$TUNNEL_DIR/$slug.log" ]] && sed 's/^/    /' "$TUNNEL_DIR/$slug.log"
        return 1
    fi
}

stop_tunnel() {
    local slug="$1" host="$2" sport="$3" dport="$4"
    local pid
    if ! pid="$(tunnel_pid "$sport")"; then
        warn "Tunnel $slug is not running."
        return 0
    fi
    # autossh supervises an ssh child; kill the supervisor first so it does
    # not resurrect the child, then the child itself.
    local parent; parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    kill "$pid" 2>/dev/null || true
    if [[ -n "$parent" && "$parent" != "1" ]]; then
        local pcomm; pcomm="$(cat "/proc/$parent/comm" 2>/dev/null)"
        [[ "$pcomm" == "autossh" ]] && { kill "$parent" 2>/dev/null || true; }
    fi
    sleep 1
    # Anything still holding the port for this tunnel.
    local p
    for p in $(socket_owner_pids "$sport"); do
        [[ "$p" == "$pid" ]] && continue
        local c; c="$(cat "/proc/$p/comm" 2>/dev/null)"
        case "$c" in ssh|autossh) kill "$p" 2>/dev/null || true ;; esac
    done
    sleep 1
    if tunnel_pid "$sport" >/dev/null 2>&1; then
        warn "Port $sport is still held — the tunnel may need a moment to release it."
    else
        ok "Tunnel $slug stopped."
    fi
}

do_create()  { submenu "Create Tunnel to Server" open; }
do_connect() { submenu "Connect Tunnel (to a server's Port)" open; }
do_stop()    { submenu "Stop a tunnel" stop; }

do_list() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_records)"
    if [[ -z "$out" ]]; then info "No tunnels registered."; return 0; fi
    printf '  %-4s %-16s %-10s %-10s %s\n' "#" "HOST" "SOURCE" "DEST" "STATUS"
    printf '  %-4s %-16s %-10s %-10s %s\n' "---" "----" "------" "----" "------"
    local n=0 line slug host user sport dport
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport <<< "$line"
        printf '  %-4s %-16s %-10s %-10s %s\n' "$n" "$host" "$sport" "$dport" "$(status_text "$sport")"
    done <<< "$out"
    return 0
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

    for p in "$sport" "$dport"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then err "Invalid port: $p"; return 1; fi
    done
    [[ -n "$host" ]] || { err "Host is required."; return 1; }

    printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
    printf '  ssh -p %s %s -L %s:%s:%s %s@%s\n' "$sshport" "$params" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    ask "Save? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$sshport"
    cfg_set LAST_SOURCE_PORT "$sport"
    cfg_set LAST_DEST_PORT "$dport"
    save_record "$host" "$user" "$sport" "$dport" "$params"
    local slug; slug="$(slug_of "$host" "$sport")"
    open_tunnel "$slug" "$host" "$user" "$sport" "$dport"
}

# ------------------------------------------------------------------ menu ----
main_menu() {
    while true; do
        printf '\n'
        print_banner_body
        ask "Choose an option" "1"
        [[ "$EOF_REACHED" == "1" ]] && { info "End of input — exiting."; exit 0; }
        case "$REPLY" in
            1) do_create ;;
            2) do_connect ;;
            3) do_list ;;
            4) do_stop ;;
            0) info "Bye."; exit 0 ;;
            *) err "Unknown option." ;;
        esac
    done
}

print_banner_body() {
    printf '%s%s    ____  _                       __________ __  __%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s   / __ \\(_)___ _____ ____  _____/ ___/ ___// / / /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s  / / / / / __ `/ __ `/ _ \\/ ___/\\__ \\__ \\/ /_/ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s / /_/ / / /_/ / /_/ /  __/ /   ___/ /__/ / __ /%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s/_____/_/\\__, /\\__, /\\___/_/   /____/____/_/ /_/%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s        /____//____/%s\n' "$C_CYAN" "$C_RESET"
    printf '%s   v%s  SSH tunnel manager%s\n' "$C_CYAN" "$VERSION" "$C_RESET"
    printf '\n'
    printf '  %s1%s) Create Tunnel to Server\n'              "$C_GREEN" "$C_RESET"
    printf '  %s2%s) Connect Tunnel (to a server'"'"'s Port)\n' "$C_GREEN" "$C_RESET"
    printf '  %s3%s) List tunnels\n'                       "$C_GREEN" "$C_RESET"
    printf '  %s4%s) Stop a tunnel\n'                     "$C_YELLOW" "$C_RESET"
    printf '  %s0%s) Exit\n\n'                            "$C_RED"   "$C_RESET"
}

init_state() {
    mkdir -p "$DIGGERSH_HOME" "$TUNNEL_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
}

init_state
main_menu
