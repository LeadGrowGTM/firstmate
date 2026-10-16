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

cleanup_all
trap - EXIT
