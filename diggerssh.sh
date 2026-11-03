#!/usr/bin/env bash
#
# DiggerSSH — SSH Tunnel Manager
#
# Two menus:
#   1) Create Tunnel  — provision key, collect connection details, establish tunnel
#   2) Connect Tunnel  — re-establish a previously saved tunnel
#
# Key material: ML-DSA-65 (post-quantum) when the local OpenSSH supports it,
# with automatic fallback to the best available modern key type.
#
set -uo pipefail

VERSION="1.0.0"
SCRIPT_NAME="DiggerSSH"

# ---------------------------------------------------------------- paths -----
DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
TUNNEL_DIR="$DIGGERSH_HOME/tunnels"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
SSH_DIR="$HOME/.ssh"
PREF_KEY="$SSH_DIR/id_mldsa65"

# -------------------------------------------------------------- colours -----
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""
fi

# ------------------------------------------------------------- logging ------
log() {
  local msg="$*"
  mkdir -p "$DIGGERSH_HOME" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info()  { printf '%s[+]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '%s[✗]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# -------------------------------------------------------------- helpers -----
require_cmds() {
  local missing=()
  for c in ssh ssh-keygen; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Required command(s) not found: ${missing[*]}"
  fi
}

init_home() {
  mkdir -p "$DIGGERSH_HOME" "$TUNNEL_DIR" "$SSH_DIR"
  chmod 700 "$SSH_DIR" 2>/dev/null || true
  [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
}

# Read a config value; usage: cfg_get KEY [DEFAULT]
cfg_get() {
  local key="$1" default="${2:-}" val=""
  if [[ -f "$CONFIG_FILE" ]]; then
    val="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
  fi
  printf '%s' "${val:-$default}"
}

# Write a config value (replacing any existing line)
cfg_set() {
  local key="$1" value="$2"
  init_home
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep -vE "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# Ask a question with an optional default. Answer goes to global REPLY.
# On EOF (e.g. piped/non-interactive input exhausted) set EOF_REACHED so the
# caller can bail out instead of looping forever on the default answer.
EOF_REACHED=0
ask() {
  local prompt="$1" default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    printf '%s%s%s [%s]: ' "$C_CYAN" "$prompt" "$C_RESET" "$default" >&2
  else
    printf '%s%s%s: ' "$C_CYAN" "$prompt" "$C_RESET" >&2
  fi
  # Read from stdin; keep the prompt on stderr so it shows even when stdin is piped.
  if ! IFS= read -r answer; then
    answer=""
    EOF_REACHED=1
  fi
  REPLY="${answer:-$default}"
}

ask_required() {
  local prompt="$1" default="${2:-}"
  while true; do
    ask "$prompt" "$default"
    [[ "$EOF_REACHED" == "1" ]] && { REPLY=""; return 1; }
    [[ -n "$REPLY" ]] && break
    warn "This field is required."
  done
  return 0
}

# ------------------------------------------------------ key type detect -----
# Determine which key types the *local* ssh-keygen supports, and which one
# we should use. Preference order: ML-DSA-65 > ML-DSA (any) > ed25519.
#
# Upstream OpenSSH only exposes the *composite* "mldsa44-ed25519" type, and
# only from v10.4. Standalone "ml-dsa-65" exists in the OQS-OpenSSH fork and
# in the draft-sfluhrer-ssh-mldsa IETF draft. We probe rather than assume.

KEY_TYPE=""

ssh_keygen_supports() {
  local type="$1" tmpdir
  tmpdir="$(mktemp -d)" || return 1
  # ssh-keygen prints an error and exits non-zero for unknown types.
  if ssh-keygen -t "$type" -N "" -C "diggerssh-probe" -f "$tmpdir/probe" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; return 0
  fi
  rm -rf "$tmpdir"; return 1
}

detect_key_type() {
  # Probe candidates in order of preference.
  local candidates=("ml-dsa-65" "ssh-mldsa-65" "mldsa65" "mldsa-44-ed25519" "mldsa44-ed25519" "ed25519")
  local c
  for c in "${candidates[@]}"; do
    if ssh_keygen_supports "$c"; then
      KEY_TYPE="$c"
      return 0
    fi
  done
  KEY_TYPE=""
  return 1
}

# Human label for the active key type
key_type_label() {
  case "$KEY_TYPE" in
    "ml-dsa-65"|"ssh-mldsa-65"|"mldsa65") printf 'ML-DSA-65 (post-quantum)' ;;
    "mldsa-44-ed25519"|"mldsa44-ed25519")   printf 'ML-DSA-44 + Ed25519 (post-quantum composite)' ;;
    "ed25519")                             printf 'Ed25519' ;;
    *)                                     printf '%s' "${KEY_TYPE:-unknown}" ;;
  esac
}

# Public key file for the active type
pubkey_path() {
  case "$KEY_TYPE" in
    "ml-dsa-65"|"ssh-mldsa-65"|"mldsa65") printf '%s' "$PREF_KEY" ;;
    "mldsa-44-ed25519"|"mldsa44-ed25519") printf '%s' "$SSH_DIR/id_mldsa44_ed25519" ;;
    "ed25519")                             printf '%s' "$SSH_DIR/id_ed25519" ;;
    *)                                     printf '%s' "$PREF_KEY" ;;
  esac
}

# ------------------------------------------------------ key management ------
# Ensure a usable keypair of the detected type exists. Returns 0 on success.
ensure_key() {
  detect_key_type || { err "No usable key type found in this ssh-keygen."; return 1; }

  local pub; pub="$(pubkey_path)"
  local priv="${pub}"

  # If a key of the right type already exists, reuse it.
  if [[ -f "$priv" && -f "$pub" ]]; then
    local existing_type
    existing_type="$(ssh-keygen -l -f "$pub" 2>/dev/null | awk '{print $4}')"
    if [[ -n "$existing_type" ]] && key_matches_type "$existing_type"; then
      ok "Using existing key: $(basename "$pub") ($(key_type_label))"
      return 0
    fi
  fi

  # Otherwise create one, without a passphrase, directly in ~/.ssh/
  info "Generating new key: $(key_type_label) (no passphrase) -> $priv"
  if ssh-keygen -t "$KEY_TYPE" -N "" -C "diggerssh@$(hostname)" -f "$priv" >/dev/null 2>&1; then
    chmod 600 "$priv" 2>/dev/null || true
    chmod 644 "$pub"  2>/dev/null || true
    ok "Key created: $pub"
    log "generated key type=$KEY_TYPE path=$priv"
    return 0
  fi

  err "Failed to generate key of type $KEY_TYPE"
  return 1
}

# Does an ssh-keygen fingerprint label correspond to the active KEY_TYPE?
key_matches_type() {
  local label="$1"
  case "$KEY_TYPE" in
    "ml-dsa-65"|"ssh-mldsa-65"|"mldsa65")
      [[ "$label" == *"ML-DSA-65"* || "$label" == *"MLDSA65"* || "$label" == *"ML-DSA-65"* ]] ;;
    "mldsa-44-ed25519"|"mldsa44-ed25519")
      [[ "$label" == *"MLDSA44"* || "$label" == *"ML-DSA-44"* ]] ;;
    "ed25519")
      [[ "$label" == *"ED25519"* || "$label" == *"ECDSA"* || "$label" == *"RSA"* ]] ;;
    *) return 0 ;;
  esac
}

# --------------------------------------------------- tunnel management ------
tunnel_id() {
  # Stable id from host/user/port triple
  printf '%s' "$1-$2-$3" | tr '/: ' '___' | tr -cd '[:alnum:]_.-'
}

save_tunnel() {
  local id="$1" host="$2" user="$3" sport="$4" dport="$5" sshport="$6" key="$7"
  local f="$TUNNEL_DIR/$id.conf"
  {
    printf 'ID=%s\n' "$id"
    printf 'HOST=%s\n' "$host"
    printf 'USER=%s\n' "$user"
    printf 'SOURCE_PORT=%s\n' "$sport"
    printf 'DEST_PORT=%s\n' "$dport"
    printf 'SSH_PORT=%s\n' "$sshport"
    printf 'KEY=%s\n' "$key"
    printf 'CREATED=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$f"
  chmod 600 "$f" 2>/dev/null || true
}

list_tunnels() {
  local f
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    printf '%s\t%s\t%s\t%s:%s -> %s:%s\tssh-port=%s\n' \
      "$ID" "$HOST" "$USER" "$HOST" "$SOURCE_PORT" "$HOST" "$DEST_PORT" "$SSH_PORT"
  done
}

# ------------------------------------------------------------- ssh probe ----
# Test whether pubkey auth works for host/user/port using the given key.
# Returns: 0 = key auth OK, 1 = failed
try_pubkey_auth() {
  local host="$1" user="$2" sshport="$3" key="$4"
  local out
  out="$(ssh -p "$sshport" -i "$key" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      -o PasswordAuthentication=no \
      -o PreferredAuthentications=publickey \
      "$user@$host" 'echo __DIGGERSSH_AUTH_OK__' 2>&1)"
  [[ "$out" == *"__DIGGERSSH_AUTH_OK__"* ]]
}

# Copy our public key onto the remote server's authorized_keys, using an
# interactive password login. Returns 0 on success.
install_pubkey_remote() {
  local host="$1" user="$2" sshport="$3" key="$4" pub="$5"
  local pubdata
  pubdata="$(cat "$pub")"

  info "Authenticating with password to install the public key..."
  ssh -p "$sshport" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=15 \
      -o PreferredAuthentications=password,keyboard-interactive \
      "$user@$host" \
      "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && grep -qF '$pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$pubdata' >> ~/.ssh/authorized_keys"
}

# --------------------------------------------------------------- tunnels ----
# Start the SSH tunnel. Runs ssh in the background with -N (no command).
start_tunnel() {
  local host="$1" user="$2" sport="$3" dport="$4" sshport="$5" key="$6"
  local id="$7"
  local pidfile="$TUNNEL_DIR/$id.pid"
  local logfile="$TUNNEL_DIR/$id.log"

  # Refuse if the local port is already bound.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
    err "Local port $sport is already in use."
    return 1
  fi

  # ExitOnForwardFailure makes ssh fail fast instead of hanging.
  nohup ssh -N -f \
    -p "$sshport" \
    -i "$key" \
    -o IdentitiesOnly=yes \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -L "${sport}:127.0.0.1:${dport}" \
    "$user@$host" > "$logfile" 2>&1

  sleep 1
  local pid
  pid="$(pgrep -f "ssh -N -f -p $sshport.*-L ${sport}:127.0.0.1:${dport}" 2>/dev/null | head -1)"
  if [[ -n "$pid" ]]; then
    echo "$pid" > "$pidfile"
    return 0
  fi
  # ssh -f may have forked; fall back to checking the listening socket.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
    return 0
  fi
  err "Tunnel failed to start. Log:"
  [[ -f "$logfile" ]] && sed 's/^/    /' "$logfile"
  return 1
}

stop_tunnel() {
  local id="$1"
  local pidfile="$TUNNEL_DIR/$id.pid"
  if [[ -f "$pidfile" ]]; then
    local pid; pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      ok "Tunnel stopped (pid $pid)."
    fi
    rm -f "$pidfile"
  fi
}

tunnel_running() {
  local id="$1"
  local pidfile="$TUNNEL_DIR/$id.pid"
  [[ -f "$pidfile" ]] || return 1
  local pid; pid="$(cat "$pidfile")"
  kill -0 "$pid" 2>/dev/null
}

# ============================================================== MENU 1 =======
create_tunnel() {
  printf '\n%s%s── Create Tunnel ──%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  # --- Step 1: key material ---------------------------------------------
  printf '\n%sStep 1 — Key material%s\n' "$C_BOLD" "$C_RESET"
  if ! ensure_key; then
    err "Cannot continue without a usable SSH key."
    return 1
  fi

  local key pub
  key="$(pubkey_path)"; pub="${key}.pub"

  # --- Step 2: connection details ---------------------------------------
  printf '\n%sStep 2 — Connection details%s\n' "$C_BOLD" "$C_RESET"

  local last_host last_user
  last_host="$(cfg_get LAST_HOST "")"
  last_user="$(cfg_get LAST_USER "")"

  ask_required "Server IP Address/Domain Name" "$last_host"; local host="$REPLY"
  [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
  ask_required "SSH Username" "$last_user";              local user="$REPLY"
  [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
  ask "Source Port" "";                                 local sport="$REPLY"
  [[ -n "$sport" ]] || sport="22"
  ask "Destination Port" "$sport";                      local dport="$REPLY"
  ask "SSH Port" "22";                                  local sshport="$REPLY"

  # Validate numeric ports
  for p in "$sport" "$dport" "$sshport"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
      err "Invalid port number: $p"
      return 1
    fi
  done

  # --- Step 3: confirm ---------------------------------------------------
  printf '\n%sStep 3 — Review%s\n' "$C_BOLD" "$C_RESET"
  printf '  Server        : %s\n' "$host"
  printf '  Username     : %s\n' "$user"
  printf '  Source port  : %s (localhost)\n' "$sport"
  printf '  Dest port    : %s (on %s)\n' "$dport" "$host"
  printf '  SSH port     : %s\n' "$sshport"
  printf '  Key          : %s (%s)\n' "$(basename "$pub")" "$(key_type_label)"
  printf '\n'
  ask "Submit? [y/N]" "y"
  [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

  # Remember last used values for next time.
  cfg_set LAST_HOST "$host"
  cfg_set LAST_USER "$user"

  # --- Step 4: authenticate & create ------------------------------------
  printf '\n%sStep 4 — Establishing tunnel%s\n' "$C_BOLD" "$C_RESET"

  info "Testing public-key authentication to $user@$host:$sshport ..."
  if try_pubkey_auth "$host" "$user" "$sshport" "$key"; then
    ok "Public-key authentication succeeded."
  else
    warn "Public-key authentication failed."
    printf '\n%sThe server does not yet trust our %s key.%s\n' "$C_YELLOW" "$(key_type_label)" "$C_RESET"
    printf 'Attempting password login to install the public key...\n\n'

    if install_pubkey_remote "$host" "$user" "$sshport" "$key" "$pub"; then
      ok "Public key installed on the server."
      info "Re-testing public-key authentication ..."
      if try_pubkey_auth "$host" "$user" "$sshport" "$key"; then
        ok "Public-key authentication now works."
      else
        warn "Key installed, but authentication still fails."
      fi
    else
      warn "Password login / key installation failed."
    fi

    if ! try_pubkey_auth "$host" "$user" "$sshport" "$key"; then
      printf '\n%sManual step required.%s\n\n' "$C_BOLD" "$C_RESET"
      printf 'Please log in to the server yourself and add this public key:\n\n'
      printf '    %s\n\n' "$(cat "$pub")"
      printf 'To:\n'
      printf '    %s@%s:~/.ssh/authorized_keys\n\n' "$user" "$host"
      printf 'On the server run:\n'
      printf '    mkdir -p ~/.ssh && chmod 700 ~/.ssh\n'
      printf '    echo %s >> ~/.ssh/authorized_keys\n' "$(cat "$pub")"
      printf '    chmod 600 ~/.ssh/authorized_keys\n\n'
      ask "Press Enter once you have finished (or type 'skip' to abort)" ""
      if [[ "${REPLY,,}" == "skip" ]]; then
        err "Aborted by user."
        return 1
      fi
      info "Re-testing public-key authentication ..."
      if ! try_pubkey_auth "$host" "$user" "$sshport" "$key"; then
        err "Authentication still failing — aborting."
        return 1
      fi
      ok "Public-key authentication works now."
    fi
  fi

  # --- Step 5: start the tunnel -----------------------------------------
  local id
  id="$(tunnel_id "$host" "$user" "$sport")"

  info "Starting tunnel: localhost:$sport -> $host:$dport"
  if start_tunnel "$host" "$user" "$sport" "$dport" "$sshport" "$key" "$id"; then
    save_tunnel "$id" "$host" "$user" "$sport" "$dport" "$sshport" "$key"
    ok "Tunnel established."
    printf '\n  %sLocal:%s http://localhost:%s  ->  %s:%s%s\n' \
      "$C_GREEN" "$C_RESET" "$sport" "$host" "$dport" "$C_RESET"
    printf '  %sSaved as:%s %s\n\n' "$C_GREEN" "$C_RESET" "$id"
    log "tunnel created id=$id host=$host user=$user sport=$sport dport=$dport"
    return 0
  fi

  err "Could not establish the tunnel."
  return 1
}

# ============================================================== MENU 2 =======
connect_tunnel() {
  printf '\n%s%s── Connect Tunnel ──%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  local found=0 f
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    found=1; break
  done

  if (( found == 0 )); then
    warn "No saved tunnels yet. Use 'Create Tunnel' first."
    return 0
  fi

  printf '\n%sSaved tunnels:%s\n' "$C_BOLD" "$C_RESET"
  local idx=0 line id status
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    idx=$((idx+1))
    # shellcheck disable=SC1090
    source "$f"
    if tunnel_running "$ID"; then status="${C_GREEN}running${C_RESET}"; else status="${C_YELLOW}stopped${C_RESET}"; fi
    printf '  %2d) %s  %s@%s  %s:%s -> :%s  [%s]\n' \
      "$idx" "$ID" "$USER" "$HOST" "$HOST" "$SOURCE_PORT" "$DEST_PORT" "$status"
  done
  printf '\n'

  ask "Select tunnel number" "1"
  local choice="$REPLY"
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Invalid selection."; return 1; }

  idx=0
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    idx=$((idx+1))
    [[ "$idx" == "$choice" ]] || continue
    # shellcheck disable=SC1090
    source "$f"

    if tunnel_running "$ID"; then
      ok "Tunnel '$ID' is already running (pid $(cat "$TUNNEL_DIR/$ID.pid"))."
      return 0
    fi

    # Ensure key still present
    if [[ ! -f "$KEY" ]]; then
      warn "Key file $KEY is missing; regenerating..."
      ensure_key || { err "Could not regenerate key."; return 1; }
      KEY="$(pubkey_path)"
    fi

    info "Connecting to $USER@$HOST:$SSH_PORT ..."
    if ! try_pubkey_auth "$HOST" "$USER" "$SSH_PORT" "$KEY"; then
      warn "Public-key authentication failed for $USER@$HOST."
      if install_pubkey_remote "$HOST" "$USER" "$SSH_PORT" "$KEY" "${KEY}.pub"; then
        ok "Public key installed on the server."
        try_pubkey_auth "$HOST" "$USER" "$SSH_PORT" "$KEY" || warn "Still failing — you may need to add the key manually."
      else
        warn "Password login failed."
      fi
      if ! try_pubkey_auth "$HOST" "$USER" "$SSH_PORT" "$KEY"; then
        printf '\nAdd this key to %s@%s:~/.ssh/authorized_keys manually, then press Enter.\n\n' "$USER" "$HOST"
        printf '    %s\n\n' "$(cat "${KEY}.pub" 2>/dev/null)"
        ask "Press Enter when done (or 'skip' to abort)" ""
        [[ "${REPLY,,}" == "skip" ]] && { err "Aborted."; return 1; }
        try_pubkey_auth "$HOST" "$USER" "$SSH_PORT" "$KEY" || { err "Authentication failing."; return 1; }
      fi
    fi

    if start_tunnel "$HOST" "$USER" "$SOURCE_PORT" "$DEST_PORT" "$SSH_PORT" "$KEY" "$ID"; then
      ok "Tunnel connected."
      printf '  %sLocal:%s localhost:%s  ->  %s:%s%s\n\n' \
        "$C_GREEN" "$C_RESET" "$SOURCE_PORT" "$HOST" "$DEST_PORT" "$C_RESET"
      log "tunnel connected id=$ID"
      return 0
    fi
    err "Could not start tunnel."
    return 1
  done

  err "Tunnel #$choice not found."
  return 1
}

# ============================================================ MAIN MENU =====
main_menu() {
  while true; do
    printf '\n%s%s╔══════════════════════════════════════╗%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '%s%s║%s  %s%-10s%s%s v%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "DiggerSSH" "$C_RESET" "$C_RESET" "$VERSION" "$C_RESET"
    printf '%s%s╚══════════════════════════════════════╝%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '  %s1%s) Create Tunnel\n' "$C_GREEN" "$C_RESET"
    printf '  %s2%s) Connect Tunnel\n' "$C_GREEN" "$C_RESET"
    printf '  %s3%s) List tunnels\n'   "$C_GREEN" "$C_RESET"
    printf '  %s4%s) Stop a tunnel\n'  "$C_GREEN" "$C_RESET"
    printf '  %s0%s) Exit\n'            "$C_GREEN" "$C_RESET"
    printf '\n'
    ask "Choose an option" "1"
    if [[ "$EOF_REACHED" == "1" ]]; then
      printf '\n%sEnd of input — exiting.%s\n' "$C_CYAN" "$C_RESET"
      exit 0
    fi
    case "$REPLY" in
      1) create_tunnel ;;
      2) connect_tunnel ;;
      3)
        printf '\n%sSaved tunnels:%s\n' "$C_BOLD" "$C_RESET"
        if [[ -n "$(list_tunnels)" ]]; then list_tunnels; else warn "None yet."; fi
        printf '\n'
        ;;
      4)
        printf '\n'
        if [[ -z "$(list_tunnels)" ]]; then warn "No saved tunnels."; else
          list_tunnels
          ask "Tunnel ID to stop" ""
          if [[ -n "$REPLY" ]]; then stop_tunnel "$REPLY"; fi
        fi
        printf '\n'
        ;;
      0|"q"|"Q") printf '\n%sBye.%s\n' "$C_CYAN" "$C_RESET"; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# ---------------------------------------------------------------- main ------
main() {
  require_cmds
  init_home
  log "=== DiggerSSH v$VERSION started ==="
  # Show what key type this system can use, once, at startup.
  if detect_key_type; then
    printf '%sKey type available:%s %s\n' "$C_CYAN" "$C_RESET" "$(key_type_label)"
  else
    warn "Could not determine a usable key type."
  fi
  main_menu
}

main "$@"
