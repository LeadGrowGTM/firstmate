#!/usr/bin/env bash
# fm-orca-view.sh - an optional Orca desktop tab that views one tmux window.
#
# Usage:
#   fm-orca-view.sh enabled <config-dir>
#   fm-orca-view.sh open --target <session:window> --view-session <name> [--title <text>] [--identity-file <path>]
#   fm-orca-view.sh window <@N> [--title <text>]
#   fm-orca-view.sh identity --file <path> --tab-id <id>
#   fm-orca-view.sh follow --view-session <name> [--socket <path>]
#
# Orca shows only its own terminals, so a tmux window becomes visible there when
# an Orca terminal attaches to it. The tab attaches a grouped tmux view session
# (`tmux new-session -t <base> -s <view>`), so every tab can show a different
# window without moving any other viewer, and an existing view session of that
# name is reused only when it carries this feature's tracking marker.
# An untracked collision gets a distinct view name without changing the old one.
# tmux keeps owning the agent's lifetime:
# closing the tab, or Orca restarting, never stops the agent.
#
# The view session follows its agent's window by the window's stable tmux id
# (@N), never by index or name. `open` records that id in the session's
# @fm_view_window option, selects it, and installs a session-window-changed
# hook that runs `follow`; so when the session's current window changes, such
# as after the agent's window closes and tmux falls back to another one, the
# view returns to the agent's window, or detaches when that window is gone.
# Firstmate never closes view tabs or kills their grouped sessions.
# The operator or ordinary tmux session cleanup removes unused views.
#
# enabled   prints `on` or `off` from <config-dir>/orca-view-tabs
#           (docs/configuration.md "Orca view tabs" owns the switch). An absent
#           file is off; any other content is off with a one-line warning.
# open      creates or reuses the view session, points it at the target window
#           as described above, then creates the Orca terminal on the
#           home-local Orca project (config/orca-view-project; schema in
#           docs/configuration.md "Orca view tabs")
#           and prints handle=<terminal-handle>
#           with its view_session=<name>. Failed opens leave the view session
#           in place. With --identity-file the tab first writes its own Orca
#           terminal identity to a unique file beside that path and prints
#           identity_file=<path> and tab_id=<id> from the fresh terminal reply.
#           Pass those values to `identity`; the requested path is only a prefix.
# window    is the helper any home (the primary or a second mate) calls to
#           pop open an Orca tab on one tmux window of its own tmux server,
#           named by that window's stable id @N (`tmux display-message -p
#           '#{window_id}'` prints it). It finds the session holding the
#           window, preferring a base session over a grouped viewer, and runs
#           `open` with view session `orca-w<N>` and the title
#           <session>:<window-name> unless --title is given, so it prints the
#           same two lines and the tab follows the window the same way.
#           An unknown or malformed id is exit 1 or 2, and an unreachable
#           Orca is exit 3 with a note saying why, as for every Orca step.
# identity  waits up to 15 seconds for that unique file, checks its
#           ORCA_TAB_ID against --tab-id from the fresh handle, then prints one
#           `export NAME='value' ...` line carrying the tab's identity -
#           ORCA_PANE_KEY, ORCA_TAB_ID, ORCA_WORKTREE_ID, the hook endpoint
#           file path ORCA_AGENT_HOOK_ENDPOINT, ORCA_AGENT_HOOK_ENV, and
#           ORCA_AGENT_HOOK_VERSION - and removes the file. An agent launched
#           with those variables reports its working and done state to that
#           tab. No port or token is carried: Orca's hook reads them from the
#           endpoint file at every hook call.
# follow    is what the view session's hook runs: it re-selects the recorded
#           window when the view shows another one. When that window is gone,
#           it detaches the view's clients and removes its own tracking.
# Tracking records its appended entry's marker in @fm_view_hook_id.
# @fm_view_parent_hooks holds copied inherited entries so their local shadow
# can be removed when untracking, unless another local entry has changed.
#
# Every Orca step stops at a one-line `note:` on stderr and exit 3 when Orca, its
# command line, or the registered worktree is unavailable, so a caller can let
# its own work continue. Exit 2 is invalid use, 1 a tmux target that does not
# exist.
#
# The Orca command line is $FM_ORCA_CLI when set; else `orca` on macOS; else
# `orca-ide` on PATH; else, on WSL, the newest launcher Orca installs under
# %APPDATA%\orca\wsl-managed-cli. On WSL every Orca call runs with the
# /run/WSL/<n>_interop socket bin/fm-wsl-interop-lib.sh proves answers, never
# the inherited WSL_INTEROP, which a long-lived tmux server can hold from a
# login that has ended; when none answers, the note says so. The terminal is created
# with `--shell wsl.exe`. FM_ORCA_VIEW_TIMEOUT bounds each Orca call (60).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wsl-interop-lib.sh
. "$SCRIPT_DIR/fm-wsl-interop-lib.sh"

IDENTITY_NAMES="ORCA_PANE_KEY ORCA_TAB_ID ORCA_WORKTREE_ID ORCA_AGENT_HOOK_ENDPOINT ORCA_AGENT_HOOK_ENV ORCA_AGENT_HOOK_VERSION"

usage() {
  sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$0"
}

die_usage() { echo "error: $*" >&2; exit 2; }
note() { echo "note: $*" >&2; exit 3; }

sh_quote() {  # POSIX single-quote form, safe for any shell the tab or pane runs
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

on_wsl() {  # the interop directory bin/fm-wsl-interop-lib.sh reads marks WSL
  [ -d "${FM_WSL_INTEROP_DIR:-/run/WSL}" ]
}

cmd_enabled() {
  local dir=${1:-} file value lines
  [ -n "$dir" ] || die_usage "enabled needs <config-dir>"
  file="$dir/orca-view-tabs"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'off\n'
    return 0
  fi
  lines=$(awk 'END { print NR }' "$file" 2>/dev/null) || lines=0
  value=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$file" 2>/dev/null) || value='(unreadable)'
  case "$lines:$value" in
  1:on | 1:off) printf '%s\n' "$value" ;;
  *)
    echo "warning: config/orca-view-tabs holds '$value'; accepted values are on and off, so Orca view tabs stay off" >&2
    printf 'off\n'
    ;;
  esac
}

orca_project() {
  local file="$CONFIG/orca-view-project" value lines
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' '33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate'
    return 0
  fi
  lines=$(awk 'END { print NR }' "$file" 2>/dev/null) ||
    note "cannot read config/orca-view-project, so no Orca tab was opened"
  value=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$file" 2>/dev/null) ||
    note "cannot read config/orca-view-project, so no Orca tab was opened"
  [ "$lines" = 1 ] && [ -n "$value" ] ||
    note "config/orca-view-project must contain one nonempty Orca worktree selector"
  printf '%s\n' "$value"
}

# resolve_target <session:window>: sets BASE_SESSION (the group base's name),
# BASE_ID (its $-id), WINDOW_ID, and SOCKET from an exact match on the window's
# index, name, or id. tmux answers an absent target from
# the active window, so the match is made against a session inventory instead.
resolve_target() {
  local target=$1 session window inventory idx name id grouped group
  case "$target" in
  *:*) session=${target%%:*} window=${target#*:} ;;
  *) die_usage "--target must be <session>:<window>" ;;
  esac
  [ -n "$session" ] && [ -n "$window" ] || die_usage "--target must be <session>:<window>"
  inventory=$(tmux list-windows -t "=$session" -F $'#{window_index}\t#{window_name}\t#{window_id}' 2>/dev/null) || {
    echo "error: tmux session $session does not exist" >&2
    exit 1
  }
  WINDOW_ID=
  while IFS=$'\t' read -r idx name id; do
    if [ "$window" = "$idx" ] || [ "$window" = "$name" ] || [ "$window" = "$id" ]; then
      WINDOW_ID=$id
      break
    fi
  done <<EOF
$inventory
EOF
  [ -n "$WINDOW_ID" ] || { echo "error: tmux window $target does not exist" >&2; exit 1; }
  BASE_SESSION=$session
  IFS=$'\t' read -r grouped group <<EOF
$(tmux display-message -p -t "=$session:" $'#{session_grouped}\t#{session_group}' 2>/dev/null)
EOF
  if [ "$grouped" = 1 ] && [ -n "$group" ] && [ "$group" != "$session" ] &&
    tmux list-windows -t "=$group" -F '#{window_id}' 2>/dev/null | grep -Fxq "$WINDOW_ID"; then
    BASE_SESSION=$group
  fi
  BASE_ID=$(tmux display-message -p -t "=$BASE_SESSION:" '#{session_id}' 2>/dev/null)
  [ -n "$BASE_ID" ] || { echo "error: tmux session $BASE_SESSION does not exist" >&2; exit 1; }
  SOCKET=$(tmux display-message -p -t "=$session:" '#{socket_path}' 2>/dev/null) || SOCKET=
}

# view_command <identity-file>: the line the tab's shell runs. It attaches only
# the view session `open` prepared, so a view that ended is never recreated
# showing whatever window its base session has current.
view_command() {
  local idfile=$1 cmd='' tmux_cmd grep_re view
  if [ -n "$idfile" ]; then
    grep_re="^($(printf '%s' "$IDENTITY_NAMES" | tr ' ' '|'))="
    cmd="(umask 077; env | grep -E $(sh_quote "$grep_re") > $(sh_quote "$idfile.tmp") && mv -f $(sh_quote "$idfile.tmp") $(sh_quote "$idfile")); "
  fi
  tmux_cmd=tmux
  [ -z "$SOCKET" ] || tmux_cmd="tmux -S $(sh_quote "$SOCKET")"
  view=$(sh_quote "=$VIEW_SESSION")
  cmd="$cmd$tmux_cmd attach-session -t $view; $tmux_cmd show-options -v -t $view @fm_view_window >/dev/null 2>&1 || printf '%s\\n' $(sh_quote "The agent window this tab showed is gone, so its view detached; this tab can be closed.")"
  printf '%s\n' "$cmd"
}

# tmux_quote <text>: one double-quoted tmux command-language word.
tmux_quote() {
  local t=$1
  t=${t//\\/\\\\}
  t=${t//\"/\\\"}
  t=${t//\$/\\\$}
  t=${t//#/##}
  printf '"%s"' "$t"
}

# track_view: point VIEW_SESSION at WINDOW_ID by id and install the hook that
# keeps it there (header). Fails when the view session cannot show the window.
track_view() {
  local follow hook_id local_hooks inherited_hooks hook_line added_hook
  follow="$(sh_quote "$SCRIPT_DIR/fm-orca-view.sh") follow --view-session $(sh_quote "$VIEW_SESSION")"
  [ -z "$SOCKET" ] || follow="$follow --socket $(sh_quote "$SOCKET")"
  tmux set-option -t "=$VIEW_SESSION:" @fm_view_window "$WINDOW_ID" || return 1
  hook_id=$(tmux show-options -v -t "=$VIEW_SESSION:" @fm_view_hook_id 2>/dev/null) || hook_id=
  if [ -z "$hook_id" ] || ! view_hook_name "$VIEW_SESSION" "$hook_id" >/dev/null; then
    added_hook="fm-orca-view-${BASHPID:-$$}"
    local_hooks=$(tmux show-options -H -t "=$VIEW_SESSION:" session-window-changed) || return 1
    if [ -z "$local_hooks" ]; then
      inherited_hooks=$(view_hook_lines "$VIEW_SESSION" inherited) || return 1
      tmux set-option -t "=$VIEW_SESSION:" @fm_view_parent_hooks "$inherited_hooks" || return 1
      while IFS= read -r hook_line; do
        [ -n "$hook_line" ] || continue
        tmux set-hook -t "=$VIEW_SESSION:" "${hook_line%% *}" "${hook_line#* }" || return 1
      done <<EOF
$inherited_hooks
EOF
    fi
    tmux set-hook -a -t "=$VIEW_SESSION:" session-window-changed \
      "run-shell -b $(tmux_quote ": $added_hook; $follow")" || return 1
    tmux set-option -t "=$VIEW_SESSION:" @fm_view_hook_id "$added_hook" || return 1
  fi
  tmux select-window -t "=$VIEW_SESSION:$WINDOW_ID"
}

view_hook_lines() {  # <view> [inherited]; normalize tmux's empty array display
  local flag=-H hooks line name
  [ "${2:-}" != inherited ] || flag=-AH
  hooks=$(tmux show-options "$flag" -t "=$1:" session-window-changed 2>/dev/null) || return 1
  case "$hooks" in '' | session-window-changed) return 0 ;; esac
  while IFS= read -r line; do
    name=${line%% *}
    printf '%s %s\n' "${name%\*}" "${line#* }"
  done <<EOF
$hooks
EOF
}

view_hook_name() {  # <view> <id>; match only this feature's identifiable entry
  local line
  [ -n "$2" ] || return 1
  while IFS= read -r line; do
    case "$line" in *": $2;"*) printf '%s\n' "${line%% *}"; return 0 ;; esac
  done <<EOF
$(view_hook_lines "$1")
EOF
  return 1
}

untrack_view() {  # <view-session>; remove only the identifiable entry
  local hook_id hook_name parent hooks
  hook_id=$(tmux show-options -v -t "=$1:" @fm_view_hook_id 2>/dev/null) || hook_id=
  if hook_name=$(view_hook_name "$1" "$hook_id"); then
    tmux set-hook -u -t "=$1:" "$hook_name" 2>/dev/null || true
  fi
  if parent=$(tmux show-options -v -t "=$1:" @fm_view_parent_hooks 2>/dev/null); then
    hooks=$(view_hook_lines "$1") || hooks=unknown
    # Restore inheritance only if nobody added or changed a local entry.
    if [ "$hooks" = "$parent" ]; then
      tmux set-hook -u -t "=$1:" session-window-changed 2>/dev/null || true
    fi
  fi
  tmux set-option -u -t "=$1:" @fm_view_hook_id 2>/dev/null || true
  tmux set-option -u -t "=$1:" @fm_view_parent_hooks 2>/dev/null || true
  tmux set-option -u -t "=$1:" @fm_view_window 2>/dev/null || true
}

parse_view_args() {
  TARGET='' VIEW_SESSION='' TITLE='' IDFILE=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --target) TARGET=${2:-}; shift 2 || die_usage "--target needs a value" ;;
    --view-session) VIEW_SESSION=${2:-}; shift 2 || die_usage "--view-session needs a value" ;;
    --title) TITLE=${2:-}; shift 2 || die_usage "--title needs a value" ;;
    --identity-file) IDFILE=${2:-}; shift 2 || die_usage "--identity-file needs a value" ;;
    *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$TARGET" ] || die_usage "--target is required"
  [ -n "$VIEW_SESSION" ] || die_usage "--view-session is required"
  case "$VIEW_SESSION" in *[:.=]* | *[[:space:]]*) die_usage "--view-session must be a plain tmux session name" ;; esac
  [ -n "$TITLE" ] || TITLE=$VIEW_SESSION
}

# orca_env: set ORCA_CLI and, on WSL, export a live WSL_INTEROP for Orca calls.
orca_env() {
  local live appdata dir
  live=
  if on_wsl; then
    live=$(fm_wsl_live_interop) || note "no live Windows-interop socket answers, so Orca cannot be reached from WSL"
    export WSL_INTEROP="$live"
  fi
  if [ -n "${FM_ORCA_CLI:-}" ]; then
    ORCA_CLI=$FM_ORCA_CLI
  elif [ "$(uname -s)" = Darwin ] && command -v orca >/dev/null 2>&1; then
    ORCA_CLI=$(command -v orca)
  elif command -v orca-ide >/dev/null 2>&1; then
    ORCA_CLI=$(command -v orca-ide)
  elif [ -n "$live" ] && command -v wslpath >/dev/null 2>&1; then
    appdata=$(cd / && fm_run_timed 10 /mnt/c/Windows/System32/cmd.exe /c 'echo %APPDATA%' 2>/dev/null </dev/null | tr -d '\r')
    dir=$(wslpath -u "$appdata" 2>/dev/null)/orca/wsl-managed-cli
    # shellcheck disable=SC2012 # newest launcher by mtime; the paths are Orca's own hash directories
    ORCA_CLI=$(ls -t "$dir"/*/orca-ide 2>/dev/null | head -n 1)
  else
    ORCA_CLI=
  fi
  [ -n "$ORCA_CLI" ] && [ -x "$ORCA_CLI" ] || note "no Orca command line was found (set FM_ORCA_CLI, or install Orca's CLI)"
}

orca_call() {
  local timeout=${FM_ORCA_VIEW_TIMEOUT:-60}
  case "$timeout" in '' | 0* | *[!0-9]*) timeout=60 ;; esac
  (cd / && fm_run_timed "$timeout" "$ORCA_CLI" "$@" </dev/null 2>&1)
}

cmd_open() {
  local cmd out handle tab_id grouped tracked project suffix
  parse_view_args "$@"
  resolve_target "$TARGET"
  [ "$VIEW_SESSION" != "$BASE_SESSION" ] || note "the base session cannot be used as its own view"
  command -v jq >/dev/null 2>&1 || note "jq is not installed, so Orca's reply cannot be read"
  project=$(orca_project) || return 3
  orca_env
  if ! tmux has-session -t "=$VIEW_SESSION" 2>/dev/null; then
    tmux new-session -d -t "$BASE_ID" -s "$VIEW_SESSION" ||
      note "tmux did not create view session $VIEW_SESSION"
  else
    grouped=$(tmux display-message -p -t "=$VIEW_SESSION:" '#{session_grouped}' 2>/dev/null) || grouped=
    if [ "$grouped" != 1 ] ||
      ! tmux list-windows -t "=$VIEW_SESSION" -F '#{window_id}' 2>/dev/null | grep -Fxq "$WINDOW_ID"; then
      note "view session $VIEW_SESSION belongs to another tmux base session"
    fi
    tracked=$(tmux show-options -v -t "=$VIEW_SESSION:" @fm_view_window 2>/dev/null) || tracked=
    if [ -z "$tracked" ]; then
      # An existing untracked group may belong to a hand-opened tab.
      # Allocate our own session without selecting or installing hooks on it.
      suffix=1
      while tmux has-session -t "=$VIEW_SESSION-fmview-$suffix" 2>/dev/null; do
        suffix=$((suffix + 1))
      done
      VIEW_SESSION="$VIEW_SESSION-fmview-$suffix"
      tmux new-session -d -t "$BASE_ID" -s "$VIEW_SESSION" ||
        note "tmux did not create view session $VIEW_SESSION"
    else
      [ "$tracked" = "$WINDOW_ID" ] ||
        note "view session $VIEW_SESSION already tracks another tmux window"
    fi
  fi
  track_view || note "view session $VIEW_SESSION cannot show window $WINDOW_ID of $BASE_SESSION"
  if [ -n "$IDFILE" ]; then
    IDFILE=$(mktemp "$IDFILE.XXXXXXXXXX") || note "cannot allocate a unique Orca identity handoff"
  fi
  cmd=$(view_command "$IDFILE")
  set -- terminal create --worktree "$project" --title "$TITLE" --command "$cmd" --json
  ! on_wsl || set -- "$@" --shell wsl.exe
  out=$(orca_call "$@") || note "Orca is unreachable or refused the view tab: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  handle=$(printf '%s' "$out" | jq -r 'select(.ok == true) | .result.terminal.handle // empty' 2>/dev/null)
  [ -n "$handle" ] || note "Orca did not return a terminal handle: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  printf 'handle=%s\nview_session=%s\n' "$handle" "$VIEW_SESSION"
  if [ -n "$IDFILE" ]; then
    tab_id=$(printf '%s' "$out" | jq -r 'select(.ok == true) | .result.terminal.tabId // empty' 2>/dev/null)
    [ -n "$tab_id" ] || note "Orca did not return the fresh terminal's tab identity"
    printf 'identity_file=%s\ntab_id=%s\n' "$IDFILE" "$tab_id"
  fi
}

cmd_window() {
  local id='' title='' inventory wid session name grouped group pick='' first=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --title) title=${2:-}; shift 2 || die_usage "--title needs a value" ;;
    -*) die_usage "unknown argument: $1" ;;
    *) [ -z "$id" ] || die_usage "window takes one window id"; id=$1; shift ;;
    esac
  done
  case "$id" in
  @ | @*[!0-9]* | [!@]* | '') die_usage "window needs a tmux window id such as @5" ;;
  esac
  inventory=$(tmux list-windows -a -F $'#{window_id}\t#{session_name}\t#{window_name}\t#{session_grouped}\t#{session_group}' 2>/dev/null) || {
    echo "error: no tmux server answers here" >&2
    exit 1
  }
  # A grouped viewer, such as another tab's view session, lists the window
  # too; name the tab after the session that owns it.
  while IFS=$'\t' read -r wid session name grouped group; do
    [ "$wid" = "$id" ] || continue
    [ -n "$first" ] || first="$session"$'\t'"$name"
    if [ "$grouped" != 1 ] || [ "$group" = "$session" ]; then
      pick="$session"$'\t'"$name"
      break
    fi
  done <<EOF
$inventory
EOF
  [ -n "$pick" ] || pick=$first
  [ -n "$pick" ] || { echo "error: tmux window $id does not exist on this tmux server" >&2; exit 1; }
  session=${pick%%$'\t'*}
  name=${pick#*$'\t'}
  cmd_open --target "$session:$id" --view-session "orca-w${id#@}" --title "${title:-$session:$name}"
}

cmd_follow() {
  local view='' socket='' want cur
  while [ $# -gt 0 ]; do
    case "$1" in
    --view-session) view=${2:-}; shift 2 || die_usage "--view-session needs a value" ;;
    --socket) socket=${2:-}; shift 2 || die_usage "--socket needs a value" ;;
    *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$view" ] || die_usage "--view-session is required"
  [ -z "$socket" ] || tmux() { command tmux -S "$socket" "$@"; }
  want=$(tmux show-options -v -t "=$view:" @fm_view_window 2>/dev/null) || return 0
  [ -n "$want" ] || return 0
  cur=$(tmux display-message -p -t "=$view:" '#{window_id}' 2>/dev/null) || return 0
  [ "$cur" != "$want" ] || return 0
  tmux select-window -t "=$view:$want" 2>/dev/null && return 0
  untrack_view "$view"
  tmux detach-client -s "=$view" 2>/dev/null || true
}

cmd_identity() {
  local file='' tab_id='' deadline line name value out='' seen=' ' error=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --file) file=${2:-}; shift 2 || die_usage "--file needs a value" ;;
    --tab-id) tab_id=${2:-}; shift 2 || die_usage "--tab-id needs a value" ;;
    *) die_usage "unknown argument: $1" ;;
    esac
  done
  [ -n "$file" ] || die_usage "--file is required"
  [ -n "$tab_id" ] || die_usage "--tab-id from the fresh terminal reply is required"
  deadline=$(($(date +%s) + 15))
  while [ ! -s "$file" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || note "the Orca view tab did not report its identity within 15s"
    sleep 0.2
  done
  while IFS= read -r line || [ -n "$line" ]; do
    name=${line%%=*}
    value=${line#*=}
    case " $IDENTITY_NAMES " in *" $name "*) ;; *) continue ;; esac
    case "$value" in '' | *[[:cntrl:]]*) continue ;; esac
    case "$seen" in *" $name "*) error="the Orca identity repeats $name"; break ;; esac
    if [ "$name" = ORCA_TAB_ID ] && [ "$value" != "$tab_id" ]; then
      error="the Orca identity does not belong to the fresh terminal handle"
      break
    fi
    out="$out $name=$(sh_quote "$value")"
    seen="$seen$name "
  done <"$file"
  rm -f "$file"
  [ -z "$error" ] || note "$error"
  for name in $IDENTITY_NAMES; do
    case "$seen" in *" $name "*) ;; *) note "the Orca view tab's identity has no $name" ;; esac
  done
  printf 'export%s\n' "$out"
}

case "${1:-}" in
-h | --help) usage; exit 0 ;;
enabled) shift; cmd_enabled "$@" ;;
open) shift; cmd_open "$@" ;;
window) shift; cmd_window "$@" ;;
identity) shift; cmd_identity "$@" ;;
follow) shift; cmd_follow "$@" ;;
'') usage >&2; exit 2 ;;
*) die_usage "unknown subcommand: $1" ;;
esac
