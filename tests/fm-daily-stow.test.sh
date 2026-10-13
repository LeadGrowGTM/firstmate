#!/usr/bin/env bash
# Daily stow guards and durable checkpoint delivery through real inbox/lock APIs.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DAILY="$ROOT/bin/fm-daily-stow.sh"
CASCADE="$ROOT/bin/fm-stow-cascade.sh"
TMP_ROOT=$(fm_test_tmproot fm-daily-stow)
mkdir -p "$TMP_ROOT"
holder_pid=
cleanup() {
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup EXIT
home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$home/config"
run_daily() {
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash "$DAILY" "$@"
}
count_wakes() {
  if [ -f "$home/state/.wake-queue" ]; then
    grep -c 'inbox:' "$home/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}
out=$(run_daily)
assert_contains "$out" 'no proven live main session' 'absent session skips'
assert_equals 0 "$(count_wakes)" 'absent session gets no wake'
printf '999999999\n' > "$home/state/.lock"
out=$(run_daily)
assert_contains "$out" 'no proven live main session' 'stale session skips'
printf '%s\n' "$$" > "$home/state/.lock"
out=$(run_daily)
assert_contains "$out" 'no proven live main session' 'non-harness lock cannot imply liveness'
pass 'missing, stale, and unrelated lock holders receive no instruction'

# Exercise the existing structural live-lock API with a real process, as in
# fm-inbox.test.sh; no vendor-dependent busy classifier is added here.
perl -e '$0="claude"; sleep 120' &
holder_pid=$!
sleep 0.2
printf '%s\n' "$holder_pid" > "$home/state/.lock"
out=$(run_daily)
assert_contains "$out" 'not proven healthy' 'live session without supervision skips'
touch "$home/state/.last-watcher-beat"
out=$(run_daily --eligible)
assert_contains "$out" 'eligible' 'first daily pass needs no prior stamp'
for posture in away quiet; do
  printf '%s\n' "$posture" > "$home/state/.afk"
  out=$(run_daily)
  assert_contains "$out" 'away or quiet mode' "$posture posture skips"
done
rm "$home/state/.afk"
touch "$home/state/.afk-contract"
out=$(run_daily)
assert_contains "$out" 'away or quiet mode' 'away contract skips'
rm "$home/state/.afk-contract"
touch "$home/.fm-secondmate-home"
out=$(run_daily)
assert_contains "$out" 'secondmate home' 'a per-home trigger refuses secondmates'
rm "$home/.fm-secondmate-home"
assert_equals 0 "$(count_wakes)" 'guarded cases write no wakes'
pass 'supervision, away, quiet, and main-only guards fail closed'

FM_HOME="$home" bash "$CASCADE" >/dev/null
[ ! -e "$home/state/.last-stow-primary-pass" ] || fail 'bare cascade must remain read-only'
FM_HOME="$home" bash "$CASCADE" --record-pass >/dev/null
out=$(run_daily)
assert_contains "$out" 'last 20 hours' 'a manual primary pass suppresses scheduled stow'
for stamp in invalid 999999999999999999999; do
  printf '%s\n' "$stamp" > "$home/state/.last-stow-primary-pass"
  out=$(run_daily)
  assert_contains "$out" 'skipped' 'invalid and future stamps fail closed'
done
printf '%s\n' "$(( $(date +%s) - 20 * 3600 - 5 ))" > "$home/state/.last-stow-primary-pass"
out=$(run_daily --eligible)
assert_contains "$out" 'eligible' 'a pass older than 20 hours permits stow'
assert_equals 0 "$(count_wakes)" 'eligibility recheck is read-only'
out=$(run_daily)
assert_contains "$out" 'queued' 'eligible primary receives a note'
assert_equals 1 "$(count_wakes)" 'one check wake queued'
kill -0 "$holder_pid" || fail 'delivery must leave the live session running'
notes=$(FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" list)
assert_contains "$notes" 'Scheduled daily stow' 'note goes to the selected live home'
out=$(run_daily)
assert_contains "$out" 'replay' 'same Toronto day retry replays note'
assert_equals 1 "$(count_wakes)" 'same-day retry cannot append another wake'
# The recipient recheck suppresses a request delayed past another manual pass.
FM_HOME="$home" bash "$CASCADE" --record-pass >/dev/null
rc=0
out=$(run_daily --eligible) || rc=$?
expect_code 3 "$rc" 'recipient can distinguish a deferred skip'
assert_contains "$out" 'last 20 hours' 'delayed note rechecks manual pass'
pass 'manual-pass stamp, 20-hour guard, idempotent wake, and delayed recheck work'

# Record-pass is primary-only and must not create secondmate bookkeeping.
sub="$TMP_ROOT/sub"
mkdir -p "$sub"
touch "$sub/.fm-secondmate-home"
FM_HOME="$sub" bash "$CASCADE" --record-pass >/dev/null
[ ! -e "$sub/state/.last-stow-primary-pass" ] || fail 'secondmate cannot record primary pass'
pass 'the existing cascade retains secondmate scope'

# Validate copyable units through systemd itself without installing/enabling.
if command -v systemd-analyze >/dev/null 2>&1; then
  python3 - "$ROOT" "$TMP_ROOT" <<'PY'
from pathlib import Path
import subprocess, sys
root, temporary = map(Path, sys.argv[1:])
units = temporary / 'units'
units.mkdir()
for name in ('fm-daily-stow.service', 'fm-daily-stow.timer'):
    template = (root / 'docs/examples/session-refresh' / name).read_text()
    template = template.replace('/path/to/main-firstmate-home', str(temporary / 'home'))
    template = template.replace('/path/to/firstmate', str(root))
    (units / name).write_text(template)
subprocess.run(['systemd-analyze', 'verify',
                str(units / 'fm-daily-stow.service'),
                str(units / 'fm-daily-stow.timer')], check=True)
PY
  pass 'configured companion units pass systemd verification without activation'
else
  echo '# systemd unit verification skipped: systemd-analyze is not installed'
fi
