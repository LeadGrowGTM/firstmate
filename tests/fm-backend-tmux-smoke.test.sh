#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_shell_ready() {
  local target=$1
  for _ in $(seq 1 100); do
    tmux send-keys -t "$target" C-c
    tmux send-keys -t "$target" -l "printf 'shell-%s\\n' ready"
    tmux send-keys -t "$target" Enter
    wait_for_capture_text "$target" "shell-ready" 10 && return 0
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
OUTER_SOCKET=
HIDDEN_SOCKET=
ROOTED_PID=
SHIM_DIR=

cleanup_all() {
  [ -z "$ROOTED_PID" ] || { kill "$ROOTED_PID" 2>/dev/null || true; wait "$ROOTED_PID" 2>/dev/null || true; }
  [ -z "$OUTER_SOCKET" ] || "$REAL_TMUX" -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$HIDDEN_SOCKET" ] || "$REAL_TMUX" -L "$HIDDEN_SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SMOKE_TMP_PARENT=${TMPDIR:-/tmp}
if [ -n "${FM_TEST_TMUX_REAL:-}" ] && [ "$REAL_TMUX" != "$FM_TEST_TMUX_REAL" ] &&
   [ "${TMUX_TMPDIR:-}" = "${REAL_TMUX%/bin/tmux}/s" ]; then
  SMOKE_TMP_PARENT=$TMUX_TMPDIR
fi
SHIM_DIR=$(mktemp -d "$SMOKE_TMP_PARENT/fm-backend-smoke.XXXXXX") || exit 1
[ -d "$SHIM_DIR" ] && [ ! -L "$SHIM_DIR" ] || exit 1
TMUX_TMPDIR="$SHIM_DIR/tmux-tmp"
export TMUX_TMPDIR
unset TMUX TMUX_PANE || exit 1
trap cleanup_all EXIT
mkdir -m 700 -- "$TMUX_TMPDIR" || fail 'could not create the private tmux socket directory'
PS_SHIM_DIR="$SHIM_DIR/ps-bin"
mkdir -p "$PS_SHIM_DIR"
FM_TEST_PRIVATE_PIDS="$SHIM_DIR/private-pids"
FM_TEST_REAL_PS=$(command -v ps)
export FM_TEST_PRIVATE_PIDS FM_TEST_REAL_PS
cat > "$PS_SHIM_DIR/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ "${3:-}" = -o ] && [ "${4:-}" = pid= ]; then
  if [ "$#" -eq 4 ]; then cat "$FM_TEST_PRIVATE_PIDS"; exit; fi
  pids=$(paste -sd, "$FM_TEST_PRIVATE_PIDS")
  [ -n "$pids" ] || exit 0
  shift 2
  exec "$FM_TEST_REAL_PS" -p "$pids" "$@"
fi
exec "$FM_TEST_REAL_PS" "$@"
SH
chmod +x "$PS_SHIM_DIR/ps"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# A near-named session must never satisfy the default container or receive a
# worker whose recorded session is firstmate. All calls use the private socket.
tmux new-session -d -s firstmate-recovery -n recovery || fail "could not seed near-named session"
got=$(TMUX='' TMUX_PANE='' fm_backend_tmux_container_ensure) || fail "could not ensure exact default session"
[ "$got" = firstmate ] || fail "default container returned '$got'"
tmux has-session -t '=firstmate' || fail "near-named session prevented exact default session creation"
fm_backend_tmux_create_task "$got" fm-exact "$HOME" || fail "could not create exact-session worker"
fm_backend_tmux_window_inventory '=firstmate' | grep -qx fm-exact || fail "capacity inventory missed the spawned worker"
if tmux list-windows -t '=firstmate-recovery' -F '#{window_name}' | grep -qx fm-exact; then
  fail "worker landed in the near-named session"
fi
tmux kill-session -t '=firstmate'
if fm_backend_tmux_create_task firstmate fm-missing "$HOME" 2>/dev/null; then
  fail "missing exact session fell back to the near-named session"
fi
pass "real tmux: default spawn and inventory share the exact session, with no prefix fallback"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
wait_for_shell_ready "$TARGET" || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" \
  || fail "the tmux task shell did not complete setup: $(fm_backend_tmux_capture "$TARGET" 80 2>&1)"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- crew label: display changes, the addressed name does not ---------------

tmux set-window-option -gu window-status-format || fail "could not restore the built-in window-status-format"
tmux set-window-option -gu window-status-current-format || fail "could not restore the built-in window-status-current-format"
builtin=$(tmux show-window-options -gv window-status-format)
builtin_current=$(tmux show-window-options -gv window-status-current-format)
local_format=$(tmux show-window-options -v -t "$TARGET" window-status-format)
local_current=$(tmux show-window-options -v -t "$TARGET" window-status-current-format)
fm_backend_tmux_show_label "$TARGET" "nap-crew-smoke1" || fail "fm_backend_tmux_show_label failed"
[ "$(tmux display-message -p -t "$TARGET" '#{window_name}')" = "$WINDOW" ] \
  || fail "showing a label renamed the addressed window"
[ "$(tmux show-window-options -v -t "$TARGET" @fm_label)" = "nap-crew-smoke1" ] \
  || fail "the label was not recorded on the window"
[ "$(tmux show-window-options -gv window-status-format)" = "$builtin" ] || fail "labeling changed the built-in window-status-format"
[ "$(tmux show-window-options -gv window-status-current-format)" = "$builtin_current" ] || fail "labeling changed the built-in window-status-current-format"
[ "$(tmux show-window-options -v -t "$TARGET" window-status-format)" = "$local_format" ] || fail "labeling changed the window's status format"
[ "$(tmux show-window-options -v -t "$TARGET" window-status-current-format)" = "$local_current" ] || fail "labeling changed the window's current status format"
for opt in window-status-format window-status-current-format; do
  shown=$(tmux display-message -p -t "$TARGET" "$(tmux show-window-options -gv "$opt")")
  case "$shown" in *"$WINDOW"*) ;; *) fail "the built-in $opt changed the plain name to '$shown'" ;; esac
done
pass "real tmux: a crew label leaves built-in status formats and the addressed name unchanged"

idx=0
for custom in ' #I:#W ' ' #I:#W#F ' '#I:#{window_name}' '#I:#{=20:window_name}' '#I'; do
  idx=$((idx + 1))
  tmux set-window-option -g window-status-format "$custom" || fail "could not set custom format $idx"
  tmux set-window-option -g window-status-current-format "$custom" || fail "could not set custom current format $idx"
  fm_backend_tmux_create_task "$SESSION" "fm-custom$idx" "$HOME" >/dev/null || fail "could not create custom window $idx"
  local_format=$(tmux show-window-options -v -t "$SESSION:fm-custom$idx" window-status-format)
  local_current=$(tmux show-window-options -v -t "$SESSION:fm-custom$idx" window-status-current-format)
  fm_backend_tmux_show_label "$SESSION:fm-custom$idx" "nap-crew-custom$idx" || fail "custom format '$custom' refused the label"
  for opt in window-status-format window-status-current-format; do
    [ "$(tmux show-window-options -gv "$opt")" = "$custom" ] || fail "labeling changed custom $opt '$custom'"
    case "$opt" in
      window-status-format) expected=$local_format ;;
      window-status-current-format) expected=$local_current ;;
    esac
    [ "$(tmux show-window-options -v -t "$SESSION:fm-custom$idx" "$opt")" = "$expected" ] \
      || fail "labeling changed the window's custom $opt '$custom'"
    shown=$(tmux display-message -p -t "$SESSION:fm-custom$idx" "$(tmux show-window-options -gv "$opt")")
    case "$shown" in *nap-crew-custom$idx*) fail "custom $opt '$custom' showed the crew label as '$shown'" ;; esac
  done
  tmux kill-window -t "$SESSION:fm-custom$idx"
done
pass "real tmux: a crew label leaves custom status formats unchanged"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created, labeled window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# A readable inventory on one socket says nothing about the endpoint on a
# different socket. Keep both servers private and prove both CLI observations.
HIDDEN_SOCKET="$SOCKET-hidden"
PROOF_SPAWN_EPOCH=$(date +%s)
"$REAL_TMUX" -L "$HIDDEN_SOCKET" new-session -d -s hidden -n agent \
  || fail 'could not create the endpoint on the hidden private socket'
[ "$(fm_backend_agent_state tmux hidden:agent)" = missing ] \
  || fail 'the current private socket unexpectedly sees the hidden endpoint'
"$REAL_TMUX" -L "$HIDDEN_SOCKET" has-session -t '=hidden:agent' \
  || fail 'the recorded private socket lost its live endpoint'
pass 'real tmux: a second private server can hide a live endpoint from the current socket'

# Exercise the recovery proof through the public control command, with real
# tmux reads and a real cwd inventory rather than a canned missing verdict.
PROOF_HOME="$SHIM_DIR/proof-home"
PROOF_COPY="$SHIM_DIR/recorded-worktree"
mkdir -p "$PROOF_HOME/state" "$PROOF_COPY/nested"
"$REAL_TMUX" -L "$SOCKET" display-message -p '#{pid}' > "$FM_TEST_PRIVATE_PIDS"
RECORDED_SOCKET=$("$REAL_TMUX" -L "$HIDDEN_SOCKET" display-message -p -t hidden:agent '#{socket_path}')
cat > "$PROOF_HOME/state/recovery.meta" <<EOF
window=hidden:fm-recovery
endpoint_task_id=recovery
tmux_socket=$RECORDED_SOCKET
worktree=$PROOF_COPY
project=$ROOT
harness=codex
kind=ship
spawn_gen=s${PROOF_SPAWN_EPOCH}.1.1
EOF
"$REAL_TMUX" -L "$HIDDEN_SOCKET" kill-server \
  || fail 'could not remove the recorded private server before recovery proof'
proof_out=$(PATH="$PS_SHIM_DIR:${PATH#*:}" FM_HOME="$PROOF_HOME" FM_GATE_REFUSE_BYPASS=1 \
  bash "$ROOT/bin/fm-control.sh" recovery exit 2>&1) \
  || fail "real missing-endpoint control proof failed: $proof_out"
case "$proof_out" in *endpoint-gone*) ;; *) fail "control did not confirm endpoint loss: $proof_out" ;; esac
pass 'real tmux: control proves a missing recorded endpoint gone through its socket and process inventory'

# The process guard must consider a process whose kernel cwd is a descendant
# of the recorded worktree, even when its command line has no worktree path.
if [ -d /proc/self/cwd ]; then
  ROOTED_DIR="$PROOF_COPY/nested"
  mkdir -p "$ROOTED_DIR"
  ( cd "$ROOTED_DIR" && : > "$SHIM_DIR/rooted-ready" && exec /bin/sleep 60 ) &
  ROOTED_PID=$!
  while [ ! -e "$SHIM_DIR/rooted-ready" ]; do sleep 0.01; done
  printf '%s\n' "$ROOTED_PID" >> "$FM_TEST_PRIVATE_PIDS"
  [ "$(readlink "/proc/$ROOTED_PID/cwd")" = "$ROOTED_DIR" ] \
    || fail 'the kernel did not report the process cwd inside the worktree child'
  case "$(ps -p "$ROOTED_PID" -o args=)" in
    *"$ROOTED_DIR"*) fail 'the process fixture leaked the worktree path into its command line' ;;
  esac
  if PATH="$PS_SHIM_DIR:${PATH#*:}" FM_HOME="$PROOF_HOME" FM_GATE_REFUSE_BYPASS=1 \
      bash "$ROOT/bin/fm-control.sh" recovery exit > "$SHIM_DIR/rooted-refusal" 2>&1; then
    fail 'control claimed an orphan process in the preserved copy had stopped'
  fi
  grep -q 'live processes still have cwd' "$SHIM_DIR/rooted-refusal" \
    || fail "control did not identify the surviving process: $(cat "$SHIM_DIR/rooted-refusal")"
  kill -0 "$ROOTED_PID" 2>/dev/null || fail 'control signaled the surviving process'
  pass 'real process: kernel cwd identifies a rooted process that command arguments do not'
fi

# --- container_ensure with a grouped viewer attached ---------------------------
# A viewer such as an Orca view tab attaches through a grouped session
# (`tmux new-session -t <base> -s <view>`). That client is then the most recently
# active one, and tmux answers an untargeted query from it, so a spawn from the
# base session's pane must still record the base session, never the view.
tmux new-session -d -s base -n spawner || fail "real tmux: could not create the base session"
tmux new-session -d -t base -s orca-view || fail "real tmux: could not create the grouped view session"
SPAWNER_PANE=$(tmux display-message -p -t '=base:spawner' '#{pane_id}')
OUTER_SOCKET="$SOCKET-outer"
"$REAL_TMUX" -L "$OUTER_SOCKET" new-session -d -x 80 -y 24 \
  "env -u TMUX -u TMUX_PANE $REAL_TMUX -L $SOCKET attach -t orca-view" \
  || fail "real tmux: could not start the viewer client"
attached=
for _ in $(seq 1 100); do
  attached=$(tmux list-clients -F '#{client_session}' 2>/dev/null)
  [ "$attached" = orca-view ] && break
  sleep 0.05
done
[ "$attached" = orca-view ] || fail "real tmux: the viewer client never attached to the view session"
# Non-vacuous: tmux itself answers the untargeted question with the view.
[ "$(TMUX=x tmux display-message -p '#S')" = orca-view ] \
  || fail "real tmux: an untargeted query should answer from the attached viewer"
got=$(TMUX=x TMUX_PANE="$SPAWNER_PANE" fm_backend_tmux_container_ensure) \
  || fail "fm_backend_tmux_container_ensure failed with a viewer attached"
[ "$got" = base ] || fail "a spawn from the base pane recorded '$got' instead of the base session"
got=$(TMUX=x TMUX_PANE='' fm_backend_tmux_container_ensure) \
  || fail "fm_backend_tmux_container_ensure failed without a pane"
[ "$got" = base ] || fail "a grouped session without a pane must resolve to its base, got '$got'"
got=$(TMUX='' TMUX_PANE='' fm_backend_tmux_container_ensure) \
  || fail "fm_backend_tmux_container_ensure failed outside tmux"
[ "$got" = firstmate ] || fail "outside tmux, the dedicated firstmate session was not selected"
"$REAL_TMUX" -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true
OUTER_SOCKET=
pass "real tmux: container_ensure records the base session while a grouped viewer is attached"

# --- a new window carries a live WSL interop socket ---------------------------
INTEROP_DIR="$SHIM_DIR/run-wsl"
mkdir -p "$INTEROP_DIR"
: > "$INTEROP_DIR/1_interop"
: > "$INTEROP_DIR/2_interop"
cat > "$SHIM_DIR/interop-probe" <<'SH'
#!/bin/sh
case "$WSL_INTEROP" in */2_interop) exit 0 ;; esac
exit 1
SH
chmod +x "$SHIM_DIR/interop-probe"
WSL_WID=$(WSL_INTEROP=/dead/5345_interop FM_WSL_INTEROP_DIR="$INTEROP_DIR" \
  FM_WSL_INTEROP_PROBE="$SHIM_DIR/interop-probe" \
  fm_backend_tmux_create_task base fm-interop "$HOME") \
  || fail "fm_backend_tmux_create_task failed with an interop directory"
wait_for_shell_ready "$WSL_WID" || fail "the tmux interop shell did not become ready"
fm_backend_tmux_send_text_line "$WSL_WID" "printf 'interop=%s\\n' \"\$WSL_INTEROP\""
wait_for_capture_text "$WSL_WID" "interop=$INTEROP_DIR/2_interop" \
  || fail "the new window's shell did not receive the live interop socket"$'\n'"$(fm_backend_tmux_capture "$WSL_WID" 20)"
pass "real tmux: a window created on WSL carries the live interop socket, not the inherited one"

# --- configured captain session ------------------------------------------------
# A launcher sitting in another session must still open mate and crew windows
# in the named session, on this same private server, and must leave the
# launcher's own windows where they are.

CAPTAIN_HOME="$SHIM_DIR/captain-home"
MATE_HOME="$SHIM_DIR/mate-home"
REMOTE_HOME="$SHIM_DIR/remote-home"
mkdir -p "$CAPTAIN_HOME/config" "$MATE_HOME/config" "$REMOTE_HOME/config" "$CAPTAIN_HOME/keep"
printf 'firstmate\n' > "$CAPTAIN_HOME/config/captain-tmux-session"
cat > "$MATE_HOME/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$CAPTAIN_HOME
EOF
cat > "$REMOTE_HOME/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=remote
parent_host=boat
EOF

tmux new-session -d -s churchill-rc -n launcher -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the launcher session on the private socket"
tmux new-window -d -t '=churchill-rc:' -n fm-already -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the pre-existing crew window"
LAUNCH_PANE=$(tmux display-message -p -t '=churchill-rc:launcher' '#{pane_id}')
[ -n "$LAUNCH_PANE" ] || fail "launcher pane id was empty"
ALREADY_ID=$(tmux display-message -p -t '=churchill-rc:fm-already' '#{window_id}')
[ -n "$ALREADY_ID" ] || fail "pre-existing window id was empty"

got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure) \
  || fail "configured container_ensure failed inside another session"
[ "$got" = firstmate ] || fail "configured container returned '$got' instead of firstmate"
[ "$(tmux display-message -p -t "$LAUNCH_PANE" '#{session_name}')" = churchill-rc ] \
  || fail "opening the named session switched the launcher pane's session"
tmux has-session -t '=firstmate' || fail "named session was not created on the private server"
if tmux list-windows -t '=firstmate-recovery' -F '#{window_name}' 2>/dev/null | grep -qx fm-placed; then
  fail "configured session resolved through the near-named session"
fi

PLACED_ID=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
  fm_backend_tmux_create_task "$got" fm-placed "$CAPTAIN_HOME/keep") \
  || fail "could not create the configured-session window"
[ "$(tmux display-message -p -t "$PLACED_ID" '#{session_name}')" = firstmate ] \
  || fail "created window is not in the named session"
[ "$(tmux display-message -p -t "$PLACED_ID" '#{window_name}')" = fm-placed ] \
  || fail "created window was renamed"
PLACED_SOCKET=$(fm_backend_tmux_socket_path "$PLACED_ID") || fail "socket path read failed"
case "$PLACED_SOCKET" in
  "$TMUX_TMPDIR"/*) ;;
  *) fail "recorded socket is not this private server: $PLACED_SOCKET" ;;
esac
[ "$PLACED_SOCKET" = "$(tmux display-message -p -t "$PLACED_ID" '#{socket_path}')" ] \
  || fail "socket path does not match the server that holds the window"
fm_backend_tmux_target_exists "firstmate:fm-placed" \
  || fail "session:window endpoint is not addressable"
if tmux list-windows -t '=churchill-rc' -F '#{window_name}' | grep -qx fm-placed; then
  fail "configured create_task also landed the window in the launcher session"
fi
tmux list-windows -t '=churchill-rc' -F '#{window_id}' | grep -qx "$ALREADY_ID" \
  || fail "configuring a session moved or removed the pre-existing window"
[ "$(tmux display-message -p -t "$ALREADY_ID" '#{window_name}')" = fm-already ] \
  || fail "pre-existing window was renamed"
pass "real tmux: a configured session receives the new window on the same server"

# The one-time link uses the window id, skips an id already in the target
# session, and leaves the source window in place.
link_into_firstmate() {
  local ses=$1 wid=$2 win=$3
  [ "$ses" = firstmate ] && return 0
  case "$win" in fm-*) ;; *) return 0 ;; esac
  if tmux list-windows -t '=firstmate' -F '#{window_id}' | grep -qx "$wid"; then
    return 0
  fi
  tmux link-window -d -s "$wid" -t '=firstmate:'
}
link_into_firstmate churchill-rc "$ALREADY_ID" fm-already \
  || fail "could not link the pre-existing window into the named session"
tmux list-windows -t '=firstmate' -F '#{window_id}' | grep -qx "$ALREADY_ID" \
  || fail "linked window is not visible in the named session"
tmux list-windows -t '=churchill-rc' -F '#{window_id}' | grep -qx "$ALREADY_ID" \
  || fail "link removed the window from its original session"
link_into_firstmate churchill-rc "$ALREADY_ID" fm-already \
  || fail "linking an already linked window should be skipped, not fail"
pass "real tmux: link-window by id is idempotent and does not move the window"

got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure) \
  || fail "local secondmate container_ensure failed"
[ "$got" = firstmate ] || fail "local secondmate ignored the parent session and returned '$got'"
printf 'bridge\n' > "$MATE_HOME/config/captain-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure) \
  || fail "secondmate's own session file failed"
[ "$got" = bridge ] || fail "secondmate's own file lost to the parent, got '$got'"
tmux has-session -t '=bridge' || fail "the overriding session was not created"
printf 'firstmate\n' > "$MATE_HOME/config/captain-tmux-session"
: > "$MATE_HOME/config/captain-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure) \
  || fail "an empty own file should fall through to the parent"
[ "$got" = firstmate ] || fail "an empty own file did not use the parent, got '$got'"
pass "real tmux: a local secondmate uses the parent session unless its own file names one"

got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$REMOTE_HOME" fm_backend_tmux_container_ensure) \
  || fail "remote home container_ensure failed"
[ "$got" = churchill-rc ] || fail "remote home with no file left its current session, got '$got'"
pass "real tmux: a remote home with no file keeps the launcher session"

bad=$(mktemp "$SHIM_DIR/bad.XXXXXX")
printf 'not a session\n' > "$CAPTAIN_HOME/config/captain-tmux-session"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
    fm_backend_tmux_container_ensure >"$bad.out" 2>"$bad.err"; then
  fail "an invalid session name should refuse"
fi
grep -q 'not a session' "$bad.err" || fail "invalid name error did not name the value: $(cat "$bad.err")"
[ ! -s "$bad.out" ] || fail "invalid name still printed a session: $(cat "$bad.out")"
printf 'firstmate\nextra\n' > "$CAPTAIN_HOME/config/captain-tmux-session"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
    fm_backend_tmux_container_ensure >"$bad.out" 2>"$bad.err"; then
  fail "a two-line session file should refuse"
fi
grep -q 'one line' "$bad.err" || fail "two-line file error was not specific: $(cat "$bad.err")"
printf 'bad:name\n' > "$MATE_HOME/config/captain-tmux-session"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" \
    fm_backend_tmux_container_ensure >"$bad.out" 2>"$bad.err"; then
  fail "a secondmate's own invalid file should refuse before the parent is used"
fi
rm -f "$MATE_HOME/config/captain-tmux-session"
printf 'also bad\n' > "$CAPTAIN_HOME/config/captain-tmux-session"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" \
    fm_backend_tmux_container_ensure >"$bad.out" 2>"$bad.err"; then
  fail "an invalid parent session file should refuse"
fi
grep -q 'also bad' "$bad.err" || fail "parent file error did not name the value: $(cat "$bad.err")"
rm -f "$CAPTAIN_HOME/config/captain-tmux-session" "$bad.out" "$bad.err"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure) \
  || fail "removing the file should restore the launcher session"
[ "$got" = churchill-rc ] || fail "unset file did not restore today's session, got '$got'"
pass "real tmux: a bad or removed session file refuses or falls back, and never picks a third session"

# --- crew session is separate from the captain session -----------------------
# Ship and scout use config/crew-tmux-session. A second mate stays on the
# captain session. An unset crew file keeps the captain-session placement.

printf 'firstmate\n' > "$CAPTAIN_HOME/config/captain-tmux-session"
printf 'firstmate-crew\n' > "$CAPTAIN_HOME/config/crew-tmux-session"
rm -f "$MATE_HOME/config/captain-tmux-session" "$MATE_HOME/config/crew-tmux-session"

got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure secondmate) \
  || fail "secondmate container_ensure failed with a crew session configured"
[ "$got" = firstmate ] || fail "a second mate followed the crew session, got '$got'"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "ship container_ensure failed"
[ "$got" = firstmate-crew ] || fail "a ship did not use the crew session, got '$got'"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure scout) \
  || fail "scout container_ensure failed"
[ "$got" = firstmate-crew ] || fail "a scout did not use the crew session, got '$got'"
tmux has-session -t '=firstmate-crew' || fail "the crew session was not created"
MATE_WID=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
  fm_backend_tmux_create_task firstmate fm-mate-new "$CAPTAIN_HOME/keep") \
  || fail "could not create the mate window"
CREW_WID=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
  fm_backend_tmux_create_task firstmate-crew fm-crew-new "$CAPTAIN_HOME/keep") \
  || fail "could not create the crew window"
[ "$(tmux display-message -p -t "$MATE_WID" '#{session_name}')" = firstmate ] \
  || fail "mate window was not created in the captain session"
[ "$(tmux display-message -p -t "$CREW_WID" '#{session_name}')" = firstmate-crew ] \
  || fail "crew window was not created in the crew session"
if tmux list-windows -t '=churchill-rc' -F '#{window_name}' | grep -qx fm-crew-new; then
  fail "the crew window also landed in the launcher session"
fi
tmux list-windows -t '=churchill-rc' -F '#{window_id}' | grep -qx "$ALREADY_ID" \
  || fail "opening the crew session moved the pre-existing launcher window"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
    fm_backend_tmux_container_ensure weird >"$bad.out" 2>"$bad.err"; then
  fail "an unknown task kind should refuse"
fi
grep -q 'weird' "$bad.err" || fail "unknown kind error did not name the kind: $(cat "$bad.err")"
pass "real tmux: a mate window uses the captain session and a crew window uses the crew session"

rm -f "$CAPTAIN_HOME/config/crew-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "ship container_ensure failed with the crew file removed"
[ "$got" = firstmate ] || fail "an unset crew file did not keep the captain session, got '$got'"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure '') \
  || fail "empty-kind container_ensure failed with the crew file removed"
[ "$got" = firstmate ] || fail "an empty kind did not keep the captain session, got '$got'"
pass "real tmux: an unset crew session keeps the captain-session placement"

printf 'firstmate-crew\n' > "$CAPTAIN_HOME/config/crew-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "local secondmate ship container_ensure failed"
[ "$got" = firstmate-crew ] || fail "a local secondmate ignored the parent's crew session, got '$got'"
printf 'mate-crew\n' > "$MATE_HOME/config/crew-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "secondmate's own crew file failed"
[ "$got" = mate-crew ] || fail "secondmate's own crew file lost to the parent, got '$got'"
tmux has-session -t '=mate-crew' || fail "the overriding crew session was not created"
: > "$MATE_HOME/config/crew-tmux-session"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$MATE_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "an empty own crew file should fall through to the parent"
[ "$got" = firstmate-crew ] || fail "an empty own crew file did not use the parent, got '$got'"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$REMOTE_HOME" fm_backend_tmux_container_ensure ship) \
  || fail "remote ship container_ensure failed"
[ "$got" = churchill-rc ] || fail "a remote home inherited a local crew session, got '$got'"
printf 'not a crew\n' > "$CAPTAIN_HOME/config/crew-tmux-session"
if TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" \
    fm_backend_tmux_container_ensure ship >"$bad.out" 2>"$bad.err"; then
  fail "an invalid crew session name should refuse"
fi
grep -q 'not a crew' "$bad.err" || fail "invalid crew name error did not name the value: $(cat "$bad.err")"
got=$(TMUX=x TMUX_PANE="$LAUNCH_PANE" FM_HOME="$CAPTAIN_HOME" fm_backend_tmux_container_ensure secondmate) \
  || fail "a bad crew file made the mate session fail"
[ "$got" = firstmate ] || fail "a bad crew file changed the mate session, got '$got'"
printf 'firstmate-crew\n' > "$CAPTAIN_HOME/config/crew-tmux-session"
rm -f "$MATE_HOME/config/crew-tmux-session" "$bad.out" "$bad.err"
pass "real tmux: crew session inheritance matches the captain session, and a remote home does not inherit it"

# --- one-time migration of this home's live crew windows ---------------------

write_task_meta() {  # <home> <id> <kind> <window> <socket> [backend]
  local home=$1 id=$2 kind=$3 window=$4 socket=$5 backend=${6:-}
  mkdir -p "$home/state" "$home/config"
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$home"
    printf 'project=%s\n' "$home"
    printf 'harness=grok\n'
    printf 'kind=%s\n' "$kind"
    printf 'spawn_gen=s1\n'
    printf 'note=keep-me\n'
    if [ -n "$backend" ]; then
      printf 'backend=%s\n' "$backend"
    fi
    if [ -n "$socket" ]; then
      printf 'tmux_socket=%s\n' "$socket"
    fi
  } >"$home/state/$id.meta"
}

if tmux has-session -t '=firstmate-crew' 2>/dev/null; then
  tmux kill-session -t '=firstmate-crew'
fi
tmux new-session -d -s holding -n keeper -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the holding session"
tmux new-window -d -t '=holding:' -n fm-crewtask -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the crew task window"
tmux new-window -d -t '=holding:' -n fm-mate -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the mate task window"
tmux new-window -d -t '=holding:' -n fm-foreign -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the foreign task window"
CREW_TASK_WID=$(tmux display-message -p -t '=holding:fm-crewtask' '#{window_id}')
MATE_TASK_WID=$(tmux display-message -p -t '=holding:fm-mate' '#{window_id}')
FOREIGN_WID=$(tmux display-message -p -t '=holding:fm-foreign' '#{window_id}')
HOLD_SOCK=$(tmux display-message -p -t "$CREW_TASK_WID" '#{socket_path}')
[ -n "$CREW_TASK_WID" ] && [ -n "$HOLD_SOCK" ] || fail "holding window identity was empty"
wait_for_shell_ready "$CREW_TASK_WID" || fail "the crew task shell did not become ready"
fm_backend_tmux_send_text_line "$CREW_TASK_WID" "printf 'migrate-marker\\n'"
wait_for_capture_text "$CREW_TASK_WID" "migrate-marker" \
  || fail "the crew task pane did not show its marker"

MIGRATE_HOME="$SHIM_DIR/migrate-home"
FOREIGN_HOME="$SHIM_DIR/foreign-home"
MISMATCH_HOME="$SHIM_DIR/mismatch-home"
SOLO_HOME="$SHIM_DIR/solo-home"
UNSET_HOME="$SHIM_DIR/unset-home"
mkdir -p "$MIGRATE_HOME/config" "$FOREIGN_HOME/state" "$MISMATCH_HOME/config" \
  "$SOLO_HOME/config" "$UNSET_HOME/config"
printf 'firstmate-crew\n' > "$MIGRATE_HOME/config/crew-tmux-session"
printf 'firstmate-crew\n' > "$MISMATCH_HOME/config/crew-tmux-session"
printf 'firstmate-crew\n' > "$SOLO_HOME/config/crew-tmux-session"
write_task_meta "$MIGRATE_HOME" crewtask ship "holding:fm-crewtask" "$HOLD_SOCK"
write_task_meta "$MIGRATE_HOME" mate secondmate "holding:fm-mate" "$HOLD_SOCK"
write_task_meta "$MIGRATE_HOME" gone ship "holding:fm-gone" "$HOLD_SOCK"
write_task_meta "$MIGRATE_HOME" herdrtask ship "herdr:fm-herdrtask" "$HOLD_SOCK" herdr
write_task_meta "$FOREIGN_HOME" foreign ship "holding:fm-foreign" "$HOLD_SOCK"
cp "$MIGRATE_HOME/state/crewtask.meta" "$MIGRATE_HOME/state/crewtask.meta.before"
cp "$MIGRATE_HOME/state/mate.meta" "$MIGRATE_HOME/state/mate.meta.before"
cp "$MIGRATE_HOME/state/gone.meta" "$MIGRATE_HOME/state/gone.meta.before"
cp "$MIGRATE_HOME/state/herdrtask.meta" "$MIGRATE_HOME/state/herdrtask.meta.before"
cp "$FOREIGN_HOME/state/foreign.meta" "$FOREIGN_HOME/state/foreign.meta.before"

dry=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$MIGRATE_HOME" "$ROOT/bin/fm-crew-session-migrate.sh") \
  || fail "dry run failed: $dry"
case "$dry" in
  *'would-move crewtask holding:fm-crewtask -> firstmate-crew:fm-crewtask'*) ;;
  *) fail "dry run did not plan the crew move: $dry" ;;
esac
case "$dry" in
  *'would-create-session firstmate-crew'*) ;;
  *) fail "dry run did not plan creating the crew session: $dry" ;;
esac
case "$dry" in
  *'skip mate mate'*) ;;
  *) fail "dry run did not leave the mate in place: $dry" ;;
esac
case "$dry" in
  *'skip not-live gone'*) ;;
  *) fail "dry run did not skip the missing window: $dry" ;;
esac
case "$dry" in
  *'skip other-backend herdrtask herdr'*) ;;
  *) fail "dry run did not skip the non-tmux record: $dry" ;;
esac
case "$dry" in
  *foreign*) fail "dry run mentioned another home's task: $dry" ;;
esac
cmp "$MIGRATE_HOME/state/crewtask.meta" "$MIGRATE_HOME/state/crewtask.meta.before" \
  || fail "dry run rewrote the crew record"
cmp "$MIGRATE_HOME/state/mate.meta" "$MIGRATE_HOME/state/mate.meta.before" \
  || fail "dry run rewrote the mate record"
cmp "$FOREIGN_HOME/state/foreign.meta" "$FOREIGN_HOME/state/foreign.meta.before" \
  || fail "dry run rewrote another home's record"
tmux list-windows -t '=holding' -F '#{window_id}' | grep -qx "$CREW_TASK_WID" \
  || fail "dry run moved the crew window"
tmux has-session -t '=firstmate-crew' && fail "dry run created the crew session"
pass "real tmux: migration dry run changes nothing"

applied=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$MIGRATE_HOME" "$ROOT/bin/fm-crew-session-migrate.sh" --apply) \
  || fail "migration apply failed: $applied"
case "$applied" in
  *'moved crewtask holding:fm-crewtask -> firstmate-crew:fm-crewtask'*) ;;
  *) fail "apply did not report the move: $applied" ;;
esac
[ "$(tmux display-message -p -t "$CREW_TASK_WID" '#{session_name}')" = firstmate-crew ] \
  || fail "the crew window is not in the crew session"
[ "$(tmux display-message -p -t "$CREW_TASK_WID" '#{window_name}')" = fm-crewtask ] \
  || fail "the move renamed the crew window"
if tmux list-windows -t '=holding' -F '#{window_id}' | grep -qx "$CREW_TASK_WID"; then
  fail "the crew window is still in the holding session"
fi
[ "$(tmux display-message -p -t "$MATE_TASK_WID" '#{session_name}')" = holding ] \
  || fail "the mate window left its session"
[ "$(tmux display-message -p -t "$FOREIGN_WID" '#{session_name}')" = holding ] \
  || fail "another home's window left its session"
grep -qx 'window=firstmate-crew:fm-crewtask' "$MIGRATE_HOME/state/crewtask.meta" \
  || fail "the crew record does not name the new window"
grep -qx "tmux_socket=$HOLD_SOCK" "$MIGRATE_HOME/state/crewtask.meta" \
  || fail "the move rewrote the recorded server"
grep -qx 'note=keep-me' "$MIGRATE_HOME/state/crewtask.meta" \
  || fail "the move dropped another record field"
grep -qx 'kind=ship' "$MIGRATE_HOME/state/crewtask.meta" \
  || fail "the move changed the task kind"
cmp "$MIGRATE_HOME/state/mate.meta" "$MIGRATE_HOME/state/mate.meta.before" \
  || fail "apply rewrote the mate record"
cmp "$MIGRATE_HOME/state/gone.meta" "$MIGRATE_HOME/state/gone.meta.before" \
  || fail "apply rewrote the not-live record"
cmp "$MIGRATE_HOME/state/herdrtask.meta" "$MIGRATE_HOME/state/herdrtask.meta.before" \
  || fail "apply rewrote the non-tmux record"
cmp "$FOREIGN_HOME/state/foreign.meta" "$FOREIGN_HOME/state/foreign.meta.before" \
  || fail "apply rewrote another home's record"
fm_backend_target_exists tmux "firstmate-crew:fm-crewtask" "" "$HOLD_SOCK" \
  || fail "liveness does not see the moved window on its recorded server"
if fm_backend_target_exists tmux "holding:fm-crewtask" "" "$HOLD_SOCK"; then
  fail "liveness still sees the crew window at its old session"
fi
resolved=$(fm_backend_resolve_selector crewtask "$MIGRATE_HOME/state") \
  || fail "selector resolution failed after the move"
[ "$resolved" = "firstmate-crew:fm-crewtask" ] \
  || fail "selector resolution still names the old window: $resolved"
peek=$(FM_HOME="$MIGRATE_HOME" "$ROOT/bin/fm-peek.sh" crewtask 200) \
  || fail "peek failed after the move: $peek"
case "$peek" in
  *migrate-marker*) ;;
  *) fail "peek did not read the moved window: $peek" ;;
esac
if ! FM_HOME="$MIGRATE_HOME" "$ROOT/bin/fm-send.sh" crewtask 'migrate-steer' \
    >"$SHIM_DIR/send.out" 2>"$SHIM_DIR/send.err"; then
  fail "send failed after the move: $(cat "$SHIM_DIR/send.err")"
fi
grep -q 'migrate-steer' "$MIGRATE_HOME/state/crewtask.inbox/"*.msg \
  || fail "send did not record the steer for the moved window"
again=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$MIGRATE_HOME" "$ROOT/bin/fm-crew-session-migrate.sh" --apply) \
  || fail "second apply failed: $again"
case "$again" in
  *'already crewtask firstmate-crew:fm-crewtask'*) ;;
  *) fail "second apply did not treat the crew window as already moved: $again" ;;
esac
case "$again" in
  *'moved crewtask'*) fail "second apply moved the crew window again: $again" ;;
esac
pass "real tmux: migration moves a crew window and liveness, peek, and send still resolve it"

tmux new-session -d -s mismatch -n keeper -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the mismatch session"
tmux new-window -d -t '=mismatch:' -n fm-bad -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the mismatched window"
BAD_WID=$(tmux display-message -p -t '=mismatch:fm-bad' '#{window_id}')
write_task_meta "$MISMATCH_HOME" bad ship "elsewhere:fm-bad" "$HOLD_SOCK"
cp "$MISMATCH_HOME/state/bad.meta" "$MISMATCH_HOME/state/bad.meta.before"
if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$MISMATCH_HOME" "$ROOT/bin/fm-crew-session-migrate.sh" \
    >"$SHIM_DIR/mismatch.out" 2>"$SHIM_DIR/mismatch.err"; then
  fail "a recorded session that is not the live session should refuse"
fi
grep -q 'elsewhere:fm-bad' "$SHIM_DIR/mismatch.err" \
  || fail "mismatch error did not name the recorded window: $(cat "$SHIM_DIR/mismatch.err")"
cmp "$MISMATCH_HOME/state/bad.meta" "$MISMATCH_HOME/state/bad.meta.before" \
  || fail "a refused migration rewrote the record"
[ "$(tmux display-message -p -t "$BAD_WID" '#{session_name}')" = mismatch ] \
  || fail "a refused migration moved the window"
pass "real tmux: migration refuses when the recorded window does not match the live one"

tmux new-session -d -s solo -n fm-solo -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the solo session"
SOLO_WID=$(tmux display-message -p -t '=solo:fm-solo' '#{window_id}')
write_task_meta "$SOLO_HOME" solo ship "solo:fm-solo" "$HOLD_SOCK"
cp "$SOLO_HOME/state/solo.meta" "$SOLO_HOME/state/solo.meta.before"
if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SOLO_HOME" "$ROOT/bin/fm-crew-session-migrate.sh" --apply \
    >"$SHIM_DIR/solo.out" 2>"$SHIM_DIR/solo.err"; then
  fail "a move that would close the source session should refuse"
fi
grep -q 'close session solo' "$SHIM_DIR/solo.err" \
  || fail "session-close refusal was not specific: $(cat "$SHIM_DIR/solo.err")"
cmp "$SOLO_HOME/state/solo.meta" "$SOLO_HOME/state/solo.meta.before" \
  || fail "a refused last-window move rewrote the record"
tmux has-session -t '=solo' || fail "the refused move destroyed the source session"
[ "$(tmux display-message -p -t "$SOLO_WID" '#{session_name}')" = solo ] \
  || fail "the refused move took the last window out of its session"
pass "real tmux: migration refuses a move that would close the source session"

tmux new-session -d -s unsethold -n keeper -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the unset-crew session"
tmux new-window -d -t '=unsethold:' -n fm-unset -c "$CAPTAIN_HOME/keep" \
  || fail "could not create the unset-crew window"
UNSET_WID=$(tmux display-message -p -t '=unsethold:fm-unset' '#{window_id}')
write_task_meta "$UNSET_HOME" unset ship "unsethold:fm-unset" "$HOLD_SOCK"
cp "$UNSET_HOME/state/unset.meta" "$UNSET_HOME/state/unset.meta.before"
if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$UNSET_HOME" "$ROOT/bin/fm-crew-session-migrate.sh" --apply \
    >"$SHIM_DIR/unset.out" 2>"$SHIM_DIR/unset.err"; then
  fail "an unset crew session should refuse to move windows"
fi
grep -q 'crew-tmux-session is unset' "$SHIM_DIR/unset.err" \
  || fail "unset crew session error was not specific: $(cat "$SHIM_DIR/unset.err")"
cmp "$UNSET_HOME/state/unset.meta" "$UNSET_HOME/state/unset.meta.before" \
  || fail "an unset crew session rewrote a record"
[ "$(tmux display-message -p -t "$UNSET_WID" '#{session_name}')" = unsethold ] \
  || fail "an unset crew session moved a window"
pass "real tmux: migration refuses when the crew session is unset"

cleanup_all
trap - EXIT
