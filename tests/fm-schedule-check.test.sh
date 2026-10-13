#!/usr/bin/env bash
# Enqueue-only schedules: isolated homes, durable replay, DST, receipts and bounds.
# No session backend, model, forge, or live home is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-schedule-check)
CHECK="$ROOT/bin/fm-schedule-check.sh"
REAL_PYTHON=$(command -v python3)
REAL_TASKS=$(command -v tasks-axi)
export REAL_PYTHON REAL_TASKS

world() {
  export FM_HOME="$TMP_ROOT/$1" FM_SCHEDULE_NOW=1791889200
  unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data"
  cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
  printf 'Read permitted freshness evidence.\n' > "$FM_HOME/data/brief.md"
}

config() {
  local kind=${1:-daily-local}
  if [ "$kind" = daily-local ]; then
    CADENCE='{"kind":"daily-local","at":"07:00","timezone":"America/Toronto"}'
  else
    CADENCE='{"kind":"interval","seconds":7200}'
  fi
  jq -n --arg home "$FM_HOME" --argjson cadence "$CADENCE" \
    '{version:1,schedules:[{id:"freshness",enabled:true,home:$home,project:"firstmate",delivery:"scout",intent:"Observe freshness",brief:($home+"/data/brief.md"),cadence:$cadence}]}' > "$FM_HOME/config/schedules.json"
}

field() { jq -r ".jobs.freshness.$1" "$FM_HOME/state/.schedule-occurrences.json"; }
queue_count() { if [ -f "$FM_HOME/state/.wake-queue" ]; then wc -l < "$FM_HOME/state/.wake-queue"; else printf '0\n'; fi; }
tasks() { bash "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
receipt() {
  case "$1" in
    dispatched) tasks start "$(field task_id)" >/dev/null ;;
    completed) tasks "done" "$(field task_id)" --report "data/$(field task_id)/report.md" --no-prune >/dev/null ;;
    *) fail 'unknown fixture transition' ;;
  esac
  bash "$CHECK" check
}

world off
[ -z "$(bash "$CHECK" check)" ] || fail 'absent config was noisy'
[ ! -e "$FM_HOME/state/.schedule-occurrences.json" ] || fail 'absent config created journal'
config
jq '.schedules[0].enabled=false' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/off.json"
mv "$FM_HOME/config/off.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'disabled job enqueued'
bash "$CHECK" arm >/dev/null
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
fm_custom_check_registered "$FM_HOME/state" scheduled-work || fail 'shim lacks authenticated trust'
bash "$CHECK" disarm >/dev/null
[ ! -e "$FM_HOME/state/scheduled-work.check.sh" ] || fail 'disarm retained shim'
pass 'absent/disabled config is off; explicit arm uses authenticated registration'

world daily
config
export FM_SCHEDULE_NOW=1791889140 # 2026-10-13 06:59 Toronto
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'daily job fired before local gate'
export FM_SCHEDULE_NOW=1791889200
bash "$CHECK" check
KEY=$(field key)
TASK=$(field task_id)
[ "$KEY" = freshness:daily:2026-10-13 ] || fail "wrong daily identity: $KEY"
[ "$(field state)" = enqueued ] || fail 'verified backlog receipt missing'
assert_contains "$(tasks show "$TASK" --full)" 'state: queued' 'scheduler did not file ordinary queued task'
assert_grep "brief: $FM_HOME/data/$TASK/schedule-brief.md" "$FM_HOME/data/backlog.md" 'backlog omitted frozen brief pointer'
BEFORE=$(cat "$FM_HOME/data/$TASK/schedule-brief.md")
printf 'New source should not replace pending intent.\n' > "$FM_HOME/data/brief.md"
bash "$CHECK" check
[ "$(cat "$FM_HOME/data/$TASK/schedule-brief.md")" = "$BEFORE" ] || fail 'source edit changed frozen occurrence brief'
[ "$(queue_count)" -eq 1 ] || fail 'daily wake missing'
bash "$CHECK" check
[ "$(queue_count)" -eq 1 ] || fail 'poll duplicated pending wake'
export FM_SCHEDULE_NOW=1792321200 # five days later, still one pending occurrence
bash "$CHECK" check
[ "$(field key)" = "$KEY" ] || fail 'downtime replaced pending occurrence'
[ "$(queue_count)" -eq 1 ] || fail 'downtime added a duplicate'
# Simulate consumed wake without a dispatch receipt, including restart replay.
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 1 ] || fail 'unclaimed occurrence was lost after wake consumption'
[ "$(field task_id)" = "$TASK" ] || fail 'replay changed task identity'
receipt dispatched
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'dispatched occurrence launched another intake'
receipt completed
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-10-18 ] || fail 'catch-up did not coalesce to current day'
bash "$CHECK" disarm >/dev/null
[ "$(field state)" = enqueued ] || fail 'disarm discarded durable pending work'
pass 'daily gate, frozen brief, ordinary backlog intake, downtime and lifecycle receipts'

world disable-pending
config
bash "$CHECK" check
jq '.schedules[0].enabled=false' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/off.json"
mv "$FM_HOME/config/off.json" "$FM_HOME/config/schedules.json"
[ "$(bash "$CHECK" pending | jq -r '.[0].enabled')" = false ] || fail 'disabled pending intent presented as enabled'
[ "$(field state)" = enqueued ] || fail 'disable discarded pending intent'
assert_contains "$(tasks show "$(field task_id)" --full)" 'state: queued' 'disable deleted already filed backlog work'
rm "$FM_HOME/config/schedules.json"
[ "$(bash "$CHECK" pending | jq -r '.[0].enabled')" = false ] || fail 'removed schedule granted intake'
pass 'disable/remove retains filed work under ordinary task lifecycle'

world concurrent
config interval
bash "$CHECK" check &
ONE=$!
bash "$CHECK" check &
TWO=$!
wait "$ONE"
wait "$TWO"
[ "$(queue_count)" -eq 1 ] || fail 'concurrent polls duplicated occurrence publication'
pass 'simultaneous polls converge on one occurrence and wake'

world batch
config interval
jq '.schedules[0] as $job | .schedules=[range(0;25) | $job + {id:("job-"+tostring)}]' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/batch.json"
mv "$FM_HOME/config/batch.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(queue_count)" -eq 5 ] || fail 'poll did not bound publication batch'
[ "$(jq '.jobs | length' "$FM_HOME/state/.schedule-occurrences.json")" -eq 25 ] || fail 'batch lost unqueued detected intent'
for round in 1 2 3 4; do bash "$CHECK" check; done
[ "$(queue_count)" -eq 25 ] || fail 'continuation starved later jobs behind queued intent'
bash "$CHECK" check
[ "$(queue_count)" -eq 25 ] || fail 'finished publication batch duplicated work'
pass 'bounded batch preserves remaining intent and continues past queued jobs'

world interval
config interval
export FM_SCHEDULE_NOW=7200
bash "$CHECK" check
[ "$(field key)" = freshness:interval:1 ] || fail 'incorrect interval slot'
[ "$(field state)" = enqueued ] || fail 'enqueue was treated as completion'
receipt dispatched
receipt completed
export FM_SCHEDULE_NOW=14400
bash "$CHECK" check
[ "$(field key)" = freshness:interval:2 ] || fail 'next interval not detected'
receipt dispatched
receipt completed
export FM_SCHEDULE_NOW=7200
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'backward clock resurrected completed slot'
pass 'interval gates and backward clock preserve successful receipt'

world edited-gate
config
bash "$CHECK" check
receipt dispatched
receipt completed
jq '.schedules[0].cadence.at="06:00"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'edited daily gate repeated completed identity'
pass 'daily gate edits cannot repeat a completed local date'

world dst
config
jq '.schedules[0].cadence.at="02:30"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/dst.json"
mv "$FM_HOME/config/dst.json" "$FM_HOME/config/schedules.json"
export FM_SCHEDULE_NOW=1772953200 # spring gap, 2026-03-08 03:00 Toronto
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-03-08 ] || fail 'spring-forward gate lost occurrence'
receipt dispatched
receipt completed
jq '.schedules[0].cadence.at="01:30"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/dst.json"
mv "$FM_HOME/config/dst.json" "$FM_HOME/config/schedules.json"
export FM_SCHEDULE_NOW=1793511000 # first 01:30, 2026-11-01
bash "$CHECK" check
receipt dispatched
receipt completed
: > "$FM_HOME/state/.wake-queue"
export FM_SCHEDULE_NOW=1793514600 # repeated 01:30
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'fall-back wall time duplicated local date'
pass 'spring gap catches up; fall repeat stays one occurrence per local date'

world malformed
config
jq '.schedules += [(.schedules[0] | .id="other" | .command="touch /tmp/forbidden")]' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/bad.json"
mv "$FM_HOME/config/bad.json" "$FM_HOME/config/schedules.json"
OUT=$(bash "$CHECK" check 2>&1) && fail 'arbitrary command field accepted'
assert_contains "$OUT" 'invalid job fields' 'invalid configuration lacks diagnostic'
[ "$(queue_count)" -eq 0 ] || fail 'partial invalid configuration published work'
OUT=$(bash "$CHECK" check 2>&1) && fail 'invalid config unexpectedly recovered'
[ -z "$OUT" ] || fail 'same failure episode repeated'
config
bash "$CHECK" check
[ ! -e "$FM_HOME/state/.schedule-error" ] || fail 'successful check did not clear episode'
pass 'whole-config validation refuses executable fields and reports one failure episode'

world crash
config
mkdir -p "$FM_HOME/fakebin"
cat > "$FM_HOME/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Simulate an uncertain return after the owner durably creates the backlog row.
if [ "${1:-}" = add ] && [ ! -e "$FM_HOME/failed-once" ]; then
  "$REAL_TASKS" "$@" || exit $?
  touch "$FM_HOME/failed-once"
  exit 1
fi
exec "$REAL_TASKS" "$@"
SH
chmod +x "$FM_HOME/fakebin/tasks-axi"
PATH="$FM_HOME/fakebin:$PATH" bash "$CHECK" check >/dev/null 2>&1 && fail 'receipt failure fixture did not fire'
[ "$(field state)" = detected ] || fail 'failed receipt was falsely recorded'
[ "$(queue_count)" -eq 0 ] || fail 'wake preceded verified backlog receipt'
assert_contains "$(tasks show "$(field task_id)" --full)" 'state: queued' 'uncertain add did not create the fixture row'
bash "$CHECK" check
[ "$(field state)" = enqueued ] || fail 'restart did not recover enqueue receipt'
[ "$(queue_count)" -eq 1 ] || fail 'crash recovery duplicated wake'
COUNT=$(tasks list --state queued --fields body | awk '/sched-/ {n++} END {print n+0}')
[ "$COUNT" -eq 1 ] || fail 'uncertain add recovery duplicated backlog task'
pass 'uncertain durable add reuses frozen occurrence and existing backlog row'

world disappeared
config
bash "$CHECK" check
TASK=$(field task_id)
tasks start "$TASK" >/dev/null
tasks "done" "$TASK" --report "data/$TASK/report.md" --keep 0 >/dev/null
: > "$FM_HOME/state/.wake-queue"
OUT=$(bash "$CHECK" check 2>&1) && fail 'disappeared task was recreated'
assert_contains "$OUT" 'unknown custody' 'missing task lacks reconciliation diagnostic'
[ "$(field state)" = enqueued ] || fail 'absence was treated as completion'
[ "$(queue_count)" -eq 0 ] || fail 'archived task was requeued'
OUT=$(bash "$CHECK" check 2>&1) && fail 'unresolved custody unexpectedly cleared'
[ -z "$OUT" ] || fail 'unknown-custody episode repeated'
pass 'disappeared or quickly archived task stays pending without duplicate recreation'

world typed
config
cat > "$FM_HOME/config/task-types.json" <<'JSON'
{"types":[{"name":"observe","use":"Inspect freshness","hand_back":"A report","touch":"Evidence only","projects":["firstmate"],"model":"fixture-model","effort":"high"}]}
JSON
jq '.schedules[0] |= (del(.brief) + {task_type:"observe"})' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/typed.json"
mv "$FM_HOME/config/typed.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
BRIEF=$(cat "$FM_HOME/data/$(field task_id)/schedule-brief.md")
assert_contains "$BRIEF" 'Name: observe' 'task-type owner render was not frozen'
case "$BRIEF" in *fixture-model*|*type-profile:*) fail 'task-type worker subscription leaked into schedule request' ;; esac
pass 'task-type request freezes owner section and leaves worker profile to current intake'

world timeout
config
mkdir -p "$FM_HOME/fakebin"
printf '#!/usr/bin/env bash\nexec sleep 10\n' > "$FM_HOME/fakebin/python3"
chmod +x "$FM_HOME/fakebin/python3"
OUT=$(FM_CHECK_TIMEOUT=2 PATH="$FM_HOME/fakebin:$PATH" bash "$CHECK" check 2>&1) && fail 'hung check did not time out'
assert_contains "$OUT" 'timed out' 'timeout lacked actionable evidence'
bash "$CHECK" check
[ "$(queue_count)" -eq 1 ] || fail 'bounded failure prevented later recovery'
pass 'watcher timeout bound preserves retry and recovers stale operation lock'

world unsafe
config
printf '{}\n' > "$FM_HOME/untouched"
ln -s "$FM_HOME/untouched" "$FM_HOME/state/.schedule-occurrences.json"
bash "$CHECK" check >/dev/null 2>&1 && fail 'symlink journal accepted'
[ "$(cat "$FM_HOME/untouched")" = '{}' ] || fail 'unsafe target changed'
rm "$FM_HOME/state/.schedule-occurrences.json"
ln -s "$FM_HOME/untouched" "$FM_HOME/config/schedules.json.link"
mv "$FM_HOME/config/schedules.json.link" "$FM_HOME/config/schedules.json"
bash "$CHECK" check >/dev/null 2>&1 && fail 'symlink config accepted'
pass 'unsafe journal/config destinations are refused'

world watcher
config
mkdir -p "$FM_HOME/fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FM_HOME/fakebin/tmux"
chmod +x "$FM_HOME/fakebin/tmux"
printf 'tmux\n' > "$FM_HOME/config/backend"
bash "$CHECK" arm >/dev/null
# Drive the production watcher with a backend test double, never a real server.
# The check's durable append publishes the existing recovery marker, which the
# next ordinary poll surfaces even though a successful enqueue has no stdout.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
OUT=$(FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 PATH="$FM_HOME/fakebin:$PATH" \
  fm_run_timed 15 bash "$ROOT/bin/fm-watch.sh" 2>"$FM_HOME/watcher.err") || fail "watcher failed: $(cat "$FM_HOME/watcher.err")"
assert_contains "$OUT" 'check:' 'armed recurring check did not wake supervisor'
[ "$(queue_count)" -eq 1 ] || fail 'watcher did not capture one durable occurrence'
assert_grep 'check: queued task sched-' "$FM_HOME/state/.wake-queue" 'wake lost ordinary queued-task context'
bash "$CHECK" check
[ "$(queue_count)" -eq 1 ] || fail 'restart replay duplicated watcher publication'
pass 'authenticated shim reaches production watcher with isolated backend double'
