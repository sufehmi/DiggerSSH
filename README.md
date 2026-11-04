# DiggerSSH

```text
    ____  _                       __________ __  __
   / __ \(_)___ _____ ____  _____/ ___/ ___// / / /
  / / / / / __ `/ __ `/ _ \/ ___/\__ \__ \/ /_/ /
 / /_/ / / /_/ / /_/ /  __/ /   ___/ /__/ / __ /
/_____/_/\__, /\__, /\___/_/   /____/____/_/ /_/
        /____//____/
```

**v1.8.5** — a single-file Bash SSH tunnel manager.

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
  - [Delete a tunnel or server](#delete-a-tunnel-or-server)
- [The two forwarding directions](#the-two-forwarding-directions)
- [How status is determined](#how-status-is-determined)
  - [autossh is a supervisor, not the tunnel](#autossh-is-a-supervisor-not-the-tunnel)
  - [The SSH port](#the-ssh-port)
  - [Log files](#log-files)
  - [Diagnosing a tunnel that did not come up](#diagnosing-a-tunnel-that-did-not-come-up)
- [Key exchange fallback](#key-exchange-fallback)
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
- **Graceful algorithm fallback** — the key exchange, host key and public key
  are negotiated against the server from a chain that ends at ECDH, so an
  older server gets a working connection instead of an error (see
  [Key exchange fallback](#key-exchange-fallback)).
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
   v1.8.5  SSH tunnel manager

  1) Create Tunnel to Server
  2) Connect Tunnel (to a server's Port)
  3) List tunnels
  4) Stop a tunnel
  5) Delete a tunnel or server
  0) Exit
```

The first two menus are **two-tier**: pick a **server**, then one of that
server's **tunnels**. The server list comes from `~/.diggerssh/servers/`,
so deleting a server's file removes it from the menus — and its tunnels
go with it.

| Entry | What it does |
|---|---|
| `+ Add new server` | Asks for host, username, SSH port, description, SSH parameters **and the source and destination ports**; saves the server, saves the tunnel and opens it |
| `+ Create tunnel on this server` | Asks for the source and destination ports; saves one file in `~/.diggerssh/tunnels/` |

The ports are part of the `+ Add new server` form because the forward
argument is built from them: the source port is the port that listens,
and the direction decides which side listens.

| Menu | Direction | Meaning |
|---|---|---|
| `Create Tunnel to Server` | `-R` | The server listens on the source port and forwards it back here |
| `Connect Tunnel (to a server's Port)` | `-L` | This machine listens on the source port and forwards into the server |

In the `Stop a tunnel` menu no forward is being built, so `+ Add new
server` registers the server only and asks for no ports.

A tunnel whose server is not registered is kept and listed, marked
`(no server)`, but it does not appear under any server. Registering the
server again re-attaches it.

`List tunnels` is a plain report. `Delete a tunnel or server` lists both
kinds of record in one continuous numbering and removes the chosen one,
stopping the tunnel first if it is running.

### Create Tunnel to Server

Choosing `+ Add new server` starts the provisioning form:

**Step 1 — Server**

| Prompt | Default |
|---|---|
| Server IP Address/Domain Name | last host used |
| SSH Username | last username used |
| SSH Port | `22` (this is ssh's `-p` argument) |

**Step 2 — Description**

| Prompt | Default |
|---|---|
| Description | *(none — free text)* |

A short label for the tunnel, shown as the first column of **List tunnels**.
Only the first 20 characters are displayed there.

**Step 3 — Tunnel**

| Prompt | Default |
|---|---|
| Source Port | the SSH port entered above |
| Destination Port | the Source Port just entered |
| SSH parameters | `-o ServerAliveInterval=30 -o ServerAliveCountMax=5` |

Every default is shown in brackets and is editable — press Enter to accept it.

**Step 4 — Review** shows the exact command that will run, for example:

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

### Delete a tunnel or server

Lists the servers and the tunnels in one continuous numbering and removes the
one you pick. A running tunnel is stopped first, so deleting a record never
leaves an orphaned `ssh` process behind.

Deleting a **server** removes its tunnels with it — that is how you start
over: delete the server, and both menus are empty again.

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
parsing that argument out of `/proc`:

```bash
ps auxw | grep 44641                # the same view the tool uses
```

`ps` enumerates the processes and the `-L`/`-R` argument is parsed out of
each `ssh`/`autossh` command line. The **source port** identifies the
tunnel; the destination may be any `host:port`, and the bind address may
be spelled several ways, so neither is compared.

Before a tunnel is started the port is checked the same way. An `ssh`
process already carrying that port **in the same direction** cannot be
bound again — `ssh` would exit with `Address already in use` and the
tunnel would never come up — so the holder is named up front, with its
pid and command line:

```
! Port 44641 is already carried by an ssh process (pid 363872, -L [::1]:44641:127.0.0.1:44641).
!   ps auxw | grep 44641:
    sufehmi 363872 /usr/bin/ssh -N ... -L [::1]:44641:127.0.0.1:44641 user@host
```

The same `ps` view is printed when a tunnel fails to come up, so the
cause is visible without leaving the tool.

### The two directions do not collide

A `-R` tunnel binds its port **on the server**; a `-L` tunnel binds it
**here**. They are the two ends of one path, so a `-R` and a `-L` on the
same port can — and often should — run at the same time.

The preflight is therefore direction-aware. A duplicate in the same
direction is refused:

```
! Port 44641 is already carried by an ssh process (pid 363872, -L ...).
!   this menu opens a -L tunnel, and so does that one.
!   stop it first, then start this one.
```

A tunnel in the *opposite* direction is allowed, with a note saying so:

```
! Port 44641 is also carried by a -R tunnel (pid 379221).
!   that one binds the port on the server, this one binds it here,
!   so they do not collide — continuing.
```

Before v1.8.3 the preflight was direction-blind and refused the pair
outright, which made the second menu unusable for the very record the
first menu had just created.

### A live ssh process is not a working tunnel

`ssh` binds a local forward **only after the handshake completes**. On a
slow or lossy link — or when the server simply is not answering — the
process sits there with nothing bound, and it says **nothing** while it
waits. That is the failure behind "ssh is running but the port is not
bound": the process was alive in `ps`, but the connection never finished,
so the forward never appeared and the log held nothing but the command
line.

The tool reads the process's socket state straight from `/proc/net/tcp`:

- **`01` ESTABLISHED** — the handshake is done; the tunnel is real.
- **`02` SYN_SENT** — the server is not answering. The forward can never
  bind. The tool now says exactly that instead of a bare "not bound".

The wait for the tunnel is generous (it gives a slow link every chance to
finish), and a fast failure — a refused connection, an unreachable
network, a denied key — is reported the moment it lands in the log rather
than after the full wait. A connection that never finishes is killed, so
it does not linger in `ps` looking like a live tunnel.

### Wildcard listeners count as "in use"

A socket on `0.0.0.0:PORT` or `[::]:PORT` blocks a bind of
`127.0.0.1:PORT` / `[::1]:PORT`. The port check looks for those
addresses too, not just the exact loopback ones — otherwise the tool
believed a port was free, `ssh` died on the bind, and the only clue was
an `Address already in use` with no hint as to who held it.

### autossh is a supervisor, not the tunnel

`autossh` keeps running and respawns `ssh` even when the connection
fails — wrong port, unreachable host, refused key — and the forward
argument sits in `autossh`'s **own** command line. So `autossh` alone
does not prove a tunnel is up.

A tunnel is reported as running only when the `ssh` **child** exists.
Otherwise a connection that is failing and being retried looks perfectly
healthy, and the tunnel is reported as up when it is not. When only the
supervisor is present, the tool says so:

```
✗ Tunnel did not come up.
✗   autossh is still retrying (pid 375204), but no ssh connection
✗   was established — the tunnel is NOT up.
```

### The SSH port

The port a server listens on for SSH is part of the server record and is
passed to `ssh` with `-p`. Without it every connection would go to port
22, and a server registered on another port could never be reached.

A tunnel record carries its own port as well, and **that one wins** — a
tunnel belongs to a server, but it was created against a particular port.

### Log files

Every entry written to a log file carries a timestamp:

```
[2026-11-03 22:25:54] Starting tunnel t1: server2.mafindo.or.id:45151 → 127.0.0.1:45151 (-L, ssh port 22)
[2026-11-03 22:25:56] Tunnel t1 started (pid 376402, -L, kex curve25519-sha256)
[2026-11-03 22:26:31] Tunnel t1 stopped
```

The tunnel's own log is the `ssh` process's output, timestamped as it is
written. The activity log records what the tool did.

The argument is **parsed, not compared as text**. `ssh` accepts many
spellings of the same forward, and the destination may be any host:port:

```
-L 44641:127.0.0.1:44641              plain
-L 127.0.0.1:44641:127.0.0.1:44641     explicit IPv4 bind
-L [::1]:44641:127.0.0.1:44641         explicit IPv6 bind
-L 0.0.0.0:44641:127.0.0.1:44641       IPv4 wildcard bind
```

A whole-string comparison misses tunnels that are plainly running. The
status then reads `stopped`, the next start collides with the live tunnel,
and the user is told the port is already in use. The **source port**
identifies the tunnel; the destination does not have to match the record.

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

### Diagnosing a tunnel that did not come up

The tunnel's own log always begins with the exact command that was run,
so there is never a blank file to puzzle over:

```
[2026-11-04 00:27:36] command: autossh -N -p 2222 -o ServerAliveInterval=30 ... -L 45521:127.0.0.1:45521 sufehmi@server2.mafindo.or.id
[2026-11-04 00:27:36] ssh: connect to host server2.mafindo.or.id port 2222: Network is unreachable
[2026-11-04 00:27:36] transport exited with status 1
```

The last line is the transport's exit status, appended when it ends, so
a silent death is still recorded.

Two more things happen on failure that used not to:

- **The failed attempt is cleaned up.** A failed launch used to leave an
  `autossh` supervisor retrying forever. The next attempt then found
  that supervisor and reported the port as carried by an unrelated
  process — with no way to clear it. Only the processes this attempt
  started are killed; pre-existing ones are left alone.
- **The reason is named.** The old message was "the ssh process wrote
  nothing to its log". Now the log contents are printed, or, if there
  genuinely are none, it says so explicitly and points at the command.

### The kernel is the source of record

The tool used to depend on four external commands that may be absent, or
may behave differently, on another machine:

| Command | Used for | If it misbehaves |
|---|---|---|
| `ps -eo pid=,comm=,args=` | finding tunnels | **every tunnel looks stopped** |
| `ss -ltn` | checking whether a port is busy | **every port looks free** |
| `awk` | timestamping the log | the filter dies, the log stays empty |
| `setsid` | detaching the tunnel | **the tunnel never starts** |

Every one of those failures was silent. A `ps` that does not understand
the format returns nothing, so no tunnel was ever found; a missing `ss`
means every port looks free, so `ssh` dies on the bind; a missing `setsid`
means the launcher never runs — and its error message went to
`/dev/null`, so the log held nothing but the command line and the tool
reported "Tunnel did not come up" with no reason at all.

So the kernel's own view under `/proc` is the source of record:

- **Processes** come from `/proc/<pid>/comm` and `/proc/<pid>/cmdline`.
- **Listeners** come from `/proc/net/tcp` and `/proc/net/tcp6`, where the
  state field `0A` means LISTEN and the address is hex, each 32-bit word
  little-endian (`127.0.0.1` reads as `0100007F`).

Neither needs an external command at all, so the tool behaves the same on
a full system and on a bare container.

`ps auxw | grep <port>` is still what you run by hand, and the tool's
answer still comes from the same `/proc` data, so the two cannot disagree.

### The tunnel is verified, not assumed

For a local forward the ground truth is the **bound socket** — an `ssh`
process can be alive and still have failed to bind, and only the listener
proves the tunnel forwards. The tool waits for that socket rather than
for the process, because `ssh` binds *after* it connects.

A remote forward cannot be checked this way — its listener is on the
server — so there the live `ssh` process is the evidence.

---

## Key exchange fallback

Some `ssh` builds — notably OQS-OpenSSH — print this when the negotiated key
exchange is not post-quantum:

```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
```

On a server that offers no post-quantum key exchange at all, that warning is
noise: the connection succeeds. It reads like a failure, though, so
DiggerSSH does not leave the choice to `ssh`.

Before opening a tunnel it negotiates the algorithms against **that server**
and pins them, walking a chain from strongest to weakest:

| Layer | Chain |
|---|---|
| Key exchange | `mlkem768x25519-sha256` → `sntrup761x25519-sha512@openssh.com` → `curve25519-sha256` → `ecdh-sha2-nistp256` |
| Host key | `ssh-mldsa-65` → `ssh-mldsa44-ed25519@openssh.com` → `ssh-ed25519` → `ecdsa-sha2-nistp256` |
| Public key | same as host key |

The strongest entry that **both** ends support is chosen and recorded, so the
whole connection degrades together rather than failing at one layer. The
chain ends at ECDH, which every server supports.

Two details make the probe reliable:

- The KEX is tested by **trying it**. OpenSSH 10.x prints only the
  *negotiated* algorithm, not the server's full proposal, so the advertised
  list cannot simply be read off the debug output.
- The host and public key algorithms come from the server's pre-auth
  `server-sig-algs` list, which is available before authentication.

Pinning the KEX also silences the spurious warning, because that build only
emits it when `ssh` picks the algorithm by itself.

Against an OpenSSH 7.9 server with no post-quantum support, the result is:

```
KexAlgorithms=curve25519-sha256
HostKeyAlgorithms=ssh-ed25519
PubkeyAcceptedAlgorithms=ssh-ed25519
```

and the tunnel opens with no warning on the wire.

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
| `~/.diggerssh/servers/<id>.conf` | One file per registered server |
| `~/.diggerssh/tunnels/<id>.tunnel` | One file per tunnel (`KEY=value` lines) |
| `~/.diggerssh/tunnels/<id>.log` | Output of that tunnel's `ssh` process |
| `~/.diggerssh/diggerssh.log` | Script activity log, one timestamped entry per action |

A server record looks like this:

```
ID=server2.mafindo.or.id_22
HOST=server2.mafindo.or.id
USER=sufehmi
SSH_PORT=22
SSH_PARAMS=-o ServerAliveInterval=30 -o ServerAliveCountMax=5
DESCRIPTION=Production DB access
CREATED=2026-11-03 19:15:29
```

and a tunnel record like this:

```
ID=server2.mafindo.or.id_44641
SERVER=server2.mafindo.or.id_22
DESCRIPTION=Production DB access
HOST=server2.mafindo.or.id
USER=sufehmi
SOURCE_PORT=44641
DEST_PORT=44641
SSH_PORT=22
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
