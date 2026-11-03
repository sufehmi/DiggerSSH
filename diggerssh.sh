#!/usr/bin/env bash
#
# DiggerSSH — SSH Tunnel Manager
#
# Menus:
#   1) Create Tunnel  — provision key, collect connection details, establish tunnel
#   2) Connect Tunnel  — re-establish a saved tunnel, or one registered on a server
#   3) List tunnels
#   4) Stop a tunnel
#
# Key material: ML-DSA-65 (post-quantum) when both client and server support
# it, otherwise automatic fallback down the chain
#   ML-DSA-65 -> ML-DSA-44+Ed25519 -> Ed25519 -> ECDSA.
#
# Transport: autossh when available (keeps the tunnel alive across network
# drops), plain ssh otherwise.
#
set -uo pipefail

VERSION="1.1.0"
SCRIPT_NAME="DiggerSSH"

# ---------------------------------------------------------------- paths -----
DIGGERSH_HOME="${DIGGERSH_HOME:-$HOME/.diggerssh}"
CONFIG_FILE="$DIGGERSH_HOME/config"
TUNNEL_DIR="$DIGGERSH_HOME/tunnels"
LOG_FILE="$DIGGERSH_HOME/diggerssh.log"
SSH_DIR="$HOME/.ssh"

# Remote registry: where a server records the tunnels currently pointed at it.
REMOTE_REGISTRY_DIR=".diggerssh"

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
  local missing=() c
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
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
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

# ======================================================== key type chain =====
# Ordered fallback chain. Each level is:
#   wire-algo|human label|fingerprint fragment|ssh-keygen spellings|file base
#
# The chain is walked from the top. A level is usable only when BOTH the local
# ssh-keygen can produce the key AND the server accepts the wire algorithm.
#
#   1. ML-DSA-65            standalone, post-quantum (OQS-OpenSSH / IETF draft)
#   2. ML-DSA-44 + Ed25519  composite, upstream OpenSSH 10.4+
#   3. Ed25519              universal
#   4. ECDSA (NIST P-256)   last resort
KEY_CHAIN=(
  "ssh-mldsa-65|ML-DSA-65 (post-quantum)|MLDSA-65|ml-dsa-65,ssh-mldsa-65,mldsa65,mldsa-65|id_mldsa65"
  "ssh-mldsa44-ed25519@openssh.com|ML-DSA-44 + Ed25519 (post-quantum composite)|MLDSA44|mldsa-44-ed25519,mldsa44-ed25519|id_mldsa44_ed25519"
  "ssh-ed25519|Ed25519|ED25519|ed25519|id_ed25519"
  "ecdsa-sha2-nistp256|ECDSA (NIST P-256)|ECDSA|ecdsa|id_ecdsa"
)

CHAIN_INDEX=0     # index into KEY_CHAIN of the level currently selected
KEY_TYPE=""       # ssh-keygen spelling, e.g. "ssh-mldsa-65"
KEY_ALGO=""       # wire algorithm, e.g. "ssh-mldsa-65"
KEY_LABEL=""      # human label
KEY_FRAGMENT=""   # fingerprint fragment to match an existing key
KEY_BASE=""       # key file base name, e.g. "id_mldsa65"

ssh_keygen_supports() {
  local type="$1" tmpdir
  tmpdir="$(mktemp -d)" || return 1
  # ssh-keygen prints an error and exits non-zero for unknown types.
  if ssh-keygen -t "$type" -N "" -C "diggerssh-probe" -f "$tmpdir/probe" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; return 0
  fi
  rm -rf "$tmpdir"; return 1
}

# Pull one field out of a chain level.
chain_field() {
  local idx="$1" field="$2"
  local -a parts
  local IFS='|'
  read -r -a parts <<< "${KEY_CHAIN[$idx]}"
  printf '%s' "${parts[$field]}"
}

# Select a chain level, trying each ssh-keygen spelling it lists.
# Returns 0 when a usable spelling was found.
select_chain_level() {
  local idx="$1"
  local spellings algo label fragment base s
  spellings="$(chain_field "$idx" 3)"
  algo="$(chain_field "$idx" 0)"
  label="$(chain_field "$idx" 1)"
  fragment="$(chain_field "$idx" 2)"
  base="$(chain_field "$idx" 4)"

  for s in ${spellings//,/ }; do
    if ssh_keygen_supports "$s"; then
      CHAIN_INDEX="$idx"
      KEY_TYPE="$s"
      KEY_ALGO="$algo"
      KEY_LABEL="$label"
      KEY_FRAGMENT="$fragment"
      KEY_BASE="$base"
      return 0
    fi
  done
  return 1
}

# Pick the best key type this machine can produce.
detect_key_type() {
  local i
  for i in "${!KEY_CHAIN[@]}"; do
    if select_chain_level "$i"; then
      return 0
    fi
  done
  KEY_TYPE=""; KEY_ALGO=""; KEY_LABEL=""; KEY_FRAGMENT=""; KEY_BASE=""
  return 1
}

# Path of the private key for the active level.
pubkey_path() {
  printf '%s' "$SSH_DIR/${KEY_BASE:-id_mldsa65}"
}

# Does an ssh-keygen fingerprint label belong to the active level?
# Fingerprint labels are hyphenated short names: "MLDSA-65", "MLDSA44-ED25519",
# "ED25519", "ECDSA" — not the spellings accepted by -t.
key_matches_type() {
  local label="${1^^}"
  [[ -n "$KEY_FRAGMENT" ]] || return 0
  [[ "$label" == *"$KEY_FRAGMENT"* ]]
}

# Record the active key type in the config file so it survives across runs.
# KEY_FALLBACK_NOTE states in plain words which level was chosen and why the
# stronger ones were not used, so the config explains itself without needing
# the script's source.
note_key_type() {
  cfg_set KEY_TYPE "$KEY_TYPE"
  cfg_set KEY_ALGORITHM "$KEY_ALGO"
  cfg_set KEY_LABEL "$KEY_LABEL"
  cfg_set KEY_LEVEL "$CHAIN_INDEX"
  cfg_set KEY_FILE "$SSH_DIR/${KEY_BASE:-id_mldsa65}"
  cfg_set KEY_UPDATED "$(date '+%Y-%m-%d %H:%M:%S')"

  local note
  case "$CHAIN_INDEX" in
    0) note="ML-DSA-65 in use (post-quantum); no fallback needed" ;;
    1) note="fell back to ML-DSA-44 + Ed25519 composite: ML-DSA-65 unavailable in the ssh client or rejected by the server" ;;
    2) note="fell back to Ed25519: ML-DSA-65 and ML-DSA-44 composite unavailable in the ssh client or rejected by the server" ;;
    3) note="fell back to ECDSA (NIST P-256): no stronger key type available in the ssh client or accepted by the server" ;;
    *) note="fell back to $KEY_LABEL (chain level $CHAIN_INDEX)" ;;
  esac
  cfg_set KEY_FALLBACK_NOTE "$note"
}

# Ensure a usable keypair of the active level exists. Returns 0 on success.
ensure_key() {
  detect_key_type || { err "No usable key type found in this ssh-keygen."; return 1; }

  local priv pub
  priv="$(pubkey_path)"
  pub="${priv}.pub"

  # If a key of the right type already exists, reuse it.
  if [[ -f "$priv" && -f "$pub" ]]; then
    local existing_type
    existing_type="$(ssh-keygen -l -f "$pub" 2>/dev/null | awk '{print $4}')"
    if [[ -n "$existing_type" ]] && key_matches_type "$existing_type"; then
      # Repair permissions: ssh refuses to use a private key that is
      # group/world readable, so make sure it is locked down.
      chmod 600 "$priv" 2>/dev/null || true
      ok "Using existing key: $(basename "$pub") ($KEY_LABEL)"
      return 0
    fi
  fi

  # Otherwise create one, without a passphrase, directly in ~/.ssh/
  info "Generating new key: $KEY_LABEL (no passphrase) -> $priv"
  if ssh-keygen -t "$KEY_TYPE" -N "" -C "diggerssh@$(hostname)" -f "$priv" >/dev/null 2>&1; then
    chmod 600 "$priv" 2>/dev/null || true
    chmod 644 "$pub"  2>/dev/null || true
    ok "Key created: $pub"
    log "generated key type=$KEY_TYPE algo=$KEY_ALGO path=$priv"
    return 0
  fi

  err "Failed to generate key of type $KEY_TYPE"
  return 1
}

# -------------------------------------------------- server capability probe --
# Ask the server which signature algorithms it accepts for public-key auth.
# ssh prints the list during key exchange, before authentication, so this
# works even when we cannot yet log in.
server_sig_algs() {
  local host="$1" user="$2" sshport="$3"
  ssh -v -p "$sshport" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -o PasswordAuthentication=no \
      -o PreferredAuthentications=publickey \
      "$user@$host" true 2>&1 </dev/null \
    | sed -n 's/.*server-sig-algs=<\([^>]*\)>.*/\1/p' | head -1
}

# Does the server's advertised algorithm list contain the given algorithm?
server_supports_algo() {
  local algos="$1" algo="$2"
  [[ -n "$algos" ]] || return 0     # could not probe -> do not second-guess
  [[ ",$algos," == *",$algo,"* ]]
}

# Walk down the chain until the server accepts our algorithm. The client must
# be able to produce the key AND the server must accept the wire algorithm.
negotiate_key_type() {
  local host="$1" user="$2" sshport="$3"
  local algos guard=0
  algos="$(server_sig_algs "$host" "$user" "$sshport")"

  if [[ -z "$algos" ]]; then
    log "key negotiation: could not probe server algorithms, keeping $KEY_TYPE"
    return 0
  fi

  while ! server_supports_algo "$algos" "$KEY_ALGO"; do
    if (( CHAIN_INDEX + 1 >= ${#KEY_CHAIN[@]} )); then
      err "The server accepts none of the key types DiggerSSH can use."
      return 1
    fi
    warn "Server does not accept $KEY_ALGO — falling back to the next key type."
    log "key negotiation: server rejected $KEY_ALGO, downgrading chain level $CHAIN_INDEX -> $((CHAIN_INDEX+1))"
    if ! select_chain_level "$((CHAIN_INDEX + 1))"; then
      err "No usable key type at the next fallback level."
      return 1
    fi
    if ! ensure_key; then
      err "Could not prepare a key for the fallback level."
      return 1
    fi
    build_extra_ssh_opts
    guard=$((guard + 1))
    (( guard > ${#KEY_CHAIN[@]} )) && { err "Key negotiation did not converge."; return 1; }
  done
  return 0
}

# --------------------------------------------------- extra ssh options -------
# A client only offers a key whose signature algorithm is in its
# PubkeyAcceptedAlgorithms list. The OQS-OpenSSH build knows the standalone
# ML-DSA algorithms but does NOT enable them by default, so they must be
# requested explicitly. Stock OpenSSH does not know them at all and refuses
# to start with "Bad key types" if they are named — so the option is only ever
# added when the local ssh genuinely supports it.
#
# The same applies to the server's host key: a post-quantum-only server needs
# its host algorithm enabled on the client side too.
SSH_EXTRA_OPTS=()

build_extra_ssh_opts() {
  SSH_EXTRA_OPTS=()
  [[ -n "$KEY_ALGO" ]] || return 0

  local algo="$KEY_ALGO" known
  known="$(ssh -Q PubkeyAcceptedAlgorithms 2>/dev/null)"

  # Enable the signature algorithm if this ssh knows it and it is not
  # already part of the effective default.
  if printf '%s\n' "$known" | grep -qxF "$algo" \
     && ! ssh -G localhost 2>/dev/null \
          | grep -i '^pubkeyacceptedalgorithms' | grep -qiF "$algo"; then
    SSH_EXTRA_OPTS+=(-o "PubkeyAcceptedAlgorithms=+$algo")
  fi

  # Enable the matching host key algorithm, same reasoning.
  local host_known
  host_known="$(ssh -Q HostKeyAlgorithms 2>/dev/null)"
  if printf '%s\n' "$host_known" | grep -qxF "$algo" \
     && ! ssh -G localhost 2>/dev/null \
          | grep -i '^hostkeyalgorithms' | grep -qiF "$algo"; then
    SSH_EXTRA_OPTS+=(-o "HostKeyAlgorithms=+$algo")
  fi
}

# ------------------------------------------------------- autossh handling ----
AUTOSSH_BIN=""

# Detect autossh without prompting.
detect_autossh() {
  if command -v autossh >/dev/null 2>&1; then
    AUTOSSH_BIN="$(command -v autossh)"
    return 0
  fi
  AUTOSSH_BIN=""
  return 1
}

# Try to install autossh with the system package manager.
#   0 = installed   1 = no package manager   2 = needs manual sudo
try_install_autossh() {
  local mgr="" pkgs="autossh" cmd=""
  if command -v apt-get >/dev/null 2>&1;      then mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1;       then mgr="dnf"
  elif command -v yum >/dev/null 2>&1;       then mgr="yum"
  elif command -v pacman >/dev/null 2>&1;    then mgr="pacman"
  elif command -v apk >/dev/null 2>&1;       then mgr="apk"
  else return 1
  fi

  case "$mgr" in
    apt-get) cmd="apt-get install -y $pkgs" ;;
    dnf)     cmd="dnf install -y $pkgs" ;;
    yum)     cmd="yum install -y $pkgs" ;;
    pacman)  cmd="pacman -S --noconfirm $pkgs" ;;
    apk)     cmd="apk add $pkgs" ;;
  esac

  info "Attempting: $mgr install -y $pkgs"
  if [[ "$(id -u)" == "0" ]]; then
    $cmd >/dev/null 2>&1 && return 0
  elif sudo -n true 2>/dev/null; then
    sudo -n $cmd >/dev/null 2>&1 && return 0
  fi
  return 2
}

# Make sure autossh is usable. If it cannot be installed automatically, offer
# the user the chance to install it themselves and wait for them.
# Returns 0 when autossh is available, 1 when we must fall back to plain ssh.
ensure_autossh() {
  [[ -n "$AUTOSSH_BIN" ]] && return 0
  detect_autossh && return 0

  warn "autossh is not installed on this system."
  info "autossh restarts the tunnel automatically when the connection drops."

  if [[ "$EOF_REACHED" == "1" ]]; then
    warn "No interactive input available — falling back to plain ssh."
    return 1
  fi

  ask "Try to install autossh now? [y/N]" "y"
  [[ "$EOF_REACHED" == "1" ]] && { warn "Falling back to plain ssh."; return 1; }

  if [[ "${REPLY,,}" == "y" ]]; then
    try_install_autossh
    local rc=$?
    if (( rc == 0 )) && detect_autossh; then
      ok "autossh installed: $AUTOSSH_BIN"
      return 0
    fi

    # Could not install it ourselves — hand it to the user.
    printf '\n%sCould not install autossh automatically.%s\n' "$C_YELLOW" "$C_RESET"
    printf 'Please install it yourself, for example:\n\n'
    printf '    sudo apt-get install -y autossh      # Debian/Ubuntu\n'
    printf '    sudo dnf install -y autossh          # Fedora/RHEL\n'
    printf '    sudo pacman -S autossh               # Arch\n\n'
    ask "Press Enter once autossh is installed (or type 'skip' to use plain ssh)" ""
    [[ "$EOF_REACHED" == "1" ]] && { warn "Falling back to plain ssh."; return 1; }
    if [[ "${REPLY,,}" != "skip" ]] && detect_autossh; then
      ok "autossh is now available: $AUTOSSH_BIN"
      return 0
    fi
  fi

  warn "Continuing with plain ssh — the tunnel will not survive a dropped connection."
  return 1
}

# ------------------------------------------------------ tunnel management ----
tunnel_id() {
  # Stable id from host/user/port triple
  printf '%s' "$1-$2-$3" | tr '/: ' '___' | tr -cd '[:alnum:]_.-'
}

save_tunnel() {
  local id="$1" host="$2" user="$3" sport="$4" dport="$5" sshport="$6" key="$7" sshparams="${8:-}"
  local f="$TUNNEL_DIR/$id.conf"
  {
    printf 'ID=%q\n' "$id"
    printf 'HOST=%q\n' "$host"
    printf 'USER=%q\n' "$user"
    printf 'SOURCE_PORT=%q\n' "$sport"
    printf 'DEST_PORT=%q\n' "$dport"
    printf 'SSH_PORT=%q\n' "$sshport"
    printf 'KEY=%q\n' "$key"
    printf 'SSH_PARAMS=%q\n' "$sshparams"
    printf 'KEY_TYPE=%q\n' "$KEY_TYPE"
    printf 'CREATED=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$f"
  chmod 600 "$f" 2>/dev/null || true
}

list_tunnels() {
  local f
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    printf '%s\t%s\t%s\t%s:%s -> %s:%s\tssh-port=%s\tkey=%s\n' \
      "$ID" "$HOST" "$USER" "$HOST" "$SOURCE_PORT" "$HOST" "$DEST_PORT" "$SSH_PORT" "${KEY_TYPE:-?}"
  done
}

# --------------------------------------------------------------- ssh probe ---
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
      "${SSH_EXTRA_OPTS[@]}" \
      "$user@$host" 'echo __DIGGERSSH_AUTH_OK__' 2>&1 < /dev/null)"
  [[ "$out" == *"__DIGGERSSH_AUTH_OK__"* ]]
}

# Copy our public key onto the remote server's authorized_keys, using an
# interactive password login. Returns 0 on success.
install_pubkey_remote() {
  local host="$1" user="$2" sshport="$3" key="$4" pub="$5"

  info "Authenticating with password to install the public key..."

  # One ssh invocation, one password prompt. The public key is piped in on
  # stdin and never interpolated into the remote command line, so it is
  # immune to shell-quoting problems. The remote side appends it only if
  # it is not already present.
  if ssh -p "$sshport" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=15 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=3 \
      "$user@$host" \
      'umask 077; mkdir -p ~/.ssh && t=$(mktemp) && cat > "$t" && \
       if grep -qxFf "$t" ~/.ssh/authorized_keys 2>/dev/null; then rm -f "$t"; \
       else cat "$t" >> ~/.ssh/authorized_keys; rm -f "$t"; fi; \
       chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys' \
      < "$pub"; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------- remote registry -----
# The server keeps a record of the tunnels currently pointed at it, under
# ~/.diggerssh/. DiggerSSH writes an entry when a tunnel is established and
# removes it when the tunnel is stopped, so "Connect Tunnel" can enumerate
# them from the server side.
register_remote_tunnel() {
  local host="$1" user="$2" sshport="$3" key="$4" id="$5" sport="$6" dport="$7" sshparams="${8:-}"
  local content
  content="$(printf 'ID=%s\nHOST=%s\nUSER=%s\nSOURCE_PORT=%s\nDEST_PORT=%s\nSSH_PORT=%s\nKEY_TYPE=%s\nKEY_LABEL=%s\nSSH_PARAMS=%s\nCREATED=%s\n' \
    "$id" "$host" "$user" "$sport" "$dport" "$sshport" \
    "$KEY_TYPE" "$KEY_LABEL" "$sshparams" "$(date '+%Y-%m-%d %H:%M:%S')")"

  # The id is sanitised by tunnel_id() to [A-Za-z0-9_.-] only, so it is safe
  # to use as a remote file name.
  printf '%s\n' "$content" | ssh -p "$sshport" -i "$key" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${SSH_EXTRA_OPTS[@]}" \
      "$user@$host" \
      "umask 077; mkdir -p ~/$REMOTE_REGISTRY_DIR && cat > ~/$REMOTE_REGISTRY_DIR/$id.tunnel" \
      >/dev/null 2>&1
}

unregister_remote_tunnel() {
  local host="$1" user="$2" sshport="$3" key="$4" id="$5"
  ssh -p "$sshport" -i "$key" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${SSH_EXTRA_OPTS[@]}" \
      "$user@$host" "rm -f ~/$REMOTE_REGISTRY_DIR/$id.tunnel" >/dev/null 2>&1 </dev/null
}

# Read every tunnel record the server holds. One record per line, fields in a
# fixed order, separated by "|":
#   ID|HOST|USER|SOURCE_PORT|DEST_PORT|SSH_PORT|KEY_LABEL|SSH_PARAMS|CREATED
list_remote_tunnels() {
  local host="$1" user="$2" sshport="$3" key="$4"
  ssh -p "$sshport" -i "$key" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${SSH_EXTRA_OPTS[@]}" \
      "$user@$host" \
      "for f in ~/$REMOTE_REGISTRY_DIR/*.tunnel; do [ -e \"\$f\" ] || continue; echo \"@@FILE@@\"; cat \"\$f\"; done" \
      2>/dev/null </dev/null | awk -F= '
        function flush() {
          if (id != "") {
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n", id, host, user, sport, dport, sshport, label, params, created
          }
          id=host=user=sport=dport=sshport=label=params=created=""
        }
        /^@@FILE@@$/ { flush(); next }
        {
          line = $0; sub(/=.*$/, "", line)
          val  = $0; sub(/^[^=]*=/, "", val); gsub(/\r/, "", val)
          if      (line == "ID")          id = val
          else if (line == "HOST")        host = val
          else if (line == "USER")        user = val
          else if (line == "SOURCE_PORT") sport = val
          else if (line == "DEST_PORT")   dport = val
          else if (line == "SSH_PORT")    sshport = val
          else if (line == "KEY_LABEL")   label = val
          else if (line == "SSH_PARAMS")  params = val
          else if (line == "CREATED")     created = val
        }
        END { flush() }'
}

# --------------------------------------------------------------- tunnels ----
# Split a free-form parameter string into an argv array.
SSH_PARAM_OPTS=()
split_ssh_params() {
  SSH_PARAM_OPTS=()
  local raw="$1"
  [[ -n "$raw" ]] || return 0
  # shellcheck disable=SC2162
  read -r -a SSH_PARAM_OPTS <<< "$raw"
}

# Start the SSH tunnel in the background.
# Uses autossh when available so the tunnel survives a dropped connection,
# and plain ssh otherwise.
start_tunnel() {
  local host="$1" user="$2" sport="$3" dport="$4" sshport="$5" key="$6" id="$7" sshparams="${8:-}"
  local pidfile="$TUNNEL_DIR/$id.pid"
  local logfile="$TUNNEL_DIR/$id.log"

  # Refuse if the local port is already bound.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
    err "Local port $sport is already in use."
    return 1
  fi

  split_ssh_params "$sshparams"

  local -a opts=(
    -p "$sshport"
    -i "$key"
    -o IdentitiesOnly=yes
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=accept-new
  )
  if (( ${#SSH_EXTRA_OPTS[@]} )); then opts+=( "${SSH_EXTRA_OPTS[@]}" ); fi
  if (( ${#SSH_PARAM_OPTS[@]} )); then opts+=( "${SSH_PARAM_OPTS[@]}" ); fi

  # stdin is redirected from /dev/null: ssh would otherwise consume the
  # script's own stdin and swallow the user's queued menu answers.
  local -a cmd=()
  if [[ -n "$AUTOSSH_BIN" ]]; then
    # -M 0 tells autossh to rely on ssh's own liveness checks instead of
    # managing a separate control port.
    cmd=("$AUTOSSH_BIN" -M 0 -N "${opts[@]}" -L "${sport}:127.0.0.1:${dport}" "$user@$host")
    info "Transport: autossh ($AUTOSSH_BIN)"
  else
    cmd=(ssh -N "${opts[@]}" -L "${sport}:127.0.0.1:${dport}" "$user@$host")
    info "Transport: ssh"
  fi

  nohup "${cmd[@]}" > "$logfile" 2>&1 < /dev/null &
  local pid=$!
  sleep 1

  if kill -0 "$pid" 2>/dev/null; then
    echo "$pid" > "$pidfile"
    return 0
  fi
  # The tunnel may still have come up; fall back to checking the socket.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${sport}\$"; then
    echo "$pid" > "$pidfile"
    return 0
  fi
  err "Tunnel failed to start. Log:"
  [[ -f "$logfile" ]] && sed 's/^/    /' "$logfile"
  rm -f "$pidfile"
  return 1
}

stop_tunnel() {
  local id="$1"
  local pidfile="$TUNNEL_DIR/$id.pid"
  local conf="$TUNNEL_DIR/$id.conf"

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

  # autossh supervises an ssh child; make sure nothing is left behind.
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    source "$conf"
    pkill -f -- "-L ${SOURCE_PORT}:127.0.0.1:${DEST_PORT} ${USER}@${HOST}" 2>/dev/null || true
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
  ask "SSH parameters" "-o ServerAliveInterval=30 -o ServerAliveCountMax=5"; local sshparams="$REPLY"

  # Validate numeric ports
  for p in "$sport" "$dport" "$sshport"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
      err "Invalid port number: $p"
      return 1
    fi
  done

  # --- Step 3: negotiate the key type against the server ----------------
  printf '\n%sStep 3 — Key negotiation%s\n' "$C_BOLD" "$C_RESET"
  info "Checking which key types the server accepts..."
  if ! negotiate_key_type "$host" "$user" "$sshport"; then
    err "Cannot agree on a key type with the server."
    return 1
  fi
  key="$(pubkey_path)"; pub="${key}.pub"
  ok "Key type: $KEY_LABEL ($KEY_TYPE)"
  note_key_type

  # --- Step 4: confirm ---------------------------------------------------
  printf '\n%sStep 4 — Review%s\n' "$C_BOLD" "$C_RESET"
  printf '  Server        : %s\n' "$host"
  printf '  Username     : %s\n' "$user"
  printf '  Source port  : %s (localhost)\n' "$sport"
  printf '  Dest port    : %s (on %s)\n' "$dport" "$host"
  printf '  SSH port     : %s\n' "$sshport"
  printf '  SSH params   : %s\n' "$sshparams"
  printf '  Key          : %s (%s)\n' "$(basename "$pub")" "$KEY_LABEL"
  printf '\n'
  ask "Submit? [y/N]" "y"
  [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
  [[ "${REPLY,,}" == "y" ]] || { warn "Cancelled."; return 1; }

  # Remember last used values for next time.
  cfg_set LAST_HOST "$host"
  cfg_set LAST_USER "$user"
  cfg_set LAST_SSH_PORT "$sshport"

  # --- Step 5: authenticate & create ------------------------------------
  printf '\n%sStep 5 — Establishing tunnel%s\n' "$C_BOLD" "$C_RESET"

  info "Testing public-key authentication to $user@$host:$sshport ..."
  if try_pubkey_auth "$host" "$user" "$sshport" "$key"; then
    ok "Public-key authentication succeeded."
  else
    warn "Public-key authentication failed."
    printf '\n%sThe server does not yet trust our %s key.%s\n' "$C_YELLOW" "$KEY_LABEL" "$C_RESET"
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
      [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
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

  # --- Step 6: transport & start ----------------------------------------
  ensure_autossh || true

  local id
  id="$(tunnel_id "$host" "$user" "$sport")"

  info "Starting tunnel: localhost:$sport -> $host:$dport"
  if start_tunnel "$host" "$user" "$sport" "$dport" "$sshport" "$key" "$id" "$sshparams"; then
    save_tunnel "$id" "$host" "$user" "$sport" "$dport" "$sshport" "$key" "$sshparams"
    if register_remote_tunnel "$host" "$user" "$sshport" "$key" "$id" "$sport" "$dport" "$sshparams"; then
      ok "Registered on the server in ~/$REMOTE_REGISTRY_DIR/"
    else
      warn "Could not register the tunnel in the server's ~/$REMOTE_REGISTRY_DIR/."
    fi
    ok "Tunnel established."
    printf '\n  %sLocal:%s http://localhost:%s  ->  %s:%s%s\n' \
      "$C_GREEN" "$C_RESET" "$sport" "$host" "$dport" "$C_RESET"
    printf '  %sSaved as:%s %s\n\n' "$C_GREEN" "$C_RESET" "$id"
    log "tunnel created id=$id host=$host user=$user sport=$sport dport=$dport key=$KEY_TYPE"
    return 0
  fi

  err "Could not establish the tunnel."
  return 1
}

# ============================================================== MENU 2 =======
connect_tunnel() {
  printf '\n%s%s── Connect Tunnel ──%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  local -a local_ids=() local_confs=()
  local f
  for f in "$TUNNEL_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    local_ids+=("$ID")
    local_confs+=("$f")
  done

  # Also look for tunnels registered on the last used server.
  local last_host last_user
  last_host="$(cfg_get LAST_HOST "")"
  last_user="$(cfg_get LAST_USER "")"
  local key="$(pubkey_path)"
  local -a remote_records=()
  if [[ -n "$last_host" && -n "$last_user" && -f "$key" ]]; then
    local sshport; sshport="$(cfg_get LAST_SSH_PORT "22")"
    remote_records=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && remote_records+=("$line")
    done < <(list_remote_tunnels "$last_host" "$last_user" "$sshport" "$key")
  fi

  if (( ${#local_ids[@]} == 0 && ${#remote_records[@]} == 0 )); then
    warn "No saved tunnels yet. Use 'Create Tunnel' first."
    return 0
  fi

  local idx=0
  if (( ${#local_ids[@]} > 0 )); then
    printf '\n%sSaved tunnels (local):%s\n' "$C_BOLD" "$C_RESET"
    for f in "${local_confs[@]}"; do
      # shellcheck disable=SC1090
      source "$f"
      idx=$((idx+1))
      local status
      if tunnel_running "$ID"; then status="${C_GREEN}running${C_RESET}"; else status="${C_YELLOW}stopped${C_RESET}"; fi
      printf '  %2d) %s  %s@%s  %s:%s -> :%s  [%s]\n' \
        "$idx" "$ID" "$USER" "$HOST" "$HOST" "$SOURCE_PORT" "$DEST_PORT" "$status"
    done
  fi

  local remote_base=0
  if (( ${#remote_records[@]} > 0 )); then
    printf '\n%sTunnels registered on %s@%s:%s\n' "$C_BOLD" "$last_user" "$last_host" "$C_RESET"
    remote_base="$idx"
    local rec
    for rec in "${remote_records[@]}"; do
      idx=$((idx+1))
      local rid rhost ruser rsport rdport rlabel
      IFS='|' read -r rid rhost ruser rsport rdport _ rlabel _ _ <<< "$rec"
      printf '  %2d) %s  %s@%s  %s:%s -> :%s  [%s]\n' \
        "$idx" "$rid" "$ruser" "$rhost" "$rhost" "$rsport" "$rdport" "${C_CYAN}server${C_RESET}"
    done
  fi
  printf '\n'

  ask "Select tunnel number" "1"
  local choice="$REPLY"
  [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Invalid selection."; return 1; }

  # --- A tunnel registered on the server ---------------------------------
  if (( ${#remote_records[@]} > 0 && choice > remote_base )); then
    local rec="${remote_records[$((choice - remote_base - 1))]}"
    local rid rhost ruser rsport rdport rsshport rlabel rparams
    IFS='|' read -r rid rhost ruser rsport rdport rsshport rlabel rparams _ <<< "$rec"
    printf '\n%sConnecting to server-registered tunnel %s%s\n' "$C_BOLD" "$rid" "$C_RESET"
    [[ -f "$key" ]] || { err "Key $key is missing."; return 1; }
    info "Connecting to $ruser@$rhost:$rsshport ..."
    if ! try_pubkey_auth "$rhost" "$ruser" "$rsshport" "$key"; then
      warn "Public-key authentication failed for $ruser@$rhost."
      err "Use 'Create Tunnel' to re-establish this connection."
      return 1
    fi
    ensure_autossh || true
    if start_tunnel "$rhost" "$ruser" "$rsport" "$rdport" "$rsshport" "$key" "$rid" "$rparams"; then
      ok "Tunnel connected."
      printf '  %sLocal:%s localhost:%s  ->  %s:%s%s\n\n' \
        "$C_GREEN" "$C_RESET" "$rsport" "$rhost" "$rdport" "$C_RESET"
      log "tunnel connected (server registry) id=$rid"
      return 0
    fi
    err "Could not start tunnel."
    return 1
  fi

  # --- A locally saved tunnel --------------------------------------------
  idx=0
  for f in "${local_confs[@]}"; do
    # shellcheck disable=SC1090
    source "$f"
    idx=$((idx+1))
    [[ "$idx" == "$choice" ]] || continue

    if tunnel_running "$ID"; then
      ok "Tunnel '$ID' is already running (pid $(cat "$TUNNEL_DIR/$ID.pid" 2>/dev/null))."
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
        [[ "$EOF_REACHED" == "1" ]] && { err "Input ended."; return 1; }
        [[ "${REPLY,,}" == "skip" ]] && { err "Aborted."; return 1; }
        try_pubkey_auth "$HOST" "$USER" "$SSH_PORT" "$KEY" || { err "Authentication failing."; return 1; }
      fi
    fi

    ensure_autossh || true

    if start_tunnel "$HOST" "$USER" "$SOURCE_PORT" "$DEST_PORT" "$SSH_PORT" "$KEY" "$ID" "${SSH_PARAMS:-}"; then
      save_tunnel "$ID" "$HOST" "$USER" "$SOURCE_PORT" "$DEST_PORT" "$SSH_PORT" "$KEY" "${SSH_PARAMS:-}"
      register_remote_tunnel "$HOST" "$USER" "$SSH_PORT" "$KEY" "$ID" "$SOURCE_PORT" "$DEST_PORT" "${SSH_PARAMS:-}" || true
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

# ============================================================ MAIN MENU ======
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
          [[ "$EOF_REACHED" == "1" ]] && { printf '\n'; continue; }
          if [[ -n "$REPLY" ]]; then
            stop_tunnel "$REPLY"
            # Remove the server-side registration too.
            local conf="$TUNNEL_DIR/$REPLY.conf"
            if [[ -f "$conf" ]]; then
              # shellcheck disable=SC1090
              source "$conf"
              if [[ -f "$KEY" ]]; then
                unregister_remote_tunnel "$HOST" "$USER" "$SSH_PORT" "$KEY" "$REPLY" || true
              fi
            fi
          fi
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
    printf '%sKey type available:%s %s\n' "$C_CYAN" "$C_RESET" "$KEY_LABEL"
    build_extra_ssh_opts
    if (( ${#SSH_EXTRA_OPTS[@]} > 0 )); then
      printf '%sSSH algorithms:%s %s\n' "$C_CYAN" "$C_RESET" "${SSH_EXTRA_OPTS[*]}"
    fi
  else
    warn "Could not determine a usable key type."
  fi

  # Report the transport that will be used.
  if detect_autossh; then
    printf '%sTransport:%s autossh (%s)\n' "$C_CYAN" "$C_RESET" "$AUTOSSH_BIN"
  else
    printf '%sTransport:%s ssh (autossh not installed)\n' "$C_CYAN" "$C_RESET"
  fi

  main_menu
}

main "$@"
