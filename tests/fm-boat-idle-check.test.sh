#!/usr/bin/env bash
# bin/fm-boat-idle-check.sh: the PC-side Boat on-demand extend and idle stop.
#
# Every case runs the real script against a fake `boat` binary (selected with
# FM_BOAT_BIN) that serves per-box fixtures and records every argument it
# receives, plus stub fm-on.sh (idle probe) and fm-boat-alias-refresh.sh
# (park), inside a temporary home, so neither the real Boat CLI, SSH, nor a
# real home is ever reached. The clock is pinned with FM_BOAT_IDLE_NOW.
#
# What these pin:
#   1. A stopped box is silent and untouched, and a busy box whose timer is
#      still full is silent without an extend.
#   2. A busy box with a short timer is re-armed with the configured short
#      timer (3600 by default), silently.
#   3. An idle box is recorded on first sight and stopped only after the
#      grace (900 by default) with no workers, dropping its receipt line and
#      parking the alias, with one boat-idle: line.
#   4. A box with a live worker is never stopped, even past the grace; an
#      unreadable idle report, state, timer, or instance is treated as busy.
#   5. A box not listed in config/boat-box-id is never touched.
#   6. A changed boot instance between probe and stop skips the stop.
#   7. Extend and stop failures, and config problems, are reported throttled.
#   8. A home with no spend config is silent and never calls Boat, and arm
#      refuses without a spend config or a readable box list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

CHECK="$ROOT/bin/fm-boat-idle-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-boat-idle-check)
NOW=1792368000 # 2026-10-19T00:00:00Z
BIN="$TMP_ROOT/bin"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$BIN"
cp "$CHECK" "$BIN/"
cp "$ROOT/bin/"*-lib.sh "$BIN/"
cp "$ROOT/bin/fm-check-register.sh" "$BIN/"
BOX=bx_aaaaaaaa

# The Boat stand-in answers info, exec of the boot id, resume, and stop from
# per-box fixtures and logs one line per call. Any other shape exits 97, so
# a stray command (limits, list, create, delete) is both recorded and refused.
cat > "$FAKEBIN/boat" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'boat %s\n' "$*" >> "$FIXTURES/calls"
[ "${1:-}" = --no-update ] || exit 97
shift
case "${1:-}" in
  info)
    box=${2:-}; [ "${3:-}" = --json ] || exit 97
    [ ! -e "$FIXTURES/$box.info.fail" ] || exit 1
    [ -f "$FIXTURES/$box.info.json" ] || exit 97
    cat "$FIXTURES/$box.info.json"
    ;;
  exec)
    box=${2:-}
    [ "${3:-} ${4:-} ${5:-} ${6:-}" = "--json -- cat /proc/sys/kernel/random/boot_id" ] || exit 97
    [ ! -e "$FIXTURES/$box.exec.fail" ] || exit 1
    n=$(cat "$FIXTURES/exec.count" 2>/dev/null || printf 0); n=$((n + 1))
    printf '%s' "$n" > "$FIXTURES/exec.count"
    id=$(cat "$FIXTURES/$box.boot")
    if [ -e "$FIXTURES/rotate" ] && [ "$n" -ge 2 ]; then id=$(cat "$FIXTURES/$box.boot2"); fi
    jq -n --arg id "$id" '{exitCode:0,stdout:($id+"\n")}'
    ;;
  resume)
    box=${2:-}
    [ "${3:-}" = --environment ] && [ "${4:-}" = fm-code ] || exit 97
    [ "${5:-}" = --ttl ] || exit 97
    case "${6:-}" in ''|*[!0-9]*) exit 97 ;; esac
    [ "${7:-}" = --json ] && [ "$#" -eq 7 ] || exit 97
    [ ! -e "$FIXTURES/resume.fail" ] || exit 1
    printf '{}\n'
    ;;
  stop)
    box=${2:-}; [ "${3:-}" = --json ] || exit 97
    [ ! -e "$FIXTURES/stop.fail" ] || exit 1
    printf '{}\n'
    ;;
  *) exit 97 ;;
esac
FAKE
# The idle probe answers from per-box fixtures, mapping the probed boot id
# back to its box through the boot fixtures, exactly like the real worker's
# instance check. Anything but an exact idle line is a refused probe.
cat > "$BIN/fm-on.sh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'on %s\n' "$*" >> "$FIXTURES/calls"
[ "${1:-}" = boat-eng ] && [ "${2:-}" = fm-boat-worker.sh ] && [ "${3:-}" = idle ] || exit 97
[ ! -e "$FIXTURES/idle.fail" ] || exit 1
found=$(grep -l -F -- "${4:-}" "$FIXTURES/"*.boot 2>/dev/null | head -n 1 || true)
[ -n "$found" ] || exit 1
box=$(basename "$found")
box=${box%.boot}
[ -f "$FIXTURES/idle.$box" ] || exit 1
cat "$FIXTURES/idle.$box"
FAKE
cat > "$BIN/fm-boat-alias-refresh.sh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'alias %s\n' "$*" >> "$FIXTURES/calls"
[ "${1:-}" = --park ] || exit 97
[ ! -e "$FIXTURES/park.fail" ] || exit 1
exit 0
FAKE
chmod +x "$BIN/"*.sh "$FAKEBIN/"*

# new_case <name> [spend-json]: fresh home with one listed box, a stopped
# info fixture, and a boot id. Prints the home path in HOME_DIR.
new_case() {
  local name=$1 cfg=${2-'{}'}
  CASE="$TMP_ROOT/$name"
  FIXTURES="$CASE/fixtures"
  HOME_DIR="$CASE/home"
  mkdir -p "$FIXTURES" "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$cfg" > "$HOME_DIR/config/boat-spend.json"
  printf '%s\n' "$BOX" > "$HOME_DIR/config/boat-box-id"
  printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  printf '%s\n' '11111111-1111-4111-8111-111111111111' > "$FIXTURES/$BOX.boot"
  : > "$FIXTURES/calls"
}

make_info() { # <state> <offset-secs>: running info with a timer, or stopped.
  if [ "$1" = stopped ]; then
    printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  else
    jq -n --argjson end "$((NOW + $2))" \
      '{"sandbox":{id:"'"$BOX"'",type:"default",state:"'"$1"'",environment:"fm-code",archiveAfter:($end|todateiso8601)}}' \
      > "$FIXTURES/$BOX.info.json"
  fi
}

set_idle() { printf '%s\n' "$1" > "$FIXTURES/idle.$BOX"; }
seed_since() { printf '%s %s\n' "$BOX" "$1" > "$HOME_DIR/state/.boat-idle-since"; }
seed_receipt() { printf '%s %s fm-code\n' "$BOX" "$(cat "$FIXTURES/$BOX.boot")" > "$HOME_DIR/state/.boat-environment"; }

# run_at <epoch>: runs the complete executable in the case home at a clock.
run_at() {
  OUT=$(env -u FM_ROOT -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u STATE \
    -u FM_WAKE_QUEUE -u FM_WAKE_QUEUE_LOCK -u TMUX \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_BOAT_BIN="$FAKEBIN/boat" FM_BOAT_IDLE_NOW="$1" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
}

boat_calls() { grep -c '^boat ' "$FIXTURES/calls" | tr -d ' '; }

test_stopped_box_is_silent() {
  new_case stopped
  set_idle 'boat-tasks-remaining: no'
  run_at "$NOW"
  expect_code 0 "$CODE" "stopped check: $OUT"
  [ -z "$OUT" ] || fail "a stopped box should be silent: $OUT"
  assert_equals 1 "$(boat_calls)" 'a stopped box needs only its info read'
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'a stopped box was resumed'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a stopped box was stopped'
  assert_no_grep 'on ' "$FIXTURES/calls" 'a stopped box was probed'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'a stopped box left an idle record'
}

test_busy_box_extends_short_timer() {
  new_case busy
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "busy check: $OUT"
  [ -z "$OUT" ] || fail "a routine extend should be silent: $OUT"
  assert_grep "on boat-eng fm-boat-worker.sh idle 11111111-1111-4111-8111-111111111111" \
    "$FIXTURES/calls" 'liveness was not probed with the current instance'
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'the short timer was not re-armed while workers were live'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a busy box was stopped'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'a busy box kept an idle record'
}

test_busy_box_with_full_timer_is_silent() {
  new_case full
  make_info running 3600
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "full-timer check: $OUT"
  [ -z "$OUT" ] || fail "a full timer should be silent: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'a full timer was re-armed'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a busy box was stopped'
}

test_idle_box_records_first_sight() {
  new_case first-idle
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  run_at "$NOW"
  expect_code 0 "$CODE" "first idle sighting: $OUT"
  [ -z "$OUT" ] || fail "an idle box inside its grace should be silent: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'an idle box was extended'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'an idle box was stopped inside its grace'
  assert_equals "$BOX $NOW" "$(cat "$HOME_DIR/state/.boat-idle-since")" 'first idle sighting was not recorded'
}

test_idle_box_stops_after_grace() {
  new_case grace
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 900))"
  seed_receipt
  run_at "$NOW"
  expect_code 0 "$CODE" "idle stop: $OUT"
  assert_equals "boat-idle: stopped $BOX after 900s with no workers reported" "$OUT" 'stop line'
  assert_grep "boat --no-update stop $BOX --json" "$FIXTURES/calls" 'the idle box was not stopped'
  assert_grep "alias --park $BOX boat-prove" "$FIXTURES/calls" 'the alias was not parked after stop'
  assert_absent "$HOME_DIR/state/.boat-environment" 'the stopped box kept its environment receipt'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'the stopped box kept its idle record'
}

test_live_worker_is_never_stopped() {
  new_case never-stop
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  seed_since "$((NOW - 3600))"
  run_at "$NOW"
  expect_code 0 "$CODE" "past-grace busy check: $OUT"
  [ -z "$OUT" ] || fail "a live worker past the grace should be silent: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a box with a live worker was stopped'
  assert_grep 'boat --no-update resume' "$FIXTURES/calls" 'a live worker lost its extend'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'a busy box kept its stale idle record'
}

test_unreadable_idle_is_busy() {
  new_case blind
  make_info running 600
  : > "$FIXTURES/idle.fail"
  seed_since "$((NOW - 3600))"
  run_at "$NOW"
  expect_code 0 "$CODE" "blind check: $OUT"
  [ -z "$OUT" ] || fail "an unreadable idle report should be silent: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a box with an unreadable idle report was stopped'
  assert_grep 'boat --no-update resume' "$FIXTURES/calls" 'blindness did not keep the box up with an extend'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'an unreadable probe kept a stale idle record'
}

test_unreadable_info_is_silent() {
  new_case no-info
  : > "$FIXTURES/$BOX.info.fail"
  run_at "$NOW"
  expect_code 0 "$CODE" "unreadable info check: $OUT"
  [ -z "$OUT" ] || fail "an unreadable state should be silent: $OUT"
  assert_equals 1 "$(boat_calls)" 'an unreadable state must not lead to more Boat calls'
  assert_no_grep 'on ' "$FIXTURES/calls" 'an unreadable state was probed'
}

test_instance_rotation_skips_stop() {
  new_case rotated
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 900))"
  printf '%s\n' '22222222-2222-4222-8222-222222222222' > "$FIXTURES/$BOX.boot2"
  : > "$FIXTURES/rotate"
  run_at "$NOW"
  expect_code 0 "$CODE" "rotated check: $OUT"
  [ -z "$OUT" ] || fail "a resumed box should be silent: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a freshly resumed box was stopped'
  assert_equals "$BOX $NOW" "$(cat "$HOME_DIR/state/.boat-idle-since")" 'the grace did not restart on rotation'
}

test_configured_resume_timer() {
  new_case short-config '{"resume_ttl_seconds":1800}'
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "configured extend: $OUT"
  [ -z "$OUT" ] || fail "a routine extend should be silent: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 1800 --json" \
    "$FIXTURES/calls" 'the configured timer was not used for the extend'
}

test_configured_grace() {
  new_case quick-grace '{"idle_grace_seconds":60}'
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 60))"
  run_at "$NOW"
  expect_code 0 "$CODE" "configured stop: $OUT"
  assert_equals "boat-idle: stopped $BOX after 60s with no workers reported" "$OUT" 'configured grace stop line'
}

test_extend_failure_is_reported() {
  new_case extend-fail
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/resume.fail"
  run_at "$NOW"
  expect_code 0 "$CODE" "failed extend: $OUT"
  assert_equals "boat-idle: extend $BOX failed with live workers" "$OUT" 'extend failure line'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a failed extend stopped the box'
}

test_stop_failure_is_reported_throttled() {
  new_case stop-fail
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 900))"
  : > "$FIXTURES/stop.fail"
  run_at "$NOW"
  expect_code 0 "$CODE" "failed stop: $OUT"
  assert_equals "boat-idle: stop $BOX failed after 900s with no workers reported" "$OUT" 'stop failure line'
  seed_since "$((NOW - 900))"
  run_at "$NOW"
  expect_code 0 "$CODE" "repeated failed stop: $OUT"
  [ -z "$OUT" ] || fail "a repeated stop failure should stay throttled: $OUT"
  seed_since "$((NOW - 900))"
  run_at "$((NOW + 3600))"
  expect_code 0 "$CODE" "hour-old failed stop: $OUT"
  assert_equals "boat-idle: stop $BOX failed after 4500s with no workers reported" "$OUT" 'hour-old failure is reported again'
}

test_invalid_config_is_reported_once_a_day() {
  new_case bad-config '{"resume_ttl_seconds":"fast"}'
  run_at "$NOW"
  expect_code 0 "$CODE" "invalid config: $OUT"
  assert_contains "$OUT" 'boat-idle: config/boat-spend.json is invalid' 'invalid config line'
  assert_equals 0 "$(boat_calls)" 'an invalid config must not call Boat'
  run_at "$NOW"
  expect_code 0 "$CODE" "repeated invalid config: $OUT"
  [ -z "$OUT" ] || fail "a repeated config problem should stay throttled: $OUT"
}

test_absent_config_is_off() {
  new_case nocfg
  rm "$HOME_DIR/config/boat-spend.json"
  run_at "$NOW"
  expect_code 0 "$CODE" "unconfigured check: $OUT"
  [ -z "$OUT" ] || fail "a home with no config should be silent: $OUT"
  assert_equals 0 "$(boat_calls)" 'an unconfigured home must not call Boat'
  env FM_HOME="$HOME_DIR" "$BIN/fm-boat-idle-check.sh" arm >/dev/null 2>&1 \
    && fail 'arm without a spend config should refuse' || true
}

test_two_boxes_extend_and_stop_on_one_line() {
  local other=bx_cccccccc
  new_case multi '{"expected_running":3}'
  printf '%s\n' "$BOX" "$other" > "$HOME_DIR/config/boat-box-id"
  printf '%s\n' 'bx_zzzzzzzz' > "$HOME_DIR/state/.boat-route-box"
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/resume.fail"
  BOX=$other
  printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$FIXTURES/$BOX.boot"
  make_info running 3600
  set_idle 'boat-tasks-remaining: no'
  printf '%s %s\n' "$BOX" "$((NOW - 900))" > "$HOME_DIR/state/.boat-idle-since"
  BOX=bx_aaaaaaaa
  run_at "$NOW"
  expect_code 0 "$CODE" "two-box check: $OUT"
  assert_equals "boat-idle: extend $BOX failed with live workers; stopped $other after 900s with no workers reported" \
    "$OUT" 'joined line'
  assert_grep "boat --no-update stop $other --json" "$FIXTURES/calls" 'the idle box was not stopped'
  assert_no_grep "boat --no-update stop $BOX " "$FIXTURES/calls" 'the busy box was stopped'
  assert_no_grep 'bx_zzzzzzzz' "$FIXTURES/calls" 'an unlisted box was touched'
  assert_equals "$other" "$(cat "$HOME_DIR/state/.boat-route-box")" 'the route record did not follow the probed box'
}

test_arm_and_disarm() {
  local out home
  new_case arm
  out=$(env FM_HOME="$HOME_DIR" "$BIN/fm-boat-idle-check.sh" arm 2>&1) \
    || fail "arm refused a complete home: $out"
  assert_equals 'armed: state/boat-idle.check.sh' "$out" 'arm line'
  assert_present "$HOME_DIR/state/boat-idle.check.sh" 'arm did not write the shim'
  assert_present "$HOME_DIR/state/boat-idle.check-trust" 'arm did not bind the shim'
  out=$(env -u FM_HOME PATH="$FAKEBIN:$PATH" FIXTURES="$FIXTURES" "$HOME_DIR/state/boat-idle.check.sh" 2>&1) \
    || fail "registered shim failed: $out"
  [ -z "$out" ] || fail "the shim did not run the check in the pinned home: $out"
  printf '%s %s\n' "$BOX" "$NOW" > "$HOME_DIR/state/.boat-idle-since"
  printf '%s %s\n' config "$NOW" > "$HOME_DIR/state/.boat-idle-report"
  env FM_HOME="$HOME_DIR" "$BIN/fm-boat-idle-check.sh" disarm >/dev/null
  assert_absent "$HOME_DIR/state/boat-idle.check.sh" 'disarm left the shim'
  assert_absent "$HOME_DIR/state/boat-idle.check-trust" 'disarm left the trust binding'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'disarm left the idle record'
  assert_absent "$HOME_DIR/state/.boat-idle-report" 'disarm left the report record'
  rm "$HOME_DIR/config/boat-box-id"
  env FM_HOME="$HOME_DIR" "$BIN/fm-boat-idle-check.sh" arm >/dev/null 2>&1 \
    && fail 'arm without a box list should refuse' || true
  home=$HOME_DIR
  printf '%s\n' "$BOX" > "$home/config/boat-box-id"
  printf '%s\n' '{"expected_running":"many"}' > "$home/config/boat-spend.json"
  env FM_HOME="$home" "$BIN/fm-boat-idle-check.sh" arm >/dev/null 2>&1 \
    && fail 'arm with an invalid spend config should refuse' || true
}

test_stopped_box_is_silent
test_busy_box_extends_short_timer
test_busy_box_with_full_timer_is_silent
test_idle_box_records_first_sight
test_idle_box_stops_after_grace
test_live_worker_is_never_stopped
test_unreadable_idle_is_busy
test_unreadable_info_is_silent
test_instance_rotation_skips_stop
test_configured_resume_timer
test_configured_grace
test_extend_failure_is_reported
test_stop_failure_is_reported_throttled
test_invalid_config_is_reported_once_a_day
test_absent_config_is_off
test_two_boxes_extend_and_stop_on_one_line
test_arm_and_disarm
pass "fm-boat-idle-check"

