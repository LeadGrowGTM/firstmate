#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout fakebin rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/tmux-helpers.sh" "$dir/runner/tests/"
  fakebin=$(fm_fakebin "$dir/standalone")
  fm_fake_exit0 "$fakebin" pi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    git -C "$2" log -1 --format=%s > "${FM_TEST_STANDALONE_COMMIT:?}"
    exit 1
  fi
  shift
done
SH
  chmod +x "$fakebin/tmux"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  bash -eus -- "$ROOT/tests/herdr-test-safety.sh" "$dir/global-herdr" <<'SH' || exit 1
. "$1"
git init -q "$2"
git -C "$2" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m initial
[ "$(git -C "$2" log -1 --format=%s)" = initial ]
SH
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  rc=0
  FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=HEAD \
    FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated \
    FM_TEST_STANDALONE_COMMIT="$dir/global-standalone-commit" PATH="$fakebin:$PATH" \
    bash "$ROOT/tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh" \
    > "$dir/standalone.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "standalone fixture did not stop at the tmux launch"
  assert_grep 'could not start isolated Pi session' "$dir/standalone.log" \
    "standalone fixture failed before the tmux launch: $(cat "$dir/standalone.log")"
  [ "$(cat "$dir/global-standalone-commit")" = 'test: initial instruction contract' ] \
    || fail "standalone fixture did not create its initial commit"
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

# A host whose `sleep` is a multicall coreutils (uutils on Ubuntu 26.04) refuses
# to run under a foreign name, so a harness-named symlink to it never becomes a
# live process. The fake `sleep` below models that refusal on any host, which
# keeps this case meaningful where CI's own `sleep` is single-purpose.
test_agent_standin_survives_a_multicall_sleep() (
  local dir="$TMP_ROOT/standin" fakebin real_sleep standin pid
  real_sleep=$(command -v sleep) || fail "sleep not found"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
case "\${0##*/}" in
  sleep) exec "$real_sleep" "\$@" ;;
  *) echo "Requested utility \${0##*/} does not match executable name" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/sleep"
  ln -s "$fakebin/sleep" "$dir/pi"
  "$fakebin/sleep" 0 || fail "the fake multicall sleep must run under its own name"
  if "$dir/pi" 0 2>/dev/null; then
    fail "the fake multicall sleep must refuse a harness name, or this case proves nothing"
  fi

  if standin=$(PATH="$fakebin:$(fm_test_base_path_sans "$PATH" cc gcc)" fm_agent_standin "$dir/nocc"); then
    fail "without a compiler, a multicall sleep must not be offered as a stand-in, got '$standin'"
  fi
  assert_absent "$dir/nocc/standin" "a refused stand-in must not be left behind"

  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "skip: no C compiler, so the compiled stand-in half of the multicall case cannot run"
    pass "agent stand-in: a multicall sleep is refused rather than offered as a stand-in"
    exit 0
  fi
  standin=$(PATH="$fakebin:$PATH" fm_agent_standin "$dir/cc") \
    || fail "with a compiler, a multicall host sleep must still yield a stand-in"
  ln -s "$standin" "$dir/cc/pi"
  "$dir/cc/pi" 60 &
  pid=$!
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "the stand-in must stay alive under a harness name"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "agent stand-in: a multicall sleep is refused, and the compiled stand-in survives a harness name"
)

test_tmux_isolation() (
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip: tmux not installed'; exit 0; }
  local dir="$TMP_ROOT/tmux-isolation" sentinel_dir sentinel child recorder
  mkdir -m 700 "$dir"
  sentinel_dir=$(mktemp -d /tmp/fmo.XXXXXX) || fail 'could not create independent operator sentinel directory'
  sentinel="$sentinel_dir/operator"
  child=
  cleanup_isolation() {
    "$FM_TEST_TMUX_REAL" -S "$sentinel" kill-server >/dev/null 2>&1 || true
    [ -z "$child" ] || FM_TEST_TMUX_ROOT="$child" fm_test_tmux_cleanup
    rmdir "$sentinel_dir" 2>/dev/null || true
  }
  trap cleanup_isolation EXIT
  "$FM_TEST_TMUX_REAL" -S "$sentinel" -f /dev/null new-session -d -s protected 'exec sleep 600' \
    || fail 'could not start disposable operator sentinel'
  export TMUX="$sentinel,0,0" TMUX_TMPDIR="$dir"
  unset FM_TEST_TMUX_OWNER
  . "$ROOT/tests/tmux-helpers.sh" || fail 'could not isolate inherited tmux'
  child=$FM_TEST_TMUX_ROOT
  tmux new-session -d -s lab 'exec sleep 60' || fail 'isolated test server did not start'
  socket=$(tmux display-message -p '#{socket_path}')
  [ "$socket" = "$(cd -P -- "$TMUX_TMPDIR" && pwd -P)/tmux-$(id -u)/fm-test" ] \
    || fail 'bare call did not select the named test server'
  ln -s "$child" "$dir/alias"
  TMUX_TMPDIR="$dir/alias/s" tmux -L fm-test has-session -t lab \
    || fail 'named socket refused through a symlinked parent spelling'
  TMUX_TMPDIR="$dir/alias/s" tmux -S "$dir/alias/s/tmux-$(id -u)/fm-test" has-session -t lab \
    || fail 'explicit socket refused through a symlinked parent spelling'
  TMUX_TMPDIR="$dir/alias/s" TMUX="$dir/alias/s/tmux-$(id -u)/fm-test,0,0" \
    tmux has-session -t lab || fail 'inherited socket refused through a symlinked parent spelling'
  if tmux has-session -t protected 2>/dev/null; then fail 'test reached inherited operator server'; fi
  tmux kill-server || fail 'isolated kill-server failed'
  "$FM_TEST_TMUX_REAL" -S "$sentinel" has-session -t protected || fail 'lab killed operator sentinel'
  if tmux -S "$sentinel" kill-server 2>"$dir/foreign.err"; then fail 'foreign private socket accepted'; fi
  assert_grep 'unrecorded socket path' "$dir/foreign.err" 'foreign private socket was not refused'
  ( cd "$sentinel_dir" && ! tmux -S operator kill-server ) 2>/dev/null \
    || fail 'relative foreign private socket accepted'
  "$FM_TEST_TMUX_REAL" -S "$sentinel" has-session -t protected || fail 'foreign selector reached operator sentinel'
  mkdir -m 700 "$dir/recorded"
  tmux -S "$dir/recorded/dedicated.sock" new-session -d -s disposable 'exec sleep 60' \
    || fail 'recorded disposable socket refused'
  tmux -S "$dir/recorded/dedicated.sock" has-session -t disposable \
    || fail 'recorded disposable socket did not answer'
  ( cd "$dir/recorded" && tmux -S dedicated.sock has-session -t disposable ) \
    || fail 'relative recorded disposable socket did not answer'
  tmux -f /dev/null -S "$dir/recorded/dedicated.sock" has-session -t disposable \
    || fail 'required config option refused a recorded socket'
  tmux -S "$dir/recorded/dedicated.sock" kill-server \
    || fail 'recorded disposable socket did not stop'
  recorder="$dir/recorder"
  cat > "$recorder" <<'SH'
#!/usr/bin/env bash
printf 'contact\n' >> "$FM_TEST_CONTACT_LOG"
exit 0
SH
  chmod +x "$recorder"
  FM_TEST_TMUX_REAL="$recorder" FM_TEST_CONTACT_LOG="$dir/contact.log" \
    bash -s -- "$ROOT" "$sentinel" "$sentinel_dir" <<'SH' \
    || fail 'foreign socket refusal contacted the real tmux command'
unset FM_TEST_TMUX_OWNER
. "$1/tests/tmux-helpers.sh" || exit 1
trap fm_test_tmux_cleanup EXIT
if tmux -S "$2" list-sessions >/dev/null 2>&1; then exit 1; fi
if tmux -vS "$2" kill-server >/dev/null 2>&1; then exit 1; fi
if tmux -vS"$2" kill-server >/dev/null 2>&1; then exit 1; fi
if tmux -vL default kill-server >/dev/null 2>&1; then exit 1; fi
if tmux -vLdefault kill-server >/dev/null 2>&1; then exit 1; fi
if tmux -T test kill-server >/dev/null 2>&1; then exit 1; fi
if TMUX_TMPDIR="$3" tmux -L operator list-sessions >/dev/null 2>&1; then exit 1; fi
[ ! -e "$FM_TEST_CONTACT_LOG" ]
SH
  if tmux -L default list-sessions 2>"$dir/default.err"; then fail 'default name accepted'; fi
  assert_grep 'default or invalid' "$dir/default.err" 'default selector did not refuse'
  if tmux -S "$dir/default" list-sessions 2>"$dir/path.err"; then fail 'default socket path accepted'; fi
  assert_grep 'default or non-private' "$dir/path.err" 'default path did not refuse'
  rm -f "$TMUX_TMPDIR/tmux-$(id -u)/fm-test"
  rmdir "$TMUX_TMPDIR/tmux-$(id -u)" "$TMUX_TMPDIR" || fail 'could not remove unused private socket directory'
  if tmux new-session -d -s escaped 2>"$dir/missing.err"; then fail 'missing socket directory fell back'; fi
  assert_grep 'private TMUX_TMPDIR is missing' "$dir/missing.err" 'missing directory did not refuse'
  "$FM_TEST_TMUX_REAL" -S "$sentinel" has-session -t protected || fail 'refusal touched operator sentinel'
  # The runner must isolate a suite that never sources tests/lib.sh itself.
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/tmux-helpers.sh" "$dir/runner/tests/"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
tmux new-session -d -s standalone 'exec sleep 60'
[ "$(tmux display-message -p '#{socket_path}')" = "$(cd -P -- "$TMUX_TMPDIR" && pwd -P)/tmux-$(id -u)/fm-test" ]
! tmux has-session -t protected 2>/dev/null
tmux kill-server
SH
  TMUX="$sentinel,0,0" TMUX_TMPDIR="$dir" bash "$dir/runner/bin/fm-test-run.sh" \
    tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
    || fail "runner let standalone suite escape isolation: $(cat "$dir/runner.log")"
  "$FM_TEST_TMUX_REAL" -S "$sentinel" has-session -t protected || fail 'standalone suite killed operator sentinel'
  pass 'tmux test isolation: inherited operator socket survives create/kill and unsafe selectors refuse'
)

test_tmux_cleanup_after_trap_override() (
  local dir="$TMP_ROOT/tmux-trap-override" root real_mktemp
  mkdir -p "$dir/bin"
  real_mktemp=$(command -v mktemp) || fail 'mktemp is required for fixture cleanup test'
  cat > "$dir/bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -e
allocated=$("$FM_TEST_REAL_MKTEMP" "$@")
case "$allocated" in
  /tmp/fmt.??????) printf '%s\n' "$allocated" >> "$FM_TEST_TMUX_ALLOCATIONS" ;;
esac
printf '%s\n' "$allocated"
SH
  chmod +x "$dir/bin/mktemp"
  PATH="$dir/bin:$PATH" FM_TEST_REAL_MKTEMP="$real_mktemp" \
    FM_TEST_TMUX_ALLOCATIONS="$dir/allocated" bash "$ROOT/tests/fm-cursor-harness.test.sh" \
    > "$dir/suite.log" 2>&1 || fail "trap-override suite failed: $(cat "$dir/suite.log")"
  [ -s "$dir/allocated" ] || fail 'trap-override suite did not create a private tmux fixture'
  while IFS= read -r root; do
    assert_absent "$root" 'trap-override suite left its private tmux fixture behind'
  done < "$dir/allocated"
  pass 'tmux fixture cleanup survives a suite replacing its EXIT trap'
)

test_tmux_signal_cleanup() (
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip: tmux not installed'; exit 0; }
  local dir="$TMP_ROOT/tmux-signal" pid rc=0 i lab
  mkdir -p "$dir"
  cat > "$dir/child.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$1/tests/lib.sh"
OUTPUT_DIR=$2
LAB=$(fm_test_tmproot signal)
printf '%s\n' "$LAB" > "$OUTPUT_DIR/lab"
tmux -S "$LAB/dedicated.sock" new-session -d -s disposable 'exec sleep 60' || exit 1
stop_owned() {
  [ -f "$LAB/.fm-test-fixture" ] || exit 3
  tmux -S "$LAB/dedicated.sock" kill-server || exit 4
  printf 'stopped\n' > "$OUTPUT_DIR/stopped"
}
trap 'fm_test_signal_cleanup 143 stop_owned' TERM
printf 'ready\n' > "$OUTPUT_DIR/ready"
while :; do sleep 0.1; done
SH
  bash "$dir/child.sh" "$ROOT" "$dir" > "$dir/child.log" 2>&1 &
  pid=$!
  for i in $(seq 1 50); do
    [ -f "$dir/ready" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  [ -f "$dir/ready" ] || fail "signal fixture did not start: $(cat "$dir/child.log")"
  lab=$(cat "$dir/lab")
  kill -TERM "$pid" || fail 'could not signal disposable fixture'
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ] || fail "signal cleanup returned $rc: $(cat "$dir/child.log")"
  [ -f "$dir/stopped" ] || fail 'signal cleanup did not stop the recorded server'
  [ ! -e "$lab" ] || fail 'signal cleanup left the registered lab behind'
  pass 'signal cleanup stops recorded server before removing its lab'
)

test_timed_suite_reaps_child_tmux() (
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip: tmux not installed'; exit 0; }
  local dir="$TMP_ROOT/tmux-runner-timeout" repo mode topology label rc root server_pid i status
  local -a jobs
  repo="$dir/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/lib.sh" "$ROOT/tests/git-config-helpers.sh" \
    "$ROOT/tests/tmux-helpers.sh" "$repo/tests/"
  cat > "$repo/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
if [ "${FM_TEST_NESTED:-0}" = 1 ] && [ "${FM_TEST_LEAF:-0}" != 1 ]; then
  FM_TEST_LEAF=1 bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 30 tests/fm-test-run.test.sh
  exit $?
fi
printf '%s\n' "$FM_TEST_TMUX_ROOT" > "$FM_TEST_CHILD_ROOT_FILE"
tmux new-session -d -s disposable 'exec sleep 600' || exit 1
tmux display-message -p '#{pid}' > "$FM_TEST_CHILD_SERVER_PID_FILE"
mkdir -m 700 "$FM_TEST_TMUX_ROOT/recorded" || exit 1
printf '%s\n' "$$" > "$FM_TEST_TMUX_ROOT/recorded/.fm-test-fixture"
tmux -S "$FM_TEST_TMUX_ROOT/recorded/dedicated.sock" new-session -d -s explicit 'exec sleep 600' || exit 1
tmux -S "$FM_TEST_TMUX_ROOT/recorded/dedicated.sock" display-message -p '#{pid}' >> "$FM_TEST_CHILD_SERVER_PID_FILE"
TMUX_TMPDIR="$FM_TEST_TMUX_ROOT/recorded" tmux -L fm-lab new-session -d -s lab-named 'exec sleep 600' || exit 1
TMUX_TMPDIR="$FM_TEST_TMUX_ROOT/recorded" tmux -L fm-lab display-message -p '#{pid}' >> "$FM_TEST_CHILD_SERVER_PID_FILE"
trap '' TERM
sleep 600
SH
  chmod +x "$repo/tests/fm-test-run.test.sh"
  cleanup_timed_fixture() {
    local file recorded
    for file in "$dir"/root.*; do
      [ -s "$file" ] || continue
      recorded=$(cat "$file")
      FM_TEST_TMUX_ROOT="$recorded" fm_test_tmux_cleanup
    done
  }
  trap cleanup_timed_fixture EXIT
  for mode in serial captured; do
    if [ "$mode" = serial ]; then jobs=(--jobs 1); else jobs=(--jobs 2); fi
    for topology in direct nested; do
      label="$mode.$topology"
      rc=0
      ( cd "$repo" && FM_TEST_NESTED=$([ "$topology" = nested ] && printf 1 || printf 0) \
        FM_TEST_CHILD_ROOT_FILE="$dir/root.$label" \
        FM_TEST_CHILD_SERVER_PID_FILE="$dir/pid.$label" \
        bin/fm-test-run.sh "${jobs[@]}" --per-script-timeout-secs 3 \
        tests/fm-test-run.test.sh ) > "$dir/$label.out" 2>&1 || rc=$?
      [ "$rc" -eq 1 ] || fail "$label timed runner returned $rc: $(cat "$dir/$label.out")"
      assert_grep 'exit=124' "$dir/$label.out" "$label suite did not time out"
      [ -s "$dir/root.$label" ] && [ "$(wc -l < "$dir/pid.$label")" -eq 3 ] \
        || fail "$label suite did not start three disposable servers"
      root=$(cat "$dir/root.$label")
      [ ! -e "$root" ] || fail "$label runner left the child socket root"
      while IFS= read -r server_pid; do
        for i in $(seq 1 50); do
          status=$(ps -p "$server_pid" -o stat= 2>/dev/null || true)
          status=${status//[[:space:]]/}
          case "$status" in ''|Z*) break ;; esac
          sleep 0.1
        done
        case "$status" in ''|Z*) ;; *) fail "$label runner left server $server_pid running" ;; esac
      done < "$dir/pid.$label"
    done
  done
  pass 'streamed and captured timeouts reap nested named and explicit child tmux servers'
)

test_grok_failed_cell_preserves_server() (
  [ -n "${FM_TEST_TMUX_REAL:-}" ] && command -v jq >/dev/null 2>&1 || {
    echo 'skip: tmux and jq are required for the Grok failure fixture'
    exit 0
  }
  local dir="$TMP_ROOT/grok-failed-cell" cell rc=0
  mkdir -p "$dir"
  cat > "$dir/fake-grok" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'fake-grok\n'; exit 0; fi
exit 7
SH
  chmod +x "$dir/fake-grok"
  : > "$dir/auth.json"
  cleanup_grok_cell() {
    for cell in "$dir"/fm-grok-stop-native.*; do
      [ -f "$cell/.fm-test-fixture" ] || continue
      "$FM_TEST_TMUX_REAL" -S "$cell/dedicated.sock" kill-server >/dev/null 2>&1 || true
    done
  }
  trap cleanup_grok_cell EXIT
  TMPDIR="$dir" FM_GROK_STOP_LIVE_E2E=1 FM_GROK_STOP_LIVE_TIMEOUT=5 \
    FM_GROK_NATIVE_BIN="$dir/fake-grok" FM_GROK_LEGACY_BIN="$dir/fake-grok" \
    FM_GROK_AUTH_FILE="$dir/auth.json" bash "$ROOT/tests/fm-grok-stop-live-e2e.test.sh" \
    > "$dir/suite.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'fake Grok failure unexpectedly passed'
  cell=$(sed -n 's/^blocked: preserving failed isolated Grok cell at //p' "$dir/suite.log")
  [ -n "$cell" ] && [ -f "$cell/.fm-test-fixture" ] || fail "failed Grok cell was not preserved: $(cat "$dir/suite.log")"
  "$FM_TEST_TMUX_REAL" -S "$cell/dedicated.sock" has-session -t native-e2e \
    || fail 'failed Grok cell server was stopped before inspection'
  pass 'failed Grok cell retains its recorded disposable server for inspection'
)

test_standalone_afk_avoids_operator_socket() (
  [ -n "${FM_TEST_TMUX_REAL:-}" ] || { echo 'skip: tmux not installed'; exit 0; }
  if command -v herdr >/dev/null 2>&1; then
    echo 'skip: standalone AFK sentinel check requires a tmux-only host'
    exit 0
  fi
  local sentinel_dir sentinel rc=0
  sentinel_dir=$(mktemp -d /tmp/fmo.XXXXXX) || fail 'could not create AFK operator sentinel directory'
  sentinel="$sentinel_dir/operator"
  cleanup_afk_sentinel() {
    "$FM_TEST_TMUX_REAL" -S "$sentinel" kill-server >/dev/null 2>&1 || true
    rm -rf "$sentinel_dir"
  }
  trap cleanup_afk_sentinel EXIT
  "$FM_TEST_TMUX_REAL" -S "$sentinel" -f /dev/null new-session -d -s protected 'exec sleep 600' \
    || fail 'could not start AFK operator sentinel'
  "$FM_TEST_TMUX_REAL" -S "$sentinel" set-hook -g session-created \
    "run-shell 'printf contact >> $sentinel_dir/contact'" \
    || fail 'could not arm AFK sentinel contact detector'
  TMUX="$sentinel,0,0" TMUX_TMPDIR="$sentinel_dir" \
    bash "$ROOT/tests/fm-afk-launch.test.sh" > "$sentinel_dir/afk.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "standalone AFK suite failed: $(grep '^not ok -' "$sentinel_dir/afk.log" || tail -n 20 "$sentinel_dir/afk.log")"
  [ ! -e "$sentinel_dir/contact" ] || fail 'standalone AFK suite created a session on operator sentinel'
  "$FM_TEST_TMUX_REAL" -S "$sentinel" has-session -t protected \
    || fail 'standalone AFK suite stopped operator sentinel'
  pass 'standalone AFK suite keeps an inherited operator server untouched'
)

test_tmux_isolation || fail 'tmux fixture isolation'
test_tmux_cleanup_after_trap_override || fail 'tmux fixture trap cleanup'
test_tmux_signal_cleanup || fail 'tmux fixture signal cleanup'
test_timed_suite_reaps_child_tmux || fail 'timed suite tmux cleanup'
test_grok_failed_cell_preserves_server || fail 'Grok failed-cell preservation'
test_standalone_afk_avoids_operator_socket || fail 'standalone AFK fixture isolation'
test_git_config_isolation || fail "Git fixture config isolation"
test_agent_standin_survives_a_multicall_sleep || fail "agent stand-in multicall case"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
