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
#      timer (3600 by default), silently, capped at the plan timer.
#   3. An idle box is recorded on first sight and stopped only after the
#      grace (900 by default) with no workers, dropping its receipt line and
#      parking the alias, with one boat-idle: line.
#   4. A box with a live worker is never stopped, even past the grace; the
#      state read, worker probe, extend, and stop all hold the send lock.
#      An unreadable idle report, state, timer, or instance is treated as busy.
#   5. A box not listed in config/boat-box-id is never touched.
#   6. A boot instance the remote probe cannot recognize skips the stop.
#   7. Extend, stop, and refresh failures, and config problems, are reported
#      throttled.
#   8. A home with no spend config is silent and never calls Boat, and arm
#      refuses without a spend config or a readable box list.
#   9. With several boxes, each probe refreshes the shared alias to the
#      probed box (the transport stub refuses a route/alias mismatch, and a
#      slow refresh fails into the extend path within its bound), and sweeps
#      rotate from the durable position.
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
    [ ! -e "$FIXTURES/info.slow" ] || sleep 5
    [ ! -e "$FIXTURES/$box.info.fail" ] || exit 1
    [ -f "$FIXTURES/$box.info.json" ] || exit 97
    if [ -e "$FIXTURES/wake-on-info" ]; then
      : > "$FM_HOME/state/.boat-idle-renew-$box/wake"
      rm "$FIXTURES/wake-on-info"
    fi
    if [ -e "$FIXTURES/info.stops-on-renew" ]; then
      count=$(cat "$FIXTURES/info.count" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$FIXTURES/info.count"
      if [ "$count" -ge 2 ]; then
        printf '{"sandbox":{"id":"%s","type":"default","state":"stopped"}}\n' "$box"
        exit 0
      fi
    fi
    cat "$FIXTURES/$box.info.json"
    ;;
  exec)
    box=${2:-}
    [ "${3:-} ${4:-} ${5:-} ${6:-}" = "--json -- cat /proc/sys/kernel/random/boot_id" ] || exit 97
    [ ! -e "$FIXTURES/exec.slow" ] || sleep 5
    [ ! -e "$FIXTURES/$box.exec.fail" ] || exit 1
    id=$(cat "$FIXTURES/$box.boot")
    if [ -e "$FIXTURES/rotate" ]; then id=$(cat "$FIXTURES/$box.boot2"); fi
    jq -n --arg id "$id" '{exitCode:0,stdout:($id+"\n")}'
    ;;
  limits)
    [ "${2:-}" = --json ] && [ "$#" -eq 2 ] || exit 97
    [ ! -e "$FIXTURES/limits.slow" ] || sleep 25
    [ ! -e "$FIXTURES/limits.near-bound" ] || sleep 5
    [ ! -e "$FIXTURES/limits.fail" ] || exit 1
    cat "$FIXTURES/limits.json"
    ;;
  resume)
    box=${2:-}
    [ ! -e "$FIXTURES/require-lock" ] || [ -e "$FM_HOME/state/.boat-send.lock" ] || exit 98
    [ "${3:-}" = --environment ] && [ "${4:-}" = fm-code ] || exit 97
    [ "${5:-}" = --ttl ] || exit 97
    case "${6:-}" in ''|*[!0-9]*) exit 97 ;; esac
    [ "${7:-}" = --json ] && [ "$#" -eq 7 ] || exit 97
    [ ! -e "$FIXTURES/resume.slow" ] || sleep 11
    [ ! -e "$FIXTURES/resume.long" ] || sleep 51
    [ ! -e "$FIXTURES/resume.fail" ] || exit 1
    printf '{}\n'
    ;;
  stop)
    box=${2:-}; [ "${3:-}" = --json ] || exit 97
    [ ! -e "$FIXTURES/require-lock" ] || [ -e "$FM_HOME/state/.boat-send.lock" ] || exit 98
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
[ ! -f "$FIXTURES/expected-boat-bin" ] || [ "${FM_BOAT_BIN:-}" = "$(cat "$FIXTURES/expected-boat-bin")" ] || exit 97
[ "${1:-}" = boat-eng ] && [ "${2:-}" = fm-boat-worker.sh ] && [ "${3:-}" = idle ] || exit 97
[ ! -e "$FIXTURES/idle.fail" ] || exit 1
# Like the real --verify, the probe reaches only the box the route record and
# the alias agree on; a mismatch, or a missing alias, refuses the probe.
if [ -f "$FM_HOME/state/.boat-route-box" ] && [ ! -L "$FM_HOME/state/.boat-route-box" ]; then
  route=$(cat "$FM_HOME/state/.boat-route-box")
  [ -f "$FIXTURES/alias.box" ] || exit 1
  [ "$(cat "$FIXTURES/alias.box")" = "$route" ] || exit 1
fi
if [ -e "$FIXTURES/retained.meta" ]; then
  printf 'boat-tasks-remaining: yes\n'
  exit 0
fi
if [ -e "$FIXTURES/rotate" ]; then
  found=$(grep -l -F -- "${4:-}" "$FIXTURES/"*.boot2 2>/dev/null | head -n 1 || true)
else
  found=$(grep -l -F -- "${4:-}" "$FIXTURES/"*.boot 2>/dev/null | head -n 1 || true)
fi
[ -n "$found" ] || exit 1
box=$(basename "$found")
box=${box%.boot}
box=${box%.boot2}
[ -f "$FIXTURES/idle.$box" ] || exit 1
if [ -e "$FIXTURES/wake-on-idle" ]; then
  : > "$FM_HOME/state/.boat-idle-renew-$box/wake"
  rm "$FIXTURES/wake-on-idle"
fi
if [ -e "$FIXTURES/idle.clears-on-renew" ]; then
  count=$(cat "$FIXTURES/idle.count" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s\n' "$count" > "$FIXTURES/idle.count"
  if [ "$count" -ge 2 ]; then
    printf 'boat-tasks-remaining: no\n'
    exit 0
  fi
fi
cat "$FIXTURES/idle.$box"
FAKE
cat > "$BIN/fm-boat-alias-refresh.sh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'alias %s\n' "$*" >> "$FIXTURES/calls"
[ ! -f "$FIXTURES/expected-boat-bin" ] || [ "${FM_BOAT_BIN:-}" = "$(cat "$FIXTURES/expected-boat-bin")" ] || exit 97
if [ "${1:-}" = --park ]; then
  [ ! -e "$FIXTURES/park.fail" ] || exit 1
  exit 0
fi
[ "$#" -eq 2 ] && [ "${2:-}" = boat-prove ] || exit 97
case "${1:-}" in bx_*) ;; *) exit 97 ;; esac
[ ! -e "$FIXTURES/refresh.fail" ] || exit 1
[ ! -e "$FIXTURES/refresh.slow" ] || sleep 25
printf '%s\n' "$1" > "$FIXTURES/alias.box"
printf 'sandbox=%s state=running\n' "$1"
FAKE
chmod +x "$BIN/fm-on.sh" "$BIN/fm-boat-alias-refresh.sh" "$FAKEBIN/"*

# new_case <name> [spend-json]: fresh home with one listed box, a stopped
# info fixture, and a boot id. Prints the home path in HOME_DIR.
new_case() {
  local name=$1 cfg=${2-'{}'}
  CASE_INTERVAL=300
  CASE="$TMP_ROOT/$name"
  FIXTURES="$CASE/fixtures"
  HOME_DIR="$CASE/home"
  mkdir -p "$FIXTURES" "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$cfg" > "$HOME_DIR/config/boat-spend.json"
  printf '%s\n' "$BOX" > "$HOME_DIR/config/boat-box-id"
  printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  printf '%s\n' '11111111-1111-4111-8111-111111111111' > "$FIXTURES/$BOX.boot"
  printf '%s\n' '{"billingStatus":"active"}' > "$FIXTURES/limits.json"
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
seed_since() { printf '%s %s:%s\n' "$BOX" "$1" "$(cat "$FIXTURES/$BOX.boot")" > "$HOME_DIR/state/.boat-idle-since"; }
seed_receipt() { printf '%s %s fm-code\n' "$BOX" "$(cat "$FIXTURES/$BOX.boot")" > "$HOME_DIR/state/.boat-environment"; }

# run_at <epoch>: runs the complete executable in the case home at a clock.
run_at() {
  OUT=$(env -u FM_ROOT -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u STATE \
    -u FM_WAKE_QUEUE -u FM_WAKE_QUEUE_LOCK -u TMUX \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_BOAT_BIN="$FAKEBIN/boat" FM_BOAT_IDLE_NOW="$1" FM_CHECK_INTERVAL="$CASE_INTERVAL" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
  wait_renewal
}

wait_renewal() {
  local marker="$HOME_DIR/state/.boat-idle-renew-$BOX" i
  [ -d "$marker" ] || return 0
  for ((i = 0; i < 700; i++)); do
    [ ! -d "$marker" ] || [ -f "$marker/result" ] && return 0
    sleep 0.1
  done
  fail "renewal did not finish for $BOX"
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
  make_info running 3600
  run_at "$((NOW + 300))"
  assert_absent "$HOME_DIR/state/.boat-idle-renew-$BOX" 'successful renewal kept its marker'
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
  assert_equals "$BOX $NOW:$(cat "$FIXTURES/$BOX.boot")" "$(cat "$HOME_DIR/state/.boat-idle-since")" 'first idle sighting was not recorded'
}

test_idle_box_stops_after_grace() {
  new_case grace
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  : > "$FIXTURES/require-lock"
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
  : > "$FIXTURES/require-lock"
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

test_unreadable_instance_renews() {
  new_case unreadable-instance
  make_info running 600
  : > "$FIXTURES/$BOX.exec.fail"
  seed_since "$((NOW - 900))"
  run_at "$NOW"
  expect_code 0 "$CODE" "unreadable instance check: $OUT"
  [ -z "$OUT" ] || fail "an unreadable instance should be silent: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'an unreadable instance skipped renewal'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'an unreadable instance caused stop'
}

test_renewal_rechecks_state_and_liveness() {
  new_case changed-state
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/info.stops-on-renew"
  run_at "$NOW"
  expect_code 0 "$CODE" "changed state check: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'renewal restarted a stopped box'

  new_case changed-liveness
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/idle.clears-on-renew"
  run_at "$NOW"
  expect_code 0 "$CODE" "changed liveness check: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'renewal used stale liveness'
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
  assert_equals "$BOX $NOW:$(cat "$FIXTURES/$BOX.boot2")" "$(cat "$HOME_DIR/state/.boat-idle-since")" 'a new instance inherited the old idle grace'
}

test_resumed_instance_gets_full_grace() {
  new_case resumed-instance
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  run_at "$NOW"
  expect_code 0 "$CODE" "first idle instance: $OUT"
  printf '%s\n' '22222222-2222-4222-8222-222222222222' > "$FIXTURES/$BOX.boot2"
  : > "$FIXTURES/rotate"
  make_info running 4300
  run_at "$((NOW + 900))"
  expect_code 0 "$CODE" "resumed idle instance: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a resumed idle box was stopped before its grace'
  assert_equals "$BOX $((NOW + 900)):$(cat "$FIXTURES/$BOX.boot2")" "$(cat "$HOME_DIR/state/.boat-idle-since")" 'the new instance did not start a fresh grace'
  run_at "$((NOW + 1800))"
  expect_code 0 "$CODE" "new instance after grace: $OUT"
  assert_grep "boat --no-update stop $BOX --json" "$FIXTURES/calls" 'the resumed box stayed up past its own grace'
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

test_revisit_window_renews() {
  new_case revisit-window '{"resume_ttl_seconds":1800}'
  make_info running 781
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "revisit window check: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 1800 --json" \
    "$FIXTURES/calls" 'a timer inside its revisit window was not renewed'
}

test_three_box_renewal_window() {
  local second=bx_cccccccc third=bx_dddddddd
  new_case short-fleet-timer '{"expected_running":3,"resume_ttl_seconds":1800}'
  printf '%s\n' "$BOX" "$second" "$third" > "$HOME_DIR/config/boat-box-id"
  run_at "$NOW"
  expect_code 0 "$CODE" "short three-box timer: $OUT"
  assert_contains "$OUT" 'resume_ttl_seconds 1800 with fallback 3600 gives an effective timer shorter than 3092s required for 3 listed boxes at FM_CHECK_INTERVAL 300' 'unsafe fleet timer was accepted'
  assert_equals 0 "$(boat_calls)" 'unsafe fleet timer contacted Boat'

  new_case default-fleet-timer '{"expected_running":3,"resume_ttl_seconds":3600}'
  printf '%s\n' "$BOX" "$second" "$third" > "$HOME_DIR/config/boat-box-id"
  printf '%s\n' '{"sandbox":{"id":"'"$second"'","type":"default","state":"stopped"}}' > "$FIXTURES/$second.info.json"
  printf '%s\n' '{"sandbox":{"id":"'"$third"'","type":"default","state":"stopped"}}' > "$FIXTURES/$third.info.json"
  make_info running 2000
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "default three-box timer: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'accepted three-box timer was not renewed in time'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'accepted live fleet was stopped'

  new_case slow-fleet-poll '{"expected_running":3,"resume_ttl_seconds":12000}'
  printf '%s\n' "$BOX" "$second" "$third" > "$HOME_DIR/config/boat-box-id"
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_INTERVAL=1200 FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "slow three-box poll: $OUT"
  assert_contains "$OUT" 'resume_ttl_seconds 12000 with fallback 3600 gives an effective timer shorter than 11192s required for 3 listed boxes at FM_CHECK_INTERVAL 1200' 'fallback timer below the fleet cadence was accepted'
  assert_equals 0 "$(boat_calls)" 'unsafe fleet cadence contacted Boat'

  new_case overflowing-fleet-poll '{"expected_running":3,"resume_ttl_seconds":3600}'
  printf '%s\n' "$BOX" "$second" "$third" > "$HOME_DIR/config/boat-box-id"
  CASE_INTERVAL=9223372036854775807
  run_at "$NOW"
  expect_code 0 "$CODE" "overflowing three-box poll: $OUT"
  assert_contains "$OUT" 'FM_CHECK_INTERVAL must be a whole number from 0 to 3600 seconds for 1 to 3 listed boxes' 'overflowing interval was accepted'
  assert_equals 0 "$(boat_calls)" 'overflowing interval contacted Boat'

  new_case safe-fleet-timer '{"expected_running":3,"resume_ttl_seconds":3600}'
  CASE_INTERVAL=240
  printf '%s\n' "$BOX" "$second" "$third" > "$HOME_DIR/config/boat-box-id"
  printf '%s\n' '{"sandbox":{"id":"'"$second"'","type":"default","state":"stopped"}}' > "$FIXTURES/$second.info.json"
  printf '%s\n' '{"sandbox":{"id":"'"$third"'","type":"default","state":"stopped"}}' > "$FIXTURES/$third.info.json"
  make_info running 1741
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/resume.fail"
  run_at "$NOW"
  expect_code 0 "$CODE" "first three-box renewal: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'the three-box timer was not renewed early'
  rm "$FIXTURES/resume.fail"
  : > "$FIXTURES/info.slow"
  : > "$FIXTURES/exec.slow"
  : > "$FIXTURES/limits.near-bound"
  : > "$FIXTURES/resume.long"
  run_at "$((NOW + 810))"
  expect_code 0 "$CODE" "three-box renewal retry: $OUT"
  assert_equals 2 "$(grep -c "boat --no-update resume $BOX " "$FIXTURES/calls")" 'a failed renewal was not retried before expiry'
  assert_equals ok "$(cat "$HOME_DIR/state/.boat-idle-renew-$BOX/result")" 'the renewal retry did not succeed'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'the live box was stopped during renewal'
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
  [ -z "$OUT" ] || fail "the first renewal failure woke early: $OUT"
  run_at "$((NOW + 300))"
  expect_code 0 "$CODE" "second failed extend: $OUT"
  [ -z "$OUT" ] || fail "the second renewal failure woke before a later poll: $OUT"
  run_at "$((NOW + 600))"
  assert_equals "boat-idle: extend $BOX failed twice with live or unreadable workers" "$OUT" 'two-failure wake line'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a failed extend stopped the box'
}

test_renewal_deadline_keeps_full_resume_allowance() {
  new_case renewal-deadline
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  mkdir "$HOME_DIR/state/.boat-idle-renew-$BOX"
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_INTERVAL="$CASE_INTERVAL" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" renew-run "$BOX" "$(($(date +%s) + 20))" 2>&1)
  CODE=$?
  expect_code 1 "$CODE" "renewal with under 60 seconds left: $OUT"
  assert_grep "boat --no-update info $BOX --json" "$FIXTURES/calls" 'the renewal did not reach its timer recheck'
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'renewal started a resume without its full allowance'
}

test_second_renewal_failure_survives_next_attempt() {
  local marker
  new_case renewal-failure-transition
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  marker="$HOME_DIR/state/.boat-idle-renew-$BOX"
  mkdir "$marker"
  printf '2\n' > "$marker/attempts"
  : > "$FIXTURES/resume.fail"
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_INTERVAL="$CASE_INTERVAL" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" renew "$BOX" 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "second failed renewal: $OUT"
  assert_equals fail "$(cat "$marker/result")" 'second failure result'
  [ -f "$marker/wake" ] || fail 'second failure did not preserve its wake'
  printf '3\n' > "$marker/attempts"
  rm "$marker/result" "$FIXTURES/resume.fail"
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_INTERVAL="$CASE_INTERVAL" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" renew "$BOX" 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "third successful renewal: $OUT"
  assert_equals ok "$(cat "$marker/result")" 'third renewal result'
  make_info running 3600
  run_at "$NOW"
  expect_code 0 "$CODE" "reconcile after a third renewal: $OUT"
  assert_equals "boat-idle: extend $BOX failed twice with live or unreadable workers" "$OUT" 'second failure wake was overwritten'
  assert_absent "$marker" 'completed renewal marker was not cleared'
}

test_second_failure_wake_survives_clear_and_output() {
  local marker
  new_case wake-after-reconcile-stopped
  marker="$HOME_DIR/state/.boat-idle-renew-$BOX"
  mkdir "$marker"
  printf '2\n' > "$marker/attempts"
  printf 'fail\n' > "$marker/result"
  : > "$FIXTURES/wake-on-info"
  run_at "$NOW"
  expect_code 0 "$CODE" "stopped box with completed second failure: $OUT"
  assert_equals "boat-idle: extend $BOX failed twice with live or unreadable workers" "$OUT" 'stopped box cleanup lost the failure wake'
  assert_absent "$marker" 'stopped box kept an emitted failure wake'

  new_case wake-after-reconcile-idle
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  marker="$HOME_DIR/state/.boat-idle-renew-$BOX"
  mkdir "$marker"
  printf '2\n' > "$marker/attempts"
  printf 'fail\n' > "$marker/result"
  : > "$FIXTURES/wake-on-idle"
  run_at "$NOW"
  expect_code 0 "$CODE" "idle box with completed second failure: $OUT"
  assert_equals "boat-idle: extend $BOX failed twice with live or unreadable workers" "$OUT" 'idle cleanup lost the failure wake'
  assert_absent "$marker" 'idle box kept an emitted failure wake'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a fresh idle report stopped the box'

  new_case wake-interrupted-output
  marker="$HOME_DIR/state/.boat-idle-renew-$BOX"
  mkdir "$marker"
  printf 'fail\n' > "$marker/result"
  : > "$marker/wake"
  env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_INTERVAL="$CASE_INTERVAL" FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>/dev/null | head -c 0 >/dev/null
  [ -f "$marker/wake" ] || fail 'interrupted output acknowledged a failure wake'
  run_at "$NOW"
  expect_code 0 "$CODE" "retry after interrupted output: $OUT"
  assert_equals "boat-idle: extend $BOX failed twice with live or unreadable workers" "$OUT" 'interrupted output lost the failure wake'
  assert_absent "$marker" 'retry left an emitted failure wake'
  run_at "$NOW"
  [ -z "$OUT" ] || fail "an emitted failure wake repeated: $OUT"
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

test_grace_and_fleet_limits_are_validated() {
  new_case grace-over-timer '{"idle_grace_seconds":7200}'
  run_at "$NOW"
  expect_code 0 "$CODE" "grace over timer: $OUT"
  assert_contains "$OUT" 'idle_grace_seconds 7200 must be shorter than min(resume_ttl_seconds 3600, fallback 3600)' 'default timer was not checked against grace'
  assert_equals 0 "$(boat_calls)" 'invalid grace contacted Boat'

  new_case grace-equals-timer '{"resume_ttl_seconds":1800,"idle_grace_seconds":1800}'
  run_at "$NOW"
  expect_code 0 "$CODE" "grace equals timer: $OUT"
  assert_contains "$OUT" 'idle_grace_seconds 1800 must be shorter than min(resume_ttl_seconds 1800, fallback 3600)' 'equal grace was accepted'
  assert_equals 0 "$(boat_calls)" 'equal grace contacted Boat'

  new_case grace-over-fallback '{"resume_ttl_seconds":14400,"idle_grace_seconds":4000}'
  run_at "$NOW"
  assert_contains "$OUT" 'idle_grace_seconds 4000 must be shorter than min(resume_ttl_seconds 14400, fallback 3600)' 'fallback timer was not checked against grace'
  assert_equals 0 "$(boat_calls)" 'fallback grace contacted Boat'

  new_case unsupported-fleet '{"expected_running":4}'
  run_at "$NOW"
  expect_code 0 "$CODE" "unsupported fleet: $OUT"
  assert_contains "$OUT" 'expected_running must be a whole number, 0 to 3' 'unsupported fleet was accepted'
  assert_equals 0 "$(boat_calls)" 'unsupported fleet contacted Boat'
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
  seed_since "$((NOW - 900))"
  BOX=bx_aaaaaaaa
  run_at "$NOW"
  expect_code 0 "$CODE" "two-box check: $OUT"
  assert_equals "boat-idle: stopped $other after 900s with no workers reported" \
    "$OUT" 'idle stop line'
  assert_grep "boat --no-update stop $other --json" "$FIXTURES/calls" 'the idle box was not stopped'
  assert_no_grep "boat --no-update stop $BOX " "$FIXTURES/calls" 'the busy box was stopped'
  assert_no_grep 'bx_zzzzzzzz' "$FIXTURES/calls" 'an unlisted box was touched'
  assert_equals "$BOX" "$(cat "$HOME_DIR/state/.boat-route-box")" 'the renewal recheck did not route to its box'
  assert_grep "alias $BOX boat-prove" "$FIXTURES/calls" 'the alias was not refreshed to the first probed box'
  assert_grep "alias $other boat-prove" "$FIXTURES/calls" 'the alias was not refreshed to the second probed box'
}

test_retained_record_counts_as_busy() {
  new_case retained-record
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 900))"
  : > "$FIXTURES/retained.meta"
  run_at "$NOW"
  expect_code 0 "$CODE" "retained worker record check: $OUT"
  [ -z "$OUT" ] || fail "a retained record should keep the box up: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a retained record did not prevent stop'
  assert_grep 'boat --no-update resume' "$FIXTURES/calls" 'a retained record did not trigger renewal'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'a retained record kept the idle record'
}

test_extend_caps_at_plan_timer() {
  new_case trial-cap '{"resume_ttl_seconds":14400}'
  printf '%s\n' '{"billingStatus":"trialing"}' > "$FIXTURES/limits.json"
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  run_at "$NOW"
  expect_code 0 "$CODE" "trial extend: $OUT"
  [ -z "$OUT" ] || fail "a capped extend should be silent: $OUT"
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 7200 --json" \
    "$FIXTURES/calls" 'the extend did not cap at the trial plan timer'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a busy box was stopped'
}

test_slow_refresh_still_extends() {
  local other=bx_cccccccc
  new_case slow-refresh '{"expected_running":2}'
  printf '%s\n' "$BOX" "$other" > "$HOME_DIR/config/boat-box-id"
  BOX=$other
  printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  BOX=bx_aaaaaaaa
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/refresh.slow"
  run_at "$NOW"
  expect_code 0 "$CODE" "slow refresh check: $OUT"
  assert_equals "boat-idle: cannot point the worker route at $BOX; keeping it up" "$OUT" 'slow refresh line'
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'a busy box was not extended after its refresh timed out'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'a busy box was stopped'
}

test_configured_cli_reaches_probe_children() {
  local other=bx_cccccccc configured="$FAKEBIN/custom-boat"
  new_case configured-cli '{"boat_bin":"'"$FAKEBIN"'/custom-boat","expected_running":2}'
  cp "$FAKEBIN/boat" "$configured"
  printf '%s\n' "$configured" > "$FIXTURES/expected-boat-bin"
  printf '%s\n' "$BOX" "$other" > "$HOME_DIR/config/boat-box-id"
  make_info running 600
  set_idle 'boat-tasks-remaining: no'
  seed_since "$((NOW - 900))"
  OUT=$(env -u FM_BOAT_BIN FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    FM_BOAT_IDLE_NOW="$NOW" FIXTURES="$FIXTURES" "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "configured CLI check: $OUT"
  assert_equals "boat-idle: stopped $BOX after 900s with no workers reported" "$OUT" 'configured CLI stop line'
  assert_grep 'alias --park' "$FIXTURES/calls" 'configured CLI did not reach alias park'
  assert_grep 'on boat-eng fm-boat-worker.sh idle' "$FIXTURES/calls" 'configured CLI did not reach idle probe'
}

test_slow_poll_extends_within_watcher_budget() {
  local started elapsed second
  new_case slow-poll '{"expected_running":2,"resume_ttl_seconds":14400}'
  printf '%s\n' '{"billingStatus":"trialing"}' > "$FIXTURES/limits.json"
  printf '%s\n' "$BOX" bx_cccccccc > "$HOME_DIR/config/boat-box-id"
  make_info running 600
  set_idle 'boat-tasks-remaining: yes'
  : > "$FIXTURES/refresh.slow"
  : > "$FIXTURES/info.slow"
  : > "$FIXTURES/exec.slow"
  : > "$FIXTURES/limits.slow"
  : > "$FIXTURES/resume.slow"
  started=$(date +%s)
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_TIMEOUT=30 FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
  elapsed=$(($(date +%s) - started))
  expect_code 0 "$CODE" "slow poll check: $OUT"
  [ "$elapsed" -lt 30 ] || fail "slow poll exceeded watcher budget: ${elapsed}s"
  rm -f "$FIXTURES/info.slow" "$FIXTURES/exec.slow" "$FIXTURES/refresh.slow"
  printf 'pos 0\n' > "$HOME_DIR/state/.boat-idle-pos"
  second=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_TIMEOUT=30 FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  [ -z "$second" ] || fail "a pending renewal caused a wake: $second"
  wait_renewal
  assert_grep "boat --no-update resume $BOX --environment fm-code --ttl 3600 --json" \
    "$FIXTURES/calls" 'slow poll did not renew with the safe fallback timer'
  assert_equals 1 "$(grep -c "boat --no-update resume $BOX " "$FIXTURES/calls")" 'a second renewal started while one was in flight'
}

test_short_watcher_budget_is_reported() {
  new_case short-budget
  OUT=$(env FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" FM_BOAT_BIN="$FAKEBIN/boat" \
    FM_BOAT_IDLE_NOW="$NOW" FM_CHECK_TIMEOUT=22 FIXTURES="$FIXTURES" \
    "$BIN/fm-boat-idle-check.sh" check 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "short watcher budget: $OUT"
  assert_contains "$OUT" 'FM_CHECK_TIMEOUT must be at least 30 seconds' 'short watcher budget was silent'
  assert_equals 0 "$(boat_calls)" 'short watcher budget contacted Boat'
}

test_sweep_rotates_across_boxes() {
  local other=bx_cccccccc
  new_case rotate '{"expected_running":2}'
  printf '%s\n' "$BOX" "$other" > "$HOME_DIR/config/boat-box-id"
  BOX=$other
  printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  BOX=bx_aaaaaaaa
  printf '%s\n' 'pos 1' > "$HOME_DIR/state/.boat-idle-pos"
  run_at "$NOW"
  expect_code 0 "$CODE" "rotated sweep: $OUT"
  [ -z "$OUT" ] || fail "stopped boxes should be silent: $OUT"
  assert_equals "boat --no-update info $other --json" "$(head -n 1 "$FIXTURES/calls")" \
    'the sweep did not resume at the recorded position'
  assert_equals 'pos 1' "$(cat "$HOME_DIR/state/.boat-idle-pos")" 'the position did not advance through the full sweep'
  new_case rotate-bad-pos '{"expected_running":2}'
  printf '%s\n' "$BOX" "$other" > "$HOME_DIR/config/boat-box-id"
  BOX=$other
  printf '%s\n' '{"sandbox":{"id":"'"$BOX"'","type":"default","state":"stopped"}}' > "$FIXTURES/$BOX.info.json"
  BOX=bx_aaaaaaaa
  printf '%s\n' 'pos stale' > "$HOME_DIR/state/.boat-idle-pos"
  run_at "$NOW"
  expect_code 0 "$CODE" "bad position sweep: $OUT"
  [ -z "$OUT" ] || fail "stopped boxes should be silent: $OUT"
  assert_equals "boat --no-update info $BOX --json" "$(head -n 1 "$FIXTURES/calls")" \
    'an unreadable position did not restart the sweep at the first box'
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
  printf '%s\n' 'pos 0' > "$HOME_DIR/state/.boat-idle-pos"
  env FM_HOME="$HOME_DIR" "$BIN/fm-boat-idle-check.sh" disarm >/dev/null
  assert_absent "$HOME_DIR/state/boat-idle.check.sh" 'disarm left the shim'
  assert_absent "$HOME_DIR/state/boat-idle.check-trust" 'disarm left the trust binding'
  assert_absent "$HOME_DIR/state/.boat-idle-since" 'disarm left the idle record'
  assert_absent "$HOME_DIR/state/.boat-idle-report" 'disarm left the report record'
  assert_absent "$HOME_DIR/state/.boat-idle-pos" 'disarm left the sweep position'
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
test_unreadable_instance_renews
test_renewal_rechecks_state_and_liveness
test_instance_rotation_skips_stop
test_resumed_instance_gets_full_grace
test_configured_resume_timer
test_revisit_window_renews
test_three_box_renewal_window
test_configured_grace
test_extend_failure_is_reported
test_renewal_deadline_keeps_full_resume_allowance
test_second_renewal_failure_survives_next_attempt
test_second_failure_wake_survives_clear_and_output
test_stop_failure_is_reported_throttled
test_invalid_config_is_reported_once_a_day
test_grace_and_fleet_limits_are_validated
test_absent_config_is_off
test_two_boxes_extend_and_stop_on_one_line
test_retained_record_counts_as_busy
test_extend_caps_at_plan_timer
test_slow_refresh_still_extends
test_configured_cli_reaches_probe_children
test_slow_poll_extends_within_watcher_budget
test_short_watcher_budget_is_reported
test_sweep_rotates_across_boxes
test_arm_and_disarm
pass "fm-boat-idle-check"
