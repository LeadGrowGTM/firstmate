#!/usr/bin/env bash
# Opt-in two-hour freshness for task-owned direct GitHub PRs.
# Usage: fm-pr-autoupdate.sh [check|arm|disarm|status|--help]
# docs/configuration.md owns config/pr-autoupdate.json and activation authority.
# Nothing arms automatically. Absent or disabled config is a silent no-op.
# arm binds a generated shim through fm-check-register.sh; disarm removes only
# that shim/trust, preserving receipts and unfinished operations for recovery.
#
# Each sweep snapshots the canonical contribution ownership set, including saved
# links. One URL is processed per poll, shared owners together. The journal at
# state/pr-autoupdate.json records the queue, coverage, and head-bound receipts.
# A sweep starts at most once per 7200 seconds; unfinished coverage continues
# on normal watcher polls. No repository-wide discovery or other-home reads.
# Per-call bounds and a 24-second segment deadline leave watcher timeout margin.
# Pending requests rotate behind other work and prevent a false complete sweep.
# Fatal read/config episodes persist in state/.pr-autoupdate-failed until a
# later check reaches journal processing; unchanged fatal failures emit once.
# Incomplete/deferred/conflict episodes emit once per unchanged URL/head/base
# result; successful no-op sweeps are silent. status prints the full journal.
#
# Under URL, task-control, and metadata locks, every owner must be a direct-PR
# ship with a canonical matching pr=, unchanged recorded branch, clean copy,
# confirmed done worker, and positively absent pipeline custody. Unknown
# evidence defers. Pipeline-owned/no-mistakes tasks are unsupported, never written.
# Use actual base/head repository/ref/SHA; skip drafts, closed, queued/auto-merge,
# unsupported forges, and any head branch outside the exact configured grant.
# Compare immutable base...head SHAs: behind_by > 0 alone establishes behind.
# Only mergeable=false is a conflict. Unknown mergeability/API failures are not.
#
# Persist the old head, captured base and pending receipt BEFORE the expected-head
# guarded gh-axi API PUT. A timeout or error may have published: never repeat that
# PUT blindly. A later GET plus compare must prove a changed head contains the
# captured base. Final publication and confirmation recheck head-bound queue
# membership. Confirmation stores checks bound to the new head, rereads the head
# after checks, then updates pr_head under the metadata locks. This
# command never grants readiness, review, or merge authority.
# Ambiguous requests remain pending for inspection even across disarm/re-arm.
# It never changes local Git refs, rebases, force-pushes, launches repair workers,
# merges, or drives any endpoint lifecycle. Live forge-write proof is separately
# authorized on a disposable PR; fixture proof is not live API proof.
# FM_PR_AUTOUPDATE_NOW is an epoch clock override for fixtures.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/pr-autoupdate.json"
JOURNAL="$STATE/pr-autoupdate.json"
FAILURE="$STATE/.pr-autoupdate-failed"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
fail() {
  local message="$*" device staged report=true
  if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
    device=$(fm_pr_file_device "$STATE")
    if fm_pr_private_file_valid "$FAILURE" 600 "$device" && [ "$(cat "$FAILURE")" = "$message" ]; then
      report=false
    elif fm_pr_regular_destination_on_device_or_absent "$FAILURE" "$device"; then
      staged=$(umask 077; mktemp "$STATE/.pr-autoupdate-failed.XXXXXX") || staged=''
      if [ -n "$staged" ]; then
        printf '%s\n' "$message" > "$staged"
        chmod 600 "$staged"
        if ! fm_pr_regular_destination_on_device_or_absent "$FAILURE" "$device" || ! mv -f -- "$staged" "$FAILURE"; then
          rm -f -- "$staged"
        fi
      fi
    fi
  fi
  [ "$report" = false ] || printf 'pr-autoupdate: incomplete: %s\n' "$message"
  exit 1
}
MODE=${1:-check}
case "$MODE" in --help|-h|help) usage; exit 0 ;; check|arm|disarm|status) ;; *) usage >&2; exit 2 ;; esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }
[ "$MODE" != status ] || {
  [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ] && exit 0
  fm_pr_private_file_valid "$JOURNAL" 600 "$(fm_pr_file_device "$STATE")" || fail 'unsafe journal'
  cat "$JOURNAL"; exit 0
}
[ "$MODE" != disarm ] || { "$SCRIPT_DIR/fm-check-unregister.sh" pr-autoupdate; exit 0; }
[ -e "$CONFIG" ] || { [ "$MODE" = check ] && exit 0; fail 'configuration absent'; }
[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail 'unsafe configuration'
command -v jq >/dev/null || fail 'jq unavailable'
CFG=$(jq -sce '
  def branch: type == "string" and length > 0 and (test("[[:cntrl:][:space:]]") | not);
  if length != 1 then error("expected one config") else .[0] end |
  if type != "object" or (keys - ["enabled","write_scope"] | length) > 0
    or (.enabled | type) != "boolean" or (.write_scope | type) != "array"
    or any(.write_scope[]; type != "object" or keys != ["head_ref","head_repo","pr"]
      or (.pr | type) != "string" or (.head_repo | type) != "string" or (.pr | test("[[:cntrl:][:space:]]") )
      or (.head_repo | test("[[:cntrl:][:space:]]")) or (.head_ref | branch | not))
  then error("invalid configuration") else . end' "$CONFIG" 2>/dev/null) || fail 'invalid configuration'
[ "$(printf '%s' "$CFG" | jq -r '.enabled')" = true ] || { [ "$MODE" = check ] && exit 0; fail 'disabled configuration'; }
while IFS=$'\t' read -r grant repo ref; do
  fm_pr_url_parse "$grant" && [ "$FM_PR_PROVIDER" = github ] || fail 'write scope needs canonical GitHub URLs'
  [[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || fail 'invalid head repository'
  git check-ref-format --branch "$ref" >/dev/null 2>&1 || fail 'invalid head branch'
done < <(printf '%s' "$CFG" | jq -r '.write_scope[] | [.pr,.head_repo,.head_ref] | @tsv')
[ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'home directories unavailable'
# Load lock primitives only after validating the explicit home directories.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-autoupdate.XXXXXX")
LOCKS=()
cleanup() {
  local lock
  for lock in "${LOCKS[@]:-}"; do [ -n "$lock" ] || continue; fm_lock_release "$lock" || true; done
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
lock() { fm_lock_try_acquire "$1" || return 1; LOCKS+=("$1"); }
lock "$STATE/.pr-autoupdate.lock" || exit 0
DEVICE=$(fm_pr_file_device "$STATE")
write_json() { # destination input-file
  local staged
  fm_pr_regular_destination_on_device_or_absent "$1" "$DEVICE" || fail 'unsafe record destination'
  staged=$(umask 077; mktemp "$STATE/.pr-autoupdate.XXXXXX")
  cat "$2" > "$staged"
  chmod 600 "$staged"
  fm_pr_regular_destination_on_device_or_absent "$1" "$DEVICE" || fail 'record destination changed'
  mv -f -- "$staged" "$1"
}
if [ "$MODE" = arm ]; then
  fm_pr_regular_destination_on_device_or_absent "$STATE/pr-autoupdate.check.sh" "$DEVICE" || fail 'unsafe check destination'
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}")" \
    "exec bash $(printf '%q' "$SCRIPT_DIR/fm-pr-autoupdate.sh") check" > "$TMP/shim"
  write_json "$STATE/pr-autoupdate.check.sh" "$TMP/shim"
  chmod 700 "$STATE/pr-autoupdate.check.sh"
  if ! "$SCRIPT_DIR/fm-check-register.sh" pr-autoupdate >/dev/null; then
    rm -f -- "$STATE/pr-autoupdate.check.sh" "$STATE/pr-autoupdate.check-trust"
    fail 'check registration failed'
  fi
  printf 'armed: pr-autoupdate\n'; exit 0
fi
NOW=${FM_PR_AUTOUPDATE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) fail 'invalid clock' ;; esac
DEADLINE=$(($(date +%s) + 24))
bounded() {
  local remaining
  remaining=$((DEADLINE - $(date +%s)))
  [ "$remaining" -gt 0 ] || return 124
  [ "$remaining" -le 3 ] || remaining=3
  fm_run_timed "$remaining" "$@" </dev/null
}
if [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; then
  fm_pr_private_file_valid "$JOURNAL" 600 "$DEVICE" || fail 'unsafe journal'
  jq -e '.schema == "fm-pr-autoupdate.v1" and (.started | type == "number" and . >= 0 and . == floor)
    and (.queue | type == "array") and (.sweep_urls | type == "array")
    and (.receipts | type == "object") and all(.queue[]; (.url | type == "string")
      and (.owners | type == "array" and length > 0 and all(.[]; type == "string")))
    and all(.receipts[]; (.pending | type == "boolean") and
      (if .pending then (.old_head | test("^[a-fA-F0-9]{40}$")) and (.base_sha | test("^[a-fA-F0-9]{40}$"))
        and (.local_heads | type == "object") else true end))' "$JOURNAL" >/dev/null || fail 'invalid journal'
  cp "$JOURNAL" "$TMP/journal"
else
  printf '%s\n' '{"schema":"fm-pr-autoupdate.v1","started":0,"queue":[],"sweep_urls":[],"receipts":{},"coverage_complete":false}' > "$TMP/journal"
fi
save() { write_json "$JOURNAL" "$TMP/journal"; }
LAST=$(jq '.started' "$TMP/journal")
if [ "$LAST" = 0 ] || [ "$NOW" -lt "$LAST" ] || [ $((NOW - LAST)) -ge 7200 ]; then
  bounded "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input" || fail 'owned task inventory unavailable'
  bounded "$SCRIPT_DIR/fm-contributions.sh" snapshot "$TMP/input" --all > "$TMP/owned" || fail 'contribution inventory unavailable'
  jq -e '.unreadable_records == 0 and (.rows | type == "array")
    and all(.rows[]; (.tasks | type == "array" and length > 0))' "$TMP/owned" >/dev/null || fail 'saved contribution coverage incomplete'
  jq -e '.backlog.present == true and (.tasks | type == "array")' "$TMP/input" >/dev/null || fail 'owned task coverage incomplete'
  jq --slurpfile owned "$TMP/owned" --slurpfile input "$TMP/input" --argjson now "$NOW" '
    ([$owned[0].rows[] | select(.kind == "pr") | . as $row | .tasks[] | {url:$row.url,task:.}]
      + [$input[0].tasks[] | select(.kind != "secondmate" and (.pr.url | type == "string" and contains("/c/"))) | {url:.pr.url,task:.id}]
      | unique_by([.url,.task]) | group_by(.url) | map({url:.[0].url,owners:map(.task)})) as $current |
    (.queue | map(.url)) as $unfinished |
    .started=$now | .coverage_complete=false |
    .queue=([$unfinished[] as $url | $current[] | select(.url == $url)]
      + [$current[] | . as $entry | select(($unfinished | index($entry.url)) == null)]) |
    .sweep_urls=(.queue | map(.url)) |
    if (.queue | length) == 0 then .coverage_complete=true else . end' "$TMP/journal" > "$TMP/new"
  mv "$TMP/new" "$TMP/journal"; save
fi
fm_pr_regular_destination_on_device_or_absent "$FAILURE" "$DEVICE" || fail 'unsafe failure record'
rm -f -- "$FAILURE"
[ "$(jq '.queue | length' "$TMP/journal")" -gt 0 ] || exit 0
URL=$(jq -r '.queue[0].url' "$TMP/journal")
OWNERS=$(jq -r '.queue[0].owners[]' "$TMP/journal")
RESULT=incomplete
REASON='unavailable evidence'
PENDING=false
HEAD=''
BASE=''
RECEIPT=$(jq -c --arg url "$URL" '.receipts[$url] // {}' "$TMP/journal")
PENDING=$(printf '%s' "$RECEIPT" | jq -r '.pending // false')
# gh-axi intentionally emits TOON. Request one marker + base64 JSON through
# --jq; validate that exact untruncated scalar before decoding with jq.
api() {
  local out encoded
  if ! out=$(bounded gh-axi api "$@" --jq '"fm_payload=" + (tojson | @base64)' --full 2> "$TMP/api-error"); then
    if grep -Eq '(^|[^[:digit:]])(HTTP|status:|status_code:) ?422([^[:digit:]]|$)' "$TMP/api-error"; then return 22; fi
    return 1
  fi
  encoded=$(printf '%s\n' "$out" | sed -n 's/^  body: fm_payload=\([A-Za-z0-9+/=]*\)$/\1/p')
  printf '%s\n' "$out" | tail -1 | grep -qx '  truncated: false' || return 1
  [ -n "$encoded" ] && [ "$(printf '%s\n' "$encoded" | wc -l | tr -d ' ')" = 1 ] || return 1
  jq -n --arg encoded "$encoded" '$encoded | @base64d | fromjson'
}
meta_value() { awk -v key="$2" 'index($0,key "=")==1 {v=substr($0,length(key)+2)} END {print v}' "$1"; }
custody() {
  local id meta wt branch raw overview choice changed overview_rc
  for id in $OWNERS; do
    fm_pr_task_id_valid "$id" || { REASON='invalid owner'; return 1; }
    meta="$STATE/$id.meta"
    fm_pr_private_file_valid "$meta" 600 "$DEVICE" || { REASON='task metadata unavailable'; return 1; }
    [ "$(meta_value "$meta" kind)" = ship ] && [ "$(meta_value "$meta" mode)" = direct-PR ] \
      || { REASON='pipeline-owned or unsupported delivery mode'; return 1; }
    [ -z "$(meta_value "$meta" remote_host)" ] || { REASON='remote worker custody unsupported'; return 1; }
    [ "$(meta_value "$meta" pr)" = "$URL" ] || { REASON='unknown branch custody'; return 1; }
    wt=$(meta_value "$meta" worktree); branch=$(meta_value "$meta" branch)
    [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$branch" ] || { REASON='task copy unavailable'; return 1; }
    changed=$(bounded git -C "$wt" status --porcelain 2>/dev/null) || { REASON='task copy unreadable'; return 1; }
    [ "$(bounded git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ] \
      && [ "$changed" = '' ] || { REASON='task copy changed'; return 1; }
    overview_rc=0
    # shellcheck disable=SC2016 # The child shell receives the worktree argument.
    overview=$(bounded bash -c 'cd "$1" && no-mistakes axi' _ "$wt" 2>/dev/null) || overview_rc=$?
    case "${overview_rc:-0}" in 124|137) REASON='pipeline custody timed out'; return 1 ;; esac
    [ -n "$overview" ] || { REASON='pipeline custody unreadable'; return 1; }
    if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$overview" error)")" != "repo not initialized (run 'no-mistakes init' first)" ]; then
      [ "$overview_rc" = 0 ] || { REASON='pipeline custody unreadable'; return 1; }
      choice=$(fm_nm_select_run "$branch" "$overview" "$wt" 1)
      [ "$choice" = absent ] || { REASON='pipeline custody present or unconfirmed'; return 1; }
    fi
    raw=$(bounded env FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || { REASON='worker state unreadable'; return 1; }
    case "$raw" in 'state: done · source: status-log · '*) ;; *) REASON='worker active or readiness unconfirmed'; return 1 ;; esac
  done
}
core_read() {
  api GET "/repos/$PROJECT/pulls/$NUMBER" > "$TMP/core" || { REASON='PR read failed'; return 1; }
  jq -e --arg url "$URL" '
    .html_url == $url and (.state == "open" or .state == "closed") and (.merged | type == "boolean")
    and (.draft | type == "boolean") and (.head.sha | test("^[a-fA-F0-9]{40}$"))
    and (.base.sha | test("^[a-fA-F0-9]{40}$")) and (.base.ref | type == "string" and length > 0)
    and (.head.ref | type == "string" and length > 0) and (.head.repo.full_name | type == "string")
    and (.base.repo.full_name | type == "string") and has("auto_merge")
    and has("mergeable") and (.mergeable == null or (.mergeable | type == "boolean"))
    and (.mergeable_state | type == "string")' "$TMP/core" >/dev/null 2>&1 || { REASON='incomplete PR response'; return 1; }
  HEAD=$(jq -r '.head.sha' "$TMP/core"); BASE=$(jq -r '.base.sha' "$TMP/core")
  if [ "$(jq -r '.state' "$TMP/core")" != open ] || [ "$(jq -r '.merged' "$TMP/core")" = true ]; then PENDING=false; RESULT=terminal; REASON='closed or merged'; return 1; fi
  if [ "$(jq -r '.draft' "$TMP/core")" = true ]; then RESULT=deferred; REASON='draft'; return 1; fi
  if [ "$(jq -r '.auto_merge != null or .mergeable_state == "queued"' "$TMP/core")" = true ]; then RESULT=deferred; REASON='queued or auto-merge enabled'; return 1; fi
}
compare() { # captured base head
  api GET "/repos/$PROJECT/compare/$1...$2" > "$TMP/compare" || { REASON='comparison unavailable'; return 1; }
  jq -e '(.behind_by | type == "number" and . >= 0 and . == floor)
    and (.status | IN("ahead","behind","identical","diverged"))' "$TMP/compare" >/dev/null || { REASON='incomplete comparison'; return 1; }
}
queue_read() {
  local owner repo query
  owner=${PROJECT%%/*}; repo=${PROJECT#*/}
  query=$(printf 'query { repository(owner:"%s",name:"%s") { pullRequest(number:%s) { headRefOid mergeQueueEntry { id } } } }' "$owner" "$repo" "$NUMBER")
  api POST /graphql --field "query=$query" > "$TMP/queue" || { REASON='merge queue state unavailable'; return 1; }
  jq -e --arg head "$HEAD" '.errors == null and .data.repository.pullRequest.headRefOid == $head
    and (.data.repository.pullRequest | has("mergeQueueEntry"))' "$TMP/queue" >/dev/null || { REASON='merge queue evidence incomplete or raced'; return 1; }
  [ "$(jq -r '.data.repository.pullRequest.mergeQueueEntry == null' "$TMP/queue")" = true ] || { RESULT=deferred; REASON='merge queued'; return 1; }
}
process_pr() {
  local id old captured expected previous meta lock_path local_head proposed_receipt
  fm_pr_url_parse "$URL" || { REASON='invalid owned PR identity'; return 0; }
  [ "$FM_PR_PROVIDER" = github ] || { RESULT=deferred; REASON='unsupported forge'; return 0; }
  PROJECT=$FM_PR_PATH; NUMBER=$FM_PR_NUMBER
  lock "$STATE/.pr-autoupdate-$FM_PR_OWNER-$FM_PR_REPO-$NUMBER.lock" || { REASON='PR lock busy'; return 0; }
  for id in $OWNERS; do
    fm_pr_task_id_valid "$id" || { REASON='invalid owner'; return 0; }
    lock "$STATE/.control-$id.lock" || { REASON='task control busy'; return 0; }
    lock_path=$(fm_meta_lock_path "$STATE/$id.meta")
    lock "$lock_path" || { REASON='task metadata busy'; return 0; }
  done
  core_read || return 0
  if ! printf '%s' "$CFG" | jq -e --slurpfile core "$TMP/core" --arg url "$URL" \
    'any(.write_scope[]; .pr == $url and .head_repo == $core[0].head.repo.full_name and .head_ref == $core[0].head.ref)' >/dev/null; then
    RESULT=deferred; REASON='head branch write not authorized'; return 0
  fi
  [ "$(jq -r '.base.repo.full_name' "$TMP/core")" = "$PROJECT" ] || { REASON='base repository mismatch'; return 0; }
  custody || { RESULT=deferred; return 0; }
  for id in $OWNERS; do
    meta="$STATE/$id.meta"
    [ "$(meta_value "$meta" branch)" = "$(jq -r '.head.ref' "$TMP/core")" ] || { REASON='recorded branch does not match PR head'; return 0; }
    local_head=$(bounded git -C "$(meta_value "$meta" worktree)" rev-parse --verify HEAD 2>/dev/null) || { REASON='local head unavailable'; return 0; }
    if [ "$PENDING" = true ]; then
      if [ "$local_head" != "$(printf '%s' "$RECEIPT" | jq -r --arg id "$id" '.local_heads[$id] // ""')" ] \
        || [ "$(meta_value "$meta" pr_head)" != "$(printf '%s' "$RECEIPT" | jq -r '.old_head')" ]; then
        [ "$local_head" = "$HEAD" ] && [ "$(meta_value "$meta" pr_head)" = "$HEAD" ] \
          || { REASON='local head changed since refresh'; return 0; }
      fi
    else
      [ "$(meta_value "$meta" pr_head)" = "$HEAD" ] || { REASON='recorded ready head changed'; return 0; }
      if [ "$local_head" != "$HEAD" ]; then
        [ "$(printf '%s' "$RECEIPT" | jq -r '.result_head // ""')" = "$HEAD" ] \
          && [ "$local_head" = "$(printf '%s' "$RECEIPT" | jq -r --arg id "$id" '.local_heads[$id] // ""')" ] \
          || { REASON='local head changed since refresh'; return 0; }
      fi
    fi
  done
  if [ "$PENDING" != true ]; then
    for id in $OWNERS; do
      [ "$(meta_value "$STATE/$id.meta" pr_head)" = "$HEAD" ] || { REASON='current head has no matching ready record'; return 0; }
    done
  fi
  queue_read || return 0
  if [ "$(printf '%s' "$RECEIPT" | jq -r '.pending // false')" = true ]; then
    old=$(printf '%s' "$RECEIPT" | jq -r '.old_head'); captured=$(printf '%s' "$RECEIPT" | jq -r '.base_sha')
    PENDING=true
    compare "$captured" "$HEAD" || return 0
    if [ "$HEAD" = "$old" ] || [ "$(jq '.behind_by' "$TMP/compare")" != 0 ]; then
      if [ "$(jq -r '.mergeable' "$TMP/core")" = false ]; then
        RESULT=conflict; REASON='forge positively reports conflict after request'; return 0
      fi
      REASON='update not yet confirmed; no repeated write'; return 0
    fi
    compare "$old" "$HEAD" || return 0
    [ "$(jq '.behind_by' "$TMP/compare")" = 0 ] || { REASON='old head no longer reachable; concurrent rewrite'; return 0; }
    api GET "/repos/$PROJECT/commits/$HEAD/check-runs?per_page=100" > "$TMP/checks" || { REASON='new-head checks unavailable'; return 0; }
    jq -e --arg head "$HEAD" '(.total_count | type == "number") and (.check_runs | type == "array") and .total_count == (.check_runs | length)
      and all(.check_runs[]; .head_sha == $head and (.status | type == "string"))' "$TMP/checks" >/dev/null || { REASON='new-head check coverage incomplete'; return 0; }
    expected=$HEAD
    core_read || return 0
    [ "$HEAD" = "$expected" ] || { REASON='head changed while reading checks'; return 0; }
    compare "$BASE" "$HEAD" || return 0
    local closing_behind
    closing_behind=$(jq '.behind_by' "$TMP/compare")
    queue_read || return 0
    for id in $OWNERS; do
      meta="$STATE/$id.meta"
      awk '!/^pr_head=/' "$meta" > "$TMP/meta"
      printf 'pr_head=%s\n' "$HEAD" >> "$TMP/meta"
      write_json "$meta" "$TMP/meta"
    done
    RECEIPT=$(printf '%s' "$RECEIPT" | jq -c --slurpfile checks "$TMP/checks" --arg head "$HEAD" \
      '. + {result_head:$head,checks:{head:$head,check_runs:$checks[0].check_runs},validation:"unconfirmed; no merge authority"}')
    PENDING=false
    if [ "$closing_behind" -gt 0 ]; then
      RESULT=incomplete; REASON='captured base integrated but current base advanced'; return 0
    fi
    RESULT=updated; REASON='captured base integrated; new-head validation required'; return 0
  fi
  compare "$BASE" "$HEAD" || return 0
  [ "$(jq '.behind_by' "$TMP/compare")" -gt 0 ] || { RESULT=current; REASON='base reachable from head'; return 0; }
  case "$(jq -r '.mergeable' "$TMP/core")" in
    false) RESULT=conflict; REASON='forge positively reports conflict'; return 0 ;;
    true) ;;
    *) REASON='mergeability unknown'; return 0 ;;
  esac
  expected=$HEAD; previous=$BASE
  cp "$TMP/core" "$TMP/first-core"
  core_read || return 0
  if ! jq -e --slurpfile first "$TMP/first-core" '
    def guarded: {state,merged,draft,head:{sha:.head.sha,ref:.head.ref,repo:.head.repo.full_name},
      base:{sha:.base.sha,ref:.base.ref,repo:.base.repo.full_name},auto_merge,mergeable,mergeable_state}; guarded == ($first[0] | guarded)' "$TMP/core" >/dev/null; then REASON='PR changed before update'; return 0; fi
  [ $((DEADLINE - $(date +%s))) -ge 4 ] || { REASON='segment budget exhausted before publication'; return 0; }
  proposed_receipt=$(jq -cn --arg head "$expected" --arg base "$previous" --slurpfile core "$TMP/core" \
    '{old_head:$head,base_sha:$base,base_ref:$core[0].base.ref,head_ref:$core[0].head.ref,head_repo:$core[0].head.repo.full_name,pending:true}')
  for id in $OWNERS; do
    local_head=$(bounded git -C "$(meta_value "$STATE/$id.meta" worktree)" rev-parse --verify HEAD 2>/dev/null) || { REASON='local head unavailable'; return 0; }
    proposed_receipt=$(printf '%s' "$proposed_receipt" | jq -c --arg id "$id" --arg head "$local_head" '.local_heads[$id]=$head')
  done
  queue_read || return 0
  RECEIPT=$proposed_receipt
  PENDING=true; RESULT=pending; REASON='request prepared; awaiting confirmed head'
  record_result # Durable before the outward-facing side effect.
  jq -n --arg head "$expected" '{expected_head_sha:$head}' > "$TMP/request"
  local put_rc=0
  api PUT "/repos/$PROJECT/pulls/$NUMBER/update-branch" --input "$TMP/request" > "$TMP/put" || put_rc=$?
  if [ "$put_rc" -eq 0 ]; then
    REASON='update accepted; awaiting confirmed head'
  elif [ "$put_rc" -eq 22 ]; then
    PENDING=false; RESULT=incomplete; REASON='update refused with HTTP 422; re-observe PR before retry'
  else
    RESULT=incomplete; REASON='update request failed or uncertain; re-observe without repeated write'
  fi
}
record_result() {
  local signal previous_signal
  signal="$RESULT|$REASON|$HEAD|$BASE"
  previous_signal=$(printf '%s' "$RECEIPT" | jq -r '.signal // ""')
  jq --arg url "$URL" --arg result "$RESULT" --arg reason "$REASON" --arg head "$HEAD" --arg base "$BASE" \
    --arg signal "$signal" --argjson now "$NOW" --argjson pending "$PENDING" --argjson receipt "$RECEIPT" '
    .receipts[$url]=($receipt + {url:$url,result:$result,reason:$reason,observed_head:$head,observed_base:$base,
      checked_at:$now,pending:$pending,signal:$signal})' "$TMP/journal" > "$TMP/new"
  mv "$TMP/new" "$TMP/journal"; save
  if [ "$previous_signal" != "$signal" ]; then
    case "$RESULT" in current|terminal|pending) ;; *) printf 'pr-autoupdate: %s %s: %s\n' "$RESULT" "$URL" "$REASON" ;; esac
  fi
}
process_pr
record_result
jq --argjson pending "$PENDING" --arg result "$RESULT" '.queue = (.queue[1:] + (if $pending or $result == "incomplete" then [.queue[0]] else [] end)) |
  . as $journal | .coverage_complete=((.queue | length) == 0 and
    all(.sweep_urls[]; . as $url | $journal.receipts[$url].result | IN("current","terminal","updated")))' "$TMP/journal" > "$TMP/new"
mv "$TMP/new" "$TMP/journal"; save
