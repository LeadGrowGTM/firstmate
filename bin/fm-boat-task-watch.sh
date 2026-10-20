#!/usr/bin/env bash
# Wake the home that sent a Boat task when that task reports.
# Usage: fm-boat-task-watch.sh arm <controller-home> <task-id>
#        fm-boat-task-watch.sh poll <controller-home> <task-id>
#        fm-boat-task-watch.sh disarm <task-id>
#
# Every second mate home sends Boat work through one shared controller home,
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
# fm-on.sh boat-eng fm-remote-file.sh get state/<task-id>.status and prints one
# `boat-task <task-id>: <status line>` per new done, failed, blocked,
# needs-decision, or resolved line. Other lines only advance the cursor
# state/boat-<task-id>.boat-watch. A remote file shorter than the cursor is read
# again from its start. An unreadable remote (box stopped, unreachable, or
# status gone) prints nothing, except one line once it has stayed unreadable
# for FM_BOAT_WATCH_LOST_SECS (default 1800) after a last seen line that was not
# done or failed. Neither poll nor fm-on.sh resumes, stops, or extends a box.
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
  tmp=$(umask 077; mktemp "$STATE/.boat-watch-shim.XXXXXX") || die 'could not write the check'
  if ! printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-boat-task-watch.sh") poll $(printf '%q' "$controller") $(printf '%q' "$id")" > "$tmp" ||
    ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    die 'could not write the check'
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "boat-$id" >/dev/null || { rm -f -- "$shim"; die 'could not register the check'; }
  printf 'armed: state/boat-%s.check.sh (controller %s)\n' "$id" "$controller"
}

poll() {  # <controller-home> <task-id>
  local controller=$1 id=$2 cursor seen=0 lost_since='' lost_reported=0 last_verb='' tmp rc=0 now lines
  local lost_secs=${FM_BOAT_WATCH_LOST_SECS:-1800} line verb tail_tmp
  case "$lost_secs" in ''|*[!0-9]*|0) die 'FM_BOAT_WATCH_LOST_SECS must be a whole number of seconds above 0' ;; esac
  valid_controller "$controller" || return 0
  cursor="$STATE/boat-$id.boat-watch"
  [ ! -L "$cursor" ] || die 'unsafe cursor path'
  if [ -f "$cursor" ]; then
    seen=$(sed -n 's/^lines=\([0-9][0-9]*\)$/\1/p' "$cursor")
    lost_since=$(sed -n 's/^lost_since=\([0-9][0-9]*\)$/\1/p' "$cursor")
    lost_reported=$(sed -n 's/^lost_reported=\([01]\)$/\1/p' "$cursor")
    last_verb=$(sed -n 's/^last_verb=\([a-z-]*\)$/\1/p' "$cursor")
  fi
  seen=${seen:-0}
  lost_reported=${lost_reported:-0}
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-boat-watch.XXXXXX")
  tail_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-boat-watch.XXXXXX")
  # shellcheck disable=SC2064 # Expand the temporary paths now.
  trap "rm -f -- '$tmp' '$tail_tmp'" EXIT
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$controller" "${FM_BOAT_WATCH_ON:-$SCRIPT_DIR/fm-on.sh}" boat-eng \
    fm-remote-file.sh get "state/$id.status" > "$tmp" 2>/dev/null < /dev/null || rc=$?
  now=$(date +%s)
  if [ "$rc" -ne 0 ]; then
    if [ -z "$lost_since" ]; then
      lost_since=$now
    elif [ "$lost_reported" -eq 0 ] && [ $((now - lost_since)) -ge "$lost_secs" ]; then
      case "$last_verb" in
        done|failed) ;;
        *)
          printf 'boat-task %s: status unreadable for %s min (box stopped or unreachable); last seen: %s; inspect with FM_HOME=%s bin/fm-on.sh boat-eng fm-crew-state.sh %s\n' \
            "$id" "$(((now - lost_since) / 60))" "${last_verb:-nothing}" "$controller" "$id"
          lost_reported=1
          ;;
      esac
    fi
  else
    # Count only complete lines, so a line still being appended is read whole next time.
    lines=$(wc -l < "$tmp" | tr -d ' ')
    [ "$lines" -ge "$seen" ] || seen=0
    head -n "$lines" "$tmp" | tail -n "+$((seen + 1))" > "$tail_tmp"
    while IFS= read -r line; do
      case "$line" in *': '*) ;; *) continue ;; esac
      verb=''
      status_line_verb "$line" verb
      case "$verb" in
        done|failed|blocked|needs-decision|resolved) printf 'boat-task %s: %s\n' "$id" "$line" ;;
      esac
      case "$verb" in working|paused|done|failed|blocked|needs-decision|resolved) last_verb=$verb ;; esac
    done < "$tail_tmp"
    seen=$lines
    lost_since=''
    lost_reported=0
  fi
  printf 'lines=%s\nlost_since=%s\nlost_reported=%s\nlast_verb=%s\n' \
    "$seen" "$lost_since" "$lost_reported" "$last_verb" > "$cursor.tmp" && mv -f -- "$cursor.tmp" "$cursor"
}

disarm() {  # <task-id>
  local id=$1
  "$SCRIPT_DIR/fm-check-unregister.sh" "boat-$id" >/dev/null || die 'could not retire the check'
  rm -f -- "$STATE/boat-$id.boat-watch"
  printf 'disarmed: state/boat-%s.check.sh\n' "$id"
}

case "${1:-}:$#" in
  arm:3|poll:3) valid_id "$3" || die 'invalid task id'; "$1" "$2" "$3" ;;
  disarm:2) valid_id "$2" || die 'invalid task id'; disarm "$2" ;;
  *) usage >&2; exit 2 ;;
esac
