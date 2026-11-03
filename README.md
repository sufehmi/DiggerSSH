# DiggerSSH

**Tailscale but simple and free.**

An SSH Tunnel Manager — a single-file Bash script for provisioning and managing SSH port-forward tunnels, with post-quantum (ML-DSA-65) key support where the local OpenSSH build provides it.

```
╔══════════════════════════════════════╗
║  DiggerSSH  v1.1.0                  ║
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
- **Post-quantum key support with automatic fallback** — DiggerSSH negotiates a key type that **both** the local client and the remote server accept, walking a four-level chain and recording the outcome in the config file (see [Key types](#key-types--the-ml-dsa-65-reality)).
- **Automatic key provisioning** — generates a passphrase-less keypair in `~/.ssh/` on first run, and reuses an existing key of the correct type on later runs.
- **Self-healing authentication** — if public-key auth fails, DiggerSSH prompts for the SSH password and installs the public key into the remote `~/.ssh/authorized_keys` automatically. If that also fails, it prints the exact commands to run manually and waits for your confirmation.
- **Server-side tunnel registry** — every tunnel you create is recorded in `~/.diggerssh/` **on the server**, so `Connect Tunnel` can list and re-establish tunnels even after the local state is deleted.
- **Survives dropped connections** — uses [autossh](http://www.haproxy.org/download/1.8/doc/autossh.txt) when it is available so the tunnel re-establishes itself after a network drop; falls back to plain `ssh` when it is not.
- **Custom SSH parameters** — the `Create Tunnel` form takes an **SSH parameters** field (default `-o ServerAliveInterval=30 -o ServerAliveCountMax=5`) that is stored with the tunnel and reused on every reconnect.
- **Remembered defaults** — the last server, username and SSH port are stored and offered as defaults on the next run.
- **Tunnel persistence** — saved tunnels can be listed, reconnected, and stopped from the menu.
- **No dependencies** — pure Bash 4+ plus `ssh` / `ssh-keygen`. `autossh` is optional and only improves reliability.

---

## Requirements

| Requirement | Notes |
|---|---|
| Bash | 4.0 or newer (uses `read -r`, arrays, `[[ ]]`) |
| `ssh` | OpenSSH client |
| `ssh-keygen` | OpenSSH client |
| `autossh` | Optional — auto-restarts the tunnel if the link drops |
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
   | SSH parameters | `-o ServerAliveInterval=30 -o ServerAliveCountMax=5` |

   **SSH parameters** is passed straight through to `ssh` / `autossh`, so any
   `-o` option works — for example `-o ServerAliveInterval=60`, or
   `-o ProxyJump=bastion`. The value is stored with the tunnel and reused
   every time you reconnect it.

3. **Key negotiation** — DiggerSSH asks the server which signature algorithms it accepts and picks the strongest key type that **both** sides support (see [Key types](#key-types--the-ml-dsa-65-reality)). The decision is written to the config file.
4. **Review & Submit** — the configuration is displayed for confirmation before anything is touched on the remote host.
5. **Establish** — DiggerSSH tests public-key authentication. On failure it falls back to a password login to install the public key, then re-tests. If that fails too, it prints manual instructions and waits for you.
6. **Tunnel up** — the forward is established as:

   ```
   autossh -N -f -L <source_port>:127.0.0.1:<dest_port> user@server
   ```

   so `localhost:<source_port>` transparently reaches the service on the remote host. With `autossh` the tunnel re-establishes itself automatically after a dropped connection; with plain `ssh` it does not.

### Connect Tunnel

Lists saved tunnels with their live status, then re-establishes the one you pick. If the key file has gone missing it is regenerated; if authentication fails the same password/manual fallback chain runs.

The menu shows two groups:

- **Saved tunnels (local)** — tunnels recorded in `~/.diggerssh/tunnels/` on *this* machine.
- **Tunnels registered on `user@server`** — tunnels recorded in `~/.diggerssh/` on the *remote server* (see [Server-side registry](#server-side-registry)). These survive the loss of local state, so you can re-establish a tunnel from a different machine that has the same key.

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

Rather than hard-coding a key type that would fail on most systems, DiggerSSH **probes the local `ssh-keygen`** at startup and picks the best available type.

### The fallback chain

A key type is usable only when **both** ends agree on it:

1. the local `ssh-keygen` can **produce** the key, and
2. the remote server **accepts** the wire algorithm.

So DiggerSSH walks this chain from the top and stops at the first level that satisfies both conditions:

| Level | Key type | Wire algorithm | Notes |
|---|---|---|---|
| 0 | `ssh-mldsa-65` | `ssh-mldsa-65` | Standalone ML-DSA-65, post-quantum (OQS-OpenSSH) |
| 1 | `ssh-mldsa44-ed25519@openssh.com` | same | ML-DSA-44 + Ed25519 composite, upstream OpenSSH 10.4+ |
| 2 | `ssh-ed25519` | `ssh-ed25519` | Universal fallback |
| 3 | `ecdsa-sha2-nistp256` | same | Last resort |

If the server rejects the level currently in use, DiggerSSH says so and steps down to the next one automatically:

```
[!] Server does not accept ssh-mldsa-65 — falling back to the next key type.
```

The server's accepted algorithms are read from the `server-sig-algs` list that
`ssh` prints during key exchange — that happens **before** authentication, so
the negotiation works even on the first run when you cannot log in yet.

### The decision is recorded in the config file

`~/.diggerssh/config` states plainly which level was chosen and why:

```
KEY_TYPE=ed25519
KEY_ALGORITHM=ssh-ed25519
KEY_LABEL=Ed25519
KEY_LEVEL=2
KEY_FILE=/home/user/.ssh/id_ed25519
KEY_UPDATED=2026-11-03 16:04:29
KEY_FALLBACK_NOTE=fell back to Ed25519: ML-DSA-65 and ML-DSA-44 composite unavailable in the ssh client or rejected by the server
```

`KEY_LEVEL` is the position in the chain (0 = strongest) and
`KEY_FALLBACK_NOTE` explains the downgrade in plain words.

The active type is also printed during the run:

```
Key type: Ed25519 (ssh-ed25519)
```

On a stock OpenSSH 10.0p2 system you will see `Ed25519`, because that build predates upstream's ML-DSA support. To get genuine ML-DSA-65 keys, use a build of `ssh-keygen` that supports the type — for example the OQS-OpenSSH fork:

```bash
# Generate an ML-DSA-65 key with the OQS-OpenSSH ssh-keygen
ssh-keygen -t mldsa-65 -N "" -f ~/.ssh/id_mldsa65
```

### The `PubkeyAcceptedAlgorithms` requirement

Merely having an ML-DSA key is not enough. A client only offers a key whose
signature algorithm appears in its `PubkeyAcceptedAlgorithms` list — and the
OQS-OpenSSH build knows the standalone ML-DSA algorithms but **does not enable
them by default**. Without intervention, ssh skips the key with:

```
debug1: Skipping ssh-mldsa-65 key /home/user/.ssh/id_mldsa65 - corresponding algorithm not in PubkeyAcceptedAlgorithms
```

DiggerSSH therefore adds the option itself when the local ssh genuinely
supports it, and prints what it did:

```
Key type available: ML-DSA-65 (post-quantum)
SSH algorithms: -o PubkeyAcceptedAlgorithms=+ssh-mldsa-65 -o HostKeyAlgorithms=+ssh-mldsa-65
```

The check is deliberately conservative, because **stock ssh refuses to start
if it is asked for an algorithm it has never heard of**:

```
command-line line 0: Bad key types '+ssh-mldsa-65'.
```

So the option is only added when `ssh -Q PubkeyAcceptedAlgorithms` lists the
algorithm *and* it is not already in the effective default. On a stock
OpenSSH system DiggerSSH therefore prints no algorithm line at all and uses
Ed25519 as before.

---

## autossh

`autossh` wraps `ssh` and restarts the tunnel whenever the connection drops —
the practical difference between a tunnel that silently dies after an idle
period and one that comes back on its own.

DiggerSSH uses `autossh` when it is installed. If it is not, it offers to
install it with the system package manager (`apt`, `dnf`, `yum`, `pacman`,
`zypper`, or `brew`):

```
[!] autossh is not installed on this system.
[+] autossh restarts the tunnel automatically when the connection drops.
Try to install autossh now? [y/N]
```

If you decline, or the install is not possible, DiggerSSH continues with
plain `ssh` and tells you what that means:

```
[!] Continuing with plain ssh — the tunnel will not survive a dropped connection.
```

The choice is not permanent: install `autossh` at any time and DiggerSSH
will use it on the next run.

---

## Server-side registry

Every tunnel you create is recorded **on the server**, in `~/.diggerssh/`:

```
~/.diggerssh/
└── 127.0.0.1-sufehmi-9961.tunnel
```

Each record holds the details needed to re-establish the tunnel:

```
ID=127.0.0.1-sufehmi-9961
HOST=127.0.0.1
USER=sufehmi
SOURCE_PORT=9961
DEST_PORT=2232
SSH_PORT=2232
KEY_TYPE=ed25519
KEY_LABEL=Ed25519
SSH_PARAMS=-o ServerAliveInterval=30 -o ServerAliveCountMax=5
CREATED=2026-11-03 16:04:29
```

The directory is created with mode `700` and the records with mode `600`, and
it is written via a single `ssh` call so the key never reaches a remote
command line.

`Connect Tunnel` reads this registry back and lists what it finds:

```
Tunnels registered on sufehmi@127.0.0.1:
   2) 127.0.0.1-sufehmi-9961  sufehmi@127.0.0.1  127.0.0.1:9961 -> :2232  [server]
```

Because the registry lives on the server, **the tunnel outlives your local
state** — delete `~/.diggerssh/` on your laptop and the tunnel is still
listed and re-establishable from any machine that holds the same key.

---

## Files & layout

### On this machine

| Path | Purpose |
|---|---|
| `~/.diggerssh/config` | Last-used server/username/port, and the negotiated key type |
| `~/.diggerssh/tunnels/<id>.conf` | Saved tunnel definitions |
| `~/.diggerssh/tunnels/<id>.pid` | PID of the running tunnel |
| `~/.diggerssh/tunnels/<id>.log` | ssh log for that tunnel |
| `~/.diggerssh/diggerssh.log` | Script activity log |
| `~/.ssh/id_mldsa65` | Generated keypair (name varies by key type) |

### On the server

| Path | Purpose |
|---|---|
| `~/.diggerssh/<id>.tunnel` | Registry entry for one tunnel |

Override the state directory with `DIGGERSH_HOME`:

```bash
DIGGERSH_HOME=/tmp/diggerssh ./diggerssh.sh
```

> The server-side registry path is **not** affected by `DIGGERSH_HOME` — it is
> always `~/.diggerssh/` on the remote host, because that is where the server
> resolves `~` for the login user.

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

GNU General Public License v3.0 — see [LICENSE](LICENSE).
