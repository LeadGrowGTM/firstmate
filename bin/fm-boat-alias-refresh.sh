#!/usr/bin/env bash
# Refresh (or remove) the OpenSSH alias for a Boat sandbox that hosts a remote
# second mate.
#
# Usage:
#   fm-boat-alias-refresh.sh <sandbox-id> <alias>   write or refresh the alias
#   fm-boat-alias-refresh.sh --remove <alias>       remove the alias and its pin
#   fm-boat-alias-refresh.sh --help
#
# Optional, and only for an operator whose remote host is a Boat sandbox
# (docs/remote-secondmates.md "Linux hosts and Boat sandboxes"). Run it on the
# primary after every `boat resume` and before any fm-on.sh call.
#
# A Boat sandbox lands on a new machine at every resume: its SSH host key
# changes, and its endpoint (host and port) usually changes too. This command
# re-reads both through the authenticated Boat CLI session, so a new host key
# is never accepted on first sight over the network:
#   - state, endpoint, and restore progress from `boat info <id> --json`
#     (.sandbox.sshEndpoint as host:port, else .sandbox.ip on port 22);
#   - the ED25519 host key from `boat exec <id>`, Boat's API command channel.
# Those two read-only calls are the only Boat commands it runs, each with the
# CLI's global --no-update flag. It refuses a sandbox that is not running.
#
# It then rewrites exactly two things under ~/.ssh and prints what changed:
#   - one block in ~/.ssh/config, between the lines
#     "# >>> boat-alias <alias> >>>" and "# <<< boat-alias <alias> <<<": the
#     previous block is dropped and the new one appended at the end;
#   - one dedicated known-hosts file, ~/.ssh/known_hosts_<alias>, with every
#     "-" in the alias written as "_".
# The block names the Boat CLI's own key (~/.ssh/ascii_box_ed25519, created by
# the first `boat ssh`), pins the host key through HostKeyAlias and that
# known-hosts file with strict checking, and disables agent forwarding. It
# stores no secret and touches nothing else in ~/.ssh, including the default
# known_hosts file. --remove deletes the block and the known-hosts file, and
# deletes ~/.ssh/config itself when the block was its whole content.
#
# It refuses, changing nothing, when ~/.ssh/config is a symbolic link (the
# rewrite would replace the link with a file) or holds a start line for this
# alias with no end line (the rest of the file would be read as the block).
#
# OpenSSH keeps the first value it reads for each option, and the block is
# last in the file. An earlier block that also matches the alias, such as
# "Host *", therefore wins for any option it sets; `ssh -G <alias>` prints the
# values in force.
#
# After a resume the sandbox's home directory is restored lazily, and until
# Boat reports hydrated=true a file open there can block with no timeout, which
# makes an fm-on.sh call hang instead of fail. Once the alias is written this
# command waits for hydrated=true and exits non-zero when it does not arrive in
# time; the refreshed alias stays in place, and a rerun waits again.
#
# Output on success:
#   sandbox=<id> state=<state>
#   endpoint: <old host:port|none> -> <host:port>
#   hostkey:  <old fingerprint|none> -> <fingerprint>
#   hydrated=true waited=<n>s
#
# Environment knobs:
#   FM_BOAT_BIN           the Boat CLI to run (boat)
#   FM_BOAT_HYDRATE_WAIT  seconds to wait for the restore (600; 0 checks once)
#   FM_BOAT_HYDRATE_POLL  seconds between restore checks (5; above 0)
#
# Exit status: 0 the alias is current and the restore has finished, or the
# alias was removed; 1 a refusal or failure, including a restore that did not
# finish in time; 2 invalid use.
set -eu

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
KEY="$SSH_DIR/ascii_box_ed25519"
BOAT_BIN=${FM_BOAT_BIN:-boat}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
bad_use() {
  printf 'error: %s\n' "$1" >&2
  printf 'usage: %s <sandbox-id> <alias> | --remove <alias> | --help\n' "${0##*/}" >&2
  exit 2
}

tmp=
known_tmp=
cleanup() {
  [ -z "$tmp" ] || rm -f -- "$tmp"
  [ -z "$known_tmp" ] || rm -f -- "$known_tmp"
}
trap cleanup EXIT

check_alias() { # <alias>
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) bad_use "unsafe alias: $1" ;; esac
}

# Leaves the config without <alias>'s block in $tmp, next to the config so the
# later rename is atomic.
strip_config() { # <alias>
  [ ! -L "$CONFIG" ] ||
    die "$CONFIG is a symbolic link, and rewriting it would replace the link with a file; make it a regular file first"
  tmp=$(mktemp "$SSH_DIR/.config.tmp.XXXXXX")
  [ -f "$CONFIG" ] || return 0
  awk -v begin="# >>> boat-alias $1 >>>" -v end="# <<< boat-alias $1 <<<" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
    END { exit skip }
  ' "$CONFIG" > "$tmp" ||
    die "$CONFIG has a '# >>> boat-alias $1 >>>' line with no matching end line; repair that block by hand"
}

publish_config() {
  if [ -s "$tmp" ]; then
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$CONFIG"
  else
    rm -f -- "$tmp" "$CONFIG"
  fi
  tmp=
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "${1:-}" = --remove ]; then
  [ "$#" -eq 2 ] || bad_use "--remove takes exactly one alias"
  ALIAS=$2
  check_alias "$ALIAS"
  KNOWN="$SSH_DIR/known_hosts_${ALIAS//-/_}"
  if [ -f "$CONFIG" ]; then
    strip_config "$ALIAS"
    publish_config
  fi
  rm -f -- "$KNOWN"
  printf 'removed: alias %s and %s\n' "$ALIAS" "$KNOWN"
  exit 0
fi

[ "$#" -eq 2 ] || bad_use "expected a sandbox id and an alias"
ID=$1
ALIAS=$2
case "$ID" in bx_*) ;; *) bad_use "not a sandbox id: $ID" ;; esac
case "$ID" in *[!A-Za-z0-9_]*) bad_use "unsafe sandbox id: $ID" ;; esac
check_alias "$ALIAS"
wait_max=${FM_BOAT_HYDRATE_WAIT:-600}
case "$wait_max" in ''|*[!0-9]*) bad_use "FM_BOAT_HYDRATE_WAIT must be a whole number of seconds" ;; esac
poll=${FM_BOAT_HYDRATE_POLL:-5}
case "$poll" in ''|*[!0-9]*|0) bad_use "FM_BOAT_HYDRATE_POLL must be a whole number of seconds above 0" ;; esac
for tool in "$BOAT_BIN" jq ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but does not resolve"
done
[ -f "$KEY" ] || die "no Boat CLI key at $KEY; run 'boat ssh $ID true' once"
KNOWN="$SSH_DIR/known_hosts_${ALIAS//-/_}"

info=$("$BOAT_BIN" --no-update info "$ID" --json) || die "boat info failed for $ID"
state=$(printf '%s' "$info" | jq -r '.sandbox.state // empty')
case "$state" in
  ready|idle|running) ;;
  *) die "sandbox $ID is not running (state=${state:-unknown}); resume it first" ;;
esac
endpoint=$(printf '%s' "$info" | jq -r '.sandbox.sshEndpoint // empty')
if [ -n "$endpoint" ]; then
  host=${endpoint%:*}
  port=${endpoint##*:}
else
  host=$(printf '%s' "$info" | jq -r '.sandbox.ip // empty')
  port=22
fi
[ -n "$host" ] || die "boat info returned no SSH endpoint or ip for $ID"
case "$port" in ''|*[!0-9]*) die "unexpected SSH port: $port" ;; esac
case "$host" in *[!A-Za-z0-9.:-]*) die "unexpected SSH host: $host" ;; esac

# The host key comes over the Boat API command channel, not over SSH.
hostkey=$("$BOAT_BIN" --no-update exec "$ID" --json -- cat /etc/ssh/ssh_host_ed25519_key.pub |
  jq -r 'select(.exitCode == 0) | .stdout' | awk 'NR == 1 { print $1, $2 }')
case "$hostkey" in 'ssh-ed25519 AAAA'*) ;; *) die "could not read the sandbox host key through boat exec" ;; esac

old_fp=
[ ! -f "$KNOWN" ] || old_fp=$(ssh-keygen -lf "$KNOWN" 2>/dev/null | awk '{print $2}')
old_target=none
if [ -f "$CONFIG" ]; then
  old_target=$(awk -v begin="# >>> boat-alias $ALIAS >>>" -v end="# <<< boat-alias $ALIAS <<<" '
    $0 == begin { on = 1; next }
    $0 == end { on = 0 }
    on && $1 == "HostName" { h = $2 }
    on && $1 == "Port" { p = $2 }
    END { if (h != "") print h ":" p; else print "none" }
  ' "$CONFIG")
fi

umask 077
strip_config "$ALIAS"
cat >> "$tmp" <<EOF
# >>> boat-alias $ALIAS >>>
Host $ALIAS
  HostName $host
  Port $port
  User user
  IdentityFile $KEY
  IdentitiesOnly yes
  HostKeyAlias $ALIAS
  UserKnownHostsFile $KNOWN
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  UpdateHostKeys no
  ForwardAgent no
  ConnectTimeout 15
# <<< boat-alias $ALIAS <<<
EOF

known_tmp="$KNOWN.tmp.$$"
printf '%s %s\n' "$ALIAS" "$hostkey" > "$known_tmp"
new_fp=$(ssh-keygen -lf "$known_tmp" 2>/dev/null | awk '{print $2}')
[ -n "$new_fp" ] || die "boat exec returned a host key ssh-keygen cannot read"
mv -f -- "$known_tmp" "$KNOWN"
known_tmp=
publish_config

printf 'sandbox=%s state=%s\n' "$ID" "$state"
printf 'endpoint: %s -> %s:%s\n' "$old_target" "$host" "$port"
printf 'hostkey:  %s -> %s\n' "${old_fp:-none}" "$new_fp"

start=$(date +%s)
hydrated=$(printf '%s' "$info" | jq -r '.sandbox.hydrated')
while [ "$hydrated" != true ] && [ $(( $(date +%s) - start )) -lt "$wait_max" ]; do
  sleep "$poll"
  hydrated=$("$BOAT_BIN" --no-update info "$ID" --json | jq -r '.sandbox.hydrated') || hydrated=unknown
done
waited=$(( $(date +%s) - start ))
printf 'hydrated=%s waited=%ss\n' "$hydrated" "$waited"
[ "$hydrated" = true ] ||
  die "the alias is refreshed, but sandbox $ID has not finished restoring its disk after ${waited}s; a Firstmate call can hang until it does, so rerun this command before using the alias"
