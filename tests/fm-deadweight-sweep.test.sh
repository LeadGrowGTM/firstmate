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
  display-message)
    if [ -f "$FIXTURE/alive" ]; then echo codex; else echo node; fi
    ;;
esac
FAKE
  cat > "$home/fakebin/treehouse" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/treehouse-calls"
case "$1" in
  return) git -C "$FIXTURE/projects/project" worktree remove "$3" ;;
  prune)
    [ "$*" = 'prune --yes' ] || exit 1
    [ ! -f "$FIXTURE/slow-prune" ] || sleep 6
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
if [ "$1" = pr ] && [ "$2" = view ] && [ -f "$FIXTURE/pr-state" ]; then
  printf 'state: %s\n' "$(cat "$FIXTURE/pr-state")"
  exit 0
fi
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
  home=$(make_home pushed); add_worker "$home"
  echo pushed-unlanded >> "$home/worker/file"
  git -C "$home/worker" add file
  git -C "$home/worker" commit -qm pushed-unlanded
  git -C "$home/worker" push -qu origin fm/task
  out=$(sweep "$home")
  assert_contains "$out" 'commits beyond its base not landed' 'pushed unlanded refusal reported'
  assert_present "$home/state/task.meta" 'pushed unlanded record kept'
  assert_grep pushed-unlanded "$home/worker/file" 'pushed unlanded content kept'
  home=$(make_home claude-work); add_worker "$home"
  mkdir -p "$home/worker/.claude/commands"
  echo valuable > "$home/worker/.claude/commands/custom.md"
  out=$(sweep "$home")
  assert_contains "$out" 'uncommitted changes' 'untracked Claude work refused'
  assert_present "$home/state/task.meta" 'untracked Claude work record kept'
  assert_grep valuable "$home/worker/.claude/commands/custom.md" 'untracked Claude work kept'
  home=$(make_home claude-settings); add_worker "$home"
  mkdir -p "$home/worker/.claude"
  echo '{"operator":true}' > "$home/worker/.claude/settings.local.json"
  out=$(sweep "$home")
  assert_contains "$out" 'uncommitted changes' 'operator Claude settings refused'
  assert_present "$home/state/task.meta" 'operator Claude settings record kept'
  assert_present "$home/worker/.claude/settings.local.json" 'operator Claude settings kept'
  pass 'sweep keeps dirty, unpushed, pushed, and untracked Claude work'
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
  home=$(make_home idle); add_worker "$home"
  touch "$home/alive"
  printf 'harness=grok\n' >> "$home/state/task.meta"
  out=$(sweep "$home")
  assert_contains "$out" 'idle-left task' 'semantically idle worker reported'
  assert_present "$home/state/task.meta" 'idle worker record kept'
  assert_present "$home/worker" 'idle worker copy kept'
  pass 'sweep keeps open decisions, secondmates, and unreadable endpoints'
}

test_recorded_pr_kept_until_merged() {
  local home out
  home=$(make_home open-pr); add_worker "$home"
  printf 'pr=https://github.com/example/repo/pull/7\n' >> "$home/state/task.meta"
  echo OPEN > "$home/pr-state"
  out=$(sweep "$home")
  assert_contains "$out" 'not confirmed merged' 'open PR refusal reported'
  assert_present "$home/state/task.meta" 'open PR record kept'
  assert_present "$home/worker" 'open PR copy kept'
  git -C "$home/projects/project" worktree remove "$home/worker"
  out=$(sweep "$home")
  assert_contains "$out" 'not confirmed merged' 'open PR refused without copy'
  assert_present "$home/state/task.meta" 'open PR record kept without copy'
  echo MERGED > "$home/pr-state"
  out=$(sweep "$home")
  assert_absent "$home/state/task.meta" 'merged PR record removed'
  pass 'sweep preserves recorded open PRs with or without copies'
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
    git -C "$home/worker" add file
    git -C "$home/worker" commit -qm scout-unlanded
    git -C "$home/worker" push -qu origin fm/task
    out=$(sweep "$home")
    assert_contains "$out" 'commits beyond its base not landed' 'pushed scout work refused'
    assert_present "$home/state/task.meta" 'pushed scout record kept'
    assert_grep changed "$home/worker/file" 'pushed scout content kept'
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

check() {
  env PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FIXTURE="$1" \
    FM_TEARDOWN_GUARD_DONE=1 "$SWEEP" check 2>&1
}

wait_result() {
  local i=0
  while [ ! -f "$1/state/.deadweight-sweep-result" ] && [ "$i" -lt 600 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  assert_present "$1/state/.deadweight-sweep-result" 'detached sweep completed'
}

test_default_daily_check_and_watcher() {
  local home out launched rc=0
  home=$(make_home automatic); add_worker "$home"
  out=$(check "$home")
  assert_equals '' "$out" 'starting a daily sweep is silent'
  wait_result "$home"
  assert_absent "$home/state/task.meta" 'default automatic sweep removes stopped worker'
  launched=$(cat "$home/state/.deadweight-sweep-launched")
  mkdir "$home/state/unwritable-queue"
  rc=0
  out=$(FM_WAKE_QUEUE="$home/state/unwritable-queue" check "$home") || rc=$?
  [ "$rc" -ne 0 ] || fail 'failed wake append must fail the check'
  assert_present "$home/state/.deadweight-sweep-result" 'failed wake append keeps the result'
  rmdir "$home/state/unwritable-queue"
  out=$(check "$home")
  assert_equals 'swept: 1 workers, 1 copies, 0 stale registrations' "$out" 'next poll reports result'
  assert_absent "$home/state/.deadweight-sweep-result" 'queued result consumed'
  assert_grep deadweight-sweep "$home/state/.wake-queue" 'result queued before consumption'
  out=$(check "$home")
  assert_equals '' "$out" 'result reported once'
  assert_equals "$launched" "$(cat "$home/state/.deadweight-sweep-launched")" 'same-day poll does not start again'
  add_worker "$home"
  out=$(check "$home")
  assert_present "$home/state/task.meta" 'new deadweight waits for daily gate'
  echo 0 > "$home/state/.deadweight-sweep-launched"
  out=$(check "$home")
  wait_result "$home"
  assert_absent "$home/state/task.meta" 'next daily sweep removes new deadweight'
  home=$(make_home watcher); add_worker "$home"
  check "$home" >/dev/null
  wait_result "$home"
  rc=0
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FIXTURE="$home" \
    FM_TEARDOWN_GUARD_DONE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 > "$home/watcher-out" 2> "$home/watcher-err" || rc=$?
  out=$(cat "$home/watcher-out")
  assert_equals 0 "$rc" 'default watcher returns maintenance wake'
  assert_contains "$out" 'check: deadweight-sweep: swept: 1 workers' 'watcher reports without check shim'
  assert_grep deadweight-sweep "$home/state/.wake-queue" 'maintenance wake queued durably'
  pass 'automatic default-on daily gate runs detached and watcher reports once'
}

test_unsafe_records() {
  local home out rc=0
  home=$(make_home unsafe); add_worker "$home"
  ln -s "$home/untouched" "$home/state/.deadweight-sweep-launched"
  rc=0; out=$(check "$home") || rc=$?
  assert_equals 1 "$rc" 'unsafe schedule destination refused'
  assert_absent "$home/untouched" 'schedule symlink target untouched'
  assert_present "$home/state/task.meta" 'unsafe schedule keeps worker'
  pass 'automatic cleanup refuses unsafe schedule records'
}

test_detached_sweep_survives_watcher_timeout() {
  local home rc=0
  home=$(make_home timeout)
  touch "$home/slow-prune"
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FIXTURE="$home" \
    FM_TEARDOWN_GUARD_DONE=1 FM_POLL=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=1 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$home/checkpoint-out" 2>&1 || rc=$?
  assert_equals 124 "$rc" 'quiet watcher checkpoint times out'
  assert_absent "$home/state/.watch.lock/pid" 'timed-out watcher releases its lock'
  wait_result "$home"
  assert_equals 1 "$(wc -l < "$home/treehouse-calls" | tr -d ' ')" 'detached safe prune completes once'
  assert_equals '' "$(check "$home")" 'empty maintenance result stays silent'
  pass 'detached sweep survives watcher timeout and leaves watcher lock clean'
}

test_clean_stopped_and_idempotence
test_changes_kept
test_decisions_secondmates_and_unknown_kept
test_recorded_pr_kept_until_merged
test_scout_gates_and_work_kept
test_stale_registration_and_live_copy
test_pool_prune_count_and_failure
test_guard_cannot_force
test_pipeline_and_captain_hold_kept

test_default_daily_check_and_watcher
test_unsafe_records
test_detached_sweep_survives_watcher_timeout
