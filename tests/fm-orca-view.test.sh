#!/usr/bin/env bash
# tests/fm-orca-view.test.sh - bin/fm-orca-view.sh, the optional Orca view tab.
#
# Every tmux call goes to a REAL tmux server on a private socket, so the grouped
# view session, its selected window, and the identity the tab writes are what
# tmux itself reports. Orca is replaced by a fake command line that records each
# call, answers in Orca's JSON shape, and runs the tab's startup command the way
# an Orca terminal would, inside a detached window with an Orca identity in its
# environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

VIEW="$ROOT/bin/fm-orca-view.sh"
REAL_TMUX=$(command -v tmux)
TMP_ROOT=$(fm_test_tmproot fm-orca-view)
mkdir -p "$TMP_ROOT"
SOCKET="fm-orca-view-$$"
SHIM="$TMP_ROOT/shim"
ORCA_LOG="$TMP_ROOT/orca.log"

view_cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap view_cleanup EXIT

mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

# The fake Orca command line. `terminal create` runs the --command text in a
# detached window carrying an Orca identity, as an Orca terminal's shell would.
# FM_FAKE_ORCA_FAIL makes every call fail; FM_FAKE_ORCA_PINNED names a handle
# whose close Orca refuses as pinned.
cat > "$SHIM/orca-ide" <<'SH'
#!/usr/bin/env bash
set -u
printf 'WSL_INTEROP=%s %s\n' "${WSL_INTEROP:-}" "$*" >> "$FM_FAKE_ORCA_LOG"
if [ -n "${FM_FAKE_ORCA_FAIL:-}" ]; then
  printf '{"ok":false,"error":{"code":"runtime_unavailable"}}\n'
  exit 1
fi
case "$1 $2" in
  "terminal create")
    cmd=
    title=
    while [ $# -gt 0 ]; do
      case "$1" in
        --command) cmd=$2; shift 2 ;;
        --title) title=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    n=$(grep -c 'terminal create' "$FM_FAKE_ORCA_LOG")
    seq=$(($(cat "$FM_FAKE_ORCA_LOG.seq" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$seq" > "$FM_FAKE_ORCA_LOG.seq"
    tmux new-window -d -t "$FM_FAKE_ORCA_TAB_HOST:" -n "tab-$title-$seq" \
      env -u TMUX -u TMUX_PANE \
      ORCA_PANE_KEY="tab-$n:leaf-$n" ORCA_TAB_ID="tab-$n" ORCA_WORKTREE_ID="wt-1" \
      ORCA_AGENT_HOOK_ENDPOINT="/home/u/.orca-wsl/agent-hooks/x/endpoint.env" \
      ORCA_AGENT_HOOK_ENV=production ORCA_AGENT_HOOK_VERSION=1 \
      ORCA_AGENT_HOOK_PORT=4242 ORCA_AGENT_HOOK_TOKEN=not-for-the-pane \
      TERM=xterm sh -c "$cmd; sleep 30"
    printf '{"ok":true,"result":{"terminal":{"handle":"term-%s","tabId":"tab-%s"}}}\n' "$n" "$n"
    ;;
  "terminal close")
    shift 2
    handle=
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal) handle=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$handle" = "${FM_FAKE_ORCA_PINNED:-}" ]; then
      printf '{"ok":false,"error":{"code":"terminal_tab_pinned","message":"tab is pinned"}}\n'
      exit 1
    fi
    printf '{"ok":true,"result":{"closed":true,"ptyKilled":false}}\n'
    ;;
  *) printf '{"ok":false}\n'; exit 1 ;;
esac
SH
chmod +x "$SHIM/orca-ide"

# Orca's own test for "this terminal is running Claude" (its agent-detection
# regex, case-insensitive), in ERE form: a bare `claude` word or path leaf.
ORCA_CLAUDE_RE="(^|[[:space:];&|('\"\`])([^[:space:];&|('\"\`]*[\\/])?claude(\\.cmd|\\.exe)?(\$|[[:space:];&|)'\"\`])"
names_claude() { printf '%s\n' "$1" | grep -Eiq "$ORCA_CLAUDE_RE"; }

run_view() {  # <args...>: off WSL unless the caller sets FM_WSL_INTEROP_DIR
  PATH="$SHIM:$PATH" FM_ORCA_CLI="$SHIM/orca-ide" FM_FAKE_ORCA_LOG="$ORCA_LOG" \
    FM_FAKE_ORCA_TAB_HOST=tabs FM_ROOT_OVERRIDE="$TMP_ROOT/code-root" \
    FM_WSL_INTEROP_DIR="${FM_WSL_INTEROP_DIR:-$TMP_ROOT/no-wsl}" \
    "$VIEW" "$@"
}

wait_for_session() {  # <name>
  local i=0
  while [ "$i" -lt 100 ]; do
    "$SHIM/tmux" has-session -t "=$1" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# A base session whose windows include one named `claude`, as the primary's
# window often is, and a separate session that hosts the fake Orca tabs.
"$SHIM/tmux" new-session -d -s firstmate -n claude -x 120 -y 40 || fail "could not start the private tmux server"
"$SHIM/tmux" new-window -d -t firstmate: -n fm-dev
"$SHIM/tmux" new-session -d -s tabs -n idle
DEV_ID=$("$SHIM/tmux" display-message -p -t '=firstmate:fm-dev' '#{window_id}')
CLAUDE_ID=$("$SHIM/tmux" display-message -p -t '=firstmate:claude' '#{window_id}')

test_switch_values() {
  local cfg="$TMP_ROOT/cfg" out err
  mkdir -p "$cfg"
  assert_equals off "$(run_view enabled "$cfg")" "an absent switch is off"
  printf 'on\n' > "$cfg/orca-view-tabs"
  assert_equals on "$(run_view enabled "$cfg")" "on turns the tabs on"
  printf ' off \n' > "$cfg/orca-view-tabs"
  assert_equals off "$(run_view enabled "$cfg")" "off keeps the tabs off"
  printf 'yes\n' > "$cfg/orca-view-tabs"
  out=$(run_view enabled "$cfg" 2>"$TMP_ROOT/err")
  err=$(cat "$TMP_ROOT/err")
  assert_equals off "$out" "an unrecognized value is off"
  assert_contains "$err" "orca-view-tabs holds 'yes'" "an unrecognized value is named in a warning"
  pass "enabled: absent and off are off, on is on, anything else is off with a warning"
}

test_command_never_names_claude() {
  local cmd
  # Non-vacuous: the regex flags the shape a hand-opened tab used, which
  # selects the primary's window by its bare name.
  names_claude "tmux new-session -A -t firstmate -s orca-main \\; select-window -t claude" \
    || fail "the Orca agent regex must flag a bare claude window name"
  names_claude "tmux select-window -t 'claude'" \
    || fail "the Orca agent regex must flag a quoted claude window name"
  cmd=$(run_view command --target firstmate:claude --view-session orca-main --identity-file "$TMP_ROOT/id") \
    || fail "command failed for a window named claude"
  names_claude "$cmd" && fail "the tab command must never name claude, got: $cmd"
  assert_contains "$cmd" "attach-session -t '=orca-main'" "the tab attaches its view session by exact name"
  cmd=$(run_view command --target "firstmate:$DEV_ID" --view-session orca-dev) || fail "command failed by id"
  assert_contains "$cmd" "attach-session -t '=orca-dev'" "an id target is accepted"
  expect_code 1 "$(run_view command --target firstmate:nope --view-session orca-dev >/dev/null 2>&1; echo $?)" \
    "a missing window is refused"
  expect_code 2 "$(run_view command --target firstmate --view-session orca-dev >/dev/null 2>&1; echo $?)" \
    "a target without a window is invalid use"
  pass "command: attaches the view session without naming any window, so no launch line names claude"
}

test_open_views_the_window_and_writes_identity() {
  local out idfile="$TMP_ROOT/dev.identity" ident sel
  : > "$ORCA_LOG"
  out=$(run_view open --target firstmate:fm-dev --view-session orca-dev --title dev --identity-file "$idfile") \
    || fail "open failed: $out"
  assert_contains "$out" "handle=term-1" "open prints the Orca terminal handle"
  assert_contains "$out" "view_session=orca-dev" "open prints the view session"
  assert_contains "$out" "view_session_owned=1" "a view session this call creates is owned"
  assert_grep "terminal create --worktree path:$TMP_ROOT/code-root --title dev" "$ORCA_LOG" \
    "the tab is created on the code root's Orca worktree with its title"
  assert_no_grep '--shell' "$ORCA_LOG" "off WSL the tab keeps Orca's default shell"
  wait_for_session orca-dev || fail "open did not create its grouped view session"
  assert_equals "$DEV_ID" "$("$SHIM/tmux" show-options -v -t '=orca-dev:' @fm_view_window)" \
    "the view session records its agent's window by tmux id"
  assert_equals firstmate "$("$SHIM/tmux" display-message -p -t '=orca-dev:' '#{session_group}')" \
    "the view session is grouped with the base session"
  sel=$("$SHIM/tmux" display-message -p -t '=orca-dev:' '#{window_id}')
  assert_equals "$DEV_ID" "$sel" "the view session shows exactly the target window"
  assert_equals "$CLAUDE_ID" "$("$SHIM/tmux" display-message -p -t '=firstmate:' '#{window_id}')" \
    "the base session's own current window is untouched"
  ident=$(run_view identity --file "$idfile" --wait 10) || fail "identity was not reported"
  assert_absent "$idfile" "the identity file is removed once read"
  assert_not_contains "$ident" "TOKEN" "no hook token is carried into the pane"
  assert_not_contains "$ident" "PORT" "no hook port is carried into the pane"
  # shellcheck disable=SC2016
  assert_equals "tab-1:leaf-1|tab-1|wt-1|production|1" \
    "$(env -i sh -c "$ident"'; printf "%s|%s|%s|%s|%s" "$ORCA_PANE_KEY" "$ORCA_TAB_ID" "$ORCA_WORKTREE_ID" "$ORCA_AGENT_HOOK_ENV" "$ORCA_AGENT_HOOK_VERSION"')" \
    "the export line carries the tab's identity"
  # A second tab for the same view session reuses it instead of duplicating it.
  out=$(run_view open --target firstmate:fm-dev --view-session orca-dev --title dev) || fail "reopen failed: $out"
  assert_contains "$out" "handle=term-2" "the second open is its own tab"
  assert_contains "$out" "view_session_owned=0" "an existing view session is reused, not owned"
  assert_equals 1 "$("$SHIM/tmux" list-sessions -F '#{session_name}' | grep -c '^orca-dev$')" \
    "no duplicate view session"
  pass "open: one tab per call on a grouped view of exactly that window, reused when it exists, identity without secrets"
}

test_identity_filters_input() {
  local f="$TMP_ROOT/raw.identity" ident
  {
    printf 'ORCA_PANE_KEY=t:l\n'
    printf 'ORCA_TAB_ID=it'\''s\n'
    printf 'ORCA_AGENT_HOOK_ENDPOINT=/e/endpoint.env\n'
    printf 'ORCA_WORKTREE_ID=bad\033[2J\n'
    printf 'ORCA_AGENT_HOOK_TOKEN=secret\n'
    printf 'PATH=/evil\n'
  } > "$f"
  ident=$(run_view identity --file "$f" --wait 0) || fail "identity refused valid input"
  assert_not_contains "$ident" "secret" "a token is never exported"
  assert_not_contains "$ident" "PATH" "only Orca identity names are exported"
  assert_not_contains "$ident" "ORCA_WORKTREE_ID" "a value with control bytes is dropped"
  # shellcheck disable=SC2016
  assert_equals "it's" "$(env -i sh -c "$ident"'; printf "%s" "$ORCA_TAB_ID"')" "values survive shell quoting"
  expect_code 3 "$(run_view identity --file "$TMP_ROOT/never" --wait 0 >/dev/null 2>&1; echo $?)" \
    "an identity that never arrives steps aside"
  pass "identity: exports only valid Orca identity names and steps aside when none arrives"
}

test_unavailable_orca_steps_aside() {
  local out status
  out=$(FM_FAKE_ORCA_FAIL=1 run_view open --target firstmate:fm-dev --view-session orca-x 2>&1)
  status=$?
  expect_code 3 "$status" "a failing Orca steps aside"
  assert_contains "$out" "note:" "the step-aside is one note"
  out=$(PATH="$SHIM:$PATH" FM_ORCA_CLI="$TMP_ROOT/missing-orca" FM_WSL_INTEROP_DIR="$TMP_ROOT/no-wsl" \
    "$VIEW" open --target firstmate:fm-dev --view-session orca-x 2>&1)
  status=$?
  expect_code 3 "$status" "a missing Orca command line steps aside"
  "$SHIM/tmux" has-session -t '=orca-x' 2>/dev/null && fail "a step-aside must not leave a view session"
  pass "open: an unavailable Orca or command line steps aside with a note and leaves nothing behind"
}

test_wsl_uses_live_interop() {
  local wsl="$TMP_ROOT/wsl" probe="$TMP_ROOT/probe" out
  mkdir -p "$wsl"
  : > "$wsl/1_interop"
  : > "$wsl/2_interop"
  : > "$wsl/10_interop"
  cat > "$probe" <<'SH'
#!/bin/sh
case "$WSL_INTEROP" in */2_interop|*/10_interop) exit 0 ;; esac
exit 1
SH
  chmod +x "$probe"
  : > "$ORCA_LOG"
  out=$(FM_WSL_INTEROP_DIR="$wsl" FM_WSL_INTEROP_PROBE="$probe" \
    run_view open --target firstmate:fm-dev --view-session orca-wsl) || fail "WSL open failed: $out"
  assert_grep "WSL_INTEROP=$wsl/2_interop terminal create" "$ORCA_LOG" \
    "Orca is called through the lowest-numbered socket that answers"
  assert_grep '--shell wsl.exe' "$ORCA_LOG" "on WSL the tab runs the WSL shell"
  pass "open on WSL: calls Orca through a live interop socket and opens a WSL shell tab"
}

# The helper a home calls to pop open a tab on one window by its tmux id. A
# grouped viewer that sorts before the owning session lists the window first,
# so the tab must still be named after the session that owns it.
test_window_helper() {
  local wsl="$TMP_ROOT/wsl-window" probe="$TMP_ROOT/probe-window" dead="$TMP_ROOT/probe-dead" out status n
  "$SHIM/tmux" new-session -d -t firstmate -s aaa-view
  assert_equals aaa-view "$("$SHIM/tmux" list-windows -a -F '#{window_id} #{session_name}' | awk -v id="$DEV_ID" '$1 == id { print $2; exit }')" \
    "the fixture lists the grouped viewer first"
  n=${DEV_ID#@}
  : > "$ORCA_LOG"
  out=$(run_view window "$DEV_ID") || fail "window failed: $out"
  assert_contains "$out" "view_session=orca-w$n" "the view session is named after the window id"
  assert_contains "$out" "handle=term-" "the helper prints the tab's handle"
  assert_grep "terminal create --worktree path:$TMP_ROOT/code-root --title firstmate:fm-dev" "$ORCA_LOG" \
    "the tab is titled after the owning session and window"
  wait_for_window "orca-w$n" "$DEV_ID" || fail "the helper's view must show exactly that window"
  assert_equals "$DEV_ID" "$("$SHIM/tmux" show-options -v -t "=orca-w$n:" @fm_view_window)" \
    "the helper's view follows the window by id"
  run_view close --handle term-0 --view-session "orca-w$n" >/dev/null 2>&1 || fail "the helper's tab did not close"
  out=$(run_view window "$CLAUDE_ID" --title primary) || fail "window with a title failed: $out"
  assert_grep '--title primary' "$ORCA_LOG" "--title names the tab"
  run_view close --handle term-0 --view-session "orca-w${CLAUDE_ID#@}" >/dev/null 2>&1 || fail "the titled tab did not close"
  expect_code 1 "$(run_view window @99999 >/dev/null 2>&1; echo $?)" "an unknown window id is refused"
  expect_code 2 "$(run_view window 5 >/dev/null 2>&1; echo $?)" "a bare index is not a window id"
  expect_code 2 "$(run_view window @5x >/dev/null 2>&1; echo $?)" "a malformed id is invalid use"
  # On WSL the inherited WSL_INTEROP is ignored for one that answers.
  mkdir -p "$wsl"
  : > "$wsl/1_interop"
  : > "$wsl/3_interop"
  cat > "$probe" <<'SH'
#!/bin/sh
case "$WSL_INTEROP" in */3_interop) exit 0 ;; esac
exit 1
SH
  printf '#!/bin/sh\nexit 1\n' > "$dead"
  chmod +x "$probe" "$dead"
  : > "$ORCA_LOG"
  out=$(WSL_INTEROP="$wsl/1_interop" FM_WSL_INTEROP_DIR="$wsl" FM_WSL_INTEROP_PROBE="$probe" \
    run_view window "$DEV_ID") || fail "window on WSL failed: $out"
  assert_grep "WSL_INTEROP=$wsl/3_interop terminal create" "$ORCA_LOG" \
    "Orca is reached through the socket that answers, not the inherited one"
  run_view close --handle term-0 --view-session "orca-w$n" >/dev/null 2>&1 || fail "the WSL tab did not close"
  out=$(FM_WSL_INTEROP_DIR="$wsl" FM_WSL_INTEROP_PROBE="$dead" run_view window "$DEV_ID" 2>&1)
  status=$?
  expect_code 3 "$status" "no answering interop socket means Orca is unreachable"
  assert_contains "$out" "no live Windows-interop socket answers" "the note says why Orca cannot be reached"
  out=$(FM_FAKE_ORCA_FAIL=1 run_view window "$DEV_ID" 2>&1)
  status=$?
  expect_code 3 "$status" "an Orca that does not answer is reported"
  assert_contains "$out" "Orca is unreachable" "the note says Orca is unreachable"
  "$SHIM/tmux" has-session -t "=orca-w$n" 2>/dev/null && fail "an unreachable Orca must not leave the helper's view session"
  "$SHIM/tmux" kill-session -t '=aaa-view'
  pass "window: opens a followed tab on a window by id, through a live interop socket, and reports an unreachable Orca"
}

test_close() {
  local out status windows
  wait_for_session orca-wsl || fail "fixture view session missing"
  : > "$ORCA_LOG"
  out=$(run_view close --handle term-7 --view-session orca-wsl 2>&1) || fail "close failed: $out"
  assert_grep "terminal close --terminal term-7 --tab --json" "$ORCA_LOG" "the tab is closed by its handle"
  "$SHIM/tmux" has-session -t '=orca-wsl' 2>/dev/null && fail "close must remove the grouped view session it was given"
  "$SHIM/tmux" has-session -t '=firstmate' 2>/dev/null || fail "close must never remove the base session"
  windows=$("$SHIM/tmux" list-windows -t '=firstmate' | wc -l | tr -d ' ')
  out=$(run_view close --handle term-8 --view-session firstmate 2>&1) || fail "close failed: $out"
  "$SHIM/tmux" has-session -t '=firstmate' 2>/dev/null || fail "a base session named as the view session must survive"
  assert_equals "$windows" "$("$SHIM/tmux" list-windows -t '=firstmate' | wc -l | tr -d ' ')" \
    "the base session keeps its windows"
  out=$(FM_FAKE_ORCA_PINNED=term-9 run_view close --handle term-9 --view-session orca-dev 2>&1)
  status=$?
  expect_code 3 "$status" "a pinned tab is reported, not closed"
  assert_contains "$out" "pinned" "the note names the pinned tab"
  "$SHIM/tmux" has-session -t '=orca-dev' 2>/dev/null || fail "a pinned tab keeps its view session"
  pass "close: closes by handle, removes only a grouped view session, and leaves a pinned tab and its session open"
}

# The view follows its agent's window by id. This is the incident shape: a
# hand-made view session left on window 0 (another agent) is reused by an open,
# as a relaunch does, and must come back to the agent's window; then the
# agent's window closes, and the view must end and say so rather than fall
# back to another agent's window.
wait_for_window() {  # <view> <window-id>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$("$SHIM/tmux" display-message -p -t "=$1:" '#{window_id}' 2>/dev/null)" = "$2" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_no_session() {  # <name>
  local i=0
  while [ "$i" -lt 100 ]; do
    "$SHIM/tmux" has-session -t "=$1" 2>/dev/null || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_view_follows_the_agent_window() {
  local alex_id out tab tab_out i=0 new_id
  "$SHIM/tmux" new-window -d -t firstmate: -n fm-alex
  alex_id=$("$SHIM/tmux" display-message -p -t '=firstmate:fm-alex' '#{window_id}')
  "$SHIM/tmux" new-session -d -t firstmate -s orca-alex
  "$SHIM/tmux" select-window -t "=orca-alex:$CLAUDE_ID"
  : > "$ORCA_LOG"
  out=$(run_view open --target firstmate:fm-alex --view-session orca-alex --title alex) \
    || fail "reopen on a drifted view failed: $out"
  assert_contains "$out" "view_session_owned=0" "a hand-made view session is reused, not owned"
  wait_for_window orca-alex "$alex_id" || fail "a relaunch's open must re-select the agent's window by id"
  "$SHIM/tmux" select-window -t "=orca-alex:$DEV_ID"
  wait_for_window orca-alex "$alex_id" || fail "the view must return to its agent's window when it is moved off it"
  assert_equals "$CLAUDE_ID" "$("$SHIM/tmux" display-message -p -t '=firstmate:' '#{window_id}')" \
    "following never moves the base session's own window"
  # The tab is attached (the fake Orca terminal); the agent's window closes.
  "$SHIM/tmux" kill-window -t "$alex_id"
  wait_for_no_session orca-alex || fail "a view whose agent window is gone must end, not show another window"
  "$SHIM/tmux" has-session -t '=firstmate' 2>/dev/null || fail "ending a view must never end its base session"
  tab=$("$SHIM/tmux" list-windows -t '=tabs' -F '#{window_id} #{window_name}' | awk '$2 ~ /^tab-alex-/ { print $1; exit }')
  [ -n "$tab" ] || fail "the fake Orca tab for alex is missing"
  while [ "$i" -lt 100 ]; do
    tab_out=$("$SHIM/tmux" capture-pane -p -t "$tab" 2>/dev/null)
    case "$tab_out" in *"agent window this tab showed is gone"*) break ;; esac
    sleep 0.05
    i=$((i + 1))
  done
  assert_contains "$tab_out" "agent window this tab showed is gone" "the tab says its agent window is gone"
  # A restart gives the agent a new window; the next open tracks the new id.
  "$SHIM/tmux" new-window -d -t firstmate: -n fm-alex
  new_id=$("$SHIM/tmux" display-message -p -t '=firstmate:fm-alex' '#{window_id}')
  out=$(run_view open --target firstmate:fm-alex --view-session orca-alex --title alex) \
    || fail "open after the restart failed: $out"
  assert_contains "$out" "view_session_owned=1" "the ended view session is created afresh"
  wait_for_window orca-alex "$new_id" || fail "the new view must show the agent's new window"
  pass "view follows its agent's window by id: a relaunch re-selects it, a move snaps back, and a closed window ends the view with a message"
}

test_switch_values
test_command_never_names_claude
test_open_views_the_window_and_writes_identity
test_view_follows_the_agent_window
test_identity_filters_input
test_unavailable_orca_steps_aside
test_wsl_uses_live_interop
test_window_helper
test_close
