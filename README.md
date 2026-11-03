# DiggerSSH

**SSH Tunnel Manager** — a single-file Bash script for provisioning and managing SSH port-forward tunnels, with post-quantum (ML-DSA-65) key support where the local OpenSSH build provides it.

```
╔══════════════════════════════════════╗
║  DiggerSSH  v1.0.0                  ║
╚══════════════════════════════════════╝
  1) Create Tunnel
  2) Connect Tunnel
  3) List tunnels
  4) Stop a tunnel
  0) Exit
```

---

## Features

- **Two-step tunnel creation** — `Create Tunnel` provisions the key, collects connection details, installs the public key on the remote server if needed, and starts the tunnel. `Connect Tunnel` re-establishes a previously saved tunnel.
- **Post-quantum key support** — uses **ML-DSA-65** when the local `ssh-keygen` supports it, automatically falling back to the best available modern type (see [Key types](#key-types--the-ml-dsa-65-reality)).
- **Automatic key provisioning** — generates a passphrase-less keypair in `~/.ssh/` on first run, and reuses an existing key of the correct type on later runs.
- **Self-healing authentication** — if public-key auth fails, DiggerSSH prompts for the SSH password and installs the public key into the remote `~/.ssh/authorized_keys` automatically. If that also fails, it prints the exact commands to run manually and waits for your confirmation.
- **Remembered defaults** — the last server and username are stored and offered as defaults on the next run.
- **Tunnel persistence** — saved tunnels can be listed, reconnected, and stopped from the menu.
- **No dependencies** — pure Bash 4+ plus `ssh` / `ssh-keygen`. Nothing to compile, no package to install.

---

## Requirements

| Requirement | Notes |
|---|---|
| Bash | 4.0 or newer (uses `read -r`, arrays, `[[ ]]`) |
| `ssh` | OpenSSH client |
| `ssh-keygen` | OpenSSH client |
| `ss` | Optional — used to detect port conflicts |

Tested on **Debian 13 (trixie)** with **OpenSSH 10.0p2**.

---

## Installation

```bash
git clone https://github.com/sufehmi/DiggerSSH.git
cd DiggerSSH
chmod +x diggerssh.sh
sudo install -m 755 diggerssh.sh /usr/local/bin/diggerssh
```

Or run it in place:

```bash
./diggerssh.sh
```

---

## Usage

Launch the menu:

```bash
diggerssh
```

### Create Tunnel

1. **Key material** — DiggerSSH checks whether a key of the preferred type already exists in `~/.ssh/`. If not, it generates one with **no passphrase**, directly in `~/.ssh/`.
2. **Connection details** — prompted with sensible defaults:

   | Prompt | Default |
   |---|---|
   | Server IP Address/Domain Name | last server used |
   | SSH Username | last username used |
   | Source Port | — (required) |
   | Destination Port | same as Source Port |
   | SSH Port | `22` |

3. **Review & Submit** — the configuration is displayed for confirmation before anything is touched on the remote host.
4. **Establish** — DiggerSSH tests public-key authentication. On failure it falls back to a password login to install the public key, then re-tests. If that fails too, it prints manual instructions and waits for you.
5. **Tunnel up** — the forward is established as:

   ```
   ssh -N -f -L <source_port>:127.0.0.1:<dest_port> user@server
   ```

   so `localhost:<source_port>` transparently reaches the service on the remote host.

### Connect Tunnel

Lists saved tunnels with their live status, then re-establishes the one you pick. If the key file has gone missing it is regenerated; if authentication fails the same password/manual fallback chain runs.

### Other menu entries

- **3) List tunnels** — show every saved tunnel and whether it is running.
- **4) Stop a tunnel** — stop a running tunnel by ID.

---

## Key types & the ML-DSA-65 reality

DiggerSSH was written to use **ML-DSA-65** post-quantum keys, but there is an important constraint worth understanding up front.

**`ssh-keygen -t ml-dsa-65` is not available in stock OpenSSH releases.** As of OpenSSH 10.6 the upstream client supports:

- `mldsa44-ed25519` — a **composite** ML-DSA-44 + Ed25519 signature (added in OpenSSH 10.4, enabled by default in 10.6). Not ML-DSA-65.
- The standalone `ssh-mldsa-65` public key algorithm is specified in the IETF draft [`draft-sfluhrer-ssh-mldsa`](https://datatracker.ietf.org/doc/html/draft-sfluhrer-ssh-mldsa-08), but **upstream OpenSSH does not implement it yet**.

A standalone ML-DSA-65 implementation does exist in the [OQS-OpenSSH](https://github.com/open-quantum-safe/openssh) fork, which exposes the key type as `mldsa-65`.

Rather than hard-coding a key type that would fail on most systems, DiggerSSH **probes the local `ssh-keygen`** at startup and picks the best available type in this order:

| Priority | Key type | Notes |
|---|---|---|
| 1 | `ml-dsa-65` | Standalone ML-DSA-65 |
| 2 | `ssh-mldsa-65` | Standalone ML-DSA-65 (alternate spelling) |
| 3 | `mldsa65` | Standalone ML-DSA-65 (alternate spelling) |
| 4 | `mldsa-44-ed25519` | Upstream OpenSSH 10.4+ composite |
| 5 | `mldsa44-ed25519` | Upstream OpenSSH 10.4+ composite |
| 6 | `ed25519` | Universal fallback |

The active type is printed at startup:

```
Key type available: ML-DSA-65 (post-quantum)
```

On a stock OpenSSH 10.0p2 system you will see `Ed25519`, because that build predates upstream's ML-DSA support. To get genuine ML-DSA-65 keys, use a build of `ssh-keygen` that supports the type — for example the OQS-OpenSSH fork:

```bash
# Generate an ML-DSA-65 key with the OQS-OpenSSH ssh-keygen
ssh-keygen -t mldsa-65 -N "" -f ~/.ssh/id_mldsa65
```

> **Note on the remote side:** the server must also accept the key type. A server running stock OpenSSH older than 10.4 will not accept an ML-DSA key, even if your client supports it. DiggerSSH's fallback chain handles this — it will report the failure and offer the password/manual path.

---

## Files & layout

| Path | Purpose |
|---|---|
| `~/.diggerssh/config` | Last-used server/username (defaults) |
| `~/.diggerssh/tunnels/<id>.conf` | Saved tunnel definitions |
| `~/.diggerssh/tunnels/<id>.pid` | PID of the running tunnel |
| `~/.diggerssh/tunnels/<id>.log` | ssh log for that tunnel |
| `~/.diggerssh/diggerssh.log` | Script activity log |
| `~/.ssh/id_mldsa65` | Generated keypair (name varies by key type) |

Override the state directory with `DIGGERSH_HOME`:

```bash
DIGGERSH_HOME=/tmp/diggerssh ./diggerssh.sh
```

---

## How the tunnel works

The forward created is a standard SSH local port forward:

```
client localhost:9999  ──SSH──▶  server 127.0.0.1:<dest_port>
```

`ExitOnForwardFailure=yes` makes `ssh` fail fast instead of hanging when the port cannot be bound, and `ServerAliveInterval=30` keeps the tunnel alive through idle periods.

---

## Security notes

- Keys are generated **without a passphrase** (as specified for unattended tunnel use). Protect `~/.ssh/` accordingly — it is created with mode `700` and private keys with mode `600`.
- `StrictHostKeyChecking=accept-new` is used: unknown hosts are accepted and recorded, but **changed** host keys are rejected, so MITM attempts on known hosts still fail.
- Saved tunnel definitions and the config file are mode `600`.
- The script never writes your password to disk; it is only passed to `ssh` for the fallback login.

---

## Contributing

Issues and pull requests are welcome. Please keep the script dependency-free (Bash + `ssh`/`ssh-keygen` only) and run `bash -n diggerssh.sh` before submitting.

## License

MIT — see [LICENSE](LICENSE).
