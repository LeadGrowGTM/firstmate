#!/usr/bin/env bash
# Validate or spawn a single code-only worker in the dedicated Boat overflow home.
# Usage: fm-boat-worker.sh validate < request.json
#        fm-boat-worker.sh spawn <box-instance> < request.json
#        fm-boat-worker.sh teardown <task-id> <box-instance>
#        fm-boat-worker.sh idle <box-instance>
#        fm-boat-worker.sh endpoints <box-instance>
#        fm-boat-worker.sh retire-claim <task-id> <box-instance>
#
# One JSON object, <=65536 bytes, with exactly these required fields:
#   id: safe task id; project: a name allowed by config/boat-projects (below);
#   kind: ship|scout;
#   mode: direct-PR|no-mistakes for ship, "scout" for scout;
#   intent, spec: nonempty task text, already labelled code-only by firstmate;
#   harness: claude|codex|grok; model: concrete nonempty model; effort:
#   low|medium|high|xhigh|max|ultra. These are the profile selected by firstmate
#   under its ordinary dispatch/quota rules, never an alternate quota budget.
# No other keys (including git_name, git_email, env, secrets, home, origin,
# yolo, flags) are accepted.
# Git identity never comes from the controller.
#
# Allowed projects: config/boat-projects in the home running the command, one
# entry per line as `<project> [<github-owner>]` (owner defaults to LeadGrowGTM;
# `#` comments and blank lines ignored); with no file, firstmate and dev-loop.
# This is the single owner of which projects may run on Boat. The controller
# validates against its own copy and the box against its own, so a project runs
# only where both list it and the box holds a clone whose origin is
# github.com/<owner>/<project>. A gtm-client-* name is refused whatever the file
# says, an unreadable or malformed file refuses every request, and a clone that
# tracks clients/ or a dot-env file is refused at spawn. Adding a name is a
# captain decision (R6), not something dispatch does.
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
# A retained record stops counting only when its endpoint is absent and its
# last status is terminal (done, failed, blocked, needs-decision) or stale
# (a readable status time at least FM_BOAT_RECORD_STALE_SECS old, default
# 86400); each such record is reported by name on stderr. A record with a
# live endpoint, a fresh nonterminal status, or no readable status at all
# always counts, so an unproven record keeps its slot. Stop is allowed only
# when the counted total is zero.
# retire-claim is the box-side records-only cleanup for such a record: it
# refuses a live endpoint or a fresh nonterminal status, archives the record
# under data/<task-id>/, and removes only state/<task-id>.meta; it never
# touches a worktree, an endpoint, or the backlog. Run it from the controller
# as fm-on.sh boat-eng fm-boat-worker.sh retire-claim <task-id> <instance>.
# An id may be retried only without a spawn record or matching live endpoint;
# unknown transport completion
# must be reconciled before reusing its id or rewriting its briefs.
# idle reports whether any worker records or endpoints remain under that lock.
# endpoints reports only whether a live fm-* worker window exists under that
# lock, as `boat-endpoints-live: yes|no`; fm-boat-send.sh uses it before
# stopping a box it resumed after a three-worker cap refusal.
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
# Codex directory-trust text is not auto-answered; missing start proof leaves
# the task intact for same-id reconciliation, never retry.
# Scout teardown requires a completed captain-hold inventory; refusal
# prints the exact controller command rather than manufacturing --none consent.
# Every worker, including scouts, requires gh-axi and a valid injected on-box
# GitHub account matching config/boat-github-account.json by numeric id before
# backlog intake. gh-axi api /user supplies only login/id;
# its --jq scalar is read from its exact untruncated api_response envelope.
# The account login and <numeric-id>+<login>@users.noreply.github.com become
# --git-name/--git-email; fm-spawn.sh applies them only to the isolated worktree.
# No merges, home transfer, secret injection, or new supervision loop is added.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# boat_project_owner <name>: prints the GitHub owner allowed for <name> on Boat,
# or returns 1 when <name> may not run here (see "Allowed projects" above).
boat_project_owner() { # <project-name>
  local name=$1 file line entry owner extra listed=0 found=''
  case "$name" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*|gtm-client-*) return 1 ;; esac
  file="${FM_HOME:-}/config/boat-projects"
  if [ -z "${FM_HOME:-}" ] || { [ ! -e "$file" ] && [ ! -L "$file" ]; }; then
    [ "$name" = firstmate ] || [ "$name" = dev-loop ] || return 1
    printf 'LeadGrowGTM\n'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] && [ "$(wc -c < "$file")" -le 4096 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    entry='' owner='' extra=''
    read -r entry owner extra <<< "$line"
    [ -n "$entry" ] && [ -z "$extra" ] || return 1
    case "$entry" in *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) return 1 ;; esac
    owner=${owner:-LeadGrowGTM}
    case "$owner" in *[!A-Za-z0-9-]*|-*) return 1 ;; esac
    listed=1
    [ "$entry" != "$name" ] || found=$owner
  done < "$file"
  [ "$listed" -eq 1 ] && [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
boat_runtime() {
  [ -z "${TMUX:-}" ] || die 'Boat worker commands must run outside tmux through the remote transport'
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  [ "$(fm_backend_name)" = tmux ] || die 'Boat worker inventory requires the tmux backend'
  fm_backend_source tmux || die 'Boat tmux adapter unavailable'
}
# boat_record_not_counted <id> <windows>: returns 0 and reports the record by
# name on stderr when it must not count toward the cap: its endpoint is absent
# and its last status is terminal or stale. Returns 1 when it counts.
boat_record_not_counted() { # <task-id> <windows>
  local id=$1 windows=$2 status_file line verb epoch now stale_secs
  if printf '%s\n' "$windows" | grep -Fxq -- "fm-$id"; then
    return 1
  fi
  stale_secs=${FM_BOAT_RECORD_STALE_SECS:-86400}
  case "$stale_secs" in ''|*[!0-9]*|0) die 'FM_BOAT_RECORD_STALE_SECS must be a whole number of seconds above 0' ;; esac
  status_file="$FM_HOME/state/$id.status"
  if [ -L "$status_file" ]; then
    return 1
  fi
  if [ ! -f "$status_file" ]; then
    return 1
  fi
  line=$(last_status_line "$status_file")
  if [ -z "$line" ]; then
    return 1
  fi
  verb=''
  status_line_verb "$line" verb
  case "$verb" in
    done|failed|blocked|needs-decision)
      printf 'boat-stale-record: %s not counted (endpoint absent, status terminal: %s)\n' "$id" "$verb" >&2
      return 0
      ;;
  esac
  epoch=$(status_line_at_epoch "$line" 2>/dev/null) || epoch=''
  if [ -z "$epoch" ]; then
    return 1
  fi
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) die 'could not read the current time' ;; esac
  if [ $((now - epoch)) -ge "$stale_secs" ]; then
    printf 'boat-stale-record: %s not counted (endpoint absent, status stale: last status %ss ago)\n' "$id" "$((now - epoch))" >&2
    return 0
  fi
  return 1
}
boat_worker_count() { # [new task id, refused if its endpoint already exists]
  local meta id records='' windows status=0
  windows=$(fm_backend_tmux_window_inventory '=firstmate') || status=$?
  case "$status" in 0) ;; 2) windows= ;; *) die 'Boat worker endpoint inventory unavailable' ;; esac
  if [ -n "${1:-}" ] && printf '%s\n' "$windows" | grep -Fxq -- "fm-$1"; then
    die 'task id has a live endpoint; reconcile before retry'
  fi
  for meta in "$FM_HOME/state/"*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || die 'unsafe worker metadata'
    if [ "$(sed -n 's/^kind=//p' "$meta")" != secondmate ]; then
      id=${meta##*/}
      id=${id%.meta}
      case "$id" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'unsafe worker metadata' ;; esac
      if boat_record_not_counted "$id" "$windows"; then
        continue
      fi
      records="${records}fm-$id"$'\n'
    fi
  done
  printf '%s\n%s\n' "$records" "$windows" | awk '/^fm-/ && !seen[$0]++ { n++ } END { print n+0 }'
}
case "${1:-}" in
  --help) sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
  validate) [ "$#" -eq 1 ] || die 'one operation required' ;;
  spawn) [ "$#" -eq 2 ] || die 'box instance required' ;;
  teardown) [ "$#" -eq 3 ] || die 'task id and box instance required' ;;
  idle|endpoints) [ "$#" -eq 2 ] || die 'box instance required' ;;
  retire-claim|--retire-claim) [ "$#" -eq 3 ] || die 'task id and box instance required' ;;
  *) die 'expected validate, spawn, teardown, idle, endpoints, or retire-claim' ;;
esac
if [ "$1" != validate ]; then
  expected_instance=${!#}
  [[ "$expected_instance" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'invalid box instance'
  [ "$(cat /proc/sys/kernel/random/boot_id)" = "$expected_instance" ] || die 'Boat instance changed; action refused'
fi
if [ "$1" = teardown ] || [ "$1" = idle ] || [ "$1" = endpoints ] || [ "$1" = retire-claim ] || [ "$1" = --retire-claim ]; then
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
    if [ "$project" != "$FM_HOME/projects/${project#"$FM_HOME/projects/"}" ] ||
      ! boat_project_owner "${project#"$FM_HOME/projects/"}" >/dev/null; then
      die 'task is not an allowed Boat worker'
    fi
    [ "$(fm_backend_of_meta "$FM_HOME/state/$ID.meta")" = tmux ] || die 'Boat teardown requires a tmux worker'
    if [ "$kind" = scout ] && ! "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >&2; then
      die "scout completion inventory required; after reviewing unresolved calls, run from the controller: fm-on.sh boat-eng fm-captain-hold.sh complete $ID --none (or list the held task ids instead of --none)"
    fi
    "$SCRIPT_DIR/fm-teardown.sh" "$ID" >&2
  fi
  if [ "$1" = retire-claim ] || [ "$1" = --retire-claim ]; then
    ID=$2
    case "$ID" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'invalid task id' ;; esac
    [ -f "$FM_HOME/state/$ID.meta" ] && [ ! -L "$FM_HOME/state/$ID.meta" ] || die 'task has no safe spawn record; reconcile before retire-claim'
    kind=$(sed -n 's/^kind=//p' "$FM_HOME/state/$ID.meta")
    project=$(sed -n 's/^project=//p' "$FM_HOME/state/$ID.meta")
    case "$kind" in ship|scout) ;; *) die 'task is not an allowed Boat worker' ;; esac
    if [ "$project" != "$FM_HOME/projects/${project#"$FM_HOME/projects/"}" ] ||
      ! boat_project_owner "${project#"$FM_HOME/projects/"}" >/dev/null; then
      die 'task is not an allowed Boat worker'
    fi
    windows=$(fm_backend_tmux_window_inventory '=firstmate') || windows_status=$?
    case "${windows_status:-0}" in 0) ;; 2) windows= ;; *) die 'Boat worker endpoint inventory unavailable' ;; esac
    boat_record_not_counted "$ID" "$windows" || die 'task has a live endpoint or a fresh nonterminal status; retire-claim refused'
    if [ ! -e "$FM_HOME/data/$ID" ] && [ ! -L "$FM_HOME/data/$ID" ]; then
      mkdir -p -- "$FM_HOME/data/$ID" || die 'could not create the task data directory'
    fi
    [ -d "$FM_HOME/data/$ID" ] && [ ! -L "$FM_HOME/data/$ID" ] || die 'task data directory is unavailable or unsafe'
    archive="$FM_HOME/data/$ID/retired-boat-record.$(date +%s).meta"
    [ ! -e "$archive" ] && [ ! -L "$archive" ] || die 'retired record archive already exists; retry retire-claim'
    cp -- "$FM_HOME/state/$ID.meta" "$archive" || die 'could not archive the worker record'
    rm -f -- "$FM_HOME/state/$ID.meta"
    printf 'retired boat record: %s (archived %s)\n' "$ID" "$archive"
  fi
  if [ "$1" = endpoints ]; then
    windows=$(fm_backend_tmux_window_inventory '=firstmate') || windows_status=$?
    case "${windows_status:-0}" in 0) ;; 2) windows= ;; *) die 'Boat worker endpoint inventory unavailable' ;; esac
    if printf '%s\n' "$windows" | grep -q '^fm-'; then
      printf 'boat-endpoints-live: yes\n'
    else
      printf 'boat-endpoints-live: no\n'
    fi
    exit 0
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
  (keys == ["effort","harness","id","intent","kind","mode","model","project","spec"]) and
  (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  (.project | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  ((.kind == "ship" and (.mode == "direct-PR" or .mode == "no-mistakes")) or
   (.kind == "scout" and .mode == "scout")) and
  (.intent | text) and (.spec | text) and (.model | text) and
  (.harness == "claude" or .harness == "codex" or .harness == "grok") and
  (.effort | IN("low","medium","high","xhigh","max","ultra")))
' "$TMP/request" >/dev/null 2>&1 || die 'invalid code-only Boat request'
OWNER=$(boat_project_owner "$(jq -r .project "$TMP/request")") ||
  die 'invalid code-only Boat request: project is not allowed on Boat'
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
  "https://github.com/$OWNER/$PROJECT.git"|"https://github.com/$OWNER/$PROJECT"|"git@github.com:$OWNER/$PROJECT.git") ;;
  *) die 'project origin is not the allowlisted fork' ;;
esac
[ -z "$(git -C "$REPO" ls-files -- 'clients' '.env' '**/.env')" ] || die 'project tracks client or secret files'
[ ! -e "$REPO/clients" ] && [ ! -e "$REPO/.env" ] || die 'project contains private client or secret paths'
command -v gh-axi >/dev/null || die 'every worker requires gh-axi installed on the Boat box'
# Ask the injected connection for public identity only, never inspect or stage
# its credentials. A marker/base64 scalar avoids parsing arbitrary TOON fields.
GH_OUTPUT=$(fm_run_timed 30 gh-axi api /user --jq '"fm_boat_identity=" + ({login,id} | tojson | @base64)' --full 2>/dev/null) || die 'on-box GitHub account is unavailable'
GH_ENCODED=$(printf '%s\n' "$GH_OUTPUT" | sed -n 's/^  body: fm_boat_identity=\([A-Za-z0-9+/=]*\)$/\1/p')
[ -n "$GH_ENCODED" ] &&
  [ "$GH_OUTPUT" = "$(printf 'api_response:\n  body: fm_boat_identity=%s\n  truncated: false' "$GH_ENCODED")" ] || die 'on-box GitHub identity response is invalid or truncated'
GH_ACCOUNT=$(jq -cen --arg encoded "$GH_ENCODED" '
  $encoded | @base64d | fromjson | select(type == "object") |
  select((.login | type == "string" and length <= 39 and
    test("\\A[A-Za-z0-9]+(-[A-Za-z0-9]+)*\\z")) and
    (.id | type == "number" and . > 0 and . <= 9007199254740991 and floor == .))
' 2>/dev/null) || die 'on-box GitHub account login or numeric id is invalid'
GIT_NAME=$(printf '%s' "$GH_ACCOUNT" | jq -r .login)
GH_ID=$(printf '%s' "$GH_ACCOUNT" | jq -r .id)
ACCOUNT_CONFIG="$FM_HOME/config/boat-github-account.json"
if [ ! -f "$ACCOUNT_CONFIG" ] || [ -L "$ACCOUNT_CONFIG" ]; then
  die "expected Boat GitHub account is missing (config/boat-github-account.json); actual $GIT_NAME ($GH_ID)"
fi
[ "$(wc -c < "$ACCOUNT_CONFIG")" -le 256 ] || die 'invalid config/boat-github-account.json'
EXPECTED_ACCOUNT=$(jq -cen --slurpfile account "$ACCOUNT_CONFIG" '
  $account | select(length == 1) | .[0] |
  select(type == "object" and (keys == ["id","login"]) and
    (.login | type == "string" and length <= 39 and
      test("\\A[A-Za-z0-9]+(-[A-Za-z0-9]+)*\\z")) and
    (.id | type == "number" and . > 0 and . <= 9007199254740991 and floor == .))
' 2>/dev/null) || die 'invalid config/boat-github-account.json'
EXPECTED_ID=$(printf '%s' "$EXPECTED_ACCOUNT" | jq -r .id)
EXPECTED_NAME=$(printf '%s' "$EXPECTED_ACCOUNT" | jq -r .login)
[ "$GH_ID" = "$EXPECTED_ID" ] ||
  die "Boat GitHub account mismatch: expected $EXPECTED_NAME ($EXPECTED_ID); actual $GIT_NAME ($GH_ID)"
GIT_EMAIL=$(printf '%s' "$GH_ACCOUNT" | jq -r '"\(.id)+\(.login)@users.noreply.github.com"')
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
  $0 == "Goal: {GOAL}" { print "Goal: Complete the one code-only task in the spec."; next }
  $0 == "{FIRSTMATE_SPEC}" { while ((getline line < spec) > 0) print line; close(spec); next }
  $0 == "Off-limits: {OFF_LIMITS}" { print "Off-limits: Secrets, client data, pushes, merges, deploys, and captain contact."; next }
  $0 == "Contracts and gates (follow them; spawned inside a pipeline, move only through its states): {CONTRACTS}" {
    print "Contracts and gates (follow them; spawned inside a pipeline, move only through its states): none"
    next
  }
  { print }
' "$BRIEF" > "$TMP/brief" || die 'brief rewrite failed'
cat "$TMP/brief" > "$BRIEF"
if [ "$MODE" != scout ]; then ARGS+=(--yolo off); fi
ARGS+=(--git-name "$GIT_NAME" --git-email "$GIT_EMAIL")
ARGS+=(--backend tmux --harness "$(jq -r .harness "$TMP/request")" --model "$(jq -r .model "$TMP/request")" --effort "$(jq -r .effort "$TMP/request")")
STATUS="$FM_HOME/state/$ID.status"
STATUS_LINES=0
if [ -L "$STATUS" ] || { [ -e "$STATUS" ] && [ ! -f "$STATUS" ]; }; then
  die 'unsafe worker status path'
fi
if [ -f "$STATUS" ]; then STATUS_LINES=$(wc -l < "$STATUS"); fi
"$SCRIPT_DIR/fm-spawn.sh" "$ID" "$REPO" "${ARGS[@]}" >&2
# A spawned pane is not proof that the brief was consumed. Only a new worker
# declaration counts.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
polls=${FM_BOAT_START_POLLS:-120}
interval=${FM_BOAT_START_INTERVAL:-1}
case "$polls" in ''|*[!0-9]*|0) die 'invalid Boat start poll limit' ;; esac
for ((poll=0; poll<polls; poll++)); do
  started=0
  refused=0
  if [ -f "$STATUS" ]; then
    fresh=$(tail -n "+$((STATUS_LINES + 1))" "$STATUS")
    while IFS= read -r line; do
      case "$line" in *': '*) ;; *) continue ;; esac
      status_line_at_epoch "$line" >/dev/null || continue
      status_verb=''
      status_line_verb "$line" status_verb
      case "$status_verb" in
        failed|blocked|needs-decision) refused=1 ;;
        working|paused|done) started=1 ;;
      esac
    done <<< "$fresh"
  fi
  [ "$refused" -eq 0 ] || die "worker $ID declared a failure or decision before start confirmation; reconcile its status"
  if [ "$started" -eq 1 ]; then
    printf 'boat-started: %s (fresh worker status)\n' "$ID"
    break
  fi
  if [ "$poll" -lt "$((polls - 1))" ]; then sleep "$interval"; fi
done
if [ "$poll" -eq "$polls" ]; then
  printf 'error: worker %s did not prove start with a fresh status; a Codex folder-trust prompt is a known cause. Reconcile the same task before retry.\n' "$ID" >&2
  printf 'Inspect: fm-on.sh boat-eng fm-peek.sh %s\n' "$ID" >&2
  printf 'If the live pane shows that prompt, answer: fm-on.sh boat-eng fm-send.sh %s --key Enter\n' "$ID" >&2
  printf 'Then inspect: fm-on.sh boat-eng fm-peek.sh %s\n' "$ID" >&2
  exit 1
fi
printf 'boat-task: %s project=%s mode=%s route=boat-eng\n' "$ID" "$PROJECT" "$MODE"
