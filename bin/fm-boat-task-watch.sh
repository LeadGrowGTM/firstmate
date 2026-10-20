#!/usr/bin/env bash
# Wake the home that sent a Boat task when that task reports.
# Usage: fm-boat-task-watch.sh arm <controller-home> <task-id>
#        fm-boat-task-watch.sh poll <controller-home> <task-id>
#        fm-boat-task-watch.sh disarm <task-id>
#
# Eligible second mate homes send code-only Boat work through one shared controller home,
# FM_HOME=<controller-home> bin/fm-boat-send.sh --code-only < request.json
# (docs/remote-secondmates.md "Sending from another home"). The worker then
# reports into the box's boat-eng home, which the sending home never reads.
# FM_HOME is always the sending home here and must be set explicitly.
#
# arm, run after the send succeeded, refuses unless the controller's
# state/.boat-task-box records the task, then writes state/boat-<task-id>.check.sh
# in the sending home and binds it with fm-check-register.sh. The existing
# watcher runs poll on its normal cadence and turns each printed line into a
# check: wake in the sending home; no new schedule or loop exists.
#
# poll reads the remote status through the controller with
# fm-on.sh boat-eng fm-remote-delta-read.sh state/<task-id>.status <offset>
# <prefix-sha256> 0 and prints one
# `boat-task <task-id>: <status line>` per new done, failed, blocked,
# needs-decision, or resolved line. Other lines only advance the byte and
# prefix-sha256 cursor in state/boat-<task-id>.boat-watch. A continuity break
# restarts from the beginning. An unreadable remote prints nothing.
# Neither poll nor fm-on.sh resumes, stops, or extends a box.
# FM_BOAT_WATCH_ON replaces fm-on.sh for tests only.
#
# disarm, run after FM_HOME=<controller-home> bin/fm-boat-send.sh --teardown
# <task-id>, retires the check with fm-check-unregister.sh and removes the cursor.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; }
[ "${1:-}" != --help ] || { usage; exit 0; }
FM_HOME=${FM_HOME:?FM_HOME is required and names the sending home}
STATE="$FM_HOME/state"
valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) return 1 ;; esac
}
valid_controller() {  # <controller-home>
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] && [ -d "$1/state" ] && [ ! -L "$1/state" ]
}
shim_content() {
  printf '%s\n' '#!/usr/bin/env bash' '# fm-boat-task-watch owned check' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-boat-task-watch.sh") poll $(printf '%q' "$1") $(printf '%q' "$2")"
}
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'sending home state directory is unavailable'

arm() {  # <controller-home> <task-id>
  local controller=$1 id=$2 shim map tmp
  valid_controller "$controller" || die 'controller home must be an absolute directory with a state directory'
  [ "$(cd "$controller" && pwd -P)" != "$(cd "$FM_HOME" && pwd -P)" ] ||
    die 'the controller watches its own Boat tasks with fm-on.sh; arm only in another home'
  map="$controller/state/.boat-task-box"
  if ! { [ -f "$map" ] && [ ! -L "$map" ] && awk -v id="$id" '$1 == id { found = 1 } END { exit !found }' "$map"; }; then
    die "controller has no Boat box recorded for $id; send it first"
  fi
  shim="$STATE/boat-$id.check.sh"
  [ ! -L "$shim" ] || die 'unsafe check path'
  if [ -e "$shim" ] && ! cmp -s "$shim" <(shim_content "$controller" "$id"); then
    die "check already exists and is not this watch: boat-$id"
  fi
  tmp=$(umask 077; mktemp "$STATE/.boat-watch-shim.XXXXXX") || die 'could not write the check'
  if ! shim_content "$controller" "$id" > "$tmp" ||
    ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    die 'could not write the check'
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "boat-$id" >/dev/null || { rm -f -- "$shim"; die 'could not register the check'; }
  printf 'armed: state/boat-%s.check.sh (controller %s)\n' "$id" "$controller"
}

poll() {  # <controller-home> <task-id>
  local controller=$1 id=$2 cursor offset=0 prefix tmp payload rc=0 status from to from_hash to_hash bytes line verb restarted=0
  local empty_hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  valid_controller "$controller" || return 0
  cursor="$STATE/boat-$id.boat-watch"
  [ ! -L "$cursor" ] || die 'unsafe cursor path'
  if [ -f "$cursor" ]; then
    offset=$(sed -n 's/^offset=\([0-9][0-9]*\)$/\1/p' "$cursor")
    prefix=$(sed -n 's/^prefix_sha256=\([a-f0-9]\{64\}\)$/\1/p' "$cursor")
  fi
  offset=${offset:-0}
  prefix=${prefix:-$empty_hash}
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-boat-watch.XXXXXX")
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-boat-watch.XXXXXX")
  # shellcheck disable=SC2064 # Expand the temporary paths now.
  trap "rm -f -- '$tmp' '$payload'" EXIT
  while :; do
    rc=0
    env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
      FM_HOME="$controller" "${FM_BOAT_WATCH_ON:-$SCRIPT_DIR/fm-on.sh}" boat-eng \
      fm-remote-delta-read.sh "state/$id.status" "$offset" "$prefix" 0 > "$tmp" 2>/dev/null < /dev/null || rc=$?
    [ "$rc" -eq 0 ] || break
    [ "$(sed -n '1p' "$tmp")" = schema=fm-remote-delta.v1 ] || break
    status=$(sed -n '2s/^status=//p' "$tmp")
    if [ "$status" = continuity-broken ]; then
      [ "$restarted" -eq 0 ] || break
      offset=0
      prefix=$empty_hash
      printf 'offset=%s\nprefix_sha256=%s\n' "$offset" "$prefix" > "$cursor.tmp" && mv -f -- "$cursor.tmp" "$cursor"
      restarted=1
      continue
    fi
    [ "$status" = delta ] && [ "$(sed -n '3p' "$tmp")" = "path=state/$id.status" ] || break
    from=$(sed -n '4s/^from_offset=//p' "$tmp")
    to=$(sed -n '5s/^to_offset=//p' "$tmp")
    from_hash=$(sed -n '6s/^from_prefix_sha256=//p' "$tmp")
    to_hash=$(sed -n '7s/^to_prefix_sha256=//p' "$tmp")
    bytes=$(sed -n '9s/^payload_bytes=//p' "$tmp")
    case "$to$bytes" in ''|*[!0-9]*) break ;; esac
    [ "$from" = "$offset" ] && [ "$from_hash" = "$prefix" ] &&
      [ "$to" -eq $((offset + bytes)) ] && [ "$bytes" -gt 0 ] &&
      [ "${#to_hash}" -eq 64 ] || break
    tail -n +12 "$tmp" > "$payload"
    [ "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" -eq "$bytes" ] || break
    while IFS= read -r line; do
      case "$line" in *': '*) ;; *) continue ;; esac
      verb=''
      status_line_verb "$line" verb
      case "$verb" in
        done|failed|blocked|needs-decision|resolved) printf 'boat-task %s: %s\n' "$id" "$line" ;;
      esac
    done < "$payload"
    offset=$to
    prefix=$to_hash
    printf 'offset=%s\nprefix_sha256=%s\n' "$offset" "$prefix" > "$cursor.tmp" && mv -f -- "$cursor.tmp" "$cursor"
  done
}

disarm() {  # <task-id>
  local id=$1 shim="$STATE/boat-$1.check.sh"
  [ -f "$shim" ] && [ ! -L "$shim" ] &&
    [ "$(sed -n '2p' "$shim")" = '# fm-boat-task-watch owned check' ] ||
    die "check is not this watch: boat-$id"
  "$SCRIPT_DIR/fm-check-unregister.sh" "boat-$id" >/dev/null || die 'could not retire the check'
  rm -f -- "$STATE/boat-$id.boat-watch"
  printf 'disarmed: state/boat-%s.check.sh\n' "$id"
}

case "${1:-}:$#" in
  arm:3|poll:3) valid_id "$3" || die 'invalid task id'; "$1" "$2" "$3" ;;
  disarm:2) valid_id "$2" || die 'invalid task id'; disarm "$2" ;;
  *) usage >&2; exit 2 ;;
esac
