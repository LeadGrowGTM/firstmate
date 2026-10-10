#!/usr/bin/env bash
# Runs INSIDE `unshare -rm`: a private systemd manager loads the two shipped
# unit files verbatim and starts them. Only the namespace's own view of
# /usr/local/bin and /home is replaced; the host is untouched.
W=$1; R=$W/root
mount --bind $R/usr/local/bin /usr/local/bin
mount --bind $R/home /home
export XDG_RUNTIME_DIR=$W/run XDG_CONFIG_HOME=$W/xdg HOME=$W/mhome
unset DBUS_SESSION_BUS_ADDRESS
mkdir -p $XDG_RUNTIME_DIR $XDG_CONFIG_HOME/systemd/user $HOME; chmod 700 $XDG_RUNTIME_DIR
U=$XDG_CONFIG_HOME/systemd/user
for u in fm-remote-job fm-remote-herdr; do
  cmp $R/etc/systemd/system/$u.service $W/shipped/$u.service && cp $W/shipped/$u.service $U/
  # The namespace maps a single uid, so the `user` account cannot exist here.
  mkdir -p $U/$u.service.d; printf '[Service]\nUser=\n' > $U/$u.service.d/ns.conf
done
sc() { systemctl --user "$@"; }
/usr/lib/systemd/systemd --user --log-target=console > $W/manager.log 2>&1 & M=$!
for _ in $(seq 100); do [ -S $XDG_RUNTIME_DIR/systemd/private ] && break; sleep 0.1; done
[ -S $XDG_RUNTIME_DIR/systemd/private ] || { echo "private systemd manager did not come up"; tail -20 $W/manager.log; exit 3; }
show() { sc show "$1" -p ActiveState -p SubState -p MainPID -p NRestarts -p Result | tr '\n' ' '; echo; }

echo "### U1 units load verbatim: systemd's own view"
systemd-analyze --user verify fm-remote-job.service fm-remote-herdr.service; echo "[verify exit $?]"
sc show fm-remote-job -p ExecStartPre -p TimeoutStartUSec -p Restart -p RestartUSec | sed 's/ ; ignore_errors.*//'

echo; echo "### U2 start while /home/user is still the lazy-restore mount (findmnt reports fuse)"
touch $W/lazy
sc start --no-block fm-remote-job fm-remote-herdr; sleep 4
show fm-remote-job; show fm-remote-herdr
echo "worker processes: $(pgrep -fc 'firstmate/bin/fm-remote-job-worker.sh')  herdr processes: $(pgrep -fc 'herdr server --session fm-remote')"

echo; echo "### U3 restore finishes (findmnt reports ext4): both services start by themselves"
rm $W/lazy; sleep 5
show fm-remote-job; show fm-remote-herdr
echo "worker processes: $(pgrep -fc 'firstmate/bin/fm-remote-job-worker.sh')  herdr processes: $(pgrep -fc 'herdr server --session fm-remote')"
echo "herdr stub saw: $(cat /home/user/herdr.argv 2>/dev/null)"
echo "--- journal-equivalent manager log lines:"
grep -E 'home ready|fm-remote|Started|Starting' $W/manager.log | tail -12
echo "--- worker state under the unit's HOME:"; find /home/user -maxdepth 4 -path '*remote-job*' 2>/dev/null | sed "s#/home/user#~#" | head -8

echo; echo "### U4 Restart=always: kill both main processes, systemd brings them back"
P1=$(sc show fm-remote-job -p MainPID --value); P2=$(sc show fm-remote-herdr -p MainPID --value)
kill -9 $P1 $P2; sleep 9
show fm-remote-job; show fm-remote-herdr
echo "old pids $P1 $P2 -> new pids $(sc show fm-remote-job -p MainPID --value) $(sc show fm-remote-herdr -p MainPID --value)"

echo; echo "### U5 home never leaves the lazy mount: start fails instead of running on it (limit shortened to 3s via drop-in)"
sc stop fm-remote-herdr; touch $W/lazy
printf '[Service]\nExecStartPre=\nExecStartPre=/usr/local/bin/fm-wait-home-ready 3\nRestart=no\n' > $U/fm-remote-herdr.service.d/short.conf
sc daemon-reload; sc start fm-remote-herdr; echo "[start exit $?]"
show fm-remote-herdr
echo "herdr processes: $(pgrep -fc 'herdr server --session fm-remote')"

sc stop fm-remote-job fm-remote-herdr 2>/dev/null
kill $M; wait $M 2>/dev/null
