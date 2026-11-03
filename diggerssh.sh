#!/usr/bin/env bash
# ============================================================================
#  DiggerSSH v1.8.3 — SSH Tunnel Manager
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
#  Finding a running tunnel
#  ------------------------
#  Whether a tunnel is up is answered by asking ps, the same way the user
#  checks by hand:
#
#      ps auxw | grep 44641
#
#  ps enumerates the processes, and the forward argument is parsed out of
#  each ssh/autossh command line. The SOURCE PORT identifies the tunnel;
#  the destination may be any host:port, and the bind address may be
#  spelled several ways, so neither is compared.
#
#  Before a tunnel is started, the port is checked the same way. An ssh
#  process already carrying that port cannot be bound again — ssh would
#  exit with "Address already in use" and the tunnel would never come up —
#  so the holder is named up front, with its pid and its command line,
#  instead of leaving that error to explain.
#
#  autossh is a SUPERVISOR: it keeps running and respawning ssh even when
#  the connection fails, and the forward argument sits in autossh's own
#  command line. So autossh alone does not prove a tunnel is up — the ssh
#  CHILD does. A tunnel is reported as running only when that child
#  exists, otherwise a connection that is failing and being retried would
#  look perfectly healthy.
#
#  The SSH port
#  ------------
#  The port a server listens on for SSH is part of the server record and
#  is passed to ssh with -p. Without it every connection would go to port
#  22, and a server registered on another port could never be reached.
#  A tunnel record carries its own port too, and that one wins: a tunnel
#  belongs to a server, but it was created against a particular port.
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
#    5) Delete a tunnel or server
#    0) Exit
#
#  Ownership
#  ---------
#  Because a -R tunnel's listener is on the server, the local socket table
#  says nothing about whether a tunnel is up. Ownership is determined by the
#  local ssh process that carries the forward argument: that process IS the
#  tunnel. It is found by PARSING that argument out of /proc, never by a
#  broad pkill -f, which can match this script's own shell.
#
#  The argument is parsed rather than compared as text, because ssh accepts
#  many spellings of the same forward ("-L 44641:...", "-L [::1]:44641:...",
#  "-L 0.0.0.0:44641:...") and the destination may be any host:port. A
#  whole-string comparison misses tunnels that are plainly running, which
#  makes the status read "stopped" and a later start collide with the live
#  tunnel. The source port identifies the tunnel; the destination does not
#  have to match the record.
#
#  State layout
#    ~/.diggerssh/config                    defaults (LAST_HOST, LAST_USER, …)
#    ~/.diggerssh/servers/<id>.conf         a server: host, user, SSH port, description
#    ~/.diggerssh/tunnels/<id>.tunnel       a tunnel belonging to that server
#    ~/.diggerssh/tunnels/<id>.log          the tunnel's output
#
#  The registry has two tiers, as specified: a server is registered once and
#  its tunnels hang off it. Deleting a server's file therefore removes that
#  server from the menus, and its tunnels go with it.
#
#  The forward target host is fixed at 127.0.0.1 on the far side.
#
#  The server form
#  ----------------
#  "Add new server" asks for the source and destination ports as well as
#  the server details, because the forward argument is built from them:
#
#      -R <source>:127.0.0.1:<dest>     the server listens
#      -L <source>:127.0.0.1:<dest>     this machine listens
#
#  Registering a server from a tunnel menu therefore also creates and
#  opens the tunnel, rather than leaving a server with no forward.
#
#  Logging
#  -------
#  Every entry written to a log file carries a timestamp:
#
#      [2026-11-03 22:25:56] Tunnel t1 started (pid 376402, -L, kex …)
#
#  The tunnel's own log is the ssh process's output, timestamped as it is
#  written. The activity log records what the tool did.
#
#  Orphan tunnels
#  --------------
#  A tunnel whose server is not registered is kept and listed, marked
#  "(no server)", but it does not appear under any server. Registering the
#  server again re-attaches it.
# ============================================================================

set -o pipefail
VERSION="1.8.3"

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
TARGET_HOST="127.0.0.1"
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_PARAMS="-o ServerAliveInterval=30 -o ServerAliveCountMax=5"

info() { printf '%s…%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------- logging ---
# A timestamped line, in the form:
#
#     [2026-11-03 22:15:54] Tunnel started (pid 1234)
#
# Every entry written to a log file carries one, so a log reads as a
# sequence of events rather than an undated wall of text.
log_stamp() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Append a timestamped entry to the script's activity log.
log_write() {
    [[ -f "$LOG_FILE" ]] || return 0
    log_stamp "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# The awk program that prefixes each line of stdin with a timestamp, so
# the ssh process's own output is timestamped as it is written to the
# tunnel's log file.
#
# It is a standalone program rather than a shell function on purpose. A
# shell function is not available inside "bash -c", and a shell loop in a
# background pipeline does not receive EOF when the writer exits, so the
# pipeline never finishes and the script hangs waiting for it. awk is a
# separate process: it ends when its stdin closes, and it inherits no file
# descriptor from the script, so it cannot hold the terminal open.
LOG_FILTER_AWK='{ printf "[%s] %s\n", strftime("%Y-%m-%d %H:%M:%S"), $0; fflush() }' 

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
# Matching a tunnel to a record must not depend on the exact text of the
# forward argument. ssh accepts many spellings of the same forward:
#
#   -L 44641:127.0.0.1:44641              plain
#   -L 127.0.0.1:44641:127.0.0.1:44641     explicit IPv4 bind
#   -L [::1]:44641:127.0.0.1:44641         explicit IPv6 bind
#   -L [::]:44641:127.0.0.1:44641          IPv6 wildcard bind
#   -L 0.0.0.0:44641:127.0.0.1:44641       IPv4 wildcard bind
#   -L *:44641:127.0.0.1:44641             star bind
#
# and the destination may be any host:port, not necessarily 127.0.0.1.
#
# A whole-string comparison therefore misses tunnels that are plainly
# running: the status reads "stopped", a later start then collides with
# the live tunnel, and the user is told the port is already in use.
#
# Instead each -L/-R argument in a process's command line is PARSED, and
# the tunnel is identified by the pair (direction, source port). The
# destination is compared only when the record knows one and the argument
# names a different one.

# Pull every forward argument out of a command line, one per line, with
# the direction and the argument separated by a tab.
parse_forwards() {
    local cmd="$1"
    local -a words=()
    local i
    # shellcheck disable=SC2206
    words=( $cmd )
    for (( i = 0; i < ${#words[@]}; i++ )); do
        case "${words[i]}" in
            -L|-R)
                (( i + 1 < ${#words[@]} )) || continue
                printf '%s\t%s\n' "${words[i]#-}" "${words[i+1]}"
                ;;
            -L*|-R*)
                # "-L44641:..." — the value is glued to the flag
                printf '%s\t%s\n' "${words[i]#[-]L}" "${words[i]#[-]R}"
                ;;
        esac
    done
}

# Split a forward argument into its fields. A forward is
#
#   [bind_address:]port:host:hostport
#
# where the bind address is optional and may be "[::1]", "127.0.0.1",
# "0.0.0.0", "[::]" or "*". The fields are separated by colons, but a
# bracketed IPv6 address contains colons of its own, so a bracketed
# address is stripped out first and kept as a single field.
#
# Sets FWD_FIELDS to: bind, port, host, hostport.
forward_split() {
    local spec="$1" bind=""
    FWD_FIELDS=()
    case "$spec" in
        \[*\]:*) bind="${spec%%]:*}"; spec="${spec#*]:}" ;;
    esac

    # Split the remainder on colons.
    local -a f=()
    local IFS=':'
    read -r -a f <<< "$spec"
    unset IFS

    case "${#f[@]}" in
        4)  FWD_FIELDS=( "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" ) ;;
        3)  FWD_FIELDS=( "$bind" "${f[0]}" "${f[1]}" "${f[2]}" ) ;;
        *)  FWD_FIELDS=( "$bind" "${f[0]:-}" "" "" ) ;;
    esac
}

# The source port of a forward argument.
forward_source_port() {
    forward_split "$1"
    printf '%s' "${FWD_FIELDS[1]}"
}

# The destination "host:port" of a forward argument, or empty.
forward_dest() {
    forward_split "$1"
    [[ -n "${FWD_FIELDS[2]}" ]] && printf '%s:%s' "${FWD_FIELDS[2]}" "${FWD_FIELDS[3]}"
}

# The ssh transports on this machine, enumerated with ps.
#
# The user checks this by hand with "ps auxw | grep <port>", so the tool
# uses the same source: ps lists the processes, and /proc/PID/cmdline gives
# the exact argument vector to parse. That means the tool's answer and the
# user's own "ps auxw" answer cannot disagree about whether a tunnel is up.
#
# Prints "pid<TAB>command line" for each ssh/autossh process.
ssh_processes() {
    local pid comm args
    while read -r pid comm args; do
        [[ -n "$pid" ]] || continue
        case "$comm" in
            ssh|autossh) ;;
            *) continue ;;
        esac
        [[ -r "/proc/$pid/cmdline" ]] || continue
        printf '%s\t%s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    done < <(ps -eo pid=,comm=,args= 2>/dev/null)
}

# Every ssh process carrying a forward for the given source port.
# Prints "pid<TAB>direction<TAB>spec" for each.
tunnel_processes() {
    local sport="$1" dir="${2:-}"
    local pid cmd fdir spec fport
    while IFS=$'\t' read -r pid cmd; do
        [[ -n "$pid" && -n "$cmd" ]] || continue
        while IFS=$'\t' read -r fdir spec; do
            [[ -n "$fdir" && -n "$spec" ]] || continue
            [[ -n "$dir" && "$fdir" != "$dir" ]] && continue
            fport="$(forward_source_port "$spec")"
            [[ "$fport" == "$sport" ]] || continue
            # The source port identifies the tunnel. The destination is not
            # required to match: ssh permits any host:port there, and a
            # mismatch must not make a running tunnel look stopped.
            printf '%s\t%s\t%s\n' "$pid" "$fdir" "$spec"
        done < <(parse_forwards "$cmd")
    done < <(ssh_processes)
}

# The PID of the ssh/autossh process carrying this forward, if any.
# $1 source port, $2 destination port (may be empty), $3 direction (L or R,
# empty for either).
tunnel_pid() {
    local sport="$1" dport="$2" dir="${3:-}"
    local pid fdir spec
    while IFS=$'\t' read -r pid fdir spec; do
        [[ -n "$pid" ]] || continue
        printf '%s' "$pid"; return 0
    done < <(tunnel_processes "$sport" "$dir")
    return 1
}

# The PID of the process that actually HOLDS the tunnel.
#
# autossh is a supervisor: it keeps running and respawning ssh even when
# the connection fails (wrong port, unreachable host, bad key). The forward
# argument sits in autossh's own command line, so autossh alone would make
# a dead tunnel look alive. The real worker is the ssh CHILD, and it is
# the child's presence that proves the connection came up.
#
# Prints the ssh pid, or the autossh pid only when no ssh child exists
# yet (the connection may still be establishing).
tunnel_worker_pid() {
    local sport="$1" dport="$2" dir="${3:-}"
    local pid fdir spec comm supervisor=""
    while IFS=$'\t' read -r pid fdir spec; do
        [[ -n "$pid" ]] || continue
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        if [[ "$comm" == "ssh" ]]; then
            printf '%s' "$pid"; return 0
        fi
        [[ -n "$supervisor" ]] || supervisor="$pid"
    done < <(tunnel_processes "$sport" "$dir")
    [[ -n "$supervisor" ]] || return 1
    printf '%s' "$supervisor"
    return 1     # only the supervisor: the connection is not up
}

# Every PID carrying this forward, used when stopping.
tunnel_pids() {
    local sport="$1" dport="$2"
    local pid fdir spec
    while IFS=$'\t' read -r pid fdir spec; do
        [[ -n "$pid" ]] || continue
        printf '%s\n' "$pid"
    done < <(tunnel_processes "$sport" "") | sort -u
}

tunnel_dir() {
    local sport="$1" dport="$2" dir
    for dir in L R; do
        if tunnel_pid "$sport" "$dport" "$dir" >/dev/null 2>&1; then printf '%s' "$dir"; return 0; fi
    done
    return 1
}

status_text() {
    local sport="$1" dport="$2" dir pid
    if dir="$(tunnel_dir "$sport" "$dport")"; then
        pid="$(tunnel_pid "$sport" "$dport" "$dir" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            printf '%srunning%s%s' "$C_GREEN" "$C_RESET" "$C_DIM(-$dir pid $pid)$C_RESET"
        else
            printf '%srunning%s%s' "$C_GREEN" "$C_RESET" "$C_DIM(-$dir)$C_RESET"
        fi
    else
        printf '%sstopped%s' "$C_YELLOW" "$C_RESET"
    fi
}

# Is an ssh process ALREADY carrying this forward? Checked with ps, the
# same way the user checks by hand:
#
#     ps auxw | grep 44641
#
# The question is asked before every start, because an ssh process that
# already holds the port cannot be bound again: ssh then exits with
# "Address already in use" and the tunnel never comes up. Reporting the
# holder is far more useful than that error.
#
# Prints the pid and the forward spec of every match.
existing_tunnel() {
    local sport="$1" dir="${2:-}"
    local pid fdir spec
    while IFS=$'\t' read -r pid fdir spec; do
        [[ -n "$pid" ]] || continue
        printf '%s\t%s\t%s\n' "$pid" "$fdir" "$spec"
    done < <(tunnel_processes "$sport" "$dir")
}

# The ssh processes that mention this port, in the same shape the user sees
# from "ps auxw | grep <port>". Only the ssh transports are shown: the
# interesting line is the one that carries the forward, and a wall of
# unrelated shells that merely mention the number helps nobody.
ps_view() {
    local port="$1"
    local pid comm args
    while read -r pid comm args; do
        [[ -n "$pid" ]] || continue
        case "$comm" in
            ssh|autossh) ;;
            *) continue ;;
        esac
        case "$args" in
            *"$port"*) printf '%s\n' "$args" ;;
        esac
    done < <(ps -eo pid=,comm=,args= 2>/dev/null)
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

# A description is stored in full but only ever shown shortened, so the
# listing stays a fixed width. 19 characters plus an ellipsis is 20.
trunc_desc() {
    local s="$1"
    if (( ${#s} > 20 )); then
        printf '%s…' "${s:0:19}"
    else
        printf '%s' "$s"
    fi
}

# ============================================================ records ========
# Two tiers, as specified:
#
#   tier 1  servers   ~/.diggerssh/servers/<host>_<port>.conf
#           the SSH hosts this machine knows about
#   tier 2  tunnels   ~/.diggerssh/tunnels/<host>_<port>.tunnel
#           the tunnels belonging to a server
#
# The menus are driven by the SERVER tier: a server is listed once and its
# tunnels hang under it. Deleting a server's file therefore removes it from
# the menus, and its tunnels go with it — which is what "start fresh" means.
slug_of() { printf '%s_%s' "${1//[^a-zA-Z0-9._-]/_}" "$2"; }

# slug|host|user|sshport|params|desc
list_servers() {
    local f
    for f in "$SERVER_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        local slug host user sshport params desc
        slug="$(basename "$f" .conf)"
        host="$(grep -m1 '^HOST='         "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sshport="$(grep -m1 '^SSH_PORT='   "$f" | cut -d'=' -f2-)"
        [[ -n "$sshport" ]] || sshport="22"
        params="$(grep -m1 '^SSH_PARAMS='  "$f" | cut -d'=' -f2-)"
        desc="$(grep -m1 '^DESCRIPTION=' "$f" | cut -d'=' -f2-)"
        printf '%s|%s|%s|%s|%s|%s\n' "$slug" "$host" "$user" "$sshport" "$params" "$desc"
    done | sort
}

save_server() {
    local host="$1" user="$2" sshport="$3" params="$4" desc="$5"
    local slug; slug="$(slug_of "$host" "$sshport")"
    {
        printf 'ID=%s\n'          "$slug"
        printf 'HOST=%s\n'        "$host"
        printf 'USER=%s\n'        "$user"
        printf 'SSH_PORT=%s\n'    "$sshport"
        printf 'SSH_PARAMS=%s\n'  "$params"
        printf 'DESCRIPTION=%s\n' "$desc"
        printf 'CREATED=%q\n'     "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$SERVER_DIR/$slug.conf"
    chmod 600 "$SERVER_DIR/$slug.conf" 2>/dev/null || true
    printf '%s' "$slug"
}

# slug|server_slug|sport|dport|desc|host|user|sshport|params
list_tunnels() {
    local f
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        local slug sslug sport dport desc host user sshport params
        slug="$(basename "$f" .tunnel)"
        sslug="$(grep -m1 '^SERVER='      "$f" | cut -d'=' -f2-)"
        sport="$(grep -m1 '^SOURCE_PORT=' "$f" | cut -d'=' -f2-)"
        dport="$(grep -m1 '^DEST_PORT='   "$f" | cut -d'=' -f2-)"
        desc="$(grep -m1 '^DESCRIPTION=' "$f" | cut -d'=' -f2-)"
        host="$(grep -m1 '^HOST='         "$f" | cut -d'=' -f2-)"
        user="$(grep -m1 '^USER='         "$f" | cut -d'=' -f2-)"
        sshport="$(grep -m1 '^SSH_PORT='   "$f" | cut -d'=' -f2-)"
        [[ -n "$sshport" ]] || sshport="22"
        params="$(grep -m1 '^SSH_PARAMS='  "$f" | cut -d'=' -f2-)"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$slug" "$sslug" "$sport" "$dport" "$desc" "$host" "$user" "$sshport" "$params"
    done | sort
}

save_tunnel() {
    local sslug="$1" host="$2" user="$3" sport="$4" dport="$5" sshport="$6" params="$7" desc="$8"
    local slug; slug="$(slug_of "$host" "$sport")"
    {
        printf 'ID=%s\n'          "$slug"
        printf 'SERVER=%s\n'     "$sslug"
        printf 'DESCRIPTION=%s\n' "$desc"
        printf 'HOST=%s\n'        "$host"
        printf 'USER=%s\n'        "$user"
        printf 'SOURCE_PORT=%s\n' "$sport"
        printf 'DEST_PORT=%s\n'   "$dport"
        printf 'SSH_PORT=%s\n'    "$sshport"
        printf 'SSH_PARAMS=%s\n'  "$params"
        printf 'CREATED=%q\n'     "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TUNNEL_DIR/$slug.tunnel"
    chmod 600 "$TUNNEL_DIR/$slug.tunnel" 2>/dev/null || true
    printf '%s' "$slug"
}

# The tunnels belonging to one server.
tunnels_of_server() {
    local want="$1" line slug sslug
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug sslug _ <<< "$line"
        [[ "$sslug" == "$want" ]] && printf '%s\n' "$line"
    done < <(list_tunnels)
}

# The tunnels whose server is no longer registered. They are kept and shown,
# never silently dropped, but they do not appear under any server.
orphan_tunnels() {
    local line slug sslug
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r slug sslug _ <<< "$line"
        [[ -z "$sslug" ]] && printf '%s\n' "$line"
    done < <(list_tunnels)
}

# ============================================================ submenu ========
# The server tier. Picking a server returns its details in SEL_*; the
# caller then asks for one of that server's tunnels.
SEL_SLUG=""; SEL_HOST=""; SEL_USER=""; SEL_SSHPORT=""; SEL_PARAMS=""; SEL_DESC=""

server_menu() {
    local title="$1" mode="${2:-}"
    local out; out="$(list_servers)"
    local total; total="$(printf '%s\n' "$out" | grep -c . || true)"

    printf '\n%s── %s ──%s\n' "$C_BOLD" "$title" "$C_RESET"
    local n=0 line slug host user sshport params desc
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug host user sshport params desc <<< "$line"
        printf '  %s%2d%s) %s:%s  %s%s%s\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sshport" "$C_DIM" "$(trunc_desc "$desc")" "$C_RESET"
    done <<< "$out"

    if [[ "$total" == "0" ]]; then
        printf '  %sno servers registered%s\n' "$C_DIM" "$C_RESET"
    fi

    local add=$((n + 1))
    printf '  %s%2d%s) %s+ Add new server%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s%2d%s) %sExit to main menu%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select server" "1"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    if [[ "$REPLY" == "0" ]]; then return 1; fi
    if [[ "$REPLY" == "$add" ]]; then
        # The form needs a bare R or L, and nothing at all for "stop",
        # where no forward is being built.
        local fdir=""
        case "$mode" in
            open-R) fdir="R" ;;
            open-L) fdir="L" ;;
        esac
        add_server_form "$fdir" || true
        return 2      # show the list again, now including the new server
    fi
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= total )); then
        local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
        IFS='|' read -r SEL_SLUG SEL_HOST SEL_USER SEL_SSHPORT SEL_PARAMS SEL_DESC <<< "$rec"
        return 0
    fi
    err "Invalid selection."
    return 1
}

# The tunnel tier: the tunnels belonging to the selected server.
# $1 mode (open-R, open-L, stop), the rest the server's details.
tunnel_menu() {
    local mode="$1" sslug="$2" host="$3" user="$4" sshport="$5" params="$6" desc="$7"
    local out; out="$(tunnels_of_server "$sslug")"
    local total; total="$(printf '%s\n' "$out" | grep -c . || true)"

    printf '\n%s── Tunnels on %s ──%s\n' "$C_BOLD" "$host" "$C_RESET"
    local n=0 line slug ts sport dport tdesc thost tuser tsshport tparams
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug ts sport dport tdesc thost tuser tsshport tparams <<< "$line"
        printf '  %s%2d%s) %s:%s → %s:%s  %s\n' \
            "$C_BOLD" "$n" "$C_RESET" "$host" "$sport" "$TARGET_HOST" "$dport" "$(status_text "$sport" "$dport")"
    done <<< "$out"

    if [[ "$total" == "0" ]]; then
        printf '  %sno tunnels on this server yet%s\n' "$C_DIM" "$C_RESET"
    fi

    local add=$((n + 1))
    if [[ "$mode" != "stop" ]]; then
        printf '  %s%2d%s) %s+ Create tunnel on this server%s\n' "$C_CYAN" "$add" "$C_RESET" "$C_DIM" "$C_RESET"
    fi
    printf '  %s%2d%s) %sBack to server list%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"

    ask "Select tunnel" "1"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    if [[ "$REPLY" == "0" ]]; then return 1; fi
    if [[ "$mode" != "stop" ]] && [[ "$REPLY" == "$add" ]]; then
        # The direction must be a bare R or L. "open-R" would be passed to
        # ssh as "-open-R", which ssh parses as "-o pen-R" and rejects.
        local dir
        case "$mode" in
            open-R) dir="R" ;;
            open-L) dir="L" ;;
            *)      dir="R" ;;
        esac
        add_tunnel_form "$sslug" "$host" "$user" "$sshport" "$params" "$desc" "$dir"
        return 1
    fi
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= total )); then
        local rec; rec="$(printf '%s\n' "$out" | sed -n "${REPLY}p")"
        local rslug rsport rdport rtsshport
        IFS='|' read -r rslug _ rsport rdport _ _ _ rtsshport _ <<< "$rec"
        # The tunnel record carries its own SSH port; use it, and fall
        # back to the server's when the record has none. Without this the
        # connection silently goes to port 22.
        [[ -n "$rtsshport" ]] || rtsshport="$sshport"
        case "$mode" in
            stop)   stop_tunnel "$rslug" "$host" "$rsport" "$rdport" ;;
            open-R) open_tunnel "$rslug" "$host" "$user" "$rsport" "$rdport" R "$rtsshport" ;;
            open-L) open_tunnel "$rslug" "$host" "$user" "$rsport" "$rdport" L "$rtsshport" ;;
        esac
        return 1
    fi
    err "Invalid selection."
    return 1
}

# The two-tier flow shared by both tunnel menus: pick a server, then pick
# one of its tunnels.
tiered_menu() {
    local title="$1" mode="$2"
    while true; do
        local rc=0
        server_menu "$title" "$mode" || rc=$?
        case "$rc" in
            0) ;;                    # a server was chosen
            2) continue ;;          # a server was added — show the list again
            *) return 0 ;;          # cancelled
        esac
        tunnel_menu "$mode" "$SEL_SLUG" "$SEL_HOST" "$SEL_USER" "$SEL_SSHPORT" "$SEL_PARAMS" "$SEL_DESC"
    done
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

    # An ssh process already carrying THIS port IN THE SAME DIRECTION will
    # make the bind fail: two -L tunnels bind the same port here, and two
    # -R tunnels bind the same port on the server. Say so up front, with
    # the process that holds it, instead of letting ssh fail with
    # "Address already in use" and an empty log.
    #
    # The OPPOSITE direction does not collide. A -R binds the port on the
    # server, a -L binds it here: they are two ends of one path and are
    # meant to run side by side. Refusing the pair made the second menu
    # unusable for the very record the first menu had just created.
    local holder hdir hspec
    while IFS=$'\t' read -r holder hdir hspec; do
        [[ -n "$holder" ]] || continue
        if [[ "$hdir" == "$dir" ]]; then
            warn "Port $sport is already carried by an ssh process (pid $holder, -$hdir $hspec)."
            warn "  this menu opens a -$dir tunnel, and so does that one."
            warn "  stop it first, then start this one."
            local view; view="$(ps_view "$sport")"
            if [[ -n "$view" ]]; then
                warn "  ps auxw | grep $sport:"
                printf '%s\n' "$view" | sed 's/^/    /' >&2
            fi
            return 1
        fi
        warn "Port $sport is also carried by a -$hdir tunnel (pid $holder)."
        warn "  that one binds the port on the server, this one binds it here,"
        warn "  so they do not collide — continuing."
    done < <(existing_tunnel "$sport")

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

    log_write "Starting tunnel $slug: $host:$sport → $TARGET_HOST:$dport (-$dir, ssh port $sshport)"

    local -a fwd=( "-$dir" "${bindaddr:+$bindaddr:}${sport}:${TARGET_HOST}:${dport}" )
    # The SSH port must be passed explicitly: ssh would otherwise use 22,
    # and a server registered on another port would never connect. An
    # empty value would make ssh fail on the option, so default it.
    [[ -n "$sshport" ]] || sshport="$DEFAULT_SSH_PORT"
    [[ "$sshport" =~ ^[0-9]+$ ]] || sshport="$DEFAULT_SSH_PORT"
    # shellcheck disable=SC2086
    # The tunnel's log is ssh's own output. A filter sits between ssh and
    # the file so every line is stamped with the time it was written.
    # The tunnel's log is ssh's own output, timestamped as it is written.
    #
    # setsid puts the whole thing in a new session: it survives the script
    # exiting, and it holds no file descriptor of the script, so the
    # script is never left waiting for it. The awk filter ends when ssh
    # ends.
    local cmdline
    printf -v cmdline '%q ' "$TRANSPORT" -N -p "$sshport" $params \
        -o StrictHostKeyChecking=accept-new \
        -o ExitOnForwardFailure=yes \
        "${algos[@]}" \
        "${fwd[@]}" "$user@$host"

    # The PIDs carrying this port BEFORE the launch. A failed launch leaves
    # an autossh supervisor behind, retrying forever; the next attempt then
    # sees that supervisor and reports the port as carried by some
    # unrelated process, with no way to clear it. Remembering what was
    # already there lets the cleanup below remove only what this attempt
    # started.
    local before_pids=" " p_bp
    while IFS=$'\t' read -r p_bp _ _; do
        [[ -n "$p_bp" ]] && before_pids+="$p_bp "
    done < <(tunnel_pids "$sport" "$dport")

    # The exact command goes into the tunnel's log BEFORE the launch, so
    # the log always shows what was attempted. An empty log used to be the
    # only clue when a tunnel failed, and it said nothing at all.
    local tlog="$TUNNEL_DIR/$slug.log"
    : > "$tlog"
    log_stamp "command: $TRANSPORT -N -p $sshport $params -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes ${algos[*]} ${fwd[*]} $user@$host" >> "$tlog"

    # The transport's exit status is appended to the log when it ends, so a
    # silent death is still recorded.
    setsid bash -c "{ $cmdline 2>&1 | awk '$LOG_FILTER_AWK'; printf '[%s] transport exited with status %s\n' \"\$(date '+%Y-%m-%d %H:%M:%S')\" \"\${PIPESTATUS[0]}\"; }" \
        >> "$tlog" 2>/dev/null < /dev/null &
    disown 2>/dev/null || true
    # Give the connection time to establish. autossh spawns ssh as a child,
    # so a short window can catch the process before it has bound. The test
    # is for the ssh CHILD: autossh exists from the first moment and would
    # report success for a connection that is failing and being retried.
    local waited=0 worker=""
    while (( waited < 15 )); do
        if worker="$(tunnel_worker_pid "$sport" "$dport" "$dir")"; then
            [[ "$(cat "/proc/$worker/comm" 2>/dev/null)" == "ssh" ]] && break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if pid="$(tunnel_worker_pid "$sport" "$dport" "$dir")" && \
       [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == "ssh" ]]; then
        if [[ -n "$kexalgo" ]]; then
            ok "Tunnel started (pid $pid) — kex $kexalgo, $host:$sport → local:$TARGET_HOST:$dport"
            log_write "Tunnel $slug started (pid $pid, -$dir, kex $kexalgo)"
        else
            ok "Tunnel started (pid $pid) — $host:$sport → local:$TARGET_HOST:$dport"
            log_write "Tunnel $slug started (pid $pid, -$dir)"
        fi
    else
        # A bind failure means the port is already taken. Say so plainly and
        # name the holder, rather than leaving the raw ssh error to explain.
        local log; log="$(cat "$TUNNEL_DIR/$slug.log" 2>/dev/null)"
        if printf '%s' "$log" | grep -qi "address already in use"; then
            err "Port $sport is already in use — the tunnel could not bind."
            # ss -p only names sockets you own, so a tunnel running as
            # another user shows no pid there even though /proc exposes its
            # command line. Look in both places.
            local holder; holder="$(socket_owner_pids "$sport" | head -1)"
            if [[ -z "$holder" ]]; then
                holder="$(tunnel_pids "$sport" "" | head -1)"
            fi
            if [[ -n "$holder" ]]; then
                local hcomm; hcomm="$(cat "/proc/$holder/comm" 2>/dev/null)"
                err "  held by $hcomm (pid $holder)"
                if [[ "$hcomm" == "ssh" || "$hcomm" == "autossh" ]]; then
                    err "  that is an SSH tunnel already forwarding port $sport."
                    err "  It is not one of the tunnels DiggerSSH tracks, so it was"
                    err "  not started here. Stop it manually: kill $holder"
                else
                    err "  it is not an ssh tunnel — free the port and retry."
                fi
                # Clean up this attempt's own supervisor so the next try is
                # not blocked by a retrying process nobody can see.
                local p3 pp3
                for p3 in $(tunnel_pids "$sport" "$dport"); do
                    [[ "$before_pids" == *" $p3 "* ]] && continue
                    kill "$p3" 2>/dev/null
                    pp3="$(ps -o ppid= -p "$p3" 2>/dev/null | tr -d ' ')"
                    if [[ -n "$pp3" && "$pp3" != "1" && "$pp3" != "$$" ]]; then
                        [[ "$(cat "/proc/$pp3/comm" 2>/dev/null)" == "autossh" ]] && kill "$pp3" 2>/dev/null
                    fi
                done
            else
                err "  no local process owns it; the port is probably bound"
                err "  on the server side of an -R tunnel."
            fi
        else
            err "Tunnel did not come up."
            log_write "Tunnel $slug did not come up (-$dir, $host:$sport)"
            # autossh retries a failing connection, so the supervisor may
            # still be alive while nothing is actually connected. Say so
            # rather than leaving it looking half-alive.
            local sup; sup="$(tunnel_worker_pid "$sport" "$dport" "$dir" || true)"
            if [[ -n "$sup" ]] && [[ "$(cat "/proc/$sup/comm" 2>/dev/null)" == "autossh" ]]; then
                err "  autossh is still retrying (pid $sup), but no ssh connection"
                err "  was established — the tunnel is NOT up."
            fi
            # Stop what this attempt started. A supervisor left retrying
            # would make the next attempt report the port as carried by an
            # unrelated process, and the tool had no way to clear it.
            local p2 pp2 cleaned=0
            for p2 in $(tunnel_pids "$sport" "$dport"); do
                [[ "$before_pids" == *" $p2 "* ]] && continue
                kill "$p2" 2>/dev/null && cleaned=1
                pp2="$(ps -o ppid= -p "$p2" 2>/dev/null | tr -d ' ')"
                if [[ -n "$pp2" && "$pp2" != "1" && "$pp2" != "$$" ]]; then
                    [[ "$(cat "/proc/$pp2/comm" 2>/dev/null)" == "autossh" ]] && kill "$pp2" 2>/dev/null
                fi
            done
            if (( cleaned )); then
                err "  the failed attempt was cleaned up; nothing is left retrying."
            fi
            if [[ -n "$log" ]]; then
                err "  Log:"
                printf '%s\n' "$log" | sed 's/^/    /'
            else
                err "  ssh produced no output at all — it exited without saying why."
                err "  The log holds the exact command that was run."
            fi
            # Show what ps sees for this port, so the cause is visible
            # without leaving the tool.
            local view; view="$(ps_view "$sport")"
            if [[ -n "$view" ]]; then
                err "  ps auxw | grep $sport:"
                printf '%s\n' "$view" | sed 's/^/    /' >&2
            fi
            # And whether anything is now carrying the forward.
            local after
            while IFS=$'\t' read -r after _ _; do
                [[ -n "$after" ]] || continue
                err "  an ssh process (pid $after) does carry this forward now"
            done < <(existing_tunnel "$sport")
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
    # Any process still carrying this forward, in either direction.
    local p parent2
    for p in $(tunnel_pids "$sport" "$dport"); do
        kill "$p" 2>/dev/null || true
        parent2="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
        if [[ -n "$parent2" && "$parent2" != "1" ]]; then
            local pc2; pc2="$(cat "/proc/$parent2/comm" 2>/dev/null)"
            [[ "$pc2" == "autossh" ]] && kill "$parent2" 2>/dev/null || true
        fi
    done
    sleep 1
    if tunnel_pid "$sport" "$dport" >/dev/null 2>&1; then
        warn "Tunnel $slug is still running — the ssh process did not exit."
        log_write "Tunnel $slug did not stop cleanly"
    else
        ok "Tunnel $slug stopped."
        log_write "Tunnel $slug stopped"
    fi
}

do_create()  { tiered_menu "Create Tunnel to Server" open-R; }
do_connect() { tiered_menu "Connect Tunnel (to a server's Port)" open-L; }
do_stop()    { tiered_menu "Stop a tunnel" stop; }

do_list() {
    printf '\n%s── List tunnels ──%s\n' "$C_BOLD" "$C_CYAN"
    local out; out="$(list_tunnels)"
    if [[ -z "$out" ]]; then info "No tunnels registered."; return 0; fi
    printf '  %-20s %-4s %-18s %-9s %-9s %s\n' "DESCRIPTION" "#" "HOST" "PORT" "LOCAL" "STATUS"
    printf '  %-20s %-4s %-18s %-9s %-9s %s\n' "----------" "---" "----" "----" "-----" "------"
    local n=0 line slug sslug sport dport desc host user sshport params
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        IFS='|' read -r slug sslug sport dport desc host user sshport params <<< "$line"
        # A tunnel whose server was deleted is still listed, but marked:
        # it is kept, never silently dropped.
        local note=""
        [[ -z "$sslug" ]] && note="${C_DIM}(no server)${C_RESET}"
        printf '  %-20s %-4s %-18s %-9s %-9s %s %s\n' \
            "$(trunc_desc "$desc")" "$n" "$host" "$sport" "$dport" "$(status_text "$sport" "$dport")" "$note"
    done <<< "$out"
    return 0
}

# Delete a tunnel record, or a whole server with its tunnels.
do_delete() {
    printf '\n%s── Delete a tunnel or server ──%s\n' "$C_BOLD" "$C_CYAN"

    printf '\n%sServers%s\n' "$C_BOLD" "$C_RESET"
    local srows; srows="$(list_servers)"
    local sn=0 sline sslug shost suser sshport sparams sdesc
    while IFS= read -r sline; do
        [[ -z "$sline" ]] && continue
        sn=$((sn + 1))
        IFS='|' read -r sslug shost suser sshport sparams sdesc <<< "$sline"
        local nt; nt="$(tunnels_of_server "$sslug" | grep -c . || true)"
        printf '  %s%2d%s) %s:%s  %s%s%s  (%s tunnel(s))\n' \
            "$C_BOLD" "$sn" "$C_RESET" "$shost" "$sshport" "$C_DIM" "$(trunc_desc "$sdesc")" "$C_RESET" "$nt"
    done <<< "$srows"

    printf '\n%sTunnels%s\n' "$C_BOLD" "$C_RESET"
    local trows; trows="$(list_tunnels)"
    local tn=0 tline tslug tsslug tsport tdport tdesc thost tuser tsshport tparams
    while IFS= read -r tline; do
        [[ -z "$tline" ]] && continue
        tn=$((tn + 1))
        IFS='|' read -r tslug tsslug tsport tdport tdesc thost tuser tsshport tparams <<< "$tline"
        # The numbering continues from the servers above, so every entry in
        # this list has ONE number the user can type.
        printf '  %s%2d%s) %s:%s  %s%s%s\n' \
            "$C_BOLD" "$((sn + tn))" "$C_RESET" "$thost" "$tsport" "$C_DIM" "$(trunc_desc "$tdesc")" "$C_RESET"
    done <<< "$trows"

    if [[ "$sn" == "0" && "$tn" == "0" ]]; then
        info "Nothing registered — nothing to delete."
        return 0
    fi

    printf '  %s%2d%s) %sBack to main menu%s\n\n' "$C_RED" "0" "$C_RESET" "$C_DIM" "$C_RESET"
    ask "Select what to delete" "1"
    [[ "$EOF_REACHED" == "1" ]] && return 0
    [[ "$REPLY" == "0" ]] && return 0

    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= sn )); then
        local rec; rec="$(printf '%s\n' "$srows" | sed -n "${REPLY}p")"
        IFS='|' read -r sslug shost suser sshport sparams sdesc <<< "$rec"
        ask "Delete server $shost and its tunnels? [y/N]" "y"
        [[ "$EOF_REACHED" == "1" ]] && return 0
        [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 0; }
        # Stop anything running on that server first.
        while IFS='|' read -r tslug _ tsport tdport _ _ _ _ _; do
            [[ -z "$tsport" ]] && continue
            stop_tunnel "$tslug" "$shost" "$tsport" "$tdport" >/dev/null 2>&1 || true
        done < <(tunnels_of_server "$sslug")
        while IFS='|' read -r tslug _ _ _ _ _ _ _ _; do
            [[ -z "$tslug" ]] && continue
            rm -f "$TUNNEL_DIR/$tslug.tunnel" "$TUNNEL_DIR/$tslug.log"
        done < <(tunnels_of_server "$sslug")
        rm -f "$SERVER_DIR/$sslug.conf"
        ok "Deleted server $shost and its tunnels."
        log_write "Deleted server $shost and its tunnels"
        return 0
    fi

    local tbase=$((sn + 1))
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= tbase && REPLY <= tbase + tn )); then
        # The first tunnel in the list is entry (sn + 1).
        local idx=$((REPLY - tbase + 1))
        local rec; rec="$(printf '%s\n' "$trows" | sed -n "${idx}p")"
        IFS='|' read -r tslug _ tsport tdport tdesc thost _ _ _ <<< "$rec"
        ask "Delete tunnel $thost:$tsport? [y/N]" "y"
        [[ "$EOF_REACHED" == "1" ]] && return 0
        [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 0; }
        stop_tunnel "$tslug" "$thost" "$tsport" "$tdport" >/dev/null 2>&1 || true
        rm -f "$TUNNEL_DIR/$tslug.tunnel" "$TUNNEL_DIR/$tslug.log"
        ok "Deleted tunnel $thost:$tsport."
        log_write "Deleted tunnel $thost:$tsport"
        return 0
    fi

    err "Invalid selection."
    return 0
}

# ============================================================ provisioning ===
# Tier 1 — register a server. The record lives in ~/.diggerssh/servers/.
# $1 is the direction to build: "R", "L", or empty when no tunnel is
# wanted (the "Stop a tunnel" menu only registers the server).
add_server_form() {
    local dir="${1:-}"
    printf '\n%s── Add New Server ──%s\n' "$C_BOLD" "$C_CYAN"
    local last_host last_user
    last_host="$(cfg_get LAST_HOST "")"
    last_user="$(cfg_get LAST_USER "$(id -un 2>/dev/null)")"

    printf '\n%sStep 1 — Server%s\n' "$C_BOLD" "$C_RESET"
    ask "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ -n "$host" ]] || { err "Host is required."; return 1; }
    ask "SSH Username" "$last_user"; local user="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "SSH Port" "$DEFAULT_SSH_PORT"; local sshport="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    if ! [[ "$sshport" =~ ^[0-9]+$ ]] || (( sshport < 1 || sshport > 65535 )); then
        err "Invalid SSH port: $sshport"; return 1
    fi

    printf '\n%sStep 2 — Description%s\n' "$C_BOLD" "$C_RESET"
    ask "Description" ""; local desc="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1

    printf '\n%sStep 3 — SSH parameters%s\n' "$C_BOLD" "$C_RESET"
    ask "SSH parameters" "$DEFAULT_SSH_PARAMS"; local params="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1

    # The ports belong to this form: the forward argument is built from
    # them, and the direction decides which side listens.
    local sport="" dport=""
    if [[ -n "$dir" ]]; then
        printf '\n%sStep 4 — Tunnel%s\n' "$C_BOLD" "$C_RESET"
        if [[ "$dir" == "R" ]]; then
            printf '  %sThe server listens on the source port and forwards it back here.%s\n' "$C_DIM" "$C_RESET"
        else
            printf '  %sThis machine listens on the source port and forwards into the server.%s\n' "$C_DIM" "$C_RESET"
        fi
        ask "Source Port" "$sshport"; sport="$REPLY"
        [[ "$EOF_REACHED" == "1" ]] && return 1
        ask "Destination Port" "$sport"; dport="$REPLY"
        [[ "$EOF_REACHED" == "1" ]] && return 1

        for p in "$sport" "$dport"; do
            if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
                err "Invalid port: $p"; return 1
            fi
        done
    fi

    printf '\n%sStep %d — Review%s\n' "$C_BOLD" "$([[ -n "$dir" ]] && echo 5 || echo 4)" "$C_RESET"
    printf '  host:        %s\n' "$host"
    printf '  user:        %s\n' "$user"
    printf '  ssh port:    %s\n' "$sshport"
    printf '  description: %s\n' "${desc:-(none)}"
    printf '  ssh params:  %s\n' "$params"
    if [[ -n "$dir" ]]; then
        printf '  source port: %s\n' "$sport"
        printf '  dest port:   %s\n' "$dport"
        printf '  ssh -p %s %s -%s %s:%s:%s %s@%s\n' \
            "$sshport" "$params" "$dir" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    fi
    ask "Save? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_HOST "$host"
    cfg_set LAST_USER "$user"
    cfg_set LAST_SSH_PORT "$sshport"

    local slug; slug="$(save_server "$host" "$user" "$sshport" "$params" "$desc")"
    ok "Server registered: $user@$host:$sshport"
    log_write "Server registered: $user@$host:$sshport (${desc:-(no description)})"
    # A tunnel recorded for this server before it was registered becomes
    # visible again now that the server exists.
    attach_orphans "$slug" "$host" "$sshport"

    # Registering a server from a tunnel menu also creates the tunnel, so
    # the forward the user asked for actually exists.
    if [[ -n "$dir" ]]; then
        cfg_set LAST_SOURCE_PORT "$sport"
        cfg_set LAST_DEST_PORT "$dport"
        local tslug; tslug="$(save_tunnel "$slug" "$host" "$user" "$sport" "$dport" "$sshport" "$params" "$desc")"
        open_tunnel "$tslug" "$host" "$user" "$sport" "$dport" "$dir" "$sshport"
    fi
}

# Tier 2 — create a tunnel on an already-registered server.
add_tunnel_form() {
    local sslug="$1" host="$2" user="$3" sshport="$4" params="$5" desc="$6" dir="$7"
    printf '\n%s── Create Tunnel on %s ──%s\n' "$C_BOLD" "$host" "$C_RESET"
    if [[ "$dir" == "R" ]]; then
        printf '  %sThe server listens on the source port and forwards it back here.%s\n' "$C_DIM" "$C_RESET"
    else
        printf '  %sThis machine listens on the source port and forwards into the server.%s\n' "$C_DIM" "$C_RESET"
    fi

    ask "Source Port" "$sshport"; local sport="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    ask "Destination Port" "$sport"; local dport="$REPLY"
    [[ "$EOF_REACHED" == "1" ]] && return 1

    for p in "$sport" "$dport"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then err "Invalid port: $p"; return 1; fi
    done

    printf '\n%sReview%s\n' "$C_BOLD" "$C_RESET"
    printf '  description: %s\n' "${desc:-(none)}"
    printf '  ssh -p %s %s -%s %s:%s:%s %s@%s\n' "$sshport" "$params" "$dir" "$sport" "$TARGET_HOST" "$dport" "$user" "$host"
    ask "Save? [y/N]" "y"
    [[ "$EOF_REACHED" == "1" ]] && return 1
    [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

    cfg_set LAST_SOURCE_PORT "$sport"
    cfg_set LAST_DEST_PORT "$dport"
    local slug; slug="$(save_tunnel "$sslug" "$host" "$user" "$sport" "$dport" "$sshport" "$params" "$desc")"
    log_write "Tunnel recorded: $host:$sport → $TARGET_HOST:$dport (-$dir)"
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
            5) do_delete ;;
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
    printf '  %s5%s) Delete a tunnel or server\n'          "$C_RED"    "$C_RESET"
    printf '  %s0%s) Exit\n\n'                            "$C_RED"   "$C_RESET"
}

# PIDs holding a listening socket on $1.
socket_owner_pids() {
    local port="$1"
    ss -ltnp 2>/dev/null | awk -v p="$port" '$4 ~ (":" p "$")' \
      | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# Whether a listener on $1 exists in the given address family.
#
# A WILDCARD listener counts: a socket on 0.0.0.0:P blocks a bind of
# 127.0.0.1:P, and one on [::]:P blocks [::1]:P. Only the exact address
# used to be looked for, so a wildcard holder was invisible here — the
# tool believed the port was free, ssh died on the bind, and the log held
# nothing but "Address already in use" with no hint as to who held it.
family_in_use() {
    local port="$1" family="$2"
    local -a addrs=()
    case "$family" in
        ipv4) addrs=( "127.0.0.1:${port}" "0.0.0.0:${port}" "*:${port}" ) ;;
        ipv6) addrs=( "[::1]:${port}" "[::]:${port}" "*:${port}" ) ;;
        *) return 1 ;;
    esac
    local a
    for a in "${addrs[@]}"; do
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qxF "$a" && return 0
    done
    return 1
}

init_state() {
    mkdir -p "$DIGGERSH_HOME" "$SERVER_DIR" "$TUNNEL_DIR" 2>/dev/null || true
    chmod 700 "$DIGGERSH_HOME" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"
    log_write "=== DiggerSSH v$VERSION started ==="
}

# A tunnel record whose server is not registered is an ORPHAN. It is kept
# and listed, never silently dropped, and it does NOT appear under any
# server.
#
# Older versions had no server tier, so old records arrive without one.
# They are deliberately NOT given a server automatically: doing that would
# resurrect a server the user had just deleted, and the server list must
# mean exactly what is on disk. Registering the server again re-attaches
# its orphans (see add_server_form).
attach_orphans() {
    local sslug="$1" host="$2" sshport="$3"
    local f slug sslug2 host2 sshport2
    for f in "$TUNNEL_DIR"/*.tunnel; do
        [[ -f "$f" ]] || continue
        sslug2="$(grep -m1 '^SERVER='      "$f" | cut -d'=' -f2-)"
        [[ -z "$sslug2" ]] || continue          # already has a server
        host2="$(grep -m1 '^HOST='             "$f" | cut -d'=' -f2-)"
        sshport2="$(grep -m1 '^SSH_PORT='       "$f" | cut -d'=' -f2-)"
        [[ -n "$sshport2" ]] || sshport2="22"
        [[ "$host2" == "$host" ]] || continue
        [[ "$sshport2" == "$sshport" ]] || continue
        local tmp="$f.attach.$$"
        {
            printf 'SERVER=%s\n' "$sslug"
            grep -v '^SERVER=' "$f"
        } > "$tmp"
        mv "$tmp" "$f"
        ok "Re-attached the tunnel for $host:$sshport to this server."
    done
}

init_state
main_menu
