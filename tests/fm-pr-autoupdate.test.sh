#!/usr/bin/env bash
# Exercise the executable updater with isolated home, custody and forge doubles.
# No tmux, Herdr, live endpoint, or forge is contacted. Pending publication,
# concurrency, write scope, incomplete coverage and head-bound receipts matter.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null || { printf 'skip: jq not found\n'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-pr-autoupdate)
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
# Real locking, safety and registration helpers; only the three evidence readers
# are replaced, so no fixture can accidentally observe a real endpoint.
cp "$ROOT/bin/fm-pr-autoupdate.sh" "$TOOLS/"
for helper in fm-pr-lib.sh fm-timeout-lib.sh fm-nm-run-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-classify-lib.sh fm-check-register.sh fm-check-unregister.sh fm-check-lib.sh; do
  cp "$ROOT/bin/$helper" "$TOOLS/$helper"
done
cat > "$TOOLS/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
[ "$*" = --contribution-input ] || exit 91
cat "$FIXTURES/input.json"
SH
cat > "$TOOLS/fm-contributions.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = snapshot ] && [ "$3" = --all ] || exit 91
jq ' .unreadable_records=(.unreadable_records // 0) | .rows |= map(.tasks=(.tasks // [.task]))' "$FIXTURES/owned.json"
SH
cat > "$TOOLS/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$FIXTURES/crew"
SH
cat > "$TOOLS/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$*" = axi ] || exit 91
cat "$FIXTURES/pipeline"
SH
cat > "$TOOLS/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURES/calls"
[ "$1" = api ] || exit 91
method=$2 path=$3
if [ -e "$FIXTURES/unavailable" ]; then exit 1; fi
case "$method:$path" in
  GET:/repos/o/r/pulls/*)
    if [ -e "$FIXTURES/queue-race" ]; then
      count=$(cat "$FIXTURES/queue-race")
      printf '%s\n' "$((count + 1))" > "$FIXTURES/queue-race"
    fi
    if [ -e "$FIXTURES/race" ]; then
      count=$(cat "$FIXTURES/race")
      printf '%s\n' "$((count + 1))" > "$FIXTURES/race"
      if [ "$count" -gt 0 ]; then
        if [ -e "$FIXTURES/core-transition" ]; then
          cp "$FIXTURES/core-transition" "$FIXTURES/core.new"
        else
          jq '.head.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$FIXTURES/core.json" > "$FIXTURES/core.new"
        fi
        mv "$FIXTURES/core.new" "$FIXTURES/core.json"
      fi
    fi
    payload=$(cat "$FIXTURES/core.json") ;;
  GET:/repos/o/r/compare/*)
    if [ -e "$FIXTURES/new-base" ] && [ "$path" = "/repos/o/r/compare/$(cat "$FIXTURES/new-base")...$(jq -r '.head.sha' "$FIXTURES/core.json")" ]; then
      payload='{"behind_by":1,"status":"diverged"}'
    else
      payload=$(cat "$FIXTURES/compare.json")
    fi ;;
  GET:/repos/o/r/commits/*/check-runs*) payload=$(cat "$FIXTURES/checks.json") ;;
  POST:/graphql)
    if [ -e "$FIXTURES/owned-transition" ]; then
      mv "$FIXTURES/owned-transition" "$FIXTURES/owned.json"
    fi
    queue="$FIXTURES/queue.json"
    if [ -e "$FIXTURES/queue-race" ] && [ "$(cat "$FIXTURES/queue-race")" -ge 2 ]; then
      queue="$FIXTURES/queue-transition"
    fi
    payload=$(jq --slurpfile core "$FIXTURES/core.json" '.data.repository.pullRequest.headRefOid=$core[0].head.sha' "$queue") ;;
  PUT:/repos/o/r/pulls/*/update-branch)
    # The expected head must be present and the pre-publication receipt durable.
    input=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --input ]; then shift; input=$1; fi
      shift
    done
    [ -n "$input" ] && jq -e --arg head "$(jq -r '.head.sha' "$FIXTURES/core.json")" '.expected_head_sha == $head' "$input" >/dev/null || exit 92
    jq -e '.receipts["https://github.com/o/r/pull/1"].pending == true' "$FM_HOME/state/pr-autoupdate.json" >/dev/null || exit 93
    if [ -e "$FIXTURES/put-422" ]; then printf 'HTTP 422: expected head changed\n' >&2; exit 1; fi
    [ ! -e "$FIXTURES/put-fails" ] || exit 1
    payload='{"message":"Updating pull request branch.","url":"https://api.github.com/repos/o/r/pulls/1"}' ;;
  *) exit 94 ;;
esac
encoded=$(printf '%s' "$payload" | jq -r 'tojson | @base64')
printf 'api_response:\n  body: fm_payload=%s\n  truncated: false\n' "$encoded"
SH
chmod +x "$TOOLS/"*.sh "$TOOLS/gh-axi" "$TOOLS/no-mistakes"
# All helper files are fixture copies; no backend tool is in PATH.
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_C=dddddddddddddddddddddddddddddddddddddddd
BASE=cccccccccccccccccccccccccccccccccccccccc
BASE_NEW=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
URL=https://github.com/o/r/pull/1
world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/"{state,data,config,fixtures,worktree}
  # A Git fixture double expresses branch/status/head without touching refs.
  cat > "$TOOLS/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = check-ref-format ]; then exit 0; fi
[ "$1" = -C ] || exit 91
shift 2
case "$*" in
  'symbolic-ref --quiet --short HEAD') printf 'topic\n' ;;
  'status --porcelain') cat "$FIXTURES/git-status" ;;
  'rev-parse --verify HEAD')
    if [ -e "$FIXTURES/local-head-read-count" ]; then
      count=$(cat "$FIXTURES/local-head-read-count")
      printf '%s\n' "$((count + 1))" > "$FIXTURES/local-head-read-count"
      [ "$count" -eq 0 ] || exit 124
    fi
    cat "$FIXTURES/local-head" ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$TOOLS/git"
  printf '%s\n' '{"enabled":true,"write_scope":[{"pr":"https://github.com/o/r/pull/1","head_repo":"o/r","head_ref":"topic"}]}' > "$home/config/pr-autoupdate.json"
  printf 'kind=ship\nmode=direct-PR\nbranch=topic\npr=%s\npr_head=%s\nworktree=%s\n' "$URL" "$HEAD_A" "$home/worktree" > "$home/state/task.meta"
  chmod 600 "$home/state/task.meta"
  printf '%s\n' '{"backlog":{"present":true,"records":[]},"tasks":[{"id":"task","kind":"ship","pr":{"url":"https://github.com/o/r/pull/1"}}]}' > "$home/fixtures/input.json"
  printf '%s\n' '{"rows":[{"task":"task","url":"https://github.com/o/r/pull/1","kind":"pr"}]}' > "$home/fixtures/owned.json"
  printf 'state: done · source: status-log · accepted delivery\n' > "$home/fixtures/crew"
  printf 'count: 0 of 0 total\nruns[0]{id,branch,status,head,pr}:\n' > "$home/fixtures/pipeline"
  printf '%s\n' "$HEAD_A" > "$home/fixtures/local-head"
  : > "$home/fixtures/git-status"
  jq -n --arg url "$URL" --arg head "$HEAD_A" --arg base "$BASE" '{html_url:$url,state:"open",merged:false,draft:false,auto_merge:null,mergeable:true,mergeable_state:"behind",head:{sha:$head,ref:"topic",repo:{full_name:"o/r"}},base:{sha:$base,ref:"release/next",repo:{full_name:"o/r"}}}' > "$home/fixtures/core.json"
  printf '%s\n' '{"behind_by":2,"status":"diverged"}' > "$home/fixtures/compare.json"
  printf '%s\n' '{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"queued","conclusion":null}]}' > "$home/fixtures/checks.json"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"","mergeQueueEntry":null}}}}' > "$home/fixtures/queue.json"
  printf '%s\n' "$home"
}
run() {
  env PATH="$TOOLS:$PATH" FM_HOME="$1" FIXTURES="$1/fixtures" FM_PR_AUTOUPDATE_NOW="${3:-10000}" bash "$TOOLS/fm-pr-autoupdate.sh" "${2:-check}"
}
set_fixture() { jq "$3" "$1/fixtures/$2.json" > "$1/fixtures/new"; mv "$1/fixtures/new" "$1/fixtures/$2.json"; }
put_count() { if [ -e "$1/fixtures/calls" ]; then awk '/^api PUT / {n++} END {print n+0}' "$1/fixtures/calls"; else printf '0\n'; fi; }
result() { jq -r --arg url "$URL" '.receipts[$url].result' "$1/state/pr-autoupdate.json"; }

regression_owner() {
  local home
  home=$(world refreshed_owner)
  touch "$home/fixtures/put-422"
  run "$home" >/dev/null
  rm "$home/fixtures/put-422"
  set_fixture "$home" owned '.rows += [{task:"other",url:"https://github.com/o/r/pull/1",kind:"pr"}]'
  cp "$home/state/task.meta" "$home/state/other.meta"
  printf 'mode=no-mistakes\n' >> "$home/state/other.meta"
  run "$home" >/dev/null
  assert_equals 1 "$(put_count "$home")" 'new owner custody prevents another write within the sweep'
  home=$(world publication_owner_race)
  cp "$home/state/task.meta" "$home/state/other.meta"
  jq '.rows += [{task:"other",url:"https://github.com/o/r/pull/1",kind:"pr"}]' "$home/fixtures/owned.json" > "$home/fixtures/owned-transition"
  run "$home" >/dev/null
  assert_equals 0 "$(put_count "$home")" 'final ownership refresh prevents publication after a new owner appears'
  assert_equals 'canonical owners changed before update' "$(jq -r --arg url "$URL" '.receipts[$url].reason' "$home/state/pr-autoupdate.json")" 'owner change is visible and remains queued'
}
regression_refusal() {
  local home
  home=$(world confirmed_then_422)
  run "$home" >/dev/null
  set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
  run "$home" >/dev/null
  set_fixture "$home" core '.base.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
  set_fixture "$home" compare '.behind_by=1 | .status="diverged"'
  touch "$home/fixtures/put-422"
  run "$home" check 17200 >/dev/null
  assert_equals false "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'definitive refusal settles request'
  rm "$home/fixtures/put-422"
  run "$home" check 17200 >/dev/null
  assert_equals 3 "$(put_count "$home")" 'confirmed local-head evidence survives later refusal and permits reobserved retry'
}
regression_confirmation() {
  local home
  home=$(world confirmation_owner_race)
  run "$home" >/dev/null
  set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
  cp "$home/state/task.meta" "$home/state/other.meta"
  jq '.rows += [{task:"other",url:"https://github.com/o/r/pull/1",kind:"pr"}]' "$home/fixtures/owned.json" > "$home/fixtures/owned-transition"
  run "$home" >/dev/null
  assert_equals incomplete "$(result "$home")" 'new canonical owner prevents confirmation'
  assert_equals 'canonical owners changed before confirmation' "$(jq -r --arg url "$URL" '.receipts[$url].reason' "$home/state/pr-autoupdate.json")" 'ownership race remains visible'
  assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'ownership race preserves pending receipt'
  assert_equals false "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" 'ownership race cannot complete coverage'
  assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_A" 'old owner metadata stays unchanged'
  assert_contains "$(cat "$home/state/other.meta")" "pr_head=$HEAD_A" 'new owner metadata stays unchanged'
  assert_equals 1 "$(put_count "$home")" 'ownership race sends no repeated update'
  home=$(world interrupted_confirmation)
  cp "$home/state/task.meta" "$home/state/other.meta"
  set_fixture "$home" owned '.rows[0].tasks=["task","other"]'
  run "$home" >/dev/null
  set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
  # Persisted crash state: one owner's metadata was published, the other and
  # pending receipt still contain the captured head. No process is killed.
  sed -i "s/pr_head=$HEAD_A/pr_head=$HEAD_B/" "$home/state/task.meta"
  run "$home" >/dev/null
  assert_equals updated "$(result "$home")" 'partially published confirmation recovers'
  assert_contains "$(cat "$home/state/other.meta")" "pr_head=$HEAD_B" 'recovery completes every owner metadata update'
  assert_equals false "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'recovered confirmation settles receipt'
  assert_equals 1 "$(put_count "$home")" 'confirmation recovery sends no repeated update'
}
regression_readiness() {
  local home
  home=$(world pending_readiness)
  mkdir -p "$home/data/task"
  jq -n --arg url "$URL" --arg head "$HEAD_A" '{schema:"fm-contributions.v1",task:"task",records:[{url:$url,kind:"pr",checked_at:"2026-10-13T10:00:00Z",error:null,seen:[],pending:[],observation:{state:"open",head:$head,draft:false,mergeable:"mergeable",can_merge:true,review_decision:"APPROVED",checks:[{name:"ci",status:"completed",conclusion:"success"}],reviews:[],events:[]}}]}' > "$home/data/task/contributions.json"
  chmod 600 "$home/data/task/contributions.json"
  set_fixture "$home" input '.tasks[0].pr.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | .tasks[0].merge_authority="away"'
  run "$home" >/dev/null
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:01:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
  jq -e '.rows[0].checked == false and .rows[0].actor == "fleet" and .rows[0].reason != "checks green; merge is authorized by delivery posture"' "$home/fixtures/projected.json" >/dev/null || fail 'pending publication retained green readiness'
  set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
  set_fixture "$home" checks '.total_count=101'
  run "$home" >/dev/null
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:01:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
  jq -e '.rows[0].checked == false and .rows[0].actor == "fleet"' "$home/fixtures/projected.json" >/dev/null || fail 'changed head awaiting confirmation retained green readiness'
  jq --arg url "$URL" '.receipts[$url].pending=false | .receipts[$url].checked_at=1791885720' "$home/state/pr-autoupdate.json" > "$home/fixtures/journal"
  mv "$home/fixtures/journal" "$home/state/pr-autoupdate.json"
  chmod 600 "$home/state/pr-autoupdate.json"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:02:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
  jq -e '.rows[0].checked == false' "$home/fixtures/projected.json" >/dev/null || fail 'newer changed-head evidence retained green readiness without pending publication'
  jq --arg head "$HEAD_B" '.records[0].observation.head=$head | .records[0].checked_at="2026-10-13T10:03:00Z"' "$home/data/task/contributions.json" > "$home/fixtures/record"
  mv "$home/fixtures/record" "$home/data/task/contributions.json"
  set_fixture "$home" input '.tasks[0].pr.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:03:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
  jq -e '.rows[0].checked == true' "$home/fixtures/projected.json" >/dev/null || fail 'a later current-head observation could not restore readiness'
  printf '%s\n' '{}' > "$home/state/pr-autoupdate.json"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:03:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
  jq -e '.rows[0].checked == false and .complete == false' "$home/fixtures/projected.json" >/dev/null || fail 'unreadable updater evidence retained readiness'
}
regression_failed=0
for regression in regression_owner regression_refusal regression_confirmation regression_readiness; do
  if ! ("$regression"); then regression_failed=1; fi
done
[ "$regression_failed" = 0 ] || fail 'custody and receipt regression failures'

home=$(world off)
rm "$home/config/pr-autoupdate.json"
assert_equals '' "$(run "$home")" 'absent config silent'
assert_equals 0 "$(put_count "$home")" 'off made no write'
printf '%s\n' '{"enabled":false,"write_scope":[]}' > "$home/config/pr-autoupdate.json"
assert_equals '' "$(run "$home")" 'disabled config silent'

home=$(world update)
assert_equals '' "$(run "$home")" 'accepted request silent until confirmed'
assert_equals 1 "$(put_count "$home")" 'one guarded write'
assert_contains "$(cat "$home/fixtures/calls")" "api GET /repos/o/r/compare/$BASE...$HEAD_A" 'comparison uses actual feature-base SHA'
assert_equals pending "$(result "$home")" '202 is pending'
run "$home" >/dev/null
assert_equals 1 "$(put_count "$home")" 'same head never repeats PUT'
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
out=$(run "$home")
assert_contains "$out" 'captured base integrated' 'later head integration confirmed'
assert_equals updated "$(result "$home")" 'confirmed update'
assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_B" 'metadata names current head'
assert_equals "$HEAD_B" "$(jq -r --arg url "$URL" '.receipts[$url].checks.head' "$home/state/pr-autoupdate.json")" 'checks bound to head'
assert_equals 1 "$(put_count "$home")" 'confirmation does not write'
assert_equals '' "$(run "$home")" 'two-hour gate holds'
run "$home" check 17200 >/dev/null
assert_equals current "$(result "$home")" 'two-hour new sweep follows remote head without local ref mutation'

home=$(world pushed_after_update)
run "$home" >/dev/null
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
run "$home" >/dev/null
printf '%s\n' "$HEAD_C" > "$home/fixtures/local-head"
set_fixture "$home" core '.head.sha="dddddddddddddddddddddddddddddddddddddddd"'
set_fixture "$home" compare '.behind_by=1 | .status="diverged"'
sed -i "s/pr_head=$HEAD_B/pr_head=$HEAD_C/" "$home/state/task.meta"
run "$home" check 17200 >/dev/null
assert_equals 2 "$(put_count "$home")" 'later ready push can receive a new guarded update'
assert_equals "$HEAD_C" "$(jq -r --arg url "$URL" '.receipts[$url].old_head' "$home/state/pr-autoupdate.json")" 'new request captures current head'

home=$(world pending_pushed_after_update)
run "$home" >/dev/null
printf '%s\n' "$HEAD_C" > "$home/fixtures/local-head"
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
sed -i "s/pr_head=$HEAD_A/pr_head=$HEAD_C/" "$home/state/task.meta"
run "$home" >/dev/null
assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'unpublished ready head keeps receipt pending'
set_fixture "$home" core '.head.sha="dddddddddddddddddddddddddddddddddddddddd"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
set_fixture "$home" checks '.check_runs[0].head_sha="dddddddddddddddddddddddddddddddddddddddd"'
run "$home" >/dev/null
assert_equals updated "$(result "$home")" 'pending request reconciles a newer ready push'
assert_equals "$HEAD_C" "$(jq -r --arg url "$URL" '.receipts[$url].result_head' "$home/state/pr-autoupdate.json")" 'pending receipt records resulting ready head'
assert_equals 1 "$(put_count "$home")" 'pending reconciliation never repeats publication'

home=$(world local_read_timeout)
printf '0\n' > "$home/fixtures/local-head-read-count"
run "$home" >/dev/null
assert_equals incomplete "$(result "$home")" 'later local head read leaves incomplete receipt'
assert_equals 'local head unavailable' "$(jq -r --arg url "$URL" '.receipts[$url].reason' "$home/state/pr-autoupdate.json")" 'local read failure has explicit reason'
assert_equals 0 "$(put_count "$home")" 'local read failure prevents publication'

home=$(world confirmed_receipt_preparation_timeout)
run "$home" >/dev/null
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
run "$home" >/dev/null
assert_equals updated "$(result "$home")" 'initial update is confirmed before the later preparation failure'
set_fixture "$home" core '.base.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
set_fixture "$home" compare '.behind_by=1 | .status="diverged"'
printf '0\n' > "$home/fixtures/local-head-read-count"
run "$home" check 17200 >/dev/null
assert_equals incomplete "$(result "$home")" 'later preparation timeout is visible'
assert_equals "$HEAD_B" "$(jq -r --arg url "$URL" '.receipts[$url].result_head' "$home/state/pr-autoupdate.json")" 'preparation timeout preserves the confirmed head'
assert_equals "$HEAD_A" "$(jq -r --arg url "$URL" '.receipts[$url].local_heads.task' "$home/state/pr-autoupdate.json")" 'preparation timeout preserves the unchanged local head'
assert_equals 1 "$(put_count "$home")" 'preparation timeout sends no new update'
rm "$home/fixtures/local-head-read-count"
run "$home" check 17200 >/dev/null
assert_equals 2 "$(put_count "$home")" 'the next poll retries after the transient preparation failure'
assert_equals "$HEAD_B" "$(jq -r --arg url "$URL" '.receipts[$url].old_head' "$home/state/pr-autoupdate.json")" 'successful preparation captures the current head'

for phase in prewrite postchecks; do
  for state in queued draft closed; do
    home=$(world "${phase}_${state}")
    if [ "$phase" = postchecks ]; then
      run "$home" >/dev/null
      set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
      set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
    fi
    case "$state" in
      queued) jq '.mergeable_state="queued"' "$home/fixtures/core.json" > "$home/fixtures/core-transition"; expected=deferred ;;
      draft) jq '.draft=true' "$home/fixtures/core.json" > "$home/fixtures/core-transition"; expected=deferred ;;
      closed) jq '.state="closed"' "$home/fixtures/core.json" > "$home/fixtures/core-transition"; expected=terminal ;;
    esac
    printf '0\n' > "$home/fixtures/race"
    run "$home" >/dev/null
    assert_equals "$expected" "$(result "$home")" "$phase $state records observed eligibility"
    if [ "$phase" = prewrite ]; then
      assert_equals 0 "$(put_count "$home")" "$state before publication prevents write"
    else
      assert_equals 1 "$(put_count "$home")" "$state after checks prevents a second write"
      assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_A" "$state after checks preserves ready metadata"
      jq -e --arg url "$URL" '.receipts[$url] | has("result_head") | not' "$home/state/pr-autoupdate.json" >/dev/null || fail "$state after checks cannot confirm updated head"
    fi
    if [ "$state" != closed ]; then
      assert_equals false "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" "$phase $state leaves coverage unfinished"
    fi
  done
done

for phase in prewrite postchecks; do
  home=$(world "${phase}_graphql_queue_race")
  if [ "$phase" = postchecks ]; then
    run "$home" >/dev/null
    set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
    set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
  fi
  jq '.data.repository.pullRequest.mergeQueueEntry={id:"queue"}' "$home/fixtures/queue.json" > "$home/fixtures/queue-transition"
  printf '0\n' > "$home/fixtures/queue-race"
  run "$home" >/dev/null
  assert_equals deferred "$(result "$home")" "$phase observes final GraphQL queue membership"
  assert_equals behind "$(jq -r '.mergeable_state' "$home/fixtures/core.json")" 'REST state stays unchanged while queue membership changes'
  if [ "$phase" = prewrite ]; then
    assert_equals 0 "$(put_count "$home")" 'final GraphQL queue evidence prevents publication'
  else
    assert_equals 1 "$(put_count "$home")" 'final GraphQL queue evidence prevents repeated publication'
    assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_A" 'final GraphQL queue evidence preserves ready metadata'
    assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'final GraphQL queue evidence leaves confirmation pending'
  fi
done

home=$(world base_advanced)
run "$home" >/dev/null
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .base.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
printf '%s\n' "$BASE_NEW" > "$home/fixtures/new-base"
run "$home" >/dev/null
assert_equals incomplete "$(result "$home")" 'advanced closing base leaves coverage incomplete'
assert_equals false "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" 'advanced base cannot complete sweep'
assert_equals false "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'captured-base integration is settled'
run "$home" >/dev/null
assert_equals 2 "$(put_count "$home")" 'advanced base gets its own guarded update on next segment'

home=$(world definitive_422)
touch "$home/fixtures/put-422"
run "$home" >/dev/null
assert_equals false "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'definitive 422 does not strand a pending receipt'
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
printf '%s\n' "$HEAD_B" > "$home/fixtures/local-head"
sed -i "s/pr_head=$HEAD_A/pr_head=$HEAD_B/" "$home/state/task.meta"
rm "$home/fixtures/put-422"
run "$home" >/dev/null
assert_equals 2 "$(put_count "$home")" 'fresh ready head is retried with its own expected SHA'
assert_equals "$HEAD_B" "$(jq -r --arg url "$URL" '.receipts[$url].old_head' "$home/state/pr-autoupdate.json")" 'retry captures reobserved head'

home=$(world stale_readiness)
mkdir -p "$home/data/task"
jq -n --arg url "$URL" --arg head "$HEAD_A" '{schema:"fm-contributions.v1",task:"task",records:[{url:$url,kind:"pr",checked_at:"2026-10-13T10:00:00Z",error:null,seen:[],pending:[],observation:{state:"open",head:$head,draft:false,mergeable:"mergeable",can_merge:true,review_decision:"APPROVED",checks:[{name:"ci",status:"completed",conclusion:"success"}],reviews:[],events:[]}}]}' > "$home/data/task/contributions.json"
chmod 600 "$home/data/task/contributions.json"
set_fixture "$home" input '.tasks[0].pr.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | .tasks[0].merge_authority="away"'
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:01:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
jq -e '.rows[0].checked == true and .rows[0].reason == "checks green; merge is authorized by delivery posture"' "$home/fixtures/projected.json" >/dev/null || fail 'same-head contribution fixture was not ready'
run "$home" >/dev/null
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
run "$home" >/dev/null
assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_B" 'confirmation records the changed head'
set_fixture "$home" input '.tasks[0].pr.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:01:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
jq -e '.rows[0].checked == false and .rows[0].actor == "fleet" and .rows[0].head == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$home/fixtures/projected.json" >/dev/null || fail 'old green observation remained ready after head changed'
set_fixture "$home" input '.tasks[0].pr.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .state="closed"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
jq --arg head "$HEAD_B" '.records[0].observation.state="closed" | .records[0].observation.head=$head' "$home/data/task/contributions.json" > "$home/fixtures/terminal-record"
mv "$home/fixtures/terminal-record" "$home/data/task/contributions.json"
chmod 600 "$home/data/task/contributions.json"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:01:00Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/projected.json"
jq -e --arg head "$HEAD_B" '.rows[0].checked == true and .rows[0].final == true and .rows[0].head == $head and .rows[0].actor == "nobody"' "$home/fixtures/projected.json" >/dev/null || fail 'terminal observation lost its final observed head'

for scenario in current conflict unknown draft closed queued scope worker pipeline dirty race unavailable checks remote uninitialized; do
  home=$(world "$scenario")
  case "$scenario" in
    current) set_fixture "$home" compare '.behind_by=0 | .status="ahead"' ;;
    conflict) set_fixture "$home" core '.mergeable=false' ;;
    unknown) set_fixture "$home" core '.mergeable=null' ;;
    draft) set_fixture "$home" core '.draft=true' ;;
    closed) set_fixture "$home" core '.state="closed"' ;;
    queued) set_fixture "$home" queue '.data.repository.pullRequest.mergeQueueEntry={id:"queue"}' ;;
    scope) printf '%s\n' '{"enabled":true,"write_scope":[]}' > "$home/config/pr-autoupdate.json" ;;
    worker) printf 'state: working · source: pane · busy\n' > "$home/fixtures/crew" ;;
    pipeline) printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  run,topic,running,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,""\n' > "$home/fixtures/pipeline" ;;
    dirty) printf ' M file\n' > "$home/fixtures/git-status" ;;
    race) printf '0\n' > "$home/fixtures/race" ;;
    remote) printf 'remote_host=example.invalid\n' >> "$home/state/task.meta" ;;
    uninitialized) printf 'error: "repo not initialized (run '\''no-mistakes init'\'' first)"\n' > "$home/fixtures/pipeline"; set_fixture "$home" compare '.behind_by=0 | .status="ahead"' ;;
    unavailable) touch "$home/fixtures/unavailable" ;;
    checks) set_fixture "$home" core '.head.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' ;;
  esac
  run "$home" >/dev/null
  assert_equals 0 "$(put_count "$home")" "$scenario makes no write"
done
home=$(world uncertain)
touch "$home/fixtures/put-fails"
run "$home" >/dev/null
run "$home" >/dev/null
assert_equals 1 "$(put_count "$home")" 'failed PUT is reobserved without repeating'
printf 'state: working · source: pane · busy\n' > "$home/fixtures/crew"
run "$home" >/dev/null
assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'custody change cannot discard pending request'
printf 'state: done · source: status-log · accepted delivery\n' > "$home/fixtures/crew"
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
set_fixture "$home" checks '.total_count=101'
run "$home" >/dev/null
assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'partial checks cannot confirm'

home=$(world dedup)
set_fixture "$home" core '.mergeable=false'
out=$(run "$home")
assert_contains "$out" conflict 'positive conflict emits once'
assert_equals '' "$(run "$home" check 17200)" 'same conflict episode is deduplicated'

home=$(world registration)
run "$home" arm >/dev/null
assert_present "$home/state/pr-autoupdate.check-trust" 'explicit arm authenticates shim'
run "$home" >/dev/null
run "$home" disarm >/dev/null
assert_absent "$home/state/pr-autoupdate.check.sh" 'disarm removes shim'
assert_present "$home/state/pr-autoupdate.json" 'disarm preserves pending receipts'

home=$(world multi)
set_fixture "$home" core '.state="closed"'
set_fixture "$home" owned '.rows += [{"task":"task","url":"https://github.com/o/r/pull/2","kind":"pr"}]'
# Both known URLs are attempted in separate segments, with no duplicate owner.
run "$home" >/dev/null
assert_equals 1 "$(jq '.queue | length' "$home/state/pr-autoupdate.json")" 'incremental cursor preserves remaining owned URL'
assert_equals false "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" 'partial sweep never complete'
# The forge double returns the wrong URL for pull/2: honest incomplete coverage.
run "$home" >/dev/null
assert_equals 1 "$(jq '.queue | length' "$home/state/pr-autoupdate.json")" 'transient PR failure remains queued'
assert_equals false "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" 'unreadable second PR preserves incomplete coverage'
assert_equals 0 "$(put_count "$home")" 'multi-PR read failures never write'
# A new ownership sweep can settle after the former incomplete URL is removed.
set_fixture "$home" owned '.rows = [.rows[0]]'
run "$home" check 17200 >/dev/null
assert_equals true "$(jq '.coverage_complete' "$home/state/pr-autoupdate.json")" 'historical errors do not poison current coverage'

home=$(world long_queue)
jq -n '{rows:[range(101;126) | {task:"task",kind:"pr",url:("https://github.com/o/r/pull/" + tostring)}]}' > "$home/fixtures/owned.json"
for segment in {1..24}; do run "$home" >/dev/null; done
assert_equals 'https://github.com/o/r/pull/125' "$(jq -r '.queue[0].url' "$home/state/pr-autoupdate.json")" 'last owned PR remains next after 24 segments'
set_fixture "$home" owned '.rows |= map(select(.url != "https://github.com/o/r/pull/110")) | .rows += [{task:"task",kind:"pr",url:"https://github.com/o/r/pull/126"}]'
run "$home" check 17200 >/dev/null
assert_equals 'https://github.com/o/r/pull/125' "$(jq -r '.sweep_urls[0]' "$home/state/pr-autoupdate.json")" 'refresh preserves unfinished queue position'
assert_equals 'https://github.com/o/r/pull/126' "$(jq -r '.sweep_urls[-1]' "$home/state/pr-autoupdate.json")" 'refresh appends new ownership'
jq -e '.sweep_urls | index("https://github.com/o/r/pull/110") == null' "$home/state/pr-autoupdate.json" >/dev/null || fail 'refresh retained removed ownership'
jq -e '.receipts["https://github.com/o/r/pull/125"].result == "incomplete"' "$home/state/pr-autoupdate.json" >/dev/null || fail 'last owned PR was not processed'

home=$(world second_owner)
set_fixture "$home" owned '.rows += [{"task":"other","url":"https://github.com/o/r/pull/1","kind":"pr"}]'
run "$home" >/dev/null
assert_equals 0 "$(put_count "$home")" 'all shared owners must establish custody'
assert_equals 1 "$(jq '.sweep_urls | length' "$home/state/pr-autoupdate.json")" 'canonical URL coverage deduplicated'

home=$(world queue_unknown)
set_fixture "$home" queue 'del(.data.repository.pullRequest.mergeQueueEntry)'
run "$home" >/dev/null
assert_equals 0 "$(put_count "$home")" 'unknown queue does not write'

home=$(world wrong_checks_head)
run "$home" >/dev/null
set_fixture "$home" core '.head.sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
set_fixture "$home" compare '.behind_by=0 | .status="ahead"'
set_fixture "$home" checks '.check_runs[0].head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
run "$home" >/dev/null
assert_equals true "$(jq -r --arg url "$URL" '.receipts[$url].pending' "$home/state/pr-autoupdate.json")" 'stale checks cannot confirm new head'
assert_contains "$(cat "$home/state/task.meta")" "pr_head=$HEAD_A" 'old ready metadata remains until confirmation'

home=$(world real_projection)
# Exercise the actual contribution owner to prevent a fake row shape becoming
# a second interpretation of canonical shared ownership.
set_fixture "$home" input '.tasks += [{id:"other",kind:"ship",pr:{url:"https://github.com/o/r/pull/1"}}]'
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all > "$home/fixtures/owned.json"
assert_equals 2 "$(jq '.rows[0].tasks | length' "$home/fixtures/owned.json")" 'actual projection retains every owner'
run "$home" >/dev/null
assert_equals 0 "$(put_count "$home")" 'actual shared-owner projection gates missing custody'

home=$(world corrupt_saved)
set_fixture "$home" owned '.unreadable_records=1'
if run "$home" > "$home/fixtures/output"; then fail 'unreadable saved contribution must refuse incomplete coverage'; fi
assert_contains "$(cat "$home/fixtures/output")" 'coverage incomplete' 'failed ownership read is visible'
if run "$home" > "$home/fixtures/output"; then fail 'repeated failed inventory must remain a failure'; fi
assert_equals '' "$(cat "$home/fixtures/output")" 'fatal failure episode does not flood wakes'
assert_equals 0 "$(put_count "$home")" 'unreadable durable ownership cannot write'

home=$(world coverage)
set_fixture "$home" input '.backlog.present=false' # file is input.json
if run "$home" > "$home/fixtures/output"; then fail 'missing ownership coverage should fail'; fi
assert_equals 0 "$(put_count "$home")" 'incomplete inventory cannot write'

pass 'fm-pr-autoupdate'
