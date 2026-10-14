#!/usr/bin/env bash
# Two homes cloning one origin must not launch in each other's treehouse slot.
#
# Treehouse keys its default pool by directory name plus origin, then reuses an
# idle slot whoever created it. These cases build that shape under a temp root
# and drive bin/fm-spawn.sh and the wake library. A machine with the treehouse
# binary also leases from a home's own pool for real, through an origin only
# the operator's git configuration can reach. Nothing here touches a real
# home, ~/.treehouse, or the real user state directory.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset TREEHOUSE_ROOT

TMP_ROOT=$(fm_test_tmproot fm-shared-pool-trust)

# lib <fm-home> <user-home> <function> [args...]
# Sources the wake library against the temp home so its source-time state
# directory is not a real Firstmate home. FM_TEST_XDG_STATE pins the user state
# directory; empty leaves it to the user home.
lib() {
  local home=$1 user_home=$2
  shift 2
  mkdir -p "$home/state" "$user_home"
  # shellcheck disable=SC2016 # $1 and $@ expand in the child shell, not here.
  env -u GIT_CONFIG_GLOBAL HOME="$user_home" XDG_STATE_HOME="${FM_TEST_XDG_STATE:-}" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c 'set -u; . "$1"; shift; "$@"' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
}

make_same_origin_clones() {  # <root>
  local root=$1 seed bare url
  seed=$root/seed
  bare=$root/origin.git
  fm_git_init_commit "$seed"
  fm_git_add_origin "$seed" "$bare"
  url=$(git -C "$seed" remote get-url origin)
  mkdir -p "$root/homeA/projects" "$root/homeB/projects"
  git clone -q "$url" "$root/homeA/projects/widget"
  git clone -q "$url" "$root/homeB/projects/widget"
  printf '%s\n' "$url"
}

# Pane path switches to FM_FAKE_PANE_AFTER_EXIT once a text-line `exit` is sent.
# Treehouse logs its HOME, its argv, and the fm.marker its git reads from the
# global configuration, and `get --lease` prints FM_FAKE_TREEHOUSE_PRINT.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_CWD_FAIL_AFTER_EXIT:-}" ] && [ -n "${FM_FAKE_EXIT_FLAG:-}" ] \
      && [ -f "$FM_FAKE_EXIT_FLAG" ]; then
      exit 1
    fi
    if [ -n "${FM_FAKE_PANE_AFTER_EXIT:-}" ] && [ -n "${FM_FAKE_EXIT_FLAG:-}" ] \
      && [ -f "$FM_FAKE_EXIT_FLAG" ]; then
      printf '%s\n' "$FM_FAKE_PANE_AFTER_EXIT"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf 'bash\n'
    exit 0
    ;;
  *"#{pane_tty}"*)
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_RELAUNCH_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_RELAUNCH_WINDOW"; exit 0 ;;
  has-session|new-session|new-window|set-window-option) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_ENDPOINT_CLOSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ENDPOINT_CLOSE_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      pending=$FM_FAKE_PANE_LOG.pending
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m)
            [ -f "$pending" ] || continue
            command=$(cat "$pending")
            rm -f "$pending"
            printf '%s\n' "$command" >> "$FM_FAKE_PANE_LOG"
            get=
            case "$command" in
              'treehouse get') get=1 ;;
              *' && treehouse get')
                guard=${command%' && treehouse get'}
                if HOME="${FM_FAKE_PANE_HOME:-$HOME}" \
                  POOL_BASE="${FM_FAKE_PANE_POOL_BASE:-${POOL_BASE:-}}" \
                  bash -c "$guard" >/dev/null 2>&1; then
                  get=1
                fi
                ;;
            esac
            if [ -n "$get" ] && [ -n "${FM_FAKE_TREEHOUSE_INITIAL_PATH:-}" ]; then
              mkdir -p "$(dirname "$FM_FAKE_TREEHOUSE_INITIAL_PATH")"
              git -C "${FM_FAKE_TREEHOUSE_INITIAL_PROJECT:?}" worktree add --quiet --detach \
                "$FM_FAKE_TREEHOUSE_INITIAL_PATH" || exit 1
              : > "${FM_FAKE_TREEHOUSE_INITIAL_LEASE:?}"
            fi
            if [ -f "$pending.literal" ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
              printf '%s\n' "$command" >> "$FM_FAKE_LAUNCH_LOG"
            fi
            if [ -f "$pending.literal" ] && [ -n "${FM_FAKE_WORKER_EDIT_PATH:-}" ]; then
              case "$command" in
                *launch.*) printf 'worker work that must survive\n' >> "$FM_FAKE_WORKER_EDIT_PATH/README.md" ;;
              esac
            fi
            rm -f "$pending.literal"
            if [ "$command" = exit ] && [ -n "${FM_FAKE_EXIT_FLAG:-}" ]; then
              : > "$FM_FAKE_EXIT_FLAG"
              if [ -n "${FM_FAKE_TREEHOUSE_INITIAL_LEASE:-}" ] \
                && [ -z "${FM_FAKE_CWD_FAIL_AFTER_EXIT:-}" ] \
                && [ -z "${FM_FAKE_TREEHOUSE_DELAY_RETURN:-}" ]; then
                treehouse fake-complete-return || exit 1
              fi
            fi
            ;;
          *)
            printf '%s' "$a" >> "$pending"
            [ -z "$literal" ] || : > "$pending.literal"
            ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TREEHOUSE_LOG:?}
printf 'HOME=%s\n' "${HOME-}" >> "$log"
printf 'args=%s\n' "$*" >> "$log"
printf 'call=%s\t%s\n' "$*" "$(pwd -P)" >> "$log"
case "$*" in
  status)
    lease=${FM_FAKE_TREEHOUSE_INITIAL_LEASE:-}
    path=${FM_FAKE_TREEHOUSE_INITIAL_PATH:-}
    if [ -z "$lease" ] || [ -z "$path" ]; then
      exit 0
    fi
    state=available
    if [ -f "$lease" ]; then
      state=in-use
    fi
    shown=$path
    case "$path" in
      "$HOME") shown='~' ;;
      "$HOME"/*) shown="~${path#"$HOME"}" ;;
    esac
    printf '%-4s  %-11s  %s\n' 1 "$state" "$shown"
    if [ -n "${FM_FAKE_TREEHOUSE_HOLD_RETURN:-}" ]; then
      printf '%-4s  %-11s  %s\n' 2 available "$shown-other"
    fi
    ;;
  status\ *)
    printf 'Error: unknown status argument\n' >&2
    exit 1
    ;;
  fake-complete-return)
    [ -n "${FM_FAKE_EXIT_FLAG:-}" ] && [ -f "$FM_FAKE_EXIT_FLAG" ] || exit 1
    [ -n "${FM_FAKE_TREEHOUSE_INITIAL_LEASE:-}" ] \
      && [ -f "$FM_FAKE_TREEHOUSE_INITIAL_LEASE" ] || exit 1
    rm -f "$FM_FAKE_TREEHOUSE_INITIAL_LEASE"
    ;;
  'get --lease --lease-holder '*)
    printf 'gitmarker=%s\n' "$(git config --global --get fm.marker 2>/dev/null)" >> "$log"
    echo "fake treehouse lease progress" >&2
    [ -z "${FM_FAKE_TREEHOUSE_LEASE_RC:-}" ] || exit "$FM_FAKE_TREEHOUSE_LEASE_RC"
    if [ -n "${FM_FAKE_TREEHOUSE_FALLBACK_LEASE:-}" ]; then
      mkdir -p "$(dirname "${FM_FAKE_TREEHOUSE_PRINT:?}")"
      git worktree add --quiet --detach "$FM_FAKE_TREEHOUSE_PRINT" || exit 1
      : > "$FM_FAKE_TREEHOUSE_FALLBACK_LEASE"
    fi
    printf '%s\n' "${FM_FAKE_TREEHOUSE_PRINT:-}"
    ;;
  return\ --force\ *)
    if [ -n "${FM_FAKE_TREEHOUSE_FALLBACK_LEASE:-}" ] \
      && [ "${3:-}" = "${FM_FAKE_TREEHOUSE_PRINT:-}" ]; then
      rm -f "$FM_FAKE_TREEHOUSE_FALLBACK_LEASE"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TREEHOUSE_COMPLETE_ON_SLEEP:-}" ] \
  && [ -n "${FM_FAKE_EXIT_FLAG:-}" ] && [ -f "$FM_FAKE_EXIT_FLAG" ] \
  && [ -n "${FM_FAKE_TREEHOUSE_LOG:-}" ] \
  && grep -Fqx 'args=status' "$FM_FAKE_TREEHOUSE_LOG" \
  && [ -n "${FM_FAKE_TREEHOUSE_INITIAL_LEASE:-}" ] \
  && [ -f "$FM_FAKE_TREEHOUSE_INITIAL_LEASE" ]; then
  treehouse fake-complete-return
fi
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# assert_grep is fixed-string, so anchors would be matched as characters.
assert_exact_line() {  # <line> <file> <msg>
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

assert_no_exact_line() {  # <line> <file> <msg>
  ! grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

assert_outside() {  # <path> <dir> <msg>
  case "$1/" in
    "$2"/*) fail "$3: $1 is inside $2" ;;
  esac
}

# First six hex digits of the sha256 of a string. sha256sum wins when both
# tools exist, matching the pool helper; shasum is the fallback.
pool_hash6() {  # <text>
  local hex
  if command -v sha256sum >/dev/null 2>&1; then
    hex=$(printf '%s' "$1" | sha256sum | awk '{ print $1 }') || fail "sha256sum failed"
  elif command -v shasum >/dev/null 2>&1; then
    hex=$(printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }') || fail "shasum failed"
  else
    fail "sha256sum and shasum are both absent"
  fi
  printf '%s\n' "${hex:0:6}"
}

add_worktree() {  # <repo> <path> [branch]
  local repo=$1 path=$2 branch=${3:-}
  mkdir -p -- "$(dirname -- "$path")"
  if [ -n "$branch" ]; then
    git -C "$repo" worktree add --quiet -b "$branch" "$path"
  else
    git -C "$repo" worktree add --quiet --detach "$path"
  fi
}

test_two_clones_of_one_origin_do_not_treat_each_others_slot_as_their_own() {
  local root=$TMP_ROOT/pair user slot_a own_b
  user=$root/user-home
  make_same_origin_clones "$root" >/dev/null
  slot_a=$root/shared-pool/1/widget
  add_worktree "$root/homeA/projects/widget" "$slot_a"
  lib "$root/homeA" "$user" fm_treehouse_same_clone \
    "$root/homeA/projects/widget" "$slot_a" \
    || fail "home A rejected a worktree of its own clone"
  lib "$root/homeB" "$user" fm_treehouse_same_clone \
    "$root/homeB/projects/widget" "$slot_a" \
    && fail "home B accepted home A's slot as its own clone"
  own_b=$root/own-b
  add_worktree "$root/homeB/projects/widget" "$own_b" own-b
  lib "$root/homeB" "$user" fm_treehouse_same_clone \
    "$root/homeB/projects/widget" "$own_b" \
    || fail "home B rejected a worktree of its own clone"
  pass "two clones of one origin disagree about whose pool slot it is"
}

test_a_homes_own_pool_is_outside_the_home_and_the_clone_and_unique_per_home() {
  local root=$TMP_ROOT/place user first second pool_first pool_second hash state
  user=$root/user-home
  first=$root/one/crew
  second=$root/two/crew
  mkdir -p "$first/projects/widget" "$second/projects/widget"
  pool_first=$(lib "$first" "$user" fm_treehouse_home_pool "$first") \
    || fail "the first home's pool could not be resolved"
  pool_second=$(lib "$second" "$user" fm_treehouse_home_pool "$second") \
    || fail "the second home's pool could not be resolved"
  hash=$(pool_hash6 "$(CDPATH='' cd -- "$first" && pwd -P)")
  assert_equals "$user/.local/state/firstmate/crew-$hash" "$pool_first" \
    "the pool was not the home's name plus the hash of its path under the user state directory"
  assert_not_equals "$pool_first" "$pool_second" \
    "two homes with one folder name in different places share a pool"
  assert_outside "$pool_first" "$first" "the pool is inside its Firstmate home"
  assert_outside "$pool_first" "$first/projects/widget" "the pool is inside the project clone"
  assert_outside "$pool_second" "$second" "the pool is inside its Firstmate home"
  state=$root/xdg-state
  pool_first=$(FM_TEST_XDG_STATE="$state" lib "$first" "$user" fm_treehouse_home_pool "$first") \
    || fail "the pool could not be resolved under a set user state directory"
  assert_equals "$state/firstmate/crew-$hash" "$pool_first" \
    "a set user state directory was not used"
  pass "a home's own pool sits outside the home and the clone, one per home"
}

# Sets CASE_HOME, CASE_FAKEBIN, CASE_STATE and CASE_POOL for one spawn case.
prepare_spawn_home() {  # <case> <id>
  local case_dir=$1 id=$2
  CASE_HOME=$case_dir/home
  CASE_USER_HOME=$case_dir/user-home
  CASE_FAKEBIN=$(make_pool_fakebin "$case_dir/fake")
  CASE_STATE=$case_dir/xdg-state
  fm_test_spawn_home "$CASE_HOME" codex
  fm_test_spawn_brief "$CASE_HOME" "$id" "Launch widget from this home's own clone."
  mkdir -p "$case_dir/other/projects" "$CASE_HOME/projects" "$CASE_USER_HOME"
  git clone -q "$CASE_URL" "$case_dir/other/projects/widget"
  git clone -q "$CASE_URL" "$CASE_HOME/projects/widget"
  git config --file "$CASE_USER_HOME/.gitconfig" fm.marker operator
  printf 'treehouse.toml\n' >> "$CASE_HOME/projects/widget/.git/info/exclude"
  CASE_POOL=$(FM_TEST_XDG_STATE="$CASE_STATE" lib "$CASE_HOME" "$CASE_USER_HOME" \
    fm_treehouse_home_pool "$CASE_HOME") || fail "the case's pool could not be resolved"
}

# run_spawn <pane> <id>: one launch of widget from CASE_HOME.
run_spawn() {
  local pane=$1 id=$2
  shift 2
  (
    unset GIT_CONFIG_GLOBAL
    XDG_STATE_HOME="$CASE_STATE" FM_TEST_SPAWN_USER_HOME="$CASE_USER_HOME" \
      fm_test_run_spawn "$CASE_HOME" "$pane" "$CASE_FAKEBIN" "$id" "$CASE_HOME/projects/widget" \
      --mode no-mistakes --yolo off "$@"
  )
}

test_spawn_handed_the_other_clones_copy_leases_this_homes_own_worktree() {
  local id=pool-foreign-lease case_dir=$TMP_ROOT/spawn-foreign
  local foreign own pane_log tree_log out status
  CASE_URL=$(make_same_origin_clones "$TMP_ROOT/spawn-origin")
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  own=$CASE_POOL/.treehouse/kept/1/widget
  add_worktree "$CASE_HOME/projects/widget" "$own" "kept-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$own" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id")
  status=$?
  expect_code 0 "$status" "spawn should launch in this home's own worktree"$'\n'"$out"
  assert_grep ' && treehouse get' "$pane_log" \
    "spawn did not check the shared pool in the pane before get"
  assert_exact_line "exit" "$pane_log" \
    "spawn did not leave the other clone's copy, so treehouse never took it back"
  assert_no_grep "args=return --force $foreign" "$tree_log" \
    "spawn force-returned a copy another clone owns"
  assert_grep "args=get --lease --lease-holder $id" "$tree_log" \
    "spawn did not lease from this home's own pool"
  assert_exact_line "HOME=$CASE_POOL" "$tree_log" \
    "the lease did not point treehouse at this home's own pool"
  assert_exact_line "gitmarker=operator" "$tree_log" \
    "git under the lease did not read the operator's global configuration"
  assert_grep "cd -- " "$pane_log" "the pane was not moved into the leased worktree"
  assert_contains "$(cat "$pane_log")" "$own" "the pane was not sent to this home's worktree"
  assert_grep "worktree=$own" "$CASE_HOME/state/$id.meta" \
    "spawn did not record this home's worktree"
  assert_no_grep "args=return --force $own" "$tree_log" \
    "a launched worker's lease was returned"
  assert_not_contains "$out" "fake treehouse lease progress" \
    "a successful lease spilled treehouse's progress onto the launch output"
  pass "a launch handed the other clone's copy leaves it and leases its own"
}

test_spawn_labels_treehouses_own_error_when_the_lease_fails() {
  local id=pool-lease-fails case_dir=$TMP_ROOT/spawn-lease-fails
  local foreign pane_log tree_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_LEASE_RC=3 FM_FAKE_PANE_AFTER_EXIT="$CASE_HOME/projects/widget" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although the lease failed"$'\n'"$out"
  assert_contains "$out" "treehouse exit 3" "the stop did not report treehouse's exit status"
  assert_contains "$out" "treehouse: fake treehouse lease progress" \
    "the stop did not carry treehouse's own error under its label"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "a failed lease published a task record"
  pass "a failed lease reports treehouse's own error under its label"
}

test_spawn_refuses_a_configured_foreign_lease_without_returning_it() {
  local id=pool-foreign-refuse case_dir=$TMP_ROOT/spawn-refuse
  local foreign leased pane_log tree_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  leased=$case_dir/shared-pool/2/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  add_worktree "$case_dir/other/projects/widget" "$leased"
  printf 'root = "%s"\n' "$case_dir/shared-pool" \
    > "$CASE_HOME/projects/widget/treehouse.toml"
  printf 'root = "%s"\n' "$case_dir/shared-pool" \
    > "$case_dir/other/projects/widget/treehouse.toml"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$leased" FM_FAKE_PANE_AFTER_EXIT="$CASE_HOME/projects/widget" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "spawn launched in the other clone's worktree"$'\n'"$out"
  assert_contains "$out" "another clone" "the refusal did not say the worktree is another clone"
  assert_contains "$out" "$leased" "the refusal did not name the worktree"
  assert_contains "$out" "$CASE_HOME/projects/widget" "the refusal did not name the spawning project"
  assert_grep "args=get --lease --lease-holder $id" "$tree_log" \
    "the fallback lease was not requested"
  assert_no_grep "args=return" "$tree_log" \
    "spawn returned a copy owned by the other clone"
  [ -d "$leased" ] || fail "spawn removed the other clone's leased copy"
  assert_no_grep "cd -- " "$pane_log" "the pane was moved into the other clone's worktree"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "refused spawn published a task record"
  pass "a configured foreign lease is refused without returning the other clone's copy"
}

test_spawn_that_stops_after_the_lease_returns_it() {
  local id=pool-lease-abort case_dir=$TMP_ROOT/spawn-abort
  local foreign own stray pane_log tree_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  own=$CASE_POOL/.treehouse/kept/1/widget
  stray=$case_dir/stray
  add_worktree "$CASE_HOME/projects/widget" "$own" "kept-$id"
  add_worktree "$CASE_HOME/projects/widget" "$stray" "stray-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$stray" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although the pane never reached its lease"$'\n'"$out"
  assert_contains "$out" "instead of the leased worktree" \
    "the stop did not say the pane missed the leased worktree"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "a stopped spawn published a task record"
  assert_exact_line "args=return --force $own" "$tree_log" \
    "a launch that stopped before publishing its record left its lease behind"
  assert_exact_line "$(printf 'call=return --force %s\t%s' "$own" "$CASE_HOME/projects/widget")" "$tree_log" \
    "the lease was not returned from the project clone that acquired it"
  pass "a launch that stops after leasing returns the lease"
}

test_spawn_abort_preserves_uncommitted_and_unlanded_leases() {
  local kind id case_dir foreign own stray pane_log tree_log out status head after_exit
  for kind in dirty unlanded; do
    id=pool-lease-abort-$kind
    case_dir=$TMP_ROOT/spawn-abort-$kind
    prepare_spawn_home "$case_dir" "$id"
    foreign=$case_dir/shared-pool/1/widget
    own=$CASE_POOL/.treehouse/kept/1/widget
    stray=$case_dir/stray
    add_worktree "$case_dir/other/projects/widget" "$foreign"
    add_worktree "$CASE_HOME/projects/widget" "$own" "kept-$id"
    add_worktree "$CASE_HOME/projects/widget" "$stray" "stray-$id"
    printf 'work that must survive\n' >> "$own/README.md"
    if [ "$kind" = unlanded ]; then
      git -C "$own" add README.md
      git -C "$own" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
        commit -qm 'unlanded work'
    fi
    head=$(git -C "$own" rev-parse HEAD)
    pane_log=$case_dir/pane.log
    tree_log=$case_dir/treehouse.log
    : > "$pane_log"
    : > "$tree_log"
    status=0
    # Dirty leases reach the real base-refresh refusal; committed leases abort
    # on the pane handoff before base refresh can change their branch.
    after_exit=$own
    [ "$kind" != unlanded ] || after_exit=$stray
    out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
      FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$after_exit" \
      FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
    [ "$status" -ne 0 ] || fail "spawn succeeded instead of aborting the $kind lease"$'\n'"$out"
    if [ "$kind" = dirty ]; then
      assert_contains "$out" "refusing to discard uncommitted work" \
        "the dirty lease did not reach the base-refresh refusal"
    fi
    assert_no_grep "args=return" "$tree_log" "abort returned a lease with $kind work"
    assert_contains "$out" "leaving per-home treehouse lease at '$own' in place" \
      "abort did not identify the preserved $kind lease"
    assert_grep "work that must survive" "$own/README.md" "abort lost the $kind work"
    assert_equals "$head" "$(git -C "$own" rev-parse HEAD)" "abort changed the $kind lease's HEAD"
    [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "aborted $kind lease published a task record"
  done
  pass "abort preserves leases with uncommitted or unlanded work"
}

test_spawn_keeps_worker_edits_after_readiness_failure_closes_endpoint() {
  local id=pool-closed-worker case_dir=$TMP_ROOT/spawn-closed-worker
  local foreign own pane_log tree_log close_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  fm_fake_exit0 "$CASE_FAKEBIN" rovo
  foreign=$case_dir/shared-pool/1/widget
  own=$CASE_POOL/.treehouse/kept/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  add_worktree "$CASE_HOME/projects/widget" "$own" "kept-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  close_log=$case_dir/closed.log
  : > "$pane_log"
  : > "$tree_log"
  : > "$close_log"
  # The fake worker edits its checkout when the launch is sent. Empty pane
  # captures then fail Rovo's real readiness gate and close that endpoint.
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$own" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" FM_FAKE_WORKER_EDIT_PATH="$own" \
    FM_FAKE_ENDPOINT_CLOSE_LOG="$close_log" FM_ROVO_READY_POLLS=3 FM_ROVO_POLL_INTERVAL=0 \
    run_spawn "$foreign" "$id" --harness rovo) || status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite the failed readiness gate"$'\n'"$out"
  assert_contains "$out" "rovo did not show a verified ready signal" "readiness gate did not fail"
  assert_grep "kill-window" "$close_log" "the launched endpoint was not closed"
  assert_grep "worker work that must survive" "$own/README.md" "closed endpoint lost worker edits"
  assert_no_grep "args=return" "$tree_log" "closed endpoint caused the worker lease to be returned"
  assert_contains "$out" "a worker was launched; preserve its work for teardown" \
    "abort did not explain why the worker lease was preserved"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "readiness failure retained the task record"
  pass "readiness failure closes the worker endpoint while preserving its work"
}

test_spawn_keeps_lease_after_dispatch_rollback_with_open_endpoint() {
  local id=pool-dispatch-rollback case_dir=$TMP_ROOT/spawn-dispatch-rollback
  local foreign own pane_log launch_log tree_log start_log out status=0
  local real_tasks_axi
  if ! real_tasks_axi=$(command -v tasks-axi); then
    printf '%s\n' 'ok - skipped dispatch rollback (tasks-axi is not installed)'
    return
  fi
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  own=$CASE_POOL/.treehouse/kept/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  add_worktree "$CASE_HOME/projects/widget" "$own" "kept-$id"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$CASE_HOME/data/backlog.md"
  cat > "$CASE_HOME/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  tasks-axi add "$id" "item for $id" --kind ship \
    --file "$CASE_HOME/data/backlog.md" >/dev/null || fail "could not add dispatch backlog item"
  cat > "$CASE_FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = start ]; then
  printf '%s\n' "$*" >> "$FM_TEST_START_LOG"
  echo 'error: backlog transition refused' >&2
  exit 1
fi
exec "$FM_TEST_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$CASE_FAKEBIN/tasks-axi"
  pane_log=$case_dir/pane.log
  launch_log=$case_dir/launch.log
  tree_log=$case_dir/treehouse.log
  start_log=$case_dir/start.log
  : > "$pane_log"
  : > "$launch_log"
  : > "$tree_log"
  : > "$start_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_LAUNCH_LOG="$launch_log" \
    FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$own" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" FM_TEST_START_LOG="$start_log" \
    FM_TEST_REAL_TASKS_AXI="$real_tasks_axi" run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded after dispatch rollback"$'\n'"$out"
  assert_contains "$out" "could not be moved to In flight" \
    "spawn did not report the failed dispatch"
  assert_equals 2 "$(wc -l < "$start_log" | tr -d ' ')" \
    "dispatch was not retried before rollback"
  assert_grep "launch." "$launch_log" "the worker launch was not sent before rollback"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "rollback retained the task record"
  [ -d "$own" ] || fail "rollback removed the worker's leased worktree"
  assert_no_grep "args=return --force $own" "$tree_log" \
    "rollback returned a lease while its worker endpoint remained open"
  pass "dispatch rollback leaves an open worker endpoint's lease intact"
}

test_spawn_keeps_the_shared_copy_of_its_own_clone() {
  local id=pool-owned case_dir=$TMP_ROOT/spawn-owned
  local own pane_log tree_log out status
  prepare_spawn_home "$case_dir" "$id"
  own=$case_dir/shared-pool/1/widget
  add_worktree "$CASE_HOME/projects/widget" "$own" "own-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" run_spawn "$own" "$id")
  status=$?
  expect_code 0 "$status" "a copy of this clone should launch from the shared pool"$'\n'"$out"
  assert_grep ' && treehouse get' "$pane_log" \
    "the launch did not check the pool in the pane before get"
  assert_no_exact_line "exit" "$pane_log" "the launch left a copy of its own clone"
  [ ! -s "$tree_log" ] || fail "a copy of this clone still called treehouse itself: $(cat "$tree_log")"
  assert_grep "worktree=$own" "$CASE_HOME/state/$id.meta" "spawn did not record the shared copy"
  [ ! -e "$CASE_POOL" ] || fail "a launch that needed no pool of its own created one"
  pass "a shared copy of the spawning clone is kept"
}

test_claude_relaunch_refuses_a_recorded_copy_of_another_clone() {
  local id=pool-foreign-relaunch case_dir=$TMP_ROOT/spawn-foreign-relaunch
  local foreign pane_log tree_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  {
    printf 'window=fake:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$foreign"
    printf 'project=%s\n' "$CASE_HOME/projects/widget"
    printf 'harness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'branch=fm/%s\n' "$id"
  } > "$CASE_HOME/state/$id.meta"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  fm_fake_exit0 "$CASE_FAKEBIN" claude
  out=$(FM_FAKE_RELAUNCH_WINDOW="fm-$id" FM_FAKE_PANE_LOG="$pane_log" \
    FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    fm_test_run_spawn "$CASE_HOME" "$foreign" "$CASE_FAKEBIN" "$id" --relaunch --harness claude) || status=$?
  [ "$status" -ne 0 ] || fail "Claude relaunched in a copy of another clone"$'\n'"$out"
  assert_contains "$out" "Claude relaunch refused" "the refusal did not name the Claude relaunch"
  assert_contains "$out" "$foreign" "the refusal did not name the recorded worktree"
  assert_contains "$out" "$CASE_HOME/projects/widget" "the refusal did not name the recorded project"
  [ ! -s "$pane_log" ] || fail "the refused relaunch sent a command to the pane"
  [ ! -s "$tree_log" ] || fail "the refused relaunch touched a treehouse pool"
  pass "Claude relaunch refuses a foreign recorded copy before launch"
}

# Lease from a home's own pool with the real binary. The clone's origin is an
# alias only the operator's global git configuration rewrites to the real
# repository, so the fetch treehouse runs succeeds only when its git still
# reads the operator's HOME. Skips with a visible line when the binary is not
# installed.
test_real_treehouse_leases_from_the_homes_own_pool_with_the_operators_git() {
  local root operator state home clone url pool private before after trust
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "# skip real-treehouse: treehouse is not installed"
    return 0
  fi
  # Treehouse detaches an update check that rewrites HOME/.treehouse after the
  # command exits. That child recreates the scratch pool while fixture cleanup
  # is removing it. The variable is treehouse's own off switch.
  export TREEHOUSE_NO_UPDATE_CHECK=1
  root=$TMP_ROOT/real
  operator=$root/operator
  state=$root/xdg-state
  mkdir -p "$operator" "$state"
  # A scratch state directory sitting inside some other checkout must not let
  # treehouse append its pool to that checkout's gitignore.
  if git -C "$state" rev-parse --show-toplevel >/dev/null 2>&1; then
    git init -q -b main "$state"
  fi
  before=$(git -C "$ROOT" status --porcelain)
  url=$(make_same_origin_clones "$root/clones")
  home=$root/clones/homeB
  clone=$home/projects/widget
  git -C "$clone" remote set-url origin fm-operator-only:widget
  git config --file "$operator/.gitconfig" "url.$url.insteadOf" fm-operator-only:widget
  pool=$(FM_TEST_XDG_STATE="$state" lib "$home" "$operator" fm_treehouse_home_pool "$home") \
    || fail "the home's own pool could not be resolved"
  private=$(cd "$clone" && FM_TEST_XDG_STATE="$state" lib "$home" "$operator" \
    fm_treehouse_home_pool_run "$home" 120 get --lease --lease-holder per-home) \
    || fail "the lease from the home's own pool failed; its fetch needs the operator's git configuration"
  [ -d "$private" ] || fail "the lease did not print a worktree directory: $private"
  lib "$home" "$operator" fm_treehouse_same_clone "$clone" "$private" \
    || fail "the lease was not a worktree of the spawning clone"
  case "$private" in
    "$pool/.treehouse/"*) ;;
    *) fail "the lease was not under the home's own pool $pool: $private" ;;
  esac
  assert_outside "$private" "$home" "the leased worktree is inside the Firstmate home"
  assert_outside "$private" "$clone" "the leased worktree is inside the project clone"
  if command -v node >/dev/null 2>&1; then
    trust=$(HOME="$operator" CLAUDE_CONFIG_DIR='' "$ROOT/bin/fm-claude-trust.sh" "$private" "$clone" 2>&1) \
      || fail "Claude workspace trust did not register for the leased worktree: $trust"
  fi
  (cd "$clone" && env HOME="$operator" treehouse return --force "$private" >/dev/null) \
    || fail "the lease could not be returned the way cleanup returns it"
  after=$(git -C "$ROOT" status --porcelain)
  [ "$before" = "$after" ] || fail "treehouse changed the firstmate worktree"
  pass "real treehouse leases from the home's own pool and fetches as the operator"
}

test_shasum_only_path_names_the_pool_from_the_home() {
  local root=$TMP_ROOT/shasum-only user home binpool cmd target out rc=0
  local physical hash base
  user=$root/user
  home=$root/crew
  binpool=$root/bin
  mkdir -p "$home" "$user" "$binpool"
  for cmd in bash env uname mkdir awk basename shasum; do
    target=$(command -v "$cmd") || fail "$cmd is not installed"
    ln -s "$target" "$binpool/$cmd"
  done
  if PATH="$binpool" command -v sha256sum >/dev/null 2>&1; then
    fail "sha256sum is still visible on the shasum-only path"
  fi
  out=$(PATH="$binpool" lib "$home" "$user" fm_treehouse_home_pool "$home") || rc=$?
  expect_code 0 "$rc" "the pool could not be named with only shasum"$'\n'"$out"
  physical=$(CDPATH='' cd -- "$home" && pwd -P)
  hash=$(printf '%s' "$physical" | shasum -a 256 | awk '{ print substr($1, 1, 6) }')
  base=$(basename -- "$physical")
  assert_equals "$user/.local/state/firstmate/${base}-$hash" "$out" \
    "the shasum-only pool did not use shasum of the physical home path"
  pass "a path with only shasum still names the pool from the home path"
}

test_initial_get_checks_returned_worktree() {
  local variant id case_dir allocated reported pane_log tree_log lease fail_cwd hold_return complete_on_sleep override_root out status
  for variant in inside outside unconfirmed pending; do
    id="pool-placement-initial-$variant"
    case_dir=$TMP_ROOT/$id
    CASE_URL=$(make_same_origin_clones "$case_dir/origin")
    prepare_spawn_home "$case_dir" "$id"
    if [ "$variant" != outside ]; then
      allocated=$CASE_HOME/worktrees/1/widget
    else
      allocated=$case_dir/external-pool/1/widget
    fi
    reported=$allocated
    if [ "$variant" = inside ]; then
      reported=$case_dir/allocated-link
      ln -s "$allocated" "$reported"
    fi
    pane_log=$case_dir/pane.log
    tree_log=$case_dir/treehouse.log
    lease=$case_dir/initial-lease
    fail_cwd=
    [ "$variant" != unconfirmed ] || fail_cwd=1
    hold_return=
    [ "$variant" != pending ] || hold_return=1
    complete_on_sleep=
    case "$variant" in inside) complete_on_sleep=1 ;; esac
    override_root=
    [ "$variant" != outside ] || override_root=$CASE_HOME/ignored-treehouse-root
    : > "$pane_log"
    : > "$tree_log"
    status=0
    out=$(TREEHOUSE_ROOT="${override_root:-}" FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
      FM_FAKE_TREEHOUSE_INITIAL_PATH="$allocated" \
      FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$CASE_HOME/projects/widget" \
      FM_FAKE_TREEHOUSE_INITIAL_LEASE="$lease" FM_FAKE_CWD_FAIL_AFTER_EXIT="$fail_cwd" \
      FM_FAKE_TREEHOUSE_DELAY_RETURN=1 FM_FAKE_TREEHOUSE_HOLD_RETURN="$hold_return" \
      FM_FAKE_TREEHOUSE_COMPLETE_ON_SLEEP="$complete_on_sleep" \
      FM_FAKE_PANE_AFTER_EXIT="$CASE_HOME/projects/widget" FM_FAKE_EXIT_FLAG="$case_dir/exited" \
      run_spawn "$reported" "$id") || status=$?
    assert_grep ' && treehouse get' "$pane_log" \
      "$variant: initial get did not follow an in-pane pool check"
    [ -d "$allocated" ] || fail "$variant: fake Treehouse did not allocate a worktree"
    if [ "$variant" = inside ]; then
      [ "$status" -ne 0 ] || fail "inside: spawn accepted the allocated worktree"$'\n'"$out"
      assert_contains "$out" "allocated worktree $allocated is inside Firstmate home" \
        "$variant: refusal did not resolve the allocated path"
      assert_exact_line 'exit' "$pane_log" "inside: allocated copy was not returned"
      [ "$(grep -Fxc 'args=status' "$tree_log")" -ge 2 ] \
        || fail "inside: return was accepted before Treehouse finished releasing the copy"
      assert_exact_line 'args=fake-complete-return' "$tree_log" \
        "$variant: no separate return completion was submitted"
      [ ! -e "$lease" ] || fail "inside: fake Treehouse lease remained active"
      [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "inside: refusal published a task"
    elif [ "$variant" = unconfirmed ]; then
      [ "$status" -ne 0 ] || fail "unconfirmed: spawn accepted the allocated worktree"$'\n'"$out"
      assert_contains "$out" "worktree '$reported' was not confirmed returned" \
        "unconfirmed: missing return warning"
      assert_exact_line 'exit' "$pane_log" "unconfirmed: return was not attempted"
      assert_no_exact_line 'args=status' "$tree_log" \
        "unconfirmed: queried status without evidence that the pane left"
      [ -f "$lease" ] || fail "unconfirmed: fake Treehouse lease was unexpectedly released"
      [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "unconfirmed: refusal published a task"
    elif [ "$variant" = pending ]; then
      [ "$status" -ne 0 ] || fail "pending: spawn accepted the allocated worktree"$'\n'"$out"
      assert_contains "$out" "worktree '$reported' was not confirmed returned" \
        "pending: missing warning while Treehouse still held the copy"
      assert_exact_line 'exit' "$pane_log" "pending: return was not attempted"
      assert_exact_line 'args=status' "$tree_log" \
        "pending: Treehouse status was not checked"
      assert_no_exact_line 'args=fake-complete-return' "$tree_log" \
        "pending: a return completion was submitted"
      [ -f "$lease" ] || fail "pending: fake Treehouse lease was unexpectedly released"
      [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "pending: refusal published a task"
    else
      expect_code 0 "$status" "outside: safe allocation was refused"$'\n'"$out"
      assert_no_exact_line 'exit' "$pane_log" "outside: safe copy was returned"
      [ -f "$lease" ] || fail "outside: fake Treehouse lease was not retained"
      assert_grep "worktree=$allocated" "$CASE_HOME/state/$id.meta" \
        "outside: spawn did not use the allocated copy"
    fi
  done
  pass "initial get releases refused copies and reports unconfirmed returns"
}

test_pool_preflight_refuses_initial_get() {
  local variant id case_dir pane_log tree_log pool allocated lease out status
  for variant in user-config linked-default repo-config repo-relative; do
    id="pool-preflight-initial-$variant"
    case_dir=$TMP_ROOT/$id
    CASE_URL=$(make_same_origin_clones "$case_dir/origin")
    prepare_spawn_home "$case_dir" "$id"
    pool=$CASE_HOME/unsafe-pool
    case "$variant" in
      user-config)
        mkdir -p "$CASE_USER_HOME/.config/treehouse"
        printf 'root = "%s"\n' "$pool" > "$CASE_USER_HOME/.config/treehouse/config.toml"
        ;;
      linked-default)
        mkdir -p "$pool"
        ln -s "$pool" "$CASE_USER_HOME/.treehouse"
        ;;
      repo-config)
        mkdir -p "$CASE_USER_HOME/.config/treehouse"
        printf 'root = "%s"\n' "$case_dir/safe-pool" > "$CASE_USER_HOME/.config/treehouse/config.toml"
        printf 'root = "%s"\n' "$pool" > "$CASE_HOME/projects/widget/treehouse.toml"
        ;;
      repo-relative)
        printf 'root = "."\n' > "$CASE_HOME/projects/widget/treehouse.toml"
        ;;
    esac
    pane_log=$case_dir/pane.log
    tree_log=$case_dir/treehouse.log
    allocated=$case_dir/should-not-allocate/widget
    lease=$case_dir/should-not-lease
    : > "$pane_log"
    : > "$tree_log"
    status=0
    out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
      FM_FAKE_TREEHOUSE_INITIAL_PATH="$allocated" \
      FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$CASE_HOME/projects/widget" \
      FM_FAKE_TREEHOUSE_INITIAL_LEASE="$lease" \
      run_spawn "$CASE_HOME/projects/widget" "$id") || status=$?
    [ "$status" -ne 0 ] || fail "$variant: unsafe pool was accepted"$'\n'"$out"
    assert_contains "$out" 'treehouse pool ' "$variant: refusal did not name the pool"
    assert_contains "$out" 'is inside Firstmate home' "$variant: refusal did not name the boundary"
    assert_grep ' && treehouse get' "$pane_log" "$variant: the in-pane pool check was skipped"
    [ ! -e "$allocated" ] && [ ! -e "$lease" ] \
      || fail "$variant: initial get allocated a copy before refusal"
    [ ! -s "$tree_log" ] || fail "$variant: Treehouse was called before pool refusal"
    [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "$variant: refusal published a task"
  done
  pass "initial pool preflight uses user and repository config and resolves links"
}

test_initial_pane_environment_controls_preflight() {
  local id=pool-preflight-pane-env case_dir=$TMP_ROOT/pool-preflight-pane-env
  local pane_log tree_log allocated lease out status=0
  CASE_URL=$(make_same_origin_clones "$case_dir/origin")
  prepare_spawn_home "$case_dir" "$id"
  printf 'root = "$POOL_BASE"\n' > "$CASE_HOME/projects/widget/treehouse.toml"
  mkdir -p "$case_dir/safe-pool" "$CASE_HOME/unsafe-pool"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  allocated=$case_dir/should-not-allocate/widget
  lease=$case_dir/should-not-lease
  : > "$pane_log"
  : > "$tree_log"
  out=$(POOL_BASE="$case_dir/safe-pool" FM_FAKE_PANE_POOL_BASE="$CASE_HOME/unsafe-pool" \
    FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_INITIAL_PATH="$allocated" \
    FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$CASE_HOME/projects/widget" \
    FM_FAKE_TREEHOUSE_INITIAL_LEASE="$lease" \
    run_spawn "$CASE_HOME/projects/widget" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "pane environment's unsafe pool was accepted"$'\n'"$out"
  assert_contains "$out" "treehouse pool $CASE_HOME/unsafe-pool" \
    "refusal used the spawn environment instead of the pane environment"
  assert_grep ' && treehouse get' "$pane_log" "pane pool check was skipped"
  [ ! -e "$allocated" ] && [ ! -e "$lease" ] \
    || fail "initial get allocated a copy despite the pane's unsafe pool"
  [ ! -s "$tree_log" ] || fail "Treehouse ran after the pane refused its pool"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "pane refusal published a task"
  pass "initial pool check uses the pane's environment before get"
}

test_pool_preflight_names_required_toml_parser() {
  local id=pool-preflight-parser case_dir=$TMP_ROOT/pool-preflight-parser
  local pane_log allocated lease out status=0
  CASE_URL=$(make_same_origin_clones "$case_dir/origin")
  prepare_spawn_home "$case_dir" "$id"
  printf 'root = "%s"\n' "$case_dir/safe-pool" > "$CASE_HOME/projects/widget/treehouse.toml"
  cat > "$case_dir/sitecustomize.py" <<'PY'
import builtins

original_import = builtins.__import__

def deny_tomllib(name, *args, **kwargs):
    if name == "tomllib":
        raise ImportError("tomllib unavailable")
    return original_import(name, *args, **kwargs)

builtins.__import__ = deny_tomllib
PY
  pane_log=$case_dir/pane.log
  allocated=$case_dir/should-not-allocate/widget
  lease=$case_dir/should-not-lease
  : > "$pane_log"
  out=$(PYTHONPATH="$case_dir" FM_FAKE_PANE_LOG="$pane_log" \
    FM_FAKE_TREEHOUSE_INITIAL_PATH="$allocated" \
    FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$CASE_HOME/projects/widget" \
    FM_FAKE_TREEHOUSE_INITIAL_LEASE="$lease" \
    run_spawn "$CASE_HOME/projects/widget" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a configured pool without tomllib"$'\n'"$out"
  assert_contains "$out" 'python3 with tomllib is required to verify the treehouse pool location' \
    "missing parser refusal did not name the requirement"
  [ ! -e "$allocated" ] && [ ! -e "$lease" ] \
    || fail "get allocated a copy without a verified TOML pool"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "parser refusal published a task"
  pass "configured pool refusal names the required TOML parser"
}

test_pool_preflight_refuses_fallback_get() {
  local id=pool-preflight-fallback case_dir=$TMP_ROOT/pool-preflight-fallback
  local foreign pane_log tree_log initial_lease out status=0
  CASE_URL=$(make_same_origin_clones "$case_dir/origin")
  prepare_spawn_home "$case_dir" "$id"
  CASE_STATE=$CASE_HOME/state/unsafe-pool
  foreign=$case_dir/shared-pool/1/widget
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  initial_lease=$case_dir/initial-lease
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_INITIAL_PATH="$foreign" \
    FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$case_dir/other/projects/widget" \
    FM_FAKE_TREEHOUSE_INITIAL_LEASE="$initial_lease" \
    FM_FAKE_PANE_AFTER_EXIT="$CASE_HOME/projects/widget" \
    FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "unsafe fallback pool was accepted"$'\n'"$out"
  assert_contains "$out" 'treehouse pool ' "fallback refusal did not name the pool"
  assert_contains "$out" 'is inside Firstmate home' "fallback refusal did not name the boundary"
  assert_grep ' && treehouse get' "$pane_log" "initial get was skipped"
  assert_exact_line 'exit' "$pane_log" "foreign copy was not exited"
  assert_no_exact_line "args=get --lease --lease-holder $id" "$tree_log" \
    "fallback get was called for an unsafe pool"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "fallback refusal published a task"
  pass "fallback pool preflight refuses before leasing"
}

test_pool_preflight_uses_operator_git_for_fallback_hash() {
  local id=pool-preflight-fallback-hash case_dir=$TMP_ROOT/pool-preflight-fallback-hash
  local project foreign pane_log tree_log linked_pool operator_origin synthetic_origin out status=0
  CASE_URL=$(make_same_origin_clones "$case_dir/origin")
  prepare_spawn_home "$case_dir" "$id"
  project=$CASE_HOME/projects/widget
  git -C "$project" remote set-url origin fm-operator-only:widget
  git config --file "$CASE_USER_HOME/.gitconfig" "url.$CASE_URL.insteadOf" fm-operator-only:widget
  operator_origin=$(env -u GIT_CONFIG_GLOBAL HOME="$CASE_USER_HOME" git -C "$project" remote get-url origin)
  synthetic_origin=$(env -u GIT_CONFIG_GLOBAL HOME="$CASE_POOL" git -C "$project" remote get-url origin)
  assert_equals "$CASE_URL" "$operator_origin" "operator Git did not rewrite the origin"
  assert_equals 'fm-operator-only:widget' "$synthetic_origin" \
    "synthetic Git unexpectedly read the operator rewrite"
  linked_pool=$CASE_POOL/.treehouse/widget-$(pool_hash6 "$operator_origin")
  mkdir -p "$CASE_POOL/.treehouse" "$CASE_HOME/unsafe-pool"
  ln -s "$CASE_HOME/unsafe-pool" "$linked_pool"
  foreign=$case_dir/shared-pool/1/widget
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_INITIAL_PATH="$foreign" \
    FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$case_dir/other/projects/widget" \
    FM_FAKE_TREEHOUSE_INITIAL_LEASE="$case_dir/initial-lease" \
    FM_FAKE_PANE_AFTER_EXIT="$project" FM_FAKE_EXIT_FLAG="$case_dir/exited" \
    run_spawn "$foreign" "$id") || status=$?
  [ "$status" -ne 0 ] || fail "rewritten fallback pool was accepted"$'\n'"$out"
  assert_contains "$out" "treehouse pool $CASE_HOME/unsafe-pool" \
    "fallback preflight hashed the origin with synthetic Git HOME"
  assert_grep ' && treehouse get' "$pane_log" \
    "initial get did not follow an in-pane pool check"
  assert_no_exact_line "args=get --lease --lease-holder $id" "$tree_log" \
    "fallback get was called before the rewritten pool was refused"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "fallback refusal published a task"
  pass "fallback preflight hashes the origin with the operator Git HOME"
}

test_fake_treehouse_return_requires_submission_and_completion() {
  local id=pool-fake-return-state case_dir=$TMP_ROOT/fake-return-state
  local allocated lease pane_log tree_log exit_flag output
  local -a fake
  CASE_URL=$(make_same_origin_clones "$case_dir/origin")
  prepare_spawn_home "$case_dir" "$id"
  allocated=$CASE_HOME/worktrees/1/widget
  lease=$case_dir/initial-lease
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  exit_flag=$case_dir/exited
  : > "$pane_log"
  : > "$tree_log"
  fake=(env HOME="$CASE_USER_HOME" PATH="$CASE_FAKEBIN:$PATH" \
    FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_INITIAL_PATH="$allocated" \
    FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$CASE_HOME/projects/widget" \
    FM_FAKE_TREEHOUSE_INITIAL_LEASE="$lease" FM_FAKE_EXIT_FLAG="$exit_flag" \
    FM_FAKE_TREEHOUSE_DELAY_RETURN=1)
  "${fake[@]}" tmux send-keys -t fake 'treehouse get'
  [ ! -e "$lease" ] || fail "typing get without Enter allocated a copy"
  "${fake[@]}" tmux send-keys -t fake Enter
  [ -f "$lease" ] || fail "submitted get did not allocate a copy"
  "${fake[@]}" tmux send-keys -t fake exit
  [ ! -e "$exit_flag" ] || fail "typing exit without Enter left the copy"
  if "${fake[@]}" treehouse fake-complete-return >/dev/null 2>&1; then
    fail "return completion succeeded before exit was submitted"
  fi
  [ -f "$lease" ] || fail "unsubmitted exit released the copy"
  "${fake[@]}" tmux send-keys -t fake Enter
  [ -f "$exit_flag" ] && [ -f "$lease" ] \
    || fail "submitted exit did not leave the lease pending confirmation"
  output=$("${fake[@]}" treehouse status)
  assert_contains "$output" 'in-use' "plain status did not report the pending lease"
  [ -f "$lease" ] || fail "reading status released the copy"
  "${fake[@]}" treehouse fake-complete-return
  [ ! -e "$lease" ] || fail "explicit return completion did not release the copy"
  output=$("${fake[@]}" treehouse status)
  assert_contains "$output" 'available' "plain status did not report the released copy"
  pass "the fake requires submitted commands and a separate return completion"
}

test_fallback_lease_checks_returned_worktree() {
  local variant id case_dir foreign allocated after_exit pane_log tree_log initial_lease fallback_lease out status
  for variant in inside outside; do
    id="pool-placement-fallback-$variant"
    case_dir=$TMP_ROOT/$id
    CASE_URL=$(make_same_origin_clones "$case_dir/origin")
    prepare_spawn_home "$case_dir" "$id"
    foreign=$case_dir/shared-pool/1/widget
    if [ "$variant" = inside ]; then
      allocated=$CASE_HOME/worktrees/1/widget
      after_exit=$CASE_HOME/projects/widget
    else
      allocated=$CASE_POOL/.treehouse/kept/1/widget
      after_exit=$allocated
    fi
    pane_log=$case_dir/pane.log
    tree_log=$case_dir/treehouse.log
    initial_lease=$case_dir/initial-lease
    fallback_lease=$case_dir/fallback-lease
    : > "$pane_log"
    : > "$tree_log"
    status=0
    out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
      FM_FAKE_TREEHOUSE_INITIAL_PATH="$foreign" \
      FM_FAKE_TREEHOUSE_INITIAL_PROJECT="$case_dir/other/projects/widget" \
      FM_FAKE_TREEHOUSE_INITIAL_LEASE="$initial_lease" \
      FM_FAKE_TREEHOUSE_FALLBACK_LEASE="$fallback_lease" \
      FM_FAKE_TREEHOUSE_PRINT="$allocated" FM_FAKE_PANE_AFTER_EXIT="$after_exit" \
      FM_FAKE_EXIT_FLAG="$case_dir/exited" run_spawn "$foreign" "$id") || status=$?
    [ -d "$foreign" ] && [ -d "$allocated" ] || fail "$variant: fake Treehouse did not allocate both copies"
    [ ! -e "$initial_lease" ] || fail "$variant: foreign interactive lease was not released"
    assert_exact_line "args=get --lease --lease-holder $id" "$tree_log" \
      "$variant: fallback lease was not requested"
    if [ "$variant" = inside ]; then
      [ "$status" -ne 0 ] || fail "inside: spawn accepted the leased worktree"$'\n'"$out"
      assert_contains "$out" "allocated worktree $allocated is inside Firstmate home" \
        "inside: fallback refusal did not name the allocated copy"
      assert_exact_line "args=return --force $allocated" "$tree_log" \
        "inside: untouched fallback lease was not returned"
      [ ! -e "$fallback_lease" ] || fail "inside: fake Treehouse fallback lease remained active"
      assert_no_grep 'cd -- ' "$pane_log" "inside: pane entered the refused lease"
      [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "inside: refusal published a task"
    else
      expect_code 0 "$status" "outside: safe fallback was refused"$'\n'"$out"
      assert_no_grep "args=return --force $allocated" "$tree_log" \
        "outside: safe fallback lease was returned"
      [ -f "$fallback_lease" ] || fail "outside: fake Treehouse fallback lease was not retained"
      assert_grep "worktree=$allocated" "$CASE_HOME/state/$id.meta" \
        "outside: spawn did not use the fallback lease"
    fi
  done
  pass "fallback lease checks the returned path and releases unsafe copies"
}

test_initial_get_checks_returned_worktree
test_pool_preflight_refuses_initial_get
test_initial_pane_environment_controls_preflight
test_pool_preflight_names_required_toml_parser
test_pool_preflight_refuses_fallback_get
test_pool_preflight_uses_operator_git_for_fallback_hash
test_fake_treehouse_return_requires_submission_and_completion
test_fallback_lease_checks_returned_worktree
test_two_clones_of_one_origin_do_not_treat_each_others_slot_as_their_own
test_a_homes_own_pool_is_outside_the_home_and_the_clone_and_unique_per_home
test_shasum_only_path_names_the_pool_from_the_home
test_spawn_handed_the_other_clones_copy_leases_this_homes_own_worktree
test_spawn_labels_treehouses_own_error_when_the_lease_fails
test_spawn_refuses_a_configured_foreign_lease_without_returning_it
test_spawn_that_stops_after_the_lease_returns_it
test_spawn_abort_preserves_uncommitted_and_unlanded_leases
test_spawn_keeps_worker_edits_after_readiness_failure_closes_endpoint
test_spawn_keeps_lease_after_dispatch_rollback_with_open_endpoint
test_spawn_keeps_the_shared_copy_of_its_own_clone
test_claude_relaunch_refuses_a_recorded_copy_of_another_clone
test_real_treehouse_leases_from_the_homes_own_pool_with_the_operators_git

echo "# all fm-shared-pool-trust tests passed"
