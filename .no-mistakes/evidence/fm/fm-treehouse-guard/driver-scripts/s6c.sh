. "$(dirname "$0")/env.sh"
export FM_HOME="$SBX/lab2"
cd "$W"
P="$FM_HOME/projects/other"
pool() { ( cd "$P" && treehouse status 2>&1 | grep -e other -e '(' ); }
REAL=$(command -v treehouse)
mkdir -p "$SBX/spybin2"
cat > "$SBX/spybin2/treehouse" <<SPY
#!/usr/bin/env bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$SBX/td-calls.log"
if [ -n "\${SPY_FAIL_PRUNE:-}" ] && [ "\$*" = "prune --yes" ]; then echo 'injected prune failure' >&2; exit 3; fi
exec "$REAL" "\$@"
SPY
chmod +x "$SBX/spybin2/treehouse"
for id in td-scout-2 td-scout-3; do
  bin/fm-brief.sh $id other --scout >/dev/null
  sed -i 's/{TASK}/Report what the README of this repository says./; s/{FIRSTMATE_SPEC}/Read README and write the report file named in the brief./' "$FM_HOME/data/$id/brief.md"
  run bin/fm-spawn.sh $id "$P" --scout --harness "cat -u"
done
echo "## three real scout tasks spawned by bin/fm-spawn.sh, each in its own treehouse copy"
pool
run tmux list-windows -a -F '#{session_name}:#{window_name}'
echo
echo "## 1. real cleanup of td-scout (treehouse calls logged through a pass-through wrapper)"
: > "$SBX/td-calls.log"
run env PATH="$SBX/spybin2:$PATH" bin/fm-teardown.sh td-scout --force
echo "-- every treehouse call that cleanup made (cwd<TAB>args):"; cat "$SBX/td-calls.log"
echo "-- pool afterwards: the returned copy is gone, the two copies still in use are untouched"
pool
run ls "$HOME/.treehouse/other-9efb4a"
run ls "$FM_HOME/state"
echo
echo "## 2. adversarial: the prune fails during cleanup of td-scout-2 (injected exit 3 on 'prune --yes' only)"
: > "$SBX/td-calls.log"
run env PATH="$SBX/spybin2:$PATH" SPY_FAIL_PRUNE=1 bin/fm-teardown.sh td-scout-2 --force
echo "-- treehouse calls:"; cat "$SBX/td-calls.log"
echo "-- cleanup still completed (record gone); the returned copy simply stays in the pool for the next prune"
run ls "$FM_HOME/state"
pool
echo
echo "## 3. the next cleanup (td-scout-3) reclaims both idle copies"
: > "$SBX/td-calls.log"
run env PATH="$SBX/spybin2:$PATH" bin/fm-teardown.sh td-scout-3 --force
echo "-- treehouse calls:"; cat "$SBX/td-calls.log"
pool; echo "(pool listing above is empty when no copies remain)"
run ls "$HOME/.treehouse/other-9efb4a"
run tmux list-windows -a -F '#{session_name}:#{window_name}'
echo S6C-DONE
