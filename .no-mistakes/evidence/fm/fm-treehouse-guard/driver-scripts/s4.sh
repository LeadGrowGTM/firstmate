. "$(dirname "$0")/env.sh"
G="$W/bin/fm-treehouse-guard.sh"
T=2000000000
rec() { echo "-- state/.treehouse-guard:"; cat "$LAB/state/.treehouse-guard" 2>/dev/null; echo "-- state/.treehouse-guard.result:"; cat "$LAB/state/.treehouse-guard.result" 2>/dev/null; }
waitswept() { i=0; while ! grep -q "swept.$1" "$LAB/state/.treehouse-guard.result" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; }
pool() { ( cd "$LAB/projects/demo"; treehouse status 2>&1 | grep demo ); }
mkprunable() { ( cd "$LAB/projects/demo"; c=$(treehouse get --lease 2>/dev/null); treehouse return --force "$c" >/dev/null 2>&1 ); }
run env FM_HOME="$LAB" "$G" disarm
mkprunable; pool
echo "## poll 1 (day 0): nothing printed, a sweep is started in the background"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$T "$G" check
waitswept $T; rec
echo "-- the background sweep pruned the returned copy:"; pool
echo "## poll 2 (5 minutes later): the finished sweep's finding is reported once"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+300)) "$G" check
rec
echo "## poll 3 (10 minutes later) and poll 4 (23h59m59s later): silent, and no new sweep"
rm -f "$SBX/calls.log"; : > "$SBX/calls.log"
REAL=$(command -v treehouse)
mkdir -p "$SBX/spybin"
cat > "$SBX/spybin/treehouse" <<SPY
#!/usr/bin/env bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$SBX/calls.log"
exec "$REAL" "\$@"
SPY
chmod +x "$SBX/spybin/treehouse"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+600)) PATH="$SBX/spybin:$PATH" "$G" check
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+86399)) PATH="$SBX/spybin:$PATH" "$G" check
sleep 3; echo "-- treehouse calls made by polls 3 and 4: $(wc -l < "$SBX/calls.log")"
rec
echo "## poll 5 (exactly 24h after poll 1): a new sweep starts; every treehouse call it makes is logged"
mkprunable; pool
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+86400)) PATH="$SBX/spybin:$PATH" "$G" check
waitswept $((T+86400)); rec
echo "-- every treehouse call the daily sweep made (cwd<TAB>args):"; cat "$SBX/calls.log"
pool
echo "## poll 6: same finding as already reported -> silent"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+86700)) "$G" check
echo "## size drops back under 5 GB; next day's sweep clears the finding, and a later regrowth is reported again"
rm -f "$HOME/.treehouse/demo-e6da16/2/demo/build-output-2.bin"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+2*86400)) "$G" check
waitswept $((T+2*86400))
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+2*86400+300)) "$G" check
rec
fallocate -l 400M "$HOME/.treehouse/demo-e6da16/2/demo/build-output-2.bin"
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+3*86400)) "$G" check
waitswept $((T+3*86400))
run env FM_HOME="$LAB" FM_TREEHOUSE_GUARD_NOW=$((T+3*86400+300)) "$G" check
