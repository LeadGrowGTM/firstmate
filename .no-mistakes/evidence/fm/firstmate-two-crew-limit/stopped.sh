#!/bin/bash
set -eu
ROOT=$PWD
LAB=$ROOT/.crew-lab
export FM_HOME=$LAB/home FM_BACKEND=tmux TMUX_TMPDIR=.crew-lab/t
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
check() {
 local label=$1 expected=$2 out rc=0
 echo "SCENARIO: $label"
 out=$(bin/fm-spawn.sh candidate "$LAB/project" --mode local-only --yolo off 2>&1) || rc=$?
 printf '%s\nexit=%s\n' "$out" "$rc"
 [[ "$out" == *"$expected"* ]]
 test ! -e "$FM_HOME/state/candidate.meta"
}
. bin/fm-backend.sh
printf 'stopped endpoint state: '; fm_backend_agent_state tmux primary:fm-live-b; echo
check 'stopped worker releases its slot' 'has no brief'
printf 'spawn_gen=buffered\n' >> "$FM_HOME/state/live-b.meta"
touch "$FM_HOME/state/live-b.crew-buffered"
check 'pending launch in a shell retains its slot' 'at most two crews'
rm "$FM_HOME/state/live-b.crew-buffered"
echo 'Live admission checks completed.'
