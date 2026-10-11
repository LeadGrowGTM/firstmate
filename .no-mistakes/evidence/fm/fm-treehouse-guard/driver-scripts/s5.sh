. "$(dirname "$0")/env.sh"
G="$W/bin/fm-treehouse-guard.sh"
( cd "$LAB/projects/demo"; c=$(treehouse get --lease 2>/dev/null); treehouse return --force "$c" >/dev/null 2>&1; treehouse status 2>&1 | grep demo )
run env FM_HOME="$LAB" "$G" disarm
run env FM_HOME="$LAB" "$G" arm
run cat "$LAB/state/treehouse-guard.check.sh"
run ls -la "$LAB/state"
echo "## the real watcher, on this lab home only, polling registered checks every 2s"
run env FM_HOME="$LAB" FM_CHECK_INTERVAL=2 timeout 90 "$W/bin/fm-watch.sh"
echo "-- records after the watcher woke:"
cat "$LAB/state/.treehouse-guard" "$LAB/state/.treehouse-guard.result"
( cd "$LAB/projects/demo"; treehouse status 2>&1 | grep demo )
echo "## disarm removes the shim, its trust binding and both records"
run env FM_HOME="$LAB" "$G" disarm
run ls -la "$LAB/state"
