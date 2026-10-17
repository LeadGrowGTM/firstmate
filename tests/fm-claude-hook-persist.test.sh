#!/usr/bin/env bash
# A symlinked Claude project directory must not drop a long session-start body.
# Claude Code persists hook output only when every component under its projects
# directory is a real directory. These cases drive bin/fm-claude-hook-persist.sh
# and the session-start runner that calls it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-hook-persist)
PERSIST="$ROOT/bin/fm-claude-hook-persist.sh"
unset CLAUDE_CODE_PROJECT_DIR_NAME

long_body() {
  local out=$1
  # 10001 bytes, one past Claude Code's inline hook limit.
  {
    printf 'S'
    dd if=/dev/zero bs=9999 count=1 2>/dev/null | tr '\0' 'x'
    printf 'E'
  } > "$out"
}

short_body() {
  printf 'short-digest\n' > "$1"
}

project_key() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

test_real_directory_keeps_the_body() {
  local case=$TMP_ROOT/real cwd=$TMP_ROOT/real/work cfg=$TMP_ROOT/real/cfg
  local key body out
  mkdir -p "$cwd" "$cfg/projects"
  key=$(project_key "$cwd")
  mkdir -p "$cfg/projects/$key"
  body=$case/body
  out=$case/out
  long_body "$body"
  CLAUDE_CONFIG_DIR=$cfg "$PERSIST" --cwd "$cwd" < "$body" > "$out"
  cmp -s "$body" "$out" || fail "a real project directory must pass the body through unchanged"
  [ ! -e "$cfg/projects/$key/tool-results" ] || fail "a real project directory must leave saving to Claude"
  pass "a real project directory passes a long body through unchanged"
}

test_symlink_saves_the_body_and_prints_a_short_pointer() {
  local case=$TMP_ROOT/link cwd=$TMP_ROOT/link/work cfg=$TMP_ROOT/link/cfg
  local target=$TMP_ROOT/link/target key body out dest size
  mkdir -p "$cwd" "$cfg/projects" "$target"
  key=$(project_key "$cwd")
  ln -s "$target" "$cfg/projects/$key"
  body=$case/body
  out=$case/out
  long_body "$body"
  CLAUDE_CONFIG_DIR=$cfg "$PERSIST" --cwd "$cwd" --session-id 'sess-1' < "$body" > "$out"
  dest=$cfg/projects/$key/sess-1/tool-results/session-start-digest.txt
  cmp -s "$body" "$dest" || fail "the full body was not written through the symlink"
  cmp -s "$body" "$target/sess-1/tool-results/session-start-digest.txt" \
    || fail "the saved body is not in the symlink target"
  size=$(wc -c < "$out" | tr -d ' ')
  [ "$size" -le 10000 ] || fail "the pointer is $size bytes, above Claude's inline limit"
  grep -F "Full session-start digest saved to: $dest" "$out" >/dev/null \
    || fail "the pointer does not name the saved digest"
  grep -F 'Read that file now' "$out" >/dev/null || fail "the pointer does not tell the reader to open the file"
  ! cmp -s "$body" "$out" || fail "the pointer must not be the whole body"
  pass "a symlinked project directory saves the body and prints a short pointer"
}

test_short_body_on_a_symlink_stays_inline() {
  local cwd=$TMP_ROOT/short/work cfg=$TMP_ROOT/short/cfg target=$TMP_ROOT/short/target
  local key body out
  mkdir -p "$cwd" "$cfg/projects" "$target"
  key=$(project_key "$cwd")
  ln -s "$target" "$cfg/projects/$key"
  body=$TMP_ROOT/short/body
  out=$TMP_ROOT/short/out
  short_body "$body"
  CLAUDE_CONFIG_DIR=$cfg "$PERSIST" --cwd "$cwd" < "$body" > "$out"
  cmp -s "$body" "$out" || fail "a short body must stay inline even when the project directory is a symlink"
  [ ! -e "$target/tool-results" ] || fail "a short body must not be copied aside"
  pass "a short body stays inline when the project directory is a symlink"
}

test_missing_project_directory_stays_inline() {
  local cwd=$TMP_ROOT/missing/work cfg=$TMP_ROOT/missing/cfg body out
  mkdir -p "$cwd" "$cfg/projects"
  body=$TMP_ROOT/missing/body
  out=$TMP_ROOT/missing/out
  long_body "$body"
  CLAUDE_CONFIG_DIR=$cfg "$PERSIST" --cwd "$cwd" < "$body" > "$out"
  cmp -s "$body" "$out" || fail "a missing project directory must pass the body through"
  pass "a missing project directory passes a long body through"
}

test_projects_symlink_with_a_real_child_stays_inline() {
  local cwd=$TMP_ROOT/rootlink/work cfg=$TMP_ROOT/rootlink/cfg shared=$TMP_ROOT/rootlink/shared
  local key body out
  mkdir -p "$cwd" "$cfg" "$shared"
  key=$(project_key "$cwd")
  mkdir -p "$shared/$key"
  ln -s "$shared" "$cfg/projects"
  body=$TMP_ROOT/rootlink/body
  out=$TMP_ROOT/rootlink/out
  long_body "$body"
  CLAUDE_CONFIG_DIR=$cfg "$PERSIST" --cwd "$cwd" < "$body" > "$out"
  cmp -s "$body" "$out" || fail "a symlink at projects/ itself must not divert the body"
  [ ! -e "$shared/$key/tool-results" ] || fail "a real child under a symlinked projects directory must not be rewritten"
  pass "a symlinked projects directory with a real child passes the body through"
}

test_dir_name_override_uses_that_directory() {
  local cwd=$TMP_ROOT/override/work cfg=$TMP_ROOT/override/cfg
  local key body out
  mkdir -p "$cwd" "$cfg/projects/realname" "$cfg/projects"
  key=$(project_key "$cwd")
  ln -s "$TMP_ROOT/override/target" "$cfg/projects/$key"
  mkdir -p "$TMP_ROOT/override/target"
  body=$TMP_ROOT/override/body
  out=$TMP_ROOT/override/out
  long_body "$body"
  CLAUDE_CONFIG_DIR=$cfg CLAUDE_CODE_PROJECT_DIR_NAME=realname \
    "$PERSIST" --cwd "$cwd" < "$body" > "$out"
  cmp -s "$body" "$out" || fail "a real override directory must pass the body through"
  mkdir -p "$TMP_ROOT/override/linked-target"
  ln -sfn "$TMP_ROOT/override/linked-target" "$cfg/projects/linked"
  CLAUDE_CONFIG_DIR=$cfg CLAUDE_CODE_PROJECT_DIR_NAME=linked \
    "$PERSIST" --cwd "$cwd" --session-id 'sess-o' < "$body" > "$out"
  cmp -s "$body" "$cfg/projects/linked/sess-o/tool-results/session-start-digest.txt" \
    || fail "a symlinked override directory did not receive the body"
  pass "CLAUDE_CODE_PROJECT_DIR_NAME selects the directory that is checked"
}

test_sessionstart_run_saves_through_the_symlink() {
  local home=$TMP_ROOT/primary cwd=$TMP_ROOT/primary-work cfg=$TMP_ROOT/primary-cfg
  local target=$TMP_ROOT/primary-target key out dest
  mkdir -p "$home/bin" "$home/state" "$cwd" "$cfg/projects" "$target"
  printf 'primary\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  for script in fm-sessionstart-run.sh fm-claude-hook-persist.sh fm-gate-refuse-lib.sh \
    fm-primary-scope-lib.sh fm-session-lock-lib.sh fm-hook-host-lib.sh fm-cursor-lib.sh; do
    cp "$ROOT/bin/$script" "$home/bin/$script"
  done
  chmod +x "$home/bin/fm-sessionstart-run.sh" "$home/bin/fm-claude-hook-persist.sh"
  cat > "$home/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'S'
dd if=/dev/zero bs=12000 count=1 2>/dev/null | tr '\0' 'y'
printf 'E'
SH
  chmod +x "$home/bin/fm-session-start.sh"
  key=$(project_key "$cwd")
  ln -s "$target" "$cfg/projects/$key"
  out=$TMP_ROOT/primary.out
  (
    cd "$cwd" || exit 1
    printf '%s' '{"source":"startup","session_id":"sess-run"}' \
      | FM_HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$home/bin/fm-sessionstart-run.sh" > "$out"
  )
  dest=$cfg/projects/$key/sess-run/tool-results/session-start-digest.txt
  [ -f "$dest" ] || fail "session start did not save the digest through the symlink"
  grep -F 'Syyyy' "$dest" >/dev/null || fail "the saved session-start digest is missing its body"
  grep -F "Full session-start digest saved to: $dest" "$out" >/dev/null \
    || fail "session start did not print the saved-digest pointer"
  size=$(wc -c < "$out" | tr -d ' ')
  [ "$size" -le 10000 ] || fail "session start pointer is $size bytes"
  pass "session start saves a long digest when the Claude project directory is a symlink"
}

test_real_directory_keeps_the_body
test_symlink_saves_the_body_and_prints_a_short_pointer
test_short_body_on_a_symlink_stays_inline
test_missing_project_directory_stays_inline
test_projects_symlink_with_a_real_child_stays_inline
test_dir_name_override_uses_that_directory
test_sessionstart_run_saves_through_the_symlink
