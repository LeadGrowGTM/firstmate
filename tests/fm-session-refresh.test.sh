#!/usr/bin/env bash
# bin/fm-session-refresh.sh: relaunch idle second mates one at a time.
#
# What these pin, through the real control-plane relaunch transaction and the
# real semantic busy-state records, against a lifecycle-modelling tmux stub:
#
#   1. An idle second mate is relaunched on the harness, model, and effort its
#      record names - not the home's secondmate pin - and confirmed idle again.
#   2. Only a positive idle verdict relaunches, read twice across the settle
#      window: busy and unknown (including a Codex mate, which has no verified
#      idle source) wait for the next run, as does a turn that resumes between
#      the two reads.
#   3. Ship and scout tasks, remote second mates, and backends that cannot
#      prove a stop are skipped without being touched.
#   4. The first failure stops the run, whether the relaunch itself fails or the
#      replacement never reads idle, and nothing after it is touched.
#   5. Named task ids narrow the run, and invalid use is refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-session-refresh.sh"
EV="$ROOT/bin/fm-busy-event.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-session-refresh)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT

# The tmux stub: the harness exit command stops the agent on that window, a
# launch brief starts the harness in `becomes`, and - when `idle-on-launch`
# exists - the replacement's real installed Stop hook reports its first turn
# settled.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s %s\n' "$target" "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command.$target" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command.$target"
          if [ -e "$D/idle-on-launch" ]; then
            # The replacement's first turn ends: run the Stop hook the launch
            # itself installed in the mate's home, exactly as Claude would.
            settings="$(cat "$D/cwd.$target")/.claude/settings.local.json"
            sh -c "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" \
              >>"$D/busy-event.log" 2>&1 || true
          fi
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd.$target"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # A wait elapses at once; when `busy-during-wait` names a mate, that mate's
  # turn resumes during the first wait and its tool call records busy.
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
if [ -f "$D/busy-during-wait" ]; then
  id=$(cat "$D/busy-during-wait")
  rm -f "$D/busy-during-wait"
  "$FM_FAKE_BUSY_EVENT" apply "$FM_FAKE_STATE" "$id" busy \
    --gen "$(cat "$FM_FAKE_STATE/$id.busy-gen")" --source claude-hook --event PreToolUse >/dev/null
fi
/bin/sleep 0.01
exit 0
SH
  chmod +x "$fb/sleep"
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  # The home's pin deliberately differs from every recorded profile below, so a
  # relaunch that re-resolved the pin instead of the record would be visible.
  printf 'claude sonnet low\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  : > "$dir/fake/idle-on-launch"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_mate <case-dir> <id> <busy|idle|none> [harness] [model] [effort] [extra-meta-line]
add_mate() {
  local dir=$1 id=$2 busy=$3 harness=${4:-claude} model=${5:-opus} effort=${6:-high} extra=${7:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$smhome" "project=$smhome" \
    "harness=$harness" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "model=$model" "effort=$effort" "home=$smhome"
  [ -z "$extra" ] || printf '%s\n' "$extra" >> "$home/state/$id.meta"
  case "$busy" in
    idle) "$EV" arm "$home/state" "$id" --state idle --source claude-hook --event Stop >/dev/null ;;
    busy) "$EV" arm "$home/state" "$id" --state busy --source claude-hook --event UserPromptSubmit >/dev/null ;;
  esac
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd.fmses:fm-$id"
}

add_ship() {  # <case-dir> <id>
  local dir=$1 id=$2
  local home="$dir/home"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/$id-wt" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  "$EV" arm "$home/state" "$id" --state idle --source claude-hook --event Stop >/dev/null
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
}

run_refresh() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_STATE="$dir/home/state" FM_FAKE_BUSY_EVENT="$EV" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_LAUNCH_WAIT=0.05 FM_SESSION_REFRESH_POLL=0.01 \
    FM_SESSION_REFRESH_IDLE_WAIT="${FM_TEST_IDLE_WAIT:-1}" \
    "$REFRESH" "$@" 2>&1
}

exited() {  # <case-dir> <id>: whether that mate's agent was told to exit
  grep -q "^fmses:fm-$2 /exit$" "$1/fake/literal"
}

# --- T1: idle relaunches on its recorded profile; busy and ships wait ---------
test_idle_mate_relaunches_on_its_recorded_profile() {
  local dir out rc meta
  dir=$(new_case recorded)
  add_mate "$dir" sm1 idle claude opus high
  add_mate "$dir" sm2 busy
  add_ship "$dir" ship1

  out=$(run_refresh "$dir"); rc=$?

  expect_code 0 "$rc" "a clean run must succeed"$'\n'"$out"
  assert_contains "$out" "sm1: relaunched" "the idle mate must be relaunched"
  assert_contains "$out" "sm2: busy, next night" "the busy mate must wait"
  assert_contains "$out" "ship1: skipped (ship task" "a ship must be skipped"
  meta="$dir/home/state/sm1.meta"
  assert_equals "claude" "$(grep '^harness=' "$meta" | cut -d= -f2)" "harness must follow the record"
  assert_equals "opus" "$(grep '^model=' "$meta" | cut -d= -f2)" "model must follow the record, not the pin"
  assert_equals "high" "$(grep '^effort=' "$meta" | cut -d= -f2)" "effort must follow the record, not the pin"
  exited "$dir" sm1 || fail "the idle mate's old agent was never stopped"
  ! exited "$dir" sm2 || fail "the busy mate was stopped"
  ! exited "$dir" ship1 || fail "the ship was stopped"
  assert_not_contains "$(cat "$dir/home/data/sm1/brief.md")" "Progress note" \
    "a second mate's charter must never be rewritten"
  pass "T1 idle relaunches on its recorded profile; busy and ships wait"
}

# --- T2: unknown is never idle, including Codex -------------------------------
test_unknown_is_never_idle() {
  local dir out rc
  dir=$(new_case unknown)
  add_mate "$dir" sm1 none
  add_mate "$dir" sm2 idle codex default default

  out=$(run_refresh "$dir"); rc=$?

  expect_code 0 "$rc" "an unknown verdict is a wait, not a failure"$'\n'"$out"
  assert_contains "$out" "sm1: idle state unknown, next night" "a missing record must not read idle"
  assert_contains "$out" "sm2: idle state unknown, next night" "a Codex mate has no verified idle source"
  ! exited "$dir" sm1 || fail "an unknown mate was stopped"
  ! exited "$dir" sm2 || fail "a Codex mate was stopped"
  pass "T2 unknown, including Codex, is never treated as idle"
}

# --- T2b: idle must hold across the settle window ----------------------------
test_idle_must_hold_across_the_settle_window() {
  local dir out rc
  dir=$(new_case settle)
  add_mate "$dir" sm1 idle
  # The turn continued past its recorded idle and calls a tool meanwhile.
  printf 'sm1' > "$dir/fake/busy-during-wait"

  out=$(run_refresh "$dir"); rc=$?

  expect_code 0 "$rc" "a mate that turned busy is a wait, not a failure"$'\n'"$out"
  assert_contains "$out" "sm1: busy, next night" "the second read must catch the resumed turn"
  ! exited "$dir" sm1 || fail "a mate whose turn resumed was stopped"
  pass "T2b idle must hold across the settle window"
}

# --- T3: remote mates and unprovable backends are skipped ---------------------
test_unrefreshable_mates_are_skipped() {
  local dir out rc
  dir=$(new_case skipped)
  add_mate "$dir" sm1 idle claude opus high "remote_host=boxa"
  add_mate "$dir" sm2 idle claude opus high "backend=zellij"

  out=$(run_refresh "$dir"); rc=$?

  expect_code 0 "$rc" "a skip is not a failure"$'\n'"$out"
  assert_contains "$out" "sm1: skipped (remote second mate" "a remote mate must be skipped"
  assert_contains "$out" "sm2: skipped (zellij backend" "an unprovable backend must be skipped"
  ! exited "$dir" sm1 || fail "a remote mate was touched"
  pass "T3 remote mates and unprovable backends are skipped"
}

# --- T4: a failed relaunch stops the run --------------------------------------
test_failed_relaunch_stops_the_run() {
  local dir out rc
  dir=$(new_case failed)
  add_mate "$dir" sm1 idle
  add_mate "$dir" sm2 idle
  # The replacement never starts: the launch brief leaves a bare shell behind.
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_refresh "$dir"); rc=$?

  expect_code 1 "$rc" "a failed relaunch must fail the run"$'\n'"$out"
  assert_contains "$out" "sm1: FAILED relaunch" "the failure must be named"
  assert_contains "$out" "  error: " "the control plane's own reason must follow the failure"
  assert_contains "$out" "stopped: remaining direct reports left as they are" "the run must stop"
  assert_not_contains "$out" "sm2:" "nothing after the failure may be reported or touched"
  ! exited "$dir" sm2 || fail "a mate after the failure was stopped"
  pass "T4 a failed relaunch stops the run"
}

# --- T5: a replacement that never reads idle stops the run --------------------
test_replacement_must_read_idle_before_the_next() {
  local dir out rc
  dir=$(new_case not-idle)
  add_mate "$dir" sm1 idle
  add_mate "$dir" sm2 idle
  rm -f "$dir/fake/idle-on-launch"

  out=$(FM_TEST_IDLE_WAIT=0 run_refresh "$dir"); rc=$?

  expect_code 1 "$rc" "an unconfirmed replacement must fail the run"$'\n'"$out"
  assert_contains "$out" "sm1: FAILED relaunched but never came back idle" "the unsettled replacement must be named"
  assert_contains "$out" "stopped: remaining direct reports left as they are" "the run must stop"
  ! exited "$dir" sm2 || fail "the next mate was touched before the first read idle"
  pass "T5 each replacement must read idle before the next is touched"
}

# --- T6: named ids narrow the run; invalid use is refused ---------------------
test_named_ids_and_invalid_use() {
  local dir out rc
  dir=$(new_case named)
  add_mate "$dir" sm1 idle
  add_mate "$dir" sm2 idle

  out=$(run_refresh "$dir" sm2); rc=$?
  expect_code 0 "$rc" "a named run must succeed"$'\n'"$out"
  assert_contains "$out" "sm2: relaunched" "the named mate must be relaunched"
  assert_not_contains "$out" "sm1:" "an unnamed mate must be left out"
  ! exited "$dir" sm1 || fail "an unnamed mate was stopped"

  out=$(run_refresh "$dir" ../sm1); rc=$?
  expect_code 2 "$rc" "a path-like id must be refused"$'\n'"$out"
  out=$(run_refresh "$dir" nosuch); rc=$?
  expect_code 1 "$rc" "a named id with no record is a failure"$'\n'"$out"
  assert_contains "$out" "nosuch: FAILED no task record" "the missing record must be named"
  out=$(env -u FM_HOME "$REFRESH" 2>&1); rc=$?
  expect_code 1 "$rc" "a run without an explicit home must be refused"$'\n'"$out"
  pass "T6 named ids narrow the run; invalid use is refused"
}

test_idle_mate_relaunches_on_its_recorded_profile
test_unknown_is_never_idle
test_idle_must_hold_across_the_settle_window
test_unrefreshable_mates_are_skipped
test_failed_relaunch_stops_the_run
test_replacement_must_read_idle_before_the_next
test_named_ids_and_invalid_use

echo "# all fm-session-refresh tests passed"
