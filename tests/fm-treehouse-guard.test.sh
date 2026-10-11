#!/usr/bin/env bash
# Behavioral coverage for the treehouse worktree-sprawl guard.
#
# Every case drives bin/fm-treehouse-guard.sh against a fake treehouse that
# records its working directory and arguments, so the exact flags and the pool
# each call was scoped to are asserted from what the guard actually ran.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-guard)
GUARD="$ROOT/bin/fm-treehouse-guard.sh"
REAL_DU=$(command -v du)
GB_KIB=1048576

# One machine: a user home holding the treehouse root, the fakes, and the
# fakes' shared record. Firstmate homes are added to it with make_home.
make_world() {  # <name>
  local world="$TMP_ROOT/$1" fakebin
  fakebin=$(fm_fakebin "$world")
  mkdir -p "$world/user/.treehouse" "$world/fake"
  : > "$world/fake/log"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
dir=${FAKE_TREEHOUSE_DIR:?}
name=$(basename "$PWD")
printf '%s\t%s\n' "$(pwd -P)" "$*" >> "$dir/log"
case "$*" in
  'status --json')
    if [ -f "$dir/status-$name.json" ]; then
      cat "$dir/status-$name.json"
    else
      printf '[]\n'
    fi
    ;;
  'prune --yes')
    [ ! -f "$dir/prune-sleep" ] || sleep "$(cat "$dir/prune-sleep")"
    if [ -f "$dir/prune-fail-$name" ]; then
      echo "simulated prune failure" >&2
      exit 3
    fi
    echo "No stale worktrees pruned."
    ;;
  'prune --all')
    [ ! -f "$dir/dryrun.out" ] || cat "$dir/dryrun.out"
    [ ! -f "$dir/dryrun.rc" ] || exit "$(cat "$dir/dryrun.rc")"
    ;;
  *)
    echo "unexpected treehouse call: $*" >&2
    exit 64
    ;;
esac
SH
  cat > "$fakebin/du" <<SH
#!/usr/bin/env bash
dir=\${FAKE_TREEHOUSE_DIR:?}
if [ -f "\$dir/du-kib" ]; then
  printf '%s\t%s\n' "\$(cat "\$dir/du-kib")" "\${@: -1}"
  exit 0
fi
exec "$REAL_DU" "\$@"
SH
  chmod +x "$fakebin/treehouse" "$fakebin/du"
  printf '%s\n' "$world"
}

make_home() {  # <world> <name> <project>...
  local world=$1 home="$1/$2" project
  shift 2
  mkdir -p "$home/state" "$home/config" "$home/projects"
  for project in "$@"; do
    fm_git_init_commit "$home/projects/$project"
  done
  printf '%s\n' "$home"
}

guard() {  # <world> <home> <guard-args>...
  local world=$1 home=$2
  shift 2
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    HOME="$world/user" PATH="$world/fakebin:$PATH" FAKE_TREEHOUSE_DIR="$world/fake" \
    FM_HOME="$home" "$GUARD" "$@"
}

# Every call the fake recorded, as "<cwd>\t<args>" lines.
calls() { cat "$1/fake/log"; }
calls_with() { grep -F -- "$2" "$1/fake/log" || true; }

assert_only_safe_flags() {  # <world> <label>
  local world=$1 label=$2 line args
  while IFS= read -r line; do
    args=${line#*$'\t'}
    case "$args" in
      'status --json'|'prune --yes'|'prune --all') ;;
      *) fail "$label: unexpected treehouse call '$args'" ;;
    esac
  done < "$world/fake/log"
}

wait_for() {  # <description> <command>...
  local description=$1 i=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "timed out waiting for $description"
    sleep 0.05
  done
}

result_swept_at() {  # <home> <epoch>
  grep -F -x -- "$(printf 'swept\t%s' "$2")" "$1/state/.treehouse-guard.result"
}

test_prune_runs_only_the_safe_prune_from_the_project() {
  local world home out rc=0
  world=$(make_world prune-flags)
  home=$(make_home "$world" home alpha)
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 0 "$rc" "safe prune"
  [ -z "$out" ] || fail "a prune that ran should be silent: $out"
  assert_equals "$(printf '%s\t%s\n%s\t%s' "$home/projects/alpha" 'status --json' "$home/projects/alpha" 'prune --yes')" \
    "$(calls "$world")" "prune did not run exactly the status read and the safe prune from the project"
}

test_prune_refuses_a_directory_that_is_not_a_clone_root() {
  local world home out rc=0
  world=$(make_world prune-root)
  home=$(make_home "$world" home alpha)
  # The home is itself a repository, as a real Firstmate home is, so git
  # discovery from a plain directory under projects/ resolves to the home.
  fm_git_init_commit "$home"
  mkdir -p "$home/projects/plain"
  out=$(guard "$world" "$home" prune "$home/projects/plain" 2>&1) || rc=$?
  expect_code 1 "$rc" "prune of a plain directory"
  assert_contains "$out" "warning: treehouse prune did not run for $home/projects/plain" "refusal did not warn"
  [ -z "$(calls "$world")" ] || fail "treehouse was run for a directory that is not a clone root: $(calls "$world")"
}

test_prune_failure_warns_and_exits_nonzero() {
  local world home out rc=0
  world=$(make_world prune-fail)
  home=$(make_home "$world" home alpha)
  : > "$world/fake/prune-fail-alpha"
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 1 "$rc" "failed prune"
  assert_contains "$out" "warning: treehouse prune did not run for $home/projects/alpha: treehouse prune exited 3: simulated prune failure" \
    "failed prune did not name treehouse's own exit and message"
}

test_prune_bound_is_reported_as_a_prune_that_did_not_finish() {
  local world home out rc=0
  world=$(make_world prune-bound)
  home=$(make_home "$world" home alpha)
  printf '5\n' > "$world/fake/prune-sleep"
  out=$(FM_TREEHOUSE_GUARD_PRUNE_SECS=1 guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 1 "$rc" "bounded prune"
  assert_contains "$out" "treehouse prune did not finish in 1s" "a prune that hit its bound was not reported as such"
}

test_prune_leaves_a_pool_holding_a_claimed_idle_copy() {
  local world home out rc=0 slot="pool/3/alpha"
  world=$(make_world prune-claim)
  home=$(make_home "$world" home alpha)
  mkdir -p "$world/user/.treehouse/$slot"
  printf 'task=scout-7\nhome=%s\n' "$home" > "$world/user/.treehouse/pool/3/.fm-slot-owner"
  printf '[{"name":"3","path":"%s","status":"available"}]\n' "$world/user/.treehouse/$slot" \
    > "$world/fake/status-alpha.json"
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 1 "$rc" "prune with a claimed idle copy"
  assert_contains "$out" "a task still claims an idle copy: copy 3 (task scout-7)" "claimed idle copy was not named"
  [ -z "$(calls_with "$world" 'prune --yes')" ] || fail "a pool with a claimed idle copy was pruned"

  # The same claim on a copy treehouse reports as in use is not at risk.
  : > "$world/fake/log"
  printf '[{"name":"3","path":"%s","status":"in-use"}]\n' "$world/user/.treehouse/$slot" \
    > "$world/fake/status-alpha.json"
  rc=0
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 0 "$rc" "prune with a claimed in-use copy"
  [ -n "$(calls_with "$world" 'prune --yes')" ] || fail "a claim on an in-use copy blocked the prune"
}

test_prune_does_not_run_when_the_pool_cannot_be_read() {
  local world home out rc=0
  world=$(make_world prune-unread)
  home=$(make_home "$world" home alpha)
  printf 'not json\n' > "$world/fake/status-alpha.json"
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 1 "$rc" "prune with an unreadable pool"
  assert_contains "$out" "its pool could not be read with treehouse status" "unreadable pool was not reported"
  [ -z "$(calls_with "$world" 'prune --yes')" ] || fail "an unverified pool was pruned"
}

test_prune_waits_out_a_pool_another_launch_or_cleanup_is_using() {
  local world home out rc=0 holder ready
  world=$(make_world prune-busy)
  home=$(make_home "$world" home alpha)
  ready="$world/lock-ready"
  # shellcheck disable=SC2016 # The positional parameters expand in the child shell.
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2/projects/alpha") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    : > "$3"
    sleep 30
    exit 0' _ "$ROOT" "$home" "$ready" &
  holder=$!
  wait_for "the project lock holder" test -e "$ready"
  out=$(guard "$world" "$home" prune "$home/projects/alpha" 2>&1) || rc=$?
  expect_code 0 "$rc" "prune of a busy pool"
  [ -z "$out" ] || fail "a busy pool should be skipped silently: $out"
  [ -z "$(calls "$world")" ] || fail "treehouse ran while the project lock was held: $(calls "$world")"

  # The holder itself, a cleanup, prunes under the lock it already holds.
  rc=0
  out=$(guard "$world" "$home" prune --locked "$home/projects/alpha" 2>&1) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 0 "$rc" "prune by the lock holder"
  [ -n "$(calls_with "$world" 'prune --yes')" ] || fail "--locked did not prune under the caller's lock"
}

test_sweep_prunes_only_this_homes_own_clones() {
  local world home_a home_b out
  world=$(make_world isolation)
  home_a=$(make_home "$world" home-a alpha beta)
  home_b=$(make_home "$world" home-b gamma)
  mkdir -p "$home_a/projects/not-a-clone"

  out=$(guard "$world" "$home_a" sweep 2>&1) || fail "sweep of the first home failed: $out"
  [ -z "$out" ] || fail "a sweep with nothing to report should be silent: $out"
  assert_equals "$(printf '%s\t%s\n%s\t%s' "$home_a/projects/alpha" 'prune --yes' "$home_a/projects/beta" 'prune --yes')" \
    "$(calls_with "$world" 'prune --yes')" "first home did not prune exactly its own two clones"
  [ -z "$(calls_with "$world" "$home_b")" ] || fail "first home's sweep ran treehouse in the other home: $(calls_with "$world" "$home_b")"
  [ -z "$(calls_with "$world" 'not-a-clone')" ] || fail "sweep ran treehouse in a directory that is not a clone"
  assert_only_safe_flags "$world" "first home sweep"
  # The only machine-wide call is the read-only dry run, never combined with --yes.
  assert_equals "$(printf '/\t%s' 'prune --all')" "$(calls_with "$world" '--all')" "the orphan dry run was not the lone machine-wide call"

  : > "$world/fake/log"
  out=$(guard "$world" "$home_b" sweep 2>&1) || fail "sweep of the second home failed: $out"
  assert_equals "$(printf '%s\t%s' "$home_b/projects/gamma" 'prune --yes')" \
    "$(calls_with "$world" 'prune --yes')" "second home did not prune exactly its own clone"
  [ -z "$(calls_with "$world" "$home_a")" ] || fail "second home's sweep ran treehouse in the first home: $(calls_with "$world" "$home_a")"
}

test_sweep_tolerates_a_failed_prune_and_reports_it() {
  local world home out rc=0
  world=$(make_world sweep-fail)
  home=$(make_home "$world" home alpha beta)
  : > "$world/fake/prune-fail-alpha"
  out=$(guard "$world" "$home" sweep 2>&1) || rc=$?
  expect_code 0 "$rc" "sweep with a failed prune"
  [ -n "$(calls_with "$world" "$(printf '%s\t%s' "$home/projects/beta" 'prune --yes')")" ] \
    || fail "a failed prune stopped the sweep before the next clone"
  assert_contains "$out" "treehouse-guard: prune did not run for alpha (treehouse prune exited 3: simulated prune failure)" \
    "failed prune was not reported"
  assert_not_contains "$out" "beta" "a clean clone was reported"
  assert_grep "$(printf 'finding\tprune did not run for alpha')" "$home/state/.treehouse-guard.result" \
    "failed prune was not recorded in the sweep result"
}

test_size_is_reported_only_past_the_limit() {
  local world home out
  world=$(make_world size)
  home=$(make_home "$world" home alpha)

  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep with a small real root failed: $out"
  [ -z "$out" ] || fail "a small treehouse root was reported: $out"

  printf '%s\n' $((6 * GB_KIB + GB_KIB / 2)) > "$world/fake/du-kib"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep past the default limit failed: $out"
  assert_equals "treehouse-guard: worktree copies use 6.5 GB under $world/user/.treehouse (limit 5 GB)" "$out" \
    "size past the default limit was not reported in one line"

  printf '%s\n' $((5 * GB_KIB)) > "$world/fake/du-kib"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep at the limit failed: $out"
  [ -z "$out" ] || fail "a root exactly at the limit was reported: $out"

  printf '%s\n' $((6 * GB_KIB + GB_KIB / 2)) > "$world/fake/du-kib"
  printf '8\n' > "$home/config/treehouse-size-limit"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep under a configured limit failed: $out"
  [ -z "$out" ] || fail "a root under the configured limit was reported: $out"

  printf '6\n' > "$home/config/treehouse-size-limit"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep past a configured limit failed: $out"
  assert_contains "$out" "use 6.5 GB under $world/user/.treehouse (limit 6 GB)" "configured limit was not applied"

  printf 'five\n' > "$home/config/treehouse-size-limit"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep with a malformed limit failed: $out"
  assert_equals "treehouse-guard: config/treehouse-size-limit is not a whole number of gigabytes, so size was not checked" "$out" \
    "a malformed limit was guessed around instead of reported"
}

test_orphaned_pools_are_reported_and_left_in_place() {
  local world home out
  world=$(make_world orphans)
  home=$(make_home "$world" home alpha)
  mkdir -p "$world/user/.treehouse/gone-3f5163/1/gone" "$world/user/.treehouse/lost-aa11bb/2/lost"
  # The report shape treehouse v2.1.1 prints, including a category that is not
  # an orphan and a path abbreviated with the home directory.
  cat > "$world/fake/dryrun.out" <<EOF
Dry run: would prune 1 stale worktree across 4 pools and reclaim 8.2 KiB.
2     8.2 KiB  ~/.treehouse/proj-3f5163/2/proj
Skipped 3 unsafe idle worktrees:
  orphaned (backing repository missing):
  1     content could not be verified  ~/.treehouse/gone-3f5163/1/gone
  2     content could not be verified  $world/user/.treehouse/lost-aa11bb/2/lost
  remove failed:
  2     git refused to remove worktree  ~/.treehouse/kept-9335e3/2/kept
Re-run with --all --yes to delete these worktrees.
EOF
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep with orphans failed: $out"
  assert_equals "treehouse-guard: 2 orphaned pool(s) with a missing backing repository, left in place: gone-3f5163, lost-aa11bb" "$out" \
    "orphaned pools were not reported from treehouse's own dry run"
  assert_present "$world/user/.treehouse/gone-3f5163/1/gone" "an orphaned pool was removed"
  assert_present "$world/user/.treehouse/lost-aa11bb/2/lost" "an orphaned pool was removed"
  assert_only_safe_flags "$world" "orphan sweep"

  printf '2\n' > "$world/fake/dryrun.rc"
  out=$(guard "$world" "$home" sweep 2>&1) || fail "sweep with a failed dry run failed: $out"
  assert_equals "treehouse-guard: orphaned pools could not be checked (treehouse prune --all dry run exited 2)" "$out" \
    "a failed dry run was read as no orphans"
}

test_check_sweeps_daily_and_reports_a_finding_once() {
  local world home out
  world=$(make_world check)
  home=$(make_home "$world" home alpha)
  printf '%s\n' $((7 * GB_KIB)) > "$world/fake/du-kib"

  out=$(FM_TREEHOUSE_GUARD_NOW=1000 guard "$world" "$home" check 2>&1) || fail "first poll failed: $out"
  [ -z "$out" ] || fail "the poll that starts a sweep should be silent: $out"
  wait_for "the first sweep result" result_swept_at "$home" 1000

  out=$(FM_TREEHOUSE_GUARD_NOW=1300 guard "$world" "$home" check 2>&1) || fail "reporting poll failed: $out"
  assert_equals "treehouse-guard: worktree copies use 7.0 GB under $world/user/.treehouse (limit 5 GB)" "$out" \
    "the finished sweep's finding was not reported on the next poll"
  out=$(FM_TREEHOUSE_GUARD_NOW=1600 guard "$world" "$home" check 2>&1) || fail "repeat poll failed: $out"
  [ -z "$out" ] || fail "an already reported finding was repeated: $out"
  assert_equals 1 "$(calls_with "$world" 'prune --yes' | wc -l | tr -d ' ')" "polls inside the day started another sweep"

  out=$(FM_TREEHOUSE_GUARD_NOW=87400 guard "$world" "$home" check 2>&1) || fail "next-day poll failed: $out"
  [ -z "$out" ] || fail "an unchanged finding was repeated when the next sweep started: $out"
  wait_for "the second sweep result" result_swept_at "$home" 87400
  assert_equals 2 "$(calls_with "$world" 'prune --yes' | wc -l | tr -d ' ')" "the next day did not start exactly one more sweep"

  # A finding that clears and later returns is news again.
  rm -f "$world/fake/du-kib"
  out=$(FM_TREEHOUSE_GUARD_NOW=200000 guard "$world" "$home" check 2>&1) || fail "clearing poll failed: $out"
  wait_for "the third sweep result" result_swept_at "$home" 200000
  out=$(FM_TREEHOUSE_GUARD_NOW=200300 guard "$world" "$home" check 2>&1) || fail "cleared poll failed: $out"
  [ -z "$out" ] || fail "a cleared finding was reported: $out"
  printf '%s\n' $((7 * GB_KIB)) > "$world/fake/du-kib"
  out=$(FM_TREEHOUSE_GUARD_NOW=300000 guard "$world" "$home" check 2>&1) || fail "returning poll failed: $out"
  wait_for "the fourth sweep result" result_swept_at "$home" 300000
  out=$(FM_TREEHOUSE_GUARD_NOW=300300 guard "$world" "$home" check 2>&1) || fail "returned poll failed: $out"
  assert_contains "$out" "worktree copies use 7.0 GB" "a finding that returned after clearing was not reported again"
}

test_sweep_outlives_the_checks_own_process_group() {
  local world home pid
  world=$(make_world detach)
  home=$(make_home "$world" home alpha)
  printf '1\n' > "$world/fake/prune-sleep"
  # The watcher runs a check in its own process group and kills that whole
  # group once the check returns; a sweep left in it would die mid-prune.
  set -m
  FM_TREEHOUSE_GUARD_NOW=5000 guard "$world" "$home" check >/dev/null 2>&1 &
  pid=$!
  set +m
  wait "$pid" || fail "the poll that starts a sweep failed"
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait_for "the detached sweep result" result_swept_at "$home" 5000
  [ -n "$(calls_with "$world" 'prune --yes')" ] || fail "the detached sweep did not prune"
}

test_arm_and_disarm_use_the_authenticated_custom_check() {
  local world home out
  world=$(make_world arm)
  home=$(make_home "$world" home alpha)
  out=$(guard "$world" "$home" arm 2>&1) || fail "arm failed: $out"
  assert_equals "armed: state/treehouse-guard.check.sh" "$out" "arm did not name the check it wrote"
  fm_custom_check_registered "$home/state" treehouse-guard \
    || fail "armed check is not bound by the authenticated custom-check mechanism"
  assert_grep "export FM_HOME=$(printf '%q' "$home")" "$home/state/treehouse-guard.check.sh" \
    "armed check does not pin its own home"

  # The armed shim is what the watcher executes: it must reach the daily gate.
  out=$(HOME="$world/user" PATH="$world/fakebin:$PATH" FAKE_TREEHOUSE_DIR="$world/fake" \
    FM_TREEHOUSE_GUARD_NOW=9000 bash "$home/state/treehouse-guard.check.sh" 2>&1) || fail "armed shim failed: $out"
  wait_for "the armed shim's sweep result" result_swept_at "$home" 9000

  out=$(guard "$world" "$home" disarm 2>&1) || fail "disarm failed: $out"
  assert_absent "$home/state/treehouse-guard.check.sh" "disarm left the check shim"
  assert_absent "$home/state/treehouse-guard.check-trust" "disarm left the trust binding"
  assert_absent "$home/state/.treehouse-guard" "disarm left the check record"
  assert_absent "$home/state/.treehouse-guard.result" "disarm left the sweep result"
}

test_unknown_command_is_refused_before_any_treehouse_call() {
  local world home rc=0
  world=$(make_world usage)
  home=$(make_home "$world" home alpha)
  guard "$world" "$home" destroy >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown command"
  [ -z "$(calls "$world")" ] || fail "an unknown command reached treehouse"
}

test_prune_runs_only_the_safe_prune_from_the_project
test_prune_refuses_a_directory_that_is_not_a_clone_root
test_prune_failure_warns_and_exits_nonzero
test_prune_bound_is_reported_as_a_prune_that_did_not_finish
test_prune_leaves_a_pool_holding_a_claimed_idle_copy
test_prune_does_not_run_when_the_pool_cannot_be_read
test_prune_waits_out_a_pool_another_launch_or_cleanup_is_using
test_sweep_prunes_only_this_homes_own_clones
test_sweep_tolerates_a_failed_prune_and_reports_it
test_size_is_reported_only_past_the_limit
test_orphaned_pools_are_reported_and_left_in_place
test_check_sweeps_daily_and_reports_a_finding_once
test_sweep_outlives_the_checks_own_process_group
test_arm_and_disarm_use_the_authenticated_custom_check
test_unknown_command_is_refused_before_any_treehouse_call
pass "fm-treehouse-guard"
