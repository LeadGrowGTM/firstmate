#!/usr/bin/env bash
# docs/examples/boat-remote-host/fm-claude-auto-compact: the Boat recipe's
# setup step and readiness check for Claude Code's auto-compact window.
#
# Every case runs the real script against a temporary HOME, so no real Claude
# Code settings are ever read or written. The written file is read back as JSON
# rather than by matching its text.
#
# What these pin:
#   1. On an account with no settings the step creates the file holding only
#      the top-level key, and the check then passes.
#   2. On an account whose settings Claude Code already wrote, the step adds or
#      corrects that one key and leaves every other key, per-model entries
#      included, exactly as it found them.
#   3. A rerun is a no-op that leaves the file's bytes alone.
#   4. The check never writes: a missing file, a missing key, and another value
#      all fail it with nothing created or changed.
#   5. A file that is not a JSON object is refused and left untouched.
#   6. CLAUDE_CONFIG_DIR selects the settings directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

STEP="$ROOT/docs/examples/boat-remote-host/fm-claude-auto-compact"
TMP_ROOT=$(fm_test_tmproot fm-boat-claude-auto-compact)

run_step() { # <home> [args...]; sets OUT and RC
  local home=$1
  shift
  OUT=$(env -u CLAUDE_CONFIG_DIR HOME="$home" "$STEP" "$@" 2>&1) && RC=0 || RC=$?
}

# --- 1. no settings yet ------------------------------------------------------
home="$TMP_ROOT/fresh"
mkdir -p "$home"
run_step "$home" --check
expect_code 1 "$RC" "the check on an account with no settings"
assert_contains "$OUT" 'missing: autoCompactWindow=300000' "the check must name the missing key"
assert_absent "$home/.claude" "the check must not create the settings directory"
run_step "$home"
expect_code 0 "$RC" "the step on an account with no settings: $OUT"
assert_contains "$OUT" "ok: autoCompactWindow=300000 in $home/.claude/settings.json" \
  "the step must report the key and the file it is in"
[ "$(jq -c . "$home/.claude/settings.json")" = '{"autoCompactWindow":300000}' ] \
  || fail "a created settings file must hold only the one key: $(cat "$home/.claude/settings.json")"
run_step "$home" --check
expect_code 0 "$RC" "the check after the step: $OUT"
pass "no settings: the step creates the file with only the top-level key and the check then passes"

# --- 2. settings Claude Code already wrote -----------------------------------
home="$TMP_ROOT/used"
mkdir -p "$home/.claude"
cat > "$home/.claude/settings.json" <<'JSON'
{
  "theme": "dark",
  "skipDangerousModePermissionPrompt": true,
  "autoCompactWindow": 200000,
  "modelSettings": {"claude-opus-5-5": {"autoCompactWindow": 500000}},
  "permissions": {"allow": ["Bash(ls:*)"], "deny": []}
}
JSON
before=$(jq -cS 'del(.autoCompactWindow)' "$home/.claude/settings.json")
run_step "$home" --check
expect_code 1 "$RC" "the check on another value"
[ "$(jq -r .autoCompactWindow "$home/.claude/settings.json")" = 200000 ] \
  || fail "the check must not change the value it found"
run_step "$home"
expect_code 0 "$RC" "the step on existing settings: $OUT"
[ "$(jq -r .autoCompactWindow "$home/.claude/settings.json")" = 300000 ] \
  || fail "the step must set the top-level key: $(cat "$home/.claude/settings.json")"
[ "$(jq -cS 'del(.autoCompactWindow)' "$home/.claude/settings.json")" = "$before" ] \
  || fail "the step must leave every other key as it found it: $(cat "$home/.claude/settings.json")"
[ -z "$(find "$home/.claude" -mindepth 1 ! -name settings.json)" ] \
  || fail "the step must leave nothing but the settings file behind: $(ls -A "$home/.claude")"
pass "existing settings: the step corrects the one key and leaves every other key alone"

# --- 3. a rerun changes nothing ----------------------------------------------
sum_before=$(cksum < "$home/.claude/settings.json")
touch -t 200101010000.00 "$home/.claude/settings.json"
stamp_before=$(stat -c %Y "$home/.claude/settings.json" 2>/dev/null || stat -f %m "$home/.claude/settings.json")
run_step "$home"
expect_code 0 "$RC" "a rerun of the step: $OUT"
[ "$(cksum < "$home/.claude/settings.json")" = "$sum_before" ] || fail "a rerun must not change the file"
stamp_after=$(stat -c %Y "$home/.claude/settings.json" 2>/dev/null || stat -f %m "$home/.claude/settings.json")
[ "$stamp_after" = "$stamp_before" ] || fail "a rerun must not rewrite a file that already holds the value"
pass "rerun: a file that already holds the value is not rewritten"

# --- 4. a missing key fails the check ----------------------------------------
home="$TMP_ROOT/nokey"
mkdir -p "$home/.claude"
printf '{"theme":"dark"}\n' > "$home/.claude/settings.json"
sum_before=$(cksum < "$home/.claude/settings.json")
run_step "$home" --check
expect_code 1 "$RC" "the check on settings without the key"
[ "$(cksum < "$home/.claude/settings.json")" = "$sum_before" ] || fail "the check must not write the key"
pass "check: a missing file, a missing key, and another value all fail it and nothing is written"

# --- 5. not a JSON object ----------------------------------------------------
for body in 'not json at all' '["autoCompactWindow", 300000]'; do
  home="$TMP_ROOT/broken"
  mkdir -p "$home/.claude"
  printf '%s\n' "$body" > "$home/.claude/settings.json"
  run_step "$home"
  expect_code 1 "$RC" "the step on a settings file holding '$body'"
  assert_contains "$OUT" 'is not a JSON object; left untouched' "the refusal must say the file was left alone"
  [ "$(cat "$home/.claude/settings.json")" = "$body" ] || fail "a refused settings file must keep its content"
  [ -z "$(find "$home/.claude" -mindepth 1 ! -name settings.json)" ] \
    || fail "a refusal must leave no scratch file behind: $(ls -A "$home/.claude")"
done
pass "unreadable settings: a file that is not a JSON object is refused and left untouched"

# --- 6. a pinned config directory --------------------------------------------
home="$TMP_ROOT/pinned"
mkdir -p "$home"
OUT=$(HOME="$home" CLAUDE_CONFIG_DIR="$home/elsewhere" "$STEP" 2>&1) || fail "the step under CLAUDE_CONFIG_DIR failed: $OUT"
[ "$(jq -r .autoCompactWindow "$home/elsewhere/settings.json")" = 300000 ] \
  || fail "CLAUDE_CONFIG_DIR must select the settings directory"
assert_absent "$home/.claude" "a pinned config directory must leave ~/.claude alone"
HOME="$home" "$STEP" --check --extra >/dev/null 2>&1 && rc=0 || rc=$?
expect_code 2 "$rc" "invalid use"
pass "CLAUDE_CONFIG_DIR selects the settings directory, and invalid use is refused"

echo "# all fm-boat-claude-auto-compact tests passed"
