#!/usr/bin/env bash
# Retention cleanup keeps live and unlanded work, and dry-run deletes nothing.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-data-manage.sh"
TMP_ROOT=$(fm_test_tmproot fm-data-manage)
stubbin="$TMP_ROOT/bin"
mkdir -p "$stubbin"
cat > "$stubbin/realpath" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stubbin/realpath"
export PATH="$stubbin:$PATH"
holder=
holders=
cleanup() {
  local p
  for p in $holder $holders; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_identity
home="$TMP_ROOT/home"
pool="$TMP_ROOT/pool"
proj="$home/projects/fm-data-manage-fixture"
bare="$TMP_ROOT/origin.git"
mkdir -p "$home/state" "$home/config" "$home/projects" "$home/.tmp" "$home/data" "$home/state/logs" "$pool/repo"
printf 'keep-me\n' > "$home/data/record.txt"
git init --bare "$bare" >/dev/null
git init "$proj" >/dev/null
git -C "$proj" checkout -b main >/dev/null
git -C "$proj" remote add origin "$bare"
printf 'seed\n' > "$proj/README"
mkdir -p "$proj/node_modules"
printf 'pkg\n' > "$proj/node_modules/pkg"
git -C "$proj" add README
git -C "$proj" commit -m seed >/dev/null
git -C "$proj" push -u origin main >/dev/null

landed=$(cd "$pool/repo" && pwd -P)/landed
dirty=$(cd "$pool/repo" && pwd -P)/dirty
named=$(cd "$pool/repo" && pwd -P)/named
git -C "$proj" worktree add -b landed "$landed" main >/dev/null
git -C "$landed" push -u origin landed >/dev/null
git -C "$proj" worktree add -b dirty "$dirty" main >/dev/null
printf 'dirt\n' >> "$dirty/README"
git -C "$proj" worktree add -b named "$named" main >/dev/null
git -C "$named" push -u origin named >/dev/null
named_phys=$(cd "$named" && pwd -P)
printf 'worktree=%s\n' "$named_phys" > "$home/state/job.meta"

idle_proj="$home/projects/fm-data-manage-idle"
idle_bare="$TMP_ROOT/idle-origin.git"
git init --bare "$idle_bare" >/dev/null
git init "$idle_proj" >/dev/null
git -C "$idle_proj" checkout -b main >/dev/null
git -C "$idle_proj" remote add origin "$idle_bare"
printf 'idle\n' > "$idle_proj/README"
git -C "$idle_proj" add README
git -C "$idle_proj" commit -m seed >/dev/null
git -C "$idle_proj" push -u origin main >/dev/null
idle=$(cd "$pool/repo" && pwd -P)/idle
git -C "$idle_proj" worktree add -b idle "$idle" main >/dev/null
git -C "$idle" push -u origin idle >/dev/null

old="$home/.tmp/old.txt"
fresh="$home/.tmp/fresh.txt"
envf="$home/.tmp/.env"
envrc="$home/.tmp/.envrc"
oauthf="$home/.tmp/oauth-token.json"
certf="$home/.tmp/client.cert"
edge_root="$home/.tmp/microsoft-edge/Default"
edge_file="$edge_root/History"
openf="$home/.tmp/open.txt"
outside="$TMP_ROOT/outside.txt"
mkdir -p "$edge_root"
printf 'old\n' > "$old"
printf 'fresh\n' > "$fresh"
printf 'secret\n' > "$envf"
printf 'secret\n' > "$envrc"
printf 'oauth\n' > "$oauthf"
printf 'certificate\n' > "$certf"
printf 'browser history\n' > "$edge_file"
printf 'open\n' > "$openf"
printf 'outside\n' > "$outside"
ln -s "$outside" "$home/.tmp/link"
now=$(date +%s)
fm_touch_epoch $((now - 3 * 86400)) "$old" "$envf" "$envrc" "$oauthf" "$certf" "$edge_file" "$openf"
unknown_checkout="$home/.tmp/nested-checkout"
git init "$unknown_checkout" >/dev/null
unknown_file="$unknown_checkout/dirty-old.txt"
printf 'uncommitted\n' > "$unknown_file"
fm_touch_epoch $((now - 3 * 86400)) "$unknown_file"
tail -f "$openf" >/dev/null &
holder=$!

cfg="$TMP_ROOT/data-management"
home_phys=$(cd "$home" && pwd -P)
pool_phys=$(cd "$pool" && pwd -P)
cat > "$cfg" <<EOF
home $home_phys
pool-root $pool_phys
tmp $home_phys/.tmp 1
EOF

run() {
  bash "$TOOL" "$@"
}

out=$(run measure --config "$cfg")
assert_contains "$out" "category=home" "measure names the home"
assert_contains "$out" "category=data" "measure names data without deleting it"
assert_contains "$out" "measure	df	" "measure prints a filesystem line"
assert_not_contains "$out" "freed	" "measure deletes nothing"
assert_present "$proj/node_modules/pkg" "measure leaves node_modules alone"
assert_present "$home/data/record.txt" "measure leaves data records alone"

out=$(run clean --config "$cfg")
assert_contains "$out" "mode=dry-run" "clean defaults to dry-run"
assert_contains "$out" "would-free	reason=aged-file	category=tmp" "dry-run lists an aged temp file"
assert_contains "$out" "path=$old" "dry-run names the aged temp file"
assert_not_contains "$out" "path=$envf" "dry-run does not select a dotenv file"
assert_not_contains "$out" "path=$envrc" "dry-run does not select an envrc file"
assert_not_contains "$out" "path=$oauthf" "dry-run does not select an OAuth token"
assert_not_contains "$out" "path=$certf" "dry-run does not select a certificate"
assert_not_contains "$out" "path=$edge_file" "dry-run does not select Edge history"
assert_not_contains "$out" "path=$unknown_file" "dry-run does not select an undiscovered checkout file"
assert_not_contains "$out" "path=$fresh" "dry-run does not select a fresh temp file"
assert_not_contains "$out" "path=$openf" "dry-run does not select an open temp file"
assert_contains "$out" "reason=uncommitted-changes	category=worktree	path=$dirty" "dirty worktree is kept"
assert_contains "$out" "reason=named-by-task-record	category=worktree	path=$named_phys" "a recorded copy is kept"
assert_contains "$out" "reason=primary-checkout	category=worktree	path=$proj" "the primary checkout is kept"
assert_contains "$out" "reason=task-record-in-project	category=worktree	path=$landed" "a sibling task record blocks the whole project"
assert_not_contains "$out" "project=$proj	" "the recorded project is not delegated"
if [ -d /proc ]; then
  assert_contains "$out" "would-delegate	reason=landed-clean	tool=fm-treehouse-guard.sh	project=$idle_proj	" "a landed idle slot is handed to the pool guard"
  assert_contains "$out" "path=$idle" "the idle slot is named in the plan"
else
  assert_contains "$out" "reason=cannot-prove-idle	category=worktree	path=$idle" "without a process table the slot is kept"
fi
assert_not_contains "$out" "freed	" "dry-run frees nothing"
assert_present "$old" "dry-run leaves the aged file"
assert_present "$outside" "dry-run leaves a symlink target"

out=$(run clean --config "$cfg" --live)
assert_contains "$out" "mode=dry-run" "live request stays dry-run without authorization"
assert_present "$old" "an unauthorized live request leaves aged files"
: > "$home/config/data-management.live-authorized"
out=$(run clean --config "$cfg" --live)
assert_contains "$out" "mode=live" "live mode says so"
assert_contains "$out" "measure	phase=before" "live output includes the before measurement"
assert_contains "$out" "measure	phase=after" "live output includes the after measurement"
after=${out#*$'measure\tphase=after'}
assert_contains "$after" "measure	df	" "after measurement includes filesystem capacity"
assert_contains "$out" "freed	reason=aged-file	category=tmp" "live mode removes the aged temp file"
assert_absent "$old" "the aged temp file is gone"
assert_present "$fresh" "a fresh temp file stays"
assert_present "$envf" "a dotenv file stays"
assert_present "$envrc" "an envrc file stays"
assert_present "$oauthf" "an OAuth token stays"
assert_present "$certf" "a certificate stays"
assert_present "$edge_file" "Edge history stays"
assert_present "$unknown_file" "an undiscovered dirty checkout stays"
assert_present "$openf" "an open temp file stays"
assert_present "$outside" "a symlink target stays"
assert_present "$dirty/README" "a dirty worktree stays"
assert_present "$named_phys/README" "a recorded worktree stays"
assert_present "$landed/README" "a landed worktree is not removed by this script"
assert_present "$idle/README" "a delegated slot is not removed by this script"
if [ -d /proc ]; then
  assert_contains "$out" "delegate-ran	status=" "live mode asks the pool guard"
  assert_contains "$out" "project=$idle_proj" "the guard is asked only for the idle project"
  assert_not_contains "$out" "project=$proj" "the recorded project is not pruned"
fi
assert_present "$home/data/record.txt" "data records stay"
assert_present "$proj/node_modules/pkg" "node_modules stay"

logf="$home/state/logs/old.log"
note="$home/state/logs/notes.txt"
printf 'log\n' > "$logf"
printf 'note\n' > "$note"
fm_touch_epoch $((now - 3 * 86400)) "$logf" "$note"
logcfg="$TMP_ROOT/logs.conf"
cat > "$logcfg" <<EOF
home $home_phys
pool-root $pool_phys
log $home_phys/state/logs 1
EOF
out=$(run clean --config "$logcfg" --live)
assert_absent "$logf" "an aged log file is removed"
assert_present "$note" "a non-log file in the log root stays"

bad="$TMP_ROOT/bad.conf"
cat > "$bad" <<EOF
home $home_phys
tmp /mnt/c/temp 7
EOF
rc=0
run clean --config "$bad" >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a Windows path refuses the run"
assert_contains "$(cat "$TMP_ROOT/bad.err")" "not an allowed absolute path" "the refusal names the path rule"

cat > "$bad" <<EOF
home $home_phys
tmp $home_phys/data 7
EOF
rc=0
run clean --config "$bad" >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a data directory refuses the run"

linkdir="$TMP_ROOT/tmplink"
ln -s "$home_phys/.tmp" "$linkdir"
cat > "$bad" <<EOF
home $home_phys
tmp $linkdir 1
EOF
rc=0
run clean --config "$bad" >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a symlink deletion root refuses the run"
assert_present "$envf" "a refused run deletes nothing"

unconfigured="$TMP_ROOT/unconfigured/data"
mkdir -p "$unconfigured/archive"
aliased_file="$unconfigured/archive/old.txt"
printf 'private\n' > "$aliased_file"
fm_touch_epoch $((now - 3 * 86400)) "$aliased_file"
ln -s "$unconfigured" "$TMP_ROOT/alias"
cat > "$bad" <<EOF
home $home_phys
tmp $TMP_ROOT/alias/archive 1
EOF
rc=0
run clean --config "$bad" --live >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a parent symlink into another home's data refuses the run"
assert_present "$aliased_file" "the protected data record remains"

gh_store="$TMP_ROOT/unconfigured/.config/gh"
mkdir -p "$gh_store"
printf 'credential\n' > "$gh_store/hosts.yml"
cat > "$bad" <<EOF
home $home_phys
cache-tool npm $gh_store
EOF
rc=0
run clean --config "$bad" --live >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a CLI credential store refuses the run"
assert_contains "$(cat "$TMP_ROOT/bad.err")" "root is protected" "the credential-store refusal names the boundary"
assert_present "$gh_store/hosts.yml" "the CLI credential remains"

cat > "$bad" <<EOF
home $home_phys
claude-sessions $edge_root 1
EOF
rc=0
run clean --config "$bad" --live >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a browser profile refuses the session root"
assert_contains "$(cat "$TMP_ROOT/bad.err")" "root is protected" "the session refusal names the boundary"
assert_present "$edge_file" "the refused profile remains"

wtcfg="$TMP_ROOT/wt.conf"
scratch="$landed/scratch-old.txt"
printf 'scratch\n' > "$scratch"
fm_touch_epoch $((now - 3 * 86400)) "$scratch"
cat > "$wtcfg" <<EOF
home $home_phys
pool-root $pool_phys
tmp $landed 1
EOF
out=$(run clean --config "$wtcfg" --live)
assert_contains "$out" "reason=inside-worktree" "a worktree is not a temp root"
assert_present "$scratch" "files inside a worktree stay"

parentcfg="$TMP_ROOT/parent.conf"
nested="$landed/nested-old.txt"
printf 'nested\n' > "$nested"
fm_touch_epoch $((now - 3 * 86400)) "$nested"
cat > "$parentcfg" <<EOF
home $home_phys
pool-root $pool_phys
tmp $pool_phys 1
EOF
out=$(run clean --config "$parentcfg")
assert_not_contains "$out" "path=$nested" "a file inside a surveyed worktree is not selected"
assert_present "$nested" "dry-run leaves a file inside a worktree"

missing="$TMP_ROOT/missing-worktree"
printf 'worktree=%s\n' "$missing" > "$home/state/missing.meta"
sessions="$TMP_ROOT/sessions"
npm_cache="$TMP_ROOT/npm-cache"
pip_cache="$TMP_ROOT/pip-cache"
mkdir -p "$sessions" "$npm_cache" "$pip_cache" \
  "$home/state/procevent-inbox" "$home/state/procevent"
old_session="$sessions/old.jsonl"
fresh_session="$sessions/fresh.jsonl"
named_session="$sessions/named.jsonl"
keep_session="$sessions/keep.jsonl"
open_session="$sessions/open.jsonl"
env_session="$sessions/.env.jsonl"
nested_session="$sessions/nested-checkout/old.jsonl"
git init "${nested_session%/*}" >/dev/null
printf 'uncommitted session\n' > "$nested_session"
printf 'old session\n' > "$old_session"
printf 'fresh session\n' > "$fresh_session"
printf 'cwd %s\n' "$named_phys" > "$named_session"
printf 'cwd %s\n' "$idle" > "$keep_session"
printf 'open session\n' > "$open_session"
printf 'secret\n' > "$env_session"
old_handled="$home/state/procevent-inbox/old-evt.1.handled"
young_handled="$home/state/procevent-inbox/young-evt.1.handled"
live_handled="$home/state/procevent-inbox/live-evt.1.handled"
unhandled="$home/state/procevent-inbox/partial-evt.1.result"
for suffix in result adapter owner-task handled; do
  printf 'old\n' > "$home/state/procevent-inbox/old-evt.1.$suffix"
  printf 'young\n' > "$home/state/procevent-inbox/young-evt.1.$suffix"
  printf 'live\n' > "$home/state/procevent-inbox/live-evt.1.$suffix"
done
printf 'partial\n' > "$unhandled"
printf 'source\n' > "$home/state/procevent/live-evt.source"
fm_touch_epoch $((now - 3 * 86400)) \
  "$old_session" "$named_session" "$keep_session" "$open_session" "$env_session" "$nested_session" \
  "$home/state/procevent-inbox/old-evt.1.result" \
  "$home/state/procevent-inbox/old-evt.1.adapter" \
  "$home/state/procevent-inbox/old-evt.1.owner-task" \
  "$old_handled" \
  "$home/state/procevent-inbox/live-evt.1.result" \
  "$home/state/procevent-inbox/live-evt.1.adapter" \
  "$home/state/procevent-inbox/live-evt.1.owner-task" \
  "$live_handled" \
  "$unhandled"
tail -f "$open_session" >/dev/null &
holders="$holders $!"
pip_open="$pip_cache/held.txt"
printf 'held\n' > "$pip_open"
tail -f "$pip_open" >/dev/null &
holders="$holders $!"
cat > "$stubbin/codex-session-prune" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/codex.log"
exit 0
EOF
cat > "$stubbin/npm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/npm.log"
exit 0
EOF
cat > "$stubbin/pip3" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/pip.log"
exit 0
EOF
chmod +x "$stubbin/codex-session-prune" "$stubbin/npm" "$stubbin/pip3"
tiercfg="$TMP_ROOT/tier.conf"
cat > "$tiercfg" <<EOF
home $home_phys
pool-root $pool_phys
procevent-result 1
claude-sessions $sessions 1
codex-sessions 1
cache-tool npm $npm_cache
cache-tool pip $pip_cache
EOF

out=$(PATH="$stubbin:$PATH" run clean --config "$tiercfg")
assert_contains "$out" "reason=missing-or-link	category=worktree	path=$missing" \
  "a missing recorded copy does not abort the survey"
assert_contains "$out" "category=procevent-result	bytes=4	age-days=3	path=$old_handled" \
  "dry-run lists an old handled procevent group"
assert_not_contains "$out" "path=$young_handled" "dry-run leaves a young procevent group"
assert_contains "$out" "reason=live-source	category=procevent-result	path=$live_handled" \
  "a registered source keeps its result group"
assert_not_contains "$out" "path=$unhandled" "an unhandled result is not a cleanup group"
assert_contains "$out" "category=claude-sessions	bytes=12	age-days=3	path=$old_session" \
  "dry-run lists an old session log"
assert_not_contains "$out" "path=$fresh_session" "dry-run leaves a fresh session log"
assert_not_contains "$out" "path=$named_session" "dry-run leaves a session that names a recorded copy"
assert_not_contains "$out" "path=$keep_session" "dry-run leaves a session that names a surveyed copy"
assert_not_contains "$out" "path=$open_session" "dry-run leaves an open session log"
assert_not_contains "$out" "path=$env_session" "dry-run leaves a dotenv session name"
assert_not_contains "$out" "path=$nested_session" "dry-run leaves a nested checkout session"
assert_contains "$out" "external	tool=codex-session-prune	status=0" "dry-run invokes the session prune"
assert_contains "$(cat "$TMP_ROOT/codex.log")" "--dry-run" "the session prune is asked not to delete"
assert_contains "$out" "would-run	tool=npm	path=$npm_cache" "dry-run plans the npm purge"
assert_not_contains "$out" "would-run	tool=pip" "dry-run does not plan a purge of a store in use"
assert_absent "$TMP_ROOT/npm.log" "dry-run does not execute npm"
assert_absent "$TMP_ROOT/pip.log" "dry-run does not execute pip"
assert_present "$old_session" "dry-run leaves the old session log"
assert_present "$old_handled" "dry-run leaves the old procevent group"

out=$(PATH="$stubbin:$PATH" run clean --config "$tiercfg" --live)
assert_absent "$old_handled" "live mode removes an old handled procevent group"
assert_absent "$home/state/procevent-inbox/old-evt.1.result" "live mode removes the whole old group"
assert_present "$young_handled" "live mode leaves a young procevent group"
assert_present "$live_handled" "live mode leaves a group whose source is registered"
assert_present "$unhandled" "live mode leaves an unhandled result"
assert_present "$home/state/procevent/live-evt.source" "live mode leaves the source record"
assert_absent "$old_session" "live mode removes an old session log"
assert_present "$fresh_session" "live mode leaves a fresh session log"
assert_present "$named_session" "live mode leaves a session that names a recorded copy"
assert_present "$keep_session" "live mode leaves a session that names a surveyed copy"
assert_present "$open_session" "live mode leaves an open session log"
assert_present "$env_session" "live mode leaves a dotenv session name"
assert_present "$nested_session" "live mode leaves a nested checkout session"
assert_contains "$(cat "$TMP_ROOT/npm.log")" "--cache $npm_cache" "live mode purges only the configured npm cache"
assert_absent "$TMP_ROOT/pip.log" "live mode does not purge a store that has an open file"
assert_not_contains "$(tail -n 1 "$TMP_ROOT/codex.log")" "--dry-run" "live mode asks the session prune to delete"
assert_present "$pip_open" "the open cache file stays"

unsafe_cache="$TMP_ROOT/unsafe-npm-cache"
mkdir -p "$unsafe_cache"
git init "$unsafe_cache/hidden-checkout" >/dev/null
cat > "$tiercfg" <<EOF
home $home_phys
cache-tool npm $unsafe_cache
EOF
npm_before=$(wc -l < "$TMP_ROOT/npm.log")
out=$(PATH="$stubbin:$PATH" run clean --config "$tiercfg" --live)
assert_contains "$out" "reason=in-use	category=npm	path=$unsafe_cache" "a cache with a nested checkout is not purged"
assert_equals "$npm_before" "$(wc -l < "$TMP_ROOT/npm.log")" "the cache tool was not called on a nested checkout"

cat > "$tiercfg" <<EOF
home $home_phys
tmp $TMP_ROOT 1
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/ancestor.err" || rc=$?
assert_equals 1 "$rc" "a cleanup root containing a home was accepted"
assert_present "$home/config/data-management.live-authorized" "a refused ancestor root left home config intact"
cat > "$tiercfg" <<EOF
home $home_phys
claude-sessions $TMP_ROOT 1
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/ancestor.err" || rc=$?
assert_equals 1 "$rc" "a Claude root containing a home was accepted"
cat > "$tiercfg" <<EOF
home $home_phys
cache-tool npm $TMP_ROOT
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/ancestor.err" || rc=$?
assert_equals 1 "$rc" "a cache-tool root containing a home was accepted"

mkdir -p "$home/config/archive"
printf 'private\n' > "$home/config/archive/old.jsonl"
fm_touch_epoch $((now - 3 * 86400)) "$home/config/archive/old.jsonl"
cat > "$tiercfg" <<EOF
home $home_phys
claude-sessions $home_phys/config/archive 1
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/protected-root.err" || rc=$?
assert_equals 1 "$rc" "a Claude root inside home config was accepted"
assert_present "$home/config/archive/old.jsonl" "a refused Claude root kept config data"
cat > "$tiercfg" <<EOF
home $home_phys
cache-tool npm $home_phys/config/archive
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/protected-root.err" || rc=$?
assert_equals 1 "$rc" "a cache-tool root inside home config was accepted"

nested_home="$home/.tmp/nested-home"
mkdir -p "$nested_home/config/archive"
printf 'private\n' > "$nested_home/config/archive/old.txt"
fm_touch_epoch $((now - 3 * 86400)) "$nested_home/config/archive/old.txt"
cat > "$tiercfg" <<EOF
home $home_phys
home $nested_home
tmp $nested_home/config/archive 1
EOF
rc=0
run clean --config "$tiercfg" --live >/dev/null 2>"$TMP_ROOT/protected-root.err" || rc=$?
assert_equals 1 "$rc" "an outer home's tmp allowance exposed a nested home's config"
assert_present "$nested_home/config/archive/old.txt" "a nested home's config stayed intact"
rm -rf -- "$nested_home"

nested_root="$home/.tmp/nested-cache"
mkdir -p "$nested_root"
nested_file="$nested_root/retained.txt"
printf 'retained\n' > "$nested_file"
fm_touch_epoch $((now - 10 * 86400)) "$nested_file"
cat > "$tiercfg" <<EOF
home $home_phys
tmp $home_phys/.tmp 7
cache nested $nested_root 30
EOF
out=$(run clean --config "$tiercfg")
assert_not_contains "$out" "path=$nested_file" "the longer nested retention kept a 10-day file"
out=$(run clean --config "$tiercfg" --live)
assert_present "$nested_file" "live cleanup kept the 10-day nested file"
fm_touch_epoch $((now - 40 * 86400)) "$nested_file"
out=$(run clean --config "$tiercfg")
assert_equals 1 "$(printf '%s\n' "$out" | grep -F "path=$nested_file" | grep -c 'would-free')" "overlapping roots counted a file twice"
out=$(run clean --config "$tiercfg" --live)
assert_absent "$nested_file" "live cleanup removed a file past the longer retention"

log_root="$home/.tmp/logs"
mkdir -p "$log_root"
nonlog_file="$log_root/stale.txt"
log_file="$log_root/stale.log"
printf 'old\n' > "$nonlog_file"
printf 'old\n' > "$log_file"
fm_touch_epoch $((now - 10 * 86400)) "$nonlog_file" "$log_file"
cat > "$tiercfg" <<EOF
home $home_phys
tmp $home_phys/.tmp 7
log $log_root 30
EOF
out=$(run clean --config "$tiercfg")
assert_contains "$out" "$(printf 'would-free\treason=aged-file\tcategory=tmp\tbytes=4\tage-days=10\tpath=%s' "$nonlog_file")" "the wider tmp root owns a non-log file"
assert_not_contains "$out" "path=$log_file" "the longer log retention kept a 10-day log"
out=$(run clean --config "$tiercfg" --live)
assert_absent "$nonlog_file" "live cleanup removed the non-log file through tmp"
assert_present "$log_file" "live cleanup kept the 10-day log"
fm_touch_epoch $((now - 40 * 86400)) "$log_file"
out=$(run clean --config "$tiercfg")
assert_equals 1 "$(printf '%s\n' "$out" | grep -F "path=$log_file" | grep -c 'would-free')" "overlapping roots counted a log twice"

for suffix in result adapter handled; do
  printf 'old\n' > "$home/state/procevent-inbox/noowner-evt.1.$suffix"
  printf 'old\n' > "$home/state/procevent-inbox/extension-evt.1.$suffix"
  fm_touch_epoch $((now - 3 * 86400)) "$home/state/procevent-inbox/noowner-evt.1.$suffix" "$home/state/procevent-inbox/extension-evt.1.$suffix"
done
printf 'old\n' > "$home/state/procevent-inbox/extension-evt.1.extension"
fm_touch_epoch $((now - 3 * 86400)) "$home/state/procevent-inbox/extension-evt.1.extension"
printf 'old\n' > "$home/state/procevent-inbox/incomplete-evt.1.result"
printf 'old\n' > "$home/state/procevent-inbox/incomplete-evt.1.handled"
fm_touch_epoch $((now - 3 * 86400)) "$home/state/procevent-inbox/incomplete-evt.1.result" "$home/state/procevent-inbox/incomplete-evt.1.handled"
cat > "$tiercfg" <<EOF
home $home_phys
procevent-result 1
EOF
out=$(run clean --config "$tiercfg" --live)
assert_absent "$home/state/procevent-inbox/noowner-evt.1.result" "a handled group without owner-task was removed"
assert_absent "$home/state/procevent-inbox/noowner-evt.1.handled" "the no-owner group was removed whole"
assert_absent "$home/state/procevent-inbox/extension-evt.1.extension" "a handled extension sidecar was removed"
assert_absent "$home/state/procevent-inbox/extension-evt.1.handled" "the extension group was removed whole"
assert_present "$home/state/procevent-inbox/incomplete-evt.1.result" "an incomplete group kept its result"
assert_present "$home/state/procevent-inbox/incomplete-evt.1.handled" "an incomplete group kept its marker"

late="$home/.tmp/late-open.log"
printf 'late\n' > "$late"
fm_touch_epoch $((now - 3 * 86400)) "$late"
cat > "$stubbin/lsof" <<EOF
#!/bin/sh
if [ "\$2" = "$late" ]; then
  printf 'opened after survey\n'
  exit 0
fi
exit 1
EOF
chmod +x "$stubbin/lsof"
cat > "$tiercfg" <<EOF
home $home_phys
tmp $home_phys/.tmp 1
EOF
out=$(run clean --config "$tiercfg" --live)
assert_present "$late" "a file opened after the process survey was retained"
rm -f "$stubbin/lsof"

cat > "$tiercfg" <<EOF
home $home_phys
EOF
real_mkdir=$(command -v mkdir)
cat > "$stubbin/mkdir" <<EOF
#!/bin/sh
"$real_mkdir" "\$@" || exit \$?
if [ "\${TEST_DELAY_LOCK:-}" = 1 ] && [ "\$1" = "$tiercfg.lock" ]; then
  : > "$TMP_ROOT/data-lock-created"
  sleep 1
fi
EOF
chmod +x "$stubbin/mkdir"
export TEST_DELAY_LOCK=1
run measure --config "$tiercfg" > "$TMP_ROOT/first-measure.out" &
first_manager=$!
i=0
while [ ! -f "$TMP_ROOT/data-lock-created" ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "the first data manager did not create its lock"
  sleep 0.01
done
rc=0
run measure --config "$tiercfg" >/dev/null 2>"$TMP_ROOT/second-measure.err" || rc=$?
assert_equals 1 "$rc" "two data managers entered the lock together"
assert_contains "$(cat "$TMP_ROOT/second-measure.err")" "another data-manage run holds" "the second manager named the held lock"
wait "$first_manager"
unset TEST_DELAY_LOCK
rm -f "$stubbin/mkdir" "$TMP_ROOT/data-lock-created"

secondmate="$TMP_ROOT/secondmate"
mkdir -p "$secondmate/config" "$secondmate/state" "$secondmate/.tmp"
printf 'parent\n' > "$secondmate/.fm-secondmate-parent"
: > "$secondmate/config/data-management.live-authorized"
secondmate_file="$secondmate/.tmp/old.txt"
printf 'keep\n' > "$secondmate_file"
fm_touch_epoch $((now - 3 * 86400)) "$secondmate_file"
rm -f "$home/config/data-management.live-authorized"
cat > "$tiercfg" <<EOF
home $secondmate
home $home_phys
tmp $secondmate/.tmp 1
EOF
out=$(run clean --config "$tiercfg" --live)
assert_contains "$out" "mode=dry-run" "a secondmate marker did not authorize live cleanup"
assert_present "$secondmate_file" "a secondmate marker left its aged file intact"

pass "fm-data-manage keeps unlanded work and treats dry-run as read-only"
