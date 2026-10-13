#!/usr/bin/env bash
# bin/fm-clutter-check.sh: the daily read-only machine clutter check.
#
# Every case runs the real script inside a temporary home with stand-in df and
# du first on PATH, each answering from a fixture.
#
# What these pin:
#   1. A clean machine is silent.
#   2. Worktree pools, copies, archived logs, root use, and Windows free space
#      are each reported, joined into one line.
#   3. Once evaluated, polls inside the day stay silent; the next due
#      evaluation reports a persisting condition again.
#   4. Copies are measured within the budget; a copy that outlasts the whole
#      budget is reported as a read failure rather than blocking every poll.
#   5. Arm refuses in a secondmate home, runs through the registered shim in
#      the root home, and disarm removes it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-clutter-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-clutter-check)
NOW=1791900000

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/df" <<'FAKE'
#!/usr/bin/env bash
echo 'Filesystem 1048576-blocks Used Available Capacity Mounted'
case "${*: -1}" in
  /) printf 'root %s %s 0 0%% /\n' 1000000 "$(cat "$FIXTURES/root-used")" ;;
  *) printf 'c 1000 %s %s 0%% /mnt/c\n' $((1000 - $(cat "$FIXTURES/win-free"))) "$(cat "$FIXTURES/win-free")" ;;
esac
FAKE
cat > "$FAKE_BIN/du" <<'FAKE'
#!/usr/bin/env bash
name=${*: -1}
name=${name##*/}
printf '%s\n' "$name" >> "$FIXTURES/du.log"
[ ! -f "$FIXTURES/slow-$name" ] || sleep 5
[ ! -f "$FIXTURES/fail-$name" ] || exit 1
printf '%s\t%s\n' "$(cat "$FIXTURES/size-$name")" "${*: -1}"
FAKE
chmod +x "$FAKE_BIN"/*

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/fixtures" "$home/worktrees" "$home/mnt-c" "$home/pools" "$home/logs"
  echo 100 > "$home/fixtures/size-pools"
  echo 100 > "$home/fixtures/size-logs"
  echo 1000 > "$home/fixtures/root-used"
  echo 500 > "$home/fixtures/win-free"
  printf '%s\n' "$home"
}

add_copy() {  # <home> <repo> <name> <mb>
  mkdir -p "$1/worktrees/$2/$3"
  echo "$4" > "$1/fixtures/size-$3"
}

run_check() {
  local home=$1
  shift
  env PATH="$FAKE_BIN:$PATH" FM_HOME="$home" FIXTURES="$home/fixtures" FM_CLUTTER_NOW="${CHECK_NOW:-$NOW}" \
    FM_CLUTTER_WORKTREES_ROOT="$home/worktrees" FM_CLUTTER_WINDOWS_MOUNT="$home/mnt-c" \
    FM_CLUTTER_POOLS_ROOT="$home/pools" FM_CLUTTER_LOGS_ROOT="$home/logs" \
    "$@" "$CHECK" check 2>&1
}

test_clean_is_silent() {
  local home out
  home=$(make_home clean)
  add_copy "$home" repo a1 100
  out=$(run_check "$home") || fail "check exited non-zero: $out"
  [ -z "$out" ] || fail "a clean machine should be silent: $out"
  pass "fm-clutter-check: a clean machine is silent"
}

test_space_conditions_join_into_one_line() {
  local home out
  home=$(make_home space)
  add_copy "$home" repo big 4000
  add_copy "$home" repo mid 17000
  echo 6000 > "$home/fixtures/size-pools"
  echo 6000 > "$home/fixtures/size-logs"
  echo 160000 > "$home/fixtures/root-used"
  echo 50 > "$home/fixtures/win-free"
  out=$(run_check "$home")
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line"
  assert_contains "$out" 'treehouse worktree pools use 5.9 GB, over 5.0 GB' "pools"
  assert_contains "$out" 'no-mistakes worktrees total 20.5 GB, over 20.0 GB' "total"
  assert_contains "$out" 'no-mistakes copies over 3.0 GB: repo/big 3.9 GB, repo/mid 16.6 GB' "copies"
  [ "$(awk -F '\t' '$1 == "repo/big" { print $2 }' "$home/state/.clutter-check/sizes")" = 4000 ] \
    || fail "copy-size cache did not persist tab-separated fields"
  assert_contains "$out" 'archived no-mistakes logs use 5.9 GB, over 5.0 GB' "logs"
  assert_contains "$out" 'WSL root has 156.2 GB in use, over 150.0 GB' "root"
  assert_contains "$out" "$home/mnt-c has 5% free, under 10%" "windows"
  pass "fm-clutter-check: space conditions are each reported on one line"
}

test_copy_depth_and_read_failures() {
  local home out
  home=$(make_home depth)
  add_copy "$home" repo run1 2500
  add_copy "$home" repo run2 2500
  out=$(run_check "$home")
  [ -z "$out" ] || fail "two smaller runs must not become one oversized copy: $out"
  home=$(make_home unreadable)
  rmdir "$home/worktrees"
  : > "$home/worktrees"
  out=$(run_check "$home")
  assert_contains "$out" 'read failed: could not traverse' "an existing untraversable root must be reported"
  home=$(make_home cache-write)
  add_copy "$home" repo run1 4000
  mkdir -p "$home/state/.clutter-check/sizes"
  out=$(run_check "$home")
  assert_contains "$out" 'read failed: could not write copy sizes' "a failed cache write must be reported"
  home=$(make_home daily-write)
  mkdir -p "$home/state/.clutter-check/last"
  out=$(run_check "$home")
  assert_contains "$out" 'read failed: could not write daily record' "a failed daily record write must be reported"
  pass "fm-clutter-check: each run is sized and measurement failures are visible"
}

test_du_error_is_not_reported_as_timeout() {
  local home out
  home=$(make_home du-error)
  add_copy "$home" repo broken 4000
  : > "$home/fixtures/fail-broken"
  out=$(run_check "$home")
  assert_contains "$out" 'read failed: could not size repo/broken' "du error must be reported"
  assert_not_contains "$out" 'within 14s' "an immediate du error is not a timeout"
  rm -f "$home/fixtures/fail-broken"
  out=$(CHECK_NOW=$((NOW + 86400)) run_check "$home")
  assert_contains "$out" 'no-mistakes copies over 3.0 GB: repo/broken 3.9 GB' "the next daily check measures the copy again"
  pass "fm-clutter-check: du errors are distinguished from timeouts"
}

test_many_cached_copies_preserve_every_category() {
  local home out i run size
  home=$(make_home many-copies)
  mkdir -p "$home/state/.clutter-check"
  : > "$home/state/.clutter-check/sizes"
  for i in {1..40}; do
    printf -v run 'run-%072d' "$i"
    mkdir -p "$home/worktrees/repo/$run"
    size=4000
    case "$i" in
      1|2|3) size=timeout ;;
      4|5|6) size=error ;;
    esac
    printf 'repo/%s\t%s\t%s\n' "$run" "$size" "$NOW" >> "$home/state/.clutter-check/sizes"
  done
  echo 6000 > "$home/fixtures/size-pools"
  echo 6000 > "$home/fixtures/size-logs"
  echo 160000 > "$home/fixtures/root-used"
  echo 50 > "$home/fixtures/win-free"
  out=$(run_check "$home") || fail "cached-copy check failed: $out"
  assert_contains "$out" 'treehouse worktree pools use' "pool finding"
  assert_contains "$out" 'archived no-mistakes logs use' "log finding"
  assert_contains "$out" 'WSL root has' "root disk finding"
  assert_contains "$out" 'has 5% free' "Windows disk finding"
  assert_contains "$out" 'no-mistakes worktrees total' "copy total finding"
  assert_contains "$out" 'no-mistakes copies over' "oversized copy finding"
  assert_contains "$out" 'within 14s' "timeout copy finding"
  assert_contains "$out" '(+32 more)' "oversized copy count"
  assert_not_contains "$out" '[truncated]' "copy list must not truncate other categories"
  [ "${#out}" -le 1000 ] || fail "the clutter line exceeded its 1000-character cap"
  assert_equals 2 "$(wc -l < "$home/fixtures/du.log" | tr -d ' ')" "cached copies should not be remeasured"
  pass "fm-clutter-check: cached copy summaries preserve every threshold category"
}

test_daily_gate() {
  local home out
  home=$(make_home daily)
  echo 160000 > "$home/fixtures/root-used"
  out=$(run_check "$home")
  assert_contains "$out" 'WSL root has' "first evaluation reports"
  [ "$(awk -F '\t' '$1 == "last_eval" { print $2 }' "$home/state/.clutter-check/last")" = "$NOW" ] \
    || fail "daily record did not persist tab-separated fields"
  out=$(CHECK_NOW=$((NOW + 3600)) run_check "$home")
  [ -z "$out" ] || fail "a poll inside the day should be silent: $out"
  out=$(CHECK_NOW=$((NOW + 86400)) run_check "$home")
  assert_contains "$out" 'WSL root has' "the next due evaluation reports again"
  pass "fm-clutter-check: one evaluation per day, a persisting condition repeats daily"
}

test_budget_and_unmeasurable_copy() {
  local home out
  home=$(make_home budget)
  add_copy "$home" repo a1 10
  add_copy "$home" repo b1 10
  add_copy "$home" repo c1 10
  touch "$home/fixtures/slow-a1" "$home/fixtures/slow-b1"
  out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  [ -z "$out" ] || fail "a poll that could not size every copy should wait: $out"
  assert_contains "$(cat "$home/fixtures/du.log")" a1 "the budget ran out after the slow copy"
  out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  [ -n "$out" ] || out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  assert_contains "$out" 'read failed: could not size repo/a1, repo/b1 within 2s' "unmeasurable copies"
  assert_equals 5 "$(wc -l < "$home/fixtures/du.log" | tr -d ' ')" "each copy and both roots are sized once per evaluation"
  pass "fm-clutter-check: copies are sized within the budget and an unmeasurable copy is a read failure"
}

test_arm_refuses_secondmate_home_and_runs_the_shim() {
  local home out
  home=$(make_home mate)
  : > "$home/.fm-secondmate-parent"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) && fail "arm in a secondmate home should fail: $out"
  assert_contains "$out" 'arm it in the root home' "refusal names the root home"
  assert_absent "$home/state/clutter.check.sh" "a refused arm writes no shim"
  home=$(make_home arm)
  echo 160000 > "$home/fixtures/root-used"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/clutter.check.sh' "arm output"
  assert_present "$home/state/clutter.check-trust" "arm did not bind the shim"
  out=$(env -u FM_HOME PATH="$FAKE_BIN:$PATH" FIXTURES="$home/fixtures" FM_CLUTTER_NOW="$NOW" \
    FM_CLUTTER_WORKTREES_ROOT="$home/worktrees" FM_CLUTTER_WINDOWS_MOUNT="$home/mnt-c" \
    FM_CLUTTER_POOLS_ROOT="$home/pools" FM_CLUTTER_LOGS_ROOT="$home/logs" \
    "$home/state/clutter.check.sh" 2>&1) || fail "registered shim failed: $out"
  assert_contains "$out" 'clutter: WSL root has' "shim did not run the check"
  assert_present "$home/state/.clutter-check/last" "the shim run was not recorded in the pinned home"
  env FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/clutter.check.sh" "disarm left the shim"
  assert_absent "$home/state/clutter.check-trust" "disarm left the trust binding"
  assert_absent "$home/state/.clutter-check" "disarm left the records"
  pass "fm-clutter-check: arm refuses a secondmate home, binds the shim in the root home, and disarm removes it"
}

test_clean_is_silent
test_space_conditions_join_into_one_line
test_copy_depth_and_read_failures
test_du_error_is_not_reported_as_timeout
test_many_cached_copies_preserve_every_category
test_daily_gate
test_budget_and_unmeasurable_copy
test_arm_refuses_secondmate_home_and_runs_the_shim
pass "fm-clutter-check"
