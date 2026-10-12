#!/bin/bash
set -eu
LAB=$PWD/.crew-lab
export FM_HOME=$LAB/fresh FM_BACKEND=tmux TMUX_TMPDIR=.crew-lab/t TREEHOUSE_ROOT=$LAB/pool
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0"
. bin/fm-backend.sh
for id in first second; do
 printf '%s after declining trust: ' "$id"; fm_backend_agent_state tmux "primary:fm-$id"; echo
 if compgen -G "$FM_HOME/state/$id.crew-*" >/dev/null; then echo 'ERROR: stranded reservation'; exit 1; fi
done
echo 'Both real launch wrappers released their reservations on exit.'
(bin/fm-spawn.sh first --relaunch > "$LAB/relaunch.log" 2>&1; echo $? > "$LAB/relaunch.rc") &
p1=$!
set +e
bin/fm-spawn.sh third "$LAB/project" --mode local-only --yolo off > "$LAB/concurrent.log" 2>&1
rc=$?
set -e
wait "$p1" || true
echo "Fresh concurrent spawn exit=$rc"
cat "$LAB/concurrent.log" "$LAB/relaunch.log"
# A contender must refuse at the shared lock; either winner is valid.
grep -q 'task set is locked' "$LAB/concurrent.log" "$LAB/relaunch.log"
echo 'Concurrent recovery/fresh admission serialized at the shared home lock.'
