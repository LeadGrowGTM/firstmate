#!/usr/bin/env bash
# Record the authority under which a task's PR may be merged, as one
# merge_ok= line in the task's state/<task-id>.meta. bin/fm-pr-merge.sh refuses
# every merge whose live PR has no matching record, after its own live checks
# (open, not a draft, mergeable, every check green at the current head) pass.
#
# Two bases exist, and the caller names which one it is recording:
#   captain   The captain's explicit word to merge this exact PR. Matches the
#             PR's canonical URL, at any head; the live green-at-head checks
#             still apply. Required for any PR that deploys live, publishes,
#             or touches client systems.
#   standing  The captain's standing rule for an ordinary PR that does not
#             deploy live, publish, or touch client systems: a clean Codex
#             review of the named head commit. Matches only while the PR's
#             live head is still that commit, so a later push needs a new
#             review and a new record.
# Recording standing is the caller's attestation of both conditions; this
# script cannot see what a PR deploys or what a review said.
#
# Record shape (one line; a new record replaces the previous one):
#   merge_ok=captain <canonical-pr-url>
#   merge_ok=standing <canonical-pr-url> <reviewed-head-sha>
#
# The task record is rewritten atomically under its metadata lock. The
# supervision branch may record only while the away-posture record relocates
# merge authority to it, the same role gate as bin/fm-pr-merge.sh.
#
# Usage: fm-merge-ok.sh <task-id> <pr-url> captain
#        fm-merge-ok.sh <task-id> <pr-url> standing <reviewed-head-sha>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

usage() {
  echo "usage: fm-merge-ok.sh <task-id> <pr-url> captain | fm-merge-ok.sh <task-id> <pr-url> standing <reviewed-head-sha>" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
ID=$1
RAW_URL=$2
BASIS=$3
case "$BASIS" in
  captain) [ "$#" -eq 3 ] || usage; HEAD_SHA= ;;
  standing)
    [ "$#" -eq 4 ] || usage
    HEAD_SHA=$4
    case "$HEAD_SHA" in
      *[!0-9a-f]*) echo "error: reviewed head must be a full lowercase commit sha" >&2; exit 2 ;;
    esac
    [ "${#HEAD_SHA}" -eq 40 ] || [ "${#HEAD_SHA}" -eq 64 ] \
      || { echo "error: reviewed head must be a full lowercase commit sha" >&2; exit 2; }
    ;;
  *) usage ;;
esac
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid merge authority request" >&2
  exit 2
fi
URL=$FM_PR_URL

fm_lease_forbid_branch "merge authority record (fm-merge-ok)" --away-relocated

META="$STATE/$ID.meta"
META_TMP=
META_LOCK_HELD=0
cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ "$META_LOCK_HELD" = 0 ] || fm_lock_release "$META_LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: task metadata is unavailable" >&2; exit 1; }
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || { echo "error: task metadata is unavailable" >&2; exit 1; }
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ] \
  || [ "$(fm_pr_file_device "$META")" != "$STATE_DEVICE" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
META_TMP=$(mktemp "$STATE/.fm-merge-ok.XXXXXX")
grep -v '^merge_ok=' "$META" > "$META_TMP" || true
if [ "$BASIS" = captain ]; then
  printf 'merge_ok=captain %s\n' "$URL" >> "$META_TMP"
else
  printf 'merge_ok=standing %s %s\n' "$URL" "$HEAD_SHA" >> "$META_TMP"
fi
chmod 0600 "$META_TMP"
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
mv -f -- "$META_TMP" "$META"
META_TMP=
printf 'recorded: merge_ok=%s %s%s for task %s\n' "$BASIS" "$URL" "${HEAD_SHA:+ $HEAD_SHA}" "$ID"
