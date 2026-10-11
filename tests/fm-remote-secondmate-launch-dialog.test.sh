#!/usr/bin/env bash
# tests/fm-remote-secondmate-launch-dialog.test.sh - a remote second-mate launch
# must not report success while the agent is parked on an interactive launch
# dialog instead of reading its charter.
#
# These assertions drive the real chain - parent fm-spawn -> fm-on -> the real
# remote entrypoint -> fm-remote-secondmate-control -> the remote host's own
# fm-spawn - over the deterministic generic SSH boundary, against the stateful
# fake Herdr CLI whose pane screen the test controls. The dialog text itself is
# vendor-rendered, so tests/fm-launch-prompt-signals-live-e2e.test.sh owns the
# proof that the real Claude Code renders what the fixture screen holds here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-launch-dialog)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ROUTE_STATE="$REMOTE_HOME/state/parent-route"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
SCREEN="$HERDR_STATE.screen"
CLAIMS="$TMP_ROOT/claims"
ACCOUNT_HOME="$TMP_ROOT/account-home"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS" \
  "$ACCOUNT_HOME"
cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true
  fi
  # A claude secondmate spawn leaves a read-only hooks directory in the home.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
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

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = fresh-box ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account; tests/fm-remote-doctor.test.sh owns
# the doctor's behavior against controlled account fixtures.
argv=()
while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(printf '%s' "$4" | base64 --decode 2>/dev/null)
if [ "${argv[0]:-}" = fm-remote-doctor.sh ]; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
# A claude launch records workspace trust in the launching account's own Claude
# store, and the real entrypoint always resolves that account as the RUNNER's.
# So the launch leg alone runs the same tracked command under the remote job
# worker's empty-environment shape with a fixture account home, plus the
# shortened confirmation window a fake agent needs. Every other leg still goes
# through the real entrypoint.
if [ "${argv[0]:-}" = fm-remote-secondmate-control.sh ] && [ "${argv[1]:-}" = launch ]; then
  exec /usr/bin/env -i \
    "PATH=$FM_FAKE_REMOTE_ROOT/bin:$PATH" \
    "HOME=$FM_FAKE_ACCOUNT_HOME" \
    "FM_HOME=$FM_FAKE_REMOTE_HOME" \
    "FM_ROOT_OVERRIDE=$FM_FAKE_REMOTE_ROOT" \
    FM_REMOTE_JOB_ACTIVE=1 \
    "FM_REMOTE_LAUNCH_CONFIRM_POLLS=$FM_FAKE_CONFIRM_POLLS" \
    FM_REMOTE_LAUNCH_CONFIRM_INTERVAL=0.1 \
    "$FM_FAKE_REMOTE_ROOT/bin/${argv[0]}" "${argv[@]:1}"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'claude\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'claude\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  FM_FAKE_REMOTE_ROOT="$REMOTE_ROOT" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" \
  FM_FAKE_ACCOUNT_HOME="$ACCOUNT_HOME" FM_FAKE_CONFIRM_POLLS="${CONFIRM_POLLS:-4}" \
  "$@"
}

# The screen the real Claude Code renders once per machine before a
# --dangerously-skip-permissions session starts, with the selection on the
# declining option.
park_on_bypass_dialog() {
  cat > "$SCREEN" <<'SCREEN'
────────────────────────────────────────────────────────────────────────────────
  WARNING: Claude Code running in Bypass Permissions mode

  In Bypass Permissions mode, Claude Code will not ask for your approval before running potentially dangerous commands.
  This mode should only be used in a sandboxed container/VM that has restricted internet access and can easily be restored if damaged.

  By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode.

  https://code.claude.com/docs/en/security

  ❯ No, exit
    Yes, I accept

  Enter to confirm · Esc to cancel
SCREEN
}

# What the agent's own hook does the moment it starts reading its charter.
agent_starts_charter_turn() {
  "$REMOTE_ROOT/bin/fm-busy-event.sh" apply "$ROUTE_STATE" ios busy --current-gen \
    --source claude-hook --event user-prompt-submit
}

pane_writes() { grep -c '^pane send-' "$HERDR_LOG" || true; }

FM_SECONDMATE_CHARTER='Own iOS delivery on the fresh box.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios fresh-box "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route"

# --- first launch on a fresh host: parked on the dialog ----------------------
park_on_bypass_dialog
: > "$HERDR_LOG"
if out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then
  fail "a remote launch parked on the Bypass Permissions dialog reported success: $out"
fi
assert_contains "$out" 'Bypass Permissions' "the refusal must name the dialog the agent is parked on"
assert_contains "$out" 'Yes, I accept' "the refusal must name the option a person has to choose"
assert_contains "$out" 'fresh-box' "the refusal must name the host the one-time step is taken on"
assert_not_contains "$out" 'spawned ios' "a parked launch must not print the spawn success line"
assert_absent "$PARENT/state/ios.meta" "a parked launch must not publish the parent's endpoint record"
if grep -Eq '^pane send-keys .*([Dd]own|[Uu]p|[Yy]es)' "$HERDR_LOG"; then
  fail "the launch tried to move or answer the dialog: $(grep '^pane send-keys' "$HERDR_LOG")"
fi
pass "first launch: a remote second mate parked on the Bypass Permissions dialog fails with the one-time step named"

# --- rerun while still parked: the live endpoint is not proof of a start -----
: > "$HERDR_LOG"
if out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then
  fail "a rerun against the still-parked endpoint reported success: $out"
fi
assert_contains "$out" 'Bypass Permissions' "the rerun refusal must still name the dialog"
assert_absent "$PARENT/state/ios.meta" "a rerun against a parked endpoint must not publish the parent's endpoint record"
[ "$(pane_writes)" = 0 ] \
  || fail "checking a parked endpoint must send nothing into its pane: $(grep '^pane send-' "$HERDR_LOG")"
pass "rerun while parked: the same refusal, and nothing is typed or keyed into the dialog"

# --- a person accepts once on the host: the same command converges -----------
rm -f "$SCREEN"
agent_starts_charter_turn || fail "the fixture could not record the agent's first turn"
: > "$HERDR_LOG"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "the rerun after the dialog was accepted failed: $out"
assert_contains "$out" 'spawned ios harness=claude' "the accepted launch must report the spawn"
assert_present "$PARENT/state/ios.meta" "the accepted launch must publish the parent's endpoint record"
assert_present "$ACCOUNT_HOME/.claude.json" "the launch leg did not run under the fixture account home"
[ "$(pane_writes)" = 0 ] \
  || fail "adopting the accepted endpoint must not launch a second agent into it: $(grep '^pane send-' "$HERDR_LOG")"
pass "after acceptance: rerunning the launch adopts the running agent and reports success"

# --- an ordinary launch on a host that already accepted ----------------------
rm -f "$PARENT/state/ios.meta" "$SCREEN"
reset_remote_herdr_fixture "$HERDR_STATE"
: > "$HERDR_LOG"
(
  for _ in $(seq 1 200); do
    if grep -q "^pane send-text [^ ]* \\. '.*' --session " "$HERDR_LOG" 2>/dev/null; then
      agent_starts_charter_turn && exit 0
    fi
    sleep 0.05
  done
) &
starter=$!
out=$(CONFIRM_POLLS=100 remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "an ordinary remote claude launch failed: $out"
wait "$starter" || fail "the fixture never saw the launch command reach the pane"
assert_contains "$out" 'spawned ios harness=claude' "an ordinary launch must report the spawn"
assert_present "$PARENT/state/ios.meta" "an ordinary launch must publish the parent's endpoint record"
pass "ordinary launch: an agent that starts its charter turn is reported as launched"

# --- no recognized dialog and no turn yet: the launch is not refused ---------
rm -f "$PARENT/state/ios.meta"
reset_remote_herdr_fixture "$HERDR_STATE"
out=$(CONFIRM_POLLS=2 remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "a launch with no recognized dialog on screen was refused: $out"
assert_present "$PARENT/state/ios.meta" "a launch with no recognized dialog must still publish the parent's endpoint record"
pass "no recognized dialog: a launch whose first turn has not started within the window is still reported"

echo "ALL TESTS PASSED"
