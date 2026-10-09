#!/usr/bin/env bash
# Relaunch this home's idle second mates onto fresh sessions, one at a time.
#
# Usage: fm-session-refresh.sh [<task-id>...] [--help]
#
# A long-lived agent compacts its conversation again and again, and it keeps the
# instructions it read at launch: a re-read steer only appends a second copy.
# Replacing the agent is the only way a fresh session and the current
# instruction surface are what it runs on, so this command is meant to run on a
# schedule (nightly, after any memory pass) and is safe to run by hand.
#
# Scope is this home's own recorded direct reports: every state/<id>.meta under
# the explicit FM_HOME, or only the named task ids. Nothing outside this home's
# state directory is read or touched.
#
# Each direct report, in task-id order, is reported as one line:
#   <id>: relaunched                     replaced and confirmed idle again
#   <id>: busy, next night               busy right now; left alone
#   <id>: idle state unknown, next night no positive idle verdict; left alone
#   <id>: skipped (<reason>)             never refreshed by this command
#   <id>: FAILED <what>                  the run stops here; the control
#                                        plane's own report follows, indented
#
# Only kind=secondmate is refreshed. A ship or scout is task-bound work in
# progress: its replacement would resume its instructions and never settle idle,
# and its relaunch would append a progress note to those instructions every
# night, so it is skipped as if busy. A remotely placed second mate, and one on a
# backend that cannot prove an agent stopped, are skipped because the control
# plane refuses them.
#
# Idle is the semantic busy-state verdict owned by bin/fm-busy-lib.sh and
# nothing else: only a positive `idle` relaunches, and unknown is never idle.
# The verdict must read idle twice, FM_SESSION_REFRESH_SETTLE seconds apart,
# because a turn can continue after its idle event was recorded (a blocking
# Stop hook) and reads busy again only at its next tool call.
# That contract has no verified Codex source yet, so a Codex second mate always
# reads unknown and is never refreshed here.
#
# An idle second mate is relaunched with bin/fm-control.sh <id> relaunch, naming
# the harness, model, and effort its state/<id>.meta records (an absent model or
# effort is `default`), so the replacement runs the profile the old agent ran.
# The control plane owns the checkpoint, the journal, the exit, the launch, and
# the rollback. The replacement must then read idle again before the next one is
# touched, so a slow host never has two launches in flight.
#
# The first failure - a refused or failed relaunch, or a replacement that does
# not come back idle - stops the run and leaves every later direct report as it
# was. A busy or unknown one simply waits for the next run.
#
# Environment knobs:
#   FM_SESSION_REFRESH_SETTLE     seconds between the two idle reads (30)
#   FM_SESSION_REFRESH_IDLE_WAIT  seconds a replacement has to read idle (240)
#   FM_SESSION_REFRESH_POLL       seconds between those reads (5)
#   FM_CONTROL_LAUNCH_WAIT        passed through to bin/fm-control.sh unchanged
#
# Exit status: 0 every direct report was refreshed, left for the next run, or
# skipped; 1 a relaunch failed and the run stopped, or the home is unusable;
# 2 invalid use.
set -u

usage() {
  sed -n '2,58{s/^# \{0,1\}//;p;}' "$0"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-session-refresh refuses to resolve direct reports without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }

IDLE_WAIT=${FM_SESSION_REFRESH_IDLE_WAIT:-240}
POLL=${FM_SESSION_REFRESH_POLL:-5}
SETTLE=${FM_SESSION_REFRESH_SETTLE:-30}
case "$IDLE_WAIT" in
  ''|*[!0-9]*) echo "error: FM_SESSION_REFRESH_IDLE_WAIT must be a whole number of seconds: $IDLE_WAIT" >&2; exit 2 ;;
esac
case "$POLL" in
  ''|*[!0-9.]*|*.*.*) echo "error: FM_SESSION_REFRESH_POLL must be a number of seconds: $POLL" >&2; exit 2 ;;
esac
case "$SETTLE" in
  ''|*[!0-9.]*|*.*.*) echo "error: FM_SESSION_REFRESH_SETTLE must be a number of seconds: $SETTLE" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

ids=()
if [ "$#" -gt 0 ]; then
  for id in "$@"; do
    fm_task_id_creation_valid "$id" || { echo "error: '$id' is not a valid task id" >&2; exit 2; }
  done
  ids=("$@")
else
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    ids+=("${id%.meta}")
  done
fi

verdict() {  # <id>
  local v
  v=$(fm_busy_classify_meta "$STATE/$1.meta" "$1" "$STATE")
  printf '%s' "${v%% *}"
}

# refresh_one <id>: print the outcome line; return 1 only on a failure that
# must stop the run.
refresh_one() {
  local id=$1 meta="$STATE/$1.meta" kind backend harness model effort out waited
  if [ ! -f "$meta" ]; then
    echo "$id: FAILED no task record in $STATE"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    echo "$id: skipped ($kind task, refreshed only by finishing its work)"
    return 0
  fi
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    echo "$id: skipped (remote second mate; refresh it on its own host)"
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  if ! fm_control_backend_state_verified "$backend"; then
    echo "$id: skipped ($backend backend cannot prove an agent stopped)"
    return 0
  fi
  case "$(verdict "$id")" in
    idle) ;;
    busy) echo "$id: busy, next night"; return 0 ;;
    *) echo "$id: idle state unknown, next night"; return 0 ;;
  esac
  sleep "$SETTLE"
  case "$(verdict "$id")" in
    idle) ;;
    busy) echo "$id: busy, next night"; return 0 ;;
    *) echo "$id: idle state unknown, next night"; return 0 ;;
  esac

  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  if ! out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
      --harness "$harness" --model "${model:-default}" --effort "${effort:-default}" 2>&1); then
    echo "$id: FAILED relaunch"
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sed 's/^/  /'
    return 1
  fi

  waited=0
  while :; do
    if [ "$(verdict "$id")" = idle ]; then
      echo "$id: relaunched"
      return 0
    fi
    awk -v w="$waited" -v t="$IDLE_WAIT" 'BEGIN{exit !(w < t)}' || break
    sleep "$POLL"
    waited=$(awk -v w="$waited" -v p="$POLL" 'BEGIN{printf "%.3f", w + p}')
  done
  echo "$id: FAILED relaunched but never came back idle within ${IDLE_WAIT}s"
  return 1
}

for id in "${ids[@]}"; do
  if ! refresh_one "$id"; then
    echo "stopped: remaining direct reports left as they are"
    exit 1
  fi
done
exit 0
