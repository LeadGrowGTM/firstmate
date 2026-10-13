#!/usr/bin/env bash
# End-to-end sweep tests use real temporary repositories and the real teardown.
# Fake endpoint and pool commands address only the fixture, never a live fleet.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity sweep-test sweep@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-deadweight-sweep)
SWEEP="$ROOT/bin/fm-deadweight-sweep.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/fakebin"
  git init -q --bare "$home/origin.git"
  git -C "$home/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$home/seed"
  git -C "$home/seed" checkout -qb main
  printf 'baseline\n' > "$home/seed/file"
  git -C "$home/seed" add file
  git -C "$home/seed" commit -qm baseline
  git -C "$home/seed" remote add origin "$home/origin.git"
  git -C "$home/seed" push -q origin main
  git clone -q "$home/origin.git" "$home/projects/project"
  # Missing windows are proven by a successful empty inventory. An error is
  # deliberately non-definitive so it must never license cleanup.
  cat > "$home/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    [ ! -f "$FIXTURE/endpoint-error" ] || { echo 'unreadable inventory' >&2; exit 1; }
    [ ! -f "$FIXTURE/alive" ] || echo fm-task
    ;;
  display-message) echo node ;;
esac
FAKE
  cat > "$home/fakebin/treehouse" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/treehouse-calls"
case "$1" in
  return) git -C "$FIXTURE/projects/project" worktree remove "$3" ;;
  prune)
    [ "$*" = 'prune --yes' ] || exit 1
    [ ! -f "$FIXTURE/prune-fail" ] || { echo 'prune refused' >&2; exit 1; }
    if [ -d "$FIXTURE/pool" ]; then
      git -C "$FIXTURE/projects/project" worktree remove "$FIXTURE/pool"
    fi
    ;;
  *) exit 1 ;;
esac
FAKE
  cat > "$home/fakebin/no-mistakes" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'axi status'*) [ ! -f "$FIXTURE/nm-status" ] || cat "$FIXTURE/nm-status" ;;
esac
exit 0
FAKE
  cat > "$home/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
echo 'count: 0'
FAKE
  cat > "$home/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  cat > "$home/fakebin/lsof" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *' -d cwd '*) exit 0 ;; *) exit 1 ;; esac
FAKE
  chmod +x "$home/fakebin"/*
  printf '%s\n' "$home"
}

add_worker() {
  local home=$1 kind=${2:-ship}
  git -C "$home/projects/project" worktree add -qb fm/task "$home/worker" main
  fm_write_meta "$home/state/task.meta" \
    window=firstmate:fm-task endpoint_task_id=task \
    "worktree=$home/worker" "project=$home/projects/project" \
    "kind=$kind" mode=no-mistakes spawn_gen=sweep-test
  echo 'done: complete' > "$home/state/task.status"
}

sweep() {
  env PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FIXTURE="$1" \
    FM_TEARDOWN_GUARD_DONE="${FM_TEARDOWN_GUARD_DONE:-1}" "$SWEEP" 2>&1
}

test_clean_stopped_and_idempotence() {
  local home out
  home=$(make_home clean); add_worker "$home"
  out=$(sweep "$home")
  assert_equals 'swept: 1 workers, 1 copies, 0 stale registrations' "$out" 'clean worker counts'
  assert_absent "$home/state/task.meta" 'clean worker record removed'
  assert_absent "$home/worker" 'clean worker copy removed'
  out=$(sweep "$home")
  assert_equals '' "$out" 'repeat sweep silent'
  pass 'sweep removes a clean stopped worker and repeats silently'
}

test_changes_kept() {
  local home out
  home=$(make_home dirty); add_worker "$home"
  echo changed >> "$home/worker/file"
  out=$(sweep "$home")
  assert_contains "$out" 'uncommitted changes' 'dirty refusal reported'
  assert_present "$home/state/task.meta" 'dirty record kept'
  assert_grep changed "$home/worker/file" 'dirty content kept'
  out=$(FM_TEARDOWN_GUARD_DONE=0 sweep "$home")
  assert_contains "$out" 'kept task: REFUSED:' 'guard warnings cannot hide the refusal'
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'refusal with guard warnings stays one line'
  home=$(make_home unpushed); add_worker "$home"
  echo unlanded >> "$home/worker/file"
  git -C "$home/worker" add file
  git -C "$home/worker" commit -qm unlanded
  out=$(sweep "$home")
  assert_contains "$out" 'work not on any remote and not landed' 'unpushed refusal reported'
  assert_present "$home/state/task.meta" 'unpushed record kept'
  assert_grep unlanded "$home/worker/file" 'unpushed content kept'
  pass 'sweep keeps dirty and unpushed workers and reports refusals'
}

test_decisions_secondmates_and_unknown_kept() {
  local home out
  home=$(make_home decision); add_worker "$home"
  printf 'needs-decision [key=choice]: waiting\nworking: preparing evidence\n' > "$home/state/task.status"
  out=$(sweep "$home")
  assert_equals '' "$out" 'open decision silent'
  assert_present "$home/state/task.meta" 'parked decision record kept'
  assert_present "$home/worker" 'parked decision copy kept'
  home=$(make_home mate); add_worker "$home" secondmate
  out=$(sweep "$home")
  assert_equals '' "$out" 'secondmate silent'
  assert_present "$home/state/task.meta" 'secondmate record kept'
  home=$(make_home unknown); add_worker "$home"
  touch "$home/endpoint-error"
  out=$(sweep "$home")
  assert_equals '' "$out" 'unknown endpoint silent'
  assert_present "$home/state/task.meta" 'unknown endpoint record kept'
  home=$(make_home alive); add_worker "$home"
  touch "$home/alive"
  out=$(sweep "$home")
  assert_equals '' "$out" 'present endpoint without stopped proof silent'
  assert_present "$home/state/task.meta" 'present endpoint record kept'
  pass 'sweep keeps open decisions, secondmates, and unreadable endpoints'
}

test_scout_gates_and_work_kept() {
  local home out
  home=$(make_home scout-report); add_worker "$home" scout
  out=$(sweep "$home")
  assert_contains "$out" 'has no report' 'scout without report refused'
  assert_present "$home/state/task.meta" 'scout without report kept'
  mkdir -p "$home/data/task"
  echo report > "$home/data/task/report.md"
  out=$(sweep "$home")
  assert_contains "$out" 'no completed captain-call inventory' 'incomplete scout refused'
  assert_present "$home/state/task.meta" 'incomplete scout kept'
  if command -v tasks-axi >/dev/null 2>&1; then
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-captain-hold.sh" complete task --none >/dev/null
    echo changed >> "$home/worker/file"
    out=$(sweep "$home")
    assert_contains "$out" 'uncommitted changes' 'completed scout with edits refused'
    assert_present "$home/state/task.meta" 'completed scout with edits kept'
    assert_grep changed "$home/worker/file" 'scout edits preserved'
  else
    printf 'skip: completed scout edit case requires tasks-axi\n'
  fi
  pass 'sweep leaves incomplete scouts and completed scouts holding changes'
}

test_stale_registration_and_live_copy() {
  local home out inventory
  home=$(make_home registrations)
  git -C "$home/projects/project" worktree add -q --detach "$home/stale" main
  git -C "$home/projects/project" worktree add -q --detach "$home/live" main
  # These are disposable test repositories, not the shared worker pool.
  rm -rf -- "$home/stale"
  out=$(sweep "$home")
  assert_equals 'swept: 0 workers, 0 copies, 1 stale registrations' "$out" 'stale count'
  inventory=$(git -C "$home/projects/project" worktree list --porcelain)
  assert_not_contains "$inventory" "$home/stale" 'stale registration pruned'
  assert_contains "$inventory" "$home/live" 'live registration kept'
  assert_present "$home/live/file" 'live copy kept'
  pass 'sweep prunes proven missing registrations and keeps live registrations'
}

test_pool_prune_count_and_failure() {
  local home out
  home=$(make_home pool)
  git -C "$home/projects/project" worktree add -q --detach "$home/pool" main
  out=$(sweep "$home")
  assert_equals 'swept: 0 workers, 1 copies, 0 stale registrations' "$out" 'safe pool removal count'
  assert_equals 'prune --yes' "$(cat "$home/treehouse-calls")" 'only treehouse safe prune called'
  touch "$home/prune-fail"
  out=$(sweep "$home")
  assert_contains "$out" 'prune refused' 'safe prune refusal reported'
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'one output line'
  pass 'sweep delegates pool removal to safe prune and reports its refusal'
}

test_guard_cannot_force() {
  local home out rc=0
  home=$(make_home force); add_worker "$home"
  out=$(env FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task --only-if-stopped --force 2>&1) || rc=$?
  assert_equals 2 "$rc" 'automatic guard refuses force'
  assert_present "$home/state/task.meta" 'force refusal keeps worker'
  assert_contains "$out" 'cannot discard work' 'force refusal reason'
  pass 'automatic teardown cannot bypass safety with force'
}

test_pipeline_and_captain_hold_kept() {
  local home out state head
  home=$(make_home pipeline); add_worker "$home"
  head=$(git -C "$home/worker" rev-parse HEAD)
  for state in running awaiting_approval; do
    cat > "$home/nm-status" <<EOF
run:
  id: sweep-run
  status: $state
  branch: fm/task
  head: $head
  outcome: ""
  step: review
EOF
    out=$(sweep "$home")
    assert_equals '' "$out" "pipeline $state silent"
    assert_present "$home/state/task.meta" "pipeline $state record kept"
  done
  if command -v tasks-axi >/dev/null 2>&1; then
    home=$(make_home held); add_worker "$home"
    cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
    cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] task - Answer a decision (repo: project) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-10-13T00:00:00Z

## Done
EOF
    out=$(sweep "$home")
    assert_equals '' "$out" 'captain-held backlog item silent'
    assert_present "$home/state/task.meta" 'captain-held record kept'
  else
    printf 'skip: captain backlog hold case requires tasks-axi\n'
  fi
  pass 'sweep preserves stopped workers with active pipelines or captain holds'
}

test_clean_stopped_and_idempotence
test_changes_kept
test_decisions_secondmates_and_unknown_kept
test_scout_gates_and_work_kept
test_stale_registration_and_live_copy
test_pool_prune_count_and_failure
test_guard_cannot_force
test_pipeline_and_captain_hold_kept
