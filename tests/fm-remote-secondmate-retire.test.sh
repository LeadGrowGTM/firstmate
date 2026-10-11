#!/usr/bin/env bash
# tests/fm-remote-secondmate-retire.test.sh - retiring a remote secondmate
# completes, converges when rerun, and clears the parent's own records.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it. Every case seeds and launches through the
# real parent-side tools on a harness that arms the busy-state contract, so the
# host-local endpoint record carries the generation a retirement must retire.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-retire)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
CLAIMS="$TMP_ROOT/claims"
# A suite-private id keeps the launch temp root, which is keyed by id alone,
# apart from every other remote-secondmate suite.
SM=retiree
SID=remote-reply-$SM
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # The published pid is the serving child; killing it alone lets its
    # detached supervisor restart it while the fixture root is being removed.
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  # A launched home holds the spawn-owned hook directory, which is read-only.
  chmod -R u+w "$REMOTE_HOME" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# Materialize the current branch as the remote host's tracked code root: a real
# git repository, because provisioning clones the home from it.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
git init -q --bare "$TMP_ROOT/firstmate-origin.git"
git -C "$REMOTE_ROOT" remote add origin "file://$TMP_ROOT/firstmate-origin.git"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$TMP_ROOT/firstmate-origin.git" symbolic-ref HEAD refs/heads/main
printf 'claude\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"

# FM_FAKE_SSH_MODE=retire-reports-failure runs the host's retirement to
# completion and then reports a failure, which is what a parent sees when the
# host finished the destructive part and still exited non-zero.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..1]);
' "$4")
IFS=$'\t' read -r command_name command_action <<EOF
$command_fields
EOF
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = retire-reports-failure ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$command_action" = retire ]; then
  "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
  printf 'error: simulated failure reported after the host retired the home\n' >&2
  exit 1
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

# Seed and launch one remote secondmate, leaving both machines' records in the
# shape a real launch leaves them.
launch_mate() {
  local out
  reset_remote_herdr_fixture "$HERDR_STATE"
  out=$(FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
    FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
    remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$SM" remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects 2>&1) \
    || fail "remote seed failed: $out"
  out=$(remote_env "$ROOT/bin/fm-spawn.sh" "$SM" --secondmate 2>&1) || fail "remote launch failed: $out"
  assert_grep 'remote_host=remote-mac' "$PARENT/state/$SM.meta" "launch did not record the remote route"
  assert_grep 'busy_gen=g' "$REMOTE_HOME/state/parent-route/$SM.meta" \
    "the launched endpoint carries no busy-state generation, so this suite would not exercise its retirement"
  assert_present "$PARENT/state/procevent/$SID.source" "launch did not arm the reply source"
}

# The host's own retirement verb, run the way the transport runs it.
host_retire() { # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" retire "$SM" 2>&1
}

# Every record the parent keeps for the retired secondmate must be gone.
assert_parent_records_cleared() { # <context>
  local context=$1 leftover
  assert_absent "$PARENT/state/$SM.meta" "$context: the parent still holds the secondmate's task record"
  assert_no_grep "- $SM " "$PARENT/data/secondmates.md" "$context: the parent still holds the registry route"
  assert_absent "$PARENT/state/procevent/$SID.source" "$context: the parent still holds the reply-source registration"
  leftover=$(remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | awk -v id="$SID" 'NR > 1 && $1 == id')
  [ -z "$leftover" ] || fail "$context: the parent still lists the reply source: $leftover"
}

assert_parent_records_preserved() { # <context>
  assert_present "$PARENT/state/$SM.meta" "$1: the parent dropped the secondmate's task record"
  assert_grep "- $SM " "$PARENT/data/secondmates.md" "$1: the parent dropped the registry route"
}

assert_host_retired() { # <context>
  assert_absent "$REMOTE_HOME" "$1: the remote home path still exists"
  [ "$(jq -r '.tabs | length' "$HERDR_STATE")" = 0 ] || fail "$1: the remote endpoint pane was not closed"
}

# --- one retirement completes, and retiring the same home again converges ---
launch_mate
out=$(remote_env "$ROOT/bin/fm-teardown.sh" "$SM" 2>&1) && rc=0 || rc=$?
expect_code 0 "$rc" "retiring a launched remote secondmate should succeed"$'\n'"$out"
assert_contains "$out" "teardown $SM complete (remote remote-mac:$REMOTE_HOME)" \
  "the retirement did not report completion"
assert_host_retired "first retirement"
assert_parent_records_cleared "first retirement"
pass "a remote secondmate retirement completes in one run and clears the parent's records"

out=$(host_retire "$REMOTE_HOME") && rc=0 || rc=$?
expect_code 0 "$rc" "retiring an already-retired remote home should converge"$'\n'"$out"
assert_contains "$out" "already-retired: $SM" "a second retirement did not report the home as already retired"
assert_absent "$REMOTE_HOME" "a second retirement left a directory at the retired home path"
out=$(host_retire "$REMOTE_HOME") && rc=0 || rc=$?
expect_code 0 "$rc" "a third retirement should converge the same way"$'\n'"$out"
assert_absent "$REMOTE_HOME" "a third retirement left a directory at the retired home path"
pass "retiring the same remote home twice converges and leaves the path absent"

# --- the parent's own rerun of a finished retirement says so ----------------
out=$(remote_env "$ROOT/bin/fm-teardown.sh" "$SM" 2>&1) && rc=0 || rc=$?
expect_code 0 "$rc" "the parent's rerun of a finished retirement should converge"$'\n'"$out"
assert_contains "$out" "teardown $SM: already retired" "the parent's rerun did not report the secondmate as already retired"
assert_not_contains "$out" 'refused' "the parent's rerun of a finished retirement still reads as a refusal"
assert_parent_records_cleared "parent rerun"
# The answer rests on the recorded retirement, so an id this home never retired
# and a retired id whose record path is no longer simply absent are refused.
out=$(remote_env "$ROOT/bin/fm-teardown.sh" never-launched 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "tearing down an id this home never held was reported as already retired: $out"
assert_contains "$out" 'teardown refused: task record is not a regular file' \
  "an id this home never held must keep the missing-record refusal"
ln -s "$TMP_ROOT/no-such-record" "$PARENT/state/$SM.meta"
out=$(remote_env "$ROOT/bin/fm-teardown.sh" "$SM" 2>&1) && rc=0 || rc=$?
rm -f "$PARENT/state/$SM.meta"
[ "$rc" -ne 0 ] || fail "a retired id whose record path holds a dangling link was reported as already retired: $out"
assert_not_contains "$out" 'already retired' "a broken record must keep its refusal"
pass "the parent's rerun of a finished retirement reports already retired, and a missing or broken record is still refused"

# --- a rerun after a partial failure finishes the parent's own cleanup ------
launch_mate
out=$(FM_FAKE_SSH_MODE=retire-reports-failure remote_env "$ROOT/bin/fm-teardown.sh" "$SM" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a retirement whose host reported failure was reported as complete"
assert_host_retired "partial failure"
assert_parent_records_preserved "partial failure"
# The route is still registered, so the parent keeps addressing the retired
# home; each such command leaves an empty directory tree at its path.
out=$(remote_env "$ROOT/bin/fm-on.sh" "$SM" fm-remote-secondmate-control.sh state "$SM" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a state read of a retired remote home did not refuse: $out"
mkdir -p "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/data/.parent-route"
[ -z "$(find "$REMOTE_HOME" ! -type d)" ] || fail "the leftover fixture is not an empty directory tree"
out=$(remote_env "$ROOT/bin/fm-teardown.sh" "$SM" 2>&1) && rc=0 || rc=$?
expect_code 0 "$rc" "rerunning a retirement after a partial failure should converge"$'\n'"$out"
assert_contains "$out" "teardown $SM complete (remote remote-mac:$REMOTE_HOME)" \
  "the rerun did not report completion"
assert_host_retired "rerun after partial failure"
assert_parent_records_cleared "rerun after partial failure"
pass "a rerun after a partial failure converges over an empty leftover home and clears the parent's records"

# --- only an empty tree counts as already retired ---------------------------
UNSEEDED="$TMP_ROOT/unseeded-home"
mkdir -p "$UNSEEDED/state/parent-route"
printf 'not ours\n' > "$UNSEEDED/state/parent-route/keep"
out=$(host_retire "$UNSEEDED") && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "retirement accepted a directory that holds content and no home marker"
assert_contains "$out" 'remote home is not a seeded secondmate home' \
  "retirement refused an unseeded directory for the wrong reason"
[ "$(cat "$UNSEEDED/state/parent-route/keep")" = 'not ours' ] \
  || fail "a refused retirement changed the content of an unseeded directory"
LINKED="$TMP_ROOT/linked-home"
mkdir -p "$LINKED"
ln -s "$UNSEEDED/state/parent-route/keep" "$LINKED/link"
out=$(host_retire "$LINKED") && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "retirement accepted a directory that holds a symlink and no home marker"
[ -L "$LINKED/link" ] || fail "a refused retirement removed a symlink from an unseeded directory"
pass "retirement still refuses an unseeded directory that holds anything but empty directories"

echo "ALL TESTS PASSED"
