#!/usr/bin/env bash
# Portable idle-sweep and target behavior. Real local backlog producer/parser;
# fake quota, forge and spawn prevent model usage and external mutations.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi required'; exit 0; }
command -v jq >/dev/null || { echo 'skip: jq required'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-idle-sweep)
home="$TMP_ROOT/home"
mkdir -p "$home" "$home/data" "$home/state" "$home/config" "$home/projects/example" "$TMP_ROOT/fakebin"
cp -R "$ROOT/bin" "$home/bin"
export FM_HOME="$home" FM_ROOT_OVERRIDE="$home" PATH="$TMP_ROOT/fakebin:$PATH"
export TEST_QUOTA=80 TEST_RED=1 TEST_SPAWN_LOG="$TMP_ROOT/starts" TEST_ENDPOINT=dead
: > "$TEST_SPAWN_LOG"
git -C "$home/projects/example" init -q
git -C "$home/projects/example" remote add origin https://github.com/example/repo.git
printf '%s\n' '- example [no-mistakes +yolo] - fixture' > "$home/data/projects.md"
cat > "$TMP_ROOT/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
string() { printf 'api_response:\n  body: %s\n  truncated: false\n' "$1"; }
  case "$2" in
  user) string fixture-user ;;
  search/issues*) echo 7 ;;
  repos/example/repo) string main ;;
  */commits/main) string abc123 ;;
  */status) string success ;;
  */check-runs*)
    [ "${TEST_FORGE_UNKNOWN:-0}" = 0 ] || exit 1
    if [ "$TEST_RED" = 1 ]; then
      echo 1
    else
      echo 0
    fi
    ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP_ROOT/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${TEST_QUOTA_HOOK:-}" ]; then
  calls=$(cat "$TEST_QUOTA_CALLS" 2>/dev/null || echo 0)
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$TEST_QUOTA_CALLS"
  [ "$calls" -ne 2 ] || bash "$TEST_QUOTA_HOOK"
fi
jq -cn --argjson percent "$TEST_QUOTA" --argjson stale "${TEST_QUOTA_STALE:-false}" \
  --arg account "${TEST_QUOTA_ACCOUNT:-codex-home}" '{schemaVersion:6,providers:[{
  provider:"codex",accountKey:$account,state:{status:"fresh",stale:$stale},
  quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",
    effectivePercentRemaining:$percent,runway:{status:"through_reset"}}]}}]}'
SH
cat > "$home/bin/fm-backend.sh" <<'SH'
fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }
fm_backend_of_meta() { echo tmux; }
fm_backend_target_of_meta() { fm_meta_get "$1" window; }
fm_backend_agent_state() { echo "$TEST_ENDPOINT"; }
SH
cat > "$home/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_SPAWN_LOG"
[ "${TEST_SPAWN_FAIL:-0}" = 0 ] || exit 1
printf 'kind=crewmate\nwindow=fm-%s\n' "$1" > "$FM_HOME/state/$1.meta"
SH
chmod +x "$TMP_ROOT/fakebin/gh-axi" "$TMP_ROOT/fakebin/quota-axi"

add_task() {
  bash "$home/bin/fm-tasks-axi.sh" add "$1" "Reversible fixture $1" --repo example >/dev/null
  mkdir -p "$home/data/$1"
  printf "# Task\n## Captain's intent\nFix the fixture.\n## Firstmate spec\nKeep it reversible.\nDelivery contract: mode=no-mistakes\n" > "$home/data/$1/brief.md"
  cat >> "$home/data/$1/brief.md" <<'BOUNDARY'
Never merge, deploy, spend money, contact a client, answer a captain decision, or alter a captain-held item.
If the task needs one of those actions, report needs-decision to firstmate and stop.
BOUNDARY
}
for id in ordinary held captain red extra extra2 extra3 flight; do add_task "$id"; done
bash "$home/bin/fm-tasks-axi.sh" hold held --reason 'on hold' >/dev/null
bash "$home/bin/fm-tasks-axi.sh" hold captain --kind captain --reason 'captain call' >/dev/null
bash "$home/bin/fm-tasks-axi.sh" start flight >/dev/null
cat > "$home/config/idle-sweep.json" <<'JSON'
{"enabled":true,"steps":[
 {"id":"ordinary","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"held","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"captain","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"extra","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"extra2","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"extra3","target":"backlog","mode":"no-mistakes","reversible":true},
 {"id":"red","target":"red_default_branches","mode":"no-mistakes","reversible":true}]}
JSON
sweep() { bash "$home/bin/fm-idle-sweep.sh" > "$TMP_ROOT/out"; }
no_starts() { [ ! -s "$TEST_SPAWN_LOG" ] || fail "$1"; pass "$1"; }
cp "$home/config/idle-sweep.json" "$TMP_ROOT/enrollment.json"
jq '.enabled=false' "$TMP_ROOT/enrollment.json" > "$home/config/idle-sweep.json"
sweep
no_starts 'disabled enrollment leaves the sweep off'
[ ! -e "$home/state/idle-sweep-backlog.json" ] || fail 'disabled sweep wrote observations'
cp "$TMP_ROOT/enrollment.json" "$home/config/idle-sweep.json"
sweep
no_starts 'orphan in-flight backlog work holds the idle batch'
bash "$home/bin/fm-tasks-axi.sh" reopen flight >/dev/null
bash "$home/bin/fm-tasks-axi.sh" hold flight --reason 'fixture parked' >/dev/null
printf 'kind=crewmate\nwindow=fm-live\n' > "$home/state/live.meta"
TEST_ENDPOINT=alive sweep
no_starts 'no fire while a worker process is live'
TEST_ENDPOINT=unverified sweep
no_starts 'unknown endpoint classification holds the batch'
rm "$home/state/live.meta"
jq '.steps |= map(select(.id=="ordinary"))' "$TMP_ROOT/enrollment.json" > "$home/config/idle-sweep.json"
cp "$home/data/ordinary/brief.md" "$TMP_ROOT/ordinary-brief"
printf "# Task\n## Captain's intent\nFix the fixture.\n## Firstmate spec\nNo boundary supplied.\n" > "$home/data/ordinary/brief.md"
sweep
if grep -q '^ordinary ' "$TEST_SPAWN_LOG"; then fail 'unbounded prepared brief was dispatched'; fi
pass 'unbounded prepared brief is not dispatched'
for id in ordinary held captain red extra extra2 extra3 flight; do rm -f "$home/state/$id.meta"; done
: > "$TEST_SPAWN_LOG"
cp "$TMP_ROOT/ordinary-brief" "$home/data/ordinary/brief.md"
cp "$TMP_ROOT/enrollment.json" "$home/config/idle-sweep.json"
TEST_QUOTA=14 sweep
no_starts 'no fire below the Codex floor'
TEST_QUOTA=15 sweep
no_starts 'no fire exactly at the Codex floor'
TEST_QUOTA_STALE=true sweep
no_starts 'stale quota cannot authorize a batch'
TEST_QUOTA=null sweep
no_starts 'unknown or malformed quota cannot authorize a batch'
TEST_QUOTA_ACCOUNT=other-account sweep
no_starts 'quota from another Codex account cannot authorize a batch'
TEST_FORGE_UNKNOWN=1 sweep
no_starts 'unknown red branch evidence holds backlog work'
# Untouched means observed unchanged, not a row created a long time ago.
jq 'with_entries(.value.changed -= 15 * 86400)' "$home/state/idle-sweep-backlog.json" > "$TMP_ROOT/aged"
mv "$TMP_ROOT/aged" "$home/state/idle-sweep-backlog.json"
result=$(bash "$home/bin/fm-targets.sh" --json)
printf '%s' "$result" | jq -e '.targets == [
  {id:"red_default_branches",current:1,limit:0,gap:1},
  {id:"open_prs",current:7,limit:4,gap:3},
  {id:"stale_backlog",current:8,limit:0,gap:8}]' >/dev/null || fail 'fixture target values and gaps'
pass 'read-only target evaluator reports fixture values and gaps'
before=$(cat "$home/state/idle-sweep-backlog.json")
text_output=$(bash "$home/bin/fm-targets.sh")
assert_contains "$text_output" 'open_prs: current=7 limit=4 gap=3' 'text target projection'
[ "$(cat "$home/state/idle-sweep-backlog.json")" = "$before" ] || fail 'evaluator mutated observations'
printf '{"open_prs":10}\n' > "$home/config/targets.json"
result=$(bash "$home/bin/fm-targets.sh" --json)
printf '%s' "$result" | jq -e '.targets[] | select(.id=="open_prs") | .limit==10 and .gap==0' >/dev/null || fail 'partial target overrides'
rm "$home/config/targets.json"
rm "$home/config/idle-sweep.json"
sweep
[ "$(wc -l < "$TEST_SPAWN_LOG" | tr -d ' ')" = 3 ] || fail 'default sweep did not start prepared backlog work'
[ "$(head -1 "$TEST_SPAWN_LOG" | cut -d ' ' -f1)" = ordinary ] || fail 'default sweep did not use backlog order'
pass 'absent configuration starts prepared reversible backlog work'
for id in ordinary held captain red extra extra2 extra3 flight; do rm -f "$home/state/$id.meta"; done
: > "$TEST_SPAWN_LOG"
: > "$home/state/idle-sweep.status"
cp "$TMP_ROOT/enrollment.json" "$home/config/idle-sweep.json"
printf 'needs-decision [at=1791902116] [key=fixture]: approval needed\n' > "$home/state/extra.status"
captain_brief=$(cat "$home/data/captain/brief.md")
ordinary_brief=$(cat "$home/data/ordinary/brief.md")
sweep
[ "$(cat "$home/data/captain/brief.md")" = "$captain_brief" ] || fail 'captain-held brief was changed'
[ "$(cat "$home/data/ordinary/brief.md")" = "$ordinary_brief" ] || fail 'enrolled brief was changed'
[ "$(wc -l < "$TEST_SPAWN_LOG" | tr -d ' ')" = 3 ] || fail 'batch cap'
[ "$(head -1 "$TEST_SPAWN_LOG" | cut -d ' ' -f1)" = red ] || fail 'red outranks backlog'
if grep -Eq '^(held|captain|extra|flight) ' "$TEST_SPAWN_LOG"; then fail 'held, decision, or in-flight work selected'; fi
grep -q -- '--yolo off' "$TEST_SPAWN_LOG" || fail 'merge authority was not forced off'
grep -q -- '--harness codex --model gpt-6.1-sol' "$TEST_SPAWN_LOG" || fail 'explicit Codex profile'
[ "$(wc -l < "$home/state/idle-sweep.status" | tr -d ' ')" = 1 ] || fail 'one status line per batch'
pass 'at most three starts, red first, holds and decisions excluded, explicit Codex and yolo off'
sweep
[ "$(wc -l < "$TEST_SPAWN_LOG" | tr -d ' ')" = 4 ] || fail 'existing metadata must prevent duplicate starts'
pass 'a later batch never restarts an existing task'
# Changing a row makes its previously observed age unknown until a heartbeat.
bash "$home/bin/fm-tasks-axi.sh" update ordinary --title 'Changed work' >/dev/null
result=$(bash "$home/bin/fm-targets.sh" --json)
printf '%s' "$result" | jq -e '.targets[] | select(.id=="stale_backlog") | .current==null and .gap==null' >/dev/null || fail 'changed row stale age'
pass 'changed row invalidates previously observed stale age'
jq '.steps[0].reversible=false' "$TMP_ROOT/enrollment.json" > "$home/config/idle-sweep.json"
if sweep 2> "$TMP_ROOT/error"; then fail 'unsafe enrollment must be refused'; fi
pass 'non-reversible enrollment is refused'
cp "$TMP_ROOT/enrollment.json" "$home/config/idle-sweep.json"
for id in ordinary held captain extra extra2 extra3 flight; do
  printf 'kind=crewmate\nwindow=fm-%s\n' "$id" > "$home/state/$id.meta"
done
rm -f "$home/state/red.meta"
: > "$TEST_SPAWN_LOG"
cp "$home/data/backlog.md" "$TMP_ROOT/backlog-before-race"
cat > "$TMP_ROOT/change-row" <<'SH'
#!/usr/bin/env bash
perl -pi -e 's/repo: example/repo: other/ if /red -/' "$FM_HOME/data/backlog.md"
SH
export TEST_QUOTA_HOOK="$TMP_ROOT/change-row" TEST_QUOTA_CALLS="$TMP_ROOT/quota-calls"
rm -f "$TEST_QUOTA_CALLS"
sweep
[ ! -s "$TEST_SPAWN_LOG" ] || fail 'moved project dispatched from stale target evidence'
cmp -s "$home/data/backlog.md" "$TMP_ROOT/backlog-before-race" && fail 'row race fixture did not change the backlog'
pass 'a project changed during quota read cannot dispatch from old target evidence'
cp "$TMP_ROOT/backlog-before-race" "$home/data/backlog.md"
cat > "$TMP_ROOT/change-brief" <<'SH'
#!/usr/bin/env bash
printf "# Task\n## Captain's intent\nFix the fixture.\n## Firstmate spec\nBoundary withdrawn.\n" > "$FM_HOME/data/red/brief.md"
SH
TEST_QUOTA_HOOK="$TMP_ROOT/change-brief"
rm -f "$TEST_QUOTA_CALLS"
sweep
[ ! -s "$TEST_SPAWN_LOG" ] || fail 'brief with withdrawn boundary dispatched'
pass 'a brief boundary withdrawn during quota read prevents dispatch'
unset TEST_QUOTA_HOOK TEST_QUOTA_CALLS
# Exercise the actual watcher heartbeat hook and its normal wake path without
# launching a worker or touching a real terminal backend.
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"
watch_home=$(make_case idle-sweep-heartbeat)
watch_code="$TMP_ROOT/watch-code"
mkdir -p "$watch_code" "$watch_home/data" "$watch_home/config"
cp -R "$ROOT/bin" "$watch_code/bin"
cat > "$watch_code/bin/fm-idle-sweep.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/sweep-called"
exit 1
SH
PATH="$watch_home/fakebin:$PATH" FM_HOME="$watch_home" FM_ROOT_OVERRIDE="$watch_code" \
  FM_STATE_OVERRIDE="$watch_home/state" FM_CONFIG_OVERRIDE="$watch_home/config" \
  FM_DATA_OVERRIDE="$watch_home/data" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
  bash "$watch_code/bin/fm-watch.sh" > "$watch_home/watch.out" 2> "$watch_home/watch.err" &
watch_pid=$!
wait_for_exit "$watch_pid" 200 || fail "watcher failed to surface sweep refusal: $(cat "$watch_home/watch.err")"
[ -f "$watch_home/sweep-called" ] || fail 'heartbeat did not call sweep'
grep -Fxq 'check: idle-sweep' "$watch_home/watch.out" || fail 'sweep failure did not produce a normal wake'
pass 'supervision heartbeat calls the sweep and surfaces failures through the wake queue'
echo '# fm-idle-sweep.test.sh: all assertions passed'
