#!/usr/bin/env bash
# Validate or spawn a single code-only worker in the dedicated Boat overflow home.
# Usage: fm-boat-worker.sh validate < request.json
#        fm-boat-worker.sh spawn <box-instance> < request.json
#        fm-boat-worker.sh teardown <task-id> <box-instance>
#        fm-boat-worker.sh idle <box-instance>
#
# One JSON object, <=65536 bytes, with exactly these required fields:
#   id: safe task id; project: firstmate|dev-loop; kind: ship|scout;
#   mode: direct-PR|no-mistakes for ship, "scout" for scout;
#   intent, spec: nonempty task text, already labelled code-only by firstmate;
#   harness: claude|codex|grok; model: concrete nonempty model; effort:
#   low|medium|high|xhigh|max|ultra. These are the profile selected by firstmate
#   under its ordinary dispatch/quota rules, never an alternate quota budget.
# Optional paired git_name/git_email are non-secret per-worker Git identity.
# Ships require both at spawn; validate and scouts may omit them.
# No other keys (including env, secrets, home, origin, yolo, flags) are accepted.
#
# validate is pure, usable before Boat is contacted. spawn requires the seeded
# boat-eng identity, safe operational directories, and allowlisted project
# clones. It generates a normal remote brief and uses fm-spawn.sh, forcing yolo
# off and a three-worker box-wide cap under one lock. Boat uses the configured
# tmux backend and its firstmate session; other runtimes refuse dispatch.
# Commands require the detached remote environment, outside any tmux session,
# so ordinary spawn and inventory both target the exact firstmate session.
# Capacity counts distinct task IDs across retained worker records and live
# fm-* windows from one backend inventory read; unreadable inventory refuses.
# Stop is allowed only when both counts are zero.
# An id may be retried only without a spawn record or matching live endpoint;
# unknown transport completion
# must be reconciled before reusing its id or rewriting its briefs.
# idle reports whether any worker records or endpoints remain under that lock.
# Before spawn, intake adds a missing backlog item through fm-tasks-axi.sh;
# an existing item must be dispatchable and match kind and project before its
# brief can be rewritten. Ordinary spawn owns its In flight transition.
# no-mistakes requires the operator's config/boat-no-mistakes-proven receipt:
# one successful proof PR URL after a real box pipeline, plus an installed CLI.
# Neither validation nor dispatch manufactures that proof or downgrades a mode.
#
# Inspect/steer/report through fm-on.sh boat-eng with existing fm-crew-state.sh,
# fm-peek.sh, fm-send.sh, and fm-remote-file.sh; task teardown uses fm-teardown.sh.
# Dispatch success requires a fresh worker status declaration within 120 polls
# (one second apart; FM_BOAT_START_POLLS and FM_BOAT_START_INTERVAL override).
# Codex directory trust is accepted once with Enter from the visible viewport;
# missing proof leaves the task intact for same-id reconciliation, never retry.
# Scout teardown requires a controller-reviewed completion inventory; refusal
# prints the exact controller command rather than manufacturing --none consent.
# Ships require gh-axi and a valid supplied Git identity before backlog intake;
# fm-spawn.sh applies the identity only to the isolated worker worktree.
# No merges, home transfer, secret injection, or new supervision loop is added.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
boat_runtime() {
  [ -z "${TMUX:-}" ] || die 'Boat worker commands must run outside tmux through the remote transport'
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  [ "$(fm_backend_name)" = tmux ] || die 'Boat worker inventory requires the tmux backend'
  fm_backend_source tmux || die 'Boat tmux adapter unavailable'
}
boat_worker_count() { # [new task id, refused if its endpoint already exists]
  local meta id records='' windows status=0
  for meta in "$FM_HOME/state/"*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || die 'unsafe worker metadata'
    if [ "$(sed -n 's/^kind=//p' "$meta")" != secondmate ]; then
      id=${meta##*/}
      id=${id%.meta}
      case "$id" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'unsafe worker metadata' ;; esac
      records="${records}fm-$id"$'\n'
    fi
  done
  windows=$(fm_backend_tmux_window_inventory '=firstmate') || status=$?
  case "$status" in 0) ;; 2) windows= ;; *) die 'Boat worker endpoint inventory unavailable' ;; esac
  if [ -n "${1:-}" ] && printf '%s\n' "$windows" | grep -Fxq -- "fm-$1"; then
    die 'task id has a live endpoint; reconcile before retry'
  fi
  printf '%s\n%s\n' "$records" "$windows" | awk '/^fm-/ && !seen[$0]++ { n++ } END { print n+0 }'
}
case "${1:-}" in
  --help) sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
  validate) [ "$#" -eq 1 ] || die 'one operation required' ;;
  spawn) [ "$#" -eq 2 ] || die 'box instance required' ;;
  teardown) [ "$#" -eq 3 ] || die 'task id and box instance required' ;;
  idle) [ "$#" -eq 2 ] || die 'box instance required' ;;
  *) die 'expected validate, spawn, teardown, or idle' ;;
esac
if [ "$1" != validate ]; then
  expected_instance=${!#}
  [[ "$expected_instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'invalid box instance'
  [ "$(cat /proc/sys/kernel/random/boot_id)" = "$expected_instance" ] || die 'Boat instance changed; action refused'
fi
if [ "$1" = teardown ] || [ "$1" = idle ]; then
  FM_HOME=${FM_HOME:?FM_HOME is required}
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] &&
    [ "$(cat "$FM_HOME/.fm-secondmate-home")" = boat-eng ] || die 'not the purpose-built boat-eng home'
  [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || die 'unsafe overflow state directory'
  boat_runtime
  fm_lock_acquire_wait "$FM_HOME/state/.boat-worker.lock" || die 'overflow teardown lock unavailable'
  trap 'fm_lock_release "$FM_HOME/state/.boat-worker.lock" || true' EXIT
  if [ "$1" = teardown ]; then
    ID=$2
    case "$ID" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'invalid task id' ;; esac
    [ -f "$FM_HOME/state/$ID.meta" ] && [ ! -L "$FM_HOME/state/$ID.meta" ] || die 'task has no safe spawn record; reconcile before teardown'
    kind=$(sed -n 's/^kind=//p' "$FM_HOME/state/$ID.meta")
    project=$(sed -n 's/^project=//p' "$FM_HOME/state/$ID.meta")
    case "$kind" in ship|scout) ;; *) die 'task is not an allowed Boat worker' ;; esac
    case "$project" in "$FM_HOME/projects/firstmate"|"$FM_HOME/projects/dev-loop") ;; *) die 'task is not an allowed Boat worker' ;; esac
    [ "$(fm_backend_of_meta "$FM_HOME/state/$ID.meta")" = tmux ] || die 'Boat teardown requires a tmux worker'
    if [ "$kind" = scout ] && ! "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >&2; then
      die "scout completion inventory required; after reviewing unresolved calls, run from the controller: fm-on.sh boat-eng fm-captain-hold.sh complete $ID --none (or list the held task ids instead of --none)"
    fi
    "$SCRIPT_DIR/fm-teardown.sh" "$ID" >&2
  fi
  COUNT=$(boat_worker_count) || exit 1
  if [ "$COUNT" -ne 0 ]; then
    printf 'boat-tasks-remaining: yes\n'
    exit 0
  fi
  printf 'boat-tasks-remaining: no\n'
  exit 0
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-boat-worker.XXXXXX")
LOCK=
cleanup() {
  rm -rf -- "$TMP"
  [ -z "$LOCK" ] || fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
head -c 65537 > "$TMP/request"
[ "$(wc -c < "$TMP/request")" -le 65536 ] || die 'request exceeds 65536 bytes'
jq -es '
  def text: type == "string" and length > 0 and (test("[\u0000-\u0008\u000b-\u001f]") | not);
  length == 1 and (.[0] | type == "object" and
  ((keys - ["git_name","git_email"]) == ["effort","harness","id","intent","kind","mode","model","project","spec"]) and
  ((has("git_name") | not) and (has("git_email") | not) or
   ((.git_name | type == "string" and test("^[^\u0000-\u001f\u007f<>]+$") and test("[^ ]")) and
    (.git_email | type == "string" and test("^[^\u0000-\u0020\u007f<>]+@[^\u0000-\u0020\u007f<>]+$")))) and
  (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  (.project == "firstmate" or .project == "dev-loop") and
  ((.kind == "ship" and (.mode == "direct-PR" or .mode == "no-mistakes")) or
   (.kind == "scout" and .mode == "scout")) and
  (.intent | text) and (.spec | text) and (.model | text) and
  (.harness == "claude" or .harness == "codex" or .harness == "grok") and
  (.effort | IN("low","medium","high","xhigh","max","ultra")))
' "$TMP/request" >/dev/null 2>&1 || die 'invalid code-only Boat request'
[ "$1" = spawn ] || exit 0
FM_HOME=${FM_HOME:?FM_HOME is required}
[ "$(cd "$FM_HOME" && pwd -P)" = "$FM_HOME" ] || die 'overflow home must be canonical'
[ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] &&
  [ "$(cat "$FM_HOME/.fm-secondmate-home")" = boat-eng ] || die 'not the purpose-built boat-eng home'
for dir in data state config projects; do
  [ -d "$FM_HOME/$dir" ] && [ ! -L "$FM_HOME/$dir" ] || die "unsafe overflow $dir directory"
done
boat_runtime
fm_lock_acquire_wait "$FM_HOME/state/.boat-worker.lock" || die 'overflow dispatch lock unavailable'
LOCK="$FM_HOME/state/.boat-worker.lock"
ID=$(jq -r .id "$TMP/request")
PROJECT=$(jq -r .project "$TMP/request")
MODE=$(jq -r .mode "$TMP/request")
[ ! -e "$FM_HOME/state/$ID.meta" ] && [ ! -L "$FM_HOME/state/$ID.meta" ] || die 'task id already exists; reconcile before retry'
[ ! -L "$FM_HOME/data/$ID" ] || die 'unsafe task data directory'
if [ "$MODE" = no-mistakes ]; then
  PROOF="$FM_HOME/config/boat-no-mistakes-proven"
  if [ -f "$PROOF" ] && [ ! -L "$PROOF" ] &&
    jq -Rse 'test("^https://github.com/LeadGrowGTM/(firstmate|dev-loop)/pull/[0-9]+\\n?$")' "$PROOF" >/dev/null &&
    command -v no-mistakes >/dev/null; then
    :
  else
    die 'no-mistakes has not been proven on this box'
  fi
fi
COUNT=$(boat_worker_count "$ID") || exit 1
[ "$COUNT" -lt 3 ] || { printf 'error: Boat three-worker cap reached\n' >&2; exit 75; }
REPO="$FM_HOME/projects/$PROJECT"
[ -d "$REPO" ] && [ ! -L "$REPO" ] && [ "$(cd "$REPO" && pwd -P)" = "$REPO" ] || die 'project clone is unavailable or unsafe'
origin=$(git -C "$REPO" remote get-url origin) || die 'project origin unavailable'
case "$origin" in
  "https://github.com/LeadGrowGTM/$PROJECT.git"|"https://github.com/LeadGrowGTM/$PROJECT"|"git@github.com:LeadGrowGTM/$PROJECT.git") ;;
  *) die 'project origin is not the allowlisted fork' ;;
esac
[ -z "$(git -C "$REPO" ls-files -- 'clients' '.env' '**/.env')" ] || die 'project tracks client or secret files'
[ ! -e "$REPO/clients" ] && [ ! -e "$REPO/.env" ] || die 'project contains private client or secret paths'
if [ "$MODE" != scout ]; then
  command -v gh-axi >/dev/null || die 'ship requires gh-axi installed on the Boat box'
  GIT_NAME=$(jq -r '.git_name // empty' "$TMP/request")
  GIT_EMAIL=$(jq -r '.git_email // empty' "$TMP/request")
  [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ] || die 'ship requires git committer name and email supplied by the controller'
  git -C "$REPO" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" var GIT_COMMITTER_IDENT >/dev/null 2>&1 || die 'ship git committer identity is invalid'
fi
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if fm_backlog_row_probe "$FM_HOME/data" "$ID"; then
  fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" || die 'existing backlog item is not dispatchable'
  [ "$FM_BACKLOG_ROW_KIND" = "$(jq -r .kind "$TMP/request")" ] &&
    [ "$FM_BACKLOG_ROW_REPO" = "$PROJECT" ] || die 'existing backlog item kind or project differs from request'
elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
  fm_run_timed 30 "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "Boat $PROJECT $ID" \
    --kind "$(jq -r .kind "$TMP/request")" --repo "$PROJECT" --queue >/dev/null || die 'remote backlog intake failed'
else
  die "remote backlog intake unavailable: $FM_BACKLOG_ROW_ERROR"
fi
ARGS=()
if [ "$MODE" = scout ]; then ARGS+=(--scout); else ARGS+=(--mode "$MODE"); fi
FM_BOAT_REWRITE_BRIEF=boat-eng "$SCRIPT_DIR/fm-brief.sh" "$ID" "$PROJECT" "${ARGS[@]}" >/dev/null
BRIEF="$FM_HOME/data/$ID/brief.md"
# Only code-only task prose crosses the wire. Generate operational paths here,
# rather than accepting a PC brief that mentions or exposes another home.
jq -r '.intent' "$TMP/request" > "$TMP/intent"
jq -r '.spec' "$TMP/request" > "$TMP/spec"
cat >> "$TMP/spec" <<'RULES'

This is a code-only Boat overflow run. Never read secrets, .env, client data,
other mates' homes, desktop/browser state, or use lg or boat env. Never merge,
deploy, publish, or contact the captain. Report only through the task status
and steering paths generated in this brief. Route any decision to firstmate.
RULES
awk -v intent="$TMP/intent" -v spec="$TMP/spec" '
  $0 == "{TASK}" { while ((getline line < intent) > 0) print line; close(intent); next }
  $0 == "{FIRSTMATE_SPEC}" { while ((getline line < spec) > 0) print line; close(spec); next }
  { print }
' "$BRIEF" > "$TMP/brief"
cat "$TMP/brief" > "$BRIEF"
if [ "$MODE" != scout ]; then ARGS+=(--yolo off --git-name "$GIT_NAME" --git-email "$GIT_EMAIL"); fi
ARGS+=(--backend tmux --harness "$(jq -r .harness "$TMP/request")" --model "$(jq -r .model "$TMP/request")" --effort "$(jq -r .effort "$TMP/request")")
STATUS="$FM_HOME/state/$ID.status"
STATUS_LINES=0
if [ -L "$STATUS" ] || { [ -e "$STATUS" ] && [ ! -f "$STATUS" ]; }; then
  die 'unsafe worker status path'
fi
if [ -f "$STATUS" ]; then STATUS_LINES=$(wc -l < "$STATUS"); fi
"$SCRIPT_DIR/fm-spawn.sh" "$ID" "$REPO" "${ARGS[@]}" >&2
# A spawned pane is not proof that the brief was consumed. Only a new worker
# declaration counts; captures and trust-key delivery cannot supply start proof.
polls=${FM_BOAT_START_POLLS:-120}
interval=${FM_BOAT_START_INTERVAL:-1}
case "$polls" in ''|*[!0-9]*|0) die 'invalid Boat start poll limit' ;; esac
trust_answered=0
trust_seen=0
harness=$(jq -r .harness "$TMP/request")
for ((poll=0; poll<polls; poll++)); do
  if [ -f "$STATUS" ] && tail -n "+$((STATUS_LINES + 1))" "$STATUS" |
    grep -Eq '^(failed|blocked|needs-decision) \[at=[0-9]+\].*: '; then
    die "worker $ID declared a failure or decision before start confirmation; reconcile its status"
  fi
  if [ -f "$STATUS" ] && tail -n "+$((STATUS_LINES + 1))" "$STATUS" |
    grep -Eq '^(working|paused|done) \[at=[0-9]+\].*: '; then
    printf 'boat-started: %s (fresh worker status)\n' "$ID"
    break
  fi
  pane=$(fm_backend_tmux_visible_capture "=firstmate:=fm-$ID") || die "worker start unconfirmed: viewport unavailable for $ID; reconcile the existing task before retry"
  if [ "$harness" = codex ] && printf '%s\n' "$pane" |
    grep -Eq '^[[:space:]]*(Do you trust the contents of this directory\?|Trust this folder\?)[[:space:]]*$'; then
    trust_seen=1
  fi
  if [ "$harness" = codex ] &&
    printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*(Do you trust the contents of this directory\?|Trust this folder\?)[[:space:]]*$' &&
    printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*[›❯>][[:space:]]*(1\.[[:space:]]*)?Yes, (I trust this folder|allow Codex to work in this folder)[[:space:]]*$' &&
    printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*(2\.[[:space:]]*)?No, exit[[:space:]]*$' &&
    ! printf '%s\n' "$pane" | grep -Fq 'FIRSTMATE_OP:'; then
    if [ "$trust_answered" -eq 0 ]; then
      fm_backend_tmux_send_key "=firstmate:=fm-$ID" Enter || die "Codex folder-trust dialog could not be answered for $ID"
      trust_answered=1
    fi
  fi
  if [ "$poll" -lt "$((polls - 1))" ]; then sleep "$interval"; fi
done
if [ "$poll" -eq "$polls" ]; then
  if [ "$trust_seen" -eq 1 ]; then
    version=$(codex --version 2>/dev/null || printf 'version unavailable')
    die "Codex folder-trust start unconfirmed for $ID ($version, Enter sent=$trust_answered); reconcile the existing task before retry"
  fi
  die "worker start unconfirmed for $ID; inspect with fm-on.sh boat-eng fm-peek.sh $ID and reconcile before retry"
fi
printf 'boat-task: %s project=%s mode=%s route=boat-eng\n' "$ID" "$PROJECT" "$MODE"
