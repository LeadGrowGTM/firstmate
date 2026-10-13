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
    if [ -n "${FM_FAKE_PANE_AFTER_EXIT:-}" ] && [ -n "${FM_FAKE_EXIT_FLAG:-}" ] \
      && [ -f "$FM_FAKE_EXIT_FLAG" ]; then
      printf '%s\n' "$FM_FAKE_PANE_AFTER_EXIT"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *)
            [ -n "$literal" ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG"
            if [ "$a" = exit ] && [ -n "${FM_FAKE_EXIT_FLAG:-}" ]; then
              : > "$FM_FAKE_EXIT_FLAG"
            fi
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
case "$*" in
  'get --lease --lease-holder '*)
    printf 'gitmarker=%s\n' "$(git config --global --get fm.marker 2>/dev/null)" >> "$log"
    echo "fake treehouse lease progress" >&2
    [ -z "${FM_FAKE_TREEHOUSE_LEASE_RC:-}" ] || exit "$FM_FAKE_TREEHOUSE_LEASE_RC"
    printf '%s\n' "${FM_FAKE_TREEHOUSE_PRINT:-}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_test_fake_sleep_noop "$fakebin"
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
  CASE_FAKEBIN=$(make_pool_fakebin "$case_dir/fake")
  CASE_STATE=$case_dir/xdg-state
  fm_test_spawn_home "$CASE_HOME" codex
  fm_test_spawn_brief "$CASE_HOME" "$id" "Launch widget from this home's own clone."
  mkdir -p "$case_dir/other/projects" "$CASE_HOME/projects" "$CASE_HOME/user-home"
  git clone -q "$CASE_URL" "$case_dir/other/projects/widget"
  git clone -q "$CASE_URL" "$CASE_HOME/projects/widget"
  git config --file "$CASE_HOME/user-home/.gitconfig" fm.marker operator
  CASE_POOL=$(FM_TEST_XDG_STATE="$CASE_STATE" lib "$CASE_HOME" "$CASE_HOME/user-home" \
    fm_treehouse_home_pool "$CASE_HOME") || fail "the case's pool could not be resolved"
}

# run_spawn <pane> <id>: one launch of widget from CASE_HOME.
run_spawn() {
  (
    unset GIT_CONFIG_GLOBAL
    XDG_STATE_HOME="$CASE_STATE" \
      fm_test_run_spawn "$CASE_HOME" "$1" "$CASE_FAKEBIN" "$2" "$CASE_HOME/projects/widget" \
      --mode no-mistakes --yolo off
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
  assert_exact_line "treehouse get" "$pane_log" "spawn did not ask the shared pool first"
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

test_spawn_refuses_a_leased_worktree_of_the_other_clone() {
  local id=pool-foreign-refuse case_dir=$TMP_ROOT/spawn-refuse
  local foreign leased pane_log tree_log out status=0
  prepare_spawn_home "$case_dir" "$id"
  foreign=$case_dir/shared-pool/1/widget
  leased=$case_dir/shared-pool/2/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  add_worktree "$case_dir/other/projects/widget" "$leased"
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
  assert_exact_line "args=return --force $leased" "$tree_log" \
    "the lease this spawn took was not returned"
  assert_no_grep "cd -- " "$pane_log" "the pane was moved into the other clone's worktree"
  [ ! -e "$CASE_HOME/state/$id.meta" ] || fail "refused spawn published a task record"
  pass "a lease of the other clone is returned and the launch stops"
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
  pass "a launch that stops after leasing returns the lease"
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
  assert_exact_line "treehouse get" "$pane_log" "the launch did not send treehouse get"
  assert_no_exact_line "exit" "$pane_log" "the launch left a copy of its own clone"
  [ ! -s "$tree_log" ] || fail "a copy of this clone still called treehouse itself: $(cat "$tree_log")"
  assert_grep "worktree=$own" "$CASE_HOME/state/$id.meta" "spawn did not record the shared copy"
  [ ! -e "$CASE_POOL" ] || fail "a launch that needed no pool of its own created one"
  pass "a shared copy of the spawning clone is kept"
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

test_two_clones_of_one_origin_do_not_treat_each_others_slot_as_their_own
test_a_homes_own_pool_is_outside_the_home_and_the_clone_and_unique_per_home
test_shasum_only_path_names_the_pool_from_the_home
test_spawn_handed_the_other_clones_copy_leases_this_homes_own_worktree
test_spawn_labels_treehouses_own_error_when_the_lease_fails
test_spawn_refuses_a_leased_worktree_of_the_other_clone
test_spawn_that_stops_after_the_lease_returns_it
test_spawn_keeps_the_shared_copy_of_its_own_clone
test_real_treehouse_leases_from_the_homes_own_pool_with_the_operators_git

echo "# all fm-shared-pool-trust tests passed"
