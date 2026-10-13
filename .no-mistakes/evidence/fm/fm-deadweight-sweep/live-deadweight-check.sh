#!/usr/bin/env bash
set -euo pipefail
repo=/home/mitch/.no-mistakes/worktrees/5782b7185c5e/01M4VNDAD4QTCRG15CBSNB45NK
lab=$FM_HOME
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export XDG_STATE_HOME="$lab/xdg-state" XDG_CONFIG_HOME="$lab/xdg-config" XDG_DATA_HOME="$lab/xdg-data"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
make_project() {
  local name=$1 p="$lab/$1"
  mkdir -p "$p"
  git init -q --bare "$p/origin.git"
  git -C "$p/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$p/seed"
  git -C "$p/seed" checkout -qb main
  printf 'baseline\n' > "$p/seed/file"
  git -C "$p/seed" add file
  git -C "$p/seed" -c user.name=Lab -c user.email=lab@example.invalid commit -qm baseline
  git -C "$p/seed" remote add origin "$p/origin.git"
  git -C "$p/seed" push -q origin main
  git clone -q "$p/origin.git" "$lab/projects/$name"
}
add_worker() {
  local name=$1 wt
  wt=$(cd "$lab/projects/$name" && treehouse get --lease --lease-holder "$name")
  git -C "$wt" checkout -qb "fm/$name" main
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nbranch=fm/%s\nmode=no-mistakes\nspawn_gen=lab\n' "$name" "$name" "$wt" "$lab/projects/$name" "$name" > "$lab/state/$name.meta"
  printf 'done: complete\n' > "$lab/state/$name.status"
  printf '%s\n' "$wt"
}
assert_kept() {
  local name=$1 wt=$2
  test -f "$lab/state/$name.meta" && test -d "$wt" || { echo "FAIL: $name was removed"; exit 1; }
}
assert_swept() {
  local name=$1 wt=$2
  test ! -e "$lab/state/$name.meta" && test ! -e "$wt" || { echo "FAIL: $name remains"; exit 1; }
}
make_project clean
clean_wt=$(add_worker clean)
echo 'SCENARIO clean stopped worker'
"$repo/bin/fm-deadweight-sweep.sh"
assert_swept clean "$clean_wt"
echo 'STATE clean: record absent; copy absent'
make_project ignored
ignored_wt=$(add_worker ignored)
printf '.env\n' >> "$lab/projects/ignored/.git/info/exclude"
printf 'operator work\n' > "$ignored_wt/.env"
echo 'SCENARIO ignored operator work'
"$repo/bin/fm-deadweight-sweep.sh"
assert_kept ignored "$ignored_wt"
test "$(cat "$ignored_wt/.env")" = 'operator work'
echo 'STATE ignored: record present; copy and ignored file present'
make_project submodule
git init -q "$lab/submodule-source"
printf 'baseline\n' > "$lab/submodule-source/file"
git -C "$lab/submodule-source" add file
git -C "$lab/submodule-source" -c user.name=Lab -c user.email=lab@example.invalid commit -qm baseline
git -C "$lab/projects/submodule" -c protocol.file.allow=always submodule add -q "$lab/submodule-source" child
git -C "$lab/projects/submodule" -c user.name=Lab -c user.email=lab@example.invalid commit -qam submodule
git -C "$lab/projects/submodule" push -q origin main
submodule_wt=$(add_worker submodule)
git -C "$submodule_wt" submodule deinit -fq child >/dev/null 2>&1 || true
mkdir -p "$submodule_wt/child"
printf 'operator file\n' > "$submodule_wt/child/file"
git -C "$lab/projects/submodule" config submodule.child.ignore all
echo 'SCENARIO occupied uninitialized submodule'
"$repo/bin/fm-deadweight-sweep.sh"
assert_kept submodule "$submodule_wt"
test "$(cat "$submodule_wt/child/file")" = 'operator file'
echo 'STATE submodule: record present; copy and submodule file present'
echo 'SCENARIO daily check and one-time report'
"$repo/bin/fm-deadweight-sweep.sh" check
for ((i=0; i<120; i++)); do
  test -f "$lab/state/.deadweight-sweep-result" && break
  sleep 0.25
done
test -f "$lab/state/.deadweight-sweep-result"
"$repo/bin/fm-deadweight-sweep.sh" check
"$repo/bin/fm-deadweight-sweep.sh" check
printf 'STATE daily: launched=%s; pending-result=%s\n' "$(test -f "$lab/state/.deadweight-sweep-launched" && echo yes || echo no)" "$(test -f "$lab/state/.deadweight-sweep-result" && echo yes || echo no)"
make_project stale
git -C "$lab/projects/stale" worktree add -q --detach "$lab/stale-copy" main
python3 - "$lab/stale-copy" "$lab" <<'PY'
import pathlib, shutil, sys
p, lab = map(pathlib.Path, sys.argv[1:])
if p.parent != lab or p.name != 'stale-copy':
    raise SystemExit('refusing unsafe fixture removal')
shutil.rmtree(p)
PY
echo 'SCENARIO absent stale worktree registration'
"$repo/bin/fm-deadweight-sweep.sh"
if git -C "$lab/projects/stale" worktree list --porcelain | grep -Fq "$lab/stale-copy"; then echo 'FAIL: stale registration remains'; exit 1; fi
echo 'STATE stale: registration absent'
make_project pool
pool_wt=$(cd "$lab/projects/pool" && treehouse get --lease --lease-holder pool)
(cd "$lab/projects/pool" && treehouse return "$pool_wt")
test -d "$pool_wt"
echo 'SCENARIO safe pool prune'
"$repo/bin/fm-deadweight-sweep.sh"
test ! -e "$pool_wt" || { echo 'FAIL: returned clean pool copy remains'; exit 1; }
echo 'STATE pool: returned clean copy absent'
