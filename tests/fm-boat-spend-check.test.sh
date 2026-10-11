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
#   3. A missing CLI, a call the bound reports as timed out, malformed JSON, a
#      missing or unreadable field, an incomplete sandbox list, and an invalid
#      config are reported, not swallowed, as one read-failure part of the line.
#   4. Only the three fixed read commands are ever passed, each with
#      --no-update, and no mutating verb is ever seen.
#   5. A home with no config is not checked and never calls Boat.
#   6. The daily gate holds, a failed read does not use it up and is reported
#      once a day, and arm and disarm bind and remove the shim.
#   7. "boat_bin" selects the CLI only as an absolute path to an executable
#      file, and FM_BOAT_BIN wins over it.
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
# stray mutating command is both recorded and visibly refused. With a
# fixtures/timeout file it exits 124, the status the bounded runner reports
# when its bound is hit, so the timeout path runs without waiting out the bound.
FAKE_BOAT="$TMP_ROOT/boat"
cat > "$FAKE_BOAT" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURES/calls.log"
[ ! -e "$FIXTURES/timeout" ] || exit 124
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

# run_check <home> [env...]: prints the check's stdout; stderr is merged. A
# later FM_BOAT_SPEND_NOW moves the clock for a second run in the same home.
run_check() {
  local home=$1
  shift
  env FM_HOME="$home" FM_BOAT_BIN="$FAKE_BOAT" FIXTURES="$home/fixtures" \
    FM_BOAT_SPEND_NOW="$NOW" "$@" "$CHECK" check 2>&1
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

test_auto_refill_enabled() {
  local home out
  home=$(make_world refill)
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(run_check "$home")
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "auto-refill line"
}

test_trial_or_plan_end_within_three_days() {
  local home out
  home=$(make_world period)
  set_json "$home" limits '.subscriptionTrialEndsAt = "2026-10-13T21:38:16.000Z" | .subscriptionCurrentPeriodEnd = "2026-10-13T21:38:16.000Z"'
  out=$(run_check "$home")
  assert_equals 'boat-spend: trial or plan ends 2026-10-13 UTC, within 3 days' "$out" "period line"
  home=$(make_world period-far)
  set_json "$home" limits '.subscriptionTrialEndsAt = "2026-10-15T21:38:16.000Z" | .subscriptionCurrentPeriodEnd = "2026-10-15T21:38:16.000Z"'
  out=$(run_check "$home")
  [ -z "$out" ] || fail "an end more than 3 days away should be silent: $out"
}

# unreadable_case <name> <fixture> <jq-filter> <expected line>
unreadable_case() {
  local home out
  home=$(make_world "$1")
  set_json "$home" "$2" "$3"
  out=$(run_check "$home")
  assert_equals "$4" "$out" "$1 should be reported as unreadable"
}

test_unreadable_fields_are_reported() {
  unreadable_case no-refill billing 'del(.prepaid.enabled)' \
    'boat-spend: read failed: unreadable auto-refill state'
  unreadable_case no-spend limits 'del(.creditUsedSeconds)' \
    'boat-spend: read failed: unreadable spend'
  unreadable_case no-usage limits 'del(.last24hUsageSeconds)' \
    'boat-spend: read failed: unreadable last-24-hour usage'
  unreadable_case no-states limits 'del(.activeStates) | .creditUsedSeconds = 3500000' \
    'boat-spend: spend $35 is over the $30 ceiling; read failed: unreadable active states'
  unreadable_case null-states limits '.activeStates = null' \
    'boat-spend: read failed: unreadable active states'
  unreadable_case bad-states limits '.activeStates = "running"' \
    'boat-spend: read failed: unreadable active states'
  unreadable_case offset-plan-end limits '.subscriptionCurrentPeriodEnd = "2026-10-12T10:00:00+00:00"' \
    'boat-spend: read failed: unreadable plan end'
  unreadable_case epoch-trial-end limits '.subscriptionTrialEndsAt = 1791800000' \
    'boat-spend: read failed: unreadable trial end'
  unreadable_case no-sandboxes list '{pageInfo, boxes: [{"id":"bx_big","state":"running","type":"xlarge","archiveAfter":null}]}' \
    'boat-spend: read failed: unreadable sandbox list'
  unreadable_case no-state list '.sandboxes += [{"id":"bx_big","type":"xlarge","archiveAfter":null}]' \
    'boat-spend: read failed: unreadable a sandbox state'
  unreadable_case no-paging list 'del(.pageInfo)' \
    'boat-spend: read failed: unreadable sandbox list paging'
  unreadable_case more-pages list '.pageInfo.hasMore = true' \
    'boat-spend: read failed: unreadable sandbox list past its first page'
}

test_read_problems_are_consolidated_beside_real_findings() {
  local home out
  home=$(make_world consolidated)
  set_json "$home" limits 'del(.last24hUsageSeconds) | .creditUsedSeconds = 3500000'
  set_json "$home" list 'del(.pageInfo)'
  set_json "$home" billing 'del(.prepaid)'
  out=$(run_check "$home")
  assert_equals 'boat-spend: spend $35 is over the $30 ceiling; read failed: unreadable last-24-hour usage, sandbox list paging, auto-refill state' \
    "$out" "several read problems should be one part of the one line"
}

test_transient_read_failure_does_not_use_up_the_day() {
  local home out
  home=$(make_world transient)
  set_json "$home" billing '.prepaid.enabled = true'
  : > "$home/fixtures/timeout"
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: boat limits timed out' "$out" "the failed read"
  rm -f "$home/fixtures/timeout"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 300)))
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "the next poll after a failed read should evaluate and report normally"
  assert_absent "$home/state/.boat-spend-check-failed" "a successful read should clear the failure record"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 600)))
  [ -z "$out" ] || fail "a poll after the day's successful evaluation should be silent: $out"
  assert_equals 4 "$(calls "$home" | wc -l | tr -d ' ')" "one failed call, three successful reads, then a gated poll"
}

test_persistent_read_failure_reports_once_a_day() {
  local home out
  home=$(make_world persistent)
  printf 'not json{' > "$home/fixtures/limits.json"
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: boat limits did not return readable JSON' "$out" "the first failed read"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 300)))
  [ -z "$out" ] || fail "a repeated failure inside the day should be silent: $out"
  assert_equals 2 "$(calls "$home" | wc -l | tr -d ' ')" "a failed read should be retried at the next poll"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 86400)))
  assert_equals 'boat-spend: read failed: boat limits did not return readable JSON' "$out" "a failure that lasts is reported again a day later"
}

test_persistent_unreadable_field_reports_once_a_day() {
  local home out
  home=$(make_world persistent-field)
  set_json "$home" billing 'del(.prepaid.enabled)'
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: unreadable auto-refill state' "$out" "the first unreadable evaluation"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 300)))
  [ -z "$out" ] || fail "a repeated unreadable field inside the day should be silent: $out"
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 600)))
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "the field becoming readable should be evaluated the same day"
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
  out=$(run_check "$home" FM_BOAT_BIN="$TMP_ROOT/no-such-boat")
  assert_equals 'boat-spend: read failed: the Boat CLI is missing' "$out" "missing CLI line"
}

test_boat_bin_config_selects_the_cli() {
  local home out
  home=$(make_world bin-key "{\"boat_bin\": \"$FAKE_BOAT\"}")
  set_json "$home" billing '.prepaid.enabled = true'
  out=$(run_check "$home" FM_BOAT_BIN=)
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "boat_bin should select the CLI when FM_BOAT_BIN is unset"
  assert_equals 3 "$(calls "$home" | wc -l | tr -d ' ')" "boat_bin should make the three reads"
  home=$(make_world bin-env-wins "{\"boat_bin\": \"$FAKE_BOAT\"}")
  out=$(run_check "$home" FM_BOAT_BIN="$TMP_ROOT/no-such-boat")
  assert_equals 'boat-spend: read failed: the Boat CLI is missing' "$out" "FM_BOAT_BIN should win over boat_bin"
}

# bad_boat_bin_case <name> <boat_bin value> <expected problem>
bad_boat_bin_case() {
  local home out
  home=$(make_world "$1" "{\"boat_bin\": \"$2\"}")
  out=$(run_check "$home" FM_BOAT_BIN=)
  assert_equals "boat-spend: config/boat-spend.json is invalid: $3" "$out" "$1 should be one invalid-config line"
  assert_equals 0 "$(calls "$home" | wc -l | tr -d ' ')" "$1 must execute nothing"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 86400)))
  assert_equals "boat-spend: config/boat-spend.json is invalid: $3" "$out" "$1 should be refused even with FM_BOAT_BIN set"
  assert_equals 0 "$(calls "$home" | wc -l | tr -d ' ')" "$1 must execute nothing with FM_BOAT_BIN set"
}

test_boat_bin_config_must_be_an_absolute_executable_file() {
  local plain="$TMP_ROOT/not-executable-boat"
  cp "$FAKE_BOAT" "$plain"
  chmod 0644 "$plain"
  bad_boat_bin_case bin-relative 'boat' 'boat_bin must be an absolute path'
  bad_boat_bin_case bin-missing "$TMP_ROOT/no-such-boat" 'boat_bin must be an existing executable file'
  bad_boat_bin_case bin-not-executable "$plain" 'boat_bin must be an existing executable file'
  bad_boat_bin_case bin-directory "$TMP_ROOT" 'boat_bin must be an existing executable file'
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
  : > "$home/fixtures/timeout"
  out=$(run_check "$home")
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

# not_one_object_case <name> <config bytes>
not_one_object_case() {
  local home out
  home=$(make_world "$1" "$2")
  out=$(run_check "$home")
  assert_equals 'boat-spend: config/boat-spend.json is invalid: must be one JSON object' "$out" "$1 should be an invalid config"
  assert_equals 0 "$(calls "$home" | wc -l | tr -d ' ')" "$1 must not reach Boat"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1) && fail "arm should refuse $1"
  assert_contains "$out" 'must be one JSON object' "arm refusal text for $1"
  assert_absent "$home/state/boat-spend.check.sh" "a refused arm for $1 left a shim"
}

test_config_must_be_exactly_one_json_object() {
  not_one_object_case cfg-empty ''
  not_one_object_case cfg-blank '   '
  not_one_object_case cfg-two '{} {"ceiling_usd": 1}'
  not_one_object_case cfg-list '[]'
}

test_missing_active_states_is_not_guessed() {
  local home out
  home=$(make_world guessed-states)
  set_json "$home" limits 'del(.activeStates)'
  set_json "$home" list '.sandboxes += [{"id":"bx_big","state":"running","type":"xlarge","archiveAfter":null}]'
  out=$(run_check "$home")
  assert_equals 'boat-spend: read failed: unreadable active states' "$out" \
    "with no activeStates the count, size and no-stop conditions should not be evaluated on a guessed list"
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
  out=$(run_check "$home")
  assert_equals 'boat-spend: auto-refill is enabled' "$out" "first due evaluation"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 600)))
  [ -z "$out" ] || fail "a poll inside the daily gate should be silent: $out"
  assert_equals 3 "$(calls "$home" | wc -l | tr -d ' ')" "a gated poll must not call Boat"
  out=$(run_check "$home" FM_BOAT_SPEND_NOW=$((NOW + 86400)))
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
  home=$(make_world disarm-failed)
  : > "$home/fixtures/timeout"
  run_check "$home" >/dev/null
  assert_present "$home/state/.boat-spend-check-failed" "a reported failed read should leave its record"
  env FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/.boat-spend-check-failed" "disarm left the failure record"
}

test_healthy_account_is_silent_and_only_reads
test_stopped_sandbox_is_never_reported
test_spend_over_ceiling
test_spend_projected_over_ceiling
test_configured_ceiling_is_used
test_more_active_than_expected
test_size_off_allow_list
test_no_auto_stop_unless_always_on
test_auto_refill_enabled
test_trial_or_plan_end_within_three_days
test_unreadable_fields_are_reported
test_read_problems_are_consolidated_beside_real_findings
test_transient_read_failure_does_not_use_up_the_day
test_persistent_read_failure_reports_once_a_day
test_persistent_unreadable_field_reports_once_a_day
test_findings_are_joined_on_one_line
test_missing_cli_is_reported
test_boat_bin_config_selects_the_cli
test_boat_bin_config_must_be_an_absolute_executable_file
test_malformed_json_is_reported
test_timed_out_call_is_reported
test_invalid_config_is_reported
test_config_must_be_exactly_one_json_object
test_missing_active_states_is_not_guessed
test_absent_config_is_off
test_only_the_three_read_commands_are_passed
test_daily_gate_and_persistent_condition
test_arm_runs_through_the_registered_shim_and_disarm_removes_it
pass "fm-boat-spend-check"
