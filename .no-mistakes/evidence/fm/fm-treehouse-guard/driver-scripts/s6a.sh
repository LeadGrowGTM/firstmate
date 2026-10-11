. "$(dirname "$0")/env.sh"
export FM_HOME="$SBX/lab2"
cd "$W"
echo "TMUX=$TMUX"
bin/fm-brief.sh td-scout other --scout; echo "[brief exit $?]"
B="$FM_HOME/data/td-scout/brief.md"
sed -i 's/{TASK}/Report what the README of this repository says./; s/{FIRSTMATE_SPEC}/Read README and write the report file named in the brief./' "$B"
grep -n "TASK\|FIRSTMATE_SPEC\|^#" "$B" | head -30
bin/fm-spawn.sh td-scout "$FM_HOME/projects/other" --scout --harness "cat"; echo "[spawn exit $?]"
ls -la "$FM_HOME/state"; cat "$FM_HOME/state/td-scout.meta" 2>/dev/null
echo S6A-DONE
