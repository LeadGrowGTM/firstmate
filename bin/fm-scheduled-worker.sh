#!/usr/bin/env bash
# fm-scheduled-worker.sh - explicitly authorized, bounded scheduled-worker intake.
# Usage: fm-scheduled-worker.sh <plan.json> <selection.json>
#        fm-scheduled-worker.sh <plan.json> <selection.json>
#          --exhaustion <proof.json> --note-file <checkpoint-note>
# Requires explicit FM_HOME. Nothing arms/enables a schedule or changes routing.
# Executes ONE supervisor-selected concrete profile per invocation, never picks
# array order or silently switches a backend, pin, model, reasoning class or rigor.
# Firstmate must refresh catalog/auth/quota/reasoning/runway/spendPriority evidence
# using current dispatch policy before every selection, including after failure.
#
# plan.json (version 1): authorized:true, occurrence/task (bare ids), project
# (absolute), backend, mode, yolo, reasoning_class, profiles (nonempty array of
# {harness,model,effort,reasoning_class}); optional branch_prefix and base_branch.
# Profiles must share the explicitly authorized reasoning class. This is a
# task-local authorization, not a schedule's permanent model/account preference.
# selection.json: {profile:<one exact profile>,observed_at:<epoch>,evidence:<text>}
# evidence records firstmate's every-candidate review and selection rationale;
# it is not a credential or an automatic routing decision. Evidence must be at
# most 300 seconds old, and newer than the previous failed selection.
# exhaustion proof: {kind:"usage-exhausted",spawn_gen:<current meta generation>,
# evidence:<text>}. A low-quota warning is not exhaustion. Requires a nonempty
# checkpoint note; guarded fm-control relaunch owns stopping and continuation.
#
# State: state/scheduled-worker/<occurrence>/journal.json, immutable plan.json,
# selection.<n>.json and outcome.<n>.json. Private attempt receipts and a per-
# occurrence lock prevent replay/crash/concurrent calls from duplicating work.
# Only typed pre-provisioning worker-unavailable permits reselect; every profile
# is tried once per launch/continuation episode. Capacity (exit 75) stays queued,
# consumes no candidate, and cannot switch profile. Unsafe refusal is blocked.
# Missing/malformed receipts, interrupted delivery, or journal phase attempting
# require reconciliation, never a second spawn. Published workers replay quietly.
# New proven exhaustion of the current incarnation begins a new continuation
# episode with its current profile excluded, always in the existing worktree.
# No automatic retries after every candidate is exhausted; firstmate owns later
# evidence/reconciliation. No task/worktree cleanup, account/login or backend change.
# shellcheck disable=SC2016 # jq expressions bind their own variables.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
die() { echo "error: $*" >&2; exit 1; }
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || die 'explicit FM_HOME is required'
[ $# -ge 2 ] || die 'plan and selection files are required'
PLAN=$1 SELECTION=$2
shift 2
PROOF='' NOTE=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "missing value for $1"
  case "$1" in --exhaustion) PROOF=$2 ;; --note-file) NOTE=$2 ;; *) die "unexpected argument $1" ;; esac
  shift 2
done
safe_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
if ! safe_file "$PLAN" || ! safe_file "$SELECTION"; then
  die 'plan/selection must be readable regular files'
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

jq -e '
  def token: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$");
  .version == 1 and .authorized == true and
  (.occurrence | token) and (.task | token) and
  (.project | type == "string" and startswith("/") and (test("[\\x00-\\x1f\\x7f]")|not)) and
  (.backend | IN("tmux","herdr","zellij","orca","cmux")) and
  (.mode | IN("no-mistakes","direct-PR","local-only")) and (.yolo | IN("on","off")) and
  (.reasoning_class | token) and
  (.branch_prefix == null or (.branch_prefix | token)) and (.base_branch // "main" | token) and
  (.profiles | type == "array" and length > 0 and length <= 32) and
  (.reasoning_class as $class | all(.profiles[];
    (keys == ["effort","harness","model","reasoning_class"]) and
    (.harness | token) and (.model | token) and
    (.effort | IN("low","medium","high","xhigh","max","ultra")) and .reasoning_class == $class))
' "$PLAN" >/dev/null || die 'invalid explicit fallback authorization'
ID=$(jq -r .task "$PLAN") OCCURRENCE=$(jq -r .occurrence "$PLAN")
if ! fm_task_id_creation_valid "$ID" || ! fm_task_id_creation_valid "$OCCURRENCE"; then
  die 'task/occurrence must be bare ids'
fi
while IFS= read -r harness; do
  fm_control_harness_supported "$harness" || die "unverified harness $harness"
done < <(jq -r '.profiles[].harness' "$PLAN")
NOW=$(date +%s)
jq -e --slurpfile plan "$PLAN" --argjson now "$NOW" '
  (.observed_at | type == "number" and floor == .) and
  .observed_at <= $now and .observed_at >= ($now - 300) and
  (.evidence | type == "string" and test("\\S")) and
  (.profile as $p | $plan[0].profiles | index($p) != null)
' "$SELECTION" >/dev/null || die 'selection needs fresh evidence and one exactly authorized profile'
PROFILE=$(jq -cS .profile "$SELECTION")
OBSERVED=$(jq -r .observed_at "$SELECTION")
PLAN_PROJECT=$(CDPATH='' cd -- "$(jq -r .project "$PLAN")" && pwd) || die 'plan project is unavailable'
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
case "$STATE" in /*) ;; *) STATE="$(pwd -P)/$STATE" ;; esac
DIR=$STATE/scheduled-worker/$OCCURRENCE
# Reject unsafe roots before creating or following any occurrence path.
for directory in "$STATE" "$STATE/scheduled-worker" "$DIR"; do
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ] && [ -O "$directory" ] || die "unsafe state directory $directory"
    [ -z "$(find "$directory" -prune \( -perm -g=w -o -perm -o=w \) -print)" ] || die "writable state directory $directory"
  fi
done
umask 077
mkdir -p "$DIR"
LOCK=$DIR/.lock
fm_lock_try_acquire "$LOCK" || die 'another attempt owns this occurrence'
trap 'fm_lock_release "$LOCK"' EXIT
JOURNAL=$DIR/journal.json
write_journal() { # <jq-filter> [jq arguments...]
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$DIR/.journal.XXXXXX") || return 1
  jq "$@" "$filter" "$JOURNAL" > "$tmp" && mv -f "$tmp" "$JOURNAL"
}
if [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ]; then
  # Creating the journal before invoking any owner is the crash barrier.
  [ ! -e "$DIR/plan.json" ] && [ ! -L "$DIR/plan.json" ] || die 'incomplete occurrence initialization needs reconciliation'
  jq -S . "$PLAN" > "$DIR/plan.json"
  printf '{"version":1,"phase":"pending","attempt":0,"tried":[],"observed_at":0,"action":"spawn"}\n' > "$JOURNAL"
fi
if ! safe_file "$JOURNAL" || ! safe_file "$DIR/plan.json"; then
  die 'unsafe occurrence records'
fi
jq -S . "$PLAN" | cmp -s - "$DIR/plan.json" || die 'occurrence authorization changed; reconcile original task'
PHASE=$(jq -er .phase "$JOURNAL")
case "$PHASE" in
  attempting|blocked) die 'occurrence needs reconciliation before further attempts' ;;
  worker-published|live-worker)
    if [ -z "$PROOF" ]; then
      printf 'already-published: %s\n' "$ID"
      exit 0
    fi
    if ! safe_file "$PROOF" || ! safe_file "$NOTE"; then
      die 'exhaustion requires proof and a checkpoint note'
    fi
    [ -n "$(tr -d '[:space:]' < "$NOTE")" ] || die 'checkpoint note is empty'
    META=$STATE/$ID.meta
    safe_file "$META" || die 'current worker metadata is missing/unsafe'
    GEN=$(fm_meta_get "$META" spawn_gen)
    [ -n "$GEN" ] || die 'worker incarnation is unbound'
    jq -e --arg gen "$GEN" '.kind == "usage-exhausted" and .spawn_gen == $gen and (.evidence | type == "string" and test("\\S"))' "$PROOF" >/dev/null || die 'exhaustion must bind current incarnation; a low warning cannot relaunch'
    [ "$(jq -r .spawn_gen "$JOURNAL")" = "$GEN" ] || die 'worker changed outside this occurrence; reconcile before continuing'
    for axis in backend mode yolo project; do
      actual=$(fm_meta_get "$META" "$axis")
      [ "$axis" != backend ] || actual=${actual:-tmux}
      if [ "$axis" = project ]; then
        actual=$(CDPATH='' cd -- "$actual" && pwd) || die 'worker project is unavailable'
        planned=$PLAN_PROJECT
      else
        planned=$(jq -r ".$axis" "$PLAN")
      fi
      [ "$actual" = "$planned" ] || die "worker $axis changed; refusing continuation"
    done
    cp "$PROOF" "$DIR/exhaustion.$GEN.json"
    cp "$NOTE" "$DIR/checkpoint.$GEN.txt"
    PRIOR=$(jq -c .profile "$JOURNAL")
    write_journal '.phase="pending" | .action="relaunch" | .tried=[$prior] | .exhaustion_gen=$gen | .observed_at=0' --argjson prior "$PRIOR" --arg gen "$GEN"
    ;;
  pending|reselect|capacity) ;;
  *) die 'invalid occurrence journal' ;;
esac
ACTION=$(jq -r .action "$JOURNAL")
if [ "$ACTION" = spawn ]; then
  [ -z "$PROOF" ] && [ -z "$NOTE" ] || die 'exhaustion cannot start a fresh task'
  [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] || die 'task already has metadata; reconcile before spawn'
else
  GEN=$(jq -r .exhaustion_gen "$JOURNAL")
  [ "$(fm_meta_get "$STATE/$ID.meta" spawn_gen)" = "$GEN" ] || die 'continuation incarnation changed'
  NOTE=$DIR/checkpoint.$GEN.txt
  safe_file "$NOTE" || die 'durable checkpoint note is missing'
fi
jq -e --argjson p "$PROFILE" '.tried | index($p) == null' "$JOURNAL" >/dev/null || die 'candidate already attempted this episode; reselect or leave pending'
if [ "$(jq -r .phase "$JOURNAL")" = capacity ]; then
  [ "$PROFILE" = "$(jq -cS .profile "$JOURNAL")" ] || die 'capacity cannot switch subscription profile'
fi
[ "$OBSERVED" -gt "$(jq -r .observed_at "$JOURNAL")" ] || die 'refresh evidence after the prior failed attempt'
if [ "$ACTION" = spawn ]; then
  if jq -e '.branch_prefix != null' "$PLAN" >/dev/null; then
    BRANCH_PREFIX=$(jq -r .branch_prefix "$PLAN")
  else
    BRIEF=${FM_DATA_OVERRIDE:-$FM_HOME/data}/$ID/brief.md
    safe_file "$BRIEF" || die "prepared ship brief is missing or unsafe: $BRIEF"
    SHIP_BRANCHES=$(sed -n 's/^Ship branch: //p' "$BRIEF")
    [ -n "$SHIP_BRANCHES" ] || die "prepared ship brief records no branch: $BRIEF"
    SHIP_BRANCH=$(printf '%s\n' "$SHIP_BRANCHES" | head -n 1)
    if printf '%s\n' "$SHIP_BRANCHES" | grep -vxF -- "$SHIP_BRANCH" >/dev/null; then
      die "prepared ship brief records conflicting branches: $BRIEF"
    fi
    git check-ref-format --branch "$SHIP_BRANCH" >/dev/null 2>&1 || die "prepared ship brief records an invalid branch: $BRIEF"
    case "$SHIP_BRANCH" in
      *"$ID") BRANCH_PREFIX=${SHIP_BRANCH%"$ID"} ;;
      *) die "prepared ship branch does not end with task id $ID: $SHIP_BRANCH" ;;
    esac
  fi
fi
ATTEMPT=$(( $(jq -r .attempt "$JOURNAL") + 1 ))
RECEIPT=$DIR/outcome.$ATTEMPT.json
cp "$SELECTION" "$DIR/selection.$ATTEMPT.json"
write_journal '.phase="attempting" | .attempt=$n | .profile=$p | .tried += [$p] | .observed_at=$at' --argjson n "$ATTEMPT" --argjson p "$PROFILE" --argjson at "$OBSERVED"
HARNESS=$(jq -r .harness <<< "$PROFILE")
MODEL=$(jq -r .model <<< "$PROFILE")
EFFORT=$(jq -r .effort <<< "$PROFILE")
ARGS=(--harness "$HARNESS" --model "$MODEL" --effort "$EFFORT")
RC=0
if [ "$ACTION" = spawn ]; then
  ARGS+=(--backend "$(jq -r .backend "$PLAN")" --mode "$(jq -r .mode "$PLAN")" --yolo "$(jq -r .yolo "$PLAN")")
  ARGS+=(--branch-prefix "$BRANCH_PREFIX")
  BASE=$(jq -r '.base_branch // empty' "$PLAN")
  [ -z "$BASE" ] || ARGS+=(--base-branch "$BASE")
  FM_SPAWN_OUTCOME_FILE=$RECEIPT FM_SCHEDULED_WORKER_PLAN=$DIR/plan.json \
    "$SCRIPT_DIR/fm-spawn.sh" "$ID" "$(jq -r .project "$PLAN")" "${ARGS[@]}" || RC=$?
else
  FM_SPAWN_OUTCOME_FILE=$RECEIPT FM_SCHEDULED_WORKER_PLAN=$DIR/plan.json \
    "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch "${ARGS[@]}" --expected-spawn-gen "$GEN" --note-file "$NOTE" || RC=$?
fi
if ! safe_file "$RECEIPT" || ! jq -e --arg task "$ID" --argjson code "$RC" '
  .version == 1 and .task == $task and .exit_code == $code and
  (.outcome | IN("worker-unavailable","capacity","unsafe-refusal","uncertain","worker-published","live-worker"))
' "$RECEIPT" >/dev/null; then
  write_journal '.phase="blocked" | .reason="missing-or-invalid-launch-receipt"'
  die 'launch result unknown; reconcile before retry'
fi
OUTCOME=$(jq -r .outcome "$RECEIPT")
case "$OUTCOME:$RC" in
  worker-published:0|live-worker:0)
    NEW_GEN=$(jq -r .spawn_gen "$RECEIPT")
    [ -n "$NEW_GEN" ] && [ "$(fm_meta_get "$STATE/$ID.meta" spawn_gen)" = "$NEW_GEN" ] || {
      write_journal '.phase="blocked" | .reason="publication-generation-mismatch"'
      die 'publication cannot be confirmed'
    }
    write_journal '.phase=$outcome | .spawn_gen=$gen' --arg outcome "$OUTCOME" --arg gen "$NEW_GEN"
    ;;
  worker-unavailable:1)
    write_journal '.phase="reselect" | .reason=$reason' --arg reason "$(jq -r .reason "$RECEIPT")"
    ;;
  capacity:75)
    write_journal '.phase="capacity" | .tried -= [.profile]'
    ;;
  *)
    write_journal '.phase="blocked" | .reason=$outcome' --arg outcome "$OUTCOME"
    ;;
esac
printf 'scheduled-worker: %s occurrence=%s task=%s receipt=%s\n' "$(jq -r .phase "$JOURNAL")" "$OCCURRENCE" "$ID" "$RECEIPT"
exit "$RC"
