#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-name-lib.sh: the names a home's short form
# (config/mate-short-name) selects for new work. Unset keeps today's fm- names
# exactly; a valid short form yields <short>-crew-<id> worker labels, plain
# second-mate labels, and a <short>/crew/ branch prefix; anything else refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-crew-name-lib.sh
. "$ROOT/bin/fm-crew-name-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-name-lib)

test_unset_keeps_todays_names() {
  local config="$TMP_ROOT/unset/config" out
  mkdir -p "$config"
  out=$(fm_crew_short_name "$config") || fail "a missing short form refused"
  assert_equals "" "$out" "a missing short form produced a name"
  assert_equals "fm/" "$(fm_crew_default_branch_prefix "$config")" "a missing short form changed the branch prefix"
  assert_equals "" "$(fm_crew_window_label "$config" ship email-waterfall-order)" "a missing short form produced a worker label"
  assert_equals "" "$(fm_crew_window_label "$config" secondmate napoleon)" "a missing short form produced a second-mate label"
  : > "$config/mate-short-name"
  assert_equals "fm/" "$(fm_crew_default_branch_prefix "$config")" "an empty declaration changed the branch prefix"
  assert_equals "" "$(fm_crew_window_label "$config" scout probe)" "an empty declaration produced a label"
  pass "crew names: an unset or empty short form keeps fm- labels and the fm/ branch prefix"
}

test_short_form_names_new_work() {
  local config="$TMP_ROOT/set/config"
  mkdir -p "$config"
  printf 'nap\n' > "$config/mate-short-name"
  assert_equals "nap" "$(fm_crew_short_name "$config")" "the short form was not read"
  assert_equals "nap/crew/" "$(fm_crew_default_branch_prefix "$config")" "the branch prefix did not name the crew"
  assert_equals "nap-crew-email-waterfall-order" "$(fm_crew_window_label "$config" ship email-waterfall-order)" \
    "a ship's label did not read short form, crew, job"
  assert_equals "nap-crew-probe" "$(fm_crew_window_label "$config" scout probe)" "a scout's label did not read as crew"
  assert_equals "legion" "$(fm_crew_window_label "$config" secondmate legion)" "a second mate's label was not its plain name"
  printf 'alexander-media' > "$config/mate-short-name"
  assert_equals "alexander-media/crew/" "$(fm_crew_default_branch_prefix "$config")" \
    "a dashed short form without a trailing newline was not read"
  pass "crew names: a short form names new workers, scouts, second mates, and the branch prefix"
}

test_malformed_short_form_refuses() {
  local config="$TMP_ROOT/bad/config" value out status
  mkdir -p "$config"
  for value in Nap 'na p' ' nap' 'nap ' '#nap' -nap nap- 'nap/x' abcdefghijklmnopq; do
    printf '%s\n' "$value" > "$config/mate-short-name"
    out=$(fm_crew_default_branch_prefix "$config" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed short form '$value' was accepted as '$out'"
    assert_contains "$out" "holds '$value'" "the refusal of '$value' did not name it"
    fm_crew_window_label "$config" ship x >/dev/null 2>&1 && fail "malformed short form '$value' produced a label"
  done
  printf 'nap\nleg\n' > "$config/mate-short-name"
  out=$(fm_crew_short_name "$config" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "two short forms were accepted"
  assert_contains "$out" "one short form on one line" "the refusal did not name the duplicate declaration"
  printf 'nap\n\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a trailing blank line was accepted"
  printf '# Napoleon\nnap\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a comment line was accepted"
  printf '\nnap\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a leading blank line was accepted"
  rm -f "$config/mate-short-name"
  mkdir "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a directory was read as a short form"
  pass "crew names: a malformed short form refuses instead of guessing a name"
}

test_unset_keeps_todays_names
test_short_form_names_new_work
test_malformed_short_form_refuses
echo "# all fm-crew-name-lib tests passed"
