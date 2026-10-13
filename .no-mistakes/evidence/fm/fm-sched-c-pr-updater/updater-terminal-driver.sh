#!/usr/bin/env bash
# Exercise the executable updater with isolated home, custody and forge doubles.
# No tmux, Herdr, live endpoint, or forge is contacted. Pending publication,
# concurrency, write scope, incomplete coverage and head-bound receipts matter.
set -eu
# shellcheck source=tests/lib.sh
. "/home/mitch/.no-mistakes/worktrees/5782b7185c5e/01M4VGTPNBVGTTWQPGKXC9G0KV/tests/lib.sh"
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
  GET:/repos/o/r/compare/*) payload=$(cat "$FIXTURES/compare.json") ;;
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
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"","mergeQueueEntry":null}}}}' > "$home/fixtures/queue.json"
  printf '%s\n' "$home"
}
run() {
  env PATH="$TOOLS:$PATH" FM_HOME="$1" FIXTURES="$1/fixtures" FM_PR_AUTOUPDATE_NOW="${3:-10000}" bash "$TOOLS/fm-pr-autoupdate.sh" "${2:-check}"
}
set_fixture() { jq "$3" "$1/fixtures/$2.json" > "$1/fixtures/new"; mv "$1/fixtures/new" "$1/fixtures/$2.json"; }
put_count() { if [ -e "$1/fixtures/calls" ]; then awk '/^api PUT / {n++} END {print n+0}' "$1/fixtures/calls"; else printf '0\n'; fi; }
result() { jq -r --arg url "$URL" '.receipts[$url].result' "$1/state/pr-autoupdate.json"; }

home=$(world terminal_projection)
mkdir -p "$home/data/task"
set_fixture "$home" input '.tasks[0].pr.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
jq -n --arg url "$URL" --arg head "$HEAD_C" '{schema:"fm-contributions.v1",task:"task",records:[{url:$url,kind:"pr",checked_at:"2026-10-13T10:00:00Z",error:null,seen:[],pending:[],observation:{state:"open",head:$head,draft:false,mergeable:"mergeable",can_merge:false,review_decision:"",checks:[],reviews:[],events:[]}}]}' > "$home/data/task/contributions.json"
chmod 600 "$home/data/task/contributions.json"
printf '%s\n' 'SCENARIO open PR observed at newer head than recorded metadata'
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:00:30Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all | jq -c '.rows[0] | {checked,final,head,actor,reason}'
jq '.records[0].observation.state="closed"' "$home/data/task/contributions.json" > "$home/fixtures/record"
mv "$home/fixtures/record" "$home/data/task/contributions.json"
chmod 600 "$home/data/task/contributions.json"
printf '%s\n' 'SCENARIO terminal PR retains its final observed head'
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONTRIBUTIONS_NOW=2026-10-13T10:00:30Z bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/fixtures/input.json" --all | jq -c '.rows[0] | {checked,final,head,actor,reason}'
