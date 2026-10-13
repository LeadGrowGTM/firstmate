#!/usr/bin/env bash
# Queue a daily /stow for an explicitly selected live primary home.
# Usage: fm-daily-stow.sh [--eligible <lock-pid> <holder-identity>|--help]
#
# The opt-in timer runs at 01:30 America/Toronto. Delivery uses fm-inbox note,
# which saves one durable check wake, never terminal keys or lifecycle control.
# The primary handles it at a normal checkpoint and uses its existing cascade.
# --eligible rechecks the bound live session and read-only delivery guards.
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
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  BOUND_PID=$2
  BOUND_IDENTITY=$3
  case "$BOUND_PID" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
  case "$BOUND_IDENTITY" in ''|*[!0-9a-f]*) usage >&2; exit 2 ;; esac
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
[ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
  || skip 'secondmate home; schedule only main'
[ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.afk-contract" ] \
  || skip 'away or quiet mode is active'
READY=$("$SCRIPT_DIR/fm-inbox.sh" ready)
# A Codex tool may run in a PID namespace where the host lock pid is hidden.
# Its own trusted conversation id proves the delivered note is in that session.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
RECIPIENT_SESSION_MATCH=0
if [ "$MODE" = eligible ] && trusted=$(fm_session_lock_trusted_codex_thread_id); then
  recorded=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
  [ "$recorded" != "codex:$trusted" ] || RECIPIENT_SESSION_MATCH=1
fi
REASON=$(python3 - "$READY" "$STATE/.last-stow-primary-pass" "$(date +%s)" "$MODE" "${BOUND_PID:-}" "$RECIPIENT_SESSION_MATCH" <<'PY'
import json, pathlib, sys
ready = json.loads(sys.argv[1])
stamp = pathlib.Path(sys.argv[2])
if ready['posture']['state'] != 'present':
    print('away/quiet posture or posture unknown')
elif ready['lock']['state'] in ('free', 'stale'):
    print('no proven live main session')
elif sys.argv[4] == 'queue' and (ready['lock']['state'] not in ('held', 'unknown') or ready['lock']['pid'] is None):
    print('no usable main lock holder')
elif sys.argv[4] == 'eligible' and (ready['lock']['state'] != 'held' or ready['lock']['live_harness'] is not True) and sys.argv[6] != '1':
    print('no proven live main session')
elif sys.argv[4] == 'eligible' and ready['lock']['pid'] != int(sys.argv[5]):
    print('different main session holds the lock')
elif sys.argv[4] == 'queue' and ready['lock']['state'] == 'held' and ready['can_receive'] is not True:
    print('main wake consumer is not proven healthy')
elif stamp.exists() or stamp.is_symlink():
    try:
        value = stamp.read_text().strip()
        if not value.isascii() or not value.isdecimal():
            raise ValueError('invalid stamp')
        if int(sys.argv[3]) - int(value) < 20 * 3600:
            print('primary stow pass ran within the last 20 hours')
    except (OSError, ValueError):
        print('last primary stow pass stamp is unreadable or malformed')
PY
)
[ -z "$REASON" ] || skip "$REASON"
LOCK_PID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["pid"])' <<< "$READY")
if [ "$MODE" = queue ]; then
  holder_harness=$("$SCRIPT_DIR/fm-harness.sh" ancestry "$LOCK_PID" 2>/dev/null || true)
  case "$holder_harness" in
    *' codex')
      recorded=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
      case "$recorded" in codex:*) ;; *) skip 'Codex session identity is unavailable' ;; esac
      ;;
  esac
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
SESSION_IDENTITY=absent
if [ -e "$STATE/.lock-session" ] || [ -L "$STATE/.lock-session" ]; then
  SESSION_IDENTITY=$(fm_session_lock_recorded_session_id "$STATE") \
    || skip 'main session identity is unavailable'
  SESSION_IDENTITY="present:$SESSION_IDENTITY"
fi
if [ "$MODE" = eligible ]; then
  case "$SESSION_IDENTITY" in
    present:codex:*)
      [ "$RECIPIENT_SESSION_MATCH" -eq 1 ] \
        || skip 'different main session holds the lock'
      ;;
  esac
fi
if [ "${SESSION_IDENTITY#present:codex:}" != "$SESSION_IDENTITY" ]; then
  HOLDER_IDENTITY=$(printf '%s' "$SESSION_IDENTITY" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
else
  HOLDER_IDENTITY=$({ fm_pid_identity "$LOCK_PID" && printf '\0%s' "$SESSION_IDENTITY"; } \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') \
    || skip 'main session identity is unavailable'
fi
if [ "$MODE" = eligible ]; then
  [ "$HOLDER_IDENTITY" = "$BOUND_IDENTITY" ] || skip 'different main session holds the lock'
  echo 'daily-stow: eligible'
  exit 0
fi
REQUEST_ID="daily-stow:$(TZ=America/Toronto date +%F)"
printf -v ELIGIBLE_CMD 'FM_HOME=%q %q --eligible %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-daily-stow.sh" "$LOCK_PID" "$HOLDER_IDENTITY"
"$SCRIPT_DIR/fm-inbox.sh" note --request-id "$REQUEST_ID" -- \
  "Scheduled daily stow: at the next safe checkpoint after current work, run $ELIGIBLE_CMD. If it exits 0, invoke /stow in this live session, including its existing secondmate cascade. If it skips, leave the scheduled pass undone. Never interrupt in-flight work or start a fresh worker for this request."
