#!/usr/bin/env bash
# Drives one real Claude primary in a disposable lab home on a private tmux socket.
# lab-primary.sh start <worktree> | cap [start-line] | keys <tmux send-keys args...> | stop
set -u
EV=$(cd "$(dirname "$0")" && pwd)
case $1 in
  start)
    cd "$2" || exit 1
    LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
    cp docs/examples/task-types.json "$LAB/config/task-types.json"
    printf '%s\n' "$LAB" > "$EV/.lab-path"
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 180 -y 50 -c "$PWD" -e FM_HOME="$LAB" claude
    echo "lab: $LAB" ;;
  cap) LAB=$(cat "$EV/.lab-path"); TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p ${2:+-S "$2"} -t primary ;;
  keys) LAB=$(cat "$EV/.lab-path"); shift; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary "$@" ;;
  stop) LAB=$(cat "$EV/.lab-path"); TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server; case $LAB in */fm-lab.*) rm -rf "$LAB" ;; esac; rm -f "$EV/.lab-path"; echo stopped ;;
esac
