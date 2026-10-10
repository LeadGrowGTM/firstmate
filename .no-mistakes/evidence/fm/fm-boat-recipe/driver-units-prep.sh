#!/usr/bin/env bash
# Builds the disposable sandbox root the private systemd manager sees.
W=$1; REPO=$2; R=$W/root
cd "$REPO" || exit 1
mkdir -p $W/shipped; cp docs/examples/boat-remote-host/*.service $W/shipped/
rm -rf $R/home/user/firstmate; mkdir -p $R/home/user/firstmate $R/home/user/.local/bin
git archive HEAD | tar -x -C $R/home/user/firstmate
# Scripted findmnt (first on the units' PATH) and a stub herdr; the wait script
# and the worker are the shipped files.
cat > $R/usr/local/bin/findmnt <<SH
#!/bin/sh
[ -e $W/lazy ] && echo fuse || echo ext4
SH
cat > $R/home/user/.local/bin/herdr <<'SH'
#!/bin/sh
echo "$*" > /home/user/herdr.argv
exec sleep 100000
SH
chmod +x $R/usr/local/bin/findmnt $R/home/user/.local/bin/herdr
# The sandbox account's ~/.bashrc carries the documented PATH block at the top.
{ awk '/# FIRSTMATE PATH START/{on=1} on{sub(/^   /,"");print} /# FIRSTMATE PATH END/{exit}' docs/remote-secondmates.md; cat /etc/skel/.bashrc; } > $R/home/user/.bashrc
cp /etc/skel/.profile $R/home/user/.profile
