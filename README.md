# DiggerSSH

```text
    ____  _                       __________ __  __
   / __ \(_)___ _____ ____  _____/ ___/ ___// / / /
  / / / / / __ `/ __ `/ _ \/ ___/\__ \__ \/ /_/ /
 / /_/ / / /_/ / /_/ /  __/ /   ___/ /__/ / __ /
/_____/_/\__, /\__, /\___/_/   /____/____/_/ /_/
        /____//____/
```

**v1.5.1** — a single-file Bash SSH tunnel manager.

DiggerSSH manages SSH port-forwarding tunnels. It keeps a local registry of
the tunnels you configure, lets you create new ones and re-open existing
ones, and reports their live status by asking the kernel who is actually
holding the port.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [The main menu](#the-main-menu)
  - [Create Tunnel to Server](#create-tunnel-to-server)
  - [Connect Tunnel (to a server's Port)](#connect-tunnel-to-a-servers-port)
  - [List tunnels](#list-tunnels)
  - [Stop a tunnel](#stop-a-tunnel)
- [The two forwarding directions](#the-two-forwarding-directions)
- [How status is determined](#how-status-is-determined)
- [autossh](#autossh)
- [Post-quantum (ML-DSA-65) support](#post-quantum-ml-dsa-65-support)
  - [A note on key types](#a-note-on-key-types)
- [Files & layout](#files--layout)
  - [On this machine](#on-this-machine)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Two menus, two forwarding directions** — `Create Tunnel to Server` opens a
  **remote** forward (`-R`): the server listens on the port and pipes the
  traffic back to this machine. `Connect Tunnel (to a server's Port)` opens a
  **local** forward (`-L`): this machine listens and forwards into the server.
- **A registry of your tunnels** — every tunnel you configure is stored under
  `~/.diggerssh/tunnels/` and listed in the menu, so you re-open a tunnel by
  number instead of re-typing its details.
- **Live status straight from the kernel** — status is decided by looking up
  the process that actually holds the port, so the list, the connect action
  and the stop action can never disagree with each other.
- **Precise stopping** — stopping a tunnel kills the exact `ssh` process
  carrying that forward, never a pattern-matched approximation.
- **Per-family port checks** — a port can be busy on IPv4 and free on IPv6;
  DiggerSSH checks each family separately and binds whichever is free.
- **Custom SSH parameters** — the form takes free-form **SSH parameters**
  (default `-o ServerAliveInterval=30 -o ServerAliveCountMax=5`) that are
  stored with the tunnel and reused on every reconnect.
- **Remembered defaults** — the last host, username and ports are stored and
  offered as editable defaults next time.
- **Survives dropped connections** — uses [autossh](http://www.haproxy.org/download/1.8/doc/autossh.txt)
  when it is installed so the tunnel re-establishes itself after a network
  drop; falls back to plain `ssh` when it is not.
- **No dependencies** — pure Bash 4+ plus `ssh`. `autossh` is optional and
  only improves reliability.

---

## Requirements

| Requirement | Notes |
|---|---|
| Bash | 4.0 or newer (uses arrays, `[[ ]]`, `read -r`) |
| `ssh` | OpenSSH client |
| `autossh` | Optional — auto-restarts the tunnel if the link drops |
| `ss` | Optional — used for per-family port checks |

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

### The main menu

```
   ____  _                       __________ __  __
  / __ \(_)___ _____ ____  _____/ ___/ ___// / / /
 / / / / / __ `/ __ `/ _ \/ ___/\__ \\__ \/ /_/ /
/_____/_/\__, /\__, /\___/_/   /____/____/_/ /_/
        /____//____/
   v1.5.1  SSH tunnel manager

  1) Create Tunnel to Server
  2) Connect Tunnel (to a server's Port)
  3) List tunnels
  4) Stop a tunnel
  0) Exit
```

Each of the first four entries opens a submenu listing your tunnels, with
`+ Add new server` and `Exit to main menu` as the final entries. `List
tunnels` is a plain report and returns to the main menu immediately.

### Create Tunnel to Server

Choosing `+ Add new server` starts the provisioning form:

**Step 1 — Server**

| Prompt | Default |
|---|---|
| Server IP Address/Domain Name | last host used |
| SSH Username | last username used |
| SSH Port | `22` (this is ssh's `-p` argument) |

**Step 2 — Tunnel**

| Prompt | Default |
|---|---|
| Source Port | the SSH port entered above |
| Destination Port | the Source Port just entered |
| SSH parameters | `-o ServerAliveInterval=30 -o ServerAliveCountMax=5` |

Every default is shown in brackets and is editable — press Enter to accept it.

**Step 3 — Review** shows the exact command that will run, for example:

```
ssh -p 22 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -R 44641:127.0.0.1:44641 sufehmi@server2.mafindo.or.id
```

**SSH parameters** is passed straight through to `ssh` / `autossh`, so any
`-o` option works — for example `-o ServerAliveInterval=60`, or
`-o ProxyJump=bastion`. The value is stored with the tunnel and reused every
time you re-open it.

### Connect Tunnel (to a server's Port)

Lists your tunnels with their live status, then opens the one you pick using
a **local** forward (`-L`). The local port matches the port the tunnel uses
on the server, so both ends use the same number.

### List tunnels

Prints every configured tunnel with its host, source port, destination port
and current status, then returns to the main menu.

### Stop a tunnel

Lists your tunnels, asks which one to terminate, and kills the `ssh` process
carrying that forward. The `autossh` supervisor is killed before its `ssh`
child so it cannot resurrect the tunnel.

---

## The two forwarding directions

DiggerSSH uses both SSH forwarding modes, one per menu entry.

**`Create Tunnel to Server` → `-R` (remote forward).** The listener is
created **on the server**, on the source port. Traffic arriving there is
carried down the SSH connection and delivered to `127.0.0.1:<destination>` on
this machine.

```
ssh -p 22 -R 44641:127.0.0.1:44641 sufehmi@server2.mafindo.or.id
```

```
   client (this machine)                server
  ┌────────────────────┐            ┌──────────────────────┐
  │  127.0.0.1:44641   │ ──SSH──▶  │  listener :44641     │
  │  (local service)   │ ◀──────── │  → 127.0.0.1:44641   │
  └────────────────────┘            └──────────────────────┘
```

**`Connect Tunnel (to a server's Port)` → `-L` (local forward).** The
listener is created **on this machine**, on the source port, and forwards
into the server's port.

```
ssh -p 22 -L 44641:127.0.0.1:44641 sufehmi@server2.mafindo.or.id
```

```
   client (this machine)                server
  ┌────────────────────┐            ┌──────────────────────┐
  │  listener :44641   │ ──SSH──▶  │  127.0.0.1:44641     │
  │  → remote service  │ ◀──────── │  (remote service)    │
  └────────────────────┘            └──────────────────────┘
```

Both forms bind the loopback interface only, so the forwarded port is not
reachable from the network.

---

## How status is determined

A tunnel's status is not guessed from a PID file. The local process that
carries the forward argument **is** the tunnel, so DiggerSSH finds it by
matching the exact `-L`/`-R` argument in `/proc`:

```bash
pgrep -x ssh; pgrep -x autossh      # then match the forward spec in /proc/PID/cmdline
```

This matters because:

- `autossh` forks an `ssh` child, and with `-f` the supervisor exits at
  once — a PID captured from `$!` is either the wrong process or already
  dead.
- `pkill -f` on a port pattern matches far too much, including the shell
  running DiggerSSH itself.
- A port can be held by a process that is not a tunnel at all. Such a
  process is reported as a conflict, never as a running tunnel.

Because status, connect and stop all read the same source, they cannot
disagree with one another.

**Address families.** A port can be busy on IPv4 and free on IPv6, and vice
versa. `ssh` binds *both* loopback families for a forward and aborts if
either fails, so DiggerSSH checks each family separately and names the free
one explicitly in the forward argument:

```
! 127.0.0.1:44641 is held by another process — binding [::1]:44641 instead.
```

---

## autossh

When `autossh` is on `PATH` it is used as the transport, so the tunnel
re-establishes itself after a dropped connection:

```bash
autossh -N -o ServerAliveInterval=30 -o ServerAliveCountMax=5 \
  -o ExitOnForwardFailure=yes -R 44641:127.0.0.1:44641 user@host
```

Without `autossh`, plain `ssh` is used and the tunnel does not survive a
network drop.

---

## Post-quantum (ML-DSA-65) support

The upstream OpenSSH client can negotiate **ML-DSA-65** post-quantum keys
when it is built against a provider that supports them. DiggerSSH prefers a
bundled such build when one is present next to the script:

```
diggerssh.sh
oqs-bin/          ← optional: ssh, sshd, ssh-keygen, … built with OQS-OpenSSH
```

If `oqs-bin/ssh` exists, that directory is prepended to `PATH` for the
session, so the key generation and the live tunnel use the same
implementation. Set `DIGGERSH_NO_OQS=1` to force the system binaries
instead:

```bash
DIGGERSH_NO_OQS=1 ./diggerssh.sh
```

`oqs-bin/` is **not** committed — it is 18 MB of machine-specific binaries.
See `scripts/build-oqs-ssh.sh` for how to build one.

### A note on key types

`ml-dsa-65` is not available in stock OpenSSH releases. Upstream OpenSSH
supports `mldsa44-ed25519`, a **composite** ML-DSA-44 + Ed25519 signature
(OpenSSH 10.4+), not the standalone ML-DSA-65. A standalone implementation
exists in the [OQS-OpenSSH](https://github.com/open-quantum-safe/openssh)
fork, which exposes the key type as `mldsa-65`:

```bash
ssh-keygen -t mldsa-65 -N "" -f ~/.ssh/id_mldsa65
```

Merely having such a key is not enough — a client only offers a key whose
signature algorithm appears in its `PubkeyAcceptedAlgorithms` list, and the
OQS build does not enable the standalone ML-DSA algorithms by default:

```
debug1: Skipping ssh-mldsa-65 key /home/user/.ssh/id_mldsa65 - corresponding algorithm not in PubkeyAcceptedAlgorithms
```

Add the option yourself when your build supports it:

```bash
ssh -o PubkeyAcceptedAlgorithms=+ssh-mldsa-65 -o HostKeyAlgorithms=+ssh-mldsa-65 ...
```

The check must be conservative, because **stock ssh refuses to start if it
is asked for an algorithm it has never heard of**:

```
command-line line 0: Bad key types '+ssh-mldsa-65'.
```

---

## Files & layout

### On this machine

| Path | Purpose |
|---|---|
| `~/.diggerssh/config` | Last-used host, username, ports |
| `~/.diggerssh/tunnels/<id>.tunnel` | One file per tunnel (`KEY=value` lines) |
| `~/.diggerssh/tunnels/<id>.log` | Output of that tunnel's `ssh` process |
| `~/.diggerssh/diggerssh.log` | Script activity log |

A tunnel record looks like this:

```
HOST=server2.mafindo.or.id
USER=sufehmi
SOURCE_PORT=44641
DEST_PORT=44641
SSH_PARAMS=-o ServerAliveInterval=30 -o ServerAliveCountMax=5
CREATED=2026-11-03\ 19:15:29
```

There is deliberately **no** PID file: the owning process is discovered from
the kernel at the moment it is needed, so the file can never go stale.

Override the state directory with `DIGGERSH_HOME`:

```bash
DIGGERSH_HOME=/tmp/diggerssh ./diggerssh.sh
```

---

## Security notes

- Forwards bind the loopback interface only, so they are not exposed to the
  network.
- Tunnel records and the config file are written with mode `600`.
- `StrictHostKeyChecking=accept-new` is used: unknown hosts are accepted on
  first contact, but a **changed** host key is still rejected. Do not
  weaken this to `StrictHostKeyChecking=no`.
- The SSH parameters field is passed to `ssh` unquoted, so it is split into
  separate arguments. This is intended — it is how `-o` options are supplied
  — but it means the field must not contain shell metacharacters.
- `ExitOnForwardFailure=yes` makes `ssh` exit rather than pretend a forward
  succeeded, which keeps the reported status honest.

---

## Contributing

Issues and pull requests are welcome. Please keep the script a single file
with no hard dependencies beyond `ssh`, and run `bash -n diggerssh.sh`
before submitting.

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
