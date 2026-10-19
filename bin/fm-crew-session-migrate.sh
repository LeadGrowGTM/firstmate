#!/usr/bin/env bash
# Move this home's live ship and scout tmux windows into the crew session.
#
# Usage: FM_HOME=<home> bin/fm-crew-session-migrate.sh [--apply]
#
# Default is a dry run. It prints the plan and changes no window and no task
# record. --apply performs that plan.
#
# The crew session name is config/crew-tmux-session, including the parent-home
# fallback a new ship window already uses (bin/backends/tmux.sh). An unset or
# unreadable crew session refuses before any move. The command reads only
# regular state/*.meta files in the explicit FM_HOME. It never opens another
# home.
#
# A record whose kind is secondmate is listed and left in place, window and
# record alike. A ship or scout record whose window is not on its recorded
# tmux server is listed as not live and left in place. A non-tmux record is
# listed and left in place. A resolvable record that disagrees with its live
# window refuses the whole command before the first move.
#
# For a ship or scout record whose backend, window, or tmux socket cannot be
# resolved (missing, ambiguous, empty, malformed, or not an absolute path),
# the command prints one warning naming the task and reason, lists it as skip
# unresolvable, and continues migrating the home. Home preconditions,
# resolvable-task preflight, and moves can still fail the command.
#
# A planned move that would empty its source session is refused. tmux closes a
# session when its last window leaves, so the source session has to keep a
# window that this command is not moving.
#
# --apply moves each planned window with `tmux move-window -d` on that task's
# recorded tmux_socket, into the crew session, keeping the window name. It
# then rewrites only that task's window= line through
# fm_backlog_atomic_transition publish, under the task's meta lock, and only
# while the record still names the window that was moved. A failed record
# write moves the window back. A second run is a no-op for windows already
# recorded in the crew session.
#
# The window name is not used to decide which records are crew. kind= is.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "error: unknown argument '${1:-}'. Usage: FM_HOME=<home> $0 [--apply]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "error: unexpected extra argument. Usage: FM_HOME=<home> $0 [--apply]" >&2
  exit 2
fi

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-crew-session-migrate refuses to choose a home" >&2
  exit 2
fi
if [ ! -d "$FM_HOME" ] || [ -L "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; nothing in this home can be moved" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if ! declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
fi
fm_backend_source tmux >/dev/null

CREW_SESSION=$(fm_backend_tmux_crew_session) || exit 1
if [ -z "$CREW_SESSION" ]; then
  echo "error: config/crew-tmux-session is unset for $FM_HOME; set it before moving windows" >&2
  exit 1
fi

MIGRATE_LOCK=
PLAN=
SKIP_FILE=
LIST_FILE=
SKIP_SUMMARY_PRINTED=0
# shellcheck disable=SC2329  # Registered by the EXIT trap below.
cleanup() {
  if [ "$SKIP_SUMMARY_PRINTED" -eq 0 ] && [ -s "${SKIP_FILE:-}" ]; then
    fm_crew_migrate_summary
  fi
  if [ -n "${MIGRATE_LOCK:-}" ]; then
    fm_lock_release "$MIGRATE_LOCK" || true
    MIGRATE_LOCK=
  fi
  [ -z "${PLAN:-}" ] || rm -f "$PLAN"
  [ -z "${SKIP_FILE:-}" ] || rm -f "$SKIP_FILE"
  [ -z "${LIST_FILE:-}" ] || rm -f "$LIST_FILE"
}
trap cleanup EXIT

PLAN=$(mktemp "${TMPDIR:-/tmp}/fm-crew-session-plan.XXXXXX") || exit 1
SKIP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-crew-session-skip.XXXXXX") || exit 1

refuse() {
  echo "error: $*" >&2
  exit 1
}

# One task whose record cannot name its endpoint: warn, list it in the summary,
# and let the caller return so the rest of the home still migrates.
fm_crew_migrate_unresolvable() {  # <id> <reason>
  echo "warning: task $1: $2; skipping it and migrating the rest of the home" >&2
  printf 'skip unresolvable %s %s\n' "$1" "$2" >>"$SKIP_FILE"
}

fm_crew_migrate_summary() {
  printf 'crew-session: %s\n' "$CREW_SESSION"
  if [ -s "$SKIP_FILE" ]; then
    cat "$SKIP_FILE"
  fi
  SKIP_SUMMARY_PRINTED=1
}

fm_crew_migrate_absent_listing() {  # <listing>
  case "$1" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      return 0
      ;;
  esac
  return 1
}

# Prints the live window id. Returns 2 when that window is not on the server.
fm_crew_migrate_probe() {  # <socket> <id> <session> <window-name>
  local socket=$1 id=$2 session=$3 window_name=$4
  local fmt listing status=0 live_ses live_id live_name live_sock wid
  local found_ses='' found_id='' found_count=0 distinct_ids=0 seen_ids=''
  fmt=$'#{session_name}\t#{window_id}\t#{window_name}'
  listing=$(fm_backend_tmux_with_socket "$socket" tmux list-windows -a -F "$fmt" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    if fm_crew_migrate_absent_listing "$listing"; then
      return 2
    fi
    echo "error: task $id: could not list windows on its recorded server" >&2
    return 1
  fi
  while IFS=$'\t' read -r live_ses live_id live_name; do
    [ -n "${live_name:-}" ] || continue
    [ "$live_name" = "$window_name" ] || continue
    found_count=$((found_count + 1))
    case " $seen_ids " in
      *" $live_id "*) ;;
      *)
        seen_ids="$seen_ids $live_id"
        distinct_ids=$((distinct_ids + 1))
        ;;
    esac
    if [ -z "$found_ses" ] || [ "$live_ses" = "$session" ]; then
      found_ses=$live_ses
      found_id=$live_id
    fi
  done <<EOF
$listing
EOF
  if [ "$found_count" -eq 0 ]; then
    return 2
  fi
  if [ "$distinct_ids" -gt 1 ]; then
    echo "error: task $id: more than one window named $window_name is on its recorded server" >&2
    return 1
  fi
  if [ "$found_count" -gt 1 ]; then
    echo "error: task $id: window $window_name is linked into more than one session, so move-window would leave a copy in the recorded session" >&2
    return 1
  fi
  if [ "$found_ses" != "$session" ]; then
    echo "error: task $id: recorded window is $session:$window_name but that window is in session $found_ses" >&2
    return 1
  fi
  wid=$found_id
  live_name=$(fm_backend_tmux_with_socket "$socket" tmux display-message -p -t "$wid" '#{window_name}') || {
    echo "error: task $id: could not read window $wid" >&2
    return 1
  }
  live_ses=$(fm_backend_tmux_with_socket "$socket" tmux display-message -p -t "$wid" '#{session_name}') || {
    echo "error: task $id: could not read the session of window $wid" >&2
    return 1
  }
  live_sock=$(fm_backend_tmux_with_socket "$socket" tmux display-message -p -t "$wid" '#{socket_path}') || {
    echo "error: task $id: could not read the server path of window $wid" >&2
    return 1
  }
  if [ "$live_name" != "$window_name" ] || [ "$live_ses" != "$session" ] || [ "$live_sock" != "$socket" ]; then
    echo "error: task $id: recorded window $session:$window_name does not match the live window on its recorded server" >&2
    return 1
  fi
  printf '%s\n' "$wid"
}

fm_crew_migrate_dest_conflict() {  # <socket> <id> <window-id> <window-name>
  local socket=$1 id=$2 wid=$3 window_name=$4
  local fmt listing status=0 live_ses live_id live_name
  fmt=$'#{session_name}\t#{window_id}\t#{window_name}'
  listing=$(fm_backend_tmux_with_socket "$socket" tmux list-windows -t "=$CREW_SESSION" -F "$fmt" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    if fm_crew_migrate_absent_listing "$listing"; then
      return 0
    fi
    echo "error: task $id: could not list crew session $CREW_SESSION" >&2
    return 1
  fi
  while IFS=$'\t' read -r live_ses live_id live_name; do
    [ -n "${live_name:-}" ] || continue
    if [ "$live_id" = "$wid" ]; then
      echo "error: task $id: window $wid is already linked into $CREW_SESSION" >&2
      return 1
    fi
    if [ "$live_name" = "$window_name" ]; then
      echo "error: task $id: session $CREW_SESSION already has a different window named $window_name" >&2
      return 1
    fi
  done <<EOF
$listing
EOF
  return 0
}

fm_crew_migrate_would_close_sessions() {
  local socket session moves listing status count
  [ -s "$PLAN" ] || return 0
  while IFS=$'\t' read -r socket session; do
    [ -n "$socket" ] || continue
    moves=$(awk -F '\t' -v s="$socket" -v n="$session" '$1 == s && $2 == n { c++ } END { print c + 0 }' "$PLAN")
    status=0
    listing=$(fm_backend_tmux_with_socket "$socket" tmux list-windows -t "=$session" -F '#{window_id}' 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
      refuse "could not count windows in session $session on $socket"
    fi
    count=$(printf '%s\n' "$listing" | grep -c . || true)
    if [ "$moves" -ge "$count" ]; then
      refuse "moving the planned windows would close session $session; tmux destroys a session when its last window leaves. Leave a window in that session and run again"
    fi
  done <<EOF
$(awk -F '\t' '{ print $1 "\t" $2 }' "$PLAN" | LC_ALL=C sort -u)
EOF
  return 0
}

fm_crew_migrate_rewrite() {  # <meta> <id> <old> <new>
  local meta=$1 id=$2 old=$3 new=$4 tmp line seen=0
  tmp=$(mktemp "$STATE/.$id.meta.crew-session.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "window=$old")
        if [ "$seen" -ne 0 ]; then
          rm -f "$tmp"
          return 1
        fi
        printf 'window=%s\n' "$new" >>"$tmp" || { rm -f "$tmp"; return 1; }
        seen=1
        ;;
      *)
        printf '%s\n' "$line" >>"$tmp" || { rm -f "$tmp"; return 1; }
        ;;
    esac
  done <"$meta" || { rm -f "$tmp"; return 1; }
  if [ "$seen" -ne 1 ]; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_crew_migrate_release() {
  if [ -n "${MIGRATE_LOCK:-}" ]; then
    fm_lock_release "$MIGRATE_LOCK" || true
    MIGRATE_LOCK=
  fi
}

fm_crew_migrate_apply_one() {  # <socket> <session> <id> <old> <wid> <new>
  local socket=$1 session=$2 id=$3 old=$4 wid=$5 new=$6
  local meta="$STATE/$id.meta" lock current kind now_socket now_wid
  local probe_status listing count live_ses live_name
  lock=$(fm_meta_lock_path "$meta") || refuse "task $id: could not name its record lock"
  fm_lock_acquire_wait "$lock"
  MIGRATE_LOCK=$lock
  current=$(fm_backend_meta_exact_value "$meta" window) || {
    fm_crew_migrate_release
    refuse "task $id: recorded window changed or is ambiguous before the move"
  }
  if [ "$current" != "$old" ]; then
    fm_crew_migrate_release
    refuse "task $id: recorded window changed from $old to $current before the move"
  fi
  kind=$(fm_backend_meta_exact_value "$meta" kind) || {
    fm_crew_migrate_release
    refuse "task $id: kind changed before the move"
  }
  case "$kind" in
    ship|scout) ;;
    *)
      fm_crew_migrate_release
      refuse "task $id: kind changed to '$kind' before the move"
      ;;
  esac
  now_socket=$(fm_backend_meta_exact_value "$meta" tmux_socket) || {
    fm_crew_migrate_release
    refuse "task $id: recorded tmux socket changed before the move"
  }
  if [ "$now_socket" != "$socket" ]; then
    fm_crew_migrate_release
    refuse "task $id: recorded tmux socket changed before the move"
  fi
  probe_status=0
  now_wid=$(fm_crew_migrate_probe "$socket" "$id" "$session" "fm-$id") || probe_status=$?
  if [ "$probe_status" -ne 0 ]; then
    fm_crew_migrate_release
    if [ "$probe_status" -eq 2 ]; then
      refuse "task $id: window disappeared before the move"
    fi
    exit 1
  fi
  if [ "$now_wid" != "$wid" ]; then
    fm_crew_migrate_release
    refuse "task $id: window id changed from $wid to $now_wid before the move"
  fi
  listing=$(fm_backend_tmux_with_socket "$socket" tmux list-windows -t "=$session" -F '#{window_id}') || {
    fm_crew_migrate_release
    refuse "task $id: could not recount session $session"
  }
  count=$(printf '%s\n' "$listing" | grep -c . || true)
  if [ "$count" -lt 2 ]; then
    fm_crew_migrate_release
    refuse "task $id: moving $old would close session $session"
  fi
  if ! fm_backend_tmux_with_socket "$socket" tmux move-window -d -s "$wid" -t "=$CREW_SESSION:"; then
    fm_crew_migrate_release
    refuse "task $id: tmux could not move $wid into $CREW_SESSION"
  fi
  live_ses=$(fm_backend_tmux_with_socket "$socket" tmux display-message -p -t "$wid" '#{session_name}' 2>/dev/null || true)
  live_name=$(fm_backend_tmux_with_socket "$socket" tmux display-message -p -t "$wid" '#{window_name}' 2>/dev/null || true)
  if [ "$live_ses" != "$CREW_SESSION" ] || [ "$live_name" != "fm-$id" ]; then
    fm_backend_tmux_with_socket "$socket" tmux move-window -d -s "$wid" -t "=$session:" >/dev/null 2>&1 || true
    fm_crew_migrate_release
    refuse "task $id: window $wid landed as ${live_ses:-unknown}:${live_name:-unknown} instead of $new"
  fi
  if fm_backend_tmux_with_socket "$socket" tmux list-windows -t "=$session" -F '#{window_id}' 2>/dev/null | grep -qxF "$wid"; then
    fm_backend_tmux_with_socket "$socket" tmux move-window -d -s "$wid" -t "=$session:" >/dev/null 2>&1 || true
    fm_crew_migrate_release
    refuse "task $id: window $wid is still in session $session after move-window"
  fi
  if ! fm_crew_migrate_rewrite "$meta" "$id" "$old" "$new"; then
    if ! fm_backend_tmux_with_socket "$socket" tmux move-window -d -s "$wid" -t "=$session:" >/dev/null 2>&1; then
      echo "error: task $id: the record was not updated and window $wid could not be moved back to $session" >&2
    fi
    fm_crew_migrate_release
    refuse "task $id: could not record $new"
  fi
  current=$(fm_backend_meta_exact_value "$meta" window) || current=
  if [ "$current" != "$new" ]; then
    fm_crew_migrate_release
    refuse "task $id: record reads '${current:-empty}' after writing $new"
  fi
  fm_crew_migrate_release
  printf 'moved %s %s -> %s\n' "$id" "$old" "$new"
}

fm_crew_migrate_classify() {  # <meta>
  local meta=$1 base id kind_count kind='' backend_count backend window session window_name
  local socket wid probe_status
  if [ -L "$meta" ]; then
    refuse "task record $meta is a symlink; this command only reads regular files in this home's state directory"
  fi
  if [ ! -f "$meta" ]; then
    refuse "task record $meta is not a regular file"
  fi
  base=${meta##*/}
  id=${base%.meta}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      refuse "task record name $base is not a task id this command can lock"
      ;;
  esac
  kind_count=$(grep -c '^kind=' "$meta" 2>/dev/null || true)
  if [ "$kind_count" -eq 1 ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2-)
    if [ "$kind" = secondmate ]; then
      printf 'skip mate %s\n' "$id" >>"$SKIP_FILE"
      return 0
    fi
  fi
  case "$kind_count" in
    1) ;;
    *)
      refuse "task $id: has $kind_count kind fields; exactly one is required"
      ;;
  esac
  case "$kind" in
    ship|scout) ;;
    *)
      refuse "task $id: kind '$kind' is neither a second mate nor a ship or scout"
      ;;
  esac
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0) backend=tmux ;;
    1) backend=$(grep '^backend=' "$meta" | cut -d= -f2-) ;;
    *)
      fm_crew_migrate_unresolvable "$id" "recorded backend is ambiguous ($backend_count fields)"
      return 0
      ;;
  esac
  if [ -z "$backend" ]; then
    fm_crew_migrate_unresolvable "$id" "recorded backend is empty"
    return 0
  fi
  if [ "$backend" != tmux ]; then
    printf 'skip other-backend %s %s\n' "$id" "$backend" >>"$SKIP_FILE"
    return 0
  fi
  window=$(fm_backend_meta_exact_value "$meta" window) || {
    fm_crew_migrate_unresolvable "$id" "recorded window is missing or ambiguous"
    return 0
  }
  case "$window" in
    *:*) ;;
    *)
      fm_crew_migrate_unresolvable "$id" "recorded window '$window' is not session:window"
      return 0
      ;;
  esac
  session=${window%%:*}
  window_name=${window#*:}
  if [ "$window_name" != "fm-$id" ] || [ -z "$session" ]; then
    fm_crew_migrate_unresolvable "$id" "recorded window '$window' does not belong to fm-$id"
    return 0
  fi
  case "$session" in
    *[!A-Za-z0-9_-]*|''|[!A-Za-z0-9]*)
      fm_crew_migrate_unresolvable "$id" "recorded session '$session' is not a tmux session name"
      return 0
      ;;
  esac
  socket=$(fm_backend_meta_exact_value "$meta" tmux_socket) || {
    fm_crew_migrate_unresolvable "$id" "recorded tmux socket is missing or ambiguous"
    return 0
  }
  case "$socket" in
    /*) ;;
    *)
      fm_crew_migrate_unresolvable "$id" "recorded tmux socket is not an absolute path"
      return 0
      ;;
  esac
  case "$socket" in
    *[$'\n\r\t,']*)
      fm_crew_migrate_unresolvable "$id" "recorded tmux socket cannot be used as a server address"
      return 0
      ;;
  esac
  probe_status=0
  wid=$(fm_crew_migrate_probe "$socket" "$id" "$session" "$window_name") || probe_status=$?
  if [ "$probe_status" -eq 2 ]; then
    printf 'skip not-live %s\n' "$id" >>"$SKIP_FILE"
    return 0
  fi
  if [ "$probe_status" -ne 0 ]; then
    exit 1
  fi
  if [ "$session" = "$CREW_SESSION" ]; then
    printf 'already %s %s\n' "$id" "$window" >>"$SKIP_FILE"
    return 0
  fi
  fm_crew_migrate_dest_conflict "$socket" "$id" "$wid" "$window_name" || exit 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$socket" "$session" "$id" "$window" "$wid" "$CREW_SESSION:$window_name" >>"$PLAN"
}

shopt -s nullglob
metas=( "$STATE"/*.meta )
shopt -u nullglob
if [ "${#metas[@]}" -gt 0 ]; then
  LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-crew-session-list.XXXXXX") || exit 1
  printf '%s\n' "${metas[@]}" | LC_ALL=C sort >"$LIST_FILE"
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    fm_crew_migrate_classify "$meta"
  done <"$LIST_FILE"
  rm -f "$LIST_FILE"
  LIST_FILE=
fi

fm_crew_migrate_would_close_sessions

fm_crew_migrate_summary
if [ -s "$PLAN" ]; then
  sockets=$(awk -F '\t' '{ print $1 }' "$PLAN" | LC_ALL=C sort -u)
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    if [ "$APPLY" -eq 1 ]; then
      fm_backend_tmux_with_socket "$socket" fm_backend_tmux_ensure_named_session "$CREW_SESSION" >/dev/null \
        || refuse "could not open crew session $CREW_SESSION"
    elif ! fm_backend_tmux_with_socket "$socket" tmux has-session -t "=$CREW_SESSION" 2>/dev/null; then
      printf 'would-create-session %s\n' "$CREW_SESSION"
    fi
  done <<EOF
$sockets
EOF
  if [ "$APPLY" -eq 0 ]; then
    while IFS=$'\t' read -r _socket _session id old _wid new; do
      [ -n "$id" ] || continue
      printf 'would-move %s %s -> %s\n' "$id" "$old" "$new"
    done <"$PLAN"
  else
    while IFS=$'\t' read -r socket session id old wid new; do
      [ -n "$id" ] || continue
      fm_crew_migrate_apply_one "$socket" "$session" "$id" "$old" "$wid" "$new"
    done <"$PLAN"
  fi
fi
exit 0
