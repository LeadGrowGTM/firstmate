#!/usr/bin/env bash
# Public scheduled-worker intake with only the spawn and control owners stubbed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-scheduled-worker)
WRAPPER=$ROOT/bin/fm-scheduled-worker.sh

make_case() {
  local name=$1 dir=$TMP_ROOT/$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/project"
  chmod 700 "$dir/home/state"
  cp "$ROOT/bin/fm-scheduled-worker.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-control-lib.sh" "$ROOT/bin/fm-path-lib.sh" \
    "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-backend.sh" "$dir/bin/"
  cat > "$dir/bin/fm-spawn.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'spawn %s\n' "$*" >> "$FM_HOME/calls"
mode=$(cat "$FM_HOME/result")
case "$mode" in
  missing) exit 1 ;;
  capacity) outcome=capacity; code=75 ;;
  unavailable) outcome=worker-unavailable; code=1 ;;
  unsafe) outcome=unsafe-refusal; code=1 ;;
  uncertain) outcome=uncertain; code=1 ;;
  published) outcome=worker-published; code=0 ;;
esac
if [ "$outcome" = worker-published ]; then
  printf 'spawn_gen=gen-1\nbackend=tmux\nmode=direct-PR\nyolo=off\nproject=%s\n' "$2" > "$FM_HOME/state/$1.meta"
fi
jq -n --arg task "$1" --arg outcome "$outcome" --argjson code "$code" \
  '{version:1,task:$task,outcome:$outcome,exit_code:$code,spawn_gen:"gen-1",reason:"fixture"}' \
  > "$FM_SPAWN_OUTCOME_FILE"
exit "$code"
STUB
  cat > "$dir/bin/fm-control.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'control %s\n' "$*" >> "$FM_HOME/calls"
[ "$2" = relaunch ] || exit 2
case " $* " in *' --note-file '*) : ;; *) exit 2 ;; esac
id=$1
note=${!#}
expected=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --expected-spawn-gen ]; then
    expected=${2:-}
    break
  fi
  shift
done
[ "$expected" = gen-1 ] || exit 2
[ -f "$note" ] && [ "$(cat "$note")" = checkpoint ] || exit 2
if [ -f "$FM_HOME/race-generation" ]; then
  printf 'spawn_gen=gen-2\nbackend=tmux\nmode=direct-PR\nyolo=off\nproject=%s\n' "$(cat "$FM_HOME/project")" > "$FM_HOME/state/$id.meta"
fi
current=$(sed -n 's/^spawn_gen=//p' "$FM_HOME/state/$id.meta")
if [ "$current" != "$expected" ]; then
  printf 'control-refused %s\n' "$current" >> "$FM_HOME/calls"
  jq -n --arg task "$id" '{version:1,task:$task,outcome:"unsafe-refusal",exit_code:1,reason:"generation-changed",launch_sent:false}' > "$FM_SPAWN_OUTCOME_FILE"
  exit 1
fi
printf 'relaunch\n' >> "$FM_HOME/control-relaunches"
printf 'spawn_gen=gen-2\nbackend=tmux\nmode=direct-PR\nyolo=off\nproject=%s\n' "$(cat "$FM_HOME/project")" > "$FM_HOME/state/$id.meta"
jq -n --arg task "$id" '{version:1,task:$task,outcome:"live-worker",exit_code:0,spawn_gen:"gen-2"}' > "$FM_SPAWN_OUTCOME_FILE"
STUB
  chmod +x "$dir/bin/fm-spawn.sh" "$dir/bin/fm-control.sh"
  printf '%s\n' published > "$dir/home/result"
  printf '%s\n' "$dir/project" > "$dir/home/project"
  jq -n --arg project "$dir/project" '{version:1,authorized:true,occurrence:"occ",task:"job",project:$project,backend:"tmux",mode:"direct-PR",yolo:"off",reasoning_class:"standard",profiles:[{harness:"codex",model:"gpt-6-sol",effort:"medium",reasoning_class:"standard"},{harness:"grok",model:"grok-4.7",effort:"medium",reasoning_class:"standard"}]}' > "$dir/plan.json"
  selection "$dir" codex
  printf '%s\n' "$dir"
}

selection() {
  local dir=$1 harness=$2 at=${3:-$(date +%s)}
  jq -n --arg harness "$harness" --argjson at "$at" '{profile:(if $harness == "codex" then {harness:"codex",model:"gpt-6-sol",effort:"medium",reasoning_class:"standard"} else {harness:"grok",model:"grok-4.7",effort:"medium",reasoning_class:"standard"} end),observed_at:$at,evidence:"catalog, auth, quota, runway and spendPriority checked for both candidates"}' > "$dir/selection.json"
}
run_case() {
  local dir=$1; shift
  FM_HOME="$dir/home" "$dir/bin/fm-scheduled-worker.sh" "$dir/plan.json" "$dir/selection.json" "$@" 2>&1
}
phase() { jq -r .phase "$1/home/state/scheduled-worker/occ/journal.json"; }
count_calls() { if [ -f "$1/home/calls" ]; then wc -l < "$1/home/calls"; else printf '0\n'; fi; }

check_authorization_and_selection() {
  local dir out rc
  dir=$(make_case authorization)
  jq '.authorized=false' "$dir/plan.json" > "$dir/other.json"; mv "$dir/other.json" "$dir/plan.json"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'authorization off'; assert_equals 0 "$(count_calls "$dir")" 'authorization off reached owner'
  jq 'del(.authorized)' "$dir/plan.json" > "$dir/other.json"; mv "$dir/other.json" "$dir/plan.json"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'missing authorization'; assert_equals 0 "$(count_calls "$dir")" 'missing authorization reached owner'
  jq '.authorized=true | .profiles[1].reasoning_class="strong"' "$dir/plan.json" > "$dir/other.json"; mv "$dir/other.json" "$dir/plan.json"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'class mismatch'; assert_equals 0 "$(count_calls "$dir")" 'class mismatch reached owner'
  jq '.profiles[1].reasoning_class="standard"' "$dir/plan.json" > "$dir/other.json"; mv "$dir/other.json" "$dir/plan.json"
  jq '.profile.model="unapproved"' "$dir/selection.json" > "$dir/other.json"; mv "$dir/other.json" "$dir/selection.json"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'unapproved profile'; assert_equals 0 "$(count_calls "$dir")" 'unapproved profile reached owner'
  selection "$dir" codex
  out=$(run_case "$dir"); rc=$?
  expect_code 0 "$rc" "authorized one-profile spawn: $out"; assert_equals 1 "$(count_calls "$dir")" 'more than one owner call'
  assert_grep 'spawn job ' "$dir/home/calls" 'spawn was not called'
  assert_no_grep 'grok' "$dir/home/calls" 'unselected profile reached owner'
  assert_equals worker-published "$(phase "$dir")" 'published phase'
  out=$(run_case "$dir"); rc=$?
  expect_code 0 "$rc" 'published replay'; assert_contains "$out" already-published 'published replay message'
  assert_equals 1 "$(count_calls "$dir")" 'published replay called owner'
  pass 'explicit authorization, class and exact selection, one call, published replay'
}

check_capacity_and_reselect() {
  local dir out rc at
  dir=$(make_case capacity); printf '%s\n' capacity > "$dir/home/result"
  out=$(run_case "$dir"); rc=$?
  expect_code 75 "$rc" 'capacity result'; assert_equals capacity "$(phase "$dir")" 'capacity phase'
  assert_equals 0 "$(jq '.tried|length' "$dir/home/state/scheduled-worker/occ/journal.json")" 'capacity consumed candidate'
  selection "$dir" grok; out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'capacity switch'; assert_contains "$out" 'capacity cannot switch' 'capacity rejection reason'
  assert_equals 1 "$(count_calls "$dir")" 'capacity switch called owner'
  selection "$dir" codex "$(jq -r .observed_at "$dir/home/state/scheduled-worker/occ/journal.json")"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'stale capacity evidence'; assert_equals 1 "$(count_calls "$dir")" 'stale evidence called owner'
  at=$(( $(date +%s) + 60 ))
  # A future timestamp is not fresh evidence.
  selection "$dir" codex "$at"; out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'future evidence'; assert_equals 1 "$(count_calls "$dir")" 'future evidence called owner'
  pass 'capacity retains candidate and profile and rejects stale or future evidence'
}

check_failure_barriers() {
  local dir out rc at
  dir=$(make_case failure); printf '%s\n' unavailable > "$dir/home/result"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'unavailable'; assert_equals reselect "$(phase "$dir")" 'unavailable phase'
  selection "$dir" grok "$(jq -r .observed_at "$dir/home/state/scheduled-worker/occ/journal.json")"
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'same-time evidence'; assert_equals 1 "$(count_calls "$dir")" 'same-time evidence called owner'
  sleep 1
  selection "$dir" grok
  out=$(run_case "$dir"); rc=$?
  expect_code 1 "$rc" 'second unavailable'; assert_equals 2 "$(count_calls "$dir")" 'fresh selection did not call owner'
  assert_equals reselect "$(phase "$dir")" 'second unavailable phase'
  dir=$(make_case unsafe); printf '%s\n' unsafe > "$dir/home/result"
  out=$(run_case "$dir"); rc=$?; expect_code 1 "$rc" 'unsafe refusal'; assert_equals blocked "$(phase "$dir")" 'unsafe refusal not blocked'
  selection "$dir" grok; out=$(run_case "$dir"); rc=$?; expect_code 1 "$rc" 'unsafe replay'; assert_equals 1 "$(count_calls "$dir")" 'unsafe replay called owner'
  dir=$(make_case missing); printf '%s\n' missing > "$dir/home/result"
  out=$(run_case "$dir"); rc=$?; expect_code 1 "$rc" 'missing receipt'; assert_equals blocked "$(phase "$dir")" 'missing receipt not blocked'
  dir=$(make_case uncertain); printf '%s\n' uncertain > "$dir/home/result"
  out=$(run_case "$dir"); rc=$?; expect_code 1 "$rc" 'late uncertainty'; assert_equals blocked "$(phase "$dir")" 'uncertainty not blocked'
  pass 'pre-provisioning reselect requires fresh evidence; unsafe, missing and uncertain block'
}

check_attempt_and_exhaustion() {
  local dir out rc journal
  dir=$(make_case crash)
  mkdir -p "$dir/home/state/scheduled-worker/occ"
  cp "$dir/plan.json" "$dir/home/state/scheduled-worker/occ/plan.json"
  printf '%s\n' '{"version":1,"phase":"attempting","attempt":1,"tried":[],"observed_at":0,"action":"spawn"}' > "$dir/home/state/scheduled-worker/occ/journal.json"
  out=$(run_case "$dir"); rc=$?; expect_code 1 "$rc" 'attempting replay'
  assert_equals 0 "$(count_calls "$dir")" 'attempting replay called owner'
  dir=$(make_case exhaustion)
  out=$(run_case "$dir"); rc=$?; expect_code 0 "$rc" 'initial publication'
  printf '%s\n' '{"kind":"low-warning","spawn_gen":"gen-1","evidence":"low"}' > "$dir/proof.json"
  printf 'checkpoint\n' > "$dir/note.txt"
  out=$(run_case "$dir" --exhaustion "$dir/proof.json" --note-file "$dir/note.txt"); rc=$?
  expect_code 1 "$rc" 'low warning'; assert_equals 1 "$(count_calls "$dir")" 'low warning called control'
  printf '%s\n' '{"kind":"usage-exhausted","spawn_gen":"gen-1","evidence":"current generation exhausted"}' > "$dir/proof.json"
  selection "$dir" grok
  out=$(run_case "$dir" --exhaustion "$dir/proof.json" --note-file "$dir/note.txt"); rc=$?
  expect_code 0 "$rc" 'proven exhaustion relaunch'
  assert_grep 'control job relaunch --harness grok --model grok-4.7 --effort medium --expected-spawn-gen gen-1 --note-file' "$dir/home/calls" 'control did not receive selected continuation, generation and note'
  assert_equals 1 "$(wc -l < "$dir/home/control-relaunches")" 'matching generation did not reach relaunch'
  assert_equals live-worker "$(phase "$dir")" 'continuation not live'
  out=$(run_case "$dir"); rc=$?; expect_code 0 "$rc" 'live replay'
  assert_equals 2 "$(count_calls "$dir")" 'live replay called owner'
  pass 'attempting barrier, current-generation exhaustion, checkpoint and live replay'
}

check_generation_change_at_control_admission() {
  local dir out rc
  dir=$(make_case generation-race)
  out=$(run_case "$dir"); rc=$?; expect_code 0 "$rc" 'initial publication before generation race'
  printf '%s\n' '{"kind":"usage-exhausted","spawn_gen":"gen-1","evidence":"current generation exhausted"}' > "$dir/proof.json"
  printf 'checkpoint\n' > "$dir/note.txt"
  : > "$dir/home/race-generation"
  selection "$dir" grok
  out=$(run_case "$dir" --exhaustion "$dir/proof.json" --note-file "$dir/note.txt"); rc=$?
  expect_code 1 "$rc" "generation change at control admission must refuse: $out"
  grep -E 'control job relaunch .*--expected-spawn-gen gen-1 --note-file' "$dir/home/calls" >/dev/null || fail 'wrapper did not forward the exhausted generation'
  assert_grep 'control-refused gen-2' "$dir/home/calls" 'control did not observe G2 at admission'
  assert_equals gen-2 "$(sed -n 's/^spawn_gen=//p' "$dir/home/state/job.meta")" 'G2 metadata was overwritten'
  [ ! -e "$dir/home/control-relaunches" ] || fail 'control relaunched G2 after its generation changed'
  assert_equals blocked "$(phase "$dir")" 'refused continuation did not block for reconciliation'
  pass 'scheduled continuation forwards G1 and refuses when control admits G2'
}

check_authorization_and_selection
check_capacity_and_reselect
check_failure_barriers
check_attempt_and_exhaustion
check_generation_change_at_control_admission
printf '# all fm-scheduled-worker tests passed\n'
