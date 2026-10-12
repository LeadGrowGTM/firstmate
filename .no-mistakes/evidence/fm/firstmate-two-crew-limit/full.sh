#!/bin/bash
set -eu
LAB=$PWD/.crew-lab
export FM_HOME=$LAB/fresh FM_BACKEND=tmux TMUX_TMPDIR=.crew-lab/t TREEHOUSE_ROOT=$LAB/pool
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0"
bin/fm-lab-home.sh create "$FM_HOME"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" fetch -q origin
tmux -L fm-lab set-environment -g TREEHOUSE_ROOT "$TREEHOUSE_ROOT"
tmux -L fm-lab set-option -g default-shell /bin/bash
for id in first second third; do
mkdir -p "$FM_HOME/data/$id"
cat > "$FM_HOME/data/$id/brief.md" <<EOF
# Task
Delivery contract: mode=local-only
## Captain's intent
This is a disposable live admission test. Make no changes and run no tools. Respond READY and wait for further instructions. Do not start any validation pipeline or publish anything.
## Firstmate spec
Remain idle after responding READY. This brief authorizes no file changes.
EOF
echo "SPAWNING $id"
rc=0
bin/fm-spawn.sh "$id" "$LAB/project" --mode local-only --yolo off || rc=$?
echo "SPAWN $id exit=$rc"
if [ "$id" != third ]; then test "$rc" = 0; else test "$rc" != 0; fi
done
