. "$(dirname "$0")/env.sh"
P="$LAB/projects/demo"; cd "$P"
C3=$(treehouse get --lease 2>/dev/null); C4=$(treehouse get --lease 2>/dev/null); C5=$(treehouse get --lease 2>/dev/null)
C1="$HOME/.treehouse/demo-e6da16/1/demo"
echo "## setup: copy 1 returned (merged, clean, idle); 2 stays leased; 3 returned then dirtied; 4 returned then given an unmerged commit; 5 returned with a live process inside"
treehouse return --force "$C1" >/dev/null 2>&1
treehouse return --force "$C3" >/dev/null 2>&1; echo scratch > "$C3/uncommitted.txt"
treehouse return --force "$C4" >/dev/null 2>&1; ( cd "$C4" && echo x > new && git add new && git commit -qm unmerged )
treehouse return --force "$C5" >/dev/null 2>&1; ( cd "$C5" && exec sleep 300 ) & SL=$!
sleep 1
run treehouse status
echo "## treehouse's own dry run (what it considers stale)"
run treehouse prune
echo "## the guard"
cd /
run env FM_HOME="$LAB" "$W/bin/fm-treehouse-guard.sh" prune "$P"
cd "$P"
run treehouse status
run ls "$HOME/.treehouse/demo-e6da16"
kill $SL 2>/dev/null
