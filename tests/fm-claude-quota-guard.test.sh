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
  cat > "$1/quota-axi" <<'EOF'
#!/bin/sh
set -u
snap=${QUOTA_AXI_SNAPSHOT-}
[ -n "$snap" ] && [ -f "$snap" ] || exit 1
case " $* " in
  *' --json '*) cat "$snap" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/quota-axi"
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

# A background child inherits this file's fixture cleanup and can delete the
# tree when it exits. A reservation test needs a pid that is already gone.
unused_dead_pid() {
  local pid=4194304
  if kill -0 "$pid" 2>/dev/null; then
    pid=4194317
  fi
  if kill -0 "$pid" 2>/dev/null; then
    fail "reservation pid is still alive"
  fi
  printf '%s\n' "$pid"
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

test_reported_weekly_window_controls_pace() {
  local home snap out rc=0
  home=$(make_home reported-window task-w engineering)
  prepare_fake reported-window quota grok
  write_snap "$TMP_ROOT/reported-window/default.json" 50 302400
  snap="$TMP_ROOT/reported-window/five-day.json"
  jq '(.providers[0].windows[] | select(.id == "seven_day") | .windowSeconds) = 432000' \
    "$TMP_ROOT/reported-window/default.json" > "$snap"
  FM_TEST_SNAP="$snap"
  out=$(run_check "$home" task-w haiku) || rc=$?
  expect_code 0 "$rc" "a reported five-day window refused the launch: $out"
  assert_equals reroute "$(verdict_field "$home/verdict" action)" "pace ignored the reported window length"
  assert_equals grok "$(verdict_field "$home/verdict" harness)" "the reported window chose the wrong route"

  jq '(.providers[0].windows[] | select(.id == "seven_day") | .id) = "rolling_week"' "$snap" \
    > "$TMP_ROOT/reported-window/weekly-kind.json"
  FM_TEST_SNAP="$TMP_ROOT/reported-window/weekly-kind.json"
  rc=0
  out=$(run_check "$home" task-w haiku) || rc=$?
  expect_code 0 "$rc" "a weekly-kind window refused the launch: $out"
  assert_equals reroute "$(verdict_field "$home/verdict" action)" "the weekly-kind window lost its length"

  jq 'del(.providers[0].windows[] | select(.id == "seven_day") | .windowSeconds)' "$snap" \
    > "$TMP_ROOT/reported-window/no-length.json"
  FM_TEST_SNAP="$TMP_ROOT/reported-window/no-length.json"
  rc=0
  out=$(run_check "$home" task-w haiku) || rc=$?
  expect_code 0 "$rc" "a missing window length refused the launch: $out"
  assert_contains "$out" "$GAP_LINE" "a missing window length hid the quota gap"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a missing window length drove pace"

  jq 'del(.providers[0].windows[] | select(.id == "seven_day") | .resetsAt)' "$snap" \
    > "$TMP_ROOT/reported-window/no-reset.json"
  FM_TEST_SNAP="$TMP_ROOT/reported-window/no-reset.json"
  rc=0
  out=$(run_check "$home" task-w haiku) || rc=$?
  expect_code 0 "$rc" "a missing reset time refused the launch: $out"
  assert_contains "$out" "$GAP_LINE" "a missing reset time hid the quota gap"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a missing reset time drove pace"

  jq '(.providers[0].windows[] | select(.id == "seven_day") | .resetsAt) as $reset
    | .providers[0].windows += [{"id":"seven_day","kind":"weekly","percentRemaining":30,"resetsAt":$reset}]' \
    "$snap" > "$TMP_ROOT/reported-window/tighter-without-length.json"
  FM_TEST_SNAP="$TMP_ROOT/reported-window/tighter-without-length.json"
  rc=0
  out=$(run_check "$home" task-w haiku) || rc=$?
  expect_code 0 "$rc" "a tighter window without length refused the launch: $out"
  assert_contains "$out" "$GAP_LINE" "the guard borrowed length from a looser window"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a tighter window without length drove pace"
  pass "pace uses the reported weekly length and missing timing skips pace"
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

test_json_skips_stale_claude_provider() {
  local home snap out rc=0
  home=$(make_home stale-json task-w engineering)
  prepare_fake stale-json grok
  link_quota "$TMP_ROOT/current-fakebin"
  snap="$TMP_ROOT/stale-json/snap.json"
  write_snap "$snap" 30 259200
  FM_TEST_SNAP="$snap"
  out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
  expect_code 0 "$rc" "a fresh JSON quota reading refused the launch: $out"
  assert_equals reroute "$(verdict_field "$home/verdict" action)" "a fresh JSON quota reading was ignored"
  assert_equals grok "$(verdict_field "$home/verdict" harness)" "a fresh JSON quota reading chose the wrong route"

  jq '.providers[0].state.stale = true' "$snap" > "$TMP_ROOT/stale-json/stale.json"
  FM_TEST_SNAP="$TMP_ROOT/stale-json/stale.json"
  rc=0
  out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale JSON quota reading refused the launch: $out"
  assert_contains "$out" "$GAP_LINE" "a stale JSON quota reading hid the missing-reading notice"
  assert_equals proceed "$(verdict_field "$home/verdict" action)" "a stale JSON quota reading drove the pace check"
  assert_equals haiku "$(verdict_field "$home/verdict" model)" "a stale JSON quota reading changed the model"
  pass "JSON fallback uses fresh Claude quota and skips stale providers"
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
  for invalid in '{"enabled":false}' '{"concurrent_claude_cap":null}' '{"opus_refused_types":[]}' '{"weekly_window_seconds":604800}'; do
    printf '%s\n' "$invalid" > "$home/config/claude-quota-guard.json"
    rc=0
    out=$(run_check "$home" task-w haiku 2>&1) || rc=$?
    expect_code 1 "$rc" "an invalid guard config was accepted: $invalid"
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
    if [ -f "${FM_FAKE_CALL_LOG%/*}/agent-window" ]; then
      cat "${FM_FAKE_CALL_LOG%/*}/agent-window"
      exit 0
    fi
    ;;
  display-message)
    if [ -f "${FM_FAKE_CALL_LOG%/*}/agent-window" ]; then
      case "$*" in *pane_current_command*) printf 'claude\n'; exit 0 ;; esac
    fi
    printf 'firstmate\n'
    exit 0
    ;;
  send-keys)
    if [ -f "${FM_FAKE_CALL_LOG%/*}/fail-before-delivery" ]; then
      case "$*" in *'export GOTMPDIR='*) exit 1 ;; esac
    fi
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
      HOME="$case_dir/user-home" CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
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
  for variant in plain joined separate continued; do
    case "$variant" in
      plain) command='claude --model opus' ;;
      joined) command='claude --model=o"pus"' ;;
      separate) command='claude --model o"pus"' ;;
      continued) command=$'claude --model=op\\\nus' ;;
    esac
    case_dir=$(make_case "raw-opus-$variant" task-w writing)
    home="$case_dir/home"
    before=$(call_count "$case_dir")
    trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
    rc=0
    out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
      "$command" --mode no-mistakes --yolo off 2>&1) || rc=$?
    expect_code 1 "$rc" "a raw Opus writing launch was allowed: $out"
    if [ "$variant" = continued ]; then
      assert_contains "$out" "raw Claude model syntax cannot be checked safely" "line continuation was not refused"
    else
      assert_contains "$out" "refused: Opus is not allowed for task type writing" "raw Opus refusal was not reached"
    fi
    assert_nothing_created "$case_dir" task-w "$before" "$trees"
    assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota')" "raw Opus refusal wrote status"
  done
  pass "raw Claude Opus model syntax refuses before launch"
}

test_spawn_leaves_compound_raw_claude_unguarded() {
  local case_dir home out rc variant command pane
  for variant in semicolon pipe ampersand newline; do
    case "$variant" in
      semicolon) command='claude --model opus; printf done' ;;
      pipe) command='claude --model opus | cat' ;;
      ampersand) command='claude --model opus && printf done' ;;
      newline) command=$'claude --model haiku\nclaude --model opus' ;;
    esac
    case_dir=$(make_case "raw-compound-$variant" task-w writing)
    home="$case_dir/home"
    pane=$(new_worktree "$case_dir" task-w)
    rc=0
    out=$(run_spawn "$case_dir" "$pane" task-w "$case_dir/sample-project" \
      "$command" --mode no-mistakes --yolo off 2>&1) || rc=$?
    expect_code 0 "$rc" "a compound raw Claude command was refused: $out"
    assert_not_contains "$out" "raw Claude model syntax cannot be checked safely" "a compound command was treated as unsafe model syntax"
    assert_not_contains "$out" "refused: Opus is not allowed for task type writing" "a compound command was guarded"
    assert_equals claude "$(awk -F= '$1=="harness"{print $2}' "$home/state/task-w.meta")" "a compound command did not launch"
  done
  pass "compound raw Claude commands launch without the quota guard"
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
  local case_dir home pane out rc=0 first_pid tries recorded_pid recorded_identity dead_pid now_epoch
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
  recorded_pid=$(awk -F= '$1=="quota_spawn_pid" {print $2}' "$home/state/task-a.meta")
  recorded_identity=$(awk -F= '$1=="quota_spawn_identity" {sub(/^[^=]*=/, ""); print}' "$home/state/task-a.meta")
  if [ -n "$recorded_pid" ] && [ -n "$recorded_identity" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    :
  else
    fail "published Claude record did not name a live spawning process"
  fi
  cp "$home/state/task-a.meta" "$case_dir/reserved.meta"
  printf '%s\n' 'quota_agent_observed=1' >> "$home/state/task-a.meta"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "second Claude worker entered while the first was published but not observable: $out"
  assert_absent "$home/state/task-b.meta" "deferred Claude worker published a record"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "published-seat deferral missed its cap line"
  : > "$case_dir/release-launch"
  wait "$first_pid" || fail "first Claude launch failed after release: $(cat "$case_dir/first.out")"
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_spawn_pid=')" "completed delivery kept its process reservation"
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_spawn_identity=')" "completed delivery kept its process identity"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "completed delivery dropped the recorded observation"
  cp "$case_dir/reserved.meta" "$home/state/task-a.meta"
  printf '%s\n' 'quota_spawn_identity=' >> "$home/state/task-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 1 "$rc" "a malformed Claude reservation did not refuse the count: $out"
  assert_absent "$home/state/task-b.meta" "malformed reservation admitted a worker"
  # The first pane read is authoritative absence. The recheck then finds the
  # session server running but cannot classify the pane, so absence stays
  # unproven without consulting this host's tmux server or process table.
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_CALL_LOG%/*}/herdr.log"
case "$*" in
  'pane get proof-pane --session proof-session')
    if [ ! -f "${FM_FAKE_CALL_LOG%/*}/herdr-pane-seen" ]; then
      : > "${FM_FAKE_CALL_LOG%/*}/herdr-pane-seen"
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    else
      printf '%s\n' '{"error":{"code":"unavailable"}}'
    fi
    ;;
  'status --json --session proof-session')
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  dead_pid=$(unused_dead_pid)
  now_epoch=$(date +%s)
  fm_write_meta "$home/state/task-a.meta" \
    harness=claude kind=ship backend=herdr \
    window=proof-session:proof-pane \
    worktree="$pane" \
    spawn_gen="s${now_epoch}.1.1" \
    quota_spawn_pid="$dead_pid" \
    quota_spawn_identity=exited-spawn
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an exited reservation with an unproven endpoint freed its seat: $out"
  assert_absent "$home/state/task-b.meta" "unproven endpoint allowed a second Claude record"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "unproven endpoint duplicated the cap line"
  assert_equals 2 "$(grep -c -F 'pane get proof-pane --session proof-session' "$case_dir/herdr.log")" \
    "the unproven endpoint did not recheck pane absence"
  pass "a live spawn holds its seat and an exited reservation without absence proof keeps it"
}

test_spawn_keeps_unverified_reserved_seat() {
  local case_dir home out rc=0 before trees dead_pid
  case_dir=$(make_case unverified-seat task-b engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  dead_pid=$(unused_dead_pid)
  fm_write_meta "$home/state/task-a.meta" \
    harness=claude kind=ship backend=cmux \
    window=cmux:surface-a \
    cmux_workspace_id=ws-a cmux_surface_id=surface-a \
    quota_spawn_pid="$dead_pid" \
    quota_spawn_identity=exited-spawn
  FM_TEST_SNAP="$case_dir/snap.json"
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unverified reserved Claude seat admitted another worker: $out"
  assert_nothing_created "$case_dir" task-b "$before" "$trees"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "unverified seat missed its cap line"
  assert_equals 0 "$(key_count "$home/state/task-b.status" 'claude-quota-pace')" "unverified seat wrote a pace line"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an unverified reserved seat admitted a retry: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "unverified seat retry wrote another cap line"
  pass "an unverified reserved Claude seat keeps the cap full"
}

test_spawn_keeps_early_dead_seat_until_startup_grace() {
  local case_dir home pane out rc=0 before trees old_epoch
  case_dir=$(make_case early-dead-seat task-a engineering)
  home="$case_dir/home"
  write_brief "$home" task-b engineering
  add_item "$home" task-b
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  pane=$(new_worktree "$case_dir" task-a)
  out=$(run_spawn "$case_dir" "$pane" task-a "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "first Claude launch failed: $out"
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_spawn_pid=')" "completed launch kept its process reservation"
  awk -F= '$1 == "window" { print "window=test-session:sample-pane"; next } { print }' \
    "$home/state/task-a.meta" > "$case_dir/task-a.meta"
  printf '%s\n' 'backend=herdr' >> "$case_dir/task-a.meta"
  mv "$case_dir/task-a.meta" "$home/state/task-a.meta"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pane get sample-pane --session test-session') printf '%s\n' '{"result":{"pane":{"pane_id":"sample-pane"}}}' ;;
  'agent get sample-pane --session test-session') printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  pane=$(new_worktree "$case_dir" task-b)
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an early dead read freed the first Claude seat: $out"
  assert_nothing_created "$case_dir" task-b "$before" "$trees"
  old_epoch=$(( $(date +%s) - 120 ))
  awk -F= -v gen="s$old_epoch.1.1" '$1 == "spawn_gen" { print "spawn_gen=" gen; next } { print }' \
    "$home/state/task-a.meta" > "$case_dir/task-a.meta"
  mv "$case_dir/task-a.meta" "$home/state/task-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a still-dead endpoint held its seat after startup grace: $out"
  assert_present "$home/state/task-b.meta" "the expired dead seat did not admit the second worker"
  pass "an early dead endpoint keeps its seat until startup grace expires"
}

test_spawn_rechecked_dead_seat_uses_startup_grace() {
  local case_dir home pane out rc=0 before trees now_epoch old_epoch
  case_dir=$(make_case rechecked-dead-seat task-b engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  now_epoch=$(date +%s)
  fm_write_meta "$home/state/task-a.meta" \
    harness=claude kind=ship backend=herdr \
    window=test-session:proof-pane worktree="$case_dir/wt-a" \
    spawn_gen="s${now_epoch}.1.1"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pane get proof-pane --session test-session')
    if [ -f "${FM_FAKE_CALL_LOG%/*}/server-started" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"proof-pane"}}}'
    else
      printf '%s\n' '{"error":{"code":"unavailable"}}'
    fi
    ;;
  'status --json --session test-session')
    if [ -f "${FM_FAKE_CALL_LOG%/*}/server-started" ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  'server --session test-session') : > "${FM_FAKE_CALL_LOG%/*}/server-started" ;;
  'agent get proof-pane --session test-session') printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  pane=$(new_worktree "$case_dir" task-b)
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a rechecked dead endpoint freed its seat during startup grace: $out"
  assert_present "$case_dir/server-started" "the missing endpoint was not rechecked with its server running"
  assert_nothing_created "$case_dir" task-b "$before" "$trees"

  old_epoch=$(( $(date +%s) - 120 ))
  awk -F= -v gen="s$old_epoch.1.1" '$1 == "spawn_gen" { print "spawn_gen=" gen; next } { print }' \
    "$home/state/task-a.meta" > "$case_dir/task-a.meta"
  mv "$case_dir/task-a.meta" "$home/state/task-a.meta"
  rm -f "$case_dir/server-started"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a rechecked dead endpoint kept its seat after startup grace: $out"
  assert_present "$home/state/task-b.meta" "the expired rechecked dead seat did not admit the second worker"
  pass "a rechecked dead endpoint keeps its seat only during startup grace"
}

test_spawn_rechecked_alive_records_observation() {
  local case_dir home pane out rc=0 before trees now_epoch dead_pid
  case_dir=$(make_case rechecked-alive-seat task-b engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  now_epoch=$(date +%s)
  dead_pid=$(unused_dead_pid)
  fm_write_meta "$home/state/task-a.meta" \
    harness=claude kind=ship backend=herdr \
    window=test-session:proof-pane worktree="$case_dir/wt-a" \
    spawn_gen="s${now_epoch}.1.1" \
    quota_spawn_pid="$dead_pid" quota_spawn_identity=exited-spawn
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pane get proof-pane --session test-session')
    if [ -f "${FM_FAKE_CALL_LOG%/*}/server-started" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"proof-pane"}}}'
    else
      printf '%s\n' '{"error":{"code":"unavailable"}}'
    fi
    ;;
  'status --json --session test-session')
    if [ -f "${FM_FAKE_CALL_LOG%/*}/server-started" ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  'server --session test-session') : > "${FM_FAKE_CALL_LOG%/*}/server-started" ;;
  'agent get proof-pane --session test-session')
    if [ -f "${FM_FAKE_CALL_LOG%/*}/agent-stopped" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    else
      printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}'
    fi
    ;;
  'pane process-info --pane proof-pane --session test-session')
    printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"proof-pane","shell_pid":123,"foreground_processes":[{"pid":456,"name":"claude","argv0":"claude","argv":["claude"],"cmdline":"claude"}]}}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  pane=$(new_worktree "$case_dir" task-b)
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a rechecked live agent did not hold its seat: $out"
  assert_present "$case_dir/server-started" "the missing endpoint was not rechecked with its server running"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "rechecked live agent was not recorded"
  assert_nothing_created "$case_dir" task-b "$before" "$trees"

  : > "$case_dir/agent-stopped"
  rm -f "$case_dir/server-started"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an observed dead endpoint kept its seat during startup grace: $out"
  assert_present "$home/state/task-b.meta" "the observed dead seat did not admit the next worker"
  pass "a rechecked live agent is observed and releases its seat when dead"
}

test_spawn_reads_quota_for_selected_claude_account() {
  local case_dir home pane out rc=0 calls
  case_dir=$(make_case account-quota task-a engineering)
  home="$case_dir/home"
  mkdir -p "$case_dir/profile-a" "$case_dir/profile-b"
  fake_tool "$case_dir/fakebin" grok
  cat > "$case_dir/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'auth status' ]
SH
  cat > "$case_dir/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
profile=${CLAUDE_CONFIG_DIR-__unset__}
printf '%s|%s\n' "$profile" "$*" >> "${FM_FAKE_CALL_LOG%/*}/quota-calls"
reset=$(cat "${FM_FAKE_CALL_LOG%/*}/reset")
if [ "$profile" = "${FM_FAKE_CALL_LOG%/*}/profile-b" ]; then
  remaining=30
else
  remaining=95
fi
case "$*" in
  *--json*)
    printf '{"providers":[{"provider":"claude","state":{"stale":false},"windows":[{"id":"seven_day","kind":"weekly","percentRemaining":%s,"resetsAt":"%s","windowSeconds":604800}]}]}\n' "$remaining" "$reset"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/claude" "$case_dir/fakebin/quota-axi"
  write_snap "$case_dir/snap.json" 30 259200
  jq -r '.providers[0].windows[] | select(.id == "seven_day") | .resetsAt' "$case_dir/snap.json" > "$case_dir/reset"
  printf '%s\n' "$case_dir/profile-b" > "$home/config/claude-account"
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/profile-a"
  pane=$(new_worktree "$case_dir" task-a)
  out=$(run_spawn "$case_dir" "$pane" task-a "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a pinned hot account did not route: $out"
  assert_equals grok "$(verdict_field "$home/state/task-a.meta" harness)" "the guard read the ambient account instead of the pin"
  calls=$(cat "$case_dir/quota-calls")
  assert_contains "$calls" "$case_dir/profile-b|--provider claude --profile-only --json --no-credential-refresh" "the JSON read did not select the pinned profile"
  assert_not_contains "$calls" "$case_dir/profile-a|" "the pinned launch read the ambient profile"

  printf '%s\n' ordinary > "$home/config/claude-account"
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/profile-b"
  write_brief "$home" task-b engineering
  add_item "$home" task-b
  pane=$(new_worktree "$case_dir" task-b)
  : > "$case_dir/quota-calls"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an ordinary pin did not use the default account: $out"
  assert_equals claude "$(verdict_field "$home/state/task-b.meta" harness)" "the ordinary pin read the hot ambient profile"
  calls=$(cat "$case_dir/quota-calls")
  assert_contains "$calls" '__unset__|--provider claude --json --no-credential-refresh' "the ordinary pin did not select the default profile"
  assert_not_contains "$calls" '--profile-only' "the ordinary pin asked for a profile without a directory"
  assert_not_contains "$calls" "$case_dir/profile-b|" "the ordinary pin read the ambient profile"

  rm -f "$home/config/claude-account"
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/profile-a"
  write_brief "$home" task-c engineering
  add_item "$home" task-c
  pane=$(new_worktree "$case_dir" task-c)
  : > "$case_dir/quota-calls"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-c "$case_dir/sample-project" \
    --harness "CLAUDE_CONFIG_DIR=$case_dir/profile-b claude --model haiku" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a raw Claude profile override did not route: $out"
  assert_equals grok "$(verdict_field "$home/state/task-c.meta" harness)" "the raw Claude launch read the ambient profile"
  calls=$(cat "$case_dir/quota-calls")
  assert_contains "$calls" "$case_dir/profile-b|--provider claude --profile-only --json --no-credential-refresh" "the raw assignment did not select its profile"
  assert_not_contains "$calls" "$case_dir/profile-a|" "the raw launch read the ambient profile"

  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/profile-b"
  write_brief "$home" task-d engineering
  add_item "$home" task-d
  pane=$(new_worktree "$case_dir" task-d)
  : > "$case_dir/quota-calls"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-d "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an unpinned ambient Claude account did not route: $out"
  assert_equals grok "$(verdict_field "$home/state/task-d.meta" harness)" "the unpinned launch did not use its forwarded profile"
  assert_contains "$(cat "$case_dir/quota-calls")" "$case_dir/profile-b|--provider claude --profile-only --json --no-credential-refresh" "the unpinned launch did not select its ambient profile"

  FM_TEST_CLAUDE_CONFIG_DIR=
  write_brief "$home" task-e engineering
  add_item "$home" task-e
  pane=$(new_worktree "$case_dir" task-e)
  : > "$case_dir/quota-calls"
  rc=0
  out=$(run_spawn "$case_dir" "$pane" task-e "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "an unpinned default Claude account did not launch: $out"
  assert_equals claude "$(verdict_field "$home/state/task-e.meta" harness)" "an unpinned default account was rerouted"
  assert_contains "$(cat "$case_dir/quota-calls")" '|--provider claude --json --no-credential-refresh' "the default account did not keep its quota source"
  pass "quota pace follows pinned, raw, and unpinned Claude accounts"
}

test_spawn_pinned_raw_override_refuses_before_reroute() {
  local case_dir home assignment id out rc before trees
  case_dir=$(make_case pinned-raw-override task-a engineering)
  home="$case_dir/home"
  mkdir -p "$case_dir/profile-b" "$case_dir/other"
  printf '%s\n' "$case_dir/profile-b" > "$home/config/claude-account"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  write_snap "$case_dir/snap.json" 30 259200
  FM_TEST_SNAP="$case_dir/snap.json"
  for assignment in "CLAUDE_CONFIG_DIR=$case_dir/other" 'ANTHROPIC_API_KEY=override'; do
    id=task-a
    [ "$assignment" != 'ANTHROPIC_API_KEY=override' ] || id=task-b
    if [ "$id" = task-b ]; then
      write_brief "$home" "$id" engineering
      add_item "$home" "$id"
    fi
    before=$(call_count "$case_dir")
    trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
    rc=0
    out=$(run_spawn "$case_dir" "$case_dir/unused" "$id" "$case_dir/sample-project" \
      --harness "$assignment claude --model haiku" --mode no-mistakes --yolo off 2>&1) || rc=$?
    expect_code 1 "$rc" "a pinned raw override was rerouted: $out"
    assert_contains "$out" "the raw launch command sets ${assignment%%=*}" "the pin refusal was not reported"
    assert_nothing_created "$case_dir" "$id" "$before" "$trees"
    assert_equals 0 "$(key_count "$home/state/$id.status" 'claude-quota-pace')" "a refused override wrote a pace line"
  done
  pass "pinned raw Claude overrides refuse before quota rerouting"
}

test_spawn_malformed_dispatch_refuses() {
  local case_dir home out rc=0 before trees
  case_dir=$(make_case malformed-dispatch task-w engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  fake_tool "$case_dir/fakebin" grok
  fake_tool "$case_dir/fakebin" muse
  write_snap "$case_dir/snap.json" 30 259200
  printf '%s\n' 'not-a-dispatch-file' > "$home/config/crew-dispatch.json"
  FM_TEST_SNAP="$case_dir/snap.json"
  before=$(call_count "$case_dir")
  trees=$(git -C "$case_dir/sample-project" worktree list --porcelain)
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 1 "$rc" "a malformed dispatch file deferred the launch: $out"
  assert_contains "$out" 'config/crew-dispatch.json is malformed' "the malformed dispatch file was not named"
  assert_not_contains "$out" 'not-a-dispatch-file' "the malformed dispatch file contents were printed"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-route')" "a malformed dispatch file wrote the route line"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-pace')" "a malformed dispatch file wrote a pace line"

  printf '%s\n' '{"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-w "$case_dir/sample-project" \
    --harness claude --model opus --effort high \
    --dispatch-rule '{"rule":"rule_9"}' --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 1 "$rc" "an unreadable dispatch rule deferred the launch: $out"
  assert_contains "$out" 'config/crew-dispatch.json: selected dispatch rule is unavailable' "the unavailable rule was not named"
  assert_not_contains "$out" 'rule_9' "the unavailable rule contents were printed"
  assert_nothing_created "$case_dir" task-w "$before" "$trees"
  assert_equals 0 "$(key_count "$home/state/task-w.status" 'claude-quota-route')" "an unavailable rule wrote the route line"
  pass "a malformed dispatch file refuses the launch without a route deferral"
}

test_failed_claude_spawn_keeps_task_lock_through_rollback() {
  local case_dir home pane real_rm spawn_pid tries teardown_out teardown_rc=0 spawn_rc=0
  case_dir=$(make_case abort-rollback-lock task-a engineering)
  home="$case_dir/home"
  link_quota "$case_dir/fakebin"
  write_snap "$case_dir/snap.json" 95 259200
  printf '%s\n' '{"concurrent_claude_cap":1}' > "$home/config/claude-quota-guard.json"
  pane=$(new_worktree "$case_dir" task-a)
  real_rm=$(command -v rm)
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg; do
  if [ "$arg" = "${FM_TEST_ROLLBACK_META:-}" ]; then
    : > "$FM_TEST_ROLLBACK_PAUSED"
    for ((attempt=0; attempt<300; attempt++)); do
      [ ! -f "$FM_TEST_ROLLBACK_RELEASE" ] || break
      sleep 0.05
    done
    [ -f "$FM_TEST_ROLLBACK_RELEASE" ] || exit 1
  fi
done
SH
  printf 'exec %q "$@"\n' "$real_rm" >> "$case_dir/fakebin/rm"
  chmod +x "$case_dir/fakebin/rm"
  : > "$case_dir/fail-before-delivery"
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_TEST_ROLLBACK_META="$home/state/task-a.meta" \
    FM_TEST_ROLLBACK_PAUSED="$case_dir/rollback-paused" \
    FM_TEST_ROLLBACK_RELEASE="$case_dir/release-rollback" \
    run_spawn "$case_dir" "$pane" task-a "$case_dir/sample-project" \
      --harness claude --model haiku --mode no-mistakes --yolo off > "$case_dir/spawn.out" 2>&1 &
  spawn_pid=$!
  for ((tries=0; tries<300; tries++)); do
    [ ! -f "$case_dir/rollback-paused" ] || break
    sleep 0.05
  done
  [ -f "$case_dir/rollback-paused" ] || fail "failed Claude spawn did not reach record rollback: $(cat "$case_dir/spawn.out")"
  assert_present "$home/state/task-a.meta" "failed Claude spawn lost its provisional record before rollback"
  teardown_out=$(HOME="$home/user-home" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-a 2>&1) || teardown_rc=$?
  [ "$teardown_rc" -ne 0 ] || fail "teardown accepted a provisional Claude record during rollback"
  assert_contains "$teardown_out" 'teardown refused while a spawn of task-a is in progress' \
    "teardown did not refuse the active spawn: $teardown_out"
  assert_present "$home/state/task-a.meta" "teardown removed the provisional Claude record during rollback"
  : > "$case_dir/release-rollback"
  wait "$spawn_pid" || spawn_rc=$?
  [ "$spawn_rc" -ne 0 ] || fail "the failed Claude launch reported success"
  assert_absent "$home/state/task-a.meta" "failed Claude spawn retained its provisional record after rollback"
  assert_absent "$home/state/.spawn-task-a.lock" "failed Claude spawn kept its task lock after rollback"
  pass "failed Claude spawn blocks teardown until provisional rollback completes"
}

test_spawn_records_live_agent_before_process_seat() {
  local case_dir home pane out rc=0 first_pid recorded_pid tries window rooted_pid
  case_dir=$(make_case live-observed-seat task-a engineering)
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
  [ -f "$case_dir/launch-paused" ] || fail "first Claude launch did not pause after publication: $(cat "$case_dir/first.out")"
  recorded_pid=$(awk -F= '$1=="quota_spawn_pid" {print $2}' "$home/state/task-a.meta")
  if [ -n "$recorded_pid" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    :
  else
    fail "published Claude record did not name a live spawning process"
  fi
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=')" "agent was observed before the competing launch"
  window=$(awk -F= '$1=="window" {print $2}' "$home/state/task-a.meta")
  printf '%s\n' "${window#*:}" > "$case_dir/agent-window"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "live Claude agent did not keep its seat: $out"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "live-agent count did not persist observation"
  assert_absent "$home/state/task-b.meta" "observed live agent allowed a second Claude record"
  rm "$case_dir/agent-window"
  kill -KILL "$recorded_pid" 2>/dev/null || fail "could not interrupt the first Claude spawn"
  : > "$case_dir/release-launch"
  wait "$first_pid" 2>/dev/null || true
  (cd "$pane" && exec sleep 30) &
  rooted_pid=$!
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  kill "$rooted_pid" 2>/dev/null || true
  wait "$rooted_pid" 2>/dev/null || true
  expect_code "$DEFER_EXIT" "$rc" "an observed agent lost its seat after spawn exit: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "missing endpoint duplicated the cap line"
  assert_absent "$home/state/task-b.meta" "unreachable agent allowed a second Claude record"
  pass "a live agent is recorded before the process seat and keeps it after interruption"
}

test_spawn_observation_preserves_pr_identity() {
  local case_dir home pane out rc=0 first_pid recorded_pid tries window order pr_url pr_head
  case_dir=$(make_case pr-observed-seat task-a engineering)
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
  [ -f "$case_dir/launch-paused" ] || fail "first Claude launch did not pause after publication: $(cat "$case_dir/first.out")"
  recorded_pid=$(awk -F= '$1=="quota_spawn_pid" {print $2}' "$home/state/task-a.meta")
  if [ -n "$recorded_pid" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    :
  else
    fail "published Claude record did not name a live spawning process"
  fi
  kill -KILL "$recorded_pid" 2>/dev/null || fail "could not interrupt the first Claude spawn"
  : > "$case_dir/release-launch"
  wait "$first_pid" 2>/dev/null || true
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=')" "agent was observed before the competing launch"
  pr_url=https://github.com/example/repo/pull/9
  pr_head=0123456789abcdef0123456789abcdef01234567
  printf 'pr=%s\npr_head=%s\n' "$pr_url" "$pr_head" >> "$home/state/task-a.meta"
  window=$(awk -F= '$1=="window" {print $2}' "$home/state/task-a.meta")
  printf '%s\n' "${window#*:}" > "$case_dir/agent-window"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a PR worker lost its Claude seat: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "PR worker deferral missed its cap line"
  assert_absent "$home/state/task-b.meta" "PR worker allowed a second Claude record"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "guard did not persist the PR worker observation"
  order=$(awk -F= '$1 == "pr" { print previous == "quota_agent_observed=1" ? 1 : 0; exit } { previous=$0 }' "$home/state/task-a.meta")
  assert_equals 1 "$order" "observation did not precede the PR identity"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_metadata_identity_parse "$home/state/task-a.meta" || fail "PR parser rejected the observed task record"
  assert_equals "$pr_url" "$FM_PR_META_URL" "observation changed the PR identity"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" "pr_head=$pr_head")" "observation changed the PR head"
  pass "an observed Claude PR worker keeps its seat and PR identity"
}

test_guard_observation_keeps_interleaved_pr_identity() {
  local case_dir home pane first_pid recorded_pid tries window meta_lock before calls guard_pid rc pr_url pr_head order
  case_dir=$(make_case interleaved-pr-observation task-a engineering)
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
  [ -f "$case_dir/launch-paused" ] || fail "first Claude launch did not pause after publication: $(cat "$case_dir/first.out")"
  recorded_pid=$(awk -F= '$1=="quota_spawn_pid" {print $2}' "$home/state/task-a.meta")
  if [ -n "$recorded_pid" ] && kill -0 "$recorded_pid" 2>/dev/null; then
    :
  else
    fail "published Claude record did not name a live spawning process"
  fi
  kill -KILL "$recorded_pid" 2>/dev/null || fail "could not interrupt the first Claude spawn"
  : > "$case_dir/release-launch"
  wait "$first_pid" 2>/dev/null || true
  window=$(awk -F= '$1=="window" {print $2}' "$home/state/task-a.meta")
  printf '%s\n' "${window#*:}" > "$case_dir/agent-window"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  meta_lock=$(fm_meta_lock_path "$home/state/task-a.meta") || fail "could not locate the task record lock"
  fm_lock_acquire_wait "$meta_lock" || fail "could not hold the task record lock"
  before=$(grep -c '^list-windows ' "$case_dir/calls.log" || true)
  (
    rc=0
    run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
      --harness claude --model haiku --mode no-mistakes --yolo off > "$case_dir/second.out" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$case_dir/second.rc"
  ) &
  guard_pid=$!
  for ((tries=0; tries<300; tries++)); do
    calls=$(grep -c '^list-windows ' "$case_dir/calls.log" || true)
    [ "$calls" -le "$before" ] || break
    [ ! -f "$case_dir/second.rc" ] || break
    sleep 0.05
  done
  calls=$(grep -c '^list-windows ' "$case_dir/calls.log" || true)
  [ "$calls" -gt "$before" ] && [ -d "$home/state/.claude-quota-guard.lock" ] ||
    fail "guard did not reach the agent observation while the record was locked: $(cat "$case_dir/second.out")"
  assert_equals 0 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=')" "guard wrote without the task record lock"
  pr_url=https://github.com/example/repo/pull/10
  pr_head=0123456789abcdef0123456789abcdef01234567
  cp "$home/state/task-a.meta" "$home/state/.task-a.pr.tmp"
  printf 'pr=%s\npr_head=%s\n' "$pr_url" "$pr_head" >> "$home/state/.task-a.pr.tmp"
  mv -f "$home/state/.task-a.pr.tmp" "$home/state/task-a.meta"
  fm_lock_release "$meta_lock" || fail "could not release the task record lock"
  wait "$guard_pid" || fail "competing spawn did not finish"
  rc=$(cat "$case_dir/second.rc")
  expect_code "$DEFER_EXIT" "$rc" "a PR worker lost its Claude seat: $(cat "$case_dir/second.out")"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "PR worker deferral missed its cap line"
  assert_absent "$home/state/task-b.meta" "PR worker allowed a second Claude record"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "guard did not persist the observation"
  order=$(awk -F= '$1 == "pr" { print previous == "quota_agent_observed=1" ? 1 : 0; exit } { previous=$0 }' "$home/state/task-a.meta")
  assert_equals 1 "$order" "observation did not precede the interleaved PR identity"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_metadata_identity_parse "$home/state/task-a.meta" || fail "PR parser rejected the observed task record"
  assert_equals "$pr_url" "$FM_PR_META_URL" "observation changed the PR identity"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" "pr_head=$pr_head")" "observation changed the PR head"
  pass "guard observation retains an intervening PR identity"
}

test_spawn_observed_agent_keeps_seat_when_endpoint_goes_missing() {
  local case_dir home pane out rc=0 first_pid rooted_pid tries window
  case_dir=$(make_case observed-seat task-a engineering)
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
  [ -f "$case_dir/launch-paused" ] || fail "first Claude launch did not publish before delivery: $(cat "$case_dir/first.out")"
  assert_present "$home/state/task-a.meta" "first launch had no published record"
  cp "$home/state/task-a.meta" "$case_dir/reserved.meta"
  assert_equals 0 "$(key_count "$case_dir/reserved.meta" 'quota_agent_observed=')" "observation preceded the guard"
  : > "$case_dir/release-launch"
  wait "$first_pid" || fail "first Claude launch failed after release: $(cat "$case_dir/first.out")"
  cp "$case_dir/reserved.meta" "$home/state/task-a.meta"
  window=$(awk -F= '$1=="window" {print $2}' "$home/state/task-a.meta")
  printf '%s\n' "${window#*:}" > "$case_dir/agent-window"
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an observed Claude agent lost its seat: $out"
  assert_equals 1 "$(key_count "$home/state/task-a.meta" 'quota_agent_observed=1')" "guard did not persist agent observation"
  assert_absent "$home/state/task-b.meta" "observed agent allowed a second Claude record"
  rm "$case_dir/agent-window"
  (cd "$pane" && exec sleep 30) &
  rooted_pid=$!
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  kill "$rooted_pid" 2>/dev/null || true
  wait "$rooted_pid" 2>/dev/null || true
  expect_code "$DEFER_EXIT" "$rc" "an unreachable observed agent lost its seat: $out"
  assert_equals 1 "$(canonical_count "$home/state/task-b.status" "$CAP_LINE")" "missing endpoint duplicated the cap line"
  assert_absent "$home/state/task-b.meta" "unreachable agent allowed a second Claude record"
  awk '$0 == "quota_agent_observed=1" { print "quota_agent_observed=2"; next } { print }' \
    "$home/state/task-a.meta" > "$case_dir/malformed.meta"
  mv "$case_dir/malformed.meta" "$home/state/task-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$case_dir/unused" task-b "$case_dir/sample-project" \
    --harness claude --model haiku --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 1 "$rc" "a malformed observation was accepted: $out"
  assert_absent "$home/state/task-b.meta" "malformed observation allowed a second Claude record"
  pass "an observed Claude agent keeps its seat across an unproven missing endpoint"
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
  FM_CQG_TRIED=$(jq -cn '[{harness:"claude",model:"sonnet",effort:"high",reasoning_class:"strong/approved"}]')
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

test_spawn_raw_sonnet_reroute_keeps_credential_dir() {
  local case_dir home pane out rc=0 calls
  case_dir=$(make_case raw-sonnet-profile task-s engineering)
  home="$case_dir/home"
  mkdir -p "$case_dir/profile-a" "$case_dir/profile-b"
  link_quota "$case_dir/fakebin"
  mv "$case_dir/fakebin/quota-axi" "$case_dir/fakebin/quota-axi-real"
  cat > "$case_dir/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CONFIG_DIR-__unset__}" >> "${FM_FAKE_CALL_LOG%/*}/quota-profiles"
exec "${BASH_SOURCE[0]}-real" "$@"
SH
  chmod +x "$case_dir/fakebin/quota-axi"
  write_snap "$case_dir/snap.json" 30 259200
  FM_TEST_SNAP="$case_dir/snap.json"
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/profile-a"
  pane=$(new_worktree "$case_dir" task-s)
  out=$(run_spawn "$case_dir" "$pane" task-s "$case_dir/sample-project" \
    --harness "CLAUDE_CONFIG_DIR=$case_dir/profile-b claude --model haiku" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a raw Claude Sonnet fallback did not launch: $out"
  assert_equals sonnet "$(verdict_field "$home/state/task-s.meta" model)" "the raw launch did not reroute to Sonnet"
  assert_equals "$case_dir/profile-b" "$(cat "$case_dir/quota-profiles")" "the pace check read the wrong profile"
  calls=$(cat "$case_dir/calls.log")
  assert_contains "$calls" "CLAUDE_CONFIG_DIR='$case_dir/profile-a' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CONFIG_DIR='$case_dir/profile-b' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" "the Sonnet launch dropped the checked profile"
  pass "raw Claude Sonnet reroutes keep the checked credential directory"
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
test_reported_weekly_window_controls_pace
test_pace_prefers_grok_then_muse_then_sonnet
test_opus_refused_for_writing_and_allowed_when_cleared
test_missing_quota_proceeds_and_still_checks_opus_and_cap
test_json_skips_stale_claude_provider
test_status_line_is_written_once
test_cap_counts_pr_workers_and_ignores_secondmates
test_bad_config_and_unreadable_record_refuse
test_selected_opus_rule_defers_without_alternate
test_refusal_only_relaunch_model
test_valid_margin_keeps_allowed_model
test_spawn_refuses_opus_for_writing
test_spawn_refuses_raw_opus_for_writing
test_spawn_leaves_compound_raw_claude_unguarded
test_spawn_selected_opus_rule_defers
test_spawn_keeps_published_claude_seat_during_delivery
test_spawn_keeps_unverified_reserved_seat
test_spawn_keeps_early_dead_seat_until_startup_grace
test_spawn_rechecked_dead_seat_uses_startup_grace
test_spawn_rechecked_alive_records_observation
test_spawn_reads_quota_for_selected_claude_account
test_spawn_pinned_raw_override_refuses_before_reroute
test_spawn_malformed_dispatch_refuses
test_failed_claude_spawn_keeps_task_lock_through_rollback
test_spawn_records_live_agent_before_process_seat
test_spawn_observation_preserves_pr_identity
test_guard_observation_keeps_interleaved_pr_identity
test_spawn_observed_agent_keeps_seat_when_endpoint_goes_missing
test_spawn_reroute_keeps_inferred_dispatch_rule
test_spawn_omitted_model_infers_dispatch_rule
test_spawn_scheduled_reroute_skips_tried_profile
test_spawn_scheduled_plan_routes_only_listed_profiles
test_spawn_reroutes_hot_window
test_spawn_sonnet_and_cap
test_spawn_raw_sonnet_reroute_keeps_credential_dir
test_spawn_missing_quota_proceeds_and_allowed_opus
test_spawn_ignores_non_claude
