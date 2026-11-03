#!/usr/bin/env bash
# Rebuild OQS-OpenSSH with a libexec path the unprivileged user can read,
# then run a full ML-DSA-65 end-to-end tunnel test against it.
#
# Why not /opt: the sshd binary bakes in its libexec path at compile time, and
# /opt/diggerssh-oqs needs root to populate. /home/sufehmi/tmp/diggerssh is
# writable by the unprivileged test user, which is what a real deployment
# on this box looks like.
set -uo pipefail

PREFIX=/home/sufehmi/tmp/diggerssh
SCRIPT=/home/sufehmi/projects/diggerssh/diggerssh.sh
PORT=2261
SRC=9987
log() { printf '\n=== %s ===\n' "$*"; }

log "[1/6] prepare state dirs"
rm -rf "$PREFIX" /home/sufehmi/.diggerssh
mkdir -p "$PREFIX/bin" "$PREFIX/libexec" "$PREFIX/etc" "$PREFIX/share"
echo "PREFIX=$PREFIX"

log "[2/6] clone + configure oqs-openssh inside the container"
docker exec -w /build dg_oqs_build bash -c "
set -uo pipefail
rm -rf /build/oqs-ssh
git clone -q --depth 1 --branch OQS-v10 https://github.com/open-quantum-safe/openssh.git /build/oqs-ssh \
  && echo CLONE_OK || { echo CLONE_FAIL; exit 1; }
cd /build/oqs-ssh
# sshkey_clear_pkey() is declared in sshkey.h only under SSHKEY_INTERNAL, but
# oqs-utils.h pulls sshkey.h in first, so the define must precede it.
python3 - <<'PYEOF'
src = open('ssh-oqs.c').read().splitlines(True)
out = ['// DiggerSSH patch: SSHKEY_INTERNAL must precede every include\n#define SSHKEY_INTERNAL 1\n']
skipped = False
for line in src:
    if not skipped and line.strip().startswith('#define SSHKEY_INTERNAL'):
        skipped = True
        continue
    out.append(line)
open('ssh-oqs.c', 'w').writelines(out)
PYEOF
# kex_reset_keys() is defined in kex.c but never declared; declare it.
python3 - <<'PYEOF'
src = open('kex.h').read().splitlines(True)
out, done = [], False
for line in src:
    out.append(line)
    if not done and line.startswith('int\t kex_derive_keys('):
        out.append('void\t kex_reset_keys(struct kex *);\n')
        done = True
open('kex.h', 'w').writelines(out)
PYEOF
autoreconf -fi >/tmp/ar.log 2>&1 && echo AUTORECONF_OK || { echo AUTORECONF_FAIL; tail -10 /tmp/ar.log; exit 1; }
./configure --prefix=$PREFIX --libexecdir=$PREFIX/libexec \
  --sysconfdir=$PREFIX/etc --datarootdir=$PREFIX/share \
  --with-ssl-dir=/usr --with-privsep-path=$PREFIX/run \
  --without-pam --with-liboqs-dir=/usr/local \
  >/tmp/conf.log 2>&1 && echo CONFIGURE_OK || { echo CONFIGURE_FAIL; tail -25 /tmp/conf.log; exit 1; }
" 2>&1 | tail -8

log "[3/6] make + install"
docker exec -w /build dg_oqs_build bash -c "
set -uo pipefail
make -j\$(nproc) >/tmp/make.log 2>&1 && echo MAKE_OK || { echo MAKE_FAIL; grep -E 'error:' /tmp/make.log | head -8; exit 1; }
make install >/tmp/mi.log 2>&1 && echo INSTALL_OK || { echo INSTALL_FAIL; tail -15 /tmp/mi.log; exit 1; }
" 2>&1 | tail -6

log "[4/6] baked libexec path + sshd version"
strings "$PREFIX/bin/sshd" 2>/dev/null | grep -o "$PREFIX/libexec/[a-z-]*" | sort -u | head -6
"$PREFIX/bin/sshd" -V 2>&1 | head -2

log "[5/6] start the test sshd on port $PORT"
mkdir -p "$PREFIX/run" "$PREFIX/hostkeys"
ssh-keygen -q -t mldsa-65 -N '' -f "$PREFIX/hostkeys/mldsa65" 2>/dev/null || \
  "$PREFIX/bin/ssh-keygen" -q -t mldsa-65 -N '' -f "$PREFIX/hostkeys/mldsa65"
cat > "$PREFIX/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $PREFIX/hostkeys/mldsa65
AuthorizedKeysFile $PREFIX/.ssh/authorized_keys
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
EOF
mkdir -p $PREFIX/.ssh
"$PREFIX/bin/sshd-session" -D -e -f "$PREFIX/sshd_config" > "$PREFIX/sshd.out" 2>&1 &
echo $! > "$PREFIX/sshd.pid"
sleep 2
ss -ltn 2>/dev/null | grep -q ":$PORT" && echo "SSHD_UP on $PORT" || { echo "SSHD_DOWN"; cat "$PREFIX/sshd.out" 2>/dev/null | head -5; }

log "[6/6] DiggerSSH end-to-end against the ML-DSA-65 server"
export DIGGERSH_HOME="$PREFIX/.diggerssh"
export PATH="$PREFIX/bin:$PATH"
mkdir -p "$DIGGERSH_HOME/tunnels"
printf "1\n127.0.0.1\nsufehmi\n$SRC\n$PORT\n$PORT\n-o ServerAliveInterval=17 -o ServerAliveCountMax=9\ny\n" \
  | timeout 90 bash "$SCRIPT" 2>&1 | grep -vE "^\s*$" | tail -20
echo "--- config file ---"; cat "$DIGGERSH_HOME/config" 2>/dev/null | head -12
echo "--- server registry ---"; ls -la /home/sufehmi/.diggerssh/ 2>/dev/null | head -5
echo "--- tunnel bound + traffic ---"
ss -ltn 2>/dev/null | grep ":$SRC" || echo "PORT_NOT_BOUND"
timeout 6 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SRC && head -c 40 <&3" 2>/dev/null | head -2 || echo "NO_TRAFFIC"

log "cleanup"
kill "$(cat "$PREFIX/sshd.pid")" 2>/dev/null
echo "done"
