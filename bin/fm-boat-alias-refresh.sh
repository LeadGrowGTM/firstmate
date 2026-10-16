#!/usr/bin/env bash
# Refresh, verify, or remove the OpenSSH alias for a Boat sandbox that hosts a
# remote second mate.
#
# Usage:
#   fm-boat-alias-refresh.sh <sandbox-id> <alias>   write or refresh the alias
#   fm-boat-alias-refresh.sh --verify <alias>       check the alias before a connection
#   fm-boat-alias-refresh.sh --remove <alias>       remove the alias and its pin
#   fm-boat-alias-refresh.sh --help
#
# Optional, and only for an operator whose remote host is a Boat sandbox
# (docs/remote-secondmates.md "Linux hosts and Boat sandboxes"). Run it on the
# primary after every `boat resume` and before any fm-on.sh call.
#
# A Boat sandbox lands on a new machine at every resume: its SSH host key
# changes, and its endpoint (host and port) usually changes too. A stopped
# sandbox has no endpoint at all, and Boat can hand its old address to another
# machine. This command re-reads both through the authenticated Boat CLI
# session, so a new host key is never accepted on first sight over the network:
#   - state, endpoint, and restore progress from `boat info <id> --json`
#     (.sandbox.sshEndpoint as host:port, else .sandbox.ip on port 22);
#   - the ED25519 host key from `boat exec <id>`, Boat's API command channel,
#     asked only after `boat info` reports the sandbox running.
# Those two read-only calls are the only Boat commands it runs, each with the
# CLI's global --no-update flag. It never resumes, stops, or extends a sandbox.
#
# It rewrites exactly two things under ~/.ssh and prints what changed:
#   - one block in ~/.ssh/config, between the lines
#     "# >>> boat-alias <alias> >>>" and "# <<< boat-alias <alias> <<<": the
#     previous block is dropped and the new one appended at the end;
#   - one dedicated known-hosts file, ~/.ssh/known_hosts_<alias>, with every
#     "-" in the alias written as "_".
# The block records its sandbox id on a "# boat-sandbox <id>" line, names the
# Boat CLI's own key (~/.ssh/ascii_box_ed25519, created by the first
# `boat ssh`), pins the host key through HostKeyAlias and that known-hosts file
# with strict checking, and disables agent forwarding. It stores no secret and
# touches nothing else in ~/.ssh, including the default known_hosts file.
#
# The block holds an address only while Boat reports the sandbox running. When
# a refresh or a --verify finds the sandbox in any other state, an existing
# block is parked: it keeps only the sandbox id line, so the alias resolves to
# no address, and the known-hosts file is deleted. The refresh then refuses.
#
# --verify is the pre-connect check fm-on.sh runs for every route. It exits 3,
# changing nothing and calling no Boat command, when ~/.ssh/config holds no
# block for the alias. For a Boat alias it reads Boat at that moment and
# connects nothing itself:
#   - a sandbox that is not running parks the block and is refused (offline);
#   - a running sandbox whose endpoint differs from the block, or whose block
#     is parked, is refreshed from Boat first, without waiting for the restore;
#   - a running sandbox at the block's endpoint whose host key from Boat
#     differs from the pinned key is refused unchanged; an explicit refresh is
#     the deliberate way to accept it;
#   - a block with no sandbox id line, written before that line existed, is
#     refused until an explicit refresh rewrites it;
#   - a sandbox whose disk restore has not finished is refused.
# On success it prints the verified OpenSSH options, one Name=value per line,
# for the caller to pass with -o, so the connection uses the address and pin
# Boat just confirmed even when an earlier block in ~/.ssh/config would win.
# --remove deletes the block and the known-hosts file, and deletes
# ~/.ssh/config itself when the block was its whole content.
#
# It refuses, changing nothing, when ~/.ssh/config is a symbolic link (the
# rewrite would replace the link with a file) or holds a start line for this
# alias with no end line (the rest of the file would be read as the block).
#
# OpenSSH keeps the first value it reads for each option, and the block is
# last in the file. An earlier block that also matches the alias, such as
# "Host *", therefore wins for any option it sets, except the ones --verify
# prints for fm-on.sh to pass on the command line; `ssh -G <alias>` prints the
# values in force.
#
# After a resume the sandbox's home directory is restored lazily, and until
# Boat reports hydrated=true a file open there can block with no timeout, which
# makes an fm-on.sh call hang instead of fail. Once the alias is written this
# command waits for hydrated=true and exits non-zero when it does not arrive in
# time; the refreshed alias stays in place, and a rerun waits again.
#
# Output of a refresh on success:
#   sandbox=<id> state=<state>
#   endpoint: <old host:port|none> -> <host:port>
#   hostkey:  <old fingerprint|none> -> <fingerprint>
#   hydrated=true waited=<n>s
#
# Environment knobs:
#   FM_BOAT_BIN           the Boat CLI to run (boat)
#   FM_BOAT_HYDRATE_WAIT  seconds a refresh waits for the restore (600; 0 checks once)
#   FM_BOAT_HYDRATE_POLL  seconds between restore checks (5; above 0)
#
# Exit status: 0 the alias is current and the restore has finished, the alias
# was verified, or the alias was removed; 1 a refusal or failure, including a
# restore that did not finish in time and a sandbox that is not running;
# 2 invalid use; 3 (--verify only) the alias is not a Boat alias.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SSH_DIR=${HOME:-~}/.ssh
CONFIG="$SSH_DIR/config"
KEY="$SSH_DIR/ascii_box_ed25519"
BOAT_BIN=${FM_BOAT_BIN:-boat}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
bad_use() {
  printf 'error: %s\n' "$1" >&2
  printf 'usage: %s <sandbox-id> <alias> | --verify <alias> | --remove <alias> | --help\n' "${0##*/}" >&2
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

check_id() { # <sandbox-id>
  case "$1" in bx_*) ;; *) bad_use "not a sandbox id: $1" ;; esac
  case "$1" in *[!A-Za-z0-9_]*) bad_use "unsafe sandbox id: $1" ;; esac
}

check_tools() {
  local tool
  for tool in "$BOAT_BIN" jq ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but does not resolve"
  done
}

# Prints "<sandbox-id|none> <host:port|none>" for <alias>'s block, or nothing
# when the config holds no block for it.
block_fields() { # <alias>
  [ -f "$CONFIG" ] || return 0
  awk -v begin="# >>> boat-alias $1 >>>" -v end="# <<< boat-alias $1 <<<" '
    $0 == begin { on = 1; found = 1; next }
    $0 == end { on = 0; next }
    on && $1 == "#" && $2 == "boat-sandbox" { id = $3 }
    on && $1 == "HostName" { h = $2 }
    on && $1 == "Port" { p = $2 }
    END {
      if (on) exit 1
      if (found) print (id == "" ? "none" : id), (h == "" ? "none" : h ":" p)
    }
  ' "$CONFIG" ||
    die "$CONFIG has a '# >>> boat-alias $1 >>>' line with no matching end line; repair that block by hand"
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

# Sets INFO, STATE, HOST, PORT, and HYDRATED from one `boat info` read. HOST and
# PORT are set only for a running sandbox.
read_sandbox() { # <sandbox-id>
  INFO=$(fm_run_timed 15 "$BOAT_BIN" --no-update info "$1" --json) || die "boat info failed for $1"
  printf '%s' "$INFO" | jq -e '.sandbox | type == "object"' >/dev/null 2>&1 ||
    die "boat info returned unexpected output for $1"
  STATE=$(printf '%s' "$INFO" | jq -r '.sandbox.state // empty')
  HYDRATED=$(printf '%s' "$INFO" | jq -r '.sandbox.hydrated')
  HOST=
  PORT=
  case "$STATE" in ready|idle|running) ;; *) return 0 ;; esac
  local endpoint
  endpoint=$(printf '%s' "$INFO" | jq -r '.sandbox.sshEndpoint // empty')
  if [ -n "$endpoint" ]; then
    HOST=${endpoint%:*}
    PORT=${endpoint##*:}
  else
    HOST=$(printf '%s' "$INFO" | jq -r '.sandbox.ip // empty')
    PORT=22
  fi
  [ -n "$HOST" ] || die "boat info returned no SSH endpoint or ip for $1"
  case "$PORT" in ''|*[!0-9]*) die "unexpected SSH port: $PORT" ;; esac
  case "$HOST" in *[!A-Za-z0-9.:-]*) die "unexpected SSH host: $HOST" ;; esac
}

running() {
  case "$STATE" in ready|idle|running) return 0 ;; *) return 1 ;; esac
}

# Sets HOSTKEY ("ssh-ed25519 <base64>"). The host key comes over the Boat API
# command channel, not over SSH.
read_hostkey() { # <sandbox-id>
  local result
  result=$(fm_run_timed 45 "$BOAT_BIN" --no-update exec "$1" --json -- cat /etc/ssh/ssh_host_ed25519_key.pub) ||
    die "could not read the sandbox host key through boat exec"
  HOSTKEY=$(printf '%s' "$result" | jq -r 'select(.exitCode == 0) | .stdout' | awk 'NR == 1 { print $1, $2 }')
  case "$HOSTKEY" in 'ssh-ed25519 AAAA'*) ;; *) die "could not read the sandbox host key through boat exec" ;; esac
}

# Writes <alias>'s block and pin for the running sandbox read into HOST, PORT,
# and HOSTKEY, and sets OLD_TARGET, OLD_FP, and NEW_FP.
write_alias() { # <sandbox-id> <alias>
  OLD_FP=
  [ ! -f "$KNOWN" ] || OLD_FP=$(ssh-keygen -lf "$KNOWN" 2>/dev/null | awk '{print $2}')
  OLD_TARGET=$(block_fields "$2")
  OLD_TARGET=${OLD_TARGET#* }
  OLD_TARGET=${OLD_TARGET:-none}
  umask 077
  strip_config "$2"
  cat >> "$tmp" <<EOF
# >>> boat-alias $2 >>>
# boat-sandbox $1
Host $2
  HostName $HOST
  Port $PORT
  User user
  IdentityFile $KEY
  IdentitiesOnly yes
  HostKeyAlias $2
  UserKnownHostsFile $KNOWN
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  UpdateHostKeys no
  ForwardAgent no
  ConnectTimeout 15
# <<< boat-alias $2 <<<
EOF
  known_tmp="$KNOWN.tmp.$$"
  printf '%s %s\n' "$2" "$HOSTKEY" > "$known_tmp"
  NEW_FP=$(ssh-keygen -lf "$known_tmp" 2>/dev/null | awk '{print $2}')
  [ -n "$NEW_FP" ] || die "boat exec returned a host key ssh-keygen cannot read"
  mv -f -- "$known_tmp" "$KNOWN"
  known_tmp=
  publish_config
}

# Replaces an existing block for <alias> with one that holds no address, and
# deletes its pin. A config with no block for <alias> is left alone.
park_alias() { # <sandbox-id> <alias>
  [ -n "$(block_fields "$2")" ] || return 0
  umask 077
  strip_config "$2"
  printf '# >>> boat-alias %s >>>\n# boat-sandbox %s\n# parked: the sandbox is not running, so this alias has no address\n# <<< boat-alias %s <<<\n' \
    "$2" "$1" "$2" >> "$tmp"
  publish_config
  rm -f -- "$KNOWN"
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

if [ "${1:-}" = --verify ]; then
  [ "$#" -eq 2 ] || bad_use "--verify takes exactly one alias"
  ALIAS=$2
  check_alias "$ALIAS"
  KNOWN="$SSH_DIR/known_hosts_${ALIAS//-/_}"
  fields=$(block_fields "$ALIAS")
  [ -n "$fields" ] || exit 3
  ID=${fields%% *}
  target=${fields#* }
  [ "$ID" != none ] ||
    die "Boat alias $ALIAS names no sandbox, so it cannot be checked; run fm-boat-alias-refresh.sh <sandbox-id> $ALIAS"
  check_id "$ID"
  check_tools
  read_sandbox "$ID"
  if ! running; then
    park_alias "$ID" "$ALIAS"
    die "Boat sandbox $ID behind $ALIAS is not running (state=${STATE:-unknown}); treating it as offline without connecting"
  fi
  read_hostkey "$ID"
  if [ "$target" != "$HOST:$PORT" ]; then
    [ -f "$KEY" ] || die "no Boat CLI key at $KEY; run 'boat ssh $ID true' once"
    write_alias "$ID" "$ALIAS"
    printf 'refreshed Boat alias %s from Boat: endpoint %s -> %s:%s, hostkey %s -> %s\n' \
      "$ALIAS" "$OLD_TARGET" "$HOST" "$PORT" "${OLD_FP:-none}" "$NEW_FP" >&2
  else
    pinned=
    [ ! -f "$KNOWN" ] || pinned=$(awk -v alias="$ALIAS" '$1 == alias { print $2, $3; exit }' "$KNOWN")
    [ "$pinned" = "$HOSTKEY" ] ||
      die "the host key Boat reports for $ID does not match the key pinned for $ALIAS at $HOST:$PORT; refusing to connect (run fm-boat-alias-refresh.sh $ID $ALIAS to accept Boat's key deliberately)"
  fi
  [ "$HYDRATED" = true ] ||
    die "Boat sandbox $ID behind $ALIAS has not finished restoring its disk; treating it as offline without connecting"
  printf '%s\n' "HostName=$HOST" "Port=$PORT" "HostKeyAlias=$ALIAS" "UserKnownHostsFile=$KNOWN" \
    "GlobalKnownHostsFile=/dev/null" "StrictHostKeyChecking=yes" "UpdateHostKeys=no"
  exit 0
fi

[ "$#" -eq 2 ] || bad_use "expected a sandbox id and an alias"
ID=$1
ALIAS=$2
check_id "$ID"
check_alias "$ALIAS"
wait_max=${FM_BOAT_HYDRATE_WAIT:-600}
case "$wait_max" in ''|*[!0-9]*) bad_use "FM_BOAT_HYDRATE_WAIT must be a whole number of seconds" ;; esac
poll=${FM_BOAT_HYDRATE_POLL:-5}
case "$poll" in ''|*[!0-9]*|0) bad_use "FM_BOAT_HYDRATE_POLL must be a whole number of seconds above 0" ;; esac
check_tools
[ -f "$KEY" ] || die "no Boat CLI key at $KEY; run 'boat ssh $ID true' once"
KNOWN="$SSH_DIR/known_hosts_${ALIAS//-/_}"

read_sandbox "$ID"
if ! running; then
  park_alias "$ID" "$ALIAS"
  die "sandbox $ID is not running (state=${STATE:-unknown}); resume it first"
fi
read_hostkey "$ID"
write_alias "$ID" "$ALIAS"

printf 'sandbox=%s state=%s\n' "$ID" "$STATE"
printf 'endpoint: %s -> %s:%s\n' "$OLD_TARGET" "$HOST" "$PORT"
printf 'hostkey:  %s -> %s\n' "${OLD_FP:-none}" "$NEW_FP"

start=$(date +%s)
hydrated=$HYDRATED
while [ "$hydrated" != true ] && [ $(( $(date +%s) - start )) -lt "$wait_max" ]; do
  sleep "$poll"
  if next_info=$(fm_run_timed 15 "$BOAT_BIN" --no-update info "$ID" --json); then
    hydrated=$(printf '%s' "$next_info" | jq -r '.sandbox.hydrated' 2>/dev/null) || hydrated=
  else
    hydrated=
  fi
  [ -n "$hydrated" ] || hydrated=unknown
done
waited=$(( $(date +%s) - start ))
printf 'hydrated=%s waited=%ss\n' "$hydrated" "$waited"
[ "$hydrated" = true ] ||
  die "the alias is refreshed, but sandbox $ID has not finished restoring its disk after ${waited}s; a Firstmate call can hang until it does, so rerun this command before using the alias"
