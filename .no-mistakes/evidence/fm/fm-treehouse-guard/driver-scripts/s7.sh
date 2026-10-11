. "$(dirname "$0")/env.sh"
mk() { # <name> <with-toml>
  git init -q --bare -b main "$SBX/origin-$1.git"; git clone -q "$SBX/origin-$1.git" "$SBX/caps/$1" 2>/dev/null
  ( cd "$SBX/caps/$1"; git checkout -q -b main 2>/dev/null; echo hi > README; [ "$2" = 1 ] && cp "$W/treehouse.toml" .; git add -A; git commit -qm init; git push -q origin main; git remote set-head origin main )
}
mkdir -p "$SBX/caps"; mk firstmate 1; mk control 0
cd "$SBX/caps/firstmate"
echo "## scratch clone carrying this change's committed treehouse.toml, read by the installed treehouse"
run cat treehouse.toml
for n in 1 2 3 4 5 6 7 8 9 10; do p=$(treehouse get --lease 2>/dev/null); echo "lease $n: rc=$? ${p#$HOME/}"; done
echo "## 11th concurrent copy"
run treehouse get --lease
run treehouse status
echo "## one copy comes back and the guard prunes it -> a launch fits again"
treehouse return --force "$HOME/.treehouse/$(ls "$HOME/.treehouse" | grep '^firstmate-')/4/firstmate" >/dev/null 2>&1
run env FM_HOME="$LAB" "$W/bin/fm-treehouse-guard.sh" prune "$SBX/caps/firstmate"
run treehouse get --lease
echo
echo "## control: identical clone without treehouse.toml (no user-level config in this sandbox HOME) is not capped at 10"
cd "$SBX/caps/control"
for n in 1 2 3 4 5 6 7 8 9 10 11; do p=$(treehouse get --lease 2>/dev/null); echo "lease $n: rc=$? ${p#$HOME/}"; done
