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
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-view)
mkdir -p "$TMP_ROOT"

# install_view_fakes <fakebin> <view-dir>: wrap the fakebin's tmux with the
# window and session reads bin/fm-orca-view.sh makes, and add the fake Orca.
install_view_fakes() {
  local fb=$1 vd=$2
  mkdir -p "$vd"
  : > "$vd/orca.log"
  : > "$vd/killed"
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
      printf '%s\t%s\t%s\n' "$n" "$w" "${FM_FAKE_TARGET_WINDOW_ID:-@$n}"
      n=$((n + 1))
    done < "$D/windows"
    exit 0 ;;
  *'#{window_id}'*) printf '%s\n' "${FM_FAKE_TARGET_WINDOW_ID:-@0}"; exit 0 ;;
  *'#{session_name}'*)
    [ "${FM_FAKE_VIEW_LOOKUP_FAIL:-}" != 1 ] || exit 1
    if [ -n "${FM_FAKE_BASE_SESSION:-}" ]; then
      printf '%s\n' "$FM_FAKE_BASE_SESSION"
      exit 0
    fi
    exec "$here/tmux.base" "$@" ;;
  *'#{session_grouped}'*)
    case "$*" in
      *=fmview-* | *=orca-*)
        args=$*
        view=${args#*=}
        view=${view%%:*}
        group=${FM_FAKE_BASE_SESSION:-firstmate}
        [ ! -e "$D/group-$view" ] || group=$(cat "$D/group-$view")
        printf '1\t%s\n' "$group" ;;
      *) printf '0\t\n' ;;
    esac
    exit 0 ;;
  *'#{session_group}'*)
    args=$*
    view=${args#*=}
    view=${view%%:*}
    group=${FM_FAKE_BASE_SESSION:-firstmate}
    [ ! -e "$D/group-$view" ] || group=$(cat "$D/group-$view")
    printf '%s\n' "$group"
    exit 0 ;;
  *'#{session_id}'*) printf '$1\n'; exit 0 ;;
  *'#{session_attached}'*) printf '0\n'; exit 0 ;;
  *'#{socket_path}'*) printf '/tmp/fm-fake-socket\n'; exit 0 ;;
esac
case "${1:-}" in
  show-options|set-option)
    view=
    option=
    value=
    for a in "$@"; do
      case "$a" in
        =fmview-*: | =orca-*: ) view=${a#=}; view=${view%:} ;;
        @fm_view_window) option=1 ;;
      esac
      value=$a
    done
    [ "$option" = 1 ] && [ -n "$view" ] || exec "$here/tmux.base" "$@"
    if [ "$1" = show-options ]; then
      [ -e "$D/option-$view" ] || exit 1
      cat "$D/option-$view"
    elif [ "$value" = @fm_view_window ]; then
      rm -f "$D/option-$view"
    else
      printf '%s\n' "$value" > "$D/option-$view"
    fi
    exit 0 ;;
  new-window) printf '%s\n' "$*" >> "$D/new-windows"; exec "$here/tmux.base" "$@" ;;
  has-session)
    for a in "$@"; do
      case "$a" in =fmview-* | =orca-*) [ -e "$D/session-${a#=}" ]; exit $? ;; esac
    done ;;
  new-session)
    s=
    prev=
    for a in "$@"; do
      [ "$prev" != -s ] || s=$a
      prev=$a
    done
    case "$s" in
      fmview-* | orca-*) : > "$D/session-$s"; printf '%s\n' "${FM_FAKE_BASE_SESSION:-firstmate}" > "$D/group-$s"; exit 0 ;;
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
    if [ ! -e "$D/identity-missing" ]; then
      worktree_id=wt-1
      [ ! -e "$D/identity-incomplete" ] || worktree_id=
      env ORCA_PANE_KEY="tab-$n:leaf" ORCA_TAB_ID="tab-$n" ORCA_WORKTREE_ID="$worktree_id" \
        ORCA_AGENT_HOOK_ENDPOINT=/hooks/endpoint.env ORCA_AGENT_HOOK_ENV=production \
        ORCA_AGENT_HOOK_VERSION=1 ORCA_AGENT_HOOK_TOKEN=never-forwarded \
        sh -c "$cmd" >/dev/null 2>&1
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"term-%s","tabId":"tab-%s"}}}\n' "$n" "$n" ;;
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

install_identity_probe() {
  local h
  for h in codex claude; do
    cat > "$1/$h" <<'SH'
#!/bin/sh
printf 'pane=%s tab=%s worktree=%s endpoint=%s env=%s version=%s\n' \
  "${ORCA_PANE_KEY-unset}" "${ORCA_TAB_ID-unset}" "${ORCA_WORKTREE_ID-unset}" \
  "${ORCA_AGENT_HOOK_ENDPOINT-unset}" "${ORCA_AGENT_HOOK_ENV-unset}" "${ORCA_AGENT_HOOK_VERSION-unset}"
SH
    chmod +x "$1/$h"
  done
}

# The pane carries an inherited identity of some unrelated Orca terminal, as a
# tmux server started inside an Orca terminal would hand every new window.
run_launch() {  # <fakebin> <pane-exports> <launch>
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    ORCA_PANE_KEY=tab-0:leaf ORCA_TAB_ID=tab-0 ORCA_WORKTREE_ID=wt-1 \
    ORCA_AGENT_HOOK_ENDPOINT=/hooks/endpoint.env ORCA_AGENT_HOOK_ENV=production ORCA_AGENT_HOOK_VERSION=1 \
    ORCA_AGENT_HOOK_TOKEN=stale-token \
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
  local name=$1 id=$2 switch=$3 allowlist=${4:-} identity_mode=${5:-} base_session=${6:-} harness=${7:-}
  local -a harness_args=()
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  VIEW_DIR="$CASE_DIR/view"
  PANE_LOG="$CASE_DIR/pane.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  install_view_fakes "$FAKEBIN" "$VIEW_DIR"
  if [ -n "$harness" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$harness"
    chmod +x "$FAKEBIN/$harness"
    harness_args=(--harness "$harness")
  fi
  [ -z "$identity_mode" ] || : > "$VIEW_DIR/identity-$identity_mode"
  printf 'fm-%s\n' "$id" > "$VIEW_DIR/windows"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id"
  [ "$switch" = absent ] || printf '%s\n' "$switch" > "$HOME_DIR/config/orca-view-tabs"
  [ -z "$allowlist" ] || : > "$HOME_DIR/config/launch-env-allowlist"
  make_secondmate_home "$CASE_DIR/sm" "$id"
  [ ! -f "$TMP_ROOT/$name.prior-meta" ] || cp "$TMP_ROOT/$name.prior-meta" "$HOME_DIR/state/$id.meta"
  [ ! -f "$TMP_ROOT/$name.other-meta" ] || cp "$TMP_ROOT/$name.other-meta" "$HOME_DIR/state/another.meta"
  : > "$PANE_LOG"
  : > "$LAUNCH_LOG"
  OUT=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" FM_FAKE_VIEW_DIR="$VIEW_DIR" \
    FM_FAKE_BASE_SESSION="$base_session" \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    fm_test_run_spawn "$HOME_DIR" "$CASE_DIR/sm" "$FAKEBIN" "$id" "$CASE_DIR/sm" --secondmate "${harness_args[@]}")
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

test_failed_container_lookup_stops_spawn() {
  local pane
  for pane in %missing ''; do
    FM_FAKE_VIEW_LOOKUP_FAIL=1 TMUX_PANE="$pane" spawn_secondmate "lookup-${pane:-none}" sm-lookup absent
    [ "$STATUS" -ne 0 ] || fail "a failed tmux container lookup accepted the spawn"
    assert_contains "$OUT" "could not resolve the tmux container session" \
      "the spawn reports the failed container lookup"
    assert_absent "$VIEW_DIR/new-windows" "no window is created after the lookup fails"
  done
  pass "a failed pane or client session lookup stops spawn before window creation"
}

test_switch_on_opens_and_forwards_identity() {
  local seen
  spawn_secondmate on sm-on on allowlist
  expect_code 0 "$STATUS" "a secondmate spawn with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-on orca_view_handle)" "the tab's handle is recorded"
  assert_equals fmview-sm-on "$(meta sm-on orca_view_session)" "the view session is recorded"
  assert_contains "$(cat "$VIEW_DIR/orca.log")" 'terminal create --worktree 33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate --title sm-on' \
    "the tab is titled for the secondmate on the configured default firstmate project"
  assert_present "$VIEW_DIR/session-fmview-sm-on" "the spawn created the tab's view session"
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

test_missing_identity_keeps_fresh_spawn_unbadged() {
  local seen
  spawn_secondmate missing-identity sm-missing on allowlist missing
  expect_code 0 "$STATUS" "a missing Orca identity must not fail the secondmate spawn: $OUT"
  assert_equals "" "$(meta sm-missing orca_view_handle)" "an unbadged tab is not recorded"
  assert_no_grep "terminal close --terminal term-1 --tab --json" "$VIEW_DIR/orca.log" \
    "a tab without an identity stays open for the operator"
  install_env_probe "$FAKEBIN"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$PANE_LOG")" "$(cat "$LAUNCH_LOG")") \
    || fail "the launch after missing identity failed to run"
  assert_equals "pane=unset token=unset" "$seen" \
    "a fresh spawn clears unrelated inherited identity when tab identity never arrives"
  pass "missing identity: the secondmate launches without recording or forwarding the new tab"
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

# relaunch_secondmate <case> <id> <switch> [untracked]: a live secondmate whose
# record names the tab term-0, relaunched through the operator verb. With
# `untracked` the record names no tab, as for a secondmate launched before the
# switch, whose hand-opened tab made the view session.
relaunch_secondmate() {
  local name=$1 id=$2 switch=$3 untracked=${4:-} identity_mode=${5:-} harness=${6:-} prior_view=${7:-fmview-$2} sm
  local -a harness_args=()
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
  if [ -n "$harness" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$harness"
    chmod +x "$FAKEBIN/$harness"
    harness_args=(--harness "$harness")
  fi
  if [ "${FM_FAKE_STAGE_FAIL:-}" = 1 ]; then
    cat > "$FAKEBIN/mkdir" <<'SH'
#!/usr/bin/env bash
case "$*" in
  /tmp/fm-*+*) exit 1 ;;
esac
exec /bin/mkdir "$@"
SH
    chmod +x "$FAKEBIN/mkdir"
  fi
  [ -z "$identity_mode" ] || : > "$VIEW_DIR/identity-$identity_mode"
  make_secondmate_home "$sm" "$id"
  mkdir -p "$sm/state"
  : > "$VIEW_DIR/literal"
  : > "$VIEW_DIR/keys"
  printf 'codex' > "$VIEW_DIR/command"
  printf 'fm-%s\n' "$id" > "$VIEW_DIR/windows"
  printf '%s' "$sm" > "$VIEW_DIR/cwd"
  : > "$VIEW_DIR/session-$prior_view"
  printf 'fmses\n' > "$VIEW_DIR/group-$prior_view"
  [ -n "$untracked" ] || printf '@0\n' > "$VIEW_DIR/option-$prior_view"
  if [ -n "$untracked" ]; then
    : > "$VIEW_DIR/session-orca-$id"
    printf 'fmses\n' > "$VIEW_DIR/group-orca-$id"
    printf '@99\n' > "$VIEW_DIR/option-orca-$id"
  fi
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
    if [ -z "$untracked" ]; then
      echo "orca_view_handle=term-0"
      echo "orca_view_session=$prior_view"
      echo "orca_view_owned=1"
    fi
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$CASE_DIR/user-home"
  OUT=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$VIEW_DIR" FM_FAKE_VIEW_DIR="$VIEW_DIR" \
    FM_FAKE_BASE_SESSION=fmses \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch "${harness_args[@]}" 2>&1)
  STATUS=$?
}

test_relaunch_replaces_the_tab() {
  local seen launch
  relaunch_secondmate relaunch-on sm-re on
  expect_code 0 "$STATUS" "a secondmate relaunch with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-re orca_view_handle)" "the fresh tab replaces the recorded one"
  assert_no_grep "terminal close --terminal term-0 --tab --json" "$VIEW_DIR/orca.log" \
    "the previous tab is left open once the relaunch went through"
  assert_no_grep "terminal close --terminal term-1" "$VIEW_DIR/orca.log" "the fresh tab stays open"
  [ ! -s "$VIEW_DIR/killed" ] || fail "a relaunch must keep the view session the fresh tab reattached: $(cat "$VIEW_DIR/killed")"
  install_env_probe "$FAKEBIN"
  launch=$(grep -E 'encode launch-brief|Firstmate operational input waiting' "$VIEW_DIR/literal" | tail -1)
  [ -n "$launch" ] || fail "the relaunch sent no replacement launch"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$VIEW_DIR/keys")" "$launch") \
    || fail "the replacement launch failed to run: $seen"
  assert_contains "$seen" "pane=tab-1:leaf" "the replacement agent badges the fresh tab"
  pass "relaunch: opens a fresh tab, forwards its identity, and leaves the previous tab open and keeps the view session"
}


test_aborted_relaunch_keeps_prior_tab_record() {
  local seen
  FM_FAKE_STAGE_FAIL=1 relaunch_secondmate relaunch-abort sm-abort on
  [ "$STATUS" -ne 0 ] || fail "launch staging failure must abort the relaunch"
  assert_contains "$OUT" "refusing to stage the launch command" \
    "the relaunch reached staging after opening and publishing the new tab"
  assert_equals term-0 "$(meta sm-abort orca_view_handle)" "the record still names the tab whose identity the surviving pane uses"
  assert_equals fmview-sm-abort "$(meta sm-abort orca_view_session)" "the surviving view is recorded"
  assert_no_grep "terminal close --terminal term-1 --tab --json" "$VIEW_DIR/orca.log" \
    "abort leaves the replacement tab open"
  assert_no_grep "terminal close --terminal term-0" "$VIEW_DIR/orca.log" \
    "abort keeps the prior tab open for the operator"
  assert_no_grep 'tab-1:leaf' "$VIEW_DIR/keys" \
    "launch staging failure sends no replacement identity into the pane"
  install_identity_probe "$FAKEBIN"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$VIEW_DIR/keys")" codex) \
    || fail "the surviving pane's identity could not be checked"
  assert_equals "pane=tab-0:leaf tab=tab-0 worktree=wt-1 endpoint=/hooks/endpoint.env env=production version=1" "$seen" \
    "the surviving pane keeps all six fields of the prior tab identity"
  pass "aborted relaunch leaves both tabs open"
}

test_post_export_abort_keeps_replacement_tab() {
  FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
    relaunch_secondmate relaunch-post-export sm-post on '' '' kimi
  [ "$STATUS" -ne 0 ] || fail "Kimi readiness failure must abort the relaunch"
  assert_contains "$OUT" "kimi did not show a verified ready signal" \
    "the relaunch reached readiness after sending the new identity"
  assert_equals term-1 "$(meta sm-post orca_view_handle)" "the exported tab remains recorded"
  assert_equals fmview-sm-post "$(meta sm-post orca_view_session)" "the exported view remains recorded"
  assert_grep 'tab-1:leaf' "$VIEW_DIR/keys" "the new identity was sent to the pane"
  assert_no_grep "terminal close --terminal term-0 --tab --json" "$VIEW_DIR/orca.log" \
    "abort leaves the superseded tab open"
  assert_no_grep "terminal close --terminal term-1" "$VIEW_DIR/orca.log" \
    "abort keeps the tab bound to the surviving pane"
  pass "post-export relaunch abort retains the new tab and leaves the prior tab open"
}


test_post_export_fresh_abort_keeps_only_tab() {
  FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
    spawn_secondmate fresh-post-export sm-fresh-post on '' '' '' kimi
  [ "$STATUS" -ne 0 ] || fail "Kimi readiness failure must abort the fresh spawn"
  assert_contains "$OUT" "kimi did not show a verified ready signal" \
    "the fresh spawn reached readiness after sending the new identity"
  assert_equals term-1 "$(meta sm-fresh-post orca_view_handle)" "the only tab remains recorded"
  assert_equals fmview-sm-fresh-post "$(meta sm-fresh-post orca_view_session)" "the only view remains recorded"
  assert_grep 'tab-1:leaf' "$PANE_LOG" "the new identity was sent to the pane"
  assert_no_grep "terminal close --terminal term-1" "$VIEW_DIR/orca.log" \
    "abort keeps the only tab bound to the surviving pane"
  pass "post-export fresh abort retains its only tab and task record"
}

test_cross_home_view_name_collision() {
  spawn_secondmate cross-first sm-cross on
  expect_code 0 "$STATUS" "the first home's secondmate should open its view: $OUT"
  assert_equals fmview-sm-cross "$(meta sm-cross orca_view_session)" \
    "the first home's default view name is preserved"
  mkdir -p "$TMP_ROOT/cross-second/view"
  : > "$TMP_ROOT/cross-second/view/session-fmview-sm-cross"
  printf 'firstmate\n' > "$TMP_ROOT/cross-second/view/group-fmview-sm-cross"
  spawn_secondmate cross-second sm-cross on '' '' otherbase
  expect_code 0 "$STATUS" "the second home's secondmate should open a distinct view: $OUT"
  assert_equals fmview-sm-cross-s-otherbase "$(meta sm-cross orca_view_session)" \
    "a foreign view is replaced by a deterministic name containing this base session"
  assert_present "$VIEW_DIR/session-fmview-sm-cross-s-otherbase" \
    "the second home creates its own grouped view"
  assert_present "$VIEW_DIR/session-fmview-sm-cross" \
    "the first home's view remains untouched"
  assert_equals term-1 "$(meta sm-cross orca_view_handle)" \
    "the second home records the tab it opened"
  assert_no_grep 'kill-session' "$VIEW_DIR/killed" "no foreign view is removed"
  mkdir -p "$TMP_ROOT/cross-dotted/view"
  : > "$TMP_ROOT/cross-dotted/view/session-fmview-sm-cross"
  printf 'firstmate\n' > "$TMP_ROOT/cross-dotted/view/group-fmview-sm-cross"
  : > "$TMP_ROOT/cross-dotted/view/session-fmview-sm-cross-h-6f746865722e62617365"
  printf 'firstmate\n' > "$TMP_ROOT/cross-dotted/view/group-fmview-sm-cross-h-6f746865722e62617365"
  spawn_secondmate cross-dotted sm-cross on '' '' other.base
  expect_code 0 "$STATUS" "a dotted base session should also open a distinct view: $OUT"
  assert_equals fmview-sm-cross-h-6f746865722e62617365-1 "$(meta sm-cross orca_view_session)" \
    "a dotted base session has a deterministic valid view name"
  assert_present "$VIEW_DIR/session-fmview-sm-cross-h-6f746865722e62617365-1" \
    "the dotted home creates its own grouped view"
  pass "same secondmate id in different base sessions gets a distinct Orca view"
}

test_derived_view_name_collision() {
  local candidate
  mkdir -p "$TMP_ROOT/derived-collision/view"
  for candidate in fmview-dev fmview-dev-s-beta; do
    : > "$TMP_ROOT/derived-collision/view/session-$candidate"
    printf 'firstmate\n' > "$TMP_ROOT/derived-collision/view/group-$candidate"
  done
  spawn_secondmate derived-collision dev on '' '' beta
  expect_code 0 "$STATUS" "a collision with the derived name should still open a tab: $OUT"
  assert_equals fmview-dev-s-beta-1 "$(meta dev orca_view_session)" \
    "the first available numbered name is selected"
  assert_present "$VIEW_DIR/session-fmview-dev-s-beta-1" \
    "the tab gets its own view instead of reusing the foreign view"
  for candidate in fmview-dev fmview-dev-s-beta; do
    assert_present "$VIEW_DIR/session-$candidate" "the foreign $candidate view survives"
  done

  mkdir -p "$TMP_ROOT/derived-exhausted/view"
  for candidate in fmview-dev fmview-dev-s-beta fmview-dev-s-beta-{1..5}; do
    : > "$TMP_ROOT/derived-exhausted/view/session-$candidate"
    printf 'firstmate\n' > "$TMP_ROOT/derived-exhausted/view/group-$candidate"
  done
  spawn_secondmate derived-exhausted dev on '' '' beta
  expect_code 0 "$STATUS" "exhausted view names should not fail the agent spawn: $OUT"
  assert_equals "" "$(meta dev orca_view_handle)" "no foreign tab is recorded"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -cF 'note: no available Orca view session name for dev in beta')" \
    "exhaustion reports one note"
  assert_no_grep 'terminal create' "$VIEW_DIR/orca.log" \
    "Orca receives no create when every candidate belongs to another base"
  pass "derived name collisions use numbered views or step aside after a bounded search"
}

test_same_group_view_name_alias() {
  local first_view second_view candidate
  first_view="$TMP_ROOT/same-group-first/view"
  second_view="$TMP_ROOT/same-group-second/view"
  mkdir -p "$first_view" "$second_view"
  : > "$first_view/session-fmview-dev"
  printf 'otherbase\n' > "$first_view/group-fmview-dev"
  spawn_secondmate same-group-first dev on '' '' beta
  expect_code 0 "$STATUS" "the dev secondmate should open its derived view: $OUT"
  assert_equals fmview-dev-s-beta "$(meta dev orca_view_session)" \
    "dev uses the derived name when its primary name belongs to another base"
  assert_equals @0 "$(cat "$VIEW_DIR/option-fmview-dev-s-beta")" \
    "dev's view records its original target window"
  for candidate in fmview-dev-s-beta fmview-dev-s-beta-s-beta fmview-dev-s-beta-s-beta-1; do
    : > "$second_view/session-$candidate"
    printf 'beta\n' > "$second_view/group-$candidate"
    printf '@0\n' > "$second_view/option-$candidate"
  done
  FM_FAKE_TARGET_WINDOW_ID=@1 spawn_secondmate same-group-second dev-s-beta on '' '' beta
  expect_code 0 "$STATUS" "a secondmate with the derived name as its ID should open its own view: $OUT"
  assert_equals fmview-dev-s-beta-s-beta-2 "$(meta dev-s-beta orca_view_session)" \
    "occupied primary, derived, and numbered views of another window are skipped"
  for candidate in fmview-dev-s-beta fmview-dev-s-beta-s-beta fmview-dev-s-beta-s-beta-1; do
    assert_equals @0 "$(cat "$VIEW_DIR/option-$candidate")" \
      "a different secondmate's view target stays unchanged"
  done
  assert_equals @1 "$(cat "$VIEW_DIR/option-fmview-dev-s-beta-s-beta-2")" \
    "the new view tracks this secondmate's window"
  pass "same-group view aliases cannot retarget another secondmate's tab"
}

test_base_session_is_not_a_view_candidate() {
  local view="$TMP_ROOT/base-view-collision/view"
  mkdir -p "$view"
  : > "$view/session-fmview-dev"
  printf 'fmview-dev\n' > "$view/group-fmview-dev"
  spawn_secondmate base-view-collision dev on '' '' fmview-dev
  expect_code 0 "$STATUS" "a base-name collision must not block spawn: $OUT"
  assert_equals fmview-dev-s-fmview-dev "$(meta dev orca_view_session)" \
    "spawn chooses a distinct view rather than the base"
  assert_absent "$VIEW_DIR/option-fmview-dev" "spawn never installs tracking on its base"
  pass "spawn: refuses the base itself as a view candidate and opens a distinct view"
}

test_recycled_prior_view_is_not_reused() {
  local view="$TMP_ROOT/recycled-prior/view"
  mkdir -p "$view"
  : > "$view/session-fmview-dev"
  printf 'otherbase\n' > "$view/group-fmview-dev"
  : > "$view/session-fmview-dev-s-beta"
  printf 'beta\n' > "$view/group-fmview-dev-s-beta"
  printf '@1\n' > "$view/option-fmview-dev-s-beta"
  cat > "$TMP_ROOT/recycled-prior.prior-meta" <<EOF
kind=secondmate
backend=tmux
orca_view_handle=term-old
orca_view_session=fmview-dev-s-beta
orca_view_owned=1
EOF
  spawn_secondmate recycled-prior dev on '' '' beta
  expect_code 0 "$STATUS" "a recycled prior view must not block respawn: $OUT"
  assert_equals fmview-dev-s-beta-1 "$(meta dev orca_view_session)" "respawn creates its own view"
  assert_equals @1 "$(cat "$VIEW_DIR/option-fmview-dev-s-beta")" "respawn leaves the other secondmate's view target alone"
  assert_no_grep 'kill-session' "$VIEW_DIR/killed" "replacement cleanup never kills the rejected recycled view"
  assert_no_grep 'terminal close --terminal term-old' "$VIEW_DIR/orca.log" "replacement leaves both the old tab and recycled session alone"
  pass "respawn: a recycled prior view name cannot retarget another secondmate's view"
}

test_another_recorded_owner_is_not_adopted() {
  local view="$TMP_ROOT/recorded-owner/view"
  mkdir -p "$view"
  : > "$view/session-fmview-dev-s-beta"
  printf 'beta\n' > "$view/group-fmview-dev-s-beta"
  cat > "$TMP_ROOT/recorded-owner.other-meta" <<EOF
kind=secondmate
orca_view_session=fmview-dev-s-beta
orca_view_owned=1
EOF
  cp "$TMP_ROOT/recorded-owner.other-meta" "$TMP_ROOT/recorded-owner.prior-meta"
  spawn_secondmate recorded-owner dev-s-beta on '' '' beta
  expect_code 0 "$STATUS" "another owner's view must not block respawn: $OUT"
  assert_equals fmview-dev-s-beta-s-beta "$(meta dev-s-beta orca_view_session)" \
    "a view recorded for another secondmate is never adopted"
  assert_absent "$VIEW_DIR/option-fmview-dev-s-beta" "the other owner's untracked view is untouched"
  pass "respawn: creates a distinct view when another secondmate owns the recorded prior name"
}


test_incomplete_identity_keeps_prior_tab() {
  local seen launch
  relaunch_secondmate relaunch-incomplete sm-incomplete on '' incomplete
  expect_code 0 "$STATUS" "an incomplete identity must not fail relaunch: $OUT"
  assert_equals term-0 "$(meta sm-incomplete orca_view_handle)" \
    "the previous tab stays recorded when replacement identity is incomplete"
  assert_no_grep "terminal close --terminal term-1 --tab --json" "$VIEW_DIR/orca.log" \
    "the unbadged replacement tab stays open"
  assert_no_grep "terminal close --terminal term-0" "$VIEW_DIR/orca.log" \
    "the previous tab remains open"
  [ ! -s "$VIEW_DIR/killed" ] || fail "the prior tab's view session must remain"
  install_identity_probe "$FAKEBIN"
  launch=$(grep -E 'encode launch-brief|Firstmate operational input waiting' "$VIEW_DIR/literal" | tail -1)
  [ -n "$launch" ] || fail "the relaunch sent no replacement launch"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$VIEW_DIR/keys")" "$launch") \
    || fail "the relaunch after incomplete identity failed to run"
  assert_equals "pane=tab-0:leaf tab=tab-0 worktree=wt-1 endpoint=/hooks/endpoint.env env=production version=1" "$seen" \
    "the relaunched agent keeps all six identity fields of recorded term-0"
  pass "incomplete identity: the old tab, record, and agent identity survive relaunch"
}

# A secondmate already running when the switch is turned on gets its identity at
# its next relaunch. An untracked view and a hand-opened tab stay untouched.
test_relaunch_preserves_untracked_views() {
  local seen launch
  relaunch_secondmate relaunch-adopt sm-adopt on untracked
  expect_code 0 "$STATUS" "relaunching a secondmate launched before the switch should succeed: $OUT"
  assert_equals term-1 "$(meta sm-adopt orca_view_handle)" "the relaunch records its fresh tab"
  assert_equals fmview-sm-adopt-s-fmses "$(meta sm-adopt orca_view_session)" "the relaunch creates a distinct view"
  assert_absent "$VIEW_DIR/option-fmview-sm-adopt" "an untracked feature-named view is not adopted"
  assert_equals @99 "$(cat "$VIEW_DIR/option-orca-sm-adopt")" "the hand-opened view's window stays unchanged"
  assert_present "$VIEW_DIR/session-orca-sm-adopt" "the hand-opened grouped session stays present"
  assert_no_grep "terminal close" "$VIEW_DIR/orca.log" "no tab is closed, so a hand-opened tab stays open"
  [ ! -s "$VIEW_DIR/killed" ] || fail "no view session may be removed: $(cat "$VIEW_DIR/killed")"
  install_env_probe "$FAKEBIN"
  launch=$(grep -E 'encode launch-brief|Firstmate operational input waiting' "$VIEW_DIR/literal" | tail -1)
  [ -n "$launch" ] || fail "the relaunch sent no replacement launch"
  seen=$(run_launch "$FAKEBIN" "$(grep -E '^(export|unset) ' "$VIEW_DIR/keys")" "$launch") \
    || fail "the replacement launch failed to run: $seen"
  assert_equals "pane=tab-1:leaf token=unset" "$seen" "the replacement agent starts with the fresh tab's identity"
  pass "relaunch opens its own view and identity while untracked and hand-opened sessions stay untouched"
}

test_relaunch_with_switch_off_keeps_the_tab() {
  relaunch_secondmate relaunch-off sm-keep off
  expect_code 0 "$STATUS" "a secondmate relaunch with the switch off should succeed: $OUT"
  assert_equals term-0 "$(meta sm-keep orca_view_handle)" "the recorded tab stays recorded"
  [ ! -s "$VIEW_DIR/orca.log" ] || fail "no Orca call may happen with the switch off: $(cat "$VIEW_DIR/orca.log")"
  pass "relaunch with the switch off keeps the recorded tab for the operator and makes no Orca call"
}

# The window-gone recovery respawns a secondmate over its existing record; its
# previous tab is left open while the recorded handle is replaced.
test_respawn_replaces_the_previous_tab() {
  printf 'window=firstmate:fm-sm-back\nendpoint_task_id=sm-back\nkind=secondmate\norca_view_handle=term-0\norca_view_session=fmview-sm-back\norca_view_owned=1\n' \
    > "$TMP_ROOT/respawn.prior-meta"
  spawn_secondmate respawn sm-back on
  expect_code 0 "$STATUS" "a secondmate respawn with the switch on should succeed: $OUT"
  assert_equals term-1 "$(meta sm-back orca_view_handle)" "the fresh tab replaces the recorded one"
  assert_no_grep "terminal close --terminal term-0 --tab --json" "$VIEW_DIR/orca.log" \
    "the previous tab is left open once the respawn went through"
  pass "respawn: a fresh tab replaces the previous one, which stays open"
}

test_views_are_never_automatically_closed() {
  local out status child childhome
  spawn_secondmate never-close sm-retain on
  expect_code 0 "$STATUS" "the cleanup fixture must spawn: $OUT"
  : > "$VIEW_DIR/orca-down"
  out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_VIEW_DIR="$VIEW_DIR" \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    "$ROOT/bin/fm-orca-view.sh" open \
    --target firstmate:fm-sm-retain --view-session orca-failed 2>&1)
  status=$?
  rm -f "$VIEW_DIR/orca-down"
  expect_code 3 "$status" "a failed open reports Orca refusal: $out"
  # Forced parent teardown traverses this child record too.
  child="$CASE_DIR/sm/state/child.meta"
  mkdir -p "$(dirname "$child")"
  childhome="$CASE_DIR/nested-home"
  make_secondmate_home "$childhome" child
  printf 'kind=secondmate\nwindow=firstmate:fm-child\nworktree=%s\nproject=%s\nhome=%s\norca_view_handle=term-child\norca_view_session=fmview-child\norca_view_owned=1\n' \
    "$childhome" "$childhome" "$childhome" > "$child"
  printf 'off\n' > "$HOME_DIR/config/orca-view-tabs"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_FAKE_VIEW_DIR="$VIEW_DIR" FM_FAKE_PANE_PATH="$CASE_DIR/sm" \
    FM_ORCA_CLI="$FAKEBIN/orca-ide" FM_WSL_INTEROP_DIR="$CASE_DIR/no-wsl" \
    TMUX=fake,1,0 "$TEARDOWN" sm-retain --force 2>&1)
  status=$?
  expect_code 0 "$status" "switch-off recursive teardown must finish: $out"
  [ ! -e "$child" ] || fail "recursive cleanup did not visit the child record"
  local log
  for log in "$TMP_ROOT"/*/view/killed; do
    assert_no_grep 'kill-session' "$log" "open failure, replacement, abort, switch-off and recursive teardown never kill view sessions"
  done
  for log in "$TMP_ROOT"/*/view/orca.log; do
    assert_no_grep 'terminal close' "$log" "Firstmate never closes Orca view tabs"
  done
  pass "view lifecycle: no session kill or tab close across open failure, replacement, abort, switch-off and recursive cleanup"
}

test_switch_absent_changes_nothing
test_failed_container_lookup_stops_spawn
test_switch_on_opens_and_forwards_identity
test_unavailable_orca_steps_aside
test_missing_identity_keeps_fresh_spawn_unbadged
test_respawn_replaces_the_previous_tab
test_relaunch_replaces_the_tab
test_aborted_relaunch_keeps_prior_tab_record
test_post_export_abort_keeps_replacement_tab
test_post_export_fresh_abort_keeps_only_tab
test_cross_home_view_name_collision
test_derived_view_name_collision
test_same_group_view_name_alias
test_base_session_is_not_a_view_candidate
test_recycled_prior_view_is_not_reused
test_another_recorded_owner_is_not_adopted
test_incomplete_identity_keeps_prior_tab
test_relaunch_preserves_untracked_views
test_relaunch_with_switch_off_keeps_the_tab
test_views_are_never_automatically_closed
