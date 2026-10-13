#!/usr/bin/env bash
# Validate or spawn a single code-only worker in the dedicated Boat overflow home.
# Usage: fm-boat-worker.sh validate|spawn < request.json; teardown <task-id>.
#
# One JSON object, <=65536 bytes, with exactly these required fields:
#   id: safe task id; project: firstmate|dev-loop; kind: ship|scout;
#   mode: direct-PR|no-mistakes for ship, "scout" for scout;
#   intent, spec: nonempty task text, already labelled code-only by firstmate;
#   harness: claude|codex|grok; model: concrete nonempty model; effort:
#   low|medium|high|xhigh|max|ultra. These are the profile selected by firstmate
#   under its ordinary dispatch/quota rules, never an alternate quota budget.
# No other keys (including env, secrets, home, origin, yolo, flags) are accepted.
#
# validate is pure, usable before Boat is contacted. spawn requires the seeded
# boat-eng identity, safe operational directories, and allowlisted project
# clones. It generates a normal remote brief and uses fm-spawn.sh, forcing yolo
# off and a three-worker box-wide cap under one lock. An id without a spawn
# record may be retried; unknown transport completion must be reconciled.
# no-mistakes requires the operator's config/boat-no-mistakes-proven receipt:
# one successful proof PR URL after a real box pipeline, plus an installed CLI.
# Neither validation nor dispatch manufactures that proof or downgrades a mode.
#
# Inspect/steer/report through fm-on.sh boat-eng with existing fm-crew-state.sh,
# fm-peek.sh, fm-send.sh, and fm-remote-file.sh; task teardown uses fm-teardown.sh.
# No merges, home transfer, secret injection, or new supervision loop is added.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
case "${1:-}" in
  --help) sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
  validate|spawn) [ "$#" -eq 1 ] || die 'one operation required' ;;
  teardown) [ "$#" -eq 2 ] || die 'task id required' ;;
  *) die 'expected validate, spawn, or teardown' ;;
esac
if [ "$1" = teardown ]; then
  FM_HOME=${FM_HOME:?FM_HOME is required}
  ID=$2
  case "$ID" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'invalid task id' ;; esac
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] &&
    [ "$(cat "$FM_HOME/.fm-secondmate-home")" = boat-eng ] || die 'not the purpose-built boat-eng home'
  [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || die 'unsafe overflow state directory'
  fm_lock_acquire_wait "$FM_HOME/state/.boat-worker.lock" || die 'overflow teardown lock unavailable'
  trap 'fm_lock_release "$FM_HOME/state/.boat-worker.lock" || true' EXIT
  [ -f "$FM_HOME/state/$ID.meta" ] && [ ! -L "$FM_HOME/state/$ID.meta" ] || die 'task has no safe spawn record; reconcile before teardown'
  kind=$(sed -n 's/^kind=//p' "$FM_HOME/state/$ID.meta")
  project=$(sed -n 's/^project=//p' "$FM_HOME/state/$ID.meta")
  case "$kind:$project" in ship:firstmate|ship:dev-loop|scout:firstmate|scout:dev-loop) ;; *) die 'task is not an allowed Boat worker' ;; esac
  "$SCRIPT_DIR/fm-teardown.sh" "$ID" >&2
  for meta in "$FM_HOME/state/"*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    printf 'boat-tasks-remaining: yes\n'
    exit 0
  done
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
  (keys == ["effort","harness","id","intent","kind","mode","model","project","spec"]) and
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
COUNT=0
for meta in "$FM_HOME/state/"*.meta; do
  [ -e "$meta" ] || continue
  [ -f "$meta" ] && [ ! -L "$meta" ] || die 'unsafe worker metadata'
  kind=$(sed -n 's/^kind=//p' "$meta")
  [ "$kind" = secondmate ] && continue
  # Retained records reserve a slot until ordinary teardown, including finished
  # agents whose panes can still hold a process. Unknown state never frees one.
  COUNT=$((COUNT + 1))
done
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
if [ "$MODE" != scout ]; then ARGS+=(--yolo off); fi
ARGS+=(--harness "$(jq -r .harness "$TMP/request")" --model "$(jq -r .model "$TMP/request")" --effort "$(jq -r .effort "$TMP/request")")
"$SCRIPT_DIR/fm-spawn.sh" "$ID" "$REPO" "${ARGS[@]}"
printf 'boat-task: %s project=%s mode=%s route=boat-eng\n' "$ID" "$PROJECT" "$MODE"
