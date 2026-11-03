#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.6.0 — SSH Tunnel Manager
#
#  Forwarding direction
#  --------------------
#  The two tunnel menus use different directions:
#
#    1) Create Tunnel to Server        →  -R  (remote forward)
#         The SERVER listens on the port. Traffic arriving there is carried
#         down the SSH connection and delivered to 127.0.0.1:<dest> here.
#
#    2) Connect Tunnel (to a server's Port)  →  -L  (local forward)
#         THIS machine listens on the port and forwards into the server's
#         port. The local port matches the port the tunnel uses on the
#         server, so both ends use the same number.
#
#  Key exchange fallback
#  ---------------------
#  Some ssh builds (notably OQS-OpenSSH) print
#
#      ** WARNING: connection is not using a post-quantum key exchange algorithm.
#
#  whenever the negotiated KEX is not post-quantum. That warning is noise on
#  a server that offers no PQ key exchange at all, and it must not be
#  mistaken for a failure. DiggerSSH therefore negotiates the KEX explicitly
#  against the server's advertised list, walking a chain from the strongest
#  post-quantum option down to ECDH:
#
#      level 0  mlkem768x25519-sha256                (post-quantum)
#      level 1  sntrup761x25519-sha512@openssh.com   (post-quantum hybrid)
#      level 2  curve25519-sha256                   (classical)
#      level 3  ecdh-sha2-nistp256                   (classical, ECDH)
#
#  The highest level the server actually accepts is used and recorded. The
#  same chain is applied to the host key and public key algorithms, so the
#  whole connection degrades together instead of failing at one layer.
#
#  Main menu
#    1) Create Tunnel to Server
#    2) Connect Tunnel (to a server's Port)
#    3) List tunnels
#    4) Stop a tunnel
#    0) Exit
#
#  Ownership
#  ---------
#  Because a -R tunnel's listener is on the server, the local socket table
#  says nothing about whether a tunnel is up. Ownership is determined by the
#  local ssh process that carries the forward argument: that process IS the
#  tunnel. It is found by matching the -R argument in /proc, never by a broad
#  pkill -f, which can match this script's own shell.
#
#  State layout
#    ~/.diggerssh/config                 defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/tunnels/<id>.tunnel    the tunnel record
#    ~/.diggerssh/tunnels/<id>.log       the tunnel's output
#
#  The forward target host is fixed at 127.0.0.1 on the far side.
# ============================================================================

set -o pipefail
VERSION="1.6.0"

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

# Prefer a bundled post-quantum build beside the script.
if [[ -z "${DIGGERSH_NO_OQS:-}" ]]; then
    _d="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -n "$_d" && -x "$_d/oqs-bin/ssh" ]]; then PATH="$_d/oqs-bin:$PATH"; export PATH; fi
    unset _d
fi
SSH_BIN="$(command -v ssh 2>/dev/null || echo ssh)"
command -v autossh >/dev/null 2>&1 && TRANSPORT="autossh" || TRANSPORT="ssh"

# ============================================================ forwarding =====
# The forward spec as it appears in an ssh command line. The bind address is
# optional: ssh accepts "-L port:host:port" and "-L [::1]:port:host:port" as
# equivalent, and the second form is used when one loopback family is
# already taken. A matcher that only knows the first form would report a
# running tunnel as stopped, and a later start would then collide with it.
forward_spec() {
    local dir="$1" sport="$2" dport="$3"
    printf -- '-%s %s:%s:%s' "$dir" "$sport" "$TARGET_HOST" "$dport"
}

# The set of specs that identify a tunnel in an ssh command line: the plain
# form and the bind-address forms.
forward_specs() {
    local dir="$1" sport="$2" dport="$3"
    printf -- '-%s %s:%s:%s\n' "$dir" "$sport" "$TARGET_HOST" "$dport"
    printf -- '-%s 127.0.0.1:%s:%s:%s\n' "$dir" "$sport" "$TARGET_HOST" "$dport"
    printf -- '-%s [::1]:%s:%s:%s\n' "$dir" "$sport" "$TARGET_HOST" "$dport"
    printf -- '-%s [::]:%s:%s:%s\n' "$dir" "$sport" "$TARGET_HOST" "$dport"
    printf -- '-%s 0.0.0.0:%s:%s:%s\n' "$dir" "$sport" "$TARGET_HOST" "$dport"
}

tunnel_pid() {
    local sport="$1" dport="$2" dir="${3:-}"
    local -a specs=()
    if [[ -n "$dir" ]]; then
        mapfile -t specs < <(forward_specs "$dir" "$sport" "$dport")
    else
        mapfile -t specs < <(forward_specs L "$sport" "$dport"; forward_specs R "$sport" "$dport")
    fi
    local pid cmd spec
    for pid in $(pgrep -x ssh 2>/dev/null; pgrep -x autossh 2>/dev/null); do
        [[ "$pid" == "$$" ]] && continue
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        for spec in "${specs[@]}"; do
            [[ "$cmd" == *"$spec"* ]] && { printf '%s' "$pid"; return 0; }
        done
    done
    return 1
}

tunnel_dir() {
    local sport="$1" dport="$2" dir
    for dir in L R; do
        if tunnel_pid "$sport" "$dport" "$dir" >/dev/null 2>&1; then printf '%s' "$dir"; return 0; fi
    done
    return 1
}

status_text() {
    local sport="$1" dport="$2" dir
    if dir="$(tunnel_dir "$sport" "$dport")"; then
        printf '%srunning%s%s' "$C_GREEN" "$C_RESET" "$C_DIM(-$dir)$C_RESET"
    else
        printf '%sstopped%s' "$C_YELLOW" "$C_RESET"
    fi
}

# ============================================================ kex negotiation =
# The chain, strongest first. "PQ" marks a post-quantum key exchange.
KEX_CHAIN=(
    "0|mlkem768x25519-sha256|PQ"
    "1|sntrup761x25519-sha512@openssh.com|PQ"
    "1|sntrup761x25519-sha512|PQ"
    "2|curve25519-sha256|classical"
    "3|ecdh-sha2-nistp256|classical"
)

# The host key / public key chain, strongest first.
HOSTKEY_CHAIN=(
    "0|ssh-mldsa-65|PQ"
    "1|ssh-mldsa44-ed25519@openssh.com|PQ"
    "2|ssh-ed25519|classical"
    "3|ecdsa-sha2-nistp256|classical"
)

# The algorithms this client build actually supports.
client_supports() {
    local kind="$1" algo="$2"
    local query
    case "$kind" in
        kex)     query="kex" ;;
        key)     query="key" ;;
        hostkey) query="key" ;;
        pubkey)  query="PubkeyAcceptedAlgorithms" ;;
        *)       return 1 ;;
    esac
    "$SSH_BIN" -Q "$query" 2>/dev/null | grep -qxF "$algo"
}

# The algorithms the server advertises. The KEXINIT exchange prints the
# server's kex list and its accepted public-key algorithms before any
# authentication happens, so this works on a first, keyless run.
server_supports() {
    local host="$1" user="$2" port="$3" kind="$4"
    local out
    out="$(timeout 20 "$SSH_BIN" -v -p "$port" \
            -o BatchMode=yes -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=accept-new \
            "$user@$host" true 2>&1 </dev/null)"
    case "$kind" in
        kex)
            # "debug1: kex_algorithms: a,b,c" lists the server's proposal.
            printf '%s\n' "$out" | sed -n 's/.*kex_algorithms: //p' | head -1 \
                | tr ',' '\n' | sed 's/^ *//; s/ *$//' ;;
        hostkey)
            # "debug1: kex: host key algorithm: X" is the negotiated one; the
            # server's full proposal is not printed by every ssh version, so
            # the accepted host keys are read from the same place the
            # accepted public keys are.
            printf '%s\n' "$out" | sed -n 's/.*server-sig-algs=<\([^>]*\)>.*/\1/p' | head -1 \
                | tr ',' '\n' | sed 's/^ *//; s/ *$//' ;;
        pubkey)
            printf '%s\n' "$out" | sed -n 's/.*server-sig-algs=<\([^>]*\)>.*/\1/p' | head -1 \
                | tr ',' '\n' | sed 's/^ *//; s/ *$//' ;;
    esac
}

# Does the server accept this specific KEX? Some ssh versions print only the
# negotiated algorithm rather than the server's full proposal, so the only
# reliable test is to try it.
server_accepts_kex() {
    local host="$1" user="$2" port="$3" algo="$4"
    local out
    out="$(timeout 20 "$SSH_BIN" -p "$port" \
            -o BatchMode=yes -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=accept-new \
            -o "KexAlgorithms=${algo}" \
            "$user@$host" true 2>&1 </dev/null)"
    case "$out" in
        *"no matching key exchange method"*|*"Unable to negotiate"*|*"no match"*) return 1 ;;
    esac
    return 0
}

# Choose the strongest chain entry the CLIENT supports and the SERVER accepts.
# Prints "level|algo|tag" or nothing if the server advertised nothing usable.
pick_algorithm() {
    local host="$1" user="$2" port="$3" kind="$4" chain_name="$5"
    local -a chain=()
    case "$chain_name" in
        kex)     chain=("${KEX_CHAIN[@]}") ;;
        hostkey) chain=("${HOSTKEY_CHAIN[@]}") ;;
        pubkey)  chain=("${HOSTKEY_CHAIN[@]}") ;;
    esac
    local entry level algo tag
    for entry in "${chain[@]}"; do
        IFS='|' read -r level algo tag <<< "$entry"
        client_supports "$kind" "$algo" || continue
        if [[ "$kind" == "kex" ]]; then
            server_accepts_kex "$host" "$user" "$port" "$algo" || continue
        else
            local server_list; server_list="$(server_supports "$host" "$user" "$port" "$kind")"
            [[ -n "$server_list" ]] || continue
            printf '%s\n' "$server_list" | grep -qxF "$algo" || continue
        fi
        printf '%s|%s|%s' "$level" "$algo" "$tag"
        return 0
    done
    return 1
}

# The ssh options that pin the negotiated algorithms, so a later connection
# uses exactly what was probed and cannot drift. One "Name=Value" per line.
algo_opts() {
    local host="$1" user="$2" port="$3"
    local pick algo
    if pick="$(pick_algorithm "$host" "$user" "$port" kex kex)"; then
        algo="${pick#*|}"; algo="${algo%%|*}"
        printf 'KexAlgorithms=%s\n' "$algo"
    fi
    if pick="$(pick_algorithm "$host" "$user" "$port" hostkey hostkey)"; then
        algo="${pick#*|}"; algo="${algo%%|*}"
        printf 'HostKeyAlgorithms=%s\n' "$algo"
    fi
    if pick="$(pick_algorithm "$host" "$user" "$port" pubkey pubkey)"; then
        algo="${pick#*|}"; algo="${algo%%|*}"
        printf 'PubkeyAcceptedAlgorithms=%s\n' "$algo"
    fi
}

# ============================================================ records ========
slug_of() { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

list_records() {
    local f
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        local slug host user sport dport sshport
        slug="$(basename "$f" .tunnel)"
        host="$(grep -m1 '^HOST='          "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='   "$f" | cut -d'=' -f2-)"
        sshport="$(grep -m1 '^SSH_PORT='   "$f" | cut -d'=' -f2-)"
        [[ -n "$sshport" ]] || sshport="22"
        printf '%s|%s|%s|%s|%s|%s\n' "$slug" "$host" "$user" "$sport" "$dport" "$sshport"
    done | sort
}

save_record() {
    local host="$1" user="$2" sport="$3" dport="$4" params="$5" sshport="$6"
    local slug; slug="$(slug_of "$host" "$sport")"
    {
        printf 'ID=%s\n'           "$slug"
        printf 'HOST=%s\n'         "$host"
        printf 'USER=%s\n'         "$user"
        printf 'SOURCE_PORT=%s\n'  "$sport"
        printf 'DEST_PORT=%s\n'    "$dport"
        printf 'SSH_PORT=%s\n'     "$6"
        printf 'SSH_PARAMS=%s\n'   "$params"
        printf 'CREATED=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TUNNEL_DIR/$slug.tunnel"
    chmod 600 "$TUNNEL_DIR/$slug.tunnel" 2>/dev/null || true
}

# ============================================================ submenu ========
submenu() {
    local title="$1" mode="$2"
    local out; out="$(list_records)"
    local total; total="$(printf '%s\n' "$out" | grep -c . || true)"

    printf '\n%s── %s ──%s\n' "$C_BOLD" "$title" "$C_RESET"
    local n=0 line slug host user sport dport
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport _ <<< "$line"
        printf '  %s%2d%s) %s:%s → %s:%s  %s\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$(status_text "$sport" "$dport")"
    done <<< "$out"

    local add=$((n + 1))
    printf '  %s%2d%s) %s+ Add new server%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s%2d%s) %sExit to main menu%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select" "1"
    [[ "$EOF_REACHED" == "1" ]] && return 0
    if [[ "$REPLY" == "0" ]]; then return 0; fi
    if [[ "$REPLY" == "$add" ]]; then
        case "$mode" in
            open-R) provisioning_form R ;;
            open-L) provisioning_form L ;;
            *)      provisioning_form R ;;
        esac
        return 0
    fi
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= total )); then
        local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
        local rslug rhost ruser rsport rdport
        local rslug rhost ruser rsport rdport rsshport
        IFS='|' read -r rslug rhost ruser rsport rdport rsshport <<< "$rec"
        case "$mode" in
            stop)   stop_tunnel "$rslug" "$rhost" "$rsport" "$rdport" ;;
            open-R) open_tunnel "$rslug" "$rhost" "$ruser" "$rsport" "$rdport" R "$rsshport" ;;
            open-L) open_tunnel "$rslug" "$rhost" "$ruser" "$rsport" "$rdport" L "$rsshport" ;;
        esac
        return 0
    fi
    err "Invalid selection."
    return 0
}

# ============================================================ actions =========
open_tunnel() {
    local slug="$1" host="$2" user="$3" sport="$4" dport="$5" dir="$6" sshport="$7"
    local params; params="$(grep -m1 '^SSH_PARAMS=' "$TUNNEL_DIR/$slug.tunnel" 2>/dev/null | cut -d'=' -f2-)"

    local pid
    if pid="$(tunnel_pid "$sport" "$dport" "$dir")"; then
        ok "Tunnel $slug is already running (pid $pid, -$dir)."
        return 0
    fi

    # Negotiate the algorithms against this server, once, and reuse them.
    local -a algo_lines=()
    mapfile -t algo_lines < <(algo_opts "$host" "$user" "$sshport")
    local -a algos=()
    local a kexalgo=""
    for a in "${algo_lines[@]}"; do
        [[ -n "$a" ]] || continue
        algos+=(-o "$a")
        case "$a" in KexAlgorithms=*) kexalgo="${a#KexAlgorithms=}" ;; esac
    done

    local bindaddr=""
    if [[ "$dir" == "L" ]]; then
        if family_in_use "$sport" ipv4 && family_in_use "$sport" ipv6; then
            local other; other="$(socket_owner_pids "$sport" | head -1)"
            warn "Port $sport is held on both IPv4 and IPv6 by another process (pid ${other:-unknown})."
            return 1
        elif family_in_use "$sport" ipv4; then
            bindaddr="[::1]"
            warn "127.0.0.1:$sport is held by another process — binding [::1]:$sport instead."
        elif family_in_use "$sport" ipv6; then
            bindaddr="127.0.0.1"
            warn "[::1]:$sport is held by another process — binding 127.0.0.1:$sport instead."
        fi
    fi

    local -a fwd=( "-$dir" "${bindaddr:+$bindaddr:}${sport}:${TARGET_HOST}:${dport}" )
    # shellcheck disable=SC2086
    nohup "$TRANSPORT" -N $params \
        -o StrictHostKeyChecking=accept-new \
        -o ExitOnForwardFailure=yes \
        "${algos[@]}" \
        "${fwd[@]}" "$user@$host" \
        > "$TUNNEL_DIR/$slug.log" 2>&1 < /dev/null &
    sleep 3

    if pid="$(tunnel_pid "$sport" "$dport" "$dir")"; then
        if [[ -n "$kexalgo" ]]; then
            ok "Tunnel started (pid $pid) — kex $kexalgo, $host:$sport → local:$TARGET_HOST:$dport"
        else
            ok "Tunnel started (pid $pid) — $host:$sport → local:$TARGET_HOST:$dport"
        fi
    else
        # A bind failure means the port is already taken. Say so plainly and
        # name the holder, rather than leaving the raw ssh error to explain.
        local log; log="$(cat "$TUNNEL_DIR/$slug.log" 2>/dev/null)"
        if printf '%s' "$log" | grep -qi "address already in use"; then
            err "Port $sport is already in use — the tunnel could not bind."
            local holder; holder="$(socket_owner_pids "$sport" | head -1)"
            if [[ -n "$holder" ]]; then
                local hcomm; hcomm="$(cat "/proc/$holder/comm" 2>/dev/null)"
                err "  held by $hcomm (pid $holder)"
                if [[ "$hcomm" == "ssh" || "$hcomm" == "autossh" ]]; then
                    err "  that looks like a tunnel DiggerSSH did not recognise —"
                    err "  try 'Stop a tunnel', or stop it manually: kill $holder"
                else
                    err "  it is not an ssh tunnel — free the port and retry."
                fi
            else
                err "  the holder is not a local process (it may be bound on the server)."
            fi
        else
            err "Tunnel did not come up. Log:"
            [[ -n "$log" ]] && printf '%s\n' "$log" | sed 's/^/    /'
        fi
        return 1
    fi
}

stop_tunnel() {
    local slug="$1" host="$2" sport="$3" dport="$4"
    local pid
    if ! pid="$(tunnel_pid "$sport" "$dport")"; then
        warn "Tunnel $slug is not running."
        return 0
    fi
    local parent; parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    kill "$pid" 2>/dev/null || true
    if [[ -n "$parent" && "$parent" != "1" ]]; then
        local pcomm; pcomm="$(cat "/proc/$parent/comm" 2>/dev/null)"
        [[ "$pcomm" == "autossh" ]] && kill "$parent" 2>/dev/null || true
    fi
    sleep 1
    local p cmd spec
    for spec in $(forward_specs L "$sport" "$dport"; forward_specs R "$sport" "$dport"); do
        for p in $(pgrep -x ssh 2>/dev/null; pgrep -x autossh 2>/dev/null); do
            [[ -r "/proc/$p/cmdline" ]] || continue
            cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
            [[ "$cmd" == *"$spec"* ]] && kill "$p" 2>/dev/null || true
        done
    done
    sleep 1
    if tunnel_pid "$sport" "$dport" >/dev/null 2>&1; then
        warn "Tunnel $slug is still running — the ssh process did not exit."
    else
        ok "Tunnel $slug stopped."
    fi
}

do_create()  { submenu "Create Tunnel to Server" open-R; }
do_connect() { submenu "Connect Tunnel (to a server's Port)" open-L; }
do_stop()    { submenu "Stop a tunnel" stop; }

do_list() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_records)"
    if [[ -z "$out" ]]; then info "No tunnels registered."; return 0; fi
    printf '  %-4s %-18s %-9s %-9s %s\n' "#" "HOST" "PORT" "LOCAL" "STATUS"
    printf '  %-4s %-18s %-9s %-9s %s\n' "---" "----" "----" "-----" "------"
    local n=0 line slug host user sport dport
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sport dport _ <<< "$line"
        printf '  %-4s %-18s %-9s %-9s %s\n' "$n" "$host" "$sport" "$dport" "$(status_text "$sport" "$dport")"
    done <<< "$out"
    return 0
}

# ============================================================ provisioning ===
provisioning_form() {
    local dir="${1:-R}"
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
    if [[ "$dir" == "R" ]]; then
        printf '  %sThe server listens on the source port and forwards it back here.%s\n' "$C_DIM" "$C_RESET"
    else
        printf '  %sThis machine listens on the source port and forwards into the server.%s\n' "$C_DIM" "$C_RESET"
    fi
    ask "Source Port" "$sshport"; local sport="$REPLY"
    ask "Destination Port" "$sport"; local dport="$REPLY"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"

    for p in "$sport" "$dport"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then err "Invalid port: $p"; return 1; fi
    done
    [[ -n "$host" ]] || { err "Host is required."; return 1; }

    printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
    printf '  ssh -p %s %s -%s %s:%s:%s %s@%s\n' "$sshport" "$params" "$dir" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    ask "Save? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$sshport"
    cfg_set LAST_SOURCE_PORT "$sport"
    cfg_set LAST_DEST_PORT "$dport"
    save_record "$host" "$user" "$sport" "$dport" "$params" "$sshport"
    local slug; slug="$(slug_of "$host" "$sport")"
    open_tunnel "$slug" "$host" "$user" "$sport" "$dport" "$dir" "$sshport"
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

# PIDs holding a listening socket on $1.
socket_owner_pids() {
    local port="$1"
    ss -ltnp 2>/dev/null | awk -v p="$port" '$4 ~ (":" p "$")' \
      | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# Whether a listener on $1 exists in the given address family.
family_in_use() {
    local port="$1" family="$2" addr
    case "$family" in
        ipv4) addr="127.0.0.1:${port}" ;;
        ipv6) addr="[::1]:${port}" ;;
        *) return 1 ;;
    esac
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qxF "$addr"
}

init_state() {
    mkdir -p "$DIGGERSH_HOME" "$TUNNEL_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
}

init_state
main_menu
