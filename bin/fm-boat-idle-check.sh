#!/usr/bin/env bash
# fm-boat-idle-check.sh - PC-side Boat on-demand extend and idle stop.
#
# Usage:
#   fm-boat-idle-check.sh [check]
#   fm-boat-idle-check.sh arm
#   fm-boat-idle-check.sh disarm
#   fm-boat-idle-check.sh --help
#
# A Boat box runs only while it has a live worker or queued Boat work.
# fm-boat-send.sh resumes with the short on-demand timer and never extends it.
# This check does the other two halves from the PC, so a down box watcher
# does not matter: while fm-boat-worker.sh idle reports live work it re-arms
# the timer by the same amount, and once a listed running box reports no
# worker records or endpoints for idle_grace_seconds (900 when absent) it
# stops that box with the Boat CLI's stop command (snapshot kept, never
# delete). `check` prints one boat-idle: line only when firstmate should wake
# (a box it stopped, or a throttled extend, stop, or config failure), and
# prints nothing at all otherwise, so it composes with the watcher's custom
# state-check contract: `arm` writes state/boat-idle.check.sh and binds its
# bytes with fm-check-register.sh, the watcher runs it on its
# FM_CHECK_INTERVAL cadence, and its one line becomes a `check:` wake.
# `disarm` removes the shim, its trust binding, and both records. A home with
# no config/boat-spend.json is not checked: `check` is silent and `arm`
# refuses, and `arm` also refuses without a readable config/boat-box-id.
#
# Safety, in priority order: a box with a live worker is never stopped; a
# box not listed in config/boat-box-id is never touched; an unreadable idle
# report, state, timer, or instance is treated as busy, so blindness keeps a
# box up rather than stopping work. Before a stop, the boot instance and the
# worker check run again under the send lock, held through the stop, so a
# dispatch or resume that lands after the first probe is never stopped.
# Stopped boxes are left alone, and
# scheduled work still resumes only through fm-boat-send.sh when a
# Boat-eligible task is actually queued; nothing here is always-on.
#
# Exactly these Boat commands are run, each with the CLI's global --no-update
# flag: info, exec of the boot id, and limits (reads), resume --environment
# fm-code --ttl (extend only, with the sender's flags, because Boat restarts
# the timer at every resume), and stop (idle stop only). It never creates,
# deletes, shares, or reconfigures a sandbox and never touches billing. The
# idle probe runs fm-on.sh boat-eng fm-boat-worker.sh idle <instance>, which
# is the worker's own live record and endpoint count; with more than one
# listed box the check points state/.boat-route-box at the probed box and
# refreshes the alias to it under the send lock, because fm-on.sh follows
# the record and verifies the alias names it, and the lock keeps a concurrent
# dispatch from crossing either. The final worker and instance checks before
# a stop run under that same lock, held through the stop, so a dispatch that
# lands after the first probe cannot put a live worker on a stopped box.
# Extend caps the timer at the plan limit the same way the sender does.
# Extend skips its spend reservation on purpose: a live worker must not lose
# its box to a ceiling, and fm-boat-spend-check.sh stays the ceiling
# watchdog. A running box whose timer cannot be read is left alone; the spend
# check reports timerless boxes.
#
# The CLI comes from FM_BOAT_BIN, else "boat_bin" in the config, else `boat`
# on PATH. docs/configuration.md owns the config schema. Each Boat read is
# bounded to 6 seconds, the idle probe to 5, and the alias refresh to 4.
# Every timed action also fits the remaining poll budget, which ends before
# FM_CHECK_TIMEOUT. Sweeps rotate across listed boxes from a durable position,
# so a slow box does not starve every box behind it. Extend, stop, and refresh
# failures are reported at most once per hour per box, config problems at
# most once per 24 hours, and every completed stop is reported at once.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/boat-spend.json"
BOX_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/boat-box-id"
CHECK_ID=boat-idle
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
SINCE_FILE="$STATE/.boat-idle-since"
REPORT_FILE="$STATE/.boat-idle-report"
POS_FILE="$STATE/.boat-idle-pos"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1000
INFO_SECS=6
EXEC_SECS=6
IDLE_SECS=5
REFRESH_SECS=4
RESUME_SECS=60
STOP_SECS=30
LOCK_WAIT=5
CONFIG_INTERVAL=86400
ACTION_INTERVAL=3600
CHECK_DEADLINE=0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-boat-budget-lib.sh
. "$SCRIPT_DIR/fm-boat-budget-lib.sh"

usage() {
  sed -n '2,65{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-boat-idle-check: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

now_epoch() {
  case "${FM_BOAT_IDLE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_BOAT_IDLE_NOW" ;;
  esac
}

poll_remaining() {
  printf '%s\n' "$((CHECK_DEADLINE - $(date +%s)))"
}

poll_timed() {
  local seconds=$1 remaining
  shift
  remaining=$(poll_remaining)
  [ "$remaining" -gt 1 ] || return 124
  [ "$seconds" -lt "$((remaining - 1))" ] || seconds=$((remaining - 1))
  fm_run_timed "$seconds" "$@"
}

poll_lock() {
  local remaining seconds=$LOCK_WAIT
  remaining=$(poll_remaining)
  [ "$remaining" -gt 1 ] || return 1
  [ "$seconds" -lt "$((remaining - 1))" ] || seconds=$((remaining - 1))
  fm_lock_acquire_wait_max "$FM_HOME/state/.boat-send.lock" "$seconds"
}

valid_box() {
  [[ "$1" =~ ^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$ ]]
}

# record_read <file> <key>: prints the value, or nothing when absent.
record_read() {
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -v k="$key" '$1 == k { print $2; exit }' "$file" 2>/dev/null || true
}

# record_write <file> <key> <value>: upserts one line, keeping the others.
record_write() {
  local file=$1 key=$2 value=$3 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.boat-idle.XXXXXX" 2>/dev/null) || return 1
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    grep -Fv -- "$key " "$file" > "$tmp" 2>/dev/null || true
  fi
  printf '%s %s\n' "$key" "$value" >> "$tmp"
  if ! fm_pr_regular_destination_on_device_or_absent "$file" "$(fm_pr_file_device "$STATE")" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# record_drop <file> <key>: removes the key's line, leaving the others, and
# removes the file when no lines remain.
record_drop() {
  local file=$1 key=$2 tmp
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.boat-idle.XXXXXX" 2>/dev/null) || return 1
  grep -Fv -- "$key " "$file" > "$tmp" 2>/dev/null || true
  if [ -s "$tmp" ]; then
    if ! fm_pr_regular_destination_on_device_or_absent "$file" "$(fm_pr_file_device "$STATE")" \
      || ! mv -f -- "$tmp" "$file"; then
      rm -f -- "$tmp"
      return 1
    fi
  else
    rm -f -- "$tmp" "$file"
  fi
}

# report_due <key> <now> <interval>: true when no report is recorded or the
# last one is at least <interval> old, so repeats stay throttled.
report_due() {
  local key=$1 now=$2 interval=$3 last
  last=$(record_read "$REPORT_FILE" "$key")
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ "$last" -le "$now" ] || return 0
  [ $((now - last)) -ge "$interval" ]
}

report_note() {  # <key> <now>
  record_write "$REPORT_FILE" "$1" "$2" || true
}

BOAT_BIN=
boat_info() {  # <box>: prints "<state> <remaining-seconds>" or fails.
  local box=$1 out
  out=$(poll_timed "$INFO_SECS" "$BOAT_BIN" --no-update info "$box" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --argjson now "$(now_epoch)" '
    .sandbox |
    if (.state | type) != "string" then error("unreadable state")
    elif .state == "stopped" then "stopped 0"
    elif (.state | IN("ready", "idle", "running")) and (.archiveAfter | type) == "string" then
      "\(.state) \(((.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now | floor))"
    else error("unreadable timer") end' 2>/dev/null
}

boat_instance() {  # <box>: prints the boot id, or fails.
  local box=$1 out
  out=$(poll_timed "$EXEC_SECS" "$BOAT_BIN" --no-update exec "$box" --json -- cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '
    select(.exitCode == 0) | .stdout |
    select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\n?$")) |
    rtrimstr("\n")' 2>/dev/null
}

# idle_probe <box> <instance> <multi> <held>: prints yes when workers
# remain, no when none. Anything else (transport failure, unexpected text)
# is not no, so the caller treats it as busy. With more than one listed box
# the route record is pointed at this box and the alias refreshed to it under
# the send lock, because fm-on.sh follows the record and verifies the alias
# names it; held=1 skips the lock steps because the caller already holds the
# lock. Exit 2 when the refresh fails.
IDLE_LOCK=
release_idle_lock() {
  [ -z "$IDLE_LOCK" ] || fm_lock_release "$IDLE_LOCK" || true
  IDLE_LOCK=
}
idle_probe() {
  local box=$1 instance=$2 multi=$3 held=$4 out rc=0
  if [ "$multi" -eq 1 ]; then
    if [ "$held" -eq 0 ]; then
      poll_lock || return 1
      IDLE_LOCK="$FM_HOME/state/.boat-send.lock"
    fi
    if [ ! -d "$FM_HOME/state" ] || [ -L "$FM_HOME/state" ] \
      || { [ -e "$FM_HOME/state/.boat-route-box" ] && { [ -L "$FM_HOME/state/.boat-route-box" ] || [ ! -f "$FM_HOME/state/.boat-route-box" ]; }; } \
      || ! printf '%s\n' "$box" > "$FM_HOME/state/.boat-route-box"; then
      [ "$held" -eq 1 ] || release_idle_lock
      return 1
    fi
    # The refresh is bounded tighter than its own reads so a slow route
    # fails into the conservative extend path instead of eating the poll;
    # its alias writes are atomic renames, so a kill leaves no half state.
    if ! FM_BOAT_BIN="$BOAT_BIN" FM_BOAT_HYDRATE_WAIT=0 poll_timed "$REFRESH_SECS" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" "$box" boat-prove >/dev/null 2>&1; then
      [ "$held" -eq 1 ] || release_idle_lock
      return 2
    fi
  fi
  if [ "$held" -eq 0 ] && [ "$(poll_remaining)" -le 12 ]; then
    [ "$multi" -eq 0 ] || [ "$held" -eq 1 ] || release_idle_lock
    return 1
  fi
  out=$(FM_BOAT_BIN="$BOAT_BIN" poll_timed "$IDLE_SECS" "$SCRIPT_DIR/fm-on.sh" boat-eng fm-boat-worker.sh idle "$instance" 2>/dev/null) || rc=$?
  if [ "$multi" -eq 1 ] && [ "$held" -eq 0 ]; then
    release_idle_lock
  fi
  [ "$rc" -eq 0 ] || return 1
  case "$out" in
    'boat-tasks-remaining: no') printf 'no\n' ;;
    'boat-tasks-remaining: yes') printf 'yes\n' ;;
    *) return 1 ;;
  esac
}

# boat_plan_max: prints the plan timer (14400 paid, 7200 trial), or fails.
boat_plan_max() {
  local out
  out=$(poll_timed "$INFO_SECS" "$BOAT_BIN" --no-update limits --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '
    if .billingStatus == "active" then 14400
    elif .billingStatus == "trialing" then 7200
    else error("plan is off") end' 2>/dev/null
}

# box_extend <box> <ttl>: re-arms the timer for a live worker only, capped by
# the plan timer the same way the sender caps a new resume. An unreadable
# plan falls back to the configured timer and reports a failure only if the
# resume itself fails.
box_extend() {
  local box=$1 ttl=$2 max
  if [ "$(poll_remaining)" -gt 12 ] && max=$(boat_plan_max 2>/dev/null) && [ -n "$max" ] && [ "$max" -lt "$ttl" ]; then
    ttl=$max
  fi
  poll_timed "$RESUME_SECS" "$BOAT_BIN" --no-update resume "$box" \
    --environment fm-code --ttl "$ttl" --json >/dev/null 2>&1
}

# box_stop <box> <held>: stops the box, drops its environment receipt line,
# and parks the alias. held=1 skips the lock steps because the caller already
# holds the send lock across its final worker check and the stop. Reports
# through STOP_DETAIL on a partial failure; the box itself is already stopped
# then.
STOP_DETAIL=
box_stop() {
  local box=$1 held=$2 receipt kept
  STOP_DETAIL=
  if [ "$held" -eq 0 ]; then
    poll_lock || return 1
    IDLE_LOCK="$FM_HOME/state/.boat-send.lock"
  fi
  poll_timed "$STOP_SECS" "$BOAT_BIN" --no-update stop "$box" --json >/dev/null 2>&1 || {
    [ "$held" -eq 1 ] || release_idle_lock
    return 1
  }
  receipt="$FM_HOME/state/.boat-environment"
  if [ -f "$receipt" ] && [ ! -L "$receipt" ]; then
    kept=$(awk -v id="$box" '$1 != id' "$receipt") || {
      STOP_DETAIL='environment receipt is unreadable'
      [ "$held" -eq 1 ] || release_idle_lock
      return 2
    }
    if [ -n "$kept" ]; then
      printf '%s\n' "$kept" > "$receipt" || {
        STOP_DETAIL='environment receipt cannot be updated'
        [ "$held" -eq 1 ] || release_idle_lock
        return 2
      }
    else
      rm -f -- "$receipt"
    fi
  elif [ -L "$receipt" ]; then
    STOP_DETAIL='environment receipt path is unsafe'
    [ "$held" -eq 1 ] || release_idle_lock
    return 2
  fi
  FM_BOAT_BIN="$BOAT_BIN" poll_timed "$REFRESH_SECS" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" --park "$box" boat-prove >/dev/null 2>&1 || {
    STOP_DETAIL='alias park failed after stop'
    [ "$held" -eq 1 ] || release_idle_lock
    return 2
  }
  [ "$held" -eq 1 ] || release_idle_lock
  return 0
}

PARTS=
part() {  # <text>: appends one finding to the one line.
  if [ -z "$PARTS" ]; then
    PARTS=$1
  else
    PARTS="$PARTS; $1"
  fi
}

# check_box <box> <now> <ttl> <grace> <multi>: extend while busy, stop once
# the grace has passed with no workers, and otherwise stay silent.
check_box() {
  local box=$1 now=$2 ttl=$3 grace=$4 multi=$5
  local state remaining instance probe probe_instance probe_rc since idle_for stop_rc
  valid_box "$box" || return 0
  if ! read -r state remaining <<< "$(boat_info "$box" 2>/dev/null)" \
    || [ -z "$state" ] || [ -z "$remaining" ]; then
    return 0
  fi
  case "$state" in
    stopped) record_drop "$SINCE_FILE" "$box" || true; return 0 ;;
    ready|idle|running) ;;
    *) record_drop "$SINCE_FILE" "$box" || true; return 0 ;;
  esac
  if ! instance=$(boat_instance "$box" 2>/dev/null) || [ -z "$instance" ]; then
    record_drop "$SINCE_FILE" "$box" || true
    return 0
  fi
  probe_instance=$instance
  probe=$(idle_probe "$box" "$instance" "$multi" 0 2>/dev/null)
  probe_rc=$?
  if [ "$probe_rc" -eq 2 ]; then
    if report_due "refresh-$box" "$now" "$ACTION_INTERVAL"; then
      part "cannot point the worker route at $box; keeping it up"
      report_note "refresh-$box" "$now"
    fi
  fi
  if [ "$probe_rc" -ne 0 ]; then
    record_drop "$SINCE_FILE" "$box" || true
    if [ "$remaining" -lt "$ttl" ] && ! box_extend "$box" "$ttl" \
      && report_due "extend-$box" "$now" "$ACTION_INTERVAL"; then
      part "extend $box failed while its workers could not be confirmed"
      report_note "extend-$box" "$now"
    fi
    return 0
  fi
  if [ "$probe" = yes ]; then
    record_drop "$SINCE_FILE" "$box" || true
    if [ "$remaining" -lt "$ttl" ]; then
      if box_extend "$box" "$ttl"; then
        return 0
      fi
      if report_due "extend-$box" "$now" "$ACTION_INTERVAL"; then
        part "extend $box failed with live workers"
        report_note "extend-$box" "$now"
      fi
    fi
    return 0
  fi
  since=$(record_read "$SINCE_FILE" "$box")
  case "$since" in ''|*[!0-9]*) since=$now; record_write "$SINCE_FILE" "$box" "$since" || true ;; esac
  idle_for=$((now - since))
  [ "$idle_for" -ge 0 ] || { record_write "$SINCE_FILE" "$box" "$now" || true; return 0; }
  if [ "$idle_for" -lt "$grace" ]; then
    return 0
  fi
  # The final worker and instance checks run under the send lock, held
  # through the stop, so a dispatch that lands after the first probe cannot
  # put a live worker on a box this poll stops. A contended lock means a send
  # is active, which is liveness itself: restart the grace and stay silent.
  if [ "$(poll_remaining)" -le 8 ] || ! poll_lock; then
    record_write "$SINCE_FILE" "$box" "$now" || true
    return 0
  fi
  IDLE_LOCK="$FM_HOME/state/.boat-send.lock"
  if ! instance=$(boat_instance "$box" 2>/dev/null) || [ "$instance" != "$probe_instance" ]; then
    record_write "$SINCE_FILE" "$box" "$now" || true
    release_idle_lock
    return 0
  fi
  probe=$(idle_probe "$box" "$instance" "$multi" 1 2>/dev/null)
  probe_rc=$?
  if [ "$probe_rc" -eq 2 ]; then
    if report_due "refresh-$box" "$now" "$ACTION_INTERVAL"; then
      part "cannot point the worker route at $box; keeping it up"
      report_note "refresh-$box" "$now"
    fi
  fi
  if [ "$probe_rc" -ne 0 ] || [ "$probe" = yes ]; then
    record_drop "$SINCE_FILE" "$box" || true
    if [ "$remaining" -lt "$ttl" ] && ! box_extend "$box" "$ttl" \
      && report_due "extend-$box" "$now" "$ACTION_INTERVAL"; then
      part "extend $box failed with live workers"
      report_note "extend-$box" "$now"
    fi
    release_idle_lock
    return 0
  fi
  stop_rc=0
  box_stop "$box" 1 || stop_rc=$?
  release_idle_lock
  if [ "$stop_rc" -eq 0 ]; then
    record_drop "$SINCE_FILE" "$box" || true
    part "stopped $box after ${idle_for}s with no workers reported"
  elif [ "$stop_rc" -eq 2 ]; then
    record_drop "$SINCE_FILE" "$box" || true
    if report_due "stop-$box" "$now" "$ACTION_INTERVAL"; then
      part "stopped $box but $STOP_DETAIL"
      report_note "stop-$box" "$now"
    fi
  else
    record_write "$SINCE_FILE" "$box" "$now" || true
    if report_due "stop-$box" "$now" "$ACTION_INTERVAL"; then
      part "stop $box failed after ${idle_for}s with no workers reported"
      report_note "stop-$box" "$now"
    fi
  fi
}

run_check() {
  local now problem bin ids multi box pos count i timeout ORDER
  PARTS=
  [ -f "$CONFIG" ] || return 0
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  [ "$timeout" -le 30 ] || timeout=30
  [ "$timeout" -gt 3 ] || return 0
  CHECK_DEADLINE=$(($(date +%s) + timeout - 3))
  now=$(now_epoch)
  problem=
  if ! command -v jq >/dev/null 2>&1; then
    problem='jq is missing'
  elif ! fm_boat_load_reservation; then
    problem="config/boat-spend.json is invalid: ${FM_BOAT_SPEND_PROBLEM:-unreadable}"
  else
    bin=$(jq -r '.boat_bin // ""' "$CONFIG" 2>/dev/null) || problem='config/boat-spend.json is unreadable'
    if [ -z "$problem" ]; then
      BOAT_BIN=${FM_BOAT_BIN:-$bin}
      [ -n "$BOAT_BIN" ] || BOAT_BIN=boat
      if ! command -v "$BOAT_BIN" >/dev/null 2>&1; then
        problem='the Boat CLI is missing'
      elif ! ids=$(fm_boat_read_box_ids "$BOX_CONFIG" 2>/dev/null) || [ -z "$ids" ]; then
        problem='config/boat-box-id is missing or invalid'
      fi
    fi
  fi
  if [ -n "$problem" ]; then
    if report_due config "$now" "$CONFIG_INTERVAL"; then
      part "$problem"
      report_note config "$now"
    fi
  else
    multi=0
    [ "$(printf '%s\n' "$ids" | wc -l)" -le 1 ] || multi=1
    if [ "$multi" -eq 0 ]; then
      while IFS= read -r box; do
        [ "$(poll_remaining)" -gt 2 ] || break
        [ -n "$box" ] || continue
        check_box "$box" "$now" "$FM_BOAT_RESUME_TTL" "$FM_BOAT_IDLE_GRACE" "$multi"
      done <<< "$ids"
    else
      # Start each sweep where the last one left off, advancing past each box
      # as it starts, so a poll killed at FM_CHECK_TIMEOUT resumes with the
      # next box instead of starving every box behind one slow extend.
      mapfile -t ORDER <<< "$ids"
      count=${#ORDER[@]}
      pos=$(record_read "$POS_FILE" pos)
      case "$pos" in ''|*[!0-9]*) pos=0 ;; esac
      pos=$((pos % count))
      for ((i = 0; i < count; i++)); do
        [ "$(poll_remaining)" -gt 2 ] || break
        box=${ORDER[$pos]}
        pos=$(((pos + 1) % count))
        record_write "$POS_FILE" pos "$pos" || true
        [ -n "$box" ] || continue
        check_box "$box" "$now" "$FM_BOAT_RESUME_TTL" "$FM_BOAT_IDLE_GRACE" "$multi"
      done
    fi
  fi
  [ -z "$PARTS" ] || fm_cap_line "boat-idle: $PARTS" "$MAX_LINE"
}

SHIM_TMP=
ARM_BACKUP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.boat-idle-shim.XXXXXX" 2>/dev/null) || return 1
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

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.boat-idle-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# A shim without a matching trust binding is rejected by the watcher on every
# cycle, so a failed or interrupted arm keeps only a shim that is still bound.
arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

arm() {
  local state_device home want
  [ -f "$CONFIG" ] || fail "no Boat spend config at $CONFIG"
  fm_boat_load_reservation >/dev/null || fail "${FM_BOAT_SPEND_PROBLEM:-invalid config} ($CONFIG)"
  fm_boat_read_box_ids "$BOX_CONFIG" >/dev/null || fail "${FM_BOAT_BOX_PROBLEM:-invalid config} ($BOX_CONFIG)"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-boat-idle-check.sh") check")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$SINCE_FILE" "$REPORT_FILE" "$POS_FILE"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || die_usage; run_check ;;
  arm) [ "$#" -eq 1 ] || die_usage; arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage; disarm ;;
  -h|--help|help) usage ;;
  *) die_usage ;;
esac
