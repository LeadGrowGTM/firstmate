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
    if [ -e "$FIXTURES/race" ]; then
      count=$(cat "$FIXTURES/race")
      printf '%s\n' "$((count + 1))" > "$FIXTURES/race"
      if [ "$count" -gt 0 ]; then
        jq '.head.sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$FIXTURES/core.json" > "$FIXTURES/core.new"
        mv "$FIXTURES/core.new" "$FIXTURES/core.json"
      fi
    fi
    payload=$(cat "$FIXTURES/core.json") ;;
  GET:/repos/o/r/compare/*) payload=$(cat "$FIXTURES/compare.json") ;;
  GET:/repos/o/r/commits/*/check-runs*) payload=$(cat "$FIXTURES/checks.json") ;;
  POST:/graphql)
    payload=$(jq --slurpfile core "$FIXTURES/core.json" '.data.repository.pullRequest.headRefOid=$core[0].head.sha' "$FIXTURES/queue.json") ;;
  PUT:/repos/o/r/pulls/*/update-branch)
    # The expected head must be present and the pre-publication receipt durable.
    input=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --input ]; then shift; input=$1; fi
      shift
    done
    [ -n "$input" ] && jq -e '.expected_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$input" >/dev/null || exit 92
    jq -e '.receipts["https://github.com/o/r/pull/1"].pending == true' "$FM_HOME/state/pr-autoupdate.json" >/dev/null || exit 93
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
BASE=cccccccccccccccccccccccccccccccccccccccc
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
  'rev-parse --verify HEAD') cat "$FIXTURES/local-head" ;;
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
