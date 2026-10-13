#!/usr/bin/env bash
# End-to-end sweep tests use real temporary repositories and the real teardown.
# Fake endpoint and pool commands address only the fixture, never a live fleet.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
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
  return) git -C "$FIXTURE/projects/project" worktree remove --force "$3" ;;
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
    "kind=$kind" branch=fm/task mode=no-mistakes spawn_gen=sweep-test
  echo 'done: complete' > "$home/state/task.status"
}

sweep() {
  env PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FIXTURE="$1" \
    FM_SWEEP_REAL_GIT="${FM_SWEEP_REAL_GIT:-}" FM_SWEEP_REAL_RM="${FM_SWEEP_REAL_RM:-}" \
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

test_tracked_wiring_kept() {
  local home out path name
  for path in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
    .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
    name=${path##*/}
    home=$(make_home "tracked-$name")
    mkdir -p "$home/seed/$(dirname "$path")"
    printf 'operator file\n' > "$home/seed/$path"
    git -C "$home/seed" add -f "$path"
    git -C "$home/seed" commit -qm operator-wiring
    git -C "$home/seed" push -q origin main
    git -C "$home/projects/project" pull -q
    add_worker "$home"
    out=$(sweep "$home")
    assert_contains "$out" 'tracked wiring' "$path refusal reported"
    assert_present "$home/state/task.meta" "$path record kept"
    assert_present "$home/worker/$path" "$path file kept"
    assert_equals 'operator file' "$(cat "$home/worker/$path")" "$path contents kept"
    assert_present "$home/worker" "$path copy kept"
  done
  pass 'sweep preserves tracked operator wiring at every removal path'
}

test_symlinked_wiring_directory_kept() {
  local home out component target name
  for component in .claude .opencode .opencode/plugins; do
    name=${component//\//-}
    home=$(make_home "symlinked-$name")
    case "$component" in
      .claude) target=settings.local.json ;;
      .opencode) target=plugins/fm-busy-state.js ;;
      .opencode/plugins) target=fm-busy-state.js ;;
    esac
    mkdir -p "$home/shared/$(dirname "$target")" "$home/seed/$(dirname "$component")"
    printf 'original\n' > "$home/shared/$target"
    ln -s "$home/shared" "$home/seed/$component"
    git -C "$home/seed" add -f "$component"
    git -C "$home/seed" commit -qm operator-symlink
    git -C "$home/seed" push -q origin main
    git -C "$home/projects/project" pull -q
    add_worker "$home"
    printf 'operator edit\n' > "$home/shared/$target"
    assert_equals '' "$(git -C "$home/worker" status --porcelain --untracked-files=all --ignored)" "$component edit hidden from Git status"
    out=$(sweep "$home")
    assert_contains "$out" 'symlinked wiring directory' "$component refusal reported"
    assert_present "$home/state/task.meta" "$component record kept"
    assert_present "$home/worker" "$component copy kept"
    assert_present "$home/shared/$target" "$component operator file kept"
    assert_equals 'operator edit' "$(cat "$home/shared/$target")" "$component operator edit kept"
  done
  pass 'sweep preserves operator files behind symlinked wiring directories'
}

test_ignored_work_kept() {
  local home out
  home=$(make_home ignored); add_worker "$home"
  printf '.env\n.claude/\n' >> "$home/projects/project/.git/info/exclude"
  printf 'operator secret\n' > "$home/worker/.env"
  mkdir -p "$home/worker/.claude/commands"
  printf 'operator command\n' > "$home/worker/.claude/commands/custom.md"
  out=$(sweep "$home")
  assert_contains "$out" 'uncommitted changes' 'ignored paths refuse automatic teardown'
  assert_present "$home/state/task.meta" 'ignored work record kept'
  assert_grep 'operator secret' "$home/worker/.env" 'ignored env kept'
  assert_grep 'operator command' "$home/worker/.claude/commands/custom.md" 'ignored command kept'
  home=$(make_home edited-settings); add_worker "$home"
  mkdir -p "$home/worker/.claude"
  printf '{"hook":"fm-busy-event.sh","operator":true}\n' > "$home/worker/.claude/settings.local.json"
  out=$(sweep "$home")
  assert_contains "$out" 'uncommitted changes' 'edited generated settings refuse teardown'
  assert_present "$home/state/task.meta" 'edited settings record kept'
  assert_present "$home/worker/.claude/settings.local.json" 'edited settings file kept'
  pass 'sweep preserves ignored operator files'
}

test_flagged_guard_under_pipefail() {
  local home i out
  home=$(make_home flag-pipefail)
  # Enough tracked paths after the flagged one to overflow a pipe buffer.
  mkdir "$home/seed/many"
  for i in $(seq 1 20000); do : > "$home/seed/many/f$i"; done
  printf 'early\n' > "$home/seed/a-flagged"
  git -C "$home/seed" add -A
  git -C "$home/seed" commit -qm many
  git -C "$home/seed" push -q origin main
  git -C "$home/projects/project" pull -q
  add_worker "$home"
  [ "$(git -C "$home/worker" ls-files | wc -l | tr -d ' ')" -gt 20000 ] || fail 'large index fixture'
  echo hidden-edit >> "$home/worker/a-flagged"
  git -C "$home/worker" update-index --assume-unchanged a-flagged
  out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FIXTURE="$home" \
    FM_TEARDOWN_GUARD_DONE=1 bash -o pipefail "$ROOT/bin/fm-teardown.sh" task --only-if-stopped 2>&1) || true
  assert_contains "$out" 'flagged assume-unchanged or skip-worktree' 'flag guard refuses under pipefail'
  assert_present "$home/state/task.meta" 'pipefail flag record kept'
  assert_grep hidden-edit "$home/worker/a-flagged" 'pipefail flag edit kept'
  pass 'flag guard refuses under pipefail with a large index'
}

test_flagged_tracked_edits_kept() {
  local home out flag
  for flag in assume-unchanged skip-worktree; do
    home=$(make_home "flag-$flag"); add_worker "$home"
    echo hidden-edit >> "$home/worker/file"
    git -C "$home/worker" update-index "--$flag" file
    assert_equals '' "$(git -C "$home/worker" status --porcelain --untracked-files=all --ignored)" "$flag hides the edit from status"
    out=$(sweep "$home")
    assert_contains "$out" 'flagged assume-unchanged or skip-worktree' "$flag refusal reported"
    assert_present "$home/state/task.meta" "$flag record kept"
    assert_grep hidden-edit "$home/worker/file" "$flag edit kept"
  done
  pass 'sweep refuses copies with assume-unchanged or skip-worktree paths'
}

test_initialized_submodule_kept() {
  local home out kind child role
  for kind in clean-ship clean-scout tracked untracked moved uninitialized empty absent; do
    if [ "$kind" = clean-scout ] && ! command -v tasks-axi >/dev/null 2>&1; then
      continue
    fi
    home=$(make_home "submodule-$kind")
    git init -q "$home/submodule-source"
    printf 'baseline\n' > "$home/submodule-source/file"
    git -C "$home/submodule-source" add file
    git -C "$home/submodule-source" commit -qm baseline
    git -C "$home/projects/project" -c protocol.file.allow=always submodule add -q "$home/submodule-source" child
    git -C "$home/projects/project" commit -qam submodule
    git -C "$home/projects/project" push -q origin main
    role=ship
    if [ "$kind" = clean-scout ]; then role=scout; fi
    add_worker "$home" "$role"
    if [ "$role" = scout ]; then
      mkdir -p "$home/data/task"
      printf 'report\n' > "$home/data/task/report.md"
      env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        "$ROOT/bin/fm-captain-hold.sh" complete task --none >/dev/null
    fi
    case "$kind" in
      uninitialized) mkdir -p "$home/worker/child"; printf 'operator file\n' > "$home/worker/child/file" ;;
      empty) mkdir -p "$home/worker/child" ;;
      absent) rmdir "$home/worker/child" 2>/dev/null || true ;;
      *) git -C "$home/worker" -c protocol.file.allow=always submodule update --init -q ;;
    esac
    git -C "$home/projects/project" config submodule.child.ignore all
    child="$home/worker/child"
    case "$kind" in
      clean-*) ;;
      tracked) printf 'operator edit\n' >> "$child/file" ;;
      untracked) printf 'operator file\n' > "$child/new-file" ;;
      moved)
        printf 'operator commit\n' >> "$child/file"
        git -C "$child" add file
        git -C "$child" commit -qm operator-commit
        ;;
    esac
    out=$(sweep "$home")
    if [ "$kind" = empty ] || [ "$kind" = absent ]; then
      assert_contains "$out" 'swept: 1 workers, 1 copies' "$kind gitlink path swept"
      assert_absent "$home/state/task.meta" "$kind gitlink record removed"
      continue
    fi
    assert_contains "$out" 'occupied submodule path; needs a human look' "$kind submodule refused"
    assert_present "$home/state/task.meta" "$kind submodule record kept"
    assert_present "$child/file" "$kind submodule copy kept"
  done
  pass 'sweep keeps occupied submodule paths for ships and scouts'
}

# Spawn writes Claude wiring with or without its statusLine fallback.
render_claude_wiring() {  # <claude|claude-statusline> <state-real> <statusline-cmd>
  if [ "$1" = claude-statusline ]; then
    fm_control_render_claude_settings "$ROOT" "$2" task sweep-generation 1 "$3"
  else
    fm_control_render_claude_settings "$ROOT" "$2" task sweep-generation 1
  fi
}

test_ignored_wiring_directories() {
  local harness case_name home out path operator state_real
  for harness in claude opencode; do
    for case_name in exact operator; do
      home=$(make_home "ignored-directory-$harness-$case_name"); add_worker "$home"
      printf 'busy_gen=sweep-generation\n' >> "$home/state/task.meta"
      state_real=$(cd "$home/state" && pwd -P)
      if [ "$harness" = claude ]; then
        path=.claude/settings.local.json
        operator=.claude/operator.txt
        mkdir -p "$home/worker/.claude"
        render_claude_wiring claude "$state_real" '' > "$home/worker/$path"
        printf '.claude/\n' >> "$home/projects/project/.git/info/exclude"
      else
        path=.opencode/plugins/fm-busy-state.js
        operator=.opencode/plugins/operator.js
        mkdir -p "$home/worker/.opencode/plugins"
        fm_control_render_opencode_plugin "$ROOT" "$state_real" task sweep-generation true > "$home/worker/$path"
        printf '.opencode/\n' >> "$home/projects/project/.git/info/exclude"
      fi
      if [ "$case_name" = operator ]; then
        printf 'operator file\n' > "$home/worker/$operator"
      fi
      out=$(sweep "$home")
      if [ "$case_name" = exact ]; then
        assert_contains "$out" 'swept: 1 workers, 1 copies' "$harness ignored generated wiring swept"
        assert_absent "$home/state/task.meta" "$harness exact record removed"
        assert_absent "$home/worker" "$harness exact copy removed"
      else
        assert_contains "$out" 'uncommitted changes' "$harness ignored operator file refused"
        assert_present "$home/state/task.meta" "$harness operator record kept"
        assert_present "$home/worker/$path" "$harness generated wiring kept with operator file"
        assert_present "$home/worker/$operator" "$harness operator file kept"
      fi
    done
  done
  pass 'sweep accepts exact wiring inside ignored directories and keeps operator files'
}

test_generated_wiring_exact_and_edited() {
  local harness home out path state_real statusline settings
  statusline="'$ROOT/bin/fm-statusbar.sh' claude-line --task 'task'"
  settings=$(render_claude_wiring claude-statusline /state "$statusline")
  assert_equals command "$(printf '%s\n' "$settings" | jq -r '.statusLine.type')" 'statusLine type'
  assert_equals "$statusline" "$(printf '%s\n' "$settings" | jq -r '.statusLine.command')" 'statusLine command'
  for harness in claude claude-statusline opencode; do
    home=$(make_home "$harness-exact"); add_worker "$home"
    printf 'busy_gen=sweep-generation\n' >> "$home/state/task.meta"
    state_real=$(cd "$home/state" && pwd -P)
    if [ "$harness" != opencode ]; then
      path=.claude/settings.local.json
      mkdir -p "$home/worker/.claude"
      render_claude_wiring "$harness" "$state_real" "$statusline" > "$home/worker/$path"
    else
      path=.opencode/plugins/fm-busy-state.js
      mkdir -p "$home/worker/.opencode/plugins"
      fm_control_render_opencode_plugin "$ROOT" "$state_real" task sweep-generation true > "$home/worker/$path"
    fi
    printf '%s\n' "$path" >> "$home/projects/project/.git/info/exclude"
    out=$(sweep "$home")
    assert_contains "$out" 'swept: 1 workers, 1 copies' "$harness exact wiring swept"
    assert_absent "$home/state/task.meta" "$harness exact wiring record removed"
    assert_absent "$home/worker" "$harness exact wiring copy removed"

    home=$(make_home "$harness-edited"); add_worker "$home"
    printf 'busy_gen=sweep-generation\n' >> "$home/state/task.meta"
    state_real=$(cd "$home/state" && pwd -P)
    if [ "$harness" != opencode ]; then
      mkdir -p "$home/worker/.claude"
      render_claude_wiring "$harness" "$state_real" "$statusline" > "$home/worker/$path"
    else
      mkdir -p "$home/worker/.opencode/plugins"
      fm_control_render_opencode_plugin "$ROOT" "$state_real" task sweep-generation true > "$home/worker/$path"
    fi
    printf 'operator edit\n' >> "$home/worker/$path"
    printf '%s\n' "$path" >> "$home/projects/project/.git/info/exclude"
    out=$(sweep "$home")
    assert_contains "$out" 'uncommitted changes' "$harness edited wiring refused"
    assert_present "$home/state/task.meta" "$harness edited wiring record kept"
    assert_grep 'operator edit' "$home/worker/$path" "$harness edited wiring kept"
  done
  pass 'sweep removes exact Claude (with or without statusLine) and OpenCode wiring and keeps edits'
}

test_late_work_kept() {
  local home out kind stage state_real
  for kind in ship scout; do
    if [ "$kind" = scout ] && ! command -v tasks-axi >/dev/null 2>&1; then
      continue
    fi
    for stage in wiring return; do
      home=$(make_home "late-$kind-$stage"); add_worker "$home" "$kind"
      if [ "$kind" = scout ]; then
        mkdir -p "$home/data/task"
        printf 'report\n' > "$home/data/task/report.md"
        env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
          "$ROOT/bin/fm-captain-hold.sh" complete task --none >/dev/null
      fi
      printf 'busy_gen=sweep-generation\n' >> "$home/state/task.meta"
      state_real=$(cd "$home/state" && pwd -P)
      mkdir -p "$home/worker/.claude"
      render_claude_wiring claude "$state_real" '' > "$home/worker/.claude/settings.local.json"
      if [ "$stage" = wiring ]; then
        cat > "$home/fakebin/git" <<'FAKE'
#!/usr/bin/env bash
"$FM_SWEEP_REAL_GIT" "$@" || exit $?
if [[ " $* " == *' checkout --detach -q '* ]]; then
  printf 'operator edit\n' >> "$FIXTURE/worker/.claude/settings.local.json"
fi
FAKE
        chmod +x "$home/fakebin/git"
      else
        cat > "$home/fakebin/rm" <<'FAKE'
#!/usr/bin/env bash
"$FM_SWEEP_REAL_RM" "$@" || exit $?
if [[ " $* " == *" $FIXTURE/worker/.claude/settings.local.json "* ]]; then
  printf 'operator file\n' > "$FIXTURE/worker/new-file"
fi
FAKE
        chmod +x "$home/fakebin/rm"
      fi
      out=$(FM_SWEEP_REAL_GIT="$(command -v git)" FM_SWEEP_REAL_RM="$(command -v rm)" sweep "$home")
      assert_contains "$out" 'uncommitted changes' "$kind late $stage work refused"
      assert_present "$home/state/task.meta" "$kind late $stage record kept"
      assert_present "$home/worker" "$kind late $stage copy kept"
      if [ "$stage" = wiring ]; then
        assert_grep 'operator edit' "$home/worker/.claude/settings.local.json" "$kind edited wiring kept"
      else
        assert_present "$home/worker/new-file" "$kind late file kept"
      fi
    done
  done
  pass 'sweep rechecks ships and scouts before wiring removal and return'
}

test_missing_copy_remote_branch_kept_until_merged() {
  local home out
  home=$(make_home missing-branch); add_worker "$home"
  printf 'unlanded\n' >> "$home/worker/file"
  git -C "$home/worker" add file
  git -C "$home/worker" commit -qm unlanded
  git -C "$home/worker" push -qu origin fm/task
  git -C "$home/projects/project" worktree remove "$home/worker"
  out=$(sweep "$home")
  assert_contains "$out" 'not confirmed merged' 'missing copy with remote work refused'
  assert_present "$home/state/task.meta" 'missing copy record kept while branch unmerged'
  git -C "$home/seed" fetch -q origin fm/task
  git -C "$home/seed" merge -q --ff-only FETCH_HEAD
  git -C "$home/seed" push -q origin main
  out=$(sweep "$home")
  assert_absent "$home/state/task.meta" 'record removed after remote branch merged'
  pass 'sweep retains missing copies with pushed unmerged work'
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

test_present_prunable_registration_skips_prune() {
  local home out inventory
  home=$(make_home present-prunable)
  git -C "$home/projects/project" worktree add -q --detach "$home/stale" main
  git -C "$home/projects/project" worktree add -q --detach "$home/present" main
  # These are disposable test repositories, not the shared worker pool.
  rm -rf -- "$home/stale"
  rm -f -- "$home/present/.git"
  inventory=$(git -C "$home/projects/project" worktree list --porcelain)
  assert_contains "$inventory" "worktree $home/present"$'\n''HEAD' 'present copy is still registered'
  assert_equals 2 "$(printf '%s\n' "$inventory" | grep -c '^prunable')" 'git marks the present copy prunable too'
  out=$(sweep "$home")
  assert_contains "$out" "prune skipped for $home/projects/project: prunable registration still present: $home/present" 'skipped prune reported'
  assert_contains "$out" '0 stale registrations' 'nothing counted as pruned'
  inventory=$(git -C "$home/projects/project" worktree list --porcelain)
  assert_contains "$inventory" "$home/present" 'present registration kept'
  assert_contains "$inventory" "$home/stale" 'missing registration kept while prune is unsafe'
  assert_present "$home/present/file" 'present copy kept'
  pass 'sweep skips repository-wide prune while any prunable copy is present'
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

test_copy_removed_before_prune_not_counted() {
  local home out pid ready=0 i
  home=$(make_home concurrent-copy); add_worker "$home"
  git -C "$home/projects/project" worktree add -q --detach "$home/pool" main
  mv "$home/fakebin/tmux" "$home/fakebin/tmux-real"
  cat > "$home/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = list-windows ] && [ ! -f "$FIXTURE/paused-once" ]; then
  touch "$FIXTURE/paused-once"
  while [ ! -f "$FIXTURE/resume" ]; do sleep 0.05; done
fi
exec "$FIXTURE/fakebin/tmux-real" "$@"
FAKE
  chmod +x "$home/fakebin/tmux"
  sweep "$home" > "$home/sweep-out" &
  pid=$!
  for ((i=0; i<200; i++)); do
    if [ -f "$home/paused-once" ]; then ready=1; break; fi
    sleep 0.05
  done
  if [ "$ready" != 1 ]; then
    kill "$pid" 2>/dev/null || true
    fail 'sweep did not pause before project prune'
  fi
  git -C "$home/projects/project" worktree remove "$home/pool"
  touch "$home/resume"
  wait "$pid"
  out=$(cat "$home/sweep-out")
  assert_equals 'swept: 1 workers, 1 copies, 0 stale registrations' "$out" 'external copy removal not counted'
  assert_absent "$home/worker" 'own teardown removed worker copy'
  assert_absent "$home/pool" 'other process removed pool copy'
  pass 'sweep counts only copies removed by its teardown or prune'
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

# A no-op sweep publishes nothing, so completion is its released lock after the prune.
wait_sweep_finished() {
  local i=0
  while { [ ! -s "$1/treehouse-calls" ] || [ -e "$1/state/.deadweight-sweep.lock" ]; } && [ "$i" -lt 600 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  assert_present "$1/treehouse-calls" 'detached sweep ran its prune'
  assert_absent "$1/state/.deadweight-sweep.lock" 'detached sweep finished'
}

test_empty_scheduled_run_keeps_unread_report() {
  local home
  home=$(make_home keep-unread)
  printf 'swept: 1 workers, 1 copies, 0 stale registrations\n' > "$home/state/.deadweight-sweep-result"
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FIXTURE="$home" \
    FM_TEARDOWN_GUARD_DONE=1 "$SWEEP" scheduled
  assert_equals 'swept: 1 workers, 1 copies, 0 stale registrations' \
    "$(cat "$home/state/.deadweight-sweep-result")" 'unread report kept after an empty scheduled run'
  assert_equals 'swept: 1 workers, 1 copies, 0 stale registrations' "$(check "$home")" 'unread report still delivered'
  pass 'an empty scheduled sweep never overwrites an unread report'
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

test_due_check_runs_before_sweep_report() {
  local home out rc=0
  home=$(make_home due-check)
  printf 'swept: 1 workers, 1 copies, 0 stale registrations\n' > "$home/state/.deadweight-sweep-result"
  date +%s > "$home/state/.deadweight-sweep-launched"
  cat > "$home/state/due.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$FIXTURE/due-check-ran"
printf 'due check ran\n'
SH
  chmod 0700 "$home/state/due.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" due >/dev/null
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FIXTURE="$home" \
    FM_TEARDOWN_GUARD_DONE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 > "$home/watcher-out" 2> "$home/watcher-err" || rc=$?
  out=$(cat "$home/watcher-out")
  assert_equals 0 "$rc" 'watcher handled due task check'
  assert_present "$home/due-check-ran" 'due task check ran before sweep wake'
  assert_contains "$out" 'due check ran' 'due task check surfaced first'
  assert_grep deadweight-sweep "$home/state/.wake-queue" 'sweep report remains queued'
  pass 'due task checks run before a completed sweep report surfaces'
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
  wait_sweep_finished "$home"
  assert_absent "$home/state/.deadweight-sweep-result" 'empty detached sweep publishes nothing'
  assert_equals 1 "$(wc -l < "$home/treehouse-calls" | tr -d ' ')" 'detached safe prune completes once'
  assert_equals '' "$(check "$home")" 'empty maintenance result stays silent'
  pass 'detached sweep survives watcher timeout and leaves watcher lock clean'
}

test_clean_stopped_and_idempotence
test_changes_kept
test_tracked_wiring_kept
test_symlinked_wiring_directory_kept
test_ignored_work_kept
test_flagged_tracked_edits_kept
test_flagged_guard_under_pipefail
test_initialized_submodule_kept
test_ignored_wiring_directories
test_generated_wiring_exact_and_edited
test_late_work_kept
test_missing_copy_remote_branch_kept_until_merged
test_decisions_secondmates_and_unknown_kept
test_recorded_pr_kept_until_merged
test_scout_gates_and_work_kept
test_stale_registration_and_live_copy
test_present_prunable_registration_skips_prune
test_pool_prune_count_and_failure
test_copy_removed_before_prune_not_counted
test_guard_cannot_force
test_pipeline_and_captain_hold_kept

test_default_daily_check_and_watcher
test_due_check_runs_before_sweep_report
test_empty_scheduled_run_keeps_unread_report
test_unsafe_records
test_detached_sweep_survives_watcher_timeout
