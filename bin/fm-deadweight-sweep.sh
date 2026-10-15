#!/usr/bin/env bash
# fm-deadweight-sweep.sh - remove stopped workers with no work to preserve.
#
# Usage: FM_HOME=/absolute/home bash /absolute/code/bin/fm-deadweight-sweep.sh
#        fm-deadweight-sweep.sh check
#        fm-deadweight-sweep.sh --help
#
# Every home's watcher calls `check` by default on its slow-check cadence.
# The check starts cleanup at most once every 86400 seconds, in a separate
# process group so the watcher's check timeout cannot interrupt pool pruning.
# Daily gating avoids repeated endpoint, git, and pool probes on every poll.
# The next poll prints the completed sweep's one-line result once. No check
# shim, cron entry, or extra daemon needs arming. The normal supervision cycle
# must be running; this script does not launch one or administer a live home.
# Direct invocation still runs a sweep for an explicit home.
# state/.deadweight-sweep-launched records the last automatic start time;
# state/.deadweight-sweep-result holds the unreported result.
#
# Only this home's ship/scout records are considered. Teardown's
# --only-if-stopped guard checks endpoint and captain-decision state under its
# lifecycle lock; its ordinary landed-work, scout-completion, ownership, and
# backlog gates own every removal. No --force or live idle-worker exit is used.
# Alive idle workers belong to the separately armed idle-exit check. Orca,
# Zellij, and cmux have no recovery-grade stopped classifier and stay retained.
# Missing legacy incarnation records are reported as ordinary refusals.
#
# For clone roots under this home's projects directory, prune stale git
# registrations only after a NUL-delimited inventory proves every registration
# git marks prunable is absent; otherwise skip the prune and report the path.
# Hold the shared project lock during inventory/pruning and delegate pool
# deletion to fm-treehouse-guard.sh's safe prune. Never scan other homes or
# remove a copy directly. Counts reflect registered paths actually removed;
# a retained reusable pool slot is not counted as a removed copy.
#
# Repeated or overlapping runs converge: one home lock serializes sweeps,
# teardown serializes lifecycle actions, and refusals remain recorded by the
# task. Output is one line with actual counts and any refusal reasons, or
# nothing when there was nothing to remove or report.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  --help|-h) sed -n '2,/^set -eu/{ /^#/ {s/^# \{0,1\}//;p;} }' "$0"; exit 0 ;;
  ''|check|scheduled) ;;
  *) echo 'error: expected no arguments, check, or --help' >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] && [ "${FM_HOME#/}" != "$FM_HOME" ] || {
  echo 'error: an explicit absolute FM_HOME is required' >&2; exit 2
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo 'error: state directory is unavailable' >&2; exit 1
}
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# Use the existing private-record destination checks for atomic publications.
publish() {  # <destination> <bytes>
  local dest=$1 value=$2 device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.deadweight-sweep-tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}
RESULT="$STATE/.deadweight-sweep-result"
LAUNCHED="$STATE/.deadweight-sweep-launched"
queue_report() {
  local report=$1 consumed=${2:-0} status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_wake_append_locked check deadweight-sweep "check: deadweight-sweep: $report" || status=$?
  if [ "$status" -eq 0 ] && [ "$consumed" = 1 ]; then
    rm -f -- "$RESULT" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$report"
}
case "${1:-}" in
  check)
    CHECK_LOCK="$STATE/.deadweight-check.lock"
    fm_lock_try_acquire "$CHECK_LOCK" || exit 0
    trap 'fm_lock_release "$CHECK_LOCK" || true' EXIT
    device=$(fm_pr_file_device "$STATE")
    for record in "$RESULT" "$LAUNCHED"; do
      fm_pr_regular_destination_on_device_or_absent "$record" "$device" || {
        queue_report 'swept: automatic cleanup refused: unsafe schedule record'
        exit 1
      }
    done
    if [ -f "$RESULT" ]; then
      report=$(cat "$RESULT")
      [ -z "$report" ] || queue_report "$report" 1
      [ -n "$report" ] || rm -f -- "$RESULT"
    fi
    launched=$(cat "$LAUNCHED" 2>/dev/null || true)
    now=$(date +%s)
    case "$launched" in
      ''|*[!0-9]*) due=1 ;;
      *) if [ "$((now - launched))" -ge 86400 ] || [ "$now" -lt "$launched" ]; then due=1; else due=0; fi ;;
    esac
    if [ "$due" = 1 ]; then
      publish "$LAUNCHED" "$now"
      # A new process group survives run_check_capture's timeout and cleanup.
      set -m
      nohup "$0" scheduled </dev/null >/dev/null 2>&1 &
      set +m
    fi
    exit 0
    ;;
  scheduled)
    rc=0
    out=$("$0" 2>&1) || rc=$?
    [ "$rc" = 0 ] || out="swept: cleanup failed: ${out:-exit $rc}"
    out=${out//[$'\t\r\n']/ }
    # Nothing to report (or another sweep held the lock): keep any unread result.
    [ -z "$out" ] || publish "$RESULT" "$out"
    exit 0
    ;;
esac

LOCK="$STATE/.deadweight-sweep.lock"
fm_lock_try_acquire "$LOCK" || exit 0
TMP=
project_lock=
cleanup() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  [ -z "$project_lock" ] || fm_lock_release "$project_lock" || true
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-deadweight-sweep.XXXXXX")
workers=0 copies=0 stale=0
findings=
projects=()
note() {
  local reason
  reason=$(printf '%s\n' "$1" | awk 'NF { print; exit }')
  reason=${reason//[$'\t\r\n']/ }
  findings="${findings:+$findings; }$reason"
}
reason() {
  awk 'NF && !first { first = $0 }
    /^(REFUSED:|error:|warning:|fm-captain-hold:)/ { print; found = 1; exit }
    END { if (!found) print first }' "$1"
}

inventory() { git -C "$1" worktree list --porcelain -z > "$2" 2> "$TMP/inventory-error"; }

for project in "$PROJECTS"/*; do
  [ -d "$project" ] && [ ! -L "$project" ] || continue
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || continue
  [ "$project" -ef "$top" ] || continue
  projects+=("$project")
done

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ''|ship|scout) ;; *) continue ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  id=${meta##*/}; id=${id%.meta}
  worker_copy=$(fm_meta_get "$meta" worktree)
  had_copy=0
  if [ -d "$worker_copy" ] && [ ! -L "$worker_copy" ]; then had_copy=1; fi
  rc=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$id" --only-if-stopped \
    > "$TMP/teardown" 2>&1 || rc=$?
  case "$rc" in
    0|4)
      workers=$((workers + 1))
      if [ "$had_copy" = 1 ] && [ ! -e "$worker_copy" ] && [ ! -L "$worker_copy" ]; then
        copies=$((copies + 1))
      fi
      if [ "$rc" = 4 ]; then
        note "cleaned $id: $(reason "$TMP/teardown")"
      fi
      ;;
    3)
      if fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
        endpoint_state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")
        case "$endpoint_state" in
          alive|unverified)
            busy_state=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null || true)
            case "$busy_state" in
              'idle '*) note "idle-left $id" ;;
            esac
            ;;
        esac
      fi
      ;;
    *) note "kept $id: $(reason "$TMP/teardown")" ;;
  esac
done

for project in "${projects[@]+"${projects[@]}"}"; do
  project_lock=$(fm_treehouse_project_lock_path "$project") || {
    note "cannot resolve project lock: $project"; continue
  }
  fm_lock_try_acquire "$project_lock" || continue
  retained_pool_task=
  for retained_meta in "$STATE"/*.meta; do
    [ -f "$retained_meta" ] && [ ! -L "$retained_meta" ] || continue
    retained_kind=$(fm_meta_get "$retained_meta" kind)
    case "$retained_kind" in ''|ship|scout) ;; *) continue ;; esac
    retained_copy=$(fm_meta_get "$retained_meta" worktree)
    if fm_treehouse_pool_slot "$project" "$retained_copy"; then
      retained_pool_task=${retained_meta##*/}
      retained_pool_task=${retained_pool_task%.meta}
      break
    fi
  done
  # Keep the lock in this process: lock ownership uses the actual process id.
  rc=0
  (
    inventory "$project" "$TMP/prune-before" || exit 1
    prune_paths=()
    while IFS= read -r -d '' field; do
      case "$field" in worktree\ *) path=${field#worktree } ;; *) continue ;; esac
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ "$path" -ef "$project" ] && continue
      prune_paths+=("$path")
    done < "$TMP/prune-before"
    # git prunes every registration it marks prunable, including a present
    # copy whose .git pointer is missing, so prune only when all are absent.
    candidates=0 present='' path=''
    while IFS= read -r -d '' field; do
      case "$field" in
        '') path= ;;
        worktree\ *) path=${field#worktree } ;;
        prunable|prunable\ *)
          candidates=$((candidates + 1))
          if [ "${path#/}" = "$path" ] || [ -e "$path" ] || [ -L "$path" ]; then
            present=${present:-${path:-unknown path}}
          fi
          ;;
      esac
    done < "$TMP/prune-before"
    if [ -n "$present" ]; then
      printf '%s\n' "$present" > "$TMP/prune-skipped"
    elif [ "$candidates" -gt 0 ]; then
      git -C "$project" worktree prune --expire now || exit 1
    fi
    inventory "$project" "$TMP/prune-after" || exit 1
    count=0
    while IFS= read -r -d '' field; do
      case "$field" in worktree\ *) path=${field#worktree } ;; *) continue ;; esac
      [ ! -e "$path" ] && [ ! -L "$path" ] || continue
      found=0
      while IFS= read -r -d '' after; do
        [ "$after" != "$field" ] || found=1
      done < "$TMP/prune-after"
      [ "$found" = 1 ] || count=$((count + 1))
    done < "$TMP/prune-before"
    printf '%s\n' "$count" > "$TMP/stale"
    prune_rc=0
    if [ -z "$retained_pool_task" ]; then
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-treehouse-guard.sh" prune --locked "$project" || prune_rc=$?
    fi
    count=0
    for path in "${prune_paths[@]+"${prune_paths[@]}"}"; do
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then count=$((count + 1)); fi
    done
    printf '%s\n' "$count" > "$TMP/copies"
    exit "$prune_rc"
  ) > "$TMP/prune-output" 2>&1 || rc=$?
  fm_lock_release "$project_lock" || true
  project_lock=
  [ ! -f "$TMP/stale" ] || stale=$((stale + $(cat "$TMP/stale")))
  rm -f -- "$TMP/stale"
  [ ! -f "$TMP/copies" ] || copies=$((copies + $(cat "$TMP/copies")))
  rm -f -- "$TMP/copies"
  if [ -f "$TMP/prune-skipped" ]; then
    note "prune skipped for $project: prunable registration still present: $(cat "$TMP/prune-skipped")"
    rm -f -- "$TMP/prune-skipped"
  fi
  [ -z "$retained_pool_task" ] || note "pool prune skipped for $project: retained task $retained_pool_task has a pool copy"
  [ "$rc" = 0 ] || note "prune failed for $project: $(reason "$TMP/prune-output")"
done
if [ "$workers" -gt 0 ] || [ "$copies" -gt 0 ] || [ "$stale" -gt 0 ] || [ -n "$findings" ]; then
  printf 'swept: %s workers, %s copies, %s stale registrations%s\n' \
    "$workers" "$copies" "$stale" "${findings:+; $findings}"
fi
