#!/usr/bin/env bash
# Backlog, snapshot, and ledger payloads must reach jq through files.
# A value over the kernel's single-argument limit used to make every idle
# check fail before it could read the backlog.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null || { echo 'skip: jq required'; exit 0; }
command -v python3 >/dev/null || { echo 'skip: python3 required'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-argv-payload)
PAYDIR="$TMP_ROOT/argv-tmp"
mkdir -p "$PAYDIR"
export TMPDIR="$PAYDIR"
TOOLBIN="$TMP_ROOT/bin"
cp -a "$ROOT/bin" "$TOOLBIN"
cat > "$TOOLBIN/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SPAWN_LOG:?}"
exit 0
SH
chmod +x "$TOOLBIN/fm-spawn.sh"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then
  printf '1760745600\n'
else
  exec /usr/bin/date "$@"
fi
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":6,"providers":[{"provider":"codex","accountKey":"codex-home","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}}]}'
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = user ]; then
  printf '%s\n' 'api_response:' '  body: "fixture-user"' '  truncated: false'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/date" "$FAKEBIN/quota-axi" "$FAKEBIN/gh-axi"
export PATH="$FAKEBIN:$PATH"
export FM_SNAPSHOT_NOW=2026-10-18T00:00:00Z FM_SNAPSHOT_NOW_EPOCH=1760745600
GOLDEN="$ROOT/tests"

write_small_backlog() {  # <home>
  cat > "$1/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] small - Small fixture (repo: example)
  One line of body.

## Done
EOF
}

prepare_home() {  # <home>
  mkdir -p "$1/data" "$1/state" "$1/config" "$1/projects"
}

assert_no_payload_leftovers() {
  local leftovers
  leftovers=$(find "$PAYDIR" -maxdepth 1 -type d \( \
    -name 'fm-targets-observe.*' -o -name 'fm-targets-collect.*' \
    -o -name 'fm-idle-sweep.*' -o -name 'fm-fleet-snapshot.*' \) -print)
  [ -z "$leftovers" ] || fail "payload temp dirs were left behind: $leftovers"
}

# --- oversized observed ledger, small backlog (targets observe) ---
ledger_home="$TMP_ROOT/ledger-home"
prepare_home "$ledger_home"
write_small_backlog "$ledger_home"
python3 - "$ledger_home/state/idle-sweep-backlog.json" <<'PY'
import json, sys
json.dump({"small": {"content": "x" * 220000, "changed": 1}}, open(sys.argv[1], "w"))
PY
[ "$(wc -c < "$ledger_home/state/idle-sweep-backlog.json")" -gt 204800 ] \
  || fail "seed ledger did not exceed 200 KiB"
export FM_HOME="$ledger_home" FM_ROOT_OVERRIDE="$ledger_home" TEST_SPAWN_LOG="$TMP_ROOT/ledger-spawns"
: > "$TEST_SPAWN_LOG"
if ! bash "$TOOLBIN/fm-idle-sweep.sh" >"$TMP_ROOT/ledger-sweep.out" 2>"$TMP_ROOT/ledger-sweep.err"; then
  fail "oversized ledger idle check failed: $(cat "$TMP_ROOT/ledger-sweep.err")"
fi
if grep -q 'Argument list too long' "$TMP_ROOT/ledger-sweep.err"; then
  fail "oversized ledger still hit the argument limit: $(cat "$TMP_ROOT/ledger-sweep.err")"
fi
cmp -s "$ledger_home/state/idle-sweep-backlog.json" "$GOLDEN/fm-argv-payload.ledger.golden.json" \
  || fail "oversized ledger was not rewritten to the small-input observation"
assert_no_payload_leftovers
pass "an observed ledger over 200 KiB still updates the idle observation"

# --- oversized backlog through snapshot, targets, and idle dispatch ---
fat_home="$TMP_ROOT/fat-home"
prepare_home "$fat_home"
mkdir -p "$fat_home/projects/example" "$fat_home/data/fat"
python3 - "$fat_home/data/backlog.md" <<'PY'
import sys
body = "\n".join("  " + ("y" * 80) for _ in range(3000))
open(sys.argv[1], "w").write(
    "## In flight\n\n## Queued\n\n- [ ] fat - Fat fixture (repo: example)\n%s\n\n## Done\n" % body
)
PY
[ "$(wc -c < "$fat_home/data/backlog.md")" -gt 204800 ] \
  || fail "fat backlog file did not exceed 200 KiB"
cat > "$fat_home/data/fat/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the fixture.
## Firstmate spec
Keep it reversible.
Delivery contract: mode=direct-PR
Ship branch: dev/crew/fat
Never merge, deploy, spend money, contact a client, answer a captain decision, or alter a captain-held item.
If the task needs one of those actions, report needs-decision to firstmate and stop.
EOF
export FM_HOME="$fat_home" FM_ROOT_OVERRIDE="$fat_home" TEST_SPAWN_LOG="$TMP_ROOT/fat-spawns"
: > "$TEST_SPAWN_LOG"
if ! bash "$TOOLBIN/fm-fleet-snapshot.sh" --contribution-input >"$TMP_ROOT/fat-contribution.json" 2>"$TMP_ROOT/fat-contribution.err"; then
  fail "fat contribution input failed: $(cat "$TMP_ROOT/fat-contribution.err")"
fi
if grep -q 'Argument list too long' "$TMP_ROOT/fat-contribution.err"; then
  fail "fat contribution input still hit the argument limit: $(cat "$TMP_ROOT/fat-contribution.err")"
fi
[ "$(wc -c < "$TMP_ROOT/fat-contribution.json")" -gt 204800 ] \
  || fail "fat contribution input was not over 200 KiB: $(wc -c < "$TMP_ROOT/fat-contribution.json") bytes"
jq -e '.tasks == [] and any(.backlog.records[]; .id == "fat" and (.body_lines | length) == 3000)' \
  "$TMP_ROOT/fat-contribution.json" >/dev/null \
  || fail "fat contribution input did not keep the backlog record"
if ! bash "$TOOLBIN/fm-targets.sh" --json >"$TMP_ROOT/fat-targets.json" 2>"$TMP_ROOT/fat-targets.err"; then
  fail "fat target read failed: $(cat "$TMP_ROOT/fat-targets.err")"
fi
if grep -q 'Argument list too long' "$TMP_ROOT/fat-targets.err"; then
  fail "fat target read still hit the argument limit: $(cat "$TMP_ROOT/fat-targets.err")"
fi
jq -e '.schema == "fm-targets.v1" and .stale_ids == []' "$TMP_ROOT/fat-targets.json" >/dev/null \
  || fail "fat target read did not return a fresh fm-targets document"
if ! bash "$TOOLBIN/fm-idle-sweep.sh" >"$TMP_ROOT/fat-sweep.out" 2>"$TMP_ROOT/fat-sweep.err"; then
  fail "fat idle check failed: $(cat "$TMP_ROOT/fat-sweep.err")"
fi
if grep -q 'Argument list too long' "$TMP_ROOT/fat-sweep.err"; then
  fail "fat idle check still hit the argument limit: $(cat "$TMP_ROOT/fat-sweep.err")"
fi
[ "$(cat "$TEST_SPAWN_LOG")" = "fat $fat_home/projects/example --mode direct-PR --yolo off --branch-prefix dev/crew/ --harness codex --model gpt-6.1-sol" ] \
  || fail "fat idle check did not dispatch the prepared task: $(cat "$TEST_SPAWN_LOG")"
jq -e '.fat.content | length > 200000' "$fat_home/state/idle-sweep-backlog.json" >/dev/null \
  || fail "fat observation did not record the backlog body"
grep -Fxq 'working [at=1760745600]: idle sweep started fat' "$fat_home/state/idle-sweep.status" \
  || fail "fat idle check did not record the start"
assert_no_payload_leftovers
pass "a backlog over 200 KiB still snapshots, scores targets, and dispatches"

# --- small inputs stay byte-identical ---
small_home="$TMP_ROOT/small-home"
prepare_home "$small_home"
write_small_backlog "$small_home"
export FM_HOME="$small_home" FM_ROOT_OVERRIDE="$small_home" TEST_SPAWN_LOG="$TMP_ROOT/small-spawns"
: > "$TEST_SPAWN_LOG"
bash "$TOOLBIN/fm-fleet-snapshot.sh" --contribution-input >"$TMP_ROOT/small-contribution.json"
# jq 1.8 does not keep object key order stable across processes, and the
# backlog record is one of those objects. Sort keys before the byte compare.
# The observation and target documents below are built with fixed key order,
# so those compares stay raw.
jq -S --arg path "$small_home/data/backlog.md" \
  'if .backlog.path == $path then .backlog.path = "BACKLOG_PATH" else error("backlog path drifted") end' \
  "$TMP_ROOT/small-contribution.json" >"$TMP_ROOT/small-contribution.norm.json"
cmp -s "$TMP_ROOT/small-contribution.norm.json" "$GOLDEN/fm-argv-payload.contribution.golden.json" \
  || fail "small contribution input bytes drifted"
bash "$TOOLBIN/fm-idle-sweep.sh" >"$TMP_ROOT/small-sweep.out" 2>"$TMP_ROOT/small-sweep.err"
cmp -s "$small_home/state/idle-sweep-backlog.json" "$GOLDEN/fm-argv-payload.ledger.golden.json" \
  || fail "small observation bytes drifted"
# No prepared project, so the sweep must not dispatch.
[ ! -s "$TEST_SPAWN_LOG" ] || fail "small idle check dispatched work"
bash "$TOOLBIN/fm-targets.sh" --json >"$TMP_ROOT/small-targets.json"
cmp -s "$TMP_ROOT/small-targets.json" "$GOLDEN/fm-argv-payload.targets.golden.json" \
  || fail "small target document bytes drifted"
assert_no_payload_leftovers
pass "small backlog, observation, and target documents stay byte-identical"

echo '# fm-argv-payload.test.sh: all assertions passed'
