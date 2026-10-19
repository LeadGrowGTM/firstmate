#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_EXISTING_WINDOW"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  local -a kind_args=(--mode no-mistakes --yolo off)
  shift
  if [ "${1:-}" = --scout ]; then
    kind_args=(--scout)
    shift
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-}" FM_FAKE_EXISTING_WINDOW="${FM_FAKE_EXISTING_WINDOW:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "${kind_args[@]}" "$@" 2>&1
}

test_git_identity_is_worktree_scoped() {
  local rec id out status ident common before
  id=settle-git-identity-z5
  rec=$(make_settle_case settle-git-identity "$id" 0)
  read_settle_record "$rec"
  git -C "$PROJ_DIR" config --local user.name 'Shared Operator'
  git -C "$PROJ_DIR" config --local user.email 'operator@example.invalid'
  common=$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)
  before=$(git config --file "$common/config" --get user.name)

  out=$(run_settle_spawn "$id" --git-name 'Task Worker' --git-email 'worker@example.invalid')
  status=$?
  expect_code 0 "$status" "spawn with task Git identity should succeed"$'\n'"$out"
  ident=$(env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git -C "$WT_DIR" var GIT_COMMITTER_IDENT)
  case "$ident" in
  'Task Worker <worker@example.invalid> '*) ;;
  *) fail "task worktree committer ident was '$ident'" ;;
  esac
  [ "$(git -C "$WT_DIR" config --worktree --get user.name)" = 'Task Worker' ] || fail "task worktree name was not set"
  [ "$(git config --file "$common/config" --get user.name)" = "$before" ] || fail "common Git name changed"
  [ "$(git config --file "$common/config" --get user.email)" = 'operator@example.invalid' ] || fail "common Git email changed"
  [ "$(git config --file "$common/config" --get --bool extensions.worktreeConfig)" = true ] || fail "worktree config extension was not enabled"
  pass "requested committer identity belongs only to the linked task worktree"
}

test_scout_git_identity_is_worktree_scoped() {
  local rec id out status ident
  id=settle-scout-git-identity-z9
  rec=$(make_settle_case settle-scout-git-identity "$id" 0)
  read_settle_record "$rec"
  out=$(run_settle_spawn "$id" --scout --git-name 'Scout Worker' --git-email 'scout@example.invalid')
  status=$?
  expect_code 0 "$status" "scout spawn with task Git identity should succeed"$'\n'"$out"
  ident=$(env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git -C "$WT_DIR" var GIT_COMMITTER_IDENT)
  case "$ident" in
  'Scout Worker <scout@example.invalid> '*) ;;
  *) fail "scout worktree committer ident was '$ident'" ;;
  esac
  pass "scout committer identity belongs to its linked task worktree"
}

test_git_identity_flag_validation() {
  local rec id out status args
  id=settle-git-invalid-z6
  rec=$(make_settle_case settle-git-invalid "$id" 0)
  read_settle_record "$rec"
  for args in name-only email-only empty-name empty-email newline-name malformed-name malformed-email double-at-email; do
    case "$args" in
    name-only) set -- --git-name Worker ;;
    email-only) set -- --git-email worker@example.invalid ;;
    empty-name) set -- --git-name '' --git-email worker@example.invalid ;;
    empty-email) set -- --git-name Worker --git-email '' ;;
    newline-name) set -- --git-name $'Worker\nOther' --git-email worker@example.invalid ;;
    malformed-name) set -- --git-name 'Worker <Other>' --git-email worker@example.invalid ;;
    malformed-email) set -- --git-name Worker --git-email 'worker example.invalid' ;;
    double-at-email) set -- --git-name Worker --git-email 'worker@extra@example.invalid' ;;
    esac
    out=$(run_settle_spawn "$id" "$@")
    status=$?
    [ "$status" -ne 0 ] || fail "$args unexpectedly launched"$'\n'"$out"
  done
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "invalid flags published task metadata"
  out=$("$SPAWN" "$id" "$PROJ_DIR" --secondmate --git-name Worker --git-email worker@example.invalid 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate accepted task Git identity"
  assert_contains "$out" "fresh ship and scout" "secondmate Git identity refusal was unexplained"
  out=$("$SPAWN" "$id" --relaunch --git-name Worker --git-email worker@example.invalid 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch accepted task Git identity"
  assert_contains "$out" "fresh ship and scout" "relaunch Git identity refusal was unexplained"
  pass "unpaired, empty, control, and malformed Git identity flags refuse"
}

test_git_identity_refuses_unsafe_common_config() {
  local rec id out status common setting
  for setting in bare worktree; do
    id="settle-git-unsafe-$setting-z7"
    rec=$(make_settle_case "settle-git-unsafe-$setting" "$id" 0)
    read_settle_record "$rec"
    common=$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)
    if [ "$setting" = bare ]; then
      git config --file "$common/config" core.bare true
    else
      git config --file "$common/config" core.worktree "$PROJ_DIR"
    fi
    out=$(run_settle_spawn "$id" --git-name Worker --git-email worker@example.invalid)
    status=$?
    [ "$status" -ne 0 ] || fail "unsafe core.$setting unexpectedly launched"$'\n'"$out"
    assert_contains "$out" "core.$setting" "unsafe core.$setting refusal was unexplained"
    [ "$(git config --file "$common/config" --get extensions.worktreeConfig || true)" != true ] || fail "unsafe core.$setting enabled worktree config"
  done
  pass "unsafe common Git core settings refuse before enabling worktree config"
}

test_no_git_flags_leave_config_unchanged() {
  local rec id out status common before after
  id=settle-git-default-z8
  rec=$(make_settle_case settle-git-default "$id" 0)
  read_settle_record "$rec"
  common=$(git -C "$PROJ_DIR" rev-parse --path-format=absolute --git-common-dir)
  before=$(cat "$common/config")
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "ordinary spawn should succeed"$'\n'"$out"
  after=$(cat "$common/config")
  [ "$before" = "$after" ] || fail "ordinary spawn changed common Git config"
  [ ! -e "$(git -C "$WT_DIR" rev-parse --git-path config.worktree)" ] || fail "ordinary spawn created worktree config"
  pass "ordinary spawn leaves Git config unchanged"
}

test_reused_slot_identity_scope() {
  local kind requested rec id out status ident
  for kind in ship scout; do
    for requested in no yes; do
      id="settle-reused-$kind-$requested-z10"
      rec=$(make_settle_case "settle-reused-$kind-$requested" "$id" 0)
      read_settle_record "$rec"
      git -C "$PROJ_DIR" config --local user.name 'Current Operator'
      git -C "$PROJ_DIR" config --local user.email 'current@example.invalid'
      git -C "$WT_DIR" config --local extensions.worktreeConfig true
      git -C "$WT_DIR" config --worktree user.name 'Prior Boat Worker'
      git -C "$WT_DIR" config --worktree user.email 'prior@example.invalid'
      set --
      [ "$kind" != scout ] || set -- --scout
      if [ "$requested" = yes ]; then
        out=$(run_settle_spawn "$id" "$@" --git-name 'Controller Worker' --git-email 'controller@example.invalid')
      else
        out=$(run_settle_spawn "$id" "$@")
      fi
      status=$?
      expect_code 0 "$status" "reused $kind spawn with requested identity $requested should succeed"$'\n'"$out"
      ident=$(env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git -C "$WT_DIR" var GIT_COMMITTER_IDENT)
      if [ "$requested" = yes ]; then
        case "$ident" in
        'Controller Worker <controller@example.invalid> '*) ;;
        *) fail "reused $kind worktree did not use the controller identity: $ident" ;;
        esac
      else
        case "$ident" in
        'Prior Boat Worker <prior@example.invalid> '*) ;;
        *) fail "ordinary reused $kind worktree changed its identity: $ident" ;;
        esac
        [ "$(git -C "$WT_DIR" config --worktree --get user.name)" = 'Prior Boat Worker' ] || fail "ordinary reused $kind worktree changed its name"
        [ "$(git -C "$WT_DIR" config --worktree --get user.email)" = 'prior@example.invalid' ] || fail "ordinary reused $kind worktree changed its email"
      fi
    done
  done
  pass "Boat identity overwrites reused ship and scout slots; ordinary launches leave them alone"
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
# A refused spawn that already created its tmux window must close that window,
# or the same-id retry dies on "window already exists". The window a spawn did
# not create, and the window of a spawn that launched a worker, stay untouched.
test_refused_spawn_closes_its_own_window() {
  local rec id out status log
  id=settle-refused-window-z11
  rec=$(make_primary_case settle-refused-window "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  log="$TMP_ROOT/settle-refused-window/tmux.log"
  : > "$log"

  out=$(FM_FAKE_TMUX_LOG="$log" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  grep -q '^new-window ' "$log" || fail "the refused spawn never created a window"$'\n'"$(cat "$log")"
  grep -q "^kill-window .*fm-$id" "$log" || fail "refused spawn left its window behind"$'\n'"$(cat "$log")"
  pass "a refused spawn closes the window it created"
}

test_refused_before_window_leaves_foreign_window() {
  local rec id out status log
  id=settle-foreign-window-z12
  rec=$(make_primary_case settle-foreign-window "$id" 0)
  read_settle_record "$rec"
  log="$TMP_ROOT/settle-foreign-window/tmux.log"
  : > "$log"

  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_EXISTING_WINDOW="fm-$id" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reused a window it did not create"$'\n'"$out"
  assert_contains "$out" "already exists" "the refusal did not name the existing window"
  if grep -q '^kill-window' "$log"; then
    fail "spawn closed a window it did not create"$'\n'"$(cat "$log")"
  fi
  pass "a spawn refused on an existing window leaves that window alone"
}

test_successful_spawn_keeps_its_window() {
  local rec id out status log
  id=settle-kept-window-z13
  rec=$(make_primary_case settle-kept-window "$id" 3)
  read_settle_record "$rec"
  log="$TMP_ROOT/settle-kept-window/tmux.log"
  : > "$log"

  out=$(FM_FAKE_TMUX_LOG="$log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  if grep -q '^kill-window' "$log"; then
    fail "successful spawn closed its window"$'\n'"$(cat "$log")"
  fi
  pass "a successful spawn keeps its window"
}

test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_refused_spawn_closes_its_own_window
test_refused_before_window_leaves_foreign_window
test_successful_spawn_keeps_its_window
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_git_identity_is_worktree_scoped
test_scout_git_identity_is_worktree_scoped
test_git_identity_flag_validation
test_git_identity_refuses_unsafe_common_config
test_no_git_flags_leave_config_unchanged
test_reused_slot_identity_scope

echo "# all fm-spawn-worktree-settle tests passed"
