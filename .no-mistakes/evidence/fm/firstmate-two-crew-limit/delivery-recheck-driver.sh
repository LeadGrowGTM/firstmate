#!/usr/bin/env bash
set -euo pipefail
source tests/fixtures.sh
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  mkdir -p "$home/user-home"
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    TMUX="$SOCKET,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}
LAB="$ROOT/.delivery-lab"
export LAB
SOCKET="$LAB/tmux.sock"
export SOCKET
cleanup() { /usr/bin/tmux -S "$SOCKET" kill-server 2>/dev/null || true; }
trap 'cleanup; rm -rf -- "$LAB"' EXIT
fb=$(fm_test_make_spawn_fakebin "$LAB/tools" gh gh-axi no-mistakes)
export LAB_FB="$fb"
cat > "$fb/tmux" <<'WRAP'
#!/usr/bin/env bash
set -eu
real() { /usr/bin/tmux -S "$SOCKET" "$@"; }
if [ "${1:-}" = send-keys ] && [ "${4:-}" = 'treehouse get' ]; then
  real send-keys -t "$3" "cd '$LAB_WT'" Enter
  exit
fi
if [ "${1:-}" = send-keys ] && [ "${4:-}" = -l ]; then
  case "${5:-}" in
    ". '"*"'")
      printf '%s\n' "$5" > "$LAB_CASE/source-line"
      real "$@"
      printf 'Real tmux buffered launch for %s\n' "$LAB_MODE" >> "$LAB_CASE/transport.log"
      ;;
    *) exec /usr/bin/tmux -S "$SOCKET" "$@" ;;
  esac
  exit
fi
if [ "${1:-}" = send-keys ] && [ "${4:-}" = Enter ] && [ -e "$LAB_CASE/source-line" ]; then
  if [ "$LAB_MODE" = unstarted ]; then
    # Real tmux rejects delivery to a nonexistent pane on this private server.
    real send-keys -t firstmate:nonexistent-delivery-target Enter
    exit $?
  fi
  real "$@"
  for ((i=0; i<200; i++)); do
    [ ! -f "$LAB_CASE/started" ] || break
    sleep .05
  done
  [ -f "$LAB_CASE/started" ] || exit 25
  # The command reached the pane; simulate a failed response with a real
  # rejected transport operation after the worker's startup acknowledgement.
  real send-keys -t firstmate:nonexistent-delivery-target Enter
  exit $?
fi
if [ "${1:-}" = send-keys ] && [ "${4:-}" = C-c ]; then
  printf 'Cleanup sent C-c through real tmux\n' >> "$LAB_CASE/transport.log"
fi
exec /usr/bin/tmux -S "$SOCKET" "$@"
WRAP
cat > "$fb/codex" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$LAB_CASE/worker.pid"
touch "$LAB_CASE/started"
while [ ! -e "$LAB_CASE/stop" ]; do sleep .05; done
exit 7
WORKER
chmod +x "$fb/tmux" "$fb/codex"
fm_git_worktree "$LAB/project" "$LAB/wt" delivery-lab
export LAB_WT="$LAB/wt"
for mode in unstarted started; do
  export LAB_MODE="$mode" LAB_CASE="$LAB/$mode"
  mkdir -p "$LAB_CASE"
  home="$LAB_CASE/home"
  bin/fm-lab-home.sh create "$home"
  fm_test_spawn_home "$home" codex
  id="delivery-$mode-$$"
  fm_test_spawn_brief "$home" "$id"
  # Server and worker inherit only this disposable environment.
  PATH="$fb:$PATH" /usr/bin/tmux -S "$SOCKET" -f /dev/null new-session -d -x 120 -y 35 -s firstmate -c "$LAB_WT" 'bash --noprofile --norc'
  /usr/bin/tmux -S "$SOCKET" set-option -g default-shell /bin/bash
  /usr/bin/tmux -S "$SOCKET" set-option -g default-command 'bash --noprofile --norc'
  status=0
  FM_BACKEND=tmux fm_test_run_spawn "$home" "$LAB_WT" "$fb" "$id" "$LAB/project" --mode no-mistakes --yolo off > "$LAB_CASE/spawn.log" 2>&1 || status=$?
  cat "$LAB_CASE/spawn.log"
  [ "$status" -ne 0 ] || fail "$mode delivery unexpectedly succeeded"
  [ -f "$LAB_CASE/source-line" ] || fail "$mode did not reach launch delivery"
  cat "$LAB_CASE/transport.log"
  shopt -s nullglob
  reservations=("$home/state/$id".crew-*)
  if [ "$mode" = unstarted ]; then
    [ "${#reservations[@]}" -eq 0 ] || fail 'unstarted reservation stranded'
    [ ! -e "$LAB_CASE/started" ] || fail 'worker started before cancellation'
    /usr/bin/tmux -S "$SOCKET" send-keys -t "firstmate:fm-$id" Enter
    /usr/bin/tmux -S "$SOCKET" send-keys -t "firstmate:fm-$id" "touch '$LAB_CASE/after-cancel'" Enter
    for ((i=0; i<100; i++)); do [ ! -e "$LAB_CASE/after-cancel" ] || break; sleep .05; done
    [ -e "$LAB_CASE/after-cancel" ] || fail 'pane not responsive after cancellation'
    [ ! -e "$LAB_CASE/started" ] || fail 'buffered command survived cancellation'
    pass 'real transport failure before startup releases reservation and cancels buffered launch'
  else
    [ "${#reservations[@]}" -eq 1 ] || fail 'started reservation not preserved'
    [ -f "$home/state/$id.meta" ] || fail 'started worker metadata removed'
    kill -0 "$(cat "$LAB_CASE/worker.pid")" || fail 'started worker killed'
    touch "$LAB_CASE/stop"
    for ((i=0; i<200; i++)); do [ -e "${reservations[0]}" ] || break; sleep .05; done
    [ ! -e "${reservations[0]}" ] || fail 'completed worker reservation stranded'
    pass 'real transport error after startup preserves worker and metadata until worker exits'
  fi
  /usr/bin/tmux -S "$SOCKET" capture-pane -p -t "firstmate:fm-$id"
  cleanup
 done
