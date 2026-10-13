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
#
# The same launches also carry the agent's Remote Control session link back to
# the parent. The link is read from Claude Code's own per-session record, whose
# shape is likewise vendor-owned; the records written here hold the fields
# Claude Code 2.1.296 writes.
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
  kill "${AGENT_PID:-}" "${PANE_TOOL_PID:-}" "${PANE_SHELL_PID:-}" 2>/dev/null || true
  # A claude secondmate spawn leaves a read-only hooks directory in the home.
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap 'cleanup; fm_test_tmux_cleanup' EXIT

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
# So the launch and relaunch legs alone run the same tracked command under the
# remote job worker's empty-environment shape with a fixture account home, plus
# the shortened confirmation window a fake agent needs. Every other leg still
# goes through the real entrypoint.
if [ "${argv[0]:-}" = fm-remote-secondmate-control.sh ] \
  && { [ "${argv[1]:-}" = launch ] || [ "${argv[1]:-}" = relaunch ]; }; then
  exec /usr/bin/env -i \
    "PATH=$FM_FAKE_REMOTE_ROOT/bin:$PATH" \
    "HOME=$FM_FAKE_ACCOUNT_HOME" \
    "FM_HOME=$FM_FAKE_REMOTE_HOME" \
    "FM_ROOT_OVERRIDE=$FM_FAKE_REMOTE_ROOT" \
    FM_REMOTE_JOB_ACTIVE=1 \
    "FM_REMOTE_LAUNCH_CONFIRM_POLLS=$FM_FAKE_CONFIRM_POLLS" \
    FM_REMOTE_LAUNCH_CONFIRM_INTERVAL=0.1 \
    FM_REMOTE_CONTROL_LINK_POLLS=2 \
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
# declining option. `narrow` is the same screen as a real remote host's agent
# pane holds it: 54 columns wide with no client attached, so the heading breaks
# after "Bypass Permissions" and "mode" lands on a line of its own.
park_on_bypass_dialog() { # [narrow]
  if [ "${1:-}" = narrow ]; then
    cat > "$SCREEN" <<'SCREEN'
──────────────────────────────────────────────────────
  WARNING: Claude Code running in Bypass Permissions
  mode
  In Bypass Permissions mode, Claude Code will not
  ask for your approval before running potentially
  dangerous commands.
  This mode should only be used in a sandboxed
  container/VM that has restricted internet access
  and can easily be restored if damaged.
  By proceeding, you accept all responsibility for
  actions taken while running in Bypass Permissions
  mode.
  https://code.claude.com/docs/en/security
  ❯ No, exit
    Yes, I accept
  Enter to confirm · Esc to cancel
SCREEN
    ! grep -q 'Claude Code running in Bypass Permissions mode' "$SCREEN" \
      || fail "the 54-column screen holds the dialog heading on one line, so it pins nothing"
    return 0
  fi
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

# Claude Code's own record of one running session, as the account that launched
# the agent holds it. <bridge> empty means a session that has not registered
# for Remote Control.
SESSIONS="$ACCOUNT_HOME/.claude/sessions"
session_record() { # <pid> <cwd> <started-ms> <bridge>
  mkdir -p "$SESSIONS"
  jq -n --argjson pid "$1" --arg cwd "$2" --argjson started "$3" --arg bridge "$4" \
    '{pid: $pid, cwd: $cwd, startedAt: $started, kind: "interactive", entrypoint: "cli"}
     + (if $bridge == "" then {} else {bridgeSessionId: $bridge} end)' > "$SESSIONS/$1.json"
}
# A pid that named a process once and names none now.
( : ) &
EXITED_PID=$!
wait "$EXITED_PID"
# The process tree under the second mate's endpoint pane: the pane's shell, the
# Claude Code agent it runs, and one other process the pane also holds.
SLEEP_BIN=$(command -v sleep) || fail "sleep not found"
(
  ( exec -a claude "$SLEEP_BIN" 600 ) &
  printf '%s\n' "$!" > "$TMP_ROOT/agent.pid"
  "$SLEEP_BIN" 600 &
  printf '%s\n' "$!" > "$TMP_ROOT/pane-tool.pid"
  wait
) &
PANE_SHELL_PID=$!
for _ in $(seq 1 100); do
  [ ! -s "$TMP_ROOT/pane-tool.pid" ] || break
  sleep 0.05
done
AGENT_PID=$(cat "$TMP_ROOT/agent.pid" 2>/dev/null)
PANE_TOOL_PID=$(cat "$TMP_ROOT/pane-tool.pid" 2>/dev/null)
[ -n "$AGENT_PID" ] && [ -n "$PANE_TOOL_PID" ] || fail "the fixture pane's process tree did not start"
printf '%s\n' "$PANE_SHELL_PID" > "$HERDR_STATE.shell-pid"

FM_SECONDMATE_CHARTER='Own iOS delivery on the fresh box.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios fresh-box "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route"

# --- first launch on a fresh host: parked on the dialog ----------------------
# In the 54-column pane a real host has, which wraps the dialog heading.
park_on_bypass_dialog narrow
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
pass "first launch: a remote second mate parked on the Bypass Permissions dialog wrapped by a 54-column pane fails with the one-time step named"

# --- rerun while still parked: the live endpoint is not proof of a start -----
# The same dialog in a pane wide enough to hold its heading on one line.
park_on_bypass_dialog
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
# The running agent's session has registered for Remote Control. Beside it sit
# the records that must not answer for it: an earlier launch whose process has
# exited, a session in another directory, and one whose id is not a session id.
rm -f "$SCREEN"
agent_starts_charter_turn || fail "the fixture could not record the agent's first turn"
session_record "$AGENT_PID" "$REMOTE_HOME" 2000 session_01LiveAgent
session_record "$EXITED_PID" "$REMOTE_HOME" 9000 session_01EarlierLaunch
session_record "$PPID" "$TMP_ROOT" 9500 session_01OtherDirectory
session_record 1 "$REMOTE_HOME" 9900 'session_01 remote_host=elsewhere'
: > "$HERDR_LOG"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "the rerun after the dialog was accepted failed: $out"
assert_contains "$out" 'spawned ios harness=claude' "the accepted launch must report the spawn"
assert_present "$PARENT/state/ios.meta" "the accepted launch must publish the parent's endpoint record"
assert_contains "$out" 'remote control: https://claude.ai/code/session_01LiveAgent' \
  "the launch must report the running agent's Remote Control link"
grep -qxF -- 'remote_control_url=https://claude.ai/code/session_01LiveAgent' "$PARENT/state/ios.meta" \
  || fail "the launch must record the running agent's Remote Control link"
[ "$(grep -c 'remote_control_url=' "$PARENT/state/ios.meta")" = 1 ] \
  || fail "the parent's record must hold exactly one Remote Control link: $(grep '^remote_control_url=' "$PARENT/state/ios.meta")"
assert_present "$ACCOUNT_HOME/.claude.json" "the launch leg did not run under the fixture account home"
[ "$(pane_writes)" = 0 ] \
  || fail "adopting the accepted endpoint must not launch a second agent into it: $(grep '^pane send-' "$HERDR_LOG")"
pass "after acceptance: rerunning the launch adopts the running agent, reports success, and records its Remote Control link"

# --- an ordinary launch on a host that already accepted ----------------------
# This agent's session never registers for Remote Control, which is also what a
# home with Remote Control off looks like from here: the launch stands, and no
# link is reported or recorded. The records an earlier launch left in this home
# do not answer for it, although a stop and resume has handed their pids to
# live processes: one unrelated to the pane, one the pane holds beside the agent.
rm -f "$PARENT/state/ios.meta" "$SCREEN"
rm -f "$SESSIONS"/*.json
session_record "$AGENT_PID" "$REMOTE_HOME" 2000 ''
session_record "$$" "$REMOTE_HOME" 1000 session_01BeforeResume
session_record "$PANE_TOOL_PID" "$REMOTE_HOME" 1500 session_01BeforeResumeToo
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
assert_not_contains "$out" 'remote control:' "a launch with no registered session must report no Remote Control link"
assert_no_grep 'remote_control_url=' "$PARENT/state/ios.meta" \
  "a launch with no registered session must record no Remote Control link"
pass "ordinary launch: an agent that starts its charter turn is reported as launched, with no link when its session has none and only leftover records carry one"

# --- no recognized dialog and no turn yet: the launch is not refused ---------
rm -f "$PARENT/state/ios.meta"
reset_remote_herdr_fixture "$HERDR_STATE"
session_record "$AGENT_PID" "$REMOTE_HOME" 2000 session_01BeforeRelaunch
out=$(CONFIRM_POLLS=2 remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "a launch with no recognized dialog on screen was refused: $out"
assert_present "$PARENT/state/ios.meta" "a launch with no recognized dialog must still publish the parent's endpoint record"
grep -qxF -- 'remote_control_url=https://claude.ai/code/session_01BeforeRelaunch' "$PARENT/state/ios.meta" \
  || fail "a launch whose session is already registered must record its Remote Control link"
pass "no recognized dialog: a launch whose first turn has not started within the window is still reported"

# --- relaunch: the replacement agent parks on the same dialog ----------------
# The previous agent ran a turn and has already exited, so the host-local
# control plane goes straight to launching the replacement into the same pane.
agent_starts_charter_turn || fail "the fixture could not record the previous agent's turn"
jq '.typed = {} | .working = {}' "$HERDR_STATE" > "$HERDR_STATE.exited" \
  && mv "$HERDR_STATE.exited" "$HERDR_STATE"
park_on_bypass_dialog narrow
cp "$PARENT/state/ios.meta" "$TMP_ROOT/ios-before-relaunch.meta"
if out=$(remote_env "$ROOT/bin/fm-remote-secondmate-relaunch.sh" ios claude - - 2>&1); then
  fail "a remote relaunch parked on the Bypass Permissions dialog reported success: $out"
fi
assert_contains "$out" 'Bypass Permissions' "the relaunch refusal must name the dialog the agent is parked on"
assert_contains "$out" 'Yes, I accept' "the relaunch refusal must name the option a person has to choose"
cmp -s "$TMP_ROOT/ios-before-relaunch.meta" "$PARENT/state/ios.meta" \
  || fail "a parked relaunch must not republish the parent's endpoint record"
if grep -Eq '^pane send-keys .*([Dd]own|[Uu]p|[Yy]es)' "$HERDR_LOG"; then
  fail "the relaunch tried to move or answer the dialog: $(grep '^pane send-keys' "$HERDR_LOG")"
fi
pass "relaunch: a replacement agent parked on the Bypass Permissions dialog fails with the one-time step named"

# --- relaunch after acceptance: the replacement's first turn is reported ------
# The replacement registers a new session, so the link the parent held is dead.
jq '.typed = {} | .working = {}' "$HERDR_STATE" > "$HERDR_STATE.exited" \
  && mv "$HERDR_STATE.exited" "$HERDR_STATE"
rm -f "$SCREEN"
session_record "$EXITED_PID" "$REMOTE_HOME" 2000 session_01BeforeRelaunch
session_record "$AGENT_PID" "$REMOTE_HOME" 3000 session_01AfterRelaunch
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
out=$(CONFIRM_POLLS=100 remote_env "$ROOT/bin/fm-remote-secondmate-relaunch.sh" ios claude - - 2>&1) \
  || fail "an ordinary remote claude relaunch failed: $out"
wait "$starter" || fail "the fixture never saw the relaunch command reach the pane"
assert_contains "$out" 'relaunched ios harness=claude' "an ordinary relaunch must report the host's confirmation"
assert_contains "$out" 'remote control: https://claude.ai/code/session_01AfterRelaunch' \
  "the relaunch must report the replacement agent's Remote Control link"
grep -qxF -- 'remote_control_url=https://claude.ai/code/session_01AfterRelaunch' "$PARENT/state/ios.meta" \
  || fail "the relaunch must record the replacement agent's Remote Control link"
assert_no_grep 'session_01BeforeRelaunch' "$PARENT/state/ios.meta" \
  "the relaunch must not keep the previous session's dead link"
pass "ordinary relaunch: a replacement agent that starts its charter turn is reported as relaunched, and its link replaces the dead one"

echo "ALL TESTS PASSED"
