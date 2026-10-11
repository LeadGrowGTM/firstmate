#!/usr/bin/env bash
# bin/fm-boat-spend-check.sh: the daily read-only Boat spend check.
#
# Every case runs the real script against a fake `boat` binary (selected with
# FM_BOAT_BIN) that serves fixture JSON and records every argument it receives,
# inside a temporary home, so neither the real Boat CLI nor a real home is ever
# reached. Field names are the ones Boat's `limits`, `list --all`, and
# `billing status` print.
#
# What these pin:
#   1. A healthy account is silent, and a stopped sandbox is never reported.
#   2. Each condition prints one line: spend over the ceiling, spend projected
#      over it, too many active sandboxes, a size off the allow list, a
#      sandbox with no auto-stop deadline off the always-on list, auto-refill
#      enabled, and a trial or plan end within 3 days.
#   3. A missing CLI, a timed-out call, malformed JSON, an unreadable
#      auto-refill field, and an invalid config are reported, not swallowed.
#   4. Only the three fixed read commands are ever passed, each with
#      --no-update, and no mutating verb is ever seen.
#   5. A home with no config is not checked and never calls Boat.
#   6. The daily gate holds, and arm and disarm bind and remove the shim.
# shellcheck disable=SC2016  # literal dollar amounts in expected report lines
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

CHECK="$ROOT/bin/fm-boat-spend-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-boat-spend-check)
NOW=1791727200 # 2026-10-11T14:00:00Z

# A Boat stand-in that answers the three read shapes from fixture files and
# logs one line per call. A first argument it does not know exits 97, so a
# stray mutating command is both recorded and visibly refused.
FAKE_BOAT="$TMP_ROOT/boat"
cat > "$FAKE_BOAT" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURES/calls.log"
[ ! -e "$FIXTURES/sleep" ] || sleep 5
case "$*" in
  "--no-update limits --json") f=limits ;;
  "--no-update list --all --json") f=list ;;
  "--no-update billing status --json") f=billing ;;
  *) exit 97 ;;
esac
cat "$FIXTURES/$f.json"
FAKE
chmod +x "$FAKE_BOAT"

# make_world <name> [config-json]: prints "<home>" with healthy fixtures.
make_world() {
  local name=$1 cfg=${2-'{}'} home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/config" "$home/state" "$home/fixtures"
  [ "$cfg" = none ] || printf '%s\n' "$cfg" > "$home/config/boat-spend.json"
  cat > "$home/fixtures/limits.json" <<'J'
{"activeStates":["provisioned","cloning","ready","idle","running"],"creditSecondsPerDollar":100000,"creditUsedSeconds":6124,"last24hUsageSeconds":4671,"subscriptionCurrentPeriodEnd":"2026-10-30T21:38:16.000Z","subscriptionTrialEndsAt":"2026-10-30T21:38:16.000Z"}
J
  cat > "$home/fixtures/list.json" <<'J'
{"pageInfo":{"hasMore":false,"limit":200,"nextCursor":null},"sandboxes":[{"id":"bx_one","state":"running","type":"default","archiveAfter":"2026-10-11T16:00:00.000Z"}]}
J
  cat > "$home/fixtures/billing.json" <<'J'
{"prepaid":{"balanceCents":0,"bufferSeconds":2500000,"cards":[],"enabled":false,"graceUntil":null}}
J
  printf '%s\n' "$home"
}

# set_json <home> <fixture> <jq-filter>
set_json() {
  local f="$1/fixtures/$2.json"
  jq -c "$3" "$f" > "$f.new" && mv "$f.new" "$f"
}

# run_check <home> [env...]: prints the check's stdout; stderr is merged.
run_check() {
  local home=$1
  shift
  env FM_HOME="$home" FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" \
    FM_BOAT_SPEND_NOW="$NOW" FM_BOAT_SPEND_INTERVAL=0 "$@" "$CHECK" check 2>&1
}

calls() { [ -f "$1/fixtures/calls.log" ] && cat "$1/fixtures/calls.log" || true; }

test_healthy_account_is_silent_and_only_reads() {
  local home out
  home=$(make_world healthy)
  out=$(run_check "$home") || fail "healthy check exited non-zero: $out"
  [ -z "$out" ] || fail "healthy account should be silent: $out"
  assert_equals 3 "$(calls "$home" | wc -l | tr -d ' ')" "healthy check should make exactly three Boat calls"
}

test_stopped_sandbox_is_never_reported() {
  local home out
  home=$(make_world stopped)
  set_json "$home" list '.sandboxes += [{"id":"bx_old","state":"stopped","type":"xlarge","archiveAfter":null}]'
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a stopped sandbox costs nothing and should be silent: $out"
}

test_spend_over_ceiling() {
  local home out
  home=$(make_world over)
  set_json "$home" limits '.creditUsedSeconds = 3500000'
  out=$(run_check "$home")
  assert_equals 'boat-spend: spend $35 is over the $30 ceiling' "$out" "over-ceiling line"
}

test_spend_projected_over_ceiling() {
  local home out
  home=$(make_world projected)
  # $20 spent, $10 a day, 19 days left in the period: far over $30.
  set_json "$home" limits '.creditUsedSeconds = 2000000 | .last24hUsageSeconds = 1000000'
  out=$(run_check "$home")
  assert_contains "$out" 'spend $20 projects to $' "projection line"
  assert_contains "$out" 'by period end, over the $30 ceiling' "projection line"
}

test_configured_ceiling_is_used() {
  local home out
  home=$(make_world ceiling '{"ceiling_usd": 5}')
  set_json "$home" limits '.creditUsedSeconds = 600000'
  out=$(run_check "$home")
  assert_equals 'boat-spend: spend $6 is over the $5 ceiling' "$out" "configured ceiling line"
}

test_more_active_than_expected() {
  local home out
  home=$(make_world count)
  set_json "$home" list '.sandboxes += [{"id":"bx_two","state":"running","type":"default","archiveAfter":"2026-10-11T16:00:00.000Z"}]'
  out=$(run_check "$home")
  assert_equals 'boat-spend: 2 sandboxes active, expected 1 (bx_one,bx_two)' "$out" "count line"
}

test_size_off_allow_list() {
  local home out
  home=$(make_world size)
  set_json "$home" list '.sandboxes[0].type = "large"'
  out=$(run_check "$home")
  assert_equals 'boat-spend: sandbox bx_one is size large, not on the allow list (small,default)' "$out" "size line"
}

test_no_auto_stop_unless_always_on() {
  local home out
  home=$(make_world nostop)
  set_json "$home" list '.sandboxes[0].archiveAfter = null'
  out=$(run_check "$home")
  assert_equals 'boat-spend: sandbox bx_one has no auto-stop deadline and is not on the always-on list' "$out" "no-stop line"
  home=$(make_world alwayson '{"always_on": ["bx_one"]}')
  set_json "$home" list '.sandboxes[0].archiveAfter = null'
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an always-on sandbox with no deadline should be silent: $out"
}

test_auto_refill_enabled_and_unreadable() {
  local home out
  home=$(make_world refill)
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(run_check "$home")
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "auto-refill line"
  set_json "$home" billing 'del(.prepaid.enabled)'
  out=$(run_check "$home")
  assert_equals 'boat-spend: auto-refill state unreadable' "$out" "unreadable auto-refill line"
}

test_trial_or_plan_end_within_three_days() {
  local home out
  home=$(make_world period)
  set_json "$home" limits '.subscriptionTrialEndsAt = "2026-10-13T21:38:16.000Z" | .subscriptionCurrentPeriodEnd = "2026-10-13T21:38:16.000Z"'
  out=$(run_check "$home")
  assert_equals 'boat-spend: trial or plan ends 2026-10-13 UTC, within 3 days' "$out" "period line"
  set_json "$home" limits '.subscriptionTrialEndsAt = "2026-10-15T21:38:16.000Z" | .subscriptionCurrentPeriodEnd = "2026-10-15T21:38:16.000Z"'
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an end more than 3 days away should be silent: $out"
}

test_findings_are_joined_on_one_line() {
  local home out
  home=$(make_world joined)
  set_json "$home" billing '.prepaid.enabled = true'
  set_json "$home" list '.sandboxes[0].type = "large"'
  out=$(run_check "$home")
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "several findings should still be one line"
  assert_contains "$out" 'is size large' "joined line lost the size finding"
  assert_contains "$out" 'auto-refill is enabled' "joined line lost the auto-refill finding"
}

test_missing_cli_is_reported() {
  local home out
  home=$(make_world missing)
  out=$(env FM_HOME="$home" FM_BOAT_BIN="$TMP_ROOT/no-such-boat" FM_BOAT_SPEND_NOW="$NOW" \
    FM_BOAT_SPEND_INTERVAL=0 "$CHECK" check 2>&1)
  assert_equals 'boat-spend: read failed: the Boat CLI is missing' "$out" "missing CLI line"
}

test_malformed_json_is_reported() {
  local home out
  home=$(make_world malformed)
  printf 'not json{' > "$home/fixtures/limits.json"
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: boat limits did not return readable JSON' "$out" "malformed JSON line"
  home=$(make_world malformed2)
  printf '[1,2]' > "$home/fixtures/list.json"
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: boat list did not return readable JSON' "$out" "non-object JSON line"
}

test_timed_out_call_is_reported() {
  local home out
  home=$(make_world timeout)
  : > "$home/fixtures/sleep"
  out=$(run_check "$home" FM_BOAT_SPEND_PROBE_SECS=1)
  assert_equals 'boat-spend: read failed: boat limits timed out' "$out" "timeout line"
}

test_invalid_config_is_reported() {
  local home out
  home=$(make_world badcfg '{"ceiling": 30}')
  out=$(run_check "$home")
  assert_contains "$out" 'boat-spend: config/boat-spend.json is invalid: unknown key "ceiling"' "unknown key line"
  assert_equals 0 "$(calls "$home" | wc -l | tr -d ' ')" "an invalid config must not reach Boat"
  home=$(make_world badcfg2 '{"allowed_sizes": "small"}')
  out=$(run_check "$home")
  assert_contains "$out" 'allowed_sizes must be a list of size names' "type error line"
}

test_absent_config_is_off() {
  local home out
  home=$(make_world nocfg none)
  out=$(run_check "$home")
  [ -z "$out" ] || fail "a home with no config should be silent: $out"
  assert_equals 0 "$(calls "$home" | wc -l | tr -d ' ')" "an unconfigured home must not call Boat"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) && fail "arm without a config should refuse"
  assert_contains "$out" 'no Boat spend config' "arm refusal text"
}

test_only_the_three_read_commands_are_passed() {
  local home line seen=0
  home=$(make_world argv)
  set_json "$home" billing '.prepaid.enabled = true'
  set_json "$home" list '.sandboxes[0].archiveAfter = null | .sandboxes[0].type = "xlarge"'
  run_check "$home" >/dev/null
  while IFS= read -r line; do
    seen=$((seen + 1))
    case "$line" in
      "--no-update limits --json"|"--no-update list --all --json"|"--no-update billing status --json") : ;;
      *) fail "unexpected Boat arguments: $line" ;;
    esac
  done < <(calls "$home")
  assert_equals 3 "$seen" "every alert path should still make only the three reads"
}

test_daily_gate_and_persistent_condition() {
  local home out
  home=$(make_world gate)
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(env FM_HOME="$home" FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" FM_BOAT_SPEND_NOW="$NOW" "$CHECK" check 2>&1)
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "first due evaluation"
  out=$(env FM_HOME="$home" FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" FM_BOAT_SPEND_NOW=$((NOW + 600)) "$CHECK" check 2>&1)
  [ -z "$out" ] || fail "a poll inside the daily gate should be silent: $out"
  assert_equals 3 "$(calls "$home" | wc -l | tr -d ' ')" "a gated poll must not call Boat"
  out=$(env FM_HOME="$home" FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" FM_BOAT_SPEND_NOW=$((NOW + 86400)) "$CHECK" check 2>&1)
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "a persisting condition is reported again at the next due evaluation"
}

test_arm_runs_through_the_registered_shim_and_disarm_removes_it() {
  local home out
  home=$(make_world arm)
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/boat-spend.check.sh' "arm output"
  assert_present "$home/state/boat-spend.check.sh" "arm did not write the shim"
  assert_present "$home/state/boat-spend.check-trust" "arm did not bind the shim"
  out=$(env -u FM_HOME FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" FM_BOAT_SPEND_NOW="$NOW" "$home/state/boat-spend.check.sh" 2>&1) \
    || fail "registered shim failed: $out"
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "shim did not run the check in the pinned home"
  env FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/boat-spend.check.sh" "disarm left the shim"
  assert_absent "$home/state/boat-spend.check-trust" "disarm left the trust binding"
  assert_absent "$home/state/.boat-spend-check" "disarm left the record"
}

test_healthy_account_is_silent_and_only_reads
test_stopped_sandbox_is_never_reported
test_spend_over_ceiling
test_spend_projected_over_ceiling
test_configured_ceiling_is_used
test_more_active_than_expected
test_size_off_allow_list
test_no_auto_stop_unless_always_on
test_auto_refill_enabled_and_unreadable
test_trial_or_plan_end_within_three_days
test_findings_are_joined_on_one_line
test_missing_cli_is_reported
test_malformed_json_is_reported
test_timed_out_call_is_reported
test_invalid_config_is_reported
test_absent_config_is_off
test_only_the_three_read_commands_are_passed
test_daily_gate_and_persistent_condition
test_arm_runs_through_the_registered_shim_and_disarm_removes_it
pass "fm-boat-spend-check"
