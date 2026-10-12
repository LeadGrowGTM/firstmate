#!/bin/bash
set -eu
ROOT=$PWD
LAB=$ROOT/.crew-lab
export FM_HOME=$LAB/home FM_BACKEND=tmux TMUX_TMPDIR=.crew-lab/t
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),1,0"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
git init -q "$LAB/project"
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
for id in live-a live-b; do
cat > "$FM_HOME/state/$id.meta" <<EOF
window=primary:fm-$id
endpoint_task_id=$id
worktree=$LAB/project
project=$LAB/project
harness=codex
kind=ship
mode=local-only
yolo=off
EOF
done
. bin/fm-backend.sh
for id in live-a live-b; do printf '%s state: ' "$id"; fm_backend_agent_state tmux "primary:fm-$id"; echo; done
check() {
 local label=$1 expected=$2 out rc=0
 echo "SCENARIO: $label"
 out=$(bin/fm-spawn.sh candidate "$LAB/project" --mode local-only --yolo off 2>&1) || rc=$?
 printf '%s\nexit=%s\n' "$out" "$rc"
 [[ "$out" == *"$expected"* ]]
 test ! -e "$FM_HOME/state/candidate.meta"
}
check 'two running crews refuse a third' 'at most two crews'
sed -i 's/kind=ship/kind=scout/' "$FM_HOME/state/live-b.meta"
check 'a running scout consumes a crew slot' 'at most two crews'
sed -i 's/kind=scout/kind=secondmate/' "$FM_HOME/state/live-b.meta"
check 'secondmate is excluded from ordinary crew capacity' 'has no brief'
sed -i 's/kind=secondmate/kind=ship/' "$FM_HOME/state/live-b.meta"
bin/fm-lab-home.sh create "$LAB/other-home"
FM_HOME="$LAB/other-home" check 'another owner has independent capacity' 'has no brief'
TMUX_TMPDIR=.t tmux -L fm-lab-other new-session -d -s other -x 120 -y 40 'sleep 300'
original_tmux=$TMUX
export TMUX="$(TMUX_TMPDIR=.t tmux -L fm-lab-other display-message -p '#{socket_path}'),1,0"
check 'wrong server cannot make two existing crews disappear' 'at most two crews'
TMUX_TMPDIR=.t tmux -L fm-lab-other kill-server
export TMUX=$original_tmux
# Replace one real agent endpoint with a stopped shell, as after worker exit.
tmux -L fm-lab respawn-window -k -t primary:fm-live-b 'bash --noprofile --norc'
sleep 1
printf 'stopped endpoint state: '; fm_backend_agent_state tmux primary:fm-live-b; echo
check 'stopped worker releases its slot' 'has no brief'
printf 'spawn_gen=buffered\n' >> "$FM_HOME/state/live-b.meta"
touch "$FM_HOME/state/live-b.crew-buffered"
check 'pending launch in a shell retains its slot' 'at most two crews'
rm "$FM_HOME/state/live-b.crew-buffered"
echo 'Live admission checks completed.'
