#!/usr/bin/env bash
# bin/fm-idle-exit.sh: end the session of a finished or parked worker.
#
# Every case runs the real script inside a temporary home against two
# stand-ins selected through its override variables: a crew-state reader that
# prints the fixture state for each task, and a control plane that records
# every call and answers from a fixture, so no real agent, pane, or pipeline is
# ever reached.
#
# What these pin:
#   1. A done task idle past ten minutes is exited, with exactly
#      `<id> exit --only-if-idle`, and reported on one line.
#   2. A parked task with an open decision waits an hour; a worker-owned gate
#      is left alone.
#   3. Working, paused, blocked, failed, and unknown tasks, secondmates, and
#      remote tasks are never exited, and young tasks are not even read.
#   4. One exit per run; the next run takes the next candidate.
#   5. A handled task is not probed again until it shows new activity, and a
#      record whose task is gone is pruned.
#   6. A turn that became busy (exit 3) is left running silently, and a failed
#      exit is reported once.
#   7. Arm runs the check through the registered shim; disarm removes it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-idle-exit.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-exit)
NOW=1791900000

FAKE_STATE="$TMP_ROOT/crew-state"
cat > "$FAKE_STATE" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FIXTURES/state-reads.log"
if [ -f "$FIXTURES/$1.answer-on-second-read" ] \
  && [ "$(grep -c -x "$1" "$FIXTURES/state-reads.log")" -eq 2 ]; then
  touch "$FM_HOME/state/$1.inbox"
  printf 'resolved [key=review]: answer arrived\n' >> "$FM_HOME/state/$1.status"
fi
s=$(cat "$FIXTURES/$1.state" 2>/dev/null) || s=unknown
detail=$(cat "$FIXTURES/$1.detail" 2>/dev/null) || detail='source: pane · fixture'
printf 'state: %s · %s\n' "$s" "$detail"
FAKE
chmod +x "$FAKE_STATE"

FAKE_CONTROL="$TMP_ROOT/control"
cat > "$FAKE_CONTROL" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURES/control.log"
[ ! -f "$FIXTURES/$1.preamble" ] || cat "$FIXTURES/$1.preamble" >&2
rc=$(cat "$FIXTURES/$1.rc" 2>/dev/null) || rc=0
case "$rc" in
  0) printf '%s %s harness=claude\n' "$(cat "$FIXTURES/$1.out" 2>/dev/null || echo stopped)" "$1" ;;
  3) echo "error: task $1 reads 'busy' rather than idle at the exit point" >&2 ;;
  *) echo "error: exit of $1 could not be proven" >&2 ;;
esac
exit "$rc"
FAKE
chmod +x "$FAKE_CONTROL"

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/fixtures"
  printf '%s\n' "$home"
}

# add_task <home> <id> <state> <idle-seconds> [meta-line...]
add_task() {
  local home=$1 id=$2 state=$3 idle=$4 line
  shift 4
  {
    printf 'window=firstmate:fm-%s\nkind=ship\nharness=claude\n' "$id"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/state/$id.meta"
  printf 'done: finished\n' > "$home/state/$id.status"
  printf '%s\n' "$state" > "$home/fixtures/$id.state"
  fm_touch_epoch $((NOW - idle)) "$home/state/$id.meta" "$home/state/$id.status"
}

run_check() {
  local home=$1
  shift
  env FM_HOME="$home" FIXTURES="$home/fixtures" FM_IDLE_EXIT_NOW="$NOW" \
    FM_IDLE_EXIT_CREW_STATE_BIN="$FAKE_STATE" FM_IDLE_EXIT_CONTROL_BIN="$FAKE_CONTROL" \
    "$@" "$CHECK" check 2>&1
}

log() { [ -f "$1/fixtures/$2.log" ] && cat "$1/fixtures/$2.log" || true; }

test_done_task_is_exited_after_ten_minutes() {
  local home out
  home=$(make_home done-old)
  add_task "$home" t1 'done' 660
  out=$(run_check "$home") || fail "check exited non-zero: $out"
  assert_equals 'idle-exit: exited t1 (done, idle 11m); endpoint, worktree, and work kept' "$out" "done exit line"
  assert_equals 't1 exit --only-if-idle' "$(log "$home" control)" "the control plane call"
  home=$(make_home done-young)
  add_task "$home" t1 'done' 540
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a done task idle under ten minutes should be left: $out"
  assert_equals '' "$(log "$home" state-reads)" "a young task should not even be read"
  pass "fm-idle-exit: a done task is exited after ten idle minutes"
}

test_parked_task_waits_an_hour() {
  local home out
  home=$(make_home parked)
  add_task "$home" p1 parked 1800
  printf 'needs-decision [key=review]: waiting for Mitch\n' > "$home/state/p1.status"
  echo 'source: status-log · waiting for Mitch' > "$home/fixtures/p1.detail"
  fm_touch_epoch $((NOW - 1800)) "$home/state/p1.status"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a parked task idle 30 minutes should be left: $out"
  assert_equals '' "$(log "$home" control)" "no exit before an hour"
  fm_touch_epoch $((NOW - 3700)) "$home/state/p1.meta" "$home/state/p1.status"
  out=$(run_check "$home")
  assert_equals 'idle-exit: exited p1 (parked, idle 61m); endpoint, worktree, and work kept' "$out" "parked exit line"
  pass "fm-idle-exit: a parked task is exited after an idle hour"
}

test_parked_gate_requires_human_decision() {
  local home out
  home=$(make_home gate)
  add_task "$home" own parked 7200
  echo 'source: run-step · parked at fix_review · run: r1' > "$home/fixtures/own.detail"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "worker-owned gate should stay active: $out"
  assert_equals '' "$(log "$home" control)" "worker-owned gate was exited"
  add_task "$home" human parked 7200
  echo 'source: run-step · parked at fix_review · ask-user: authority decision · run: r2' > "$home/fixtures/human.detail"
  out=$(run_check "$home")
  assert_contains "$out" 'exited human (parked' "human gate should be exited"
  pass "fm-idle-exit: only a human-owned parked gate is exited"
}

test_new_activity_before_exit_keeps_worker_running() {
  local home out
  home=$(make_home answered-done)
  add_task "$home" t1 'done' 7200
  : > "$home/fixtures/t1.answer-on-second-read"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a newly answered done task should remain: $out"
  assert_equals '' "$(log "$home" control)" "a newly answered done task was exited"
  home=$(make_home answered-parked)
  add_task "$home" p1 parked 7200
  printf 'needs-decision [key=review]: waiting for Mitch\n' > "$home/state/p1.status"
  echo 'source: status-log · waiting for Mitch' > "$home/fixtures/p1.detail"
  fm_touch_epoch $((NOW - 7200)) "$home/state/p1.status"
  : > "$home/fixtures/p1.answer-on-second-read"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an answered decision should remain: $out"
  assert_equals '' "$(log "$home" control)" "an answered parked task was exited"
  pass "fm-idle-exit: activity and decision changes before exit keep the worker running"
}

test_other_states_and_kinds_are_never_exited() {
  local home out s
  home=$(make_home others)
  for s in working paused blocked failed unknown; do
    add_task "$home" "s-$s" "$s" 7200
  done
  add_task "$home" mate 'done' 7200 kind=secondmate
  add_task "$home" far 'done' 7200 remote_host=box
  out=$(run_check "$home")
  [ -z "$out" ] || fail "nothing should be exited: $out"
  assert_equals '' "$(log "$home" control)" "the control plane must not be called"
  assert_not_contains "$(log "$home" state-reads)" mate "a secondmate is not read"
  assert_not_contains "$(log "$home" state-reads)" far "a remote task is not read"
  pass "fm-idle-exit: other states, secondmates, and remote tasks are left alone"
}

test_one_exit_per_run_and_records_stop_reprobing() {
  local home out
  home=$(make_home one)
  add_task "$home" a1 'done' 7200
  add_task "$home" b1 'done' 7200
  out=$(run_check "$home")
  assert_equals 'idle-exit: exited a1 (done, idle 120m); endpoint, worktree, and work kept' "$out" "first run takes one"
  out=$(run_check "$home")
  assert_equals 'idle-exit: exited b1 (done, idle 120m); endpoint, worktree, and work kept' "$out" "next run takes the next"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "handled tasks should be silent: $out"
  assert_equals 2 "$(log "$home" control | wc -l | tr -d ' ')" "each task is exited once"
  fm_touch_epoch $((NOW - 900)) "$home/state/a1.status"
  printf 'already-stopped\n' > "$home/fixtures/a1.out"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an already-stopped agent is recorded silently: $out"
  assert_equals 3 "$(log "$home" control | wc -l | tr -d ' ')" "new activity is probed once more"
  rm -f "$home/state/b1.meta"
  run_check "$home" >/dev/null
  assert_absent "$home/state/.idle-exit/b1" "a record whose task is gone should be pruned"
  assert_present "$home/state/.idle-exit/a1" "a live task's record stays"
  pass "fm-idle-exit: one exit per run, handled tasks are not re-probed, records are pruned"
}

test_endpoint_gone_is_not_reprobed_until_activity_changes() {
  local home out
  home=$(make_home endpoint-gone)
  add_task "$home" gone 'done' 7200
  printf 'endpoint-gone\n' > "$home/fixtures/gone.out"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an already absent endpoint should be silent: $out"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a handled absent endpoint should remain silent: $out"
  assert_equals 1 "$(log "$home" control | wc -l | tr -d ' ')" "an absent endpoint was reprobed without new activity"
  fm_touch_epoch $((NOW - 900)) "$home/state/gone.status"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an absent endpoint after new activity should be silent: $out"
  assert_equals 2 "$(log "$home" control | wc -l | tr -d ' ')" "new activity should permit a fresh probe"
  pass "fm-idle-exit: an absent endpoint is handled until new activity"
}

test_control_preamble_does_not_hide_exit_result() {
  local home out
  home=$(make_home preamble)
  add_task "$home" t1 'done' 7200
  printf 'fm-gate-refuse: gate agent lifecycle permitted only against lab home\n' > "$home/fixtures/t1.preamble"
  out=$(run_check "$home")
  assert_contains "$out" 'idle-exit: exited t1 (done' "a control preamble must not hide a successful exit"
  assert_equals stopped "$(sed -n 2p "$home/state/.idle-exit/t1")" "the final control outcome is recorded"
  pass "fm-idle-exit: a control preamble does not hide the exit result"
}

test_busy_turn_is_left_and_failure_reported_once() {
  local home out
  home=$(make_home busy)
  add_task "$home" bz 'done' 7200
  printf '3\n' > "$home/fixtures/bz.rc"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a turn that became busy should be left silently: $out"
  printf '1\n' > "$home/fixtures/bz.rc"
  out=$(run_check "$home")
  assert_contains "$out" 'idle-exit: exit of bz (done, idle 120m) failed: error: exit of bz could not be proven' "failure line"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a failure is reported once per activity: $out"
  assert_equals 3 "$(log "$home" control | wc -l | tr -d ' ')" "a failed exit is retried"
  printf '0\n' > "$home/fixtures/bz.rc"
  out=$(run_check "$home")
  assert_contains "$out" 'idle-exit: exited bz' "a later successful exit is reported"
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a successful exit should not be retried: $out"
  assert_equals 4 "$(log "$home" control | wc -l | tr -d ' ')" "successful exit stops retries"
  pass "fm-idle-exit: a busy turn is left running and failed exits retry without repeat reports"
}

test_record_failure_is_reported() {
  local home out
  home=$(make_home record-failure)
  add_task "$home" t1 'done' 7200
  mkdir -p "$home/state/.idle-exit/t1"
  out=$(run_check "$home")
  assert_contains "$out" 'idle-exit: could not record exit of t1' "record failure must be visible"
  pass "fm-idle-exit: a failed record write is reported"
}

test_arm_runs_through_the_registered_shim_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  add_task "$home" t1 'done' 7200
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/idle-exit.check.sh' "arm output"
  assert_present "$home/state/idle-exit.check-trust" "arm did not bind the shim"
  out=$(env -u FM_HOME FIXTURES="$home/fixtures" FM_IDLE_EXIT_NOW="$NOW" \
    FM_IDLE_EXIT_CREW_STATE_BIN="$FAKE_STATE" FM_IDLE_EXIT_CONTROL_BIN="$FAKE_CONTROL" \
    "$home/state/idle-exit.check.sh" 2>&1) || fail "registered shim failed: $out"
  assert_contains "$out" 'idle-exit: exited t1' "shim did not run the check in the pinned home"
  env FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/idle-exit.check.sh" "disarm left the shim"
  assert_absent "$home/state/idle-exit.check-trust" "disarm left the trust binding"
  assert_absent "$home/state/.idle-exit" "disarm left the records"
  pass "fm-idle-exit: arm binds the shim and disarm removes it"
}

test_done_task_is_exited_after_ten_minutes
test_parked_task_waits_an_hour
test_parked_gate_requires_human_decision
test_new_activity_before_exit_keeps_worker_running
test_other_states_and_kinds_are_never_exited
test_one_exit_per_run_and_records_stop_reprobing
test_endpoint_gone_is_not_reprobed_until_activity_changes
test_control_preamble_does_not_hide_exit_result
test_busy_turn_is_left_and_failure_reported_once
test_record_failure_is_reported
test_arm_runs_through_the_registered_shim_and_disarm_removes_it
pass "fm-idle-exit"
