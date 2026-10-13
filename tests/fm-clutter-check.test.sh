#!/usr/bin/env bash
# bin/fm-clutter-check.sh: the daily read-only machine clutter check.
#
# Every case runs the real script inside a temporary home with stand-in ps,
# df, and du first on PATH, each answering from a fixture, so no real process
# table, filesystem, or pipeline copy is read.
#
# What these pin:
#   1. A clean machine is silent, and only orphaned helpers past the age bound
#      are reported; a helper with a live parent or a young one is not.
#   2. The worktree total, an oversized copy, root use, and Windows free space
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
cat > "$FAKE_BIN/ps" <<'FAKE'
#!/usr/bin/env bash
cat "$FIXTURES/ps"
FAKE
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
printf '%s\t%s\n' "$(cat "$FIXTURES/size-$name")" "${*: -1}"
FAKE
chmod +x "$FAKE_BIN"/*

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/fixtures" "$home/worktrees" "$home/mnt-c"
  printf '%s\n' '      1       0  9000 /sbin/init' '    210       1  9000 /usr/lib/systemd/systemd --user' \
    > "$home/fixtures/ps"
  echo 1000 > "$home/fixtures/root-used"
  echo 500 > "$home/fixtures/win-free"
  printf '%s\n' "$home"
}

add_copy() {  # <home> <name> <mb>
  mkdir -p "$1/worktrees/$2"
  echo "$3" > "$1/fixtures/size-$2"
}

run_check() {
  local home=$1
  shift
  env PATH="$FAKE_BIN:$PATH" FM_HOME="$home" FIXTURES="$home/fixtures" FM_CLUTTER_NOW="${CHECK_NOW:-$NOW}" \
    FM_CLUTTER_WORKTREES_ROOT="$home/worktrees" FM_CLUTTER_WINDOWS_MOUNT="$home/mnt-c" \
    "$@" "$CHECK" check 2>&1
}

test_clean_is_silent_and_only_orphans_are_reported() {
  local home out
  home=$(make_home clean)
  add_copy "$home" a1 100
  out=$(run_check "$home") || fail "check exited non-zero: $out"
  [ -z "$out" ] || fail "a clean machine should be silent: $out"
  home=$(make_home orphans)
  printf '%s\n' \
    '    300     210  9000 node /x/bin/gemini -y hello' \
    '    301     210    30 node /x/bin/gemini -y hello' \
    '    302     250  9000 node /x/bin/gemini -y hello' \
    '    303       1  9000 chrome-devtools-mcp' \
    '    304     210  9000 /usr/bin/tmux new-session' \
    >> "$home/fixtures/ps"
  out=$(run_check "$home")
  assert_contains "$out" 'clutter: orphaned processes older than 60m:' "orphan line"
  assert_contains "$out" 'gemini -y hello x1' "only the old orphaned gemini counts"
  assert_contains "$out" 'chrome-devtools-mcp x1' "a PID 1 child counts"
  assert_not_contains "$out" tmux "an unlisted process is never reported"
  pass "fm-clutter-check: a clean machine is silent and only old orphaned helpers are reported"
}

test_space_conditions_join_into_one_line() {
  local home out
  home=$(make_home space)
  add_copy "$home" big 4000
  add_copy "$home" mid 17000
  echo 160000 > "$home/fixtures/root-used"
  echo 50 > "$home/fixtures/win-free"
  out=$(run_check "$home")
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line"
  assert_contains "$out" 'no-mistakes worktrees total 20.5 GB, over 20.0 GB' "total"
  assert_contains "$out" 'no-mistakes copies over 3.0 GB: big 3.9 GB, mid 16.6 GB' "copies"
  assert_contains "$out" 'WSL root has 156.2 GB in use, over 150.0 GB' "root"
  assert_contains "$out" "$home/mnt-c has 5% free, under 10%" "windows"
  pass "fm-clutter-check: space conditions are each reported on one line"
}

test_daily_gate() {
  local home out
  home=$(make_home daily)
  echo 160000 > "$home/fixtures/root-used"
  out=$(run_check "$home")
  assert_contains "$out" 'WSL root has' "first evaluation reports"
  out=$(CHECK_NOW=$((NOW + 3600)) run_check "$home")
  [ -z "$out" ] || fail "a poll inside the day should be silent: $out"
  out=$(CHECK_NOW=$((NOW + 86400)) run_check "$home")
  assert_contains "$out" 'WSL root has' "the next due evaluation reports again"
  pass "fm-clutter-check: one evaluation per day, a persisting condition repeats daily"
}

test_budget_and_unmeasurable_copy() {
  local home out
  home=$(make_home budget)
  add_copy "$home" a1 10
  add_copy "$home" b1 10
  add_copy "$home" c1 10
  touch "$home/fixtures/slow-a1" "$home/fixtures/slow-b1"
  out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  [ -z "$out" ] || fail "a poll that could not size every copy should wait: $out"
  assert_equals a1 "$(cat "$home/fixtures/du.log")" "the budget ran out after the slow copy"
  out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  [ -z "$out" ] || fail "the second poll still has a copy to size: $out"
  out=$(run_check "$home" FM_CLUTTER_MEASURE_BUDGET_SECS=2)
  assert_equals 'clutter: read failed: could not size a1, b1 within 2s' "$out" "unmeasurable copies"
  assert_equals 3 "$(wc -l < "$home/fixtures/du.log" | tr -d ' ')" "each copy is sized once per evaluation"
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
    "$home/state/clutter.check.sh" 2>&1) || fail "registered shim failed: $out"
  assert_contains "$out" 'clutter: WSL root has' "shim did not run the check"
  assert_present "$home/state/.clutter-check/last" "the shim run was not recorded in the pinned home"
  env FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/clutter.check.sh" "disarm left the shim"
  assert_absent "$home/state/clutter.check-trust" "disarm left the trust binding"
  assert_absent "$home/state/.clutter-check" "disarm left the records"
  pass "fm-clutter-check: arm refuses a secondmate home, binds the shim in the root home, and disarm removes it"
}

test_clean_is_silent_and_only_orphans_are_reported
test_space_conditions_join_into_one_line
test_daily_gate
test_budget_and_unmeasurable_copy
test_arm_refuses_secondmate_home_and_runs_the_shim
pass "fm-clutter-check"
