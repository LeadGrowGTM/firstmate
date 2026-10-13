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

world foreign-check
config
printf '#!/usr/bin/env bash\nexit 0\n' > "$FM_HOME/state/scheduled-work.check.sh"
chmod 0700 "$FM_HOME/state/scheduled-work.check.sh"
bash "$ROOT/bin/fm-check-register.sh" scheduled-work >/dev/null
cp "$FM_HOME/state/scheduled-work.check.sh" "$FM_HOME/foreign-shim"
cp "$FM_HOME/state/scheduled-work.check-trust" "$FM_HOME/foreign-trust"
OUT=$(bash "$CHECK" arm 2>&1) && fail 'arm replaced a foreign scheduled-work check'
assert_contains "$OUT" 'not scheduler-owned' 'foreign arm refusal lacked ownership evidence'
OUT=$(bash "$CHECK" disarm 2>&1) && fail 'disarm removed a foreign scheduled-work check'
assert_contains "$OUT" 'not scheduler-owned' 'foreign disarm refusal lacked ownership evidence'
cmp -s "$FM_HOME/foreign-shim" "$FM_HOME/state/scheduled-work.check.sh" || fail 'foreign shim changed'
cmp -s "$FM_HOME/foreign-trust" "$FM_HOME/state/scheduled-work.check-trust" || fail 'foreign trust changed'
fm_custom_check_registered "$FM_HOME/state" scheduled-work || fail 'foreign check lost its authenticated trust'
pass 'arm and disarm refuse a foreign authenticated check'

world failed-rearm
config
bash "$CHECK" arm >/dev/null
cp "$FM_HOME/state/scheduled-work.check.sh" "$FM_HOME/prior-shim"
cp "$FM_HOME/state/scheduled-work.check-trust" "$FM_HOME/prior-trust"
REAL_MV=$(command -v mv)
export REAL_MV
mkdir -p "$FM_HOME/fakebin"
cat > "$FM_HOME/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg; do target=$arg; done
if [ "$target" = "$FM_HOME/state/scheduled-work.check-trust" ] && [ ! -e "$FM_HOME/fakebin/failed-once" ]; then
  "$REAL_MV" "$@" || exit $?
  printf 'corrupt\n' > "$target"
  : > "$FM_HOME/fakebin/failed-once"
  exit 1
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$FM_HOME/fakebin/mv"
PATH="$FM_HOME/fakebin:$PATH" bash "$CHECK" arm >/dev/null 2>&1 && fail 'failed rearm unexpectedly succeeded'
[ -e "$FM_HOME/fakebin/failed-once" ] || fail 'rearm fixture did not corrupt trust after registration'
cmp -s "$FM_HOME/prior-shim" "$FM_HOME/state/scheduled-work.check.sh" || fail 'failed rearm changed prior shim'
cmp -s "$FM_HOME/prior-trust" "$FM_HOME/state/scheduled-work.check-trust" || fail 'failed rearm did not restore prior trust'
fm_custom_check_registered "$FM_HOME/state" scheduled-work || fail 'failed rearm broke the prior authenticated check'
pass 'failed rearm restores the prior shim and trust together'

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
bash "$CHECK" check
[ "$(field state)" = enqueued ] || fail 'disable discarded pending intent'
assert_contains "$(tasks show "$(field task_id)" --full)" 'state: queued' 'disable deleted already filed backlog work'
rm "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(field state)" = enqueued ] || fail 'removed schedule discarded pending intent'
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

world batch-failure
config interval
export FM_SCHEDULE_NOW=7200
jq '.schedules[0] as $job | .schedules=[range(0;5) | $job + {id:("job-"+tostring)}]' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/batch.json"
mv "$FM_HOME/config/batch.json" "$FM_HOME/config/schedules.json"
BLOCKED=$("$REAL_PYTHON" -c 'import hashlib; print("sched-" + hashlib.sha256(b"job-0:interval:7200-14400").hexdigest()[:24])')
mkdir -p "$FM_HOME/data/$BLOCKED"
printf 'wrong frozen content\n' > "$FM_HOME/data/$BLOCKED/schedule-brief.md"
bash "$CHECK" check >/dev/null 2>&1 && fail 'broken first job unexpectedly prepared'
[ "$(queue_count)" -eq 0 ] || fail 'first failure did not stop initial batch'
bash "$CHECK" check >/dev/null 2>&1 && fail 'broken first job unexpectedly recovered'
[ "$(queue_count)" -eq 4 ] || fail 'broken first job starved the other four jobs'
[ "$(jq '[.jobs[] | select(.state=="enqueued")] | length' "$FM_HOME/state/.schedule-occurrences.json")" -eq 4 ] || fail 'healthy jobs lack enqueue receipts'
pass 'five pending jobs advance past a repeatedly failing first job'

world interval
config interval
export FM_SCHEDULE_NOW=7200
bash "$CHECK" check
[ "$(field key)" = freshness:interval:7200-14400 ] || fail 'incorrect interval window'
[ "$(field state)" = enqueued ] || fail 'enqueue was treated as completion'
receipt dispatched
receipt completed
export FM_SCHEDULE_NOW=14400
bash "$CHECK" check
[ "$(field key)" = freshness:interval:14400-21600 ] || fail 'next interval not detected'
receipt dispatched
receipt completed
export FM_SCHEDULE_NOW=7200
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'backward clock resurrected completed slot'
pass 'interval gates and backward clock preserve successful receipt'

world interval-edit
config interval
export FM_SCHEDULE_NOW=10800
bash "$CHECK" check
ORIGINAL=$(field task_id)
receipt dispatched
receipt completed
tasks prune --keep 0 >/dev/null
jq '.schedules[0].cadence.seconds=3600' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(field key)" = freshness:interval:10800-14400 ] || fail 'one-hour edit did not create its current slot'
receipt dispatched
receipt completed
tasks prune --keep 0 >/dev/null
jq '.schedules[0].cadence.seconds=7200' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'two-hour restoration recreated completed slot'
[ "$(field key)" = freshness:interval:10800-14400 ] || fail 'two-hour restoration replaced completed receipt'
tasks show "$ORIGINAL" --full >/dev/null 2>&1 && fail 'completed archived slot was recreated'
export FM_SCHEDULE_NOW=14400
bash "$CHECK" check
[ "$(field key)" = freshness:interval:14400-21600 ] || fail 'new two-hour slot did not fire'
[ "$(jq '.jobs.freshness.completed_slots | length' "$FM_HOME/state/.schedule-occurrences.json")" -eq 0 ] || fail 'expired completed slots were retained'
pass 'cadence edits retain completed active slots and prune expired identities'

world interval-window-edit
config interval
jq '.schedules[0].cadence.seconds=3600' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
export FM_SCHEDULE_NOW=5400
bash "$CHECK" check
[ "$(field key)" = freshness:interval:3600-7200 ] || fail 'one-hour fixture entered wrong window'
receipt dispatched
receipt completed
jq '.schedules[0].cadence.seconds=7200' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
export FM_SCHEDULE_NOW=7200
bash "$CHECK" check
[ "$(field key)" = freshness:interval:7200-14400 ] || fail 'two-hour edit reused earlier slot identity'
[ "$(queue_count)" -eq 2 ] || fail 'two-hour edit suppressed its distinct time window'
pass 'interval identity follows the UTC window across cadence edits'

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

world timezone-edit
config
export FM_SCHEDULE_NOW=1791943200 # 2026-10-13 22:00 Toronto, 2026-10-14 11:00 Tokyo
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-10-13 ] || fail 'Toronto fixture did not enter its expected date'
ORIGINAL=$(field task_id)
receipt dispatched
receipt completed
tasks prune --keep 0 >/dev/null
jq '.schedules[0].cadence.timezone="Asia/Tokyo"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-10-14 ] || fail 'timezone edit did not create Tokyo date'
receipt dispatched
receipt completed
tasks prune --keep 0 >/dev/null
jq '.schedules[0].cadence.timezone="America/Toronto"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'timezone restoration recreated completed local date'
[ "$(field key)" = freshness:daily:2026-10-14 ] || fail 'timezone restoration replaced completed receipt'
tasks show "$ORIGINAL" --full >/dev/null 2>&1 && fail 'completed archived local date was recreated'
pass 'timezone edits retain completed local-date identity while its slot is active'

world timezone-late-date
config
jq '.schedules[0].cadence.timezone="Asia/Tokyo"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
export FM_SCHEDULE_NOW=1791943200
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-10-14 ] || fail 'Tokyo fixture entered wrong date'
receipt dispatched
receipt completed
jq '.schedules[0].cadence.timezone="America/Los_Angeles"' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/edited.json"
mv "$FM_HOME/config/edited.json" "$FM_HOME/config/schedules.json"
bash "$CHECK" check
[ "$(field key)" = freshness:daily:2026-10-13 ] || fail 'Los Angeles fixture entered wrong date'
receipt dispatched
receipt completed
export FM_SCHEDULE_NOW=1791993600
: > "$FM_HOME/state/.wake-queue"
bash "$CHECK" check
[ "$(queue_count)" -eq 0 ] || fail 'Tokyo date was republished after Tokyo midnight'
[ "$(field key)" = freshness:daily:2026-10-13 ] || fail 'completed Tokyo date lost its receipt'
pass 'completed local date survives until it ends in every possible zone'

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

world typed-missing
config
cat > "$FM_HOME/config/task-types.json" <<'JSON'
{"types":[{"name":"observe","use":"Inspect freshness","hand_back":"A report","touch":"Evidence only","projects":["firstmate"]}]}
JSON
jq '.schedules[0] |= (del(.brief) + {task_type:"missing"})' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/typed.json"
mv "$FM_HOME/config/typed.json" "$FM_HOME/config/schedules.json"
OUT=$(bash "$CHECK" check 2>&1) && fail 'unknown task type was accepted'
assert_contains "$OUT" "unknown task type 'missing'" 'unknown task type lacked exact diagnostic'
[ "$(queue_count)" -eq 0 ] || fail 'unknown task type published work'

world typed-project
config
cat > "$FM_HOME/config/task-types.json" <<'JSON'
{"types":[{"name":"observe","use":"Inspect freshness","hand_back":"A report","touch":"Evidence only","projects":["other"]}]}
JSON
jq '.schedules[0] |= (del(.brief) + {task_type:"observe"})' "$FM_HOME/config/schedules.json" > "$FM_HOME/config/typed.json"
mv "$FM_HOME/config/typed.json" "$FM_HOME/config/schedules.json"
OUT=$(bash "$CHECK" check 2>&1) && fail 'excluded project task type was accepted'
assert_contains "$OUT" "task type 'observe' does not apply to project 'firstmate'" 'excluded project lacked exact diagnostic'
[ "$(queue_count)" -eq 0 ] || fail 'excluded project published work'
pass 'task-type renderer failures name the rejected type and project'

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
