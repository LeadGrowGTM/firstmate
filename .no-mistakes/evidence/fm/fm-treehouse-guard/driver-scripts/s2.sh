. "$(dirname "$0")/env.sh"
G="$W/bin/fm-treehouse-guard.sh"
# The lab home is itself made a git clone with its own pool, as a real Firstmate home is,
# so a plain directory under projects/ would resolve to the enclosing repository.
cd "$LAB"; git init -q -b main . ; git remote add origin "$SBX/origin-home.git"
git init -q --bare -b main "$SBX/origin-home.git"
printf 'projects/\nstate/\n' > .gitignore; git add .gitignore; git commit -qm home; git push -q origin main; git remote set-head origin main
H1=$(treehouse get --lease 2>/dev/null); treehouse return --force "$H1" >/dev/null 2>&1
mkdir -p "$LAB/projects/plain-dir"
echo "## enclosing home pool has one returned, merged, clean, idle copy (prunable by treehouse's rule)"
run treehouse status
echo "## adversarial 1: prune aimed at a plain directory inside the home (not its own clone root)"
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/plain-dir"
echo "## adversarial 2: prune aimed at a subdirectory of a real project clone"
mkdir -p "$LAB/projects/demo/sub"
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/demo/sub"
echo "## adversarial 3: missing directory, and caller-supplied widening flags"
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/nope"
run env FM_HOME="$LAB" "$G" prune --all
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/demo" --prune-orphans
echo "## the enclosing home pool copy is untouched"
cd "$LAB"; run treehouse status
echo "## adversarial 4: the project's pool lock is held by a launch/cleanup -> skipped silently, nothing pruned"
cd "$LAB/projects/demo"; D=$(treehouse get --lease 2>/dev/null); treehouse return --force "$D" >/dev/null 2>&1
run treehouse status
(
  . "$W/bin/fm-wake-lib.sh"; . "$W/bin/fm-pr-lib.sh" 2>/dev/null
  export FM_HOME="$LAB"
  lock=$(fm_treehouse_project_lock_path "$LAB/projects/demo") || { echo "lock path failed"; exit 1; }
  echo "$lock" > "$SBX/lockpath"
  fm_lock_try_acquire "$lock" || { echo "acquire failed"; exit 1; }
  sleep 6
  fm_lock_release "$lock"
) & HOLD=$!
sleep 2
echo "lock held at: $(cat "$SBX/lockpath" 2>/dev/null)"
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/demo"
run treehouse status
wait $HOLD
echo "## lock released -> same call now prunes"
run env FM_HOME="$LAB" "$G" prune "$LAB/projects/demo"
run treehouse status
echo "## adversarial 5: treehouse not on PATH"
run env FM_HOME="$LAB" PATH=/usr/bin:/bin "$G" prune "$LAB/projects/demo"
