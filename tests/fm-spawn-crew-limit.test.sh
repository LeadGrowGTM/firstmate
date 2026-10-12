#!/usr/bin/env bash
# Behavior tests for the fixed two-crew admission limit in bin/fm-spawn.sh.
#
# These drive the executable with a fake tmux whose liveness responses exercise
# the existing backend classifier; they do not inspect fm-spawn.sh source text.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-limit)

make_case() {
  local name=$1 dir fb
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/home/projects"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  fm_git_init_commit "$dir/project"
  fm_git_add_origin "$dir/project" "$dir/project.origin.git"
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *list-windows*)
    printf '%s\n' "${FM_FAKE_LIVE_WINDOWS:-}"
    exit 0
    ;;
  *pane_current_command*)
    printf '%s\n' "${FM_FAKE_COMMAND:-codex}"
    exit 0
    ;;
  *pane_tty*)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse gh gh-axi no-mistakes
  printf '%s\n' "$dir"
}

write_live() {
  local home=$1 id=$2 kind=$3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/worktree-$id" \
    "project=$CASE_DIR/project" \
    "harness=codex" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off"
}

run_spawn() {
  local home=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$CASE_DIR/fakebin:$PATH" \
    "$SPAWN" "$id" "$CASE_DIR/project" --mode no-mistakes --yolo off "$@" 2>&1
}

test_third_live_crew_is_refused() {
  local out status=0 home
  CASE_DIR=$(make_case third)
  home="$CASE_DIR/home"
  write_live "$home" live-a ship
  write_live "$home" live-b ship
  out=$(FM_FAKE_LIVE_WINDOWS=$'fm-live-a\nfm-live-b' run_spawn "$home" queued-c) || status=$?
  expect_code 1 "$status" "a third live crew was admitted: $out"
  assert_contains "$out" "at most two crews may run for one lead" \
    "the refusal did not explain the per-lead limit"
  assert_contains "$out" "live-a, live-b" \
    "the refusal did not identify the live crews occupying the limit"
  assert_absent "$home/state/queued-c.meta" "a refused third crew published a task record"
  pass "a third live crew in one Firstmate home is refused before launch"
}

test_scouts_count_and_secondmates_do_not() {
  local out status=0 home
  CASE_DIR=$(make_case kind-boundaries)
  home="$CASE_DIR/home"
  write_live "$home" ship-a ship
  write_live "$home" scout-b scout
  write_live "$home" mate-c secondmate
  out=$(FM_FAKE_LIVE_WINDOWS=$'fm-ship-a\nfm-scout-b\nfm-mate-c' run_spawn "$home" queued-d) || status=$?
  expect_code 1 "$status" "the two ordinary live crews were not enforced: $out"
  assert_contains "$out" "occupied crew slots (scout-b, ship-a)" \
    "the limit did not include a scout or incorrectly included the secondmate"
  pass "scouts count as crews while secondmates remain outside the limit"

  rm -f "$home/state/scout-b.meta"
  status=0
  out=$(FM_FAKE_LIVE_WINDOWS='fm-ship-a' run_spawn "$home" queued-e) || status=$?
  assert_not_contains "$out" "at most two crews may run for one lead" \
    "a secondmate record consumed the remaining ordinary crew slot"
  assert_contains "$out" "has no brief" \
    "the under-limit spawn did not continue through the public brief check"
  pass "a secondmate record does not consume an ordinary crew slot"
}

test_other_home_is_not_counted() {
  local out status=0 home_a home_b
  CASE_DIR=$(make_case owner-isolation)
  home_a="$CASE_DIR/home-a"
  home_b="$CASE_DIR/home-b"
  mkdir -p "$home_a/state" "$home_a/config" "$home_a/data" "$home_a/projects"
  mkdir -p "$home_b/state" "$home_b/config" "$home_b/data" "$home_b/projects"
  printf 'codex\n' > "$home_a/config/crew-harness"
  printf 'codex\n' > "$home_b/config/crew-harness"
  write_live "$home_a" live-a ship
  write_live "$home_a" live-b ship
  out=$(FM_FAKE_LIVE_WINDOWS=$'fm-live-a\nfm-live-b' run_spawn "$home_b" queued-c) || status=$?
  expect_code 1 "$status" "the isolated owner test did not reach the missing-brief check: $out"
  assert_contains "$out" "has no brief" \
    "a different Firstmate home was incorrectly counted against this owner"
  assert_not_contains "$out" "at most two crews may run for one lead" \
    "a different Firstmate home consumed this owner's crew limit"
  pass "live crews in another Firstmate home do not count against this owner"
}

test_uncertain_endpoints_consume_one_slot() {
  local out home backend
  for backend in tmux orca cmux zellij; do
    CASE_DIR=$(make_case "uncertain-$backend")
    home="$CASE_DIR/home"
    write_live "$home" uncertain-a ship
    printf 'backend=%s\n' "$backend" >> "$home/state/uncertain-a.meta"
    out=$(run_spawn "$home" next-b) || true
    assert_contains "$out" "has no brief" "one uncertain $backend record blocked the second slot: $out"
    write_live "$home" uncertain-b scout
    printf 'backend=%s\n' "$backend" >> "$home/state/uncertain-b.meta"
    out=$(run_spawn "$home" next-c) || true
    assert_contains "$out" "at most two crews" "two uncertain $backend records did not fill the limit: $out"
  done
  pass "missing tmux and unverified backend records each consume one slot"
}

test_dead_and_pending_records() {
  local out home
  CASE_DIR=$(make_case dead)
  home="$CASE_DIR/home"
  write_live "$home" dead-a ship
  write_live "$home" dead-b ship
  out=$(FM_FAKE_COMMAND=bash FM_FAKE_LIVE_WINDOWS=$'fm-dead-a\nfm-dead-b' run_spawn "$home" next-c) || true
  assert_contains "$out" "has no brief" "stopped records did not release slots: $out"
  printf 'spawn_gen=pending-a\n' >> "$home/state/dead-a.meta"
  printf 'spawn_gen=pending-b\n' >> "$home/state/dead-b.meta"
  touch "$home/state/dead-a.crew-pending-a" "$home/state/dead-b.crew-pending-b"
  out=$(FM_FAKE_COMMAND=bash FM_FAKE_LIVE_WINDOWS=$'fm-dead-a\nfm-dead-b' run_spawn "$home" next-c) || true
  assert_contains "$out" "at most two crews" "buffered launches were treated as stopped crews: $out"
  pass "pending generations reserve slots even when endpoints still hold shells"
}

test_relaunch_takes_admission_lock() {
  local out home status=0
  CASE_DIR=$(make_case relaunch-lock)
  home="$CASE_DIR/home"
  mkdir "$home/state/.task-set.lock"
  printf '%s\n' "$$" > "$home/state/.task-set.lock/pid"
  out=$(FM_HOME="$home" FM_SPAWN_NO_GUARD=1 PATH="$CASE_DIR/fakebin:$PATH" \
    "$SPAWN" replacement --relaunch 2>&1) || status=$?
  expect_code 1 "$status" "relaunch ignored occupied admission lock: $out"
  assert_contains "$out" "task set is locked" "relaunch bypassed shared admission: $out"
  pass "relaunch and fresh admission share the home lock"
}

test_launch_reservation_lifetime() {
  local home project wt fb id out status=0 launchlog generation reservation pid
  CASE_DIR="$TMP_ROOT/launch"
  home="$CASE_DIR/home"
  project="$CASE_DIR/project"
  wt="$CASE_DIR/wt"
  id="crew-limit-$$"
  fb=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" gh gh-axi no-mistakes)
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$project" "$wt" "crew-limit-test"
  fm_test_spawn_brief "$home" "$id"
  launchlog="$CASE_DIR/launch.log"
  mv "$fb/tmux" "$fb/tmux-delegate"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'export GOTMPDIR='*)
    touch "$FM_CREW_TEST_READY"
    while [ ! -f "$FM_CREW_TEST_RELEASE" ]; do /bin/sleep 0.05; done
    ;;
  *pane_current_command*) printf 'bash\n'; exit 0 ;;
  *pane_tty*) exit 0 ;;
esac
exec "$(dirname "$0")/tmux-delegate" "$@"
SH
  chmod +x "$fb/tmux"
  FM_CREW_TEST_READY="$CASE_DIR/ready" FM_CREW_TEST_RELEASE="$CASE_DIR/release" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$wt" "$fb" "$id" "$project" --mode no-mistakes --yolo off > "$CASE_DIR/spawn.out" &
  pid=$!
  local attempts=0
  while [ ! -e "$CASE_DIR/ready" ] && kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 400 ]; do
    /bin/sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$CASE_DIR/ready" ]; then
    touch "$CASE_DIR/release"
    wait "$pid" || true
    fail "spawn never reached launch delivery: $(cat "$CASE_DIR/spawn.out")"
  fi
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$home" "$wt" "$fb" next-c "$project" --mode no-mistakes --yolo off) || true
  assert_contains "$out" "task set is locked" "fresh admission escaped while launch delivery was paused: $out"
  touch "$CASE_DIR/release"
  wait "$pid" || status=$?
  expect_code 0 "$status" "launch fixture failed: $(cat "$CASE_DIR/spawn.out")"
  generation=$(sed -n 's/^spawn_gen=//p' "$home/state/$id.meta")
  reservation="$home/state/$id.crew-$generation"
  [ -f "$reservation" ] || fail "buffered launch did not retain its reservation"
  write_live "$home" live-a ship
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$wt" "$fb" next-c "$project" --mode no-mistakes --yolo off) || true
  assert_contains "$out" "at most two crews" "buffered shell launch freed its slot: $out"
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$wt" "$fb" "$id" --relaunch) || true
  assert_contains "$out" "still has an admitted launch" "relaunch duplicated a buffered launch: $out"
  cat > "$fb/codex" <<'SH'
#!/bin/sh
exit 7
SH
  chmod +x "$fb/codex"
  status=0
  (cd "$wt" && PATH="$fb:$PATH" bash "$launchlog") > "$CASE_DIR/agent.out" 2>&1 || status=$?
  expect_code 7 "$status" "launch wrapper changed the harness exit status: $(cat "$CASE_DIR/agent.out")"
  assert_absent "$reservation" "finished launch retained its reservation"
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_BACKEND=tmux \
    fm_test_run_spawn "$home" "$wt" "$fb" next-c "$project" --mode no-mistakes --yolo off) || true
  assert_contains "$out" "has no brief" "finished launch did not release capacity: $out"
  pass "launch delivery is serialized and its reservation lasts through buffered startup"
}

test_third_live_crew_is_refused
test_scouts_count_and_secondmates_do_not
test_other_home_is_not_counted
test_uncertain_endpoints_consume_one_slot
test_dead_and_pending_records
test_relaunch_takes_admission_lock
test_launch_reservation_lifetime

echo "# all fm-spawn-crew-limit tests passed"
