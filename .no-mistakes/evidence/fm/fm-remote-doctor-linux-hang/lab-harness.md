# Lab harness used for the live runs (disposable, lived under a mktemp dir, removed afterwards)

## setup.sh
#!/usr/bin/env bash
# setup.sh <sandbox> <name> <commit> : build one disposable "remote host" (code root + account home + fm home)
set -eu
SB=$1; NAME=$2; COMMIT=$3; WT=$4
H=$SB/$NAME; mkdir -p "$H/root" "$H/home/.local/bin" "$H/home/.local/lib/node_modules" "$H/home/.ssh" "$H/op-home/data"
git -C "$WT" archive "$COMMIT" | tar -x -C "$H/root"
git -C "$H/root" init -q; git -C "$H/root" add -A
git -C "$H/root" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "snapshot of $COMMIT"
cp "$SB/tools/herdr" "$H/home/.local/bin/herdr"
cp /home/mitch/go/bin/treehouse "$H/home/.local/bin/treehouse"
cp -rL /home/mitch/.local/lib/node_modules/tasks-axi "$H/home/.local/lib/node_modules/tasks-axi"
ln -s ../lib/node_modules/tasks-axi/dist/bin/tasks-axi.js "$H/home/.local/bin/tasks-axi"
chmod +x "$H/home/.local/lib/node_modules/tasks-axi/dist/bin/tasks-axi.js"
ln -s "$H/root/bin/fm-remote-entrypoint.sh" "$H/home/.local/bin/fm-remote-entrypoint.sh"
[ -f "$SB/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$SB/id_ed25519"
[ -f "$SB/hostkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$SB/hostkey"
cp "$SB/id_ed25519.pub" "$H/home/.ssh/authorized_keys"
cat > "$H/sshd_config" <<CFG
Port 22922
ListenAddress 127.0.0.1
HostKey $SB/hostkey
PidFile $H/sshd.pid
AuthorizedKeysFile /home/mitch/.ssh/authorized_keys
PasswordAuthentication no
UsePAM no
StrictModes no
SetEnv PATH=/home/mitch/.local/bin:/usr/local/bin:/usr/bin:/bin
CFG
printf '[127.0.0.1]:22922 %s\n' "$(cut -d' ' -f1,2 "$SB/hostkey.pub")" > "$SB/known_hosts"
cat > "$SB/ssh_config" <<CFG
Host fmbox
  HostName 127.0.0.1
  Port 22922
  User mitch
  IdentityFile $SB/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $SB/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
CFG
cat > "$SB/driver/ssh-lab" <<CFG
#!/usr/bin/env bash
exec /usr/bin/ssh -F "$SB/ssh_config" "\$@"
CFG
chmod +x "$SB/driver/ssh-lab"
printf -- '- box1 - disposable linux lab host (host: fmbox; root: %s; home: %s; scope: lab; projects: none; added 2026-10-10)\n' "$H/root" "$H/fmhome" > "$H/op-home/data/secondmates.md"
echo "built $H"

## host-up.sh
#!/usr/bin/env bash
# host-up.sh <sandbox> <name> : run sshd for the disposable host inside private user/mount/pid namespaces,
# with the sandbox account home mounted over /home/mitch so nothing touches the real home.
SB=$1; NAME=$2; H=$SB/$NAME
exec unshare -Urm --pid --fork --mount-proc --kill-child bash -c "mount --rbind '$H/home' /home/mitch && exec unshare -U --map-user=1000 --map-group=1000 '$SB/sshd-root/usr/sbin/sshd' -D -e -f '$H/sshd_config'" > "$H/sshd.log" 2>&1

## run.sh
#!/usr/bin/env bash
# run.sh <sandbox> <name> <bound-seconds> <label> [doctor args] : drive fm-on.sh ... fm-remote-doctor.sh over the lab sshd
SB=$1; NAME=$2; BOUND=$3; LABEL=$4; shift 4; H=$SB/$NAME
echo "### $LABEL"
echo "\$ FM_HOME=<operator lab home> FM_SSH_BIN=<ssh -F lab config> bin/fm-on.sh box1 fm-remote-doctor.sh $*   (code root: $NAME, bound ${BOUND}s)"
start=$(cut -d" " -f1 /proc/uptime)
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H/op-home" FM_SSH_BIN="$SB/driver/ssh-lab" timeout "$BOUND" "$H/root/bin/fm-on.sh" box1 fm-remote-doctor.sh "$@" 2>&1 | cat
rc=${PIPESTATUS[0]}
end=$(cut -d" " -f1 /proc/uptime)
printf '### exit=%s elapsed=%.1fs%s\n' "$rc" "$(echo "$end - $start" | bc)" "$([ "$rc" = 124 ] && echo '  <-- timeout(1) killed the SSH call: it never returned on its own')"
echo "### herdr server processes on the lab host afterwards:"
ps -C herdr -o pid=,ppid=,etimes=,args= || echo "(none)"
