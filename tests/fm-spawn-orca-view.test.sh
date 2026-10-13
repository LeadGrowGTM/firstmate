#!/usr/bin/env bash
# tests/fm-spawn-orca-view.test.sh - the optional Orca view tab a secondmate
# spawn or relaunch opens (config/orca-view-tabs, bin/fm-orca-view.sh).
#
# The real spawn and relaunch run against a fake tmux and a fake Orca command
# line. The fake Orca runs each tab's startup command with an Orca identity in
# its environment, the way an Orca terminal's shell would, so the identity the
# pane receives is the one the tab itself wrote. Each launch is then executed
# with the harness replaced by a probe, so the assertions read what the agent
# would have started with rather than the command text.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-view)
mkdir -p "$TMP_ROOT"

# install_view_fakes <fakebin> <view-dir>: wrap the fakebin's tmux with the
# window and session reads bin/fm-orca-view.sh makes, and add the fake Orca.
install_view_fakes() {
  local fb=$1 vd=$2
  mkdir -p "$vd"
  : > "$vd/orca.log"
  mv "$fb/tmux" "$fb/tmux.base"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_VIEW_DIR
here=$(dirname "$0")
case "${1:-}" in
  -S) shift 2; exec "$0" "$@" ;;
esac
case "$*" in
  *'#{window_index}'*)
    n=0
    while IFS= read -r w; do
      printf '%s\t%s\t@%s\n' "$n" "$w" "$n"
      n=$((n + 1))
    done < "$D/windows"
    exit 0 ;;
  *'#{session_name}'*) exec "$here/tmux.base" "$@" ;;
  *'#{session_grouped}'*)
    case "$*" in *=orca-*) printf '1\tbase\n' ;; *) printf '0\t\n' ;; esac
    exit 0 ;;
  *'#{session_id}'*) printf '$1\n'; exit 0 ;;
  *'#{socket_path}'*) printf '/tmp/fm-fake-socket\n'; exit 0 ;;
esac
case "${1:-}" in
  has-session)
    for a in "$@"; do
      case "$a" in =orca-*) [ -e "$D/session-${a#=}" ]; exit $? ;; esac
    done ;;
  new-session)
    s=
    prev=
    for a in "$@"; do
      [ "$prev" != -s ] || s=$a
      prev=$a
    done
    case "$s" in
      orca-*) : > "$D/session-$s"; exit 0 ;;
    esac ;;
  kill-session) printf '%s\n' "$*" >> "$D/killed"; exit 0 ;;
esac
exec "$here/tmux.base" "$@"
SH
  chmod +x "$fb/tmux"
  cat > "$fb/orca-ide" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_VIEW_DIR
printf '%s\n' "$*" >> "$D/orca.log"
[ ! -e "$D/orca-down" ] || { printf '{"ok":false,"error":{"code":"runtime_unavailable"}}\n'; exit 1; }
case "$1 $2" in
  "terminal create")
    cmd=
    while [ $# -gt 0 ]; do
      case "$1" in --command) cmd=$2; shift 2 ;; *) shift ;; esac
    done
    n=$(grep -c 'terminal create' "$D/orca.log")
    env ORCA_PANE_KEY="tab-$n:leaf" ORCA_TAB_ID="tab-$n" ORCA_WORKTREE_ID=wt-1 \
      ORCA_AGENT_HOOK_ENDPOINT=/hooks/endpoint.env ORCA_AGENT_HOOK_ENV=production \
      ORCA_AGENT_HOOK_VERSION=1 ORCA_AGENT_HOOK_TOKEN=never-forwarded \
      sh -c "$cmd" >/dev/null 2>&1
    printf '{"ok":true,"result":{"terminal":{"handle":"term-%s"}}}\n' "$n" ;;
  "terminal close") printf '{"ok":true,"result":{"closed":true}}\n' ;;
  *) printf '{"ok":false}\n'; exit 1 ;;
esac
SH
  chmod +x "$fb/orca-ide"
}

install_env_probe() {  # <fakebin>: every harness binary a launch may name
  local h
  for h in codex claude; do
    cat > "$1/$h" <<'SH'
#!/bin/sh
printf 'pane=%s token=%s\n' "${ORCA_PANE_KEY-unset}" "${ORCA_AGENT_HOOK_TOKEN-unset}"
SH
    chmod +x "$1/$h"
  done
}

# The pane carries an inherited identity of some unrelated Orca terminal, as a
# tmux server started inside an Orca terminal would hand every new window.
run_launch() {  # <fakebin> <pane-exports> <launch>
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    ORCA_PANE_KEY=stale-tab:leaf ORCA_AGENT_HOOK_TOKEN=stale-token \
    /bin/sh -c "$2
$3"
}

make_secondmate_home() {  # <dir> <id>
  mkdir -p "$1/bin" "$1/data"
  printf '# Firstmate\n' > "$1/AGENTS.md"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'charter for %s\n' "$2" > "$1/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$1/.gitignore"
  git -C "$1" init -q -b main
}

# spawn_secondmate <case> <id> <switch|absent> [allowlist]: sets CASE_DIR,
# HOME_DIR, FAKEBIN, VIEW_DIR, PANE_LOG, LAUNCH_LOG, OUT, STATUS. A file at
# $TMP_ROOT/<case>.prior-meta becomes the existing record a respawn replaces.
spawn_secondmate() {
  local name=$1 id=$2 switch=$3 allowlist=${4:-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  VIEW_DIR="$CASE_DIR/view"
  PANE_LOG="$CASE_DIR/pane.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  install_view_fakes "$FAKEBIN" "$VIEW_DIR"
  printf 'fm-%s\n' "$id" > "$VIEW_DIR/windows"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id"
  [ "$switch" = absent ] || printf '%s\n' "$switch" > "$HOME_DIR/config/orca-view-tabs"
  [ -z "$allowlist" ] || : > "$HOME_DIR/config/launch-env-allowlist"
  make_secondmate_home "$CASE_DIR/sm" "$id"
  [ ! -f "$TMP_ROOT/$name.prior-meta" ] || cp "$TMP_ROOT/$name.prior-meta" "$HOME_DIR/state/$id.meta"
  : > "$PANE_LOG"
  : > "$LAUNCH_LOG"
  OUT=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" FM_FAKE_VIEW_DIR="$VIEW_DIR" \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    fm_test_run_spawn "$HOME_DIR" "$CASE_DIR/sm" "$FAKEBIN" "$id" "$CASE_DIR/sm" --secondmate)
  STATUS=$?
}

meta() { grep "^$2=" "$HOME_DIR/state/$1.meta" | tail -1 | cut -d= -f2-; }

test_switch_absent_changes_nothing() {
  spawn_secondmate absent sm-off absent
  expect_code 0 "$STATUS" "a secondmate spawn without the switch should succeed: $OUT"
  [ ! -s "$VIEW_DIR/orca.log" ] || fail "no Orca call may happen without the switch: $(cat "$VIEW_DIR/orca.log")"
  assert_equals "" "$(meta sm-off orca_view_handle)" "no tab is recorded without the switch"
  assert_no_grep 'ORCA_' "$PANE_LOG" "the pane receives no Orca export or unset without the switch"
  pass "switch absent: a secondmate spawn makes no Orca call and changes nothing in its pane"
}

test_switch_on_opens_and_forwards_identity() {
  local seen
  spawn_secondmate on sm-on on allowlist
  expect_code 0 "$STATUS" "a secondmate spawn with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-on orca_view_handle)" "the tab's handle is recorded"
  assert_equals orca-sm-on "$(meta sm-on orca_view_session)" "the view session is recorded"
  assert_equals 1 "$(meta sm-on orca_view_owned)" "a view session the spawn created is owned"
  assert_grep "terminal create --worktree path:$ROOT --title sm-on" "$VIEW_DIR/orca.log" \
    "the tab is titled for the secondmate on the code root's Orca worktree"
  assert_present "$VIEW_DIR/session-orca-sm-on" "the spawn created the tab's view session"
  assert_absent "$HOME_DIR/state/sm-on.orca-view-identity" "the identity hand-off file is consumed"
  install_env_probe "$FAKEBIN"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$PANE_LOG")" "$(cat "$LAUNCH_LOG")") \
    || fail "the emitted launch failed to run"
  assert_equals "pane=tab-1:leaf token=unset" "$seen" \
    "the agent starts with the tab's identity and no hook token, even under the cleared environment"
  pass "switch on: the spawn opens one tab, records it, and the agent starts with that tab's identity"
}

test_unavailable_orca_steps_aside() {
  local seen
  CASE_DIR="$TMP_ROOT/down"
  mkdir -p "$CASE_DIR/view"
  : > "$CASE_DIR/view/orca-down"
  spawn_secondmate down sm-down on
  expect_code 0 "$STATUS" "an unavailable Orca must never fail the spawn: $OUT"
  assert_contains "$OUT" "note:" "the spawn reports the missing tab in one note"
  assert_equals "" "$(meta sm-down orca_view_handle)" "no tab is recorded when Orca is unavailable"
  install_env_probe "$FAKEBIN"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$PANE_LOG")" "$(cat "$LAUNCH_LOG")") \
    || fail "the emitted launch failed to run"
  assert_equals "pane=unset token=unset" "$seen" \
    "with no tab, an inherited Orca identity is cleared so the agent cannot badge an unrelated tab"
  pass "Orca unavailable: the spawn goes on without a tab and clears any inherited Orca identity"
}

# --- relaunch ---------------------------------------------------------------
# The lifecycle stub: the harness exit command leaves a bare shell, and a launch
# literal starts the harness again.
make_relaunch_stub() {  # <fakebin>
  mkdir -p "$1"
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$1/sleep"
  chmod +x "$1/sleep"
}

# relaunch_secondmate <case> <id> <switch>: a live secondmate whose record
# names the tab term-0, relaunched through the operator verb.
relaunch_secondmate() {
  local name=$1 id=$2 switch=$3 sm
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  VIEW_DIR="$CASE_DIR/fake"
  FAKEBIN="$CASE_DIR/fakebin"
  sm="$CASE_DIR/sm"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$id" "$HOME_DIR/config" "$HOME_DIR/projects" "$VIEW_DIR"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf '# secondmate brief\n' > "$HOME_DIR/data/$id/brief.md"
  [ "$switch" = absent ] || printf '%s\n' "$switch" > "$HOME_DIR/config/orca-view-tabs"
  make_relaunch_stub "$FAKEBIN"
  install_view_fakes "$FAKEBIN" "$VIEW_DIR"
  make_secondmate_home "$sm" "$id"
  mkdir -p "$sm/state"
  : > "$VIEW_DIR/literal"
  : > "$VIEW_DIR/keys"
  printf 'codex' > "$VIEW_DIR/command"
  printf 'fm-%s\n' "$id" > "$VIEW_DIR/windows"
  printf '%s' "$sm" > "$VIEW_DIR/cwd"
  : > "$VIEW_DIR/session-orca-$id"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$sm"
    echo "project=$sm"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$sm"
    echo "orca_view_handle=term-0"
    echo "orca_view_session=orca-$id"
    echo "orca_view_owned=1"
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$CASE_DIR/user-home"
  OUT=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$VIEW_DIR" FM_FAKE_VIEW_DIR="$VIEW_DIR" \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch 2>&1)
  STATUS=$?
}

test_relaunch_replaces_the_tab() {
  local seen launch
  relaunch_secondmate relaunch-on sm-re on
  expect_code 0 "$STATUS" "a secondmate relaunch with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-re orca_view_handle)" "the fresh tab replaces the recorded one"
  assert_equals 1 "$(meta sm-re orca_view_owned)" \
    "the reattached view session the previous tab created stays this feature's to remove"
  assert_grep "terminal close --terminal term-0 --tab --json" "$VIEW_DIR/orca.log" \
    "the previous tab is closed once the relaunch went through"
  assert_no_grep "terminal close --terminal term-1" "$VIEW_DIR/orca.log" "the fresh tab stays open"
  [ ! -s "$VIEW_DIR/killed" ] || fail "a relaunch must keep the view session the fresh tab reattached: $(cat "$VIEW_DIR/killed")"
  install_env_probe "$FAKEBIN"
  launch=$(grep -E 'encode launch-brief|Firstmate operational input waiting' "$VIEW_DIR/literal" | tail -1)
  [ -n "$launch" ] || fail "the relaunch sent no replacement launch"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$VIEW_DIR/keys")" "$launch") \
    || fail "the replacement launch failed to run: $seen"
  assert_contains "$seen" "pane=tab-1:leaf" "the replacement agent badges the fresh tab"
  pass "relaunch: opens a fresh tab, forwards its identity, then closes the previous tab and keeps the view session"
}

test_relaunch_with_switch_off_keeps_the_tab() {
  relaunch_secondmate relaunch-off sm-keep off
  expect_code 0 "$STATUS" "a secondmate relaunch with the switch off should succeed: $OUT"
  assert_equals term-0 "$(meta sm-keep orca_view_handle)" "the recorded tab stays recorded"
  [ ! -s "$VIEW_DIR/orca.log" ] || fail "no Orca call may happen with the switch off: $(cat "$VIEW_DIR/orca.log")"
  pass "relaunch with the switch off keeps the recorded tab for cleanup and makes no Orca call"
}

# The window-gone recovery respawns a secondmate over its existing record; its
# previous tab, whose view ended with the window, is replaced and closed.
test_respawn_replaces_the_previous_tab() {
  printf 'window=firstmate:fm-sm-back\nendpoint_task_id=sm-back\nkind=secondmate\norca_view_handle=term-0\norca_view_session=orca-sm-back\norca_view_owned=1\n' \
    > "$TMP_ROOT/respawn.prior-meta"
  spawn_secondmate respawn sm-back on
  expect_code 0 "$STATUS" "a secondmate respawn with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-back orca_view_handle)" "the fresh tab replaces the recorded one"
  assert_equals 1 "$(meta sm-back orca_view_owned)" "the recreated view session is owned"
  assert_grep "terminal close --terminal term-0 --tab --json" "$VIEW_DIR/orca.log" \
    "the previous tab is closed once the respawn went through"
  pass "respawn: a fresh tab replaces the previous one, which is closed"
}

test_switch_absent_changes_nothing
test_switch_on_opens_and_forwards_identity
test_unavailable_orca_steps_aside
test_respawn_replaces_the_previous_tab
test_relaunch_replaces_the_tab
test_relaunch_with_switch_off_keeps_the_tab
