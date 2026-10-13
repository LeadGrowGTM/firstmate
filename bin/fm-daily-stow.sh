#!/usr/bin/env bash
# Queue a daily /stow for an explicitly selected live primary home.
# Usage: fm-daily-stow.sh [--eligible <home>|--help]
#
# The opt-in timer runs at 01:30 America/Toronto. Delivery uses fm-inbox note,
# which saves one durable check wake, never terminal keys or lifecycle control.
# The primary handles it at a normal checkpoint and uses its existing cascade.
# --eligible checks only the intended home and the read-only primary-pass guard.
# Reading the note in that home is sufficient evidence of a live recipient.
#
# Queue for a recorded lock PID even when the host cannot classify its holder.
# A verified local holder also needs a healthy wake consumer. Away/quiet records
# and a secondmate home also skip. A primary pass recorded by fm-stow-cascade --record-pass in
# state/.last-stow-primary-pass within 20 hours skips, including a future stamp.
# An unreadable or malformed stamp fails closed. Missing stamps allow a pass.
# --eligible exits 3 for a skip, so the recipient can distinguish eligibility.
# Notes use a Toronto-date request id so same-day retries cannot enqueue twice.
# Queue errors retain fm-inbox's exit status, including saved-but-unannounced 3;
# retry the same day to repair that note instead of creating another request.
#
# FM_HOME must be the main operational home; the service sets it explicitly.
# FM_STATE_OVERRIDE is supported for isolated tests, as in fm-inbox.
set -euo pipefail

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
MODE=queue
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --eligible) MODE=eligible ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$MODE" = eligible ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  BOUND_HOME=$2
else
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] \
  || { echo 'error: FM_HOME must explicitly name the main operational home' >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state directory is missing: $STATE" >&2; exit 1; }

skip() {
  printf 'daily-stow: skipped (%s)\n' "$1"
  [ "$MODE" != eligible ] || exit 3
  exit 0
}
if [ "$MODE" = eligible ]; then
  [ -d "$BOUND_HOME" ] && [ "$(cd "$BOUND_HOME" && pwd -P)" = "$(cd "$FM_HOME" && pwd -P)" ] \
    || skip 'note belongs to a different home'
else
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    || skip 'secondmate home; schedule only main'
  [ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.afk-contract" ] \
    || skip 'away or quiet mode is active'
  READY=$("$SCRIPT_DIR/fm-inbox.sh" ready)
  REASON=$(python3 - "$READY" <<'PY_READY'
import json, sys
ready = json.loads(sys.argv[1])
if ready['posture']['state'] != 'present':
    print('away/quiet posture or posture unknown')
elif ready['lock']['state'] in ('free', 'stale'):
    print('no proven live main session')
elif ready['lock']['state'] not in ('held', 'unknown') or ready['lock']['pid'] is None:
    print('no usable main lock holder')
elif ready['lock']['state'] == 'held' and ready['can_receive'] is not True:
    print('main wake consumer is not proven healthy')
PY_READY
)
  [ -z "$REASON" ] || skip "$REASON"
fi
REASON=$(python3 - "$STATE/.last-stow-primary-pass" "$(date +%s)" <<'PY'
import pathlib, sys
stamp = pathlib.Path(sys.argv[1])
if stamp.exists() or stamp.is_symlink():
    try:
        value = stamp.read_text().strip()
        if not value.isascii() or not value.isdecimal():
            raise ValueError('invalid stamp')
        if int(sys.argv[2]) - int(value) < 20 * 3600:
            print('primary stow pass ran within the last 20 hours')
    except (OSError, ValueError):
        print('last primary stow pass stamp is unreadable or malformed')
PY
)
[ -z "$REASON" ] || skip "$REASON"
if [ "$MODE" = eligible ]; then
  echo 'daily-stow: eligible'
  exit 0
fi
REQUEST_ID="daily-stow:$(TZ=America/Toronto date +%F)"
printf -v ELIGIBLE_CMD 'FM_HOME=%q %q --eligible %q' "$FM_HOME" "$SCRIPT_DIR/fm-daily-stow.sh" "$FM_HOME"
"$SCRIPT_DIR/fm-inbox.sh" note --request-id "$REQUEST_ID" -- \
  "Scheduled daily stow: at the next safe checkpoint after current work, run $ELIGIBLE_CMD. If it exits 0, invoke /stow in this live session, including its existing secondmate cascade. If it skips, leave the scheduled pass undone. Never interrupt in-flight work or start a fresh worker for this request."
