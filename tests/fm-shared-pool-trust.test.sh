#!/usr/bin/env bash
# Two homes cloning one origin must not launch in each other's treehouse slot.
#
# Treehouse keys its default pool by directory name plus origin, then reuses an
# idle slot whoever created it. These cases build that shape under a temp root
# and drive bin/fm-spawn.sh and bin/fm-treehouse-guard.sh. A machine with the
# treehouse binary also checks that the pool path we predict is the one
# treehouse creates. Nothing here touches a real home or ~/.treehouse.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-shared-pool-trust)

# lib <fm-home> <user-home> <function> [args...]
# Sources the wake library against the temp home so its source-time state
# directory is not a real Firstmate home.
lib() {
  local home=$1 user_home=$2
  shift 2
  mkdir -p "$home/state" "$user_home"
  # shellcheck disable=SC2016 # $1 and $@ expand in the child shell, not here.
  env HOME="$user_home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
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
# Treehouse logs HOME and argv, and `get --lease` prints FM_FAKE_TREEHOUSE_PRINT.
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
  local root=$TMP_ROOT/pair user url pool hash slot_a own_b
  root=$TMP_ROOT/pair
  user=$root/user-home
  url=$(make_same_origin_clones "$root")
  hash=$(printf '%s' "$url" | sha256sum | awk '{ print substr($1, 1, 6) }')
  pool=$(lib "$root/homeB" "$user" fm_treehouse_default_pool_dir "$root/homeB/projects/widget")
  assert_equals "widget-$hash" "$(basename -- "$pool")" \
    "pool name was not the directory name plus the origin hash"
  assert_equals "$user/.treehouse/widget-$hash" "$pool" \
    "an unconfigured pool was not under the user home"
  slot_a=$pool/1/widget
  add_worktree "$root/homeA/projects/widget" "$slot_a"
  lib "$root/homeB" "$user" fm_treehouse_pool_is_foreign "$root/homeB/projects/widget" \
    || fail "home B did not see a pool of only home A's copy as foreign"
  if lib "$root/homeA" "$user" fm_treehouse_pool_is_foreign "$root/homeA/projects/widget"; then
    fail "home A treated its own copy as a foreign pool"
  fi
  lib "$root/homeB" "$user" fm_treehouse_same_clone \
    "$root/homeB/projects/widget" "$slot_a" \
    && fail "home B accepted home A's slot as its own clone"
  own_b=$root/own-b
  add_worktree "$root/homeB/projects/widget" "$own_b" own-b
  lib "$root/homeB" "$user" fm_treehouse_same_clone \
    "$root/homeB/projects/widget" "$own_b" \
    || fail "home B rejected a worktree of its own clone"
  # A pool that already holds this clone stays on the shared path even if it
  # also holds the other clone.
  add_worktree "$root/homeB/projects/widget" "$pool/2/widget" shared-b
  if lib "$root/homeB" "$user" fm_treehouse_pool_is_foreign "$root/homeB/projects/widget"; then
    fail "a mixed pool was treated as foreign"
  fi
  pass "two clones of one origin disagree about whose pool slot it is"
}

prepare_spawn_home() {  # <case> <id>
  local case_dir=$1 id=$2 home fakebin
  home=$case_dir/home
  fakebin=$(make_pool_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" "Launch widget from this home's own clone."
  mkdir -p "$case_dir/other/projects" "$home/projects"
  git clone -q "$CASE_URL" "$case_dir/other/projects/widget"
  git clone -q "$CASE_URL" "$home/projects/widget"
  printf '%s\n' "$home|$fakebin"
}

test_spawn_from_a_foreign_pool_leases_this_homes_own_worktree() {
  local id=pool-foreign-lease case_dir=$TMP_ROOT/spawn-foreign rec home fakebin
  local user pool foreign own anchor pane_log tree_log out status
  CASE_URL=$(make_same_origin_clones "$TMP_ROOT/spawn-origin")
  rec=$(prepare_spawn_home "$case_dir" "$id")
  home=${rec%%|*}
  fakebin=${rec#*|}
  user=$home/user-home
  pool=$(lib "$home" "$user" fm_treehouse_default_pool_dir "$home/projects/widget")
  foreign=$pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  anchor=$home/state/treehouse-clone-anchor/.treehouse/kept/1/widget
  add_worktree "$home/projects/widget" "$anchor" "kept-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$anchor" \
    fm_test_run_spawn "$home" "$anchor" "$fakebin" "$id" "$home/projects/widget" \
      --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch in this home's own worktree"$'\n'"$out"
  assert_grep "worktree=$anchor" "$home/state/$id.meta" \
    "spawn did not record this home's worktree"
  assert_no_exact_line "treehouse get" "$pane_log" \
    "a foreign pool still sent the shared treehouse get"
  assert_grep "args=get --lease --lease-holder $id" "$tree_log" \
    "spawn did not lease from this home's own pool"
  assert_grep "HOME=$home/state/treehouse-clone-anchor" "$tree_log" \
    "the lease did not use the per-home pool root"
  assert_grep "cd -- " "$pane_log" "the pane was not moved into the leased worktree"
  assert_contains "$(cat "$pane_log")" "$anchor" "the pane was not sent to this home's worktree"
  pass "a foreign default pool leases a worktree of the spawning clone"
}

test_spawn_refuses_a_leased_worktree_of_the_other_clone() {
  local id=pool-foreign-refuse case_dir=$TMP_ROOT/spawn-refuse rec home fakebin
  local user pool foreign pane_log tree_log out status
  rec=$(prepare_spawn_home "$case_dir" "$id")
  home=${rec%%|*}
  fakebin=${rec#*|}
  user=$home/user-home
  pool=$(lib "$home" "$user" fm_treehouse_default_pool_dir "$home/projects/widget")
  foreign=$pool/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$foreign" \
    fm_test_run_spawn "$home" "$foreign" "$fakebin" "$id" "$home/projects/widget" \
      --mode no-mistakes --yolo off) || status=$?
  status=${status:-0}
  [ "$status" -ne 0 ] || fail "spawn launched in the other clone's worktree"$'\n'"$out"
  assert_contains "$out" "another clone" "the refusal did not say the worktree is another clone"
  assert_contains "$out" "$foreign" "the refusal did not name the worktree"
  assert_contains "$out" "$home/projects/widget" "the refusal did not name the spawning project"
  assert_grep "args=return --force $foreign" "$tree_log" \
    "the foreign lease was not returned"
  assert_no_exact_line "exit" "$pane_log" "refusal of a private lease sent exit to the pane"
  assert_no_exact_line "treehouse get" "$pane_log" "refusal still sent the shared treehouse get"
  [ ! -e "$home/state/$id.meta" ] || fail "refused spawn published a task record"
  pass "a lease of the other clone is returned and the launch stops"
}

test_spawn_falls_back_when_the_shared_get_returns_the_other_clone() {
  local id=pool-race-fallback case_dir=$TMP_ROOT/spawn-race rec home fakebin
  local foreign own pane_log tree_log exit_flag out status
  rec=$(prepare_spawn_home "$case_dir" "$id")
  home=${rec%%|*}
  fakebin=${rec#*|}
  foreign=$case_dir/other-slot
  own=$home/state/treehouse-clone-anchor/.treehouse/kept/1/widget
  add_worktree "$case_dir/other/projects/widget" "$foreign"
  add_worktree "$home/projects/widget" "$own" "kept-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  exit_flag=$case_dir/exited
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    FM_FAKE_TREEHOUSE_PRINT="$own" FM_FAKE_PANE_AFTER_EXIT="$own" \
    FM_FAKE_EXIT_FLAG="$exit_flag" \
    fm_test_run_spawn "$home" "$foreign" "$fakebin" "$id" "$home/projects/widget" \
      --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should recover onto this home's own worktree"$'\n'"$out"
  assert_exact_line "treehouse get" "$pane_log" "an empty pool did not try the shared treehouse get"
  assert_exact_line "exit" "$pane_log" "spawn did not leave the other clone's interactive slot"
  assert_grep "worktree=$own" "$home/state/$id.meta" \
    "spawn did not record this home's worktree after the fallback"
  assert_grep "HOME=$home/state/treehouse-clone-anchor" "$tree_log" \
    "the fallback lease did not use the per-home pool root"
  pass "a shared get that returns the other clone falls back to this home's pool"
}

test_spawn_keeps_the_shared_get_for_an_empty_or_owned_pool() {
  local id=pool-empty case_dir=$TMP_ROOT/spawn-empty rec home fakebin
  local own pane_log tree_log out status user pool
  rec=$(prepare_spawn_home "$case_dir" "$id")
  home=${rec%%|*}
  fakebin=${rec#*|}
  own=$case_dir/own-slot
  add_worktree "$home/projects/widget" "$own" "own-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    fm_test_run_spawn "$home" "$own" "$fakebin" "$id" "$home/projects/widget" \
      --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an empty pool should still use treehouse get"$'\n'"$out"
  assert_exact_line "treehouse get" "$pane_log" "an empty pool did not send treehouse get"
  assert_no_grep '--lease' "$pane_log" "an empty pool leased a private pool"
  [ ! -s "$tree_log" ] || fail "an empty pool called treehouse itself: $(cat "$tree_log")"

  id='pool-owned'
  case_dir=$TMP_ROOT/spawn-owned
  rec=$(prepare_spawn_home "$case_dir" "$id")
  home=${rec%%|*}
  fakebin=${rec#*|}
  user=$home/user-home
  pool=$(lib "$home" "$user" fm_treehouse_default_pool_dir "$home/projects/widget")
  own=$pool/1/widget
  add_worktree "$home/projects/widget" "$own" "owned-$id"
  pane_log=$case_dir/pane.log
  tree_log=$case_dir/treehouse.log
  : > "$pane_log"
  : > "$tree_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_TREEHOUSE_LOG="$tree_log" \
    fm_test_run_spawn "$home" "$own" "$fakebin" "$id" "$home/projects/widget" \
      --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a pool of this clone should still use treehouse get"$'\n'"$out"
  assert_exact_line "treehouse get" "$pane_log" "this clone's own pool did not send treehouse get"
  assert_no_grep '--lease' "$pane_log" "this clone's own pool leased a private pool"
  [ ! -s "$tree_log" ] || fail "this clone's own pool called treehouse itself: $(cat "$tree_log")"
  pass "an empty pool and a pool of this clone keep the shared treehouse get"
}

# Compare the helper's pool directory with the directory real treehouse creates.
# Skips with a visible line when the binary is not installed.
test_predicted_pool_matches_treehouse_including_config_root() {
  local root scratch home clone url slot pool got bare abs_root rel before after anchor private
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "# skip predicted-pool: treehouse is not installed"
    return 0
  fi
  # Treehouse detaches an update check that rewrites HOME/.treehouse after the
  # command exits. That child recreates the scratch pool while fixture cleanup
  # is removing it. The variable is treehouse's own off switch.
  export TREEHOUSE_NO_UPDATE_CHECK=1
  root=$TMP_ROOT/real
  scratch=$root/user-home
  home=$root/home
  case "$scratch" in
    "$TMP_ROOT"/*) ;;
    *) fail "treehouse scratch escaped the temp root: $scratch" ;;
  esac
  mkdir -p "$scratch" "$home/state" "$home/projects"
  # A scratch home sitting inside some other checkout must not let treehouse
  # append its pool to that checkout's gitignore.
  if git -C "$scratch" rev-parse --show-toplevel >/dev/null 2>&1; then
    git init -q -b main "$scratch"
  fi
  before=$(git -C "$ROOT" status --porcelain)
  url=$(make_same_origin_clones "$root/clones")
  clone=$root/clones/homeA/projects/widget
  slot=$(cd "$clone" && env HOME="$scratch" treehouse get --lease --lease-holder predicted) \
    || fail "treehouse get --lease failed for the default pool"
  pool=$(dirname -- "$(dirname -- "$slot")")
  got=$(lib "$home" "$scratch" fm_treehouse_default_pool_dir "$clone")
  assert_equals "$(cd "$pool" && pwd -P)" "$(cd "$got" && pwd -P)" \
    "the predicted default pool was not the pool treehouse created"
  env HOME="$scratch" treehouse return --force "$slot" >/dev/null \
    || fail "could not return the default-pool lease"
  abs_root=$root/absolute-root
  mkdir -p "$scratch/.config/treehouse"
  printf 'root = "%s"\n' "$abs_root" > "$scratch/.config/treehouse/config.toml"
  slot=$(cd "$clone" && env HOME="$scratch" treehouse get --lease --lease-holder absolute) \
    || fail "treehouse get --lease failed for a user-level absolute root"
  pool=$(dirname -- "$(dirname -- "$slot")")
  got=$(lib "$home" "$scratch" fm_treehouse_default_pool_dir "$clone")
  assert_equals "$(cd "$pool" && pwd -P)" "$(cd "$got" && pwd -P)" \
    "a user-level absolute root was not honored"
  case "$pool" in
    "$abs_root/.treehouse/"*) ;;
    *) fail "user-level root did not place the pool under $abs_root/.treehouse: $pool" ;;
  esac
  env HOME="$scratch" treehouse return --force "$slot" >/dev/null || fail "could not return the absolute-root lease"
  printf 'max_trees = 4\n' > "$clone/treehouse.toml"
  slot=$(cd "$clone" && env HOME="$scratch" treehouse get --lease --lease-holder repo-toml) \
    || fail "treehouse get --lease failed when repo toml sets only max_trees"
  pool=$(dirname -- "$(dirname -- "$slot")")
  got=$(lib "$home" "$scratch" fm_treehouse_default_pool_dir "$clone")
  assert_equals "$(cd "$pool" && pwd -P)" "$(cd "$got" && pwd -P)" \
    "a repo toml without root did not ignore the user-level root"
  case "$pool" in
    "$scratch/.treehouse/"*) ;;
    *) fail "repo toml without root still used the user-level root: $pool" ;;
  esac
  env HOME="$scratch" treehouse return --force "$slot" >/dev/null || fail "could not return the repo-toml lease"
  printf 'root = "relpools"\n' > "$clone/treehouse.toml"
  slot=$(cd "$clone" && env HOME="$scratch" treehouse get --lease --lease-holder relative) \
    || fail "treehouse get --lease failed for a relative repo root"
  pool=$(dirname -- "$(dirname -- "$slot")")
  got=$(lib "$home" "$scratch" fm_treehouse_default_pool_dir "$clone")
  assert_equals "$(cd "$pool" && pwd -P)" "$(cd "$got" && pwd -P)" \
    "a relative repo root was not joined to the clone"
  case "$pool" in
    "$(cd "$clone" && pwd -P)/relpools/.treehouse/"*) ;;
    *) fail "relative root did not land inside the clone: $pool" ;;
  esac
  env HOME="$scratch" treehouse return --force "$slot" >/dev/null || fail "could not return the relative-root lease"
  # The second clone, pointed at a per-home HOME, gets its own common dir.
  bare=$root/clones/homeB/projects/widget
  anchor=$(lib "$home" "$scratch" fm_treehouse_clone_anchor_prepare "$home")
  private=$(cd "$bare" && env HOME="$anchor" treehouse get --lease --lease-holder per-home) \
    || fail "per-home treehouse get --lease failed"
  lib "$home" "$scratch" fm_treehouse_same_clone "$bare" "$private" \
    || fail "per-home lease was not a worktree of the spawning clone"
  case "$private" in
    "$anchor/.treehouse/"*) ;;
    *) fail "per-home lease was not under the anchor: $private" ;;
  esac
  env HOME="$anchor" treehouse return --force "$private" >/dev/null \
    || fail "could not return the per-home lease"
  after=$(git -C "$ROOT" status --porcelain)
  [ "$before" = "$after" ] || fail "treehouse changed the firstmate worktree while predicting pools"
  # url is unused except to keep the clone pair honest for a reader of the failure.
  [ -n "$url" ] || fail "the shared origin URL was empty"
  pass "the predicted pool matches the pool treehouse creates"
}

test_two_clones_of_one_origin_do_not_treat_each_others_slot_as_their_own
test_spawn_from_a_foreign_pool_leases_this_homes_own_worktree
test_spawn_refuses_a_leased_worktree_of_the_other_clone
test_spawn_falls_back_when_the_shared_get_returns_the_other_clone
test_spawn_keeps_the_shared_get_for_an_empty_or_owned_pool
test_predicted_pool_matches_treehouse_including_config_root

echo "# all fm-shared-pool-trust tests passed"
