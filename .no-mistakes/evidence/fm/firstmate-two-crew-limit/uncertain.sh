#!/bin/bash
set -eu
LAB=$PWD/.crew-lab
export FM_HOME=$LAB/home FM_BACKEND=tmux TMUX_TMPDIR=.crew-lab/t
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0"
for backend in orca cmux zellij; do
 for id in live-a live-b; do
  sed -i '/^backend=/d' "$FM_HOME/state/$id.meta"
  printf 'backend=%s\n' "$backend" >> "$FM_HOME/state/$id.meta"
 done
 echo "Two unverifiable $backend records:"
 out=$(bin/fm-spawn.sh candidate "$LAB/project" --mode local-only --yolo off 2>&1) || true
 echo "$out"
 [[ "$out" == *'at most two crews'* ]]
 mv "$FM_HOME/state/live-b.meta" "$LAB/saved.meta"
 echo "One unverifiable $backend record:"
 out=$(bin/fm-spawn.sh candidate "$LAB/project" --mode local-only --yolo off 2>&1) || true
 echo "$out"
 [[ "$out" == *'has no brief'* ]]
 mv "$LAB/saved.meta" "$FM_HOME/state/live-b.meta"
done
