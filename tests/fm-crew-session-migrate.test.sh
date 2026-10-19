#!/usr/bin/env bash
# bin/fm-crew-session-migrate.sh: a task whose own record cannot name its tmux
# endpoint is one dead task, not a broken home. It warns, is listed as skipped,
# and the rest of the home still migrates; a task that can be resolved but then
# disagrees with its live window still fails the whole command.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-crew-migrate)
LABEL="fm-crewmig-$$"
TMUXC=(tmux -L "$LABEL")
SOCK=
stop_server() { "${TMUXC[@]}" kill-server >/dev/null 2>&1 || true; }
trap 'stop_server; fm_test_cleanup' EXIT

write_meta() {  # <home> <id> <window> [extra meta line...]
  local home=$1 id=$2 window=$3
  shift 3
  mkdir -p "$home/state"
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\nproject=%s\nharness=codex\nkind=ship\nspawn_gen=s1\n' "$home" "$home"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/state/$id.meta"
}

make_world() {  # <name>; builds a home with a healthy task and a live source session
  local home="$TMP_ROOT/$1"
  stop_server
  mkdir -p "$home/config" "$home/state"
  printf 'firstmate-crew\n' > "$home/config/crew-tmux-session"
  "${TMUXC[@]}" new-session -d -s holding -n keeper -c "$home" || fail "could not start tmux"
  "${TMUXC[@]}" new-window -d -t '=holding:' -n fm-healthy -c "$home" || fail "could not add the healthy window"
  "${TMUXC[@]}" display-message -p -t '=holding:fm-healthy' '#{socket_path}' > "$home/sock" || fail "no socket path"
  SOCK=$(cat "$home/sock")
  write_meta "$home" healthy "holding:fm-healthy" "tmux_socket=$SOCK"
  printf '%s\n' "$home"
}

run_migrate() {  # <home> [--apply]; sets OUT, ERR, RC
  local home=$1
  shift
  RC=0
  OUT=$(FM_HOME="$home" "$ROOT/bin/fm-crew-session-migrate.sh" "$@" 2>"$TMP_ROOT/err") || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

test_missing_socket_skips_with_a_warning() {
  local home
  home=$(make_world missing-socket)
  write_meta "$home" dead "holding:fm-dead"
  run_migrate "$home" --apply
  [ "$RC" -eq 0 ] || fail "a missing tmux socket aborted the home (rc=$RC): $ERR"
  assert_contains "$ERR" "warning: task dead: recorded tmux socket is missing or ambiguous" \
    "the skipped task was not named with its reason"
  assert_contains "$OUT" "skip unresolvable dead recorded tmux socket is missing or ambiguous" \
    "the summary did not list the skipped task"
  assert_contains "$OUT" "moved healthy holding:fm-healthy -> firstmate-crew:fm-healthy" \
    "the healthy task was not migrated"
  grep -qx 'window=firstmate-crew:fm-healthy' "$home/state/healthy.meta" \
    || fail "the healthy record was not rewritten"
  grep -qx 'window=holding:fm-dead' "$home/state/dead.meta" || fail "the dead record was touched"
  pass "a missing tmux socket skips that task with a warning and migrates the rest"
}

test_ambiguous_socket_skips_with_a_warning() {
  local home
  home=$(make_world ambiguous-socket)
  SOCK=$(cat "$home/sock")
  write_meta "$home" twin "holding:fm-twin" "tmux_socket=$SOCK" "tmux_socket=$SOCK.other"
  run_migrate "$home"
  [ "$RC" -eq 0 ] || fail "an ambiguous tmux socket aborted the home (rc=$RC): $ERR"
  assert_contains "$ERR" "warning: task twin: recorded tmux socket is missing or ambiguous" \
    "the ambiguous task was not named with its reason"
  assert_contains "$OUT" "skip unresolvable twin" "the summary did not list the ambiguous task"
  assert_contains "$OUT" "would-move healthy holding:fm-healthy -> firstmate-crew:fm-healthy" \
    "the dry run did not plan the healthy task"
  pass "an ambiguous tmux socket skips that task and the dry run still plans the rest"
}

test_ambiguous_backend_skips_with_a_warning() {
  local home
  home=$(make_world ambiguous-backend)
  write_meta "$home" twin "holding:fm-twin" 'backend=tmux' 'backend=other'
  run_migrate "$home" --apply
  [ "$RC" -eq 0 ] || fail "an ambiguous backend aborted the home (rc=$RC): $ERR"
  assert_contains "$ERR" 'warning: task twin: recorded backend is ambiguous (2 fields)' \
    "the ambiguous backend was not named with its reason"
  assert_contains "$OUT" 'skip unresolvable twin recorded backend is ambiguous (2 fields)' \
    "the summary did not list the ambiguous backend"
  assert_contains "$OUT" 'moved healthy holding:fm-healthy -> firstmate-crew:fm-healthy' \
    "the healthy task was not migrated after the ambiguous backend"
  pass "an ambiguous backend skips that task and migrates the rest"
}

test_other_unresolvable_endpoint_records_skip() {
  local home
  home=$(make_world other-records)
  write_meta "$home" relsock "holding:fm-relsock" "tmux_socket=relative.sock"
  write_meta "$home" nowindow ""
  run_migrate "$home"
  [ "$RC" -eq 0 ] || fail "unresolvable records aborted the home (rc=$RC): $ERR"
  assert_contains "$ERR" "warning: task relsock: recorded tmux socket is not an absolute path" \
    "the relative socket was not warned about"
  assert_contains "$ERR" "warning: task nowindow: recorded window is missing or ambiguous" \
    "the empty window was not warned about"
  assert_contains "$OUT" "would-move healthy" "the healthy task was not planned"
  pass "other unresolvable endpoint records also skip with a warning"
}

test_a_resolvable_task_that_disagrees_still_fails() {
  local home
  home=$(make_world still-refuses)
  SOCK=$(cat "$home/sock")
  write_meta "$home" dead "holding:fm-dead"
  write_meta "$home" wrong "elsewhere:fm-wrong" "tmux_socket=$SOCK"
  "${TMUXC[@]}" new-session -d -s mismatch -n keeper -c "$home" || fail "could not add a session"
  "${TMUXC[@]}" new-window -d -t '=mismatch:' -n fm-wrong -c "$home" || fail "could not add the window"
  run_migrate "$home" --apply
  [ "$RC" -ne 0 ] || fail "a resolvable task in the wrong session did not fail the command: $OUT / $ERR"
  assert_contains "$ERR" "task wrong: recorded window is elsewhere:fm-wrong but that window is in session mismatch" \
    "the real disagreement was not reported"
  assert_contains "$OUT" 'skip unresolvable dead recorded tmux socket is missing or ambiguous' \
    "the skipped task was missing from the summary after a later preflight refusal"
  grep -qx 'window=holding:fm-healthy' "$home/state/healthy.meta" \
    || fail "a refused run moved the healthy task"
  pass "a resolvable task that disagrees with its live window still refuses the home"
}

test_missing_socket_skips_with_a_warning
test_ambiguous_socket_skips_with_a_warning
test_ambiguous_backend_skips_with_a_warning
test_other_unresolvable_endpoint_records_skip
test_a_resolvable_task_that_disagrees_still_fails
