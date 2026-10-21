#!/usr/bin/env bash
# Claude subscription guard: Opus refusal, pace reroute, worker cap, a missing
# quota reading, and one status line per launch. Drives bin/fm-claude-quota-guard.sh
# and, for the dispatch path, bin/fm-spawn.sh with fake tmux and treehouse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/bin/fm-claude-quota-guard.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota-guard)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
TASKS_BIN=
if command -v tasks-axi >/dev/null 2>&1; then
  HAVE_TASKS_AXI=1
  TASKS_BIN=$(command -v tasks-axi)
fi
QUOTA_BIN=$(command -v quota-axi)
PACE_LINE='working [key=claude-quota-pace]: claude weekly usage is ahead of the window, so this launch was routed off the requested claude model'
CAP_LINE='paused [key=claude-quota-cap]: claude worker cap deferred this launch'
ROUTE_LINE='paused [key=claude-quota-route]: claude weekly usage is ahead of the window, and the selected dispatch rule allows no alternate worker, so this launch was deferred'
GAP_LINE='claude-quota-guard: quota-axi could not report Claude weekly usage; this launch continues without a pace check'

# Drop directories that contain a real grok or muse binary so a test chooses
# the route with the tools it placed on its own fakebin.
guard_path() {
  local fakebin=$1 dir kept=
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/grok" ] || [ -x "$dir/muse" ]; then
      continue
    fi
    kept=${kept:+$kept:}$dir
  done
  printf '%s' "$fakebin:$kept"
}

fake_tool() {
  local fakebin=$1 name=$2
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$fakebin/$name"
  chmod +x "$fakebin/$name"
}

link_quota() {
  ln -sfn "$QUOTA_BIN" "$1/quota-axi"
}

write_snap() { # <path> <percent-remaining> <seconds-until-reset>
  local path=$1 percent=$2 ahead=$3 now reset session
  now=$(date +%s)
  reset=$(date -u -d "@$((now + ahead))" +%Y-%m-%dT%H:%M:%SZ)
  session=$(date -u -d "@$((now + 7200))" +%Y-%m-%dT%H:%M:%SZ)
  cat > "$path" <<EOF
{
  "schemaVersion": 3,
  "providers": [{
    "provider": "claude",
    "label": "Claude",
    "source": "oauth",
    "accountKey": "acct-sample",
    "windows": [
      {"id": "five_hour", "label": "session", "kind": "session", "percentUsed": 10, "percentRemaining": 90, "resetsAt": "$session", "windowSeconds": 18000},
      {"id": "seven_day", "label": "week", "kind": "weekly", "percentUsed": $((100 - percent)), "percentRemaining": $percent, "resetsAt": "$reset", "windowSeconds": 604800}
    ],
    "state": {"status": "fresh", "stale": false, "sourcesTried": ["oauth"]}
  }]
}
EOF
}

write_brief() { # <home> <id> [type] [client]
  local home=$1 id=$2 type=${3-} client=${4-}
  mkdir -p "$home/data/$id"
  {
    printf '%s\n' '# Task' "## Captain's intent" "Exercise the quota guard for $id." ''
    printf '%s\n' '## Firstmate spec' 'Goal: Exercise the quota guard.' 'Off-limits: Unrelated files.'
    printf '%s\n' 'Contracts and gates (follow them; spawned inside a pipeline, move only through its states): none'
    if [ -n "$type" ]; then
      printf '%s\n' '' '## Task type' "Name: $type"
    fi
    if [ "$client" = client ]; then
      printf '%s\n' 'client-data: yes'
    fi
    printf '%s\n' '' '# Definition of done' 'Delivery contract: mode=no-mistakes'
  } > "$home/data/$id/brief.md"
}

make_home() { # <name> <id> [type] [client]
  local name=$1 id=$2 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/user-home" "$TMP_ROOT/$name/fakebin"
  touch "$home/state/.last-watcher-beat"
  write_brief "$home" "$id" "${3-}" "${4-}"
  printf '%s\n' "$home"
}

verdict_field() { # <file> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

key_count() { # <file> <text>
  if [ ! -f "$1" ]; then
    printf 0
    return
  fi
  grep -c -F -- "$2" "$1" || true
}

# A status line is stamped before it is appended. Count lines whose text
# matches the canonical event once that time tag is removed.
canonical_count() { # <file> <unstamped-line>
  local line stripped n=0
  if [ ! -f "$1" ]; then
    printf 0
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=$(printf '%s\n' "$line" | sed -E 's/ \[at=[0-9]+\]//')
    [ "$stripped" = "$2" ] && n=$((n + 1))
  done <"$1"
  printf '%s' "$n"
}

run_check() { # <home> <id> <model> [extra guard args]
  local home=$1 id=$2 model=$3
  shift 3
  mkdir -p "$home/user-home"
  if [ -n "${FM_TEST_SNAP:-}" ]; then
    HOME="$home/user-home" PATH="$(guard_path "$TMP_ROOT/current-fakebin")" \
      QUOTA_AXI_SNAPSHOT="$FM_TEST_SNAP" \
      "$GUARD" check \
      --config "$home/config" --state "$home/state" --home "$home" \
      --id "$id" --brief "$home/data/$id/brief.md" --model="$model" \
      --verdict "$home/verdict" "$@"
  else
    env -u QUOTA_AXI_SNAPSHOT \
      HOME="$home/user-home" PATH="$(guard_path "$TMP_ROOT/current-fakebin")" \
      "$GUARD" check \
      --config "$home/config" --state "$home/state" --home "$home" \
      --id "$id" --brief "$home/data/$id/brief.md" --model="$model" \
      --verdict "$home/verdict" "$@"
  fi
}

use_fakebin() { # <case-name>
  TMP_ROOT_FAKE="$TMP_ROOT/$1/fakebin"
  mkdir -p "$TMP_ROOT_FAKE"
  # shellcheck disable=SC2034
  ln -sfn "$TMP_ROOT_FAKE" "$TMP_ROOT/current-fakebin-link"
  rm -rf "$TMP_ROOT/current-fakebin"
  mkdir -p "$TMP_ROOT/current-fakebin"
  # The path helper reads this directory. Copying links keeps each case isolated.
  if [ -n "$(ls -A "$TMP_ROOT_FAKE" 2>/dev/null || true)" ]; then
    cp -a "$TMP_ROOT_FAKE/." "$TMP_ROOT/current-fakebin/"
  fi
}

prepare_fake() { # <case-name> [grok|muse|quota ...]
  local name=$1 tool
  shift
  rm -rf "$TMP_ROOT/$name/fakebin"
  mkdir -p "$TMP_ROOT/$name/fakebin"
  for tool in "$@"; do
    case "$tool" in
      quota) link_quota "$TMP_ROOT/$name/fakebin" ;;
      *) fake_tool "$TMP_ROOT/$name/fakebin" "$tool" ;;
    esac
  done
  rm -rf "$TMP_ROOT/current-fakebin"
  mkdir -p "$TMP_ROOT/current-fakebin"
  cp -a "$TMP_ROOT/$name/fakebin/." "$TMP_ROOT/current-fakebin/"
}

# --- command ---------------------------------------------------------------

test_exact_margin_does_not_reroute() {
  local home out rc=0
  home=$(make_home exact task-w engineering)
  prepare_fake exact quota grok
  write_snap "$TMP_ROOT/exact/snap.json" 40 302400
  FM_TEST_SNAP="$TMP_ROOT/exact/snap.json"
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "an exact 10-point lead refused the launch: $out"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "an exact 10-point lead rerouted"
  assert_equals opus "$(verdict_field "$home/verdict" model)" "an exact 10-point lead changed the model"
  pass "usage exactly at the margin stays on the requested model"
}

test_pace_prefers_grok_then_muse_then_sonnet() {
  local home out rc=0
  home=$(make_home pace-grok task-w writing)
  prepare_fake pace-grok quota grok muse
  write_snap "$TMP_ROOT/pace-grok/snap.json" 30 259200
  FM_TEST_SNAP="$TMP_ROOT/pace-grok/snap.json"
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "a hot window refused a grok route: $out"
  assert_equals reroute "$(verdict_field "$home/verdict" action)" "a hot window did not reroute"
  assert_equals grok "$(verdict_field "$home/verdict" harness)" "a hot window did not prefer grok"
  assert_contains "$out" "routing this launch to grok" "the grok route was not announced"

  home=$(make_home pace-muse task-w writing client)
  prepare_fake pace-muse quota grok muse
  write_snap "$TMP_ROOT/pace-muse/snap.json" 30 259200
  FM_TEST_SNAP="$TMP_ROOT/pace-muse/snap.json"
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "client data refused a muse route: $out"
  assert_equals muse "$(verdict_field "$home/verdict" harness)" "client data was offered to grok"
  assert_contains "$out" "routing this launch to muse" "the muse route was not announced"

  home=$(make_home pace-sonnet task-w writing)
  prepare_fake pace-sonnet quota
  write_snap "$TMP_ROOT/pace-sonnet/snap.json" 30 259200
  FM_TEST_SNAP="$TMP_ROOT/pace-sonnet/snap.json"
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "a hot window with no other tool refused sonnet: $out"
  assert_equals claude "$(verdict_field "$home/verdict" harness)" "sonnet left claude"
  assert_equals sonnet "$(verdict_field "$home/verdict" model)" "the fallback model was not sonnet"
  pass "a hot window routes to grok, then muse, then claude sonnet"
}

test_opus_refused_for_writing_and_allowed_when_cleared() {
  local home out rc=0
  home=$(make_home opus-no task-w writing)
  prepare_fake opus-no quota
  write_snap "$TMP_ROOT/opus-no/snap.json" 95 259200
  FM_TEST_SNAP="$TMP_ROOT/opus-no/snap.json"
  out=$(run_check "$home" task-w opus 2>&1) || rc=$?
  expect_code 1 "$rc" "opus on a writing task was launched: $out"
  assert_contains "$out" "refused: Opus is not allowed for task type writing; task task-w was not launched" \
    "the refusal did not name the task type"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota')" "an opus refusal wrote a status line"

  printf '%s\n' '{"opus_refused_types":["execution"]}' > "$home/config/claude-quota-guard.json"
  rc=0
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "a writing launch was refused despite an execution-only list: $out"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "an execution-only list rerouted"
  assert_equals opus "$(verdict_field "$home/verdict" model)" "an execution-only list changed the model"
  pass "opus is refused only for configured task types"
}

test_missing_quota_proceeds_and_still_checks_opus_and_cap() {
  local home out rc=0
  home=$(make_home gap task-q engineering)
  prepare_fake gap
  out=$(run_check "$home" task-q haiku) || rc=$?
  expect_code 0 "$rc" "a missing quota reading refused the launch: $out"
  assert_contains "$out" "$GAP_LINE" "the missing reading was not stated"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a missing reading rerouted"
  assert_equals haiku "$(verdict_field "$home/verdict" model)" "a missing reading changed the model"

  write_brief "$home" task-w writing
  rc=0
  out=$(run_check "$home" task-w opus 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing reading skipped the opus refusal: $out"
  assert_contains "$out" "$GAP_LINE" "the opus refusal hid the missing reading"
  assert_contains "$out" "refused: Opus is not allowed for task type writing" "opus was not refused without a reading"

  write_brief "$home" task-c engineering
  fm_write_meta "$home/state/occ-a.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-b.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-c.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-d.meta" harness=claude kind=ship
  rc=0
  out=$(run_check "$home" task-c haiku 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a missing reading skipped the cap: $out"
  assert_contains "$out" "deferred:" "the cap did not defer"
  pass "a missing quota reading continues, and opus refusal and the cap still apply"
}

test_status_line_is_written_once() {
  local home out rc=0 file
  home=$(make_home once task-p writing)
  prepare_fake once quota grok
  write_snap "$TMP_ROOT/once/snap.json" 30 259200
  FM_TEST_SNAP="$TMP_ROOT/once/snap.json"
  out=$(run_check "$home" task-p opus --apply-status) || rc=$?
  expect_code 0 "$rc" "the first pace notice failed: $out"
  rc=0
  out=$(run_check "$home" task-p opus --apply-status) || rc=$?
  expect_code 0 "$rc" "the pace retry failed: $out"
  file="$home/state/task-p.status"
  assert_equals 1 "$(canonical_count "$file" "$PACE_LINE")" "the pace line was not written exactly once"
  assert_equals 1 "$(key_count "$file" '[at=')" "the pace line was not stamped"

  home=$(make_home once-cap task-c engineering)
  prepare_fake once-cap quota
  write_snap "$TMP_ROOT/once-cap/snap.json" 95 259200
  FM_TEST_SNAP="$TMP_ROOT/once-cap/snap.json"
  fm_write_meta "$home/state/occ-a.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-b.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-c.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-d.meta" harness=claude kind=ship
  rc=0
  out=$(run_check "$home" task-c haiku --apply-status 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the first cap deferral failed: $out"
  rc=0
  out=$(run_check "$home" task-c haiku --apply-status 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the cap retry failed: $out"
  file="$home/state/task-c.status"
  assert_equals 1 "$(canonical_count "$file" "$CAP_LINE")" "the cap line was not written exactly once"
  assert_equals 0 "$(key_count "$file" 'claude-quota-pace')" "a cap deferral also wrote the pace line"
  pass "a pace reroute and a cap deferral each append one status line"
}

test_cap_counts_pr_workers_and_ignores_secondmates() {
  local home out rc=0
  home=$(make_home seats task-c engineering)
  prepare_fake seats quota
  write_snap "$TMP_ROOT/seats/snap.json" 95 259200
  FM_TEST_SNAP="$TMP_ROOT/seats/snap.json"
  fm_write_meta "$home/state/occ-a.meta" harness=claude kind=ship pr=https://example.invalid/pull/1
  fm_write_meta "$home/state/occ-b.meta" harness=claude kind=secondmate
  fm_write_meta "$home/state/occ-c.meta" harness=claude kind=ship
  fm_write_meta "$home/state/occ-d.meta" harness=claude kind=scout
  fm_write_meta "$home/state/occ-e.meta" harness=claude kind=ship
  fm_write_meta "$home/state/task-c.meta" harness=claude kind=ship
  out=$(run_check "$home" task-c haiku 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a live or unverified PR worker did not hold a seat: $out"
  fm_write_meta "$home/state/occ-a.meta" harness=claude kind=ship pr=https://example.invalid/pull/1 \
    window=retired:fm-occ-a tmux_socket=relative-socket
  cat > "$TMP_ROOT/current-fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf "can't find session: retired\n" >&2
exit 1
SH
  chmod +x "$TMP_ROOT/current-fakebin/tmux"
  rc=0
  out=$(run_check "$home" task-c haiku 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unproven missing endpoint freed a Claude seat: $out"
  rm "$home/state/occ-a.meta"
  rc=0
  out=$(run_check "$home" task-c haiku) || rc=$?
  expect_code 0 "$rc" "three remaining workers filled the cap: $out"
  pass "a PR worker and an unproven missing endpoint hold seats"
}

test_bad_config_and_unreadable_record_refuse() {
  local home out rc=0
  home=$(make_home bad task-w writing)
  prepare_fake bad quota
  printf '%s\n' '{"not-a-key": true}' > "$home/config/claude-quota-guard.json"
  out=$(run_check "$home" task-w opus 2>&1) || rc=$?
  expect_code 1 "$rc" "a malformed config was accepted: $out"
  assert_contains "$out" 'config/claude-quota-guard.json is malformed' "the malformed file was not named"
  assert_not_contains "$out" 'not-a-key' "the malformed file contents were printed"
  local invalid
  for invalid in '{"enabled":false}' '{"concurrent_claude_cap":null}' '{"opus_refused_types":[]}'; do
    printf '%s\n' "$invalid" > "$home/config/claude-quota-guard.json"
    rc=0
    out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
    expect_code 1 "$rc" "a guard opt-out was accepted: $invalid"
  done
  printf '%s\n%s\n' '{"concurrent_claude_cap":1}' '{"concurrent_claude_cap":4}' > "$home/config/claude-quota-guard.json"
  rc=0
  out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
  expect_code 1 "$rc" "multiple JSON objects bypassed config validation: $out"
  assert_contains "$out" 'config/claude-quota-guard.json is malformed' "multiple JSON objects were not rejected"

  rm -f "$home/config/claude-quota-guard.json"
  fm_write_meta "$home/state/occ-a.meta" harness=claude kind=ship
  chmod 000 "$home/state/occ-a.meta"
  rc=0
  out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
  chmod 600 "$home/state/occ-a.meta"
  expect_code 1 "$rc" "an unreadable task record was counted as empty: $out"
  assert_contains "$out" "unreadable" "the unreadable record was not reported"
  pass "a malformed config and an unreadable task record refuse the launch"
}

test_selected_opus_rule_defers_without_alternate() {
  local home out rc=0
  home=$(make_home selected task-w engineering)
  prepare_fake selected quota grok muse
  write_snap "$TMP_ROOT/selected/snap.json" 30 259200
  printf '%s\n' '{"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$home/config/crew-dispatch.json"
  FM_TEST_SNAP="$TMP_ROOT/selected/snap.json"
  out=$(run_check "$home" task-w opus \
    --dispatch-rule '{"default":true}' --effort high --apply-status 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Opus-only rule selected an unlisted worker: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "route deferral did not write one line"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-pace')" "route deferral wrote a pace line"
  rc=0
  out=$(run_check "$home" task-w opus \
    --dispatch-rule '{"default":true}' --effort high --apply-status 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Opus-only rule launched on retry: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "route retry wrote another line"
  pass "an Opus-only dispatch rule defers with one route line"
}

test_refusal_only_relaunch_model() {
  local home out rc=0
  home=$(make_home relaunch task-w writing)
  prepare_fake relaunch quota
  out=$(run_check "$home" task-w opus --refusal-only 2>&1) || rc=$?
  expect_code 1 "$rc" "an Opus relaunch of a writing task was allowed: $out"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota')" "a refused relaunch wrote status"
  pass "an Opus relaunch is refused without a pace or cap check"
}

test_valid_margin_keeps_allowed_model() {
  local home out rc=0
  home=$(make_home off task-w engineering)
  prepare_fake off quota grok
  write_snap "$TMP_ROOT/off/snap.json" 30 259200
  printf '%s\n' '{"pace_margin_points":100}' > "$home/config/claude-quota-guard.json"
  FM_TEST_SNAP="$TMP_ROOT/off/snap.json"
  out=$(run_check "$home" task-w opus) || rc=$?
  expect_code 0 "$rc" "a configured margin refused allowed opus: $out"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a configured margin rerouted"
  assert_equals opus "$(verdict_field "$home/verdict" model)" "a configured margin changed the model"
  pass "a configured margin keeps an allowed Claude model"
}

# --- spawn path ------------------------------------------------------------

add_item() {
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

make_case() { # <name> <id> [type] [client]
  local name=$1 id=$2 case_dir fakebin home
  case_dir="$TMP_ROOT/spawn-$name"
  mkdir -p "$case_dir"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    if [ -f "${FM_FAKE_CALL_LOG%/*}/inventory-unreadable" ]; then
      printf 'unavailable\n' >&2
      exit 1
    fi
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    # A launch is typed as `. '<staged file>'`. Record that file so the test
    # sees the worker command, not only the short source line.
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        case "$a" in
          ". '"*"'")
            staged=${a#". '"}
            staged=${staged%"'"}
            if [ "${FM_FAKE_PAUSE_LAUNCH:-0}" = 1 ]; then
              : > "${FM_FAKE_CALL_LOG%/*}/launch-paused"
              for ((pause_try=0; pause_try<300; pause_try++)); do
                [ ! -f "${FM_FAKE_CALL_LOG%/*}/release-launch" ] || break
                sleep 0.05
              done
              [ -f "${FM_FAKE_CALL_LOG%/*}/release-launch" ] || exit 1
            fi
            if [ -f "$staged" ]; then
              cat "$staged" >> "$FM_FAKE_CALL_LOG"
              printf '\n' >> "$FM_FAKE_CALL_LOG"
            fi
            ;;
        esac
      fi
      prev=$a
    done
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  # The closed path hides the directory that also holds grok and muse, so the
  # backlog tool has to be linked beside the fakes or a launch cannot move its item.
  if [ -n "$TASKS_BIN" ]; then
    ln -sfn "$TASKS_BIN" "$fakebin/tasks-axi"
  fi
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/sample-project"
  fm_git_add_origin "$case_dir/sample-project" "$case_dir/sample-project.origin.git"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$home/user-home" "$case_dir/grok-home" "$case_dir/xdg/muse"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '{}\n' > "$case_dir/xdg/muse/auth.json"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  write_brief "$home" "$id" "${3-}" "${4-}"
  add_item "$home" "$id"
  printf '%s\n' "$case_dir"
}

new_worktree() {
  git -C "$1/sample-project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() { # <case> <pane> <args...>
  local case_dir=$1 pane=$2
  shift 2
  (
    if [ -n "${FM_TEST_SNAP:-}" ]; then
      export QUOTA_AXI_SNAPSHOT=$FM_TEST_SNAP
    else
      unset QUOTA_AXI_SNAPSHOT || true
    fi
    env -u META_API_KEY \
      HOME="$case_dir/user-home" CLAUDE_CONFIG_DIR='' \
      GROK_HOME="$case_dir/grok-home" XDG_CONFIG_HOME="$case_dir/xdg" \
      FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
      FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
      FM_FAKE_PAUSE_LAUNCH="${FM_FAKE_PAUSE_LAUNCH:-0}" \
      PATH="$(guard_path "$case_dir/fakebin")" \
      "$SPAWN" "$@"
  )
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

assert_nothing_created() {
  local case_dir=$1 id=$2 before=$3 worktrees=$4 home unexpected
  home="$case_dir/home"
  assert_absent "$home/state/$id.meta" "a refused spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a refused spawn rendered a launch brief for $id"
  unexpected=$(tail -n +"$((before + 1))" "$case_dir/calls.log" | sed '/^list-windows /d')
  [ -z "$unexpected" ] ||
    fail "a refused spawn touched the terminal or worktree pool for $id: $unexpected"
  assert_equals "$worktrees" "$(git -C "$case_dir/sample-project" worktree list --porcelain)" \
    "a refused spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a refused spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

test_spawn_refuses_opus_for_writing() {
  local case_dir home out rc=0 before trees
  case_dir=$(make_case opus task-w writing)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 1 "$rc" "spawn launched an opus writing task: $out"
  assert_contains "$out" "refused: Opus is not allowed for task type writing; task task-w was not launched" \
    "spawn did not report the opus refusal"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota')" "spawn wrote a status line for an opus refusal"
  pass "spawn refuses opus for a writing task before creating the worker"
}

test_spawn_refuses_raw_opus_for_writing() {
  local case_dir home out rc before trees command variant
  for variant in plain joined separate continued multiple; do
    case "$variant" in
      plain) command='claude --model opus' ;;
      joined) command='claude --model=o"pus"' ;;
      separate) command='claude --model o"pus"' ;;
      continued) command=$'claude --model=op\\\nus' ;;
      multiple) command=$'claude --model=haiku\nclaude --model=opus' ;;
    esac
    case_dir=$(make_case "raw-opus-$variant" task-w writing)
    home="$case_dir/home"
    before=$(call_count "$case_dir")
    trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
    rc=0
    out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
      "$command" --mode no-mistakes --yolo off 2>&1) || rc=$?
    expect_code 1 "$rc" "a raw Opus writing launch was allowed: $out"
    if [ "$variant" = continued ] || [ "$variant" = multiple ]; then
      assert_contains "$out" "raw Claude model syntax cannot be checked safely" "line continuation was not refused"
    else
      assert_contains "$out" "refused: Opus is not allowed for task type writing" "raw Opus refusal was not reached"
    fi
    assert_nothing_created "$case_dir" task-w "$before" "$trees"
    assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota')" "raw Opus refusal wrote status"
  done
  pass "raw Claude Opus model syntax refuses before launch"
}

test_spawn_selected_opus_rule_defers() {
  local case_dir home out rc=0 before trees
  case_dir=$(make_case rule-only-opus task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' '{"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$home/config/crew-dispatch.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --dispatch-rule '{"default":true}' \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Opus-only rule launched an unlisted worker: $out"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "spawn missed route line"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-pace')" "spawn wrote pace line"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --dispatch-rule '{"default":true}' \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Opus-only rule launched on retry: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "spawn retry duplicated route line"
  pass "spawn leaves an Opus-only rule queued with one route line"
}

test_spawn_keeps_published_claude_seat_during_delivery() {
  local case_dir home pane out rc=0 first_pid tries deadline now
  case_dir=$(make_case published-seat task-a engineering)
  home="$case_dir/home"
  write_brief "$home" task-b engineering
  add_item "$home" task-b
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  pane=$(new_worktree "$case_dir" task-a)
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_FAKE_PAUSE_LAUNCH=1 run_spawn "$case_dir" "$pane" task-a "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off > "$case_dir/first.out" 2>&1 &
  first_pid=$!
  for ((tries=0; tries<300; tries++)); do
    [ ! -f "$case_dir/launch-paused" ] || break
    sleep 0.05
  done
  [ -f "$case_dir/launch-paused" ] || fail "first Claude launch did not reach its published delivery gap: $(cat "$case_dir/first.out")"
  assert_present "$home/state/task-a.meta" "first launch had no published record during delivery"
  deadline=$(awk -F= '$1=="quota_reservation_until" {print $2}' "$home/state/task-a.meta")
  now=$(date +%s)
  [[ "$deadline" =~ ^[0-9]+$ ]] && [ "$deadline" -ge "$now" ] && [ "$deadline" -le "$((now + 90))" ] ||
    fail "published Claude reservation was not bounded by launch wait: $deadline"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "second Claude worker entered while the first was published but not observable: $out"
  assert_absent "$home/state/task-b.meta" "deferred Claude worker published a record"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "published-seat deferral missed its cap line"
  : > "$case_dir/release-launch"
  wait "$first_pid" || fail "first Claude launch failed after release: $(cat "$case_dir/first.out")"
  pass "a published Claude launch holds the seat before its agent is observable"
}

test_spawn_reroute_keeps_inferred_dispatch_rule() {
  local case_dir home pane out rc=0
  case_dir=$(make_case inferred-rule task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' '{"default":[{"harness":"claude","model":"opus","effort":"high","reasoning_class":"strong"},{"harness":"grok","model":"grok-4.7","effort":"high","reasoning_class":"strong"}],"rules":[{"when":"other work","use":[{"harness":"grok","model":"grok-4.7","effort":"high","reasoning_class":"strong"}]}]}' > "$home/config/crew-dispatch.json"
  pane=$(new_worktree "$case_dir" task-w)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an inferred rule lost its identity after quota reroute: $out"
  assert_equals grok "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-w.meta")" "reroute did not publish Grok"
  assert_equals '{"default":true}' "$(awk -F= '$1=="dispatch_rule"{print $2}' "$home/state/task-w.meta")" "reroute lost the default rule"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$PACE_LINE")" "reroute missed its pace line"
  pass "quota reroute preserves an inferred dispatch rule"
}

test_spawn_omitted_model_infers_dispatch_rule() {
  local case_dir home pane out rc=0
  unset FM_SCHEDULED_WORKER_PLAN || true
  unset FM_CQG_TRIED || true
  case_dir=$(make_case omitted-model task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  jq -n '{default:[{harness:"claude"},{harness:"grok",model:"grok-4.7",effort:"medium"}]}' \
    > "$home/config/crew-dispatch.json"
  pane=$(new_worktree "$case_dir" task-w)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
    --harness claude --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an omitted model deferred a unique default rule: $out"
  assert_equals grok "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-w.meta")" "omitted model did not reroute to grok"
  assert_equals '{"default":true}' "$(awk -F= '$1=="dispatch_rule"{print $2}' "$home/state/task-w.meta")" "omitted model lost the default rule"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$PACE_LINE")" "omitted model missed its pace line"
  pass "an omitted model infers the unique default rule and reroutes"
}

test_spawn_scheduled_reroute_skips_tried_profile() {
  local case_dir home out rc=0 before trees
  case_dir=$(make_case tried-sonnet task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  jq -n '{authorized:true,reasoning_class:"strong/approved",profiles:[
      {harness:"claude",model:"opus",effort:"high",reasoning_class:"strong/approved"},
      {harness:"claude",model:"sonnet",effort:"high",reasoning_class:"strong/approved"}
    ]}' > "$case_dir/plan.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_SCHEDULED_WORKER_PLAN="$case_dir/plan.json"
  FM_CQG_TRIED='[{"harness":"claude","model":"sonnet","effort":"high","reasoning_class":"strong/approved"}]'
  export FM_SCHEDULED_WORKER_PLAN FM_CQG_TRIED
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  unset FM_SCHEDULED_WORKER_PLAN || true
  unset FM_CQG_TRIED || true
  expect_code "$DEFER_EXIT" "$rc" "a tried Sonnet destination was provisioned: $out"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "tried destination missed its route line"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-pace')" "tried destination wrote a pace line"
  pass "a scheduled reroute skips a profile already tried in the episode"
}

test_spawn_scheduled_plan_routes_only_listed_profiles() {
  local case_dir home pane out rc=0 before trees
  case_dir=$(make_case plan-sonnet task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' '{"authorized":true,"reasoning_class":"strong/approved","profiles":[{"harness":"claude","model":"opus","effort":"high","reasoning_class":"strong/approved"},{"harness":"claude","model":"sonnet","effort":"high","reasoning_class":"strong/approved"}]}' > "$case_dir/plan.json"
  pane=$(new_worktree "$case_dir" task-w)
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_SCHEDULED_WORKER_PLAN="$case_dir/plan.json"
  export FM_SCHEDULED_WORKER_PLAN
  out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a scheduled Sonnet alternate did not launch: $out"
  assert_contains "$out" "routing this launch to claude sonnet" "the scheduled plan was not used for the route"
  assert_grep "--model 'sonnet'" "$case_dir/calls.log" "the scheduled Sonnet model was not launched"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$PACE_LINE")" "the scheduled route missed its pace line"

  case_dir=$(make_case plan-opus-only task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' '{"authorized":true,"reasoning_class":"strong/approved","profiles":[{"harness":"claude","model":"opus","effort":"high","reasoning_class":"strong/approved"}]}' > "$case_dir/plan.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_SCHEDULED_WORKER_PLAN="$case_dir/plan.json"
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Opus-only scheduled plan launched an unlisted worker: $out"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$ROUTE_LINE")" "the scheduled deferral missed its route line"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-pace')" "the scheduled deferral wrote a pace line"
  unset FM_SCHEDULED_WORKER_PLAN
  pass "scheduled plans route only listed profiles or defer once"
}

test_spawn_reroutes_hot_window() {
  local case_dir home pane out rc=0
  case_dir=$(make_case hot task-w writing)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  pane=$(new_worktree "$case_dir" task-w)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a hot window did not launch: $out"
  assert_contains "$out" "routing this launch to grok" "spawn did not announce the grok route"
  assert_grep 'grok --permission-mode bypassPermissions' "$case_dir/calls.log" "the launch did not use grok"
  assert_equals grok "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-w.meta")" "the recorded worker was not grok"
  assert_equals 1 "$(canonical_count "$home/state/task-w.status" "$PACE_LINE")" "the pace line was not written once"

  case_dir=$(make_case muse task-m writing client)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  pane=$(new_worktree "$case_dir" task-m)
  FM_TEST_SNAP="$case_dir/snap.json"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-m "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "client data did not launch on muse: $out"
  assert_grep  '--contributor-mode off' "$case_dir/calls.log" "the muse launch left contributor mode on"
  assert_equals muse "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-m.meta")" "client data was not recorded as muse"
  pass "spawn reroutes a hot window to grok, or to muse when the launch carries client data"
}

test_spawn_sonnet_and_cap() {
  local case_dir home pane out rc=0 before trees i
  case_dir=$(make_case sonnet task-s writing)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 30 259200
  pane=$(new_worktree "$case_dir" task-s)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$pane" task-s "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "sonnet fallback did not launch: $out"
  assert_contains "$out" "routing this launch to claude sonnet" "spawn did not announce sonnet"
  assert_grep  "--model 'sonnet'" "$case_dir/calls.log" "the launch did not request sonnet"
  assert_equals claude "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-s.meta")" "sonnet left claude"
  assert_equals 1 "$(canonical_count "$home/state/task-s.status" "$PACE_LINE")" "the sonnet route skipped the pace line"

  case_dir=$(make_case cap task-c engineering)
  touch "$case_dir/inventory-unreadable"
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  FM_TEST_SNAP="$case_dir/snap.json"
  for i in a b c d; do
    fm_write_meta "$home/state/occ-$i.meta" \
      "window=firstmate:fm-occ-$i" "endpoint_task_id=occ-$i" \
      "worktree=$home/absent-occ-$i" "project=$case_dir/sample-project" \
      harness=claude kind=ship mode=no-mistakes yolo=off "spawn_gen=s-occ-$i"
  done
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-c "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a fifth Claude worker was launched: $out"
  assert_contains "$out" "deferred:" "the cap did not say the launch was deferred"
  assert_nothing_created "$case_dir" task-c "$before" "$trees"
  assert_equals 1 "$(canonical_count "$home/state/task-c.status" "$CAP_LINE")" "the cap line was missing"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-c "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the cap retry launched: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-c.status" "$CAP_LINE")" "the cap retry appended another line"

  case_dir=$(make_case both task-b writing)
  touch "$case_dir/inventory-unreadable"
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 30 259200
  FM_TEST_SNAP="$case_dir/snap.json"
  for i in a b c d; do
    fm_write_meta "$home/state/occ-$i.meta" \
      "window=firstmate:fm-occ-$i" "endpoint_task_id=occ-$i" \
      "worktree=$home/absent-occ-$i" "project=$case_dir/sample-project" \
      harness=claude kind=ship mode=no-mistakes yolo=off "spawn_gen=s-occ-$i"
  done
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a hot window at the cap did not defer: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "the combined deferral missed the cap line"
  assert_equals 0 "$(key_count "$home/state/task-b.status" 'claude-quota-pace')" "the combined deferral also wrote the pace line"
  rm -f "$home/state/occ-d.meta"
  pane=$(new_worktree "$case_dir" task-b)
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the under-cap retry did not launch: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "the retry added another cap line"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$PACE_LINE")" "the under-cap retry missed the pace line"
  assert_grep  "--model 'sonnet'" "$case_dir/calls.log" "the under-cap retry did not request sonnet"
  pass "spawn defers at the cap with one line, and a later under-cap retry records the pace line once"
}

test_spawn_missing_quota_proceeds_and_allowed_opus() {
  local case_dir home pane out rc=0
  case_dir=$(make_case gap task-q engineering)
  home="$case_dir/home"
  pane=$(new_worktree "$case_dir" task-q)
  unset FM_TEST_SNAP || true
  out=$(run_spawn "$case_dir" "$pane" task-q "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a missing quota reading blocked spawn: $out"
  assert_contains "$out" "$GAP_LINE" "spawn did not state the missing reading"
  assert_equals claude "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-q.meta")" "the launch left claude"
  assert_grep  "--model 'haiku'" "$case_dir/calls.log" "the requested model was not kept"
  assert_equals 0 "$(key_count "$home/state/task-q.status" 'claude-quota-pace')" "a missing reading wrote a pace line"

  case_dir=$(make_case allowed task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' '{"pace_margin_points":100}' > "$home/config/claude-quota-guard.json"
  pane=$(new_worktree "$case_dir" task-w)
  FM_TEST_SNAP="$case_dir/snap.json"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
    --harness claude --model opus --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a configured margin blocked allowed opus: $out"
  assert_grep  "--model 'opus'" "$case_dir/calls.log" "a configured margin did not keep opus"
  assert_equals claude "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-w.meta")" "a configured margin left claude"
  pass "spawn continues when quota is missing and a configured margin keeps allowed opus"
}

test_spawn_ignores_non_claude() {
  local case_dir home pane out rc=0
  case_dir=$(make_case other task-o engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' codex > "$home/config/crew-harness"
  pane=$(new_worktree "$case_dir" task-o)
  FM_TEST_SNAP="$case_dir/snap.json"
  out=$(run_spawn "$case_dir" "$pane" task-o "$case_dir/sample-project" \
    --harness codex --model gpt-6 --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a codex launch was refused by the claude guard: $out"
  assert_equals codex "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-o.meta")" "the codex launch changed harness"
  if grep -F -q 'grok --permission-mode' "$case_dir/calls.log"; then
    fail "a codex launch was rerouted to grok"
  fi
  pass "a non-claude launch is not rewritten by the claude guard"
}

test_exact_margin_does_not_reroute
test_pace_prefers_grok_then_muse_then_sonnet
test_opus_refused_for_writing_and_allowed_when_cleared
test_missing_quota_proceeds_and_still_checks_opus_and_cap
test_status_line_is_written_once
test_cap_counts_pr_workers_and_ignores_secondmates
test_bad_config_and_unreadable_record_refuse
test_selected_opus_rule_defers_without_alternate
test_refusal_only_relaunch_model
test_valid_margin_keeps_allowed_model
test_spawn_refuses_opus_for_writing
test_spawn_refuses_raw_opus_for_writing
test_spawn_selected_opus_rule_defers
test_spawn_keeps_published_claude_seat_during_delivery
test_spawn_reroute_keeps_inferred_dispatch_rule
test_spawn_omitted_model_infers_dispatch_rule
test_spawn_scheduled_reroute_skips_tried_profile
test_spawn_scheduled_plan_routes_only_listed_profiles
test_spawn_reroutes_hot_window
test_spawn_sonnet_and_cap
test_spawn_missing_quota_proceeds_and_allowed_opus
test_spawn_ignores_non_claude
