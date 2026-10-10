#!/usr/bin/env bash
# Live drive of the sandbox-side recipe pieces: the wait script and the PATH block.
W=$1; REPO=$2; X=$REPO/docs/examples/boat-remote-host
clean() { env -i HOME="$1" PATH=/usr/bin:/bin SSH_CLIENT='10.0.0.1 5 22' /bin/bash -c "$2"; }

echo "### W1 fm-wait-home-ready: home is fuse for 3 checks, then ext4 (scripted findmnt on PATH)"
mkdir -p $W/fm; cat > $W/fm/findmnt <<SH
#!/bin/sh
echo "\$*" >> $W/fm/args
n=\$((\$(cat $W/fm/n 2>/dev/null || echo 0)+1)); echo \$n > $W/fm/n
[ \$n -le \${FUSE_CHECKS:-3} ] && echo fuse || echo ext4
SH
chmod +x $W/fm/findmnt
s=$(date +%s); PATH=$W/fm:$PATH sh $X/fm-wait-home-ready; echo "[exit $?] wall=$(( $(date +%s)-s ))s"; echo "findmnt args: $(sort -u $W/fm/args)"
echo; echo "### W2 home stays lazy past the limit (limit 2s)"
rm -f $W/fm/n; s=$(date +%s); FUSE_CHECKS=999 PATH=$W/fm:$PATH sh $X/fm-wait-home-ready 2; echo "[exit $?] wall=$(( $(date +%s)-s ))s"
echo; echo "### W3 real findmnt on this host (no lazy mount)"
sh $X/fm-wait-home-ready 5; echo "[exit $?]"
echo; echo "### W4 real findmnt, real mounts in a private user+mount namespace: /home/user on tmpfs (byte-identical copy of the script, since the namespace hides /home)"
unshare -rm sh -c "mount -t tmpfs none /home && mkdir /home/user && mount -t tmpfs none /home/user && findmnt -n -o FSTYPE --target /home/user && sh $W/wait-copy 3; echo \"[exit \$?]\""

echo; echo "### P1 PATH block: non-interactive SSH-style bash with a stock Ubuntu ~/.bashrc"
BLOCK=$(awk '/# FIRSTMATE PATH START/{on=1} on{sub(/^   /,"");print} /# FIRSTMATE PATH END/{exit}' $REPO/docs/remote-secondmates.md)
echo "--- block as shipped in docs/remote-secondmates.md:"; echo "$BLOCK"
for v in none top bottom; do
  h=$W/bh-$v; mkdir -p $h/.local/bin
  printf '#!/bin/sh\necho entrypoint-ran\n' > $h/.local/bin/fm-remote-entrypoint.sh; chmod +x $h/.local/bin/fm-remote-entrypoint.sh
  case $v in
    none) cp /etc/skel/.bashrc $h/.bashrc ;;
    top) { echo "$BLOCK"; cat /etc/skel/.bashrc; } > $h/.bashrc ;;
    bottom) { cat /etc/skel/.bashrc; echo "$BLOCK"; } > $h/.bashrc ;;
  esac
  echo "--- block=$v:"; clean $h 'fm-remote-entrypoint.sh'; echo "[exit $?]"
done
echo "--- block=top, sourced a second time does not duplicate the entry:"
clean $W/bh-top '. ~/.bashrc; printf "%s\n" "$PATH" | sed "s#$HOME#~#g"'
