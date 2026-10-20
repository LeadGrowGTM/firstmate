#!/usr/bin/env bash
# bin/fm-boat-task-watch.sh: wake the home that sent a Boat task when it reports.
#
# Every case runs the real script against a sending home and a controller home
# in a temporary root. FM_BOAT_WATCH_ON replaces fm-on.sh with a stand-in that
# serves a fixture status file (or fails like a stopped box) and logs the home
# and arguments it was called with, so no Boat CLI, SSH, or real home is reached.
#
# What these pin:
#   1. arm refuses a task the controller has not recorded and refuses the
#      controller's own home; once recorded it writes a private shim bound by
#      the watcher's trust registration that runs poll for that controller.
#   2. poll reads the remote status through the controller's route and prints
#      each new done, failed, blocked, needs-decision, or resolved line once;
#      working and paused lines stay silent.
#   3. A partial last line waits until it is complete, and a remote file that
#      became shorter is read again from its start.
#   4. An unreadable remote is silent, then reported once after the lost
#      window when the last line was not terminal, and never after done.
#   5. disarm removes the shim, its trust binding, and the cursor.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-boat-task-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-boat-task-watch)
SENDER="$TMP_ROOT/sender"
CONTROLLER="$TMP_ROOT/controller"
FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$SENDER/state" "$CONTROLLER/state" "$FIXTURES"
export FIXTURES

ON="$TMP_ROOT/fm-on-standin"
cat > "$ON" <<'STANDIN'
#!/usr/bin/env bash
printf '%s|%s\n' "$FM_HOME" "$*" >> "$FIXTURES/calls"
[ ! -e "$FIXTURES/down" ] || exit 255
cat "$FIXTURES/remote-status"
STANDIN
chmod +x "$ON"

poll() {  # prints poll output
  FM_HOME="$SENDER" FM_BOAT_WATCH_ON="$ON" "$WATCH" poll "$CONTROLLER" t1
}

test_arm() {
  local out rc=0
  out=$(FM_HOME="$SENDER" "$WATCH" arm "$CONTROLLER" t1 2>&1) || rc=$?
  expect_code 1 "$rc" "arm without a controller record"
  assert_contains "$out" "send it first" "arm names the missing send"
  assert_absent "$SENDER/state/boat-t1.check.sh" "no shim before the task is recorded"
  printf 'other bx_aaaaaaaa\nt1 bx_bbbbbbbb\n' > "$CONTROLLER/state/.boat-task-box"
  rc=0
  out=$(FM_HOME="$CONTROLLER" "$WATCH" arm "$CONTROLLER" t1 2>&1) || rc=$?
  expect_code 1 "$rc" "arm in the controller's own home"
  out=$(FM_HOME="$SENDER" "$WATCH" arm "$CONTROLLER" t1) || fail "arm after the record: $out"
  assert_contains "$out" "armed: state/boat-t1.check.sh" "arm reports the shim"
  [ "$(stat -c %a "$SENDER/state/boat-t1.check.sh")" = 700 ] || fail "shim is private"
  assert_present "$SENDER/state/boat-t1.check-trust" "shim is bound for the watcher"
  printf 'working [at=1]: started\n' > "$FIXTURES/remote-status"
  : > "$FIXTURES/calls"
  out=$(env -u FM_HOME FM_BOAT_WATCH_ON="$ON" bash "$SENDER/state/boat-t1.check.sh")
  assert_equals "" "$out" "a working line is silent through the shim"
  assert_equals "$CONTROLLER|boat-eng fm-remote-file.sh get state/t1.status" "$(cat "$FIXTURES/calls")" \
    "poll reads the task status through the controller's boat-eng route"
  pass "arm writes a bound shim only for a recorded task"
}

test_new_lines_once() {
  local out
  printf 'working [at=1]: started\npaused [at=2]: waiting on validation\n' > "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "" "$out" "working and paused stay silent"
  printf 'needs-decision [at=3] [key=k1]: pick a name\n' >> "$FIXTURES/remote-status"
  printf 'resolved [at=4] [key=k1]: named\nblocked [at=5]: tests need a fixture\n' >> "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "boat-task t1: needs-decision [at=3] [key=k1]: pick a name
boat-task t1: resolved [at=4] [key=k1]: named
boat-task t1: blocked [at=5]: tests need a fixture" "$out" "each actionable line is reported in order"
  out=$(poll)
  assert_equals "" "$out" "reported lines are not repeated"
  printf 'done [at=6]: PR https://github.com/LeadGrowGTM/firstmate/pull/1 ready' >> "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "" "$out" "a partial last line waits"
  printf '\n' >> "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "boat-task t1: done [at=6]: PR https://github.com/LeadGrowGTM/firstmate/pull/1 ready" "$out" \
    "the completed done line is reported"
  printf 'failed [at=7]: rerun\n' > "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "boat-task t1: failed [at=7]: rerun" "$out" "a shorter remote file is read from its start"
  pass "poll reports each actionable line once"
}

test_unreadable() {
  local out
  printf 'working [at=1]: started\n' > "$FIXTURES/remote-status"
  rm -f "$SENDER/state/boat-t1.boat-watch"
  poll >/dev/null
  touch "$FIXTURES/down"
  out=$(FM_BOAT_WATCH_LOST_SECS=1 poll)
  assert_equals "" "$out" "first unreadable poll is silent"
  sleep 2
  out=$(FM_BOAT_WATCH_LOST_SECS=1 poll)
  assert_contains "$out" "boat-task t1: status unreadable" "a lasting loss after working is reported"
  assert_contains "$out" "last seen: working" "the report names the last seen state"
  out=$(FM_BOAT_WATCH_LOST_SECS=1 poll)
  assert_equals "" "$out" "the loss is reported once"
  rm -f "$FIXTURES/down"
  printf 'working [at=1]: started\ndone [at=2]: report ready\n' > "$FIXTURES/remote-status"
  out=$(poll)
  assert_equals "boat-task t1: done [at=2]: report ready" "$out" "recovery resumes reporting"
  touch "$FIXTURES/down"
  FM_BOAT_WATCH_LOST_SECS=1 poll >/dev/null
  sleep 2
  out=$(FM_BOAT_WATCH_LOST_SECS=1 poll)
  assert_equals "" "$out" "a loss after done stays silent"
  rm -f "$FIXTURES/down"
  pass "an unreadable remote is reported once and never after done"
}

test_disarm() {
  local out
  out=$(FM_HOME="$SENDER" "$WATCH" disarm t1) || fail "disarm: $out"
  assert_absent "$SENDER/state/boat-t1.check.sh" "disarm removes the shim"
  assert_absent "$SENDER/state/boat-t1.check-trust" "disarm removes the trust binding"
  assert_absent "$SENDER/state/boat-t1.boat-watch" "disarm removes the cursor"
  pass "disarm retires the watch"
}

test_arm
test_new_lines_once
test_unreadable
test_disarm
pass "fm-boat-task-watch"
