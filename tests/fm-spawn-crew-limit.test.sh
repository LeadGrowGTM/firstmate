#!/usr/bin/env bash
# Behavior tests for the fixed two-crew admission limit in bin/fm-spawn.sh.
#
# These drive the executable with a fake tmux whose liveness responses exercise
# the existing backend classifier; they do not inspect fm-spawn.sh source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
    printf 'codex\n'
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
  assert_contains "$out" "live crews (scout-b, ship-a)" \
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

test_third_live_crew_is_refused
test_scouts_count_and_secondmates_do_not
test_other_home_is_not_counted

echo "# all fm-spawn-crew-limit tests passed"
