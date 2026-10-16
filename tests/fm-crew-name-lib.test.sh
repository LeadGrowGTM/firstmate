#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-name-lib.sh: the names a home's short form
# (config/mate-short-name) selects for new work. Unset keeps today's fm- names
# exactly; a valid short form yields <short>-crew-<id> worker labels, plain
# second-mate labels, and a <short>/crew/ branch prefix; anything else warns and
# falls back to today's names.
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
  assert_equals "" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" ship email-waterfall-order)" "a missing short form produced a worker label"
  assert_equals "" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" secondmate napoleon)" "a missing short form produced a second-mate label"
  : > "$config/mate-short-name"
  assert_equals "fm/" "$(fm_crew_default_branch_prefix "$config")" "an empty declaration changed the branch prefix"
  assert_equals "" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" scout probe)" "an empty declaration produced a label"
  pass "crew names: an unset or empty short form keeps fm- labels and the fm/ branch prefix"
}

test_short_form_names_new_work() {
  local config="$TMP_ROOT/set/config"
  mkdir -p "$config"
  printf 'nap\n' > "$config/mate-short-name"
  assert_equals "nap" "$(fm_crew_short_name "$config")" "the short form was not read"
  assert_equals "nap/crew/" "$(fm_crew_default_branch_prefix "$config")" "the branch prefix did not name the crew"
  assert_equals "nap-crew-email-waterfall-order" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" ship email-waterfall-order)" \
    "a ship's label did not read short form, crew, job"
  assert_equals "nap-crew-probe" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" scout probe)" "a scout's label did not read as crew"
  assert_equals "legion" "$(fm_crew_label_for "$(fm_crew_usable_short_name "$config")" secondmate legion)" "a second mate's label was not its plain name"
  printf 'alexander-media' > "$config/mate-short-name"
  assert_equals "alexander-media/crew/" "$(fm_crew_default_branch_prefix "$config")" \
    "a dashed short form without a trailing newline was not read"
  pass "crew names: a short form names new workers, scouts, second mates, and the branch prefix"
}

test_malformed_short_form_falls_back() {
  local config="$TMP_ROOT/bad/config" value out status
  mkdir -p "$config"
  for value in Nap 'na p' ' nap' 'nap ' '#nap' -nap nap- 'nap/x' abcdefghijklmnopq; do
    printf '%s\n' "$value" > "$config/mate-short-name"
    out=$(fm_crew_short_name "$config" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed short form '$value' was accepted as '$out'"
    assert_contains "$out" "holds '$value'" "the strict read of '$value' did not name it"
    out=$(fm_crew_default_branch_prefix "$config" 2>"$TMP_ROOT/warn") || fail "malformed short form '$value' blocked the branch prefix"
    assert_equals "fm/" "$out" "malformed short form '$value' did not fall back to fm/"
    assert_contains "$(cat "$TMP_ROOT/warn")" "holds '$value'" "the fallback for '$value' did not warn"
    out=$(fm_crew_label_for "$(fm_crew_usable_short_name "$config" 2>/dev/null)" ship x) || fail "malformed short form '$value' blocked the label"
    assert_equals "" "$out" "malformed short form '$value' produced a label"
  done
  printf 'nap\nleg\n' > "$config/mate-short-name"
  out=$(fm_crew_short_name "$config" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "two short forms were accepted"
  assert_contains "$out" "one short form on one line" "the refusal did not name the duplicate declaration"
  assert_equals "fm/" "$(fm_crew_default_branch_prefix "$config" 2>/dev/null)" "two short forms did not fall back to fm/"
  printf 'nap\n\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a trailing blank line was accepted"
  printf '# Napoleon\nnap\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a comment line was accepted"
  printf '\nnap\n' > "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a leading blank line was accepted"
  rm -f "$config/mate-short-name"
  mkdir "$config/mate-short-name"
  fm_crew_short_name "$config" >/dev/null 2>&1 && fail "a directory was read as a short form"
  assert_equals "" "$(fm_crew_usable_short_name "$config" 2>/dev/null)" "a directory was used as a short form"
  pass "crew names: a malformed short form is never guessed; it warns and falls back to the fm- names"
}

test_unset_keeps_todays_names
test_short_form_names_new_work
test_malformed_short_form_falls_back
echo "# all fm-crew-name-lib tests passed"
