#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin tip, launches a clean origin-less
# pool as-is, or stops when a configured origin is unusable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_private_process_inventory() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ "${3:-}" = -o ] && [ "${4:-}" = pid= ] && [ "$#" -eq 4 ]; then
  [ "${FM_TEST_PS_FAIL:-0}" = 0 ] || exit 1
  printf '%s\n' "$PPID"
  [ -z "${FM_TEST_PROCESS_PIDS:-}" ] || cat "$FM_TEST_PROCESS_PIDS"
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$1/ps"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_private_process_inventory "$fakebin"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_remote_seeded_home_spawns_from_treehouse_pool() {
  local rec id out status lock
  id='pool-remote-seeded-r13'
  rec=$(make_case remote-seeded "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=parent-machine
REC

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" \
    "a remote-seeded secondmate home should allocate and launch from its Treehouse pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" \
    "the remote-seeded spawn did not report success"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the remote-seeded spawn did not publish its allocated pool worktree"
  lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") \
    || fail "the launched remote-seeded home could not resolve its Treehouse project lock"
  case "$lock" in
    "$HOME_DIR/state/"*) ;;
    *) fail "the remote-seeded spawn anchored its lock outside its local root: $lock" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse spawn command\n'
    printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' \
      "$HOME_DIR" "$id" "$PROJECT_DIR" "$out" "$status"
    printf 'published worktree=%s\nresolved project lock=%s\n' "$POOL_DIR" "$lock"
  fi
  pass "a remote-seeded secondmate home allocates and launches from its Treehouse pool"
}

test_linked_spawning_home_rejects_primary_before_refresh() {
  local rec id out status returned primary spawning before_reflog
  for returned in primary primary-alias spawning scout; do
    id="pool-linked-${returned}-r12"
    rec=$(make_case "linked-$returned" "$id")
    read_case_record "$rec"
    primary=$PROJECT_DIR
    spawning="$CASE_DIR/secondmate"
    git -C "$primary" worktree add --quiet --detach "$spawning" HEAD
    PROJECT_DIR=$spawning
    case "$returned" in
      primary) POOL_DIR=$primary ;;
      primary-alias)
        ln -s "$primary" "$CASE_DIR/primary-alias"
        POOL_DIR="$CASE_DIR/primary-alias"
        ;;
      spawning) POOL_DIR=$spawning ;;
    esac
    before_reflog=$(git -C "$primary" reflog)
    # The assertion concerns identity, not how long an unchanged cwd is polled.
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"

    out=$(run_spawn "$id" --scout)
    status=$?
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: linked-home spawn, returned=%s\n' "$returned"
      printf '$ bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' "$id" "$PROJECT_DIR" "$out" "$status"
      printf 'primary HEAD before=%s after=%s\n' "$INITIAL_SHA" "$(git -C "$primary" rev-parse HEAD)"
      printf 'primary reflog before:\n%s\nprimary reflog after:\n%s\n' "$before_reflog" "$(git -C "$primary" reflog)"
      if [ -e "$primary/.git/FETCH_HEAD" ]; then
        printf 'FETCH_HEAD:\n'; cat "$primary/.git/FETCH_HEAD"
      else
        printf 'FETCH_HEAD absent\n'
      fi
      if [ -e "$HOME_DIR/state/$id.meta" ]; then
        printf 'saved task metadata:\n'; cat "$HOME_DIR/state/$id.meta"
        printf 'worker HEAD=%s origin/main=%s\n' "$(git -C "$POOL_DIR" rev-parse HEAD)" "$(git -C "$POOL_DIR" rev-parse origin/main)"
      else
        printf 'task metadata absent\n'
      fi
      printf '# evidence end\n'
    fi
    if [ "$returned" = scout ]; then
      expect_code 0 "$status" "a genuine scout copy from a linked home should launch"$'\n'"$out"
      assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
        "spawn did not record the genuine scout copy"
      [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
        || fail "spawn did not refresh the genuine scout copy"
    else
      [ "$status" -ne 0 ] || fail "linked spawning home accepted $returned as a disposable copy"
      # None of these is an isolated copy, so the worktree poll never adopts one
      # and the wait runs out instead: the spawning directory fails the poll's
      # own project comparison, and the repository primary (named directly or
      # through a symlink) fails the isolation screen the poll shares with the
      # guard. The refusal names the last path the pane reported.
      assert_contains "$out" "did not enter an isolated worktree" \
        "spawn did not explain its isolation refusal"
      assert_contains "$out" "last seen" "refusal did not name the path the pane reported"
      [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
      [ ! -e "$primary/.git/FETCH_HEAD" ] || fail "refused spawn fetched before proving isolation"
    fi
    [ "$(git -C "$primary" rev-parse HEAD)" = "$INITIAL_SHA" ] \
      || fail "spawn reset the repository primary from a linked home"
    [ "$(git -C "$primary" reflog)" = "$before_reflog" ] \
      || fail "spawn touched the primary reflog from a linked home"
    pass "linked spawning home: $returned preserves the primary before any refresh"
  done
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head repeat_pool
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  repeat_pool="$CASE_DIR/pool-repeat"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$repeat_pool" "$current"
  POOL_DIR=$repeat_pool
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

make_originless_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_private_process_inventory "$fakebin"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

test_originless_pool_launches_without_a_freshness_fetch() {
  local rec id out status before
  id='pool-originless-r6'
  rec=$(make_originless_case originless "$id")
  read_case_record "$rec"
  ! git -C "$POOL_DIR" remote get-url origin >/dev/null 2>&1 \
    || fail "fixture unexpectedly configured an origin remote"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch a local-only pooled worktree with no origin"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the origin-less pool"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn attempted a freshness fetch against a nonexistent origin"
  [ ! -e "$POOL_DIR/.git/FETCH_HEAD" ] || fail "spawn fetched against a pooled worktree with no origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD on an origin-less pooled worktree that had nothing to refresh against"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed origin-less launch: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an origin-less pooled worktree launches as-is, skipping the freshness gate"
}

test_originless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-originless-dirty-r1'
  rec=$(make_originless_case originless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty origin-less pooled worktree"
  assert_contains "$out" "is not clean" \
    "spawn did not clearly refuse a dirty origin-less pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty origin-less pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded local work from an origin-less pool"
  pass "a dirty origin-less pooled worktree is refused without discarding its local work"
}

test_origin_config_without_url_refuses_pool() {
  local rec id out status before
  id='pool-origin-without-url-r1'
  rec=$(make_originless_case origin-without-url "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin configuration with no URL"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an origin configuration with no URL as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an unusable origin configuration"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an origin configuration without a URL refuses the pooled worktree"
}

test_empty_origin_config_section_refuses_pool() {
  local rec id out status before config
  id='pool-empty-origin-section-r1'
  rec=$(make_originless_case empty-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  printf '\n[remote "origin"]\n' >> "$config"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an empty origin configuration section"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an empty origin configuration section as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an empty origin configuration section"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an empty origin configuration section refuses the pooled worktree"
}

test_empty_only_included_origin_config_section_launches_pool() {
  local rec id out status before config included
  id='pool-empty-only-included-origin-section-r1'
  rec=$(make_originless_case empty-only-included-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/empty-origin.inc
  printf '[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config include.path "$(basename "$included")"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should proceed when an included empty origin section is not enumerable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the undetectable included section"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn treated an undetectable included empty section as a configured origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite treating the included empty section as origin-less"
  pass "an empty-only included origin section documents the accepted detection boundary"
}

test_inactive_conditional_origin_include_launches_pool() {
  local rec id out status before config included
  id='pool-inactive-origin-include-r1'
  rec=$(make_originless_case inactive-origin-include "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/inactive-origin.inc
  printf '[fm-test]\n\tmarker = true\n[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config 'includeIf.gitdir:/never/matches/this/worktree/.path' "$included"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should ignore an inactive conditional origin include"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success with an inactive origin include"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite having no effective origin"
  pass "an inactive conditional origin include leaves the pooled worktree origin-less"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# A slot left on a stale submodule pin is the field failure this diagnosis exists
# for: a refresh moved the superproject and left the submodule behind, so the
# refusal fires a spawn later, on a slot whose own `git status` looks clean to the
# operator. Nothing here is converged - the gate only has to say why. The fixture
# only builds the repositories; the residue itself is produced by a real spawn, so
# these tests cover the reset that actually strands the submodule.
make_submodule_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin sub subpin1 subpin2 advanced
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  sub="$case_dir/sub-origin"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  make_private_process_inventory "$fakebin"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout --quiet "$subpin1"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c protocol.file.allow=always -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    submodule --quiet add "file://$sub" ui
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  git -C "$pool" -c protocol.file.allow=always submodule --quiet update --init

  # Advance origin and move the submodule pin, exactly as the field incident did.
  git clone --quiet "file://$origin" "$publisher"
  git -C "$publisher" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$publisher/ui" checkout --quiet "$subpin2"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam advance-pin
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$subpin1|$subpin2|$advanced"
}

read_submodule_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR SUBPIN1 SUBPIN2 ADVANCED_SHA <<EOF
$1
EOF
}

# The first of two consecutive spawns: it succeeds, resets the superproject onto
# the base that moved the pin, and leaves the submodule checkout on the pin the
# old base recorded. That reset is what strands the slot, so every case below
# starts from residue this code path actually produced rather than a hand-built one.
strand_submodule_pin_via_spawn() {  # <seed-id>
  local id=$1 out status
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn that moves the submodule pin should succeed"
  assert_contains "$out" "spawned $id" "the spawn that moves the submodule pin did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "the first spawn did not move the pooled base across the moved submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "the first spawn did not strand the submodule on the pin the old base recorded"
  mkdir -p "$CASE_DIR/retired"
  mv "$HOME_DIR/state/$id.meta" "$CASE_DIR/retired/$id.meta"
}

test_stale_submodule_pin_explains_itself() {
  local rec id out status before before_sub
  id='pool-stale-pin-r7'
  rec=$(make_submodule_case stale-pin "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-stale-pin-seed-r7'
  git -C "$POOL_DIR" remote remove origin
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$(git -C "$POOL_DIR/ui" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the second spawn launched from a slot carrying a stale submodule pin"
  assert_contains "$out" "stale submodule checkout" \
    "refusal did not name the cause as a stale submodule checkout"
  assert_contains "$out" "submodule 'ui'" "refusal did not name the submodule"
  assert_contains "$out" "$SUBPIN1" "refusal did not report the pin the slot actually has"
  assert_contains "$out" "$SUBPIN2" "refusal did not report the pin the base records"
  # No remedy is printed on purpose: the containment check reads local refs only,
  # so a stale remote-tracking ref can make an unpushed commit look contained, and
  # a checkout command on that judgement could cost the operator a commit.
  assert_not_contains "$out" "submodule update --checkout" \
    "refusal printed a remedy command the containment check cannot stand behind"
  assert_not_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin was misreported as uncommitted work"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a stale submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn converged the submodule; this gate must never touch the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-pin refusal: %s\n' "$(printf '%s\n' "$out" | grep 'submodule' | head -n 1)"
  fi
  pass "an origin-less pool with a stale submodule pin refuses while naming both pins and no remedy"
}

test_unpushed_submodule_commit_is_still_uncommitted_work() {
  local rec id out status unpushed before before_sub
  id='pool-sub-unpushed-r10'
  rec=$(make_submodule_case sub-unpushed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-unpushed-seed-r10'
  # A commit made inside the submodule and never pushed leaves the submodule work
  # tree clean and the pins different - the same two facts a stale pin shows. Any
  # checkout of the recorded pin would move HEAD off this commit and leave it
  # unreferenced, so this case must keep the conservative refusal.
  printf 'unlanded submodule work\n' > "$POOL_DIR/ui/unlanded.txt"
  git -C "$POOL_DIR/ui" add unlanded.txt
  git -C "$POOL_DIR/ui" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm unlanded-submodule-work
  unpushed=$(git -C "$POOL_DIR/ui" rev-parse HEAD)
  [ -z "$(git -C "$POOL_DIR/ui" status --porcelain)" ] \
    || fail "fixture did not leave the submodule work tree clean"
  [ "$unpushed" != "$(git -C "$POOL_DIR" rev-parse "HEAD:ui")" ] \
    || fail "fixture did not leave the recorded pin different from what is checked out"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$unpushed

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "an unpushed submodule commit was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "an unpushed submodule commit was misreported as a stale pin"
  assert_not_contains "$out" "is checked out at" \
    "an unpushed submodule commit still drew the stale-pin diagnosis"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn moved the submodule off its unpushed commit"
  git -C "$POOL_DIR/ui" cat-file -e "$unpushed^{commit}" \
    || fail "the unpushed submodule commit did not survive the refusal"
  assert_grep 'unlanded submodule work' "$POOL_DIR/ui/unlanded.txt" \
    "spawn discarded the unpushed submodule work while refusing the pool"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a slot holding an unpushed submodule commit"
  pass "an unpushed submodule commit keeps the uncommitted-work refusal and survives it"
}

test_work_inside_submodule_is_still_uncommitted_work() {
  local rec id out status
  id='pool-sub-work-r8'
  rec=$(make_submodule_case sub-work "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-work-seed-r8'
  # Put the submodule back on the pin the base records, so the ONLY deviation is
  # real work inside it. This must never be softened into a stale-pin diagnosis.
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN2"
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "work inside a submodule was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "real work inside a submodule was misreported as a stale pin"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "work inside a submodule is still refused as uncommitted work, not called stale"
}

test_stale_pin_carrying_real_work_is_not_called_stale() {
  local rec id out status
  id='pool-sub-both-r9'
  rec=$(make_submodule_case sub-both "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-both-seed-r9'
  # Stale pin AND real work inside it: calling this merely stale would be wrong, so
  # the refusal must stay the conservative one.
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin carrying real work was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a submodule holding real work was reported as merely stale"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "a stale pin carrying real work is refused conservatively, never called stale"
}

test_stale_pin_beside_other_dirt_reports_one_verdict() {
  local rec id out status
  id='pool-sub-mixed-r11'
  rec=$(make_submodule_case sub-mixed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-mixed-seed-r11'
  # Git sorts status paths, so the stale 'ui' entry is scanned before this file.
  # The conservative verdict must not arrive contradicted by a stale-pin line.
  printf 'notes the operator still wants\n' > "$POOL_DIR/zz-notes.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin beside an untracked file was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a slot carrying more than a stale pin was reported as merely stale"
  assert_not_contains "$out" "is checked out at" \
    "the stale-pin diagnosis was printed alongside the conservative refusal"
  assert_grep 'notes the operator still wants' "$POOL_DIR/zz-notes.txt" \
    "spawn discarded the untracked file while refusing the pool"
  pass "a stale pin beside other dirt yields the conservative refusal alone, with no stale-pin line"
}

# Re-lay a case's pooled worktree as a managed Treehouse slot: <pool>/<slot>/<repo>
# with the pool's state file beside the slot, which is the shape fm-spawn claims
# for its task. Rewrites POOL_DIR to the relocated checkout.
lay_out_as_pool_slot() {
  local slot_root="$CASE_DIR/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot_root/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_root/1/project" \
    > "$slot_root/treehouse-state.json"
  POOL_DIR="$slot_root/1/project"
  SLOT_CLAIM="$slot_root/1/.fm-slot-owner"
}

test_pool_custody_refuses_unreadable_nested_registry() {
  local mode=${1:-file} rec id first sibling descendant registry blocked_path restore_mode out status before_head before_reflog
  id="pool-nested-registry-$mode"
  rec=$(make_case "nested-registry-$mode" "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  first="$CASE_DIR/first-home"
  sibling="$CASE_DIR/later-home"
  descendant="$CASE_DIR/grandchild-home"
  mkdir -p "$first/state" "$first/data" "$sibling/state" "$sibling/data" \
    "$descendant/state" "$descendant/data"
  printf '%s\n' \
    "- first - fixture (home: $first; scope: test; projects: project; added 2026-01-01)" \
    "- later - fixture (home: $sibling; scope: test; projects: project; added 2026-01-01)" \
    > "$HOME_DIR/data/secondmates.md"
  registry="$first/data/secondmates.md"
  printf '%s\n' "- child - fixture (home: $descendant; scope: test; projects: project; added 2026-01-01)" \
    > "$registry"
  : > "$sibling/data/secondmates.md"
  fm_write_meta "$descendant/state/prior-worker.meta" \
    'window=firstmate:fm-prior-worker' 'endpoint_task_id=prior-worker' \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" 'kind=scout'
  blocked_path=$registry
  restore_mode=600
  if [ "$mode" = parent ]; then
    blocked_path="$first/data"
    restore_mode=700
  fi
  chmod 000 "$blocked_path"
  if ( : < "$registry" ) 2>/dev/null; then
    chmod "$restore_mode" "$blocked_path"
    echo "skip - current user can read a registry with mode-000 $mode"
    return 0
  fi
  before_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_reflog=$(git -C "$POOL_DIR" reflog)
  out=$(FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    run_spawn "$id" --scout)
  status=$?
  chmod "$restore_mode" "$blocked_path"
  [ "$status" -ne 0 ] || fail 'spawn accepted custody after omitting a registered grandchild'
  assert_contains "$out" 'local Firstmate registry' 'spawn did not name the unreadable registry'
  assert_absent "$HOME_DIR/state/$id.meta" 'unreadable registry refusal published a new task record'
  assert_present "$descendant/state/prior-worker.meta" 'unreadable registry refusal removed the prior reservation'
  assert_absent "$SLOT_CLAIM" 'unreadable registry refusal claimed the copy'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before_head" ] \
    || fail 'unreadable registry refusal refreshed the copy'
  [ "$(git -C "$POOL_DIR" reflog)" = "$before_reflog" ] \
    || fail 'unreadable registry refusal changed the reflog'
  [ ! -s "$CASE_DIR/launch.log" ] || fail 'unreadable registry refusal launched a worker'
  if [ -f "$CASE_DIR/pane.log" ]; then
    assert_no_grep 'treehouse get' "$CASE_DIR/pane.log" 'unreadable registry refusal happened after acquisition'
  fi
  pass "spawn refuses an unreadable registry $mode despite a later readable sibling"
}

test_pool_custody_refuses_before_refresh_or_claim() {
  local variant rec id other other_home recorded before_head before_remote before_reflog before_claim out status launch_log pane_log
  for variant in same-home sibling-home unreadable-sibling alias unsafe-metadata other-claim; do
    id="pool-custody-${variant}-r1"
    other="prior-${variant}-r1"
    rec=$(make_case "custody-$variant" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    other_home=$HOME_DIR
    recorded=$POOL_DIR
    case "$variant" in
      sibling-home|unreadable-sibling)
        other_home="$CASE_DIR/secondmate-home"
        mkdir -p "$other_home/state" "$other_home/data" "$other_home/config"
        printf '%s\n' "- mate - fixture (home: $other_home; scope: test; projects: project; added 2026-01-01)" \
          > "$HOME_DIR/data/secondmates.md"
        ;;
      alias)
        ln -s "$POOL_DIR" "$CASE_DIR/pool-alias"
        recorded="$CASE_DIR/pool-alias"
        ;;
    esac
    if [ "$variant" != other-claim ]; then
      if [ "$variant" = unsafe-metadata ]; then
        printf 'worktree=%s\nworktree=%s\n' "$POOL_DIR" "$POOL_DIR" \
          > "$other_home/state/$other.meta"
      else
        fm_write_meta "$other_home/state/$other.meta" \
          "window=firstmate:fm-$other" "endpoint_task_id=$other" \
          "worktree=$recorded" "project=$PROJECT_DIR" "kind=scout"
      fi
    fi
    if [ "$variant" = unreadable-sibling ]; then
      chmod 000 "$other_home/state"
    fi
    before_claim=
    if [ "$variant" = other-claim ]; then
      printf 'task=%s\nhome=%s\n' "$other" "$other_home" > "$SLOT_CLAIM"
      before_claim=$(cat "$SLOT_CLAIM")
    fi
    before_head=$(git -C "$POOL_DIR" rev-parse HEAD)
    before_remote=$(git -C "$POOL_DIR" rev-parse --verify -q refs/remotes/origin/main || true)
    before_reflog=$(git -C "$POOL_DIR" reflog)
    launch_log="$CASE_DIR/launch.log"
    pane_log="$CASE_DIR/pane.log"
    out=$(FM_FAKE_PANE_LOG="$pane_log" FM_FAKE_LAUNCH_LOG="$launch_log" run_spawn "$id" --scout)
    status=$?
    if [ "$variant" = unreadable-sibling ]; then
      chmod 700 "$other_home/state"
    fi
    [ "$status" -ne 0 ] || fail "$variant: spawn accepted a slot already held by $other"
    assert_absent "$HOME_DIR/state/$id.meta" "$variant: refused spawn published metadata"
    if [ "$variant" = other-claim ]; then
      [ "$(cat "$SLOT_CLAIM")" = "$before_claim" ] \
        || fail "$variant: refused spawn overwrote the owner marker"
    else
      assert_absent "$SLOT_CLAIM" "$variant: refused spawn wrote a new owner marker"
    fi
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before_head" ] \
      || fail "$variant: refused spawn moved HEAD"
    [ "$(git -C "$POOL_DIR" rev-parse --verify -q refs/remotes/origin/main || true)" = "$before_remote" ] \
      || fail "$variant: refused spawn fetched the remote base"
    [ "$(git -C "$POOL_DIR" reflog)" = "$before_reflog" ] \
      || fail "$variant: refused spawn changed the reflog"
    [ ! -e "$POOL_DIR/advanced-main.txt" ] \
      || fail "$variant: refused spawn refreshed the checkout"
    [ ! -s "$launch_log" ] || fail "$variant: refused spawn launched a worker"
    if [ -f "$pane_log" ]; then
      assert_no_grep 'treehouse get' "$pane_log" "$variant: custody refusal happened after pool acquisition"
    fi
    pass "spawn refuses a $variant pool custody collision before refresh and claim"
  done
}

test_returned_pool_copy_rechecks_custody_before_refresh() {
  local rec id=new-worker old=old-worker out status before_head before_reflog before_status launch_log collision
  for collision in record marker; do
  rec=$(make_case "returned-custody-$collision" "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  printf 'preserve tracked work\n' >> "$POOL_DIR/README.md"
  printf 'preserve untracked work\n' > "$POOL_DIR/untracked.txt"
  before_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_reflog=$(git -C "$POOL_DIR" reflog)
  before_status=$(git -C "$POOL_DIR" status --porcelain)
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*)
    if [ -f "$FM_TEST_RACE_EXITED" ]; then printf '%s\n' "$FM_TEST_RACE_PROJECT"; exit; fi
    ;;
  *'treehouse get'*)
    if [ "$FM_TEST_RACE_KIND" = record ]; then
      printf 'worktree=%s\nproject=%s\nkind=scout\n' \
        "$FM_TEST_RACE_COPY" "$FM_TEST_RACE_PROJECT" > "$FM_TEST_RACE_META"
    else
      printf 'task=%s\nhome=%s\n' "$FM_TEST_RACE_OLD" "$FM_TEST_RACE_HOME" > "$FM_TEST_RACE_MARKER"
    fi
    : > "$FM_TEST_RACE_REACHED"
    ;;
  *' exit Enter'*) : > "$FM_TEST_RACE_EXITED" ;;
esac
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ -f "$FM_TEST_RACE_EXITED" ]; then
  printf '1  available  %s\n' "$FM_TEST_RACE_COPY"
  exit
fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  launch_log="$CASE_DIR/launch.log"
  out=$(FM_TEST_RACE_KIND="$collision" FM_TEST_RACE_COPY="$POOL_DIR" FM_TEST_RACE_PROJECT="$PROJECT_DIR" \
    FM_TEST_RACE_META="$HOME_DIR/state/$old.meta" FM_TEST_RACE_MARKER="$SLOT_CLAIM" \
    FM_TEST_RACE_OLD="$old" FM_TEST_RACE_HOME="$HOME_DIR" \
    FM_TEST_RACE_REACHED="$CASE_DIR/reached" FM_TEST_RACE_EXITED="$CASE_DIR/exited" \
    FM_FAKE_LAUNCH_LOG="$launch_log" run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail 'spawn accepted a copy claimed after preflight'
  assert_present "$CASE_DIR/reached" 'spawn never reached the Treehouse handoff'
  assert_present "$CASE_DIR/exited" 'spawn did not leave the disputed interactive copy'
  if [ "$collision" = record ]; then
    assert_contains "$out" 'custody conflict' 'spawn did not refuse the returned record'
    assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$old.meta" 'spawn changed the old record'
    assert_absent "$SLOT_CLAIM" 'spawn added a slot marker on record refusal'
  else
    assert_contains "$out" 'retains a slot claim' 'spawn did not refuse the returned marker'
    assert_absent "$HOME_DIR/state/$old.meta" 'spawn added an old record on marker refusal'
    assert_grep "task=$old" "$SLOT_CLAIM" 'spawn changed the old slot marker'
  fi
  assert_absent "$HOME_DIR/state/$id.meta" 'spawn published a conflicting record'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before_head" ] || fail 'spawn changed the copy HEAD'
  [ "$(git -C "$POOL_DIR" reflog)" = "$before_reflog" ] || fail 'spawn changed the copy reflog'
  [ "$(git -C "$POOL_DIR" status --porcelain)" = "$before_status" ] || fail 'spawn changed preserved work'
  [ ! -s "$launch_log" ] || fail 'spawn launched a worker on the disputed copy'
  pass "returned pool copy is refused when a $collision claim arrives after preflight"
  done
}

test_returned_pool_copy_rechecks_process_evidence() {
  local rec id=process-worker variant out status survivor='' launch_log
  for variant in survivor unreadable; do
    rec=$(make_case "returned-process-$variant" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*)
    if [ -f "$FM_TEST_PANE_EXITED" ]; then printf '%s\n' "$FM_TEST_PANE_PROJECT"; exit; fi
    ;;
  *'treehouse get'*) : > "$FM_TEST_PANE_REACHED" ;;
  *' exit Enter'*) : > "$FM_TEST_PANE_EXITED" ;;
esac
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
    cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ -f "$FM_TEST_PANE_EXITED" ]; then
  printf '1  available  %s\n' "$FM_TEST_PANE_COPY"
  exit
fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
SH
    chmod +x "$FAKEBIN_DIR/treehouse"
    if [ "$variant" = survivor ]; then
      (cd "$POOL_DIR" && exec /bin/sleep 60) &
      survivor=$!
      printf '%s\n' "$survivor" > "$CASE_DIR/process-pids"
    fi
    launch_log="$CASE_DIR/launch.log"
    out=$(FM_TEST_PANE_COPY="$POOL_DIR" FM_TEST_PANE_PROJECT="$PROJECT_DIR" \
      FM_TEST_PANE_REACHED="$CASE_DIR/reached" FM_TEST_PANE_EXITED="$CASE_DIR/exited" \
      FM_TEST_PROCESS_PIDS="$CASE_DIR/process-pids" FM_TEST_PS_FAIL=$([ "$variant" = unreadable ] && echo 1 || echo 0) \
      FM_FAKE_LAUNCH_LOG="$launch_log" run_spawn "$id" --scout)
    status=$?
    if [ -n "$survivor" ]; then kill "$survivor" 2>/dev/null || true; wait "$survivor" 2>/dev/null || true; survivor=; fi
    [ "$status" -ne 0 ] || fail "$variant: spawn accepted unproven process custody"
    assert_present "$CASE_DIR/reached" "$variant: spawn never reached the returned copy"
    assert_present "$CASE_DIR/exited" "$variant: spawn did not leave the returned copy"
    if [ "$variant" = survivor ]; then
      assert_contains "$out" 'other live processes' "$variant: spawn did not refuse the rooted process"
    else
      assert_contains "$out" 'process custody' "$variant: spawn did not refuse unreadable evidence"
    fi
    assert_absent "$HOME_DIR/state/$id.meta" "$variant: spawn published task metadata"
    [ ! -s "$launch_log" ] || fail "$variant: spawn launched a worker"
    pass "returned pool copy refuses $variant process evidence before refresh"
  done
}

test_returned_pool_copy_accepts_unreadable_cwd_process() {
  local rec id=unreadable-cwd-worker out status nodump_pid pane_dummy
  [ "$(uname -s)" = Linux ] || { echo 'skip - nondumpable process needs Linux'; return 0; }
  rec=$(make_case returned-unreadable-cwd "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid}'*) cat "$FM_TEST_PANE_PID_FILE"; exit ;;
  *'#{pane_current_path}'*)
    if [ -f "$FM_TEST_PANE_EXITED" ]; then printf '%s\n' "$FM_TEST_PANE_PROJECT"; exit; fi
    ;;
  *'treehouse get'*) : > "$FM_TEST_PANE_REACHED" ;;
  *' exit Enter'*) : > "$FM_TEST_PANE_EXITED" ;;
esac
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ -f "$FM_TEST_PANE_EXITED" ]; then
  printf '1  available  %s\n' "$FM_TEST_PANE_COPY"
  exit
fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  python3 - "$CASE_DIR" "$CASE_DIR/nodump-ready" <<'PY' &
import ctypes, os, sys, time
os.chdir(sys.argv[1])
if ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) != 0:
    sys.exit(1)
open(sys.argv[2], 'w').write(str(os.getpid()))
time.sleep(60)
PY
  nodump_pid=$!
  for _ in $(seq 1 100); do [ -s "$CASE_DIR/nodump-ready" ] && break; sleep 0.05; done
  [ -s "$CASE_DIR/nodump-ready" ] || fail 'the unreadable-cwd fixture never started'
  nodump_pid=$(cat "$CASE_DIR/nodump-ready")
  ! readlink "/proc/$nodump_pid/cwd" >/dev/null 2>&1 \
    || fail 'the fixture cwd stayed readable, so this case proves nothing'
  ( exec /bin/sleep 60 ) &
  pane_dummy=$!
  printf '%s\n' "$nodump_pid" > "$CASE_DIR/process-pids"
  printf '%s\n' "$pane_dummy" > "$CASE_DIR/pane-pid"
  out=$(FM_TEST_PANE_COPY="$POOL_DIR" FM_TEST_PANE_PROJECT="$PROJECT_DIR" \
    FM_TEST_PANE_PID_FILE="$CASE_DIR/pane-pid" FM_TEST_PANE_REACHED="$CASE_DIR/reached" \
    FM_TEST_PANE_EXITED="$CASE_DIR/exited" FM_TEST_PROCESS_PIDS="$CASE_DIR/process-pids" \
    run_spawn "$id" --scout)
  status=$?
  kill "$nodump_pid" "$pane_dummy" 2>/dev/null || true
  expect_code 0 "$status" "spawn pool custody refused beside an unreadable-cwd process outside the pane tree: $out"
  assert_present "$CASE_DIR/reached" 'unreadable-cwd spawn never reached the returned copy'
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" 'unreadable-cwd spawn did not publish the returned copy'
  pass 'returned pool copy accepts custody beside an unreadable-cwd process outside the pane tree'
}

test_returned_pool_copy_refuses_active_interactive_builtins() {
  local mode rec id label pane out status
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip - tmux not installed'; return 0; }
  for mode in busy fd; do
    id="pool-builtin-$mode"
    rec=$(make_case "$id" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    label="$id-$RANDOM"
    pane=$(fm_test_active_tmux_shell "$label" nested task "$POOL_DIR" "$mode" "$CASE_DIR/activity") \
      || fail "$mode: could not start an active allocation pane"
    printf '%s\n' "$pane" > "$CASE_DIR/process-pids"
    printf '%s\n' "$pane" > "$CASE_DIR/pane-pid"
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid}'*) cat "$FM_TEST_PANE_PID_FILE"; exit ;;
  *'#{pane_current_path}'*)
    if [ -f "$FM_TEST_PANE_EXITED" ]; then printf '%s\n' "$FM_TEST_PANE_PROJECT"; exit; fi
    ;;
  *'treehouse get'*) : > "$FM_TEST_PANE_REACHED" ;;
  *' exit Enter'*) : > "$FM_TEST_PANE_EXITED" ;;
esac
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    out=$(FM_TEST_PANE_COPY="$POOL_DIR" FM_TEST_PANE_PROJECT="$PROJECT_DIR" \
      FM_TEST_PANE_PID_FILE="$CASE_DIR/pane-pid" FM_TEST_PANE_REACHED="$CASE_DIR/reached" \
      FM_TEST_PANE_EXITED="$CASE_DIR/exited" FM_TEST_PROCESS_PIDS="$CASE_DIR/process-pids" \
      FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --scout)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode: allocation accepted an active interactive builtin: $out"
    assert_present "$CASE_DIR/reached" "$mode: allocation never reached the returned copy"
    assert_contains "$out" 'cannot prove' "$mode: allocation did not explain unproven absence"
    assert_absent "$HOME_DIR/state/$id.meta" "$mode: allocation published task metadata"
    assert_absent "$SLOT_CLAIM" "$mode: allocation claimed the busy slot"
    assert_absent "$POOL_DIR/advanced-main.txt" "$mode: allocation refreshed the active copy"
    [ ! -s "$CASE_DIR/launch.log" ] || fail "$mode: allocation launched a worker"
    tmux -L "$label" has-session -t nested || fail "$mode: allocation closed the active pane"
    [ ! -e "$CASE_DIR/activity/finished" ] || fail "$mode: the unrelated-FD wait ended before refusal"
    tmux -L "$label" kill-server
  done
  pass 'returned pool copies refuse real active interactive builtin loops and unrelated-FD waits'
}

test_returned_pool_copy_accepts_its_foreground_task_shell() {
  local rec id=nested-shell-worker label=pulse-nested-shell pane nested capture out status
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip - tmux not installed'; return 0; }
  rec=$(make_case returned-nested-shell "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  tmux -L "$label" new-session -d -s nested -n task -c "$POOL_DIR" 'bash --noprofile --norc -i'
  pane=$(tmux -L "$label" display-message -p -t nested:task '#{pane_pid}')
  tmux -L "$label" send-keys -t nested:task 'bash --noprofile --norc -i' Enter
  nested=
  for _ in $(seq 1 30); do
    tmux -L "$label" send-keys -t nested:task 'printf "NESTED=%s\n" "$$"' Enter
    sleep 0.05
    capture=$(tmux -L "$label" capture-pane -p -t nested:task)
    nested=$(printf '%s\n' "$capture" | sed -n 's/^NESTED=\([0-9][0-9]*\).*$/\1/p' | tail -1)
    [ -n "$nested" ] && [ "$nested" != "$pane" ] && break
  done
  [ -n "$nested" ] && [ "$nested" != "$pane" ] || fail 'private tmux did not start a nested foreground task shell'
  if ! fm_test_terminal_read_available "$nested"; then
    tmux -L "$label" kill-server
    echo 'skip - nested idle-shell proof unavailable on this kernel; manual confirmation required'
    return 0
  fi
  printf '%s\n%s\n' "$pane" "$nested" > "$CASE_DIR/process-pids"
  printf '%s\n' "$pane" > "$CASE_DIR/pane-pid"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_pid}'*) cat "$FM_TEST_PANE_PID_FILE"; exit ;;
  *'#{pane_current_path}'*)
    if [ -f "$FM_TEST_PANE_EXITED" ]; then printf '%s\n' "$FM_TEST_PANE_PROJECT"; exit; fi
    ;;
  *'treehouse get'*) : > "$FM_TEST_PANE_REACHED" ;;
  *' exit Enter'*) : > "$FM_TEST_PANE_EXITED" ;;
esac
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ -f "$FM_TEST_PANE_EXITED" ]; then
  printf '1  available  %s\n' "$FM_TEST_PANE_COPY"
  exit
fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  out=$(FM_TEST_PANE_COPY="$POOL_DIR" FM_TEST_PANE_PROJECT="$PROJECT_DIR" \
    FM_TEST_PANE_PID_FILE="$CASE_DIR/pane-pid" FM_TEST_PANE_REACHED="$CASE_DIR/reached" \
    FM_TEST_PANE_EXITED="$CASE_DIR/exited" FM_TEST_PROCESS_PIDS="$CASE_DIR/process-pids" \
    run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the returned copy's foreground nested shell was refused: $out"
  assert_present "$CASE_DIR/reached" 'nested-shell spawn did not reach Treehouse allocation'
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" 'nested-shell spawn did not publish the returned copy'
  tmux -L "$label" kill-server
  pass 'returned pool copy accepts its verified nested foreground task shell'
}

test_provider_pool_marker_from_sibling_clone_blocks_allocation() {
  local rec id=pool-cross-clone-r1 provider sibling marker before_head out status launch_log
  rec=$(make_case cross-clone "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/user-home/.config/treehouse"
  printf 'root = "%s"\n' "$CASE_DIR" > "$HOME_DIR/user-home/.config/treehouse/config.toml"
  provider=$(FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" bash -c \
    '. "$1"; fm_treehouse_pool_check "$2" "$3" "$4"; printf "%s" "$FM_TREEHOUSE_POOL_RESOLVED"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR" "$PROJECT_DIR" "$HOME_DIR/user-home") \
    || fail 'the private provider pool could not be resolved'
  sibling="$CASE_DIR/sibling/project"
  mkdir -p "${sibling%/*}" "$provider/29"
  git clone --quiet "file://$CASE_DIR/origin.git" "$sibling"
  git -C "$sibling" worktree add --quiet --detach "$provider/29/project" HEAD
  printf '{"worktrees":[{"name":"29","path":"%s"}]}\n' "$provider/29/project" \
    > "$provider/treehouse-state.json"
  marker="$provider/29/.fm-slot-owner"
  printf 'task=old-task\nhome=%s\n' "$CASE_DIR/other-home" > "$marker"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    case "$arg" in
      *fm-treehouse-pool-check.sh*'&& treehouse get'*) bash -c "$arg"; exit $? ;;
    esac
  done
fi
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  cat > "$FAKEBIN_DIR/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ "${3:-}" = -o ] && [ "${4:-}" = pid= ] && [ "$#" -eq 4 ]; then
  printf '%s\n' "$$"
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$FAKEBIN_DIR/ps"
  before_head=$(git -C "$provider/29/project" rev-parse HEAD)
  launch_log="$CASE_DIR/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn allocated while a sibling clone retained a provider slot marker: $out"
  assert_contains "$out" 'slot claim' 'spawn did not name the provider marker refusal'
  assert_absent "$HOME_DIR/state/$id.meta" 'refused spawn published task metadata'
  [ ! -s "$launch_log" ] || fail 'spawn launched a worker after the provider marker refusal'
  [ "$(git -C "$provider/29/project" rev-parse HEAD)" = "$before_head" ] \
    || fail 'refused spawn moved the sibling clone copy'
  assert_grep 'task=old-task' "$marker" 'refused spawn changed the sibling claim'
  out=$(HOME="$HOME_DIR/user-home" FM_HOME="$HOME_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    bash "$ROOT/bin/fm-treehouse-pool-check.sh" "$HOME_DIR" "$PROJECT_DIR" "$CASE_DIR/refusal" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail 'pane preflight accepted the sibling clone marker'
  assert_contains "$out" 'slot claim' 'pane preflight did not name the marker refusal'
  pass 'provider pool markers from sibling clones block both allocation preflights'
}

# The preflight screens the copy `treehouse get` would hand out next, not every
# idle copy: a task record parked on one idle copy must not block a spawn that
# the provider would serve from another, while the copy it would serve stays
# protected.
test_pool_preflight_screens_only_the_copy_to_be_allocated() {
  local rec provider copy variant out status n variants bridge_pid bridge_script hidden process_pids
  rec=$(make_case next-copy pool-next-copy-r1)
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/user-home/.config/treehouse"
  printf 'root = "%s"\n' "$CASE_DIR" > "$HOME_DIR/user-home/.config/treehouse/config.toml"
  provider=$(FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" bash -c \
    '. "$1"; fm_treehouse_pool_check "$2" "$3" "$4"; printf "%s" "$FM_TREEHOUSE_POOL_RESOLVED"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR" "$PROJECT_DIR" "$HOME_DIR/user-home") \
    || fail 'the private provider pool could not be resolved'
  for n in 1 2 3; do
    mkdir -p "$provider/$n"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$provider/$n/project" "$INITIAL_SHA"
  done
  variants='meta-later meta-next marker-later marker-next valid-created-meta-later leased-first unreadable-state
    dirty-first-meta-second dirty-first-marker-second dirty-first-inventory-second
    destroying-first-meta-second owner-first-meta-second locked-first-meta-second unknown-first-meta-second
    bad-created-first-meta-second bad-created-first-marker-second bad-created-first-inventory-second
    bad-leased-later-meta-second'
  if [ "$(uname -s)" = Linux ]; then
    variants="$variants bridge-first-meta-second bridge-first-marker-second bridge-first-inventory-second"
  fi
  for variant in $variants; do
    rm -f "$HOME_DIR"/state/*.meta "$provider"/*/.fm-slot-owner
    rm -f "$provider/1/project/dirty.txt" "$CASE_DIR/process-pids"
    bridge_pid=
    process_pids=
    printf '{"worktrees":[{"name":"1","path":"%s","leased":%s},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
      "$provider/1/project" false "$provider/2/project" "$provider/3/project" \
      > "$provider/treehouse-state.json"
    case "$variant" in
      meta-later|marker-later|valid-created-meta-later) copy=$provider/3/project ;;
      leased-first|*-second) copy=$provider/2/project ;;
      *) copy=$provider/1/project ;;
    esac
    case "$variant" in
      meta-*|valid-created-meta-later|leased-first|unreadable-state|dirty-first-meta-second|destroying-first-meta-second|owner-first-meta-second|locked-first-meta-second|unknown-first-meta-second|bridge-first-meta-second|bad-created-first-meta-second|bad-leased-later-meta-second)
        fm_write_meta "$HOME_DIR/state/parked.meta" "window=firstmate:fm-parked" \
          "endpoint_task_id=parked" "worktree=$copy" "project=$PROJECT_DIR" "kind=scout" ;;
      marker-*|dirty-first-marker-second|dirty-first-inventory-second|bridge-first-marker-second|bridge-first-inventory-second|bad-created-first-marker-second|bad-created-first-inventory-second)
        printf 'task=parked\nhome=%s\n' "$CASE_DIR/other-home" > "${copy%/project}/.fm-slot-owner" ;;
    esac
    case "$variant" in
      leased-first)
        printf '{"worktrees":[{"name":"1","path":"%s","leased":true},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      unreadable-state)
        printf 'not json\n' > "$provider/treehouse-state.json" ;;
      dirty-first-*)
        printf 'dirty\n' > "$provider/1/project/dirty.txt" ;;
      destroying-first-meta-second)
        printf '{"worktrees":[{"name":"1","path":"%s","destroying":true},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      owner-first-meta-second)
        printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":1,"owner_started_at":1},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      locked-first-meta-second)
        touch "$(git -C "$provider/1/project" rev-parse --git-path index.lock)" ;;
      unknown-first-meta-second)
        printf '{"worktrees":[{"name":"1","path":"%s","reset_failed":true},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      bad-created-first-*)
        printf '{"worktrees":[{"name":"1","path":"%s","created_at":"bad"},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      bad-leased-later-meta-second)
        printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"},{"name":"3","path":"%s","leased_at":"bad"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      valid-created-meta-later)
        printf '{"worktrees":[{"name":"1","path":"%s","created_at":"2026-10-20T00:00:00Z","leased_at":"2026-10-20T00:00:00.123456789+00:00"},{"name":"2","path":"%s"},{"name":"3","path":"%s"}]}\n' \
          "$provider/1/project" "$provider/2/project" "$provider/3/project" \
          > "$provider/treehouse-state.json" ;;
      bridge-first-*)
        bridge_script="$CASE_DIR/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js"
        mkdir -p "${bridge_script%/*}"
        printf 'for ((i=0; i<120; i++)); do /bin/sleep 1; done\n' > "$bridge_script"
        bridge_pid=$(python3 - "$provider/1/project" "$bridge_script" <<'PY'
import subprocess, sys
bridge = subprocess.Popen(["node", sys.argv[2]], executable="/bin/bash",
                          cwd=sys.argv[1], start_new_session=True,
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
print(bridge.pid)
PY
        ) || fail 'could not start the detached bridge fixture'
        process_pids="$CASE_DIR/process-pids"
        printf '%s\n' "$bridge_pid" > "$process_pids"
        for n in 1 2 3 4 5 6 7 8 9 10; do
          [ "$(readlink "/proc/$bridge_pid/cwd")" = "$provider/1/project" ] \
            || fail 'the bridge fixture did not stay inside the first copy'
          hidden=$(FM_TEST_PROCESS_PIDS="$process_pids" PATH="$FAKEBIN_DIR:$PATH" \
            bash -c '. "$1"; fm_agent_worktree_processes "$2"' _ \
            "$ROOT/bin/fm-agent-process-lib.sh" "$provider/1/project") \
            || fail 'the bridge fixture broke the worker absence proof'
          [ -n "$hidden" ] || break
          /bin/sleep 0.05
        done
        [ -z "$hidden" ] || fail 'the bridge fixture was not excluded from worker absence proof' ;;
    esac
    if [ "$variant" = dirty-first-inventory-second ] || [ "$variant" = bridge-first-inventory-second ] \
      || [ "$variant" = bad-created-first-inventory-second ]; then
      out=$(HOME="$HOME_DIR/user-home" FM_HOME="$HOME_DIR" FM_TEST_PROCESS_PIDS="$process_pids" PATH="$FAKEBIN_DIR:$PATH" \
        bash -c '. "$1"; fm_treehouse_pool_custody_check "$2" "$3" "$4" records' _ \
        "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR" "$PROJECT_DIR" "$HOME_DIR/user-home" 2>&1)
    else
      out=$(HOME="$HOME_DIR/user-home" FM_HOME="$HOME_DIR" FM_TEST_PROCESS_PIDS="$process_pids" PATH="$FAKEBIN_DIR:$PATH" \
        bash "$ROOT/bin/fm-treehouse-pool-check.sh" "$HOME_DIR" "$PROJECT_DIR" "$CASE_DIR/refusal" 2>&1)
    fi
    status=$?
    if [ -n "$bridge_pid" ]; then
      kill -- "-$bridge_pid" 2>/dev/null || true
    fi
    case "$variant" in
      meta-later|marker-later|valid-created-meta-later)
        [ "$status" -eq 0 ] || fail "$variant: preflight refused a copy the provider would not allocate: $out" ;;
      *)
        [ "$status" -ne 0 ] || fail "$variant: preflight let the provider reset the reserved copy it would allocate"
        assert_contains "$out" "${copy%/project}" "$variant: refusal did not name the reserved copy" ;;
    esac
    rm -f "$(git -C "$provider/1/project" rev-parse --git-path index.lock)"
  done
  pass 'pool preflight selects only a provably available copy'
}

test_state_override_pane_preflight_blocks_retained_claim() {
  local rec id=pool-override-new-r1 old=pool-override-old-r1 state provider out status survivor
  local before_head before_reflog before_status
  rec=$(make_case state-override-custody "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/user-home/.config/treehouse"
  printf 'root = "%s"\n' "$CASE_DIR" > "$HOME_DIR/user-home/.config/treehouse/config.toml"
  provider=$(FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" bash -c \
    '. "$1"; fm_treehouse_pool_check "$2" "$3" "$4"; printf "%s" "$FM_TREEHOUSE_POOL_RESOLVED"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR" "$PROJECT_DIR" "$HOME_DIR/user-home") \
    || fail 'the private provider pool could not be resolved'
  mkdir -p "$provider/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$provider/1/project"
  POOL_DIR="$provider/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$POOL_DIR" \
    > "$provider/treehouse-state.json"
  state="$CASE_DIR/override-state"
  mkdir -p "$state"
  fm_write_meta "$state/$old.meta" "window=firstmate:fm-$old" \
    "endpoint_task_id=$old" "worktree=$POOL_DIR" "project=$PROJECT_DIR" "kind=scout"
  printf 'preserve tracked work\n' >> "$POOL_DIR/README.md"
  printf 'preserve untracked work\n' > "$POOL_DIR/untracked.txt"
  before_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_reflog=$(git -C "$POOL_DIR" reflog)
  before_status=$(git -C "$POOL_DIR" status --porcelain)
  (cd "$POOL_DIR" && exec /bin/sleep 60) &
  survivor=$!
  printf '%s\n' "$survivor" > "$CASE_DIR/process-pids"
  /bin/sleep 0.1
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.fixture"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = send-keys ]; then
  for arg in "$@"; do
    case "$arg" in
      *fm-treehouse-pool-check.sh*'&& treehouse get'*)
        : > "$FM_TEST_PANE_ENTERED"
        kill "$FM_TEST_EXIT_PID"
        /bin/sleep 0.1
        bash -c "$arg"
        exit $?
        ;;
    esac
  done
fi
exec "$(dirname "$0")/tmux.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.fixture"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then : > "$FM_TEST_PROVIDER_ENTERED"; fi
exec "$(dirname "$0")/treehouse.fixture" "$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  out=$(FM_TEST_STATE_OVERRIDE="$state" FM_TEST_PROCESS_PIDS="$CASE_DIR/process-pids" \
    FM_TEST_EXIT_PID="$survivor" FM_TEST_PANE_ENTERED="$CASE_DIR/pane-entered" \
    FM_TEST_PROVIDER_ENTERED="$CASE_DIR/provider-entered" run_spawn "$id" --scout)
  status=$?
  kill "$survivor" 2>/dev/null || true
  wait "$survivor" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail 'spawn accepted a retained claim in the overridden state directory'
  assert_present "$CASE_DIR/pane-entered" 'spawn did not reach the pane preflight'
  assert_absent "$CASE_DIR/provider-entered" 'pane entered the provider despite the retained claim'
  assert_contains "$out" 'still reserved' 'pane preflight did not refuse the retained claim'
  assert_grep "worktree=$POOL_DIR" "$state/$old.meta" 'pane preflight changed the old record'
  assert_absent "$state/$id.meta" 'refused spawn published a new record'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before_head" ] || fail 'refused spawn moved HEAD'
  [ "$(git -C "$POOL_DIR" reflog)" = "$before_reflog" ] || fail 'refused spawn changed the reflog'
  [ "$(git -C "$POOL_DIR" status --porcelain)" = "$before_status" ] || fail 'refused spawn changed preserved work'
  pass 'pane preflight honors the resolved state override before provider acquisition'
}

# The spawn side of the slot-owner claim that bin/fm-teardown.sh later reads:
# a launched task's claim names it, a slot that cannot be claimed refuses before
# anything is published, and an abort while the allocation lock is still held
# leaves no claim naming a task with no record.
test_pool_slot_claim_follows_the_spawn_outcome() {
  local rec id out status before

  id='pool-slot-claim-r1'
  rec=$(make_case slot-claim "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn from a Treehouse slot should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not publish the relocated slot as its worktree"
  [ -f "$SLOT_CLAIM" ] || fail "spawn left its Treehouse slot unclaimed: $out"
  grep -Fxq -- "task=$id" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawned task: $(cat "$SLOT_CLAIM")"
  grep -Fxq -- "home=$HOME_DIR" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawning home: $(cat "$SLOT_CLAIM")"

  id='pool-slot-unclaimable-r1'
  rec=$(make_case slot-unclaimable "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$SLOT_CLAIM"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker on a slot it could not claim"
  assert_contains "$out" "unreadable custody" \
    "spawn did not name the unclaimable slot as the reason"
  [ -d "$SLOT_CLAIM" ] || fail "spawn replaced the directory blocking its slot claim"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn published a record for an unclaimable slot"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the slot's HEAD after failing to claim it"

  id='pool-slot-claim-aborted-r1'
  rec=$(make_originless_case slot-claim-aborted "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unusable origin on the slot"
  assert_contains "$out" "could not fetch origin" \
    "the aborted spawn did not refuse on its unusable origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted spawn published task metadata"
  [ ! -e "$SLOT_CLAIM" ] && [ ! -L "$SLOT_CLAIM" ] \
    || fail "the aborted spawn left a slot claim naming a task with no record: $(cat "$SLOT_CLAIM")"
  pass "a Treehouse slot claim names the launched task, refuses when unclaimable, and is dropped by a locked abort"
}

publish_feature_branch() { # <branch>
  git -C "$CASE_DIR/publisher" checkout --quiet -b "$1"
  printf 'only on %s\n' "$1" > "$CASE_DIR/publisher/feature-only.txt"
  git -C "$CASE_DIR/publisher" add feature-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature
  git -C "$CASE_DIR/publisher" push --quiet origin "$1"
}

brief_with_base() { # <id> <base> [<intent>]
  fm_test_spawn_brief "$HOME_DIR" "$1" ${3:+"$3"}
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: %s\n' "$2" >> "$HOME_DIR/data/$1/brief.md"
}

test_named_base_branch_starts_from_that_branch() {
  local rec id out status kind
  for kind in ship scout; do
    id="pool-named-base-$kind-r1"
    rec=$(make_case "named-base-$kind" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    brief_with_base "$id" feature/hub
    if [ "$kind" = ship ]; then
      out=$(run_spawn "$id" --mode direct-PR --yolo off --base-branch feature/hub)
    else
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
    fi
    status=$?
    expect_code 0 "$status" "a $kind spawn with a matching base branch should launch"$'\n'"$out"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
      || fail "the $kind copy did not start from origin/feature/hub"
    assert_grep 'only on feature/hub' "$POOL_DIR/feature-only.txt" \
      "the $kind copy is missing the base branch content"
    assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" \
      "the $kind spawn did not record its base branch"
  done

  id='pool-named-base-missing-r1'
  rec=$(make_case named-base-missing "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/missing
  out=$(run_spawn "$id" --scout --base-branch feature/missing)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch origin lacks should refuse the spawn"
  assert_contains "$out" "origin/feature/missing" "the refusal did not name the missing base"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused base-branch spawn published task metadata"

  id='pool-named-base-local-only-r1'
  rec=$(make_case named-base-local-only "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch on a local-only ship should refuse the spawn"
  assert_contains "$out" "mode=local-only" "the local-only refusal did not explain itself"
  pass "--base-branch picks the copy's starting point and is recorded; a missing or local-only base refuses"
}

test_base_branch_must_agree_with_the_brief() {
  local rec id out status case_name
  for case_name in flag-only line-only task-decoy; do
    id="pool-base-agree-$case_name-r1"
    rec=$(make_case "base-agree-$case_name" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    case "$case_name" in
    flag-only)
      fm_test_spawn_brief "$HOME_DIR" "$id"
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    line-only)
      brief_with_base "$id" feature/hub
      out=$(run_spawn "$id" --scout)
      ;;
    task-decoy)
      brief_with_base "$id" feature/hub $'You are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: decoy'
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "a $case_name base-branch disagreement should refuse the spawn"
    assert_contains "$out" "Base branch" "the $case_name refusal did not name the Base branch line"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused $case_name spawn published task metadata"
  done
  pass "a spawn refuses when --base-branch and the brief's Base branch lines disagree"
}

# A Base branch line quoted in the captain's intent is prose: it neither blocks
# a spawn nor redirects it.
test_prose_base_branch_line_is_ignored() {
  local rec id out status
  id='pool-base-prose-none-r1'
  rec=$(make_case base-prose-none "$id")
  read_case_record "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a no-base brief quoting a Base branch line should launch"$'\n'"$out"
  assert_no_grep 'base_branch=' "$HOME_DIR/state/$id.meta" "prose recorded a base branch"

  id='pool-base-prose-flag-r1'
  rec=$(make_case base-prose-flag "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  brief_with_base "$id" feature/hub $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  expect_code 0 "$status" "a flagged spawn whose intent names another branch should launch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
    || fail "the prose branch redirected the copy away from origin/feature/hub"
  assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" "the flag's base was not recorded"
  pass "a Base branch line in the captain's intent neither blocks nor redirects a spawn"
}

# A named base is validated against the project's registered forge for scouts
# too, so a scout that promotion could never ship is refused at spawn.
test_scout_base_branch_refused_on_gerrit_forge() {
  local rec id out status
  id='pool-base-gerrit-scout-r1'
  rec=$(make_case base-gerrit-scout "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  printf '%s\n' '- project [no-mistakes forge=gerrit] - fixture (added 2026-01-01)' > "$HOME_DIR/data/projects.md"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a based scout on a forge=gerrit project should refuse the spawn"
  assert_contains "$out" "forge=gerrit" "the gerrit refusal did not explain itself"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused gerrit scout spawn published task metadata"
  pass "a based scout on a forge=gerrit project is refused at spawn"
}

test_pool_rollback_preserves_or_releases_custody() {
  local phase rec id out status real_tasks project_lock
  command -v tasks-axi >/dev/null 2>&1 || { echo 'skip - tasks-axi not installed'; return 0; }
  real_tasks=$(command -v tasks-axi)
  for phase in prelaunch postlaunch foreign release-failure lock-contention; do
    id="pool-rollback-$phase"
    rec=$(make_case "rollback-$phase" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    project_lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") || fail 'could not resolve the project lock'
    /bin/mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-base"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_R12_TMUX_LOG"
exec "$(dirname "$0")/tmux-base" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
    printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
    tasks-axi add "$id" 'Exercise failed dispatch custody' --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null
    mkdir -p "$CASE_DIR/other-home"
    printf '#!/usr/bin/env bash\nreal=%q\n' "$real_tasks" > "$FAKEBIN_DIR/tasks-axi"
    cat >> "$FAKEBIN_DIR/tasks-axi" <<'SH'
if [ "$FM_R12_PHASE" = postlaunch ] && [ "${1:-}" = start ]; then
  cp "$FM_R12_HOME/state/$FM_R12_ID.meta" "$FM_R12_CASE/observed.meta" || exit 2
  cp "$FM_R12_SLOT" "$FM_R12_CASE/observed.claim" || exit 2
  : > "$FM_R12_CASE/reached"
  printf 'injected backlog start failure\n' >&2
  exit 1
fi
exec "$real" "$@"
SH
    cat > "$FAKEBIN_DIR/mv" <<'SH'
#!/usr/bin/env bash
if [ "$FM_R12_PHASE" != postlaunch ]; then
  for arg in "$@"; do
    case "$arg" in
      */launch.s*.sh)
        cp "$FM_R12_HOME/state/$FM_R12_ID.meta" "$FM_R12_CASE/observed.meta" || exit 2
        cp "$FM_R12_SLOT" "$FM_R12_CASE/observed.claim" || exit 2
        : > "$FM_R12_CASE/reached"
        if [ "$FM_R12_PHASE" = foreign ]; then
          printf 'task=other-task\nhome=%s/other-home\n' "$FM_R12_CASE" > "$FM_R12_SLOT"
        fi
        if [ "$FM_R12_PHASE" = lock-contention ]; then
          mkdir -p "$FM_R12_LOCK"
          printf '%s\n' "$FM_R12_LOCK_PID" > "$FM_R12_LOCK/pid"
        fi
        printf 'injected prelaunch staging failure\n' >&2
        exit 1
        ;;
    esac
  done
fi
exec /bin/mv "$@"
SH
    cat > "$FAKEBIN_DIR/rm" <<'SH'
#!/usr/bin/env bash
if [ "$FM_R12_PHASE" = release-failure ]; then
  for arg in "$@"; do
    [ "$arg" != "$FM_R12_SLOT" ] || exit 1
  done
fi
exec /bin/rm "$@"
SH
    chmod +x "$FAKEBIN_DIR/tasks-axi" "$FAKEBIN_DIR/mv" "$FAKEBIN_DIR/rm"
    out=$(FM_R12_PHASE="$phase" FM_R12_CASE="$CASE_DIR" FM_R12_HOME="$HOME_DIR" \
      FM_R12_LOCK="$project_lock" FM_R12_LOCK_PID="$$" FM_R12_TMUX_LOG="$CASE_DIR/tmux.log" \
      FM_R12_SLOT="$SLOT_CLAIM" FM_R12_ID="$id" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
      run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$phase dispatch unexpectedly succeeded"
    assert_present "$CASE_DIR/reached" "$phase fixture never reached the provisional record and slot claim"
    assert_grep "task=$id" "$CASE_DIR/observed.claim" "$phase never held its own claim before the failure"
    assert_grep "worktree=$POOL_DIR" "$CASE_DIR/observed.meta" "$phase never published the allocated worktree"
    if [ "$phase" = postlaunch ] || [ "$phase" = release-failure ] || [ "$phase" = lock-contention ]; then
      assert_present "$HOME_DIR/state/$id.meta" "$phase removed the observable task record"
      assert_grep "task=$id" "$SLOT_CLAIM" "$phase lost its own retained claim"
    else
      assert_absent "$HOME_DIR/state/$id.meta" "$phase retained the prelaunch provisional record"
      assert_absent "$HOME_DIR/state/$id.busy-state" "$phase retained the prelaunch busy generation"
      if [ "$phase" = foreign ]; then
        assert_grep 'task=other-task' "$SLOT_CLAIM" 'rollback released another task claim'
        assert_grep "home=$CASE_DIR/other-home" "$SLOT_CLAIM" 'rollback changed another home claim'
      else
        assert_absent "$SLOT_CLAIM" 'prelaunch rollback orphaned its own slot claim'
      fi
    fi
    assert_grep 'new-window ' "$CASE_DIR/tmux.log" "$phase never created its task window"
    if [ "$phase" = prelaunch ] || [ "$phase" = foreign ]; then
      assert_grep 'kill-window ' "$CASE_DIR/tmux.log" "$phase left an unrecorded task window behind"
    elif grep -q '^kill-window ' "$CASE_DIR/tmux.log"; then
      fail "$phase closed a window whose task record or worker was retained"
    fi
    if [ "$phase" = postlaunch ]; then
      assert_present "$CASE_DIR/launch.log" 'backlog failure happened before launch delivery'
      assert_contains "$out" 'worker may be active' 'postlaunch failure did not explain custody preservation'
    else
      [ ! -s "$CASE_DIR/launch.log" ] || fail "$phase attempted to launch a worker"
    fi
    if [ "$phase" = lock-contention ]; then
      assert_contains "$out" 'cannot lock the claimed slot for rollback' \
        'rollback did not encounter the competing project lock'
    fi
    [ "$(tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md" | sed -n 's/^  state: *//p')" = queued ] \
      || fail "$phase changed the failed-dispatch backlog row"
  done
  pass 'failed pool dispatch releases only prelaunch own claims and keeps postlaunch or unreleasable claims paired'
}

test_pool_custody_refuses_unreadable_nested_registry
test_pool_custody_refuses_unreadable_nested_registry parent
test_returned_pool_copy_refuses_active_interactive_builtins
test_pool_rollback_preserves_or_releases_custody

test_remote_seeded_home_spawns_from_treehouse_pool
test_pool_slot_claim_follows_the_spawn_outcome
test_pool_custody_refuses_before_refresh_or_claim
test_returned_pool_copy_rechecks_custody_before_refresh
test_returned_pool_copy_rechecks_process_evidence
test_returned_pool_copy_accepts_unreadable_cwd_process
test_returned_pool_copy_accepts_its_foreground_task_shell
test_provider_pool_marker_from_sibling_clone_blocks_allocation
test_pool_preflight_screens_only_the_copy_to_be_allocated
test_state_override_pane_preflight_blocks_retained_claim
test_linked_spawning_home_rejects_primary_before_refresh
test_stale_pool_base_refreshes_before_branching
test_named_base_branch_starts_from_that_branch
test_base_branch_must_agree_with_the_brief
test_prose_base_branch_line_is_ignored
test_scout_base_branch_refused_on_gerrit_forge
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_originless_pool_launches_without_a_freshness_fetch
test_originless_dirty_pool_refuses_without_discarding_work
test_origin_config_without_url_refuses_pool
test_empty_origin_config_section_refuses_pool
test_empty_only_included_origin_config_section_launches_pool
test_inactive_conditional_origin_include_launches_pool
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
