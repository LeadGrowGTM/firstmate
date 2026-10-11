. "$(dirname "$0")/env.sh"
export FM_HOME="$SBX/lab2"
cd "$W"
bin/fm-spawn.sh td-scout "$FM_HOME/projects/other" --scout --harness "cat -u"; echo "[spawn exit $?]"
ls -la "$FM_HOME/state"; cat "$FM_HOME/state/td-scout.meta" 2>/dev/null
( cd "$FM_HOME/projects/other" && treehouse status 2>&1 | grep other )
echo S6B-DONE
