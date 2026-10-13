#!/usr/bin/env bash
# fm-idle-exit.sh - end the agent session of a finished or parked worker, keep
# the work.
#
# Usage:
#   fm-idle-exit.sh [check]
#   fm-idle-exit.sh arm
#   fm-idle-exit.sh disarm
#   fm-idle-exit.sh --help
#
# A worker that reported done, or that is parked on a decision, keeps a live
# agent session (and its MCP children) until someone exits it, although its
# work already sits in its worktree, branch, report, and pipeline run. `check`
# stops at most one such agent per run through the control plane's
# `bin/fm-control.sh <id> exit --only-if-idle`, which preserves the endpoint,
# the worktree, and every uncommitted change, and refuses a turn that is not
# idle. It never tears down, discards, or relaunches anything; an exited
# worker is resumed the usual way, by relaunch, when its answer arrives.
#
# A direct ship or scout task in this home qualifies when its newest activity
# (the mtime of its status, turn-ended, and meta files and its inbox) is old
# enough and bin/fm-crew-state.sh reads it as:
#   done     after FM_IDLE_EXIT_DONE_SECS   (default 600, ten minutes)
#   parked   on an open decision after FM_IDLE_EXIT_PARKED_SECS (default 3600,
#            one hour)
# Every other state is left alone: working, paused, blocked, failed, and
# unknown keep their supervision. A secondmate and a remotely placed task are
# never touched.
#
# One exit per run keeps the run inside the watcher's per-check bound; the
# next poll takes the next candidate. A handled task is recorded in
# state/.idle-exit/<id> against its activity stamp. Successful exits are not
# probed again until new activity; failed exits are retried on later polls but
# reported only once per activity stamp. A record whose task is gone is pruned.
# Eligibility and activity are read again just before the exit call. An answer
# can still arrive after that read; it remains in the inbox and the worker can
# be relaunched with all work and records intact.
#
# Output follows the watcher's custom state-check contract: one line when an
# agent was stopped or an exit first failed for an activity stamp, nothing
# otherwise. `arm` writes
# state/idle-exit.check.sh and binds its bytes with fm-check-register.sh, so
# the watcher runs it on its FM_CHECK_INTERVAL cadence; `disarm` removes the
# shim, its trust binding, and the records. docs/configuration.md "Idle
# session exit" is the operator reference.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=idle-exit
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD_DIR="$STATE/.idle-exit"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
CREW_STATE_BIN="${FM_IDLE_EXIT_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
CONTROL_BIN="${FM_IDLE_EXIT_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
STATE_READ_SECS=8
CONTROL_START_BUDGET_SECS=12
CONTROL_SECS=12
MAX_LINE=1000

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '2,39{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-idle-exit: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

whole_secs() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$((10#$1))" ;;
  esac
}

DONE_SECS=$(whole_secs "${FM_IDLE_EXIT_DONE_SECS:-}" 600)
PARKED_SECS=$(whole_secs "${FM_IDLE_EXIT_PARKED_SECS:-}" 3600)

now_epoch() {
  case "${FM_IDLE_EXIT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_IDLE_EXIT_NOW" ;;
  esac
}

mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1
}

# Newest mtime among the task's status, turn-ended, meta, and inbox.
activity_epoch() {  # <id>
  local id=$1 f t newest=0
  for f in "$STATE/$id.status" "$STATE/$id.turn-ended" "$STATE/$id.meta" "$STATE/$id.inbox"; do
    [ -e "$f" ] || continue
    t=$(mtime "$f") || continue
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$t" -le "$newest" ] || newest=$t
  done
  printf '%s\n' "$newest"
}

record_outcome() {  # <id> <activity>
  local file="$RECORD_DIR/$1"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  [ "$(sed -n 1p "$file" 2>/dev/null)" = "$2" ] || return 0
  sed -n 2p "$file" 2>/dev/null
}

record_write() {  # <id> <activity> <outcome>
  local tmp
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || mkdir -m 700 "$RECORD_DIR" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$RECORD_DIR/.$1.XXXXXX" 2>/dev/null) || return 1
  if [ -d "$RECORD_DIR/$1" ] || ! printf '%s\n%s\n' "$2" "$3" > "$tmp" || ! mv -f -- "$tmp" "$RECORD_DIR/$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

prune_records() {
  local f id
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || return 0
  for f in "$RECORD_DIR"/*; do
    [ -f "$f" ] || continue
    id=${f##*/}
    [ -f "$STATE/$id.meta" ] || rm -f -- "$f"
  done
}

crew_state() {  # <id>
  local out
  out=$(FM_HOME="$FM_HOME" FM_CREW_STATE_NO_FORGE=1 \
    fm_run_timed "$STATE_READ_SECS" "$CREW_STATE_BIN" "$1" 2>/dev/null </dev/null) || return 1
  out=${out%%$'\n'*}
  case "$out" in
    'state: '*) printf '%s\n' "$out" ;;
    *) return 1 ;;
  esac
}

parked_on_decision() {  # <state-line> <status-file>
  local line=$1 part rest
  case "$line" in
    *' · source: status-log · '*) status_has_open_needs_decision "$2"; return ;;
    *' · source: run-step · '*) ;;
    *) return 1 ;;
  esac
  rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}
    rest=${rest#* · }
    [ "$part" = "$FM_GATE_HUMAN_DECISION" ] && return 0
  done
  return 1
}

run_check() {
  local meta id kind activity fresh_activity now started age state state_line fresh_state_line limit out rc left previous line=
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  prune_records
  now=$(now_epoch)
  started=$SECONDS
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ $((SECONDS - started)) -lt "$CONTROL_START_BUDGET_SECS" ] || break
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    kind=$(meta_value "$meta" kind)
    case "$kind" in secondmate) continue ;; esac
    [ -z "$(meta_value "$meta" remote_host)" ] || continue
    activity=$(activity_epoch "$id")
    [ "$activity" -gt 0 ] || continue
    age=$((now - activity))
    [ "$age" -ge "$DONE_SECS" ] || continue
    previous=$(record_outcome "$id" "$activity")
    case "$previous" in stopped|already-stopped|endpoint-gone) continue ;; esac
    state_line=$(crew_state "$id") || continue
    state=${state_line#state: }
    state=${state%% *}
    case "$state" in
      done) limit=$DONE_SECS ;;
      parked) parked_on_decision "$state_line" "$STATE/$id.status" || continue; limit=$PARKED_SECS ;;
      *) continue ;;
    esac
    [ "$age" -ge "$limit" ] || continue
    fresh_state_line=$(crew_state "$id") || continue
    [ "$fresh_state_line" = "$state_line" ] || continue
    if [ "$state" = parked ]; then
      parked_on_decision "$fresh_state_line" "$STATE/$id.status" || continue
    fi
    fresh_activity=$(activity_epoch "$id")
    [ "$fresh_activity" = "$activity" ] || continue
    left=$((27 - (SECONDS - started)))
    [ "$left" -ge 1 ] || break
    [ "$left" -le "$CONTROL_SECS" ] || left=$CONTROL_SECS
    rc=0
    out=$(FM_HOME="$FM_HOME" fm_run_timed "$left" "$CONTROL_BIN" "$id" exit --only-if-idle 2>&1 </dev/null) || rc=$?
    case "$rc" in
      0)
        record_write "$id" "$activity" "${out%% *}" || { line="could not record exit of $id"; break; }
        case "$out" in
          stopped*) line="exited $id ($state, idle $((age / 60))m); endpoint, worktree, and work kept" ;;
          *) continue ;;
        esac
        ;;
      3) continue ;;
      *)
        if [ "$previous" != failed ]; then
          record_write "$id" "$activity" failed || { line="could not record failed exit of $id"; break; }
          if fm_timed_out "$rc"; then
            line="exit of $id ($state, idle $((age / 60))m) timed out after ${left}s"
          else
            line="exit of $id ($state, idle $((age / 60))m) failed: ${out%%$'\n'*}"
          fi
        fi
        ;;
    esac
    break
  done
  [ -z "$line" ] || fm_cap_line "idle-exit: $line" "$MAX_LINE"
}

SHIM_TMP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.idle-exit-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# A shim without a matching trust binding is rejected by the watcher on every
# cycle, so a failed arm removes both rather than leave one unbound.
arm_failed() {  # <message>
  trap - HUP INT TERM
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  fail "$1"
}

arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-idle-exit.sh") check")
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  [ ! -d "$RECORD_DIR" ] || [ -L "$RECORD_DIR" ] || rm -rf -- "$RECORD_DIR"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || die_usage; run_check ;;
  arm) [ "$#" -eq 1 ] || die_usage; arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage; disarm ;;
  -h|--help|help) usage ;;
  *) die_usage ;;
esac
