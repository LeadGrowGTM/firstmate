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
# Set config/deadweight-sweep to `off` to disable automatic cleanup in that
# home. Missing configuration means on; other contents refuse automatic work.
# Direct invocation still runs a sweep for an explicit home.
# state/.deadweight-sweep-launched records the last automatic start time;
# state/.deadweight-sweep-result holds the unreported result.
#
# Only this home's ship/scout records are considered. Teardown's
# --only-if-stopped guard checks endpoint and captain-decision state under its
# lifecycle lock; its ordinary landed-work, scout-completion, ownership, and
# backlog gates own every removal. No --force or live idle-worker exit is used.
# The separately armed idle-exit check can stop idle workers first. Backends
# without a recovery-grade stopped classifier are retained conservatively.
# Missing legacy incarnation records are reported as ordinary refusals.
#
# For clone roots under this home's projects directory, prune stale git
# registrations only after a NUL-delimited inventory proves a missing path.
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
case "${1:-}" in
  check)
    config="$FM_HOME/config/deadweight-sweep"
    if [ -e "$config" ] || [ -L "$config" ]; then
      [ -f "$config" ] && [ ! -L "$config" ] && [ -r "$config" ] \
        && [ "$(cat "$config")" = off ] || {
        echo 'swept: automatic cleanup refused: config/deadweight-sweep must contain off' ; exit 1
      }
      exit 0
    fi
    CHECK_LOCK="$STATE/.deadweight-check.lock"
    fm_lock_try_acquire "$CHECK_LOCK" || exit 0
    trap 'fm_lock_release "$CHECK_LOCK" || true' EXIT
    device=$(fm_pr_file_device "$STATE")
    for record in "$RESULT" "$LAUNCHED"; do
      fm_pr_regular_destination_on_device_or_absent "$record" "$device" || {
        echo 'swept: automatic cleanup refused: unsafe schedule record'; exit 1
      }
    done
    if [ -f "$RESULT" ]; then
      cat "$RESULT"
      rm -f -- "$RESULT"
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
    publish "$RESULT" "$out"
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
projects=() copies_before=()
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

# Capture existing copies before teardown, which can itself safely prune a
# returned pool slot. Do not count the clone root or duplicate shared paths.
for project in "$PROJECTS"/*; do
  [ -d "$project" ] && [ ! -L "$project" ] || continue
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || continue
  [ "$project" -ef "$top" ] || continue
  projects+=("$project")
  if ! inventory "$project" "$TMP/before"; then
    note "inventory failed: $project"
    continue
  fi
  while IFS= read -r -d '' field; do
    case "$field" in worktree\ *) path=${field#worktree } ;; *) continue ;; esac
    [ -e "$path" ] && [ ! "$path" -ef "$project" ] || continue
    duplicate=0
    for seen in "${copies_before[@]+"${copies_before[@]}"}"; do
      [ "$seen" != "$path" ] || duplicate=1
    done
    [ "$duplicate" = 1 ] || copies_before+=("$path")
  done < "$TMP/before"
done

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ''|ship|scout) ;; *) continue ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  id=${meta##*/}; id=${id%.meta}
  rc=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "$id" --only-if-stopped \
    > "$TMP/teardown" 2>&1 || rc=$?
  case "$rc" in
    0) workers=$((workers + 1)) ;;
    3) ;;
    *) note "kept $id: $(reason "$TMP/teardown")" ;;
  esac
done

for project in "${projects[@]+"${projects[@]}"}"; do
  project_lock=$(fm_treehouse_project_lock_path "$project") || {
    note "cannot resolve project lock: $project"; continue
  }
  fm_lock_try_acquire "$project_lock" || continue
  # Keep the lock in this process: lock ownership uses the actual process id.
  rc=0
  (
    inventory "$project" "$TMP/prune-before" || exit 1
    missing=0
    while IFS= read -r -d '' field; do
      case "$field" in worktree\ *) path=${field#worktree } ;; *) continue ;; esac
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then missing=1; fi
    done < "$TMP/prune-before"
    if [ "$missing" = 1 ]; then
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
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-treehouse-guard.sh" prune --locked "$project" || exit 1
  ) > "$TMP/prune-output" 2>&1 || rc=$?
  fm_lock_release "$project_lock" || true
  project_lock=
  [ ! -f "$TMP/stale" ] || stale=$((stale + $(cat "$TMP/stale")))
  rm -f -- "$TMP/stale"
  [ "$rc" = 0 ] || note "prune failed for $project: $(reason "$TMP/prune-output")"
done
for path in "${copies_before[@]+"${copies_before[@]}"}"; do
  [ -e "$path" ] || [ -L "$path" ] || copies=$((copies + 1))
done
if [ "$workers" -gt 0 ] || [ "$copies" -gt 0 ] || [ "$stale" -gt 0 ] || [ -n "$findings" ]; then
  printf 'swept: %s workers, %s copies, %s stale registrations%s\n' \
    "$workers" "$copies" "$stale" "${findings:+; $findings}"
fi
