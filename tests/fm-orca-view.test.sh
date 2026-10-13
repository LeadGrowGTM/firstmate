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
if [ -n "${FM_FAKE_ORCA_REMOVE_BASE:-}" ]; then
  tmux kill-session -t "=$FM_FAKE_ORCA_REMOVE_BASE"
  [ "${FM_FAKE_ORCA_RECYCLE_BASE:-}" != 1 ] || tmux new-session -d -s "$FM_FAKE_ORCA_REMOVE_BASE" -n unrelated
  printf '{"ok":false,"error":{"code":"runtime_unavailable"}}\n'
  exit 1
fi
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
    seq=$(($(cat "$FM_FAKE_ORCA_LOG.seq" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$seq" > "$FM_FAKE_ORCA_LOG.seq"
    tab=$(tmux new-window -d -P -F '#{window_id}' -t "$FM_FAKE_ORCA_TAB_HOST:" -n "tab-$title-$seq" \
      env -u TMUX -u TMUX_PANE \
      ORCA_PANE_KEY="tab-$seq:leaf-$seq" ORCA_TAB_ID="tab-$seq" ORCA_WORKTREE_ID="wt-1" \
      ORCA_AGENT_HOOK_ENDPOINT="/home/u/.orca-wsl/agent-hooks/x/endpoint.env" \
      ORCA_AGENT_HOOK_ENV=production ORCA_AGENT_HOOK_VERSION=1 \
      ORCA_AGENT_HOOK_PORT=4242 ORCA_AGENT_HOOK_TOKEN=not-for-the-pane \
      TERM=xterm sh -c "$cmd; sleep 30")
    printf 'term-%s\t%s\n' "$seq" "$tab" >> "$FM_FAKE_ORCA_LOG.handles"
    printf '{"ok":true,"result":{"terminal":{"handle":"term-%s","tabId":"tab-%s"}}}\n' "$seq" "$seq"
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
    tab=$(awk -F '\t' -v handle="$handle" '$1 == handle { print $2; exit }' "$FM_FAKE_ORCA_LOG.handles" 2>/dev/null)
    if [ -z "$tab" ]; then
      printf '{"ok":false,"error":{"code":"unknown_terminal"}}\n'
      exit 1
    fi
    if [ "$handle" = "${FM_FAKE_ORCA_PINNED:-}" ]; then
      printf '{"ok":false,"error":{"code":"terminal_tab_pinned","message":"tab is pinned"}}\n'
      exit 1
    fi
    if ! tmux kill-window -t "$tab" 2>/dev/null; then
      printf '{"ok":false,"error":{"code":"unknown_terminal"}}\n'
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

returned_handle() { printf '%s\n' "$1" | sed -n 's/^handle=//p'; }

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
  printf ' o n \n' > "$cfg/orca-view-tabs"
  out=$(run_view enabled "$cfg" 2>"$TMP_ROOT/err")
  assert_equals off "$out" "whitespace inside a value does not turn tabs on"
  assert_contains "$(cat "$TMP_ROOT/err")" "accepted values are on and off" \
    "an internally spaced value is rejected"
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
  expect_code 2 "$(run_view open --target firstmate:fm-dev --view-session orca-extra --worktree /other >/dev/null 2>&1; echo $?)" \
    "open refuses a public worktree override"
  expect_code 2 "$(run_view window "$DEV_ID" --worktree /other >/dev/null 2>&1; echo $?)" \
    "window refuses a public worktree override"
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
  ident=$(run_view identity --file "$idfile") || fail "identity was not reported"
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

test_open_refuses_a_foreign_view_session() {
  local out before
  "$SHIM/tmux" new-session -d -s otherbase -n fm-other
  before=$(grep -c 'terminal create' "$ORCA_LOG")
  out=$(run_view open --target otherbase:fm-other --view-session orca-dev 2>&1)
  expect_code 3 "$?" "open must refuse a view grouped with another base session"
  assert_contains "$out" "belongs to another tmux base session" \
    "the foreign view's owner is reported"
  assert_equals "$before" "$(grep -c 'terminal create' "$ORCA_LOG")" \
    "Orca receives no new tab for the foreign view"
  assert_equals "$DEV_ID" "$("$SHIM/tmux" display-message -p -t '=orca-dev:' '#{window_id}')" \
    "the foreign view keeps its selected window"
  pass "open refuses a view session belonging to another base without changing it"
}

test_identity_filters_input() {
  local f="$TMP_ROOT/raw.identity" ident missing name value mode
  {
    printf 'ORCA_PANE_KEY=t:l\n'
    printf 'ORCA_TAB_ID=it'\''s\n'
    printf 'ORCA_AGENT_HOOK_ENDPOINT=/e/endpoint.env\n'
    printf 'ORCA_WORKTREE_ID=wt-1\n'
    printf 'ORCA_AGENT_HOOK_ENV=production\n'
    printf 'ORCA_AGENT_HOOK_VERSION=1\n'
    printf 'ORCA_AGENT_HOOK_TOKEN=secret\n'
    printf 'PATH=/evil\n'
  } > "$f"
  ident=$(run_view identity --file "$f") || fail "identity refused valid input"
  expect_code 2 "$(run_view identity --file "$f" --wait 0 >/dev/null 2>&1; echo $?)" \
    "identity refuses the removed wait override"
  assert_not_contains "$ident" "secret" "a token is never exported"
  assert_not_contains "$ident" "PATH" "only Orca identity names are exported"
  # shellcheck disable=SC2016
  assert_equals "it's" "$(env -i sh -c "$ident"'; printf "%s" "$ORCA_TAB_ID"')" "values survive shell quoting"
  for missing in ORCA_PANE_KEY ORCA_TAB_ID ORCA_WORKTREE_ID ORCA_AGENT_HOOK_ENDPOINT \
    ORCA_AGENT_HOOK_ENV ORCA_AGENT_HOOK_VERSION; do
    for mode in absent empty; do
      : > "$f"
      for name in ORCA_PANE_KEY ORCA_TAB_ID ORCA_WORKTREE_ID ORCA_AGENT_HOOK_ENDPOINT \
        ORCA_AGENT_HOOK_ENV ORCA_AGENT_HOOK_VERSION; do
        [ "$name" != "$missing" ] || [ "$mode" != absent ] || continue
        value=valid
        [ "$name" != "$missing" ] || value=
        printf '%s=%s\n' "$name" "$value" >> "$f"
      done
      expect_code 3 "$(run_view identity --file "$f" >/dev/null 2>&1; echo $?)" \
        "$missing $mode must not yield a partial identity"
    done
  done
  {
    printf 'ORCA_PANE_KEY=t:l\nORCA_TAB_ID=tab\nORCA_WORKTREE_ID=wt\n'
    printf 'ORCA_AGENT_HOOK_ENDPOINT=/e\nORCA_AGENT_HOOK_ENV=production\n'
    printf 'ORCA_AGENT_HOOK_VERSION=bad\033[2J\n'
  } > "$f"
  expect_code 3 "$(run_view identity --file "$f" >/dev/null 2>&1; echo $?)" \
    "a control byte makes the six-field identity incomplete"
  expect_code 3 "$(run_view identity --file "$TMP_ROOT/never" >/dev/null 2>&1; echo $?)" \
    "an identity that never arrives steps aside"
  pass "identity: exports only six nonempty safe fields and refuses missing or incomplete delivery"
}

test_failed_open_restores_existing_view() {
  local out status prior_hook window_view="orca-w${DEV_ID#@}"
  "$SHIM/tmux" new-session -d -t firstmate -s orca-rollback
  "$SHIM/tmux" select-window -t "=orca-rollback:$CLAUDE_ID"
  "$SHIM/tmux" set-option -t '=orca-rollback:' @fm_view_window "$CLAUDE_ID"
  "$SHIM/tmux" set-hook -t '=orca-rollback:' session-window-changed 'display-message previous'
  prior_hook=$("$SHIM/tmux" show-options -H -t '=orca-rollback:' session-window-changed)
  out=$(FM_FAKE_ORCA_FAIL=1 run_view open --target firstmate:fm-dev --view-session orca-rollback 2>&1)
  status=$?
  expect_code 3 "$status" "a refused create reports failure on a reused view"
  assert_equals "$CLAUDE_ID" "$("$SHIM/tmux" display-message -p -t '=orca-rollback:' '#{window_id}')" \
    "a refused create restores the selected window"
  assert_equals "$CLAUDE_ID" "$("$SHIM/tmux" show-options -v -t '=orca-rollback:' @fm_view_window)" \
    "a refused create restores the view option"
  assert_equals "$prior_hook" "$("$SHIM/tmux" show-options -H -t '=orca-rollback:' session-window-changed)" \
    "a refused create restores the hook"
  "$SHIM/tmux" new-session -d -t firstmate -s "$window_view"
  "$SHIM/tmux" select-window -t "=$window_view:$CLAUDE_ID"
  out=$(FM_FAKE_ORCA_FAIL=1 run_view window "$DEV_ID" 2>&1)
  status=$?
  expect_code 3 "$status" "a refused window helper create reports failure"
  assert_equals "$CLAUDE_ID" "$("$SHIM/tmux" display-message -p -t "=$window_view:" '#{window_id}')" \
    "the window helper restores a reused view's selection"
  assert_equals "" "$("$SHIM/tmux" show-options -v -t "=$window_view:" @fm_view_window 2>/dev/null)" \
    "the window helper removes an option that was absent"
  assert_equals "" "$("$SHIM/tmux" show-options -H -t "=$window_view:" session-window-changed 2>/dev/null)" \
    "the window helper removes a hook that was absent"
  pass "a failed create restores every prior state of reused open and window views"
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
  WSL_HANDLE=$(returned_handle "$out")
  assert_grep "WSL_INTEROP=$wsl/2_interop terminal create" "$ORCA_LOG" \
    "Orca is called through the lowest-numbered socket that answers"
  assert_grep '--shell wsl.exe' "$ORCA_LOG" "on WSL the tab runs the WSL shell"
  pass "open on WSL: calls Orca through a live interop socket and opens a WSL shell tab"
}

# The helper a home calls to pop open a tab on one window by its tmux id. A
# grouped viewer that sorts before the owning session lists the window first,
# so the tab must still be named after the session that owns it.
test_window_helper() {
  local wsl="$TMP_ROOT/wsl-window" probe="$TMP_ROOT/probe-window" dead="$TMP_ROOT/probe-dead" out status n handle
  "$SHIM/tmux" new-session -d -t firstmate -s aaa-view
  assert_equals aaa-view "$("$SHIM/tmux" list-windows -a -F '#{window_id} #{session_name}' | awk -v id="$DEV_ID" '$1 == id { print $2; exit }')" \
    "the fixture lists the grouped viewer first"
  n=${DEV_ID#@}
  : > "$ORCA_LOG"
  out=$(run_view window "$DEV_ID") || fail "window failed: $out"
  handle=$(returned_handle "$out")
  assert_contains "$out" "view_session=orca-w$n" "the view session is named after the window id"
  assert_contains "$out" "handle=term-" "the helper prints the tab's handle"
  assert_grep "terminal create --worktree path:$TMP_ROOT/code-root --title firstmate:fm-dev" "$ORCA_LOG" \
    "the tab is titled after the owning session and window"
  wait_for_window "orca-w$n" "$DEV_ID" || fail "the helper's view must show exactly that window"
  assert_equals "$DEV_ID" "$("$SHIM/tmux" show-options -v -t "=orca-w$n:" @fm_view_window)" \
    "the helper's view follows the window by id"
  run_view close --handle "$handle" --view-session "orca-w$n" >/dev/null 2>&1 || fail "the helper's tab did not close"
  out=$(run_view window "$CLAUDE_ID" --title primary) || fail "window with a title failed: $out"
  handle=$(returned_handle "$out")
  assert_grep '--title primary' "$ORCA_LOG" "--title names the tab"
  run_view close --handle "$handle" --view-session "orca-w${CLAUDE_ID#@}" >/dev/null 2>&1 || fail "the titled tab did not close"
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
  handle=$(returned_handle "$out")
  assert_grep "WSL_INTEROP=$wsl/3_interop terminal create" "$ORCA_LOG" \
    "Orca is reached through the socket that answers, not the inherited one"
  run_view close --handle "$handle" --view-session "orca-w$n" >/dev/null 2>&1 || fail "the WSL tab did not close"
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
  local out status windows handle pinned_handle
  wait_for_session orca-wsl || fail "fixture view session missing"
  : > "$ORCA_LOG"
  out=$(run_view close --handle "$WSL_HANDLE" --view-session orca-wsl 2>&1) || fail "close failed: $out"
  assert_grep "terminal close --terminal $WSL_HANDLE --tab --json" "$ORCA_LOG" "the tab is closed by its handle"
  "$SHIM/tmux" has-session -t '=orca-wsl' 2>/dev/null && fail "close must remove the grouped view session it was given"
  "$SHIM/tmux" has-session -t '=firstmate' 2>/dev/null || fail "close must never remove the base session"
  windows=$("$SHIM/tmux" list-windows -t '=firstmate' | wc -l | tr -d ' ')
  out=$(run_view open --target firstmate:fm-dev --view-session orca-base-test) || fail "base test open failed: $out"
  handle=$(returned_handle "$out")
  out=$(run_view close --handle "$handle" --view-session firstmate 2>&1) || fail "close failed: $out"
  "$SHIM/tmux" has-session -t '=firstmate' 2>/dev/null || fail "a base session named as the view session must survive"
  assert_equals "$windows" "$("$SHIM/tmux" list-windows -t '=firstmate' | wc -l | tr -d ' ')" \
    "the base session keeps its windows"
  "$SHIM/tmux" kill-session -t '=orca-base-test'
  out=$(run_view open --target firstmate:fm-dev --view-session orca-pin-test) || fail "pinned test open failed: $out"
  pinned_handle=$(returned_handle "$out")
  out=$(FM_FAKE_ORCA_PINNED="$pinned_handle" run_view close --handle "$pinned_handle" --view-session orca-pin-test 2>&1)
  status=$?
  expect_code 3 "$status" "a pinned tab is reported, not closed"
  assert_contains "$out" "pinned" "the note names the pinned tab"
  "$SHIM/tmux" has-session -t '=orca-pin-test' 2>/dev/null || fail "a pinned tab keeps its view session"
  out=$(run_view close --handle term-unknown --view-session orca-pin-test 2>&1)
  expect_code 3 "$?" "the fake rejects a handle no tab returned"
  "$SHIM/tmux" has-session -t '=orca-pin-test' 2>/dev/null || fail "an unknown handle cannot close a view"
  run_view close --handle "$pinned_handle" --view-session orca-pin-test >/dev/null 2>&1 || fail "the unpinned tab did not close"
  pass "close: closes known handles, preserves base sessions, and refuses pinned or unknown handles"
}

wait_for_attached_count() {
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$("$SHIM/tmux" display-message -p -t "=$1:" '#{session_attached}' 2>/dev/null)" = "$2" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_close_keeps_windows_when_base_is_gone() {
  local replacement base view out handle window pane_pid
  for replacement in absent recycled; do
    base="close-base-$replacement"
    view="close-view-$replacement"
    "$SHIM/tmux" new-session -d -s "$base" -n agent 'sleep 120' || fail "could not create the base"
    window=$("$SHIM/tmux" display-message -p -t "=$base:" '#{window_id}')
    pane_pid=$("$SHIM/tmux" display-message -p -t "=$base:" '#{pane_pid}')
    out=$(run_view open --target "$base:$window" --view-session "$view") || fail "could not open the view: $out"
    handle=$(returned_handle "$out")
    wait_for_attached_count "$view" 1 || fail "the tab did not attach"
    "$SHIM/tmux" kill-session -t "=$base"
    assert_equals "$base" "$("$SHIM/tmux" display-message -p -t "=$view:" '#{session_group}')" \
      "the last surviving group member retains the missing base's name"
    if [ "$replacement" = recycled ]; then
      "$SHIM/tmux" new-session -d -s "$base" -n unrelated || fail "could not recycle the base name"
    fi
    run_view close --handle "$handle" --view-session "$view" >/dev/null 2>&1 || fail "the tab did not close"
    "$SHIM/tmux" has-session -t "=$view" 2>/dev/null || fail "closing the last group member killed the surviving agent's session ($replacement base)"
    assert_equals "$window" "$("$SHIM/tmux" display-message -p -t "=$view:" '#{window_id}')" \
      "closing the tab preserves the surviving window"
    kill -0 "$pane_pid" 2>/dev/null || fail "closing the tab killed the surviving agent process"
    assert_grep "terminal close --terminal $handle --tab --json" "$ORCA_LOG" "the Orca tab still closes"
    "$SHIM/tmux" kill-session -t "=$view"
    [ "$replacement" != recycled ] || "$SHIM/tmux" kill-session -t "=$base"
  done
  pass "close: preserves surviving agent windows when the base is gone or its name is recycled"
}

test_close_keeps_shared_view() {
  local first second first_handle second_handle
  first=$(run_view open --target firstmate:fm-dev --view-session orca-shared) || fail "first shared tab did not open"
  second=$(run_view open --target firstmate:fm-dev --view-session orca-shared) || fail "second shared tab did not open"
  first_handle=$(returned_handle "$first")
  second_handle=$(returned_handle "$second")
  wait_for_attached_count orca-shared 2 || fail "both tabs did not attach to the shared view"
  run_view close --handle "$first_handle" --view-session orca-shared >/dev/null 2>&1 || fail "first tab did not close"
  "$SHIM/tmux" has-session -t '=orca-shared' 2>/dev/null || fail "closing one tab removed the shared view"
  wait_for_attached_count orca-shared 1 || fail "the second tab did not stay attached"
  run_view close --handle "$second_handle" --view-session orca-shared >/dev/null 2>&1 || fail "second tab did not close"
  "$SHIM/tmux" has-session -t '=orca-shared' 2>/dev/null && fail "the view remained after its last tab closed"
  pass "close: a shared view lives until its last attached tab closes"
}

test_open_refuses_the_base_as_a_view() {
  local before hooks out status
  before=$("$SHIM/tmux" display-message -p -t '=firstmate:' '#{window_id}')
  "$SHIM/tmux" set-hook -t '=firstmate:' 'session-window-changed[7]' 'run-shell true'
  hooks=$("$SHIM/tmux" show-options -H -t '=firstmate:' session-window-changed)
  : > "$ORCA_LOG"
  out=$(run_view open --target firstmate:fm-dev --view-session firstmate 2>&1)
  status=$?
  expect_code 3 "$status" "the grouped base cannot be used as its own view"
  assert_contains "$out" "base session" "the refusal names the base session"
  assert_equals "$before" "$("$SHIM/tmux" display-message -p -t '=firstmate:' '#{window_id}')" \
    "the base's selected window is unchanged"
  assert_equals "$hooks" "$("$SHIM/tmux" show-options -H -t '=firstmate:' session-window-changed)" \
    "the base's hooks are unchanged"
  "$SHIM/tmux" show-options -v -t '=firstmate:' @fm_view_window >/dev/null 2>&1 && fail "the base acquired view tracking"
  assert_no_grep 'terminal create' "$ORCA_LOG" "no Orca tab is created for the base itself"
  "$SHIM/tmux" set-hook -u -t '=firstmate:' 'session-window-changed[7]'
  pass "open: refuses the grouped base itself without installing tracking or moving its window"
}

test_follow_keeps_windows_when_base_is_gone() {
  local replacement base view out handle target survivor pane_pid hooks i
  for replacement in absent recycled; do
    base="follow-base-$replacement"
    view="follow-view-$replacement"
    "$SHIM/tmux" new-session -d -s "$base" -n target 'sleep 120' || fail "could not create the base"
    target=$("$SHIM/tmux" display-message -p -t "=$base:" '#{window_id}')
    survivor=$("$SHIM/tmux" new-window -dP -F '#{window_id}' -t "$base:" -n survivor 'sleep 120')
    pane_pid=$("$SHIM/tmux" display-message -p -t "$survivor" '#{pane_pid}')
    out=$(run_view open --target "$base:$target" --view-session "$view") || fail "could not open the view: $out"
    handle=$(returned_handle "$out")
    wait_for_attached_count "$view" 1 || fail "the tab did not attach"
    "$SHIM/tmux" set-hook -t "=$view:" 'session-window-changed[7]' 'run-shell true'
    "$SHIM/tmux" kill-session -t "=$base"
    if [ "$replacement" = recycled ]; then
      "$SHIM/tmux" new-session -d -s "$base" -n unrelated || fail "could not recycle the base name"
    fi
    "$SHIM/tmux" kill-window -t "$target"
    i=0
    while [ "$i" -lt 100 ]; do
      "$SHIM/tmux" show-options -v -t "=$view:" @fm_view_window >/dev/null 2>&1 || break
      sleep 0.05
      i=$((i + 1))
    done
    "$SHIM/tmux" has-session -t "=$view" 2>/dev/null || fail "the follow hook killed the last surviving session ($replacement base)"
    assert_equals "$survivor" "$("$SHIM/tmux" display-message -p -t "=$view:" '#{window_id}')" \
      "the follow hook preserves the unrelated surviving window"
    kill -0 "$pane_pid" 2>/dev/null || fail "the follow hook killed the surviving agent process"
    "$SHIM/tmux" show-options -v -t "=$view:" @fm_view_window >/dev/null 2>&1 && fail "the follow hook did not remove its tracking option"
    hooks=$("$SHIM/tmux" show-options -H -t "=$view:" session-window-changed)
    assert_not_contains "$hooks" 'session-window-changed[0]' "the follow hook removes its own tracking hook"
    assert_contains "$hooks" 'session-window-changed[7]' "the follow hook preserves unrelated hooks"
    run_view close --handle "$handle" --view-session "$view" >/dev/null 2>&1 || fail "the tab did not close"
    "$SHIM/tmux" kill-session -t "=$view"
    [ "$replacement" != recycled ] || "$SHIM/tmux" kill-session -t "=$base"
  done
  pass "follow: removes only its tracking and preserves agents when the base is gone or recycled"
}

test_failed_open_keeps_windows_when_base_is_gone() {
  local replacement base view target pane_pid out status recycle
  for replacement in absent recycled; do
    base="failed-base-$replacement"
    view="failed-view-$replacement"
    "$SHIM/tmux" new-session -d -s "$base" -n agent 'sleep 120' || fail "could not create the base"
    target=$("$SHIM/tmux" display-message -p -t "=$base:" '#{window_id}')
    pane_pid=$("$SHIM/tmux" display-message -p -t "=$base:" '#{pane_pid}')
    recycle=0
    [ "$replacement" != recycled ] || recycle=1
    out=$(FM_FAKE_ORCA_REMOVE_BASE="$base" FM_FAKE_ORCA_RECYCLE_BASE="$recycle" \
      run_view open --target "$base:$target" --view-session "$view" 2>&1)
    status=$?
    expect_code 3 "$status" "failed open is reported after its base disappears"
    "$SHIM/tmux" has-session -t "=$view" 2>/dev/null || fail "failed open killed the surviving session ($replacement base)"
    assert_equals "$target" "$("$SHIM/tmux" display-message -p -t "=$view:" '#{window_id}')" \
      "failed open preserves the original agent window"
    kill -0 "$pane_pid" 2>/dev/null || fail "failed open killed the surviving agent process"
    "$SHIM/tmux" show-options -v -t "=$view:" @fm_view_window >/dev/null 2>&1 && fail "failed open left its tracking option"
    assert_not_contains "$("$SHIM/tmux" show-options -H -t "=$view:" session-window-changed)" 'session-window-changed[0]' \
      "failed open removes its installed tracking hook"
    "$SHIM/tmux" kill-session -t "=$view"
    [ "$replacement" != recycled ] || "$SHIM/tmux" kill-session -t "=$base"
  done
  pass "failed open: removes tracking and preserves agents if its base disappears during the Orca call"
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

test_timeout_defaults() {
  local real_timeout timeout_log="$TMP_ROOT/timeout.log" wsl="$TMP_ROOT/timeout-wsl" out handle value
  real_timeout=$(command -v timeout) || fail "timeout is unavailable for the Orca deadline test"
  mkdir -p "$wsl"
  : > "$wsl/1_interop"
  printf '#!/bin/sh\nexit 0\n' > "$SHIM/interop-timeout-probe"
  chmod +x "$SHIM/interop-timeout-probe"
  cat > "$SHIM/timeout" <<'SH'
#!/bin/sh
printf '%s\n' "$3" >> "$FM_FAKE_TIMEOUT_LOG"
exec "$FM_FAKE_REAL_TIMEOUT" "$@"
SH
  chmod +x "$SHIM/timeout"
  for value in 0 invalid; do
    : > "$timeout_log"
    out=$(FM_FAKE_TIMEOUT_LOG="$timeout_log" FM_FAKE_REAL_TIMEOUT="$real_timeout" \
      FM_WSL_INTEROP_DIR="$wsl" FM_WSL_INTEROP_PROBE="$SHIM/interop-timeout-probe" \
      FM_WSL_INTEROP_TIMEOUT="$value" FM_ORCA_VIEW_TIMEOUT="$value" \
      run_view window "$DEV_ID") || fail "window failed with timeout value $value: $out"
    grep -qx '3' "$timeout_log" || fail "the interop probe did not use its bounded default for $value"
    grep -qx '60' "$timeout_log" || fail "Orca create did not use its bounded default for $value"
    handle=$(returned_handle "$out")
    FM_FAKE_TIMEOUT_LOG="$timeout_log" FM_FAKE_REAL_TIMEOUT="$real_timeout" \
      FM_WSL_INTEROP_DIR="$wsl" FM_WSL_INTEROP_PROBE="$SHIM/interop-timeout-probe" \
      FM_WSL_INTEROP_TIMEOUT="$value" FM_ORCA_VIEW_TIMEOUT="$value" \
      run_view close --handle "$handle" --view-session "orca-w${DEV_ID#@}" >/dev/null \
      || fail "close failed with timeout value $value"
    assert_equals 2 "$(grep -c '^60$' "$timeout_log")" \
      "Orca close also uses its bounded default for $value"
  done
  pass "zero and invalid Orca and WSL timeouts fall back to bounded defaults"
}

test_switch_values
test_command_never_names_claude
test_open_views_the_window_and_writes_identity
test_open_refuses_the_base_as_a_view
test_open_refuses_a_foreign_view_session
test_view_follows_the_agent_window
test_identity_filters_input
test_failed_open_restores_existing_view
test_unavailable_orca_steps_aside
test_wsl_uses_live_interop
test_window_helper
test_close_keeps_shared_view
test_follow_keeps_windows_when_base_is_gone
test_failed_open_keeps_windows_when_base_is_gone
test_close_keeps_windows_when_base_is_gone
test_close
test_timeout_defaults
