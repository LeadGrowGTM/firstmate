#!/usr/bin/env bash
# Live drive of bin/fm-boat-alias-refresh.sh: real helper, real OpenSSH client,
# real SSH server; only the Boat CLI is a scripted fake.
W=$1; REPO=$2
export HOME=$W/home FAKE_BOAT_DIR=$W/boat PATH=$W/bin:$PATH PYTHONPATH=$W/py FM_BOAT_HYDRATE_POLL=1
ID=bx_live1; ALIAS=fm-boat; H=$REPO/bin/fm-boat-alias-refresh.sh
CFG=$HOME/.ssh/config
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
sshx() { run ssh -F "$CFG" -o BatchMode=yes "$@"; }
info() { jq -n --arg s "$1" --arg e "$2" --argjson h "$3" '{sandbox:{state:$s,sshEndpoint:$e,ip:"10.0.0.9",hydrated:$h}}'; }
hostkey() { jq -n --arg o "$(cat $W/keys/$1.pub)"$'\n' '{exitCode:0,stdout:$o,stderr:""}' > $W/boat/exec; }
reset_calls() { rm -f $W/boat/calls $W/boat/info.count $W/boat/info.[0-9]*; }
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
start_sshd() { # <key> <port> <tag>
  python3 $W/sshd.py $W/keys/$1 $2 $HOME/.ssh/ascii_box_ed25519.pub $3 & SPID=$!
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$2) 2>/dev/null && return; sleep 0.1; done; echo "sshd did not start"; }
snap() { (cd $HOME/.ssh && for f in $(ls -A | sort); do [ -L "$f" ] && echo "$f -> $(readlink $f)" || echo "$(sha256sum < $f | cut -c1-16) $(stat -c %a $f) $f"; done); }

# The operator's pre-existing config and default known_hosts.
printf 'Host personal\n  HostName example.invalid\n  User me\n' > $CFG
echo 'example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOperatorOwnPinnedKeyxxxxxxxxxxxxxxxxxxxxxxxxx' > $HOME/.ssh/known_hosts
PRE_KH=$(sha256sum < $HOME/.ssh/known_hosts)
echo "host1 fingerprint: $(ssh-keygen -lf $W/keys/host1.pub | awk '{print $2}')"
echo "host2 fingerprint: $(ssh-keygen -lf $W/keys/host2.pub | awk '{print $2}')"

say "S1 first run: write the alias, then connect through it with real OpenSSH"
P1=$(freeport); start_sshd host1 $P1 machine-1; S1=$SPID
info running 127.0.0.1:$P1 true > $W/boat/info; hostkey host1
run bash $H $ID $ALIAS
echo "--- boat calls:"; cat $W/boat/calls
echo "--- ~/.ssh/config:"; cat $CFG
echo "--- ~/.ssh listing (sha, mode, name):"; snap
sshx $ALIAS true
sshx personal -G | grep -i '^hostname' # operator block still resolves

say "S2 resume: sandbox moved to a new machine (new host key, new port)"
kill $S1; wait $S1 2>/dev/null
echo "--- adversarial: an impostor/new machine answers on the OLD endpoint with a different host key"
start_sshd host2 $P1 impostor-on-old-endpoint; SI=$SPID
KH_BEFORE=$(sha256sum < $HOME/.ssh/known_hosts_fm_boat)
sshx $ALIAS true
[ "$KH_BEFORE" = "$(sha256sum < $HOME/.ssh/known_hosts_fm_boat)" ] && echo "pinned known-hosts file unchanged by the rejected connection (no trust-on-first-use)"
kill $SI; wait $SI 2>/dev/null
P2=$(freeport); start_sshd host2 $P2 machine-2; S2=$SPID
echo "--- stale alias, old endpoint now dead:"
sshx $ALIAS true
reset_calls; info running 127.0.0.1:$P2 true > $W/boat/info; hostkey host2
run bash $H $ID $ALIAS
sshx $ALIAS true
echo "--- config after refresh (one block, operator block intact):"; cat $CFG
echo "boat-alias blocks: $(grep -c '^# >>> boat-alias' $CFG)"
[ "$PRE_KH" = "$(sha256sum < $HOME/.ssh/known_hosts)" ] && echo "default known_hosts untouched"

say "S3 adversarial: Boat returns a host key that is NOT the server's (wrong pin must refuse the connection)"
reset_calls; hostkey host1
run bash $H $ID $ALIAS
sshx $ALIAS true
hostkey host2; run bash $H $ID $ALIAS >/dev/null; reset_calls

say "S4 restore wait: hydrated=false for two polls, then true"
info running 127.0.0.1:$P2 false > $W/boat/info; info running 127.0.0.1:$P2 true > $W/boat/info.3
run bash $H $ID $ALIAS
echo "boat info calls: $(grep -c '^--no-update info' $W/boat/calls)"
say "S5 restore never finishes within FM_BOAT_HYDRATE_WAIT=3"
reset_calls
FM_BOAT_HYDRATE_WAIT=3 run bash $H $ID $ALIAS
echo "--- alias still refreshed and usable:"; sshx $ALIAS true
say "S5b a poll that fails mid-wait reports hydrated=unknown, not empty"
reset_calls; cat > $W/bin/boat-flaky <<EOF
#!/usr/bin/env bash
n=\$((\$(cat $W/boat/flaky.count 2>/dev/null || echo 0)+1)); echo \$n > $W/boat/flaky.count
[ "\$2" = info ] && [ \$n -gt 1 ] && { echo "boat: API error" >&2; exit 1; }
exec $W/bin/boat "\$@"
EOF
chmod +x $W/bin/boat-flaky; rm -f $W/boat/flaky.count
FM_BOAT_BIN=$W/bin/boat-flaky FM_BOAT_HYDRATE_WAIT=2 run bash $H $ID $ALIAS

say "S6 refusals leave ~/.ssh byte-identical"
info running 127.0.0.1:$P2 true > $W/boat/info; reset_calls; run bash $H $ID $ALIAS >/dev/null
BASE=$(snap)
check() { [ "$BASE" = "$(snap)" ] && echo "=> ~/.ssh unchanged" || { echo "=> ~/.ssh CHANGED"; snap; }; }
echo "--- stopped sandbox"; info stopped "" false > $W/boat/info; run bash $H $ID $ALIAS; check
echo "--- boat info prints non-JSON"; echo 'Upgrade available! visit https://boat.dev' > $W/boat/info; run bash $H $ID $ALIAS; check
echo "--- boat info prints a JSON array"; echo '[]' > $W/boat/info; run bash $H $ID $ALIAS; check
echo "--- boat exec fails on the sandbox"; info running 127.0.0.1:$P2 true > $W/boat/info
jq -n '{exitCode:1,stdout:"",stderr:"cat: no such file"}' > $W/boat/exec; run bash $H $ID $ALIAS; check
echo "--- boat exec returns a non-key"; jq -n '{exitCode:0,stdout:"ssh-rsa AAAAB3 x\n",stderr:""}' > $W/boat/exec; run bash $H $ID $ALIAS; check
echo "--- endpoint with shell metacharacters"; hostkey host2; info running 'evil;touch /tmp/x:22' true > $W/boat/info; run bash $H $ID $ALIAS; check
echo "--- alias that could inject config"; info running 127.0.0.1:$P2 true > $W/boat/info; run bash $H $ID 'a b'; check
echo "--- not a sandbox id"; run bash $H myhost $ALIAS; check
echo "--- no Boat CLI on PATH"; PATH=/usr/bin:/bin:$(dirname $(command -v jq)) FM_BOAT_BIN=boat-nope run bash $H $ID $ALIAS; check
echo "--- unterminated block"; cp $CFG $W/cfg.bak; printf '# >>> boat-alias other >>>\nHost other\n' >> $CFG; B2=$(snap); run bash $H $ID other
[ "$B2" = "$(snap)" ] && echo "=> ~/.ssh unchanged"; cp $W/cfg.bak $CFG
echo "--- symlinked config"; mv $CFG $W/realcfg; ln -s $W/realcfg $CFG; B3=$(snap); run bash $H $ID $ALIAS
[ "$B3" = "$(snap)" ] && [ -L $CFG ] && echo "=> still a symlink, unchanged"; rm $CFG; mv $W/realcfg $CFG

say "S7 --remove"
reset_calls
run bash $H --remove $ALIAS
echo "--- config now:"; cat $CFG; echo "--- listing:"; ls -A $HOME/.ssh
echo "boat calls during remove: $(cat $W/boat/calls 2>/dev/null | wc -l)"
sshx $ALIAS -G | grep -i '^hostname'
[ "$PRE_KH" = "$(sha256sum < $HOME/.ssh/known_hosts)" ] && echo "default known_hosts untouched"
kill $S2 2>/dev/null
