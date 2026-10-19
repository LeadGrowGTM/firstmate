#!/usr/bin/env bash
# Operator status surfaces for tmux-backed fleets: a detail line on each pane
# fed by durable per-window data and a compact Claude Code statusLine fed by
# Claude's statusLine JSON input.
#
# Usage:
#   fm-statusbar.sh [--socket <path>] theme
#       Load the persistent dark theme on that server. The tracked
#       fm-statusbar.tmux snippet calls this when sourced by tmux. Its window
#       list shows a window's crew label (@fm_label, set by
#       bin/backends/tmux.sh fm_backend_tmux_show_label) in place of the
#       window name when one is set, and the name otherwise.
#   fm-statusbar.sh install|check [config-file]
#       Append/check the exact source line (default ~/.tmux.conf).
#       Install changes only the config file, never live tmux options.
#   fm-statusbar.sh source-line
#       Print the line to add to the config. Use a stable installed checkout.
#   fm-statusbar.sh label <target> <id> <harness> <model> <effort> <worktree>
#       Record the task's facts as window user options (@fm_task,
#       @fm_model, @fm_effort, @fm_wt) on one tmux window. fm-spawn
#       calls it for every tmux spawn and relaunch. Never fails the caller.
#   fm-statusbar.sh sync
#       Label every tmux window recorded in this home's state/*.meta, for
#       windows spawned before the labels existed. Idempotent.
#   fm-statusbar.sh apply [--primary] <session>
#       Turn the detail line on for windows in <session>. Grouped view sessions
#       share those window options, including views created later. --primary
#       also shows the fleet count (see fleet) at the left of the session bar.
#   fm-statusbar.sh fleet [session]
#       Print "crew N | 2nd M": live worker agents and live second mates
#       recorded in this home's state/*.meta. A tmux task counts while its
#       window exists; other backends count while their record exists.
#       With a session, read its @fm_fleet_state instead of ambient state.
#   fm-statusbar.sh crew-tracker
#       Print the cached six-mate summary. Refresh from fm-crew-state.sh in a
#       bounded background job at most once every 30 seconds.
#   fm-statusbar.sh usage <window>
#       Print the cached plan-usage segment for one window,
#       and refresh it from `quota-axi` in the background at most once a minute.
#       The cache holds account keys and percentages, never credentials.
#   fm-statusbar.sh claude-line --task <id>
#       The Claude Code statusLine command: reads Claude's statusLine JSON on
#       stdin and prints one short line (model and effort, Ctx %, live second
#       mates, task, worktree, rate-limit windows). Only whitelisted JSON
#       fields are ever printed. The mate segment is a few-second cache of
#       this home's durable records and is omitted when that cache or a
#       required source cannot be read. Mates named by secondmate_on_demand
#       are left out of it. claude-fleet-refresh rebuilds it. The
#       subscription-usage segment follows the rate-limit windows (see
#       claude-segments).
#   fm-statusbar.sh claude-segments
#       Print only the live-mates and subscription-usage segments, joined by
#       " | " on one line (empty when neither is readable), so a custom
#       statusLine wrapper can append them without calling claude-line.
#       The usage segment lists Muse (mu), Grok (gk), each Claude account
#       (cl-gmail and cl-second) and Codex (cx) as remaining percent and, when
#       COLUMNS indicates enough room, time to reset. An unmeasurable quota
#       shows "n/a"; Muse also shows "n/a" when no quota row is reported.
#       A failed read or unavailable account shows "?". Claude accounts use
#       the two directories listed in order in
#       ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/statusline-claude-accounts,
#       or the gmail and second directories under $HOME/.claude-accounts;
#       quota-axi reads each available directory using only that profile.
#       The segment only reads a cache that a
#       background quota-axi job rebuilds at most every five minutes. A cache
#       over ten minutes old is marked "(stale)" and one over an hour old is
#       dropped. The cache holds only labels, percentages and reset times.
#
# Environment: FM_STATE_OVERRIDE selects the state directory (default
# $FM_HOME/state).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
USAGE_CACHE="$STATE/statusbar-usage.txt"
USAGE_ATTEMPT="$STATE/.statusbar-usage-attempt"
USAGE_LOCK="$STATE/.statusbar-usage.lock"
USAGE_TTL=60
FLEET_CACHE="$STATE/statusbar-claude-fleet.txt"
FLEET_ATTEMPT="$STATE/.statusbar-claude-fleet-attempt"
FLEET_LOCK="$STATE/.statusbar-claude-fleet.lock"
FLEET_TTL=5
CUSAGE_CACHE="$STATE/statusbar-claude-usage.tsv"
CUSAGE_ATTEMPT="$STATE/.statusbar-claude-usage-attempt"
CUSAGE_LOCK="$STATE/.statusbar-claude-usage.lock"
CUSAGE_TTL=300
TRACKER_ROOT=${FM_SB_TRACKER_ROOT:-}
TRACKER_MAIN_HOME=${FM_SB_TRACKER_MAIN_HOME:-}
case "${1:-}" in --socket) tracker_sub=${3:-} ;; *) tracker_sub=${1:-} ;; esac
if [ -z "$TRACKER_MAIN_HOME" ]; then
  if [ "$tracker_sub" = theme ] || [ "$tracker_sub" = apply ] ||
    [ "$tracker_sub" = crew-tracker ] || [ "$tracker_sub" = crew-tracker-refresh ]; then
    if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
      TRACKER_MAIN_HOME=$(. "$SCRIPT_DIR/fm-wake-lib.sh"; fm_firstmate_root_home "$FM_HOME") || exit 1
    fi
  fi
  if [ -z "$TRACKER_MAIN_HOME" ] && [ -n "$TRACKER_ROOT" ]; then
    TRACKER_MAIN_HOME=$TRACKER_ROOT/firstmate
  elif [ -z "$TRACKER_MAIN_HOME" ]; then
    TRACKER_MAIN_HOME=$FM_HOME
  fi
fi
if [ -z "$TRACKER_ROOT" ]; then TRACKER_ROOT=${TRACKER_MAIN_HOME%/*}; fi
TRACKER_MAIN_STATE=${FM_SB_TRACKER_MAIN_STATE:-}
if [ -z "$TRACKER_MAIN_STATE" ]; then
  if [ "$FM_HOME" = "$TRACKER_MAIN_HOME" ]; then
    TRACKER_MAIN_STATE=$STATE
  else
    TRACKER_MAIN_STATE=$TRACKER_MAIN_HOME/state
  fi
fi
TRACKER_MAIN_DATA=${FM_SB_TRACKER_MAIN_DATA:-}
TRACKER_MAIN_CONFIG=${FM_SB_TRACKER_MAIN_CONFIG:-}
TRACKER_MAIN_PROJECTS=${FM_SB_TRACKER_MAIN_PROJECTS:-}
if [ "$FM_HOME" = "$TRACKER_MAIN_HOME" ]; then
  TRACKER_MAIN_DATA=${TRACKER_MAIN_DATA:-${FM_DATA_OVERRIDE:-$FM_HOME/data}}
  TRACKER_MAIN_CONFIG=${TRACKER_MAIN_CONFIG:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}}
  TRACKER_MAIN_PROJECTS=${TRACKER_MAIN_PROJECTS:-${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}}
else
  TRACKER_MAIN_DATA=${TRACKER_MAIN_DATA:-$TRACKER_MAIN_HOME/data}
  TRACKER_MAIN_CONFIG=${TRACKER_MAIN_CONFIG:-$TRACKER_MAIN_HOME/config}
  TRACKER_MAIN_PROJECTS=${TRACKER_MAIN_PROJECTS:-$TRACKER_MAIN_HOME/projects}
fi
TRACKER_CACHE_DIR=${FM_SB_TRACKER_CACHE_DIR:-$TRACKER_MAIN_STATE}
TRACKER_TTL=30
TRACKER_CREW_STATE=${FM_SB_CREW_STATE_SCRIPT:-$SCRIPT_DIR/fm-crew-state.sh}
SELF="$SCRIPT_DIR/fm-statusbar.sh"
FM_SB_SOCKET=
if [ "${1:-}" = --socket ]; then
  [ "$#" -ge 3 ] && [ -n "$2" ] || exit 2
  FM_SB_SOCKET=$2
  shift 2
fi
if [ "${1:-}" = crew-tracker ] && [ -z "$FM_SB_SOCKET" ]; then
  FM_SB_SOCKET=$(command tmux display-message -p '#{socket_path}' 2>/dev/null) || FM_SB_SOCKET=
fi
TRACKER_SOCKET_KEY=$(printf '%s\037%s\037%s\037%s\037%s' \
  "${FM_SB_SOCKET:-default}" "$TRACKER_MAIN_STATE" "$TRACKER_MAIN_DATA" \
  "$TRACKER_MAIN_CONFIG" "$TRACKER_MAIN_PROJECTS" | cksum)
TRACKER_SOCKET_KEY=${TRACKER_SOCKET_KEY%% *}
TRACKER_CACHE="$TRACKER_CACHE_DIR/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
TRACKER_ATTEMPT="$TRACKER_CACHE_DIR/.statusbar-crew-tracker-attempt.$TRACKER_SOCKET_KEY"
TRACKER_LOCK="$TRACKER_CACHE_DIR/.statusbar-crew-tracker.lock.$TRACKER_SOCKET_KEY"
# Explicit server addressing also reaches status jobs outside their caller's
# shell. Never let a named preview query the default tmux server.
tmux() {
  if [ -n "$FM_SB_SOCKET" ]; then
    command tmux -S "$FM_SB_SOCKET" "$@"
  else
    command tmux "$@"
  fi
}
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# One value, one line, no tmux style or format metacharacters, bounded length.
fm_sb_clean() {  # <value> [max]
  local v=${1-} max=${2:-60}
  v=$(printf '%s' "$v" | tr -d '\000-\037\177' | tr -d '#{}\\"'\''`$;')
  printf '%s' "${v:0:$max}"
}

# <project>/<slot> for a leased pool path ending <project>-<hash>/<slot>/<name>;
# otherwise the final path component, which names a secondmate home.
fm_sb_wt_label() {  # <path>
  local p=${1%/} base parent slot pool
  [ -n "$p" ] || return 0
  base=${p##*/}
  parent=${p%/*}
  slot=${parent##*/}
  case "$slot" in
  '' | *[!0-9]*) printf '%s' "$base" ;;
  *)
    pool=${parent%/*}
    if [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ]; then
      printf '%s/%s' "$base" "$slot"
    else
      case "${pool%/*}" in
        */.treehouse) printf '%s/%s' "$base" "$slot" ;;
        *) printf '%s' "$base" ;;
      esac
    fi
    ;;
  esac
}

# Short model: drop the vendor prefix.
fm_sb_model_label() {  # <model-id>
  local m=${1-}
  m=${m##*/}
  m=${m#claude-}
  [ "$m" != default ] || m=
  printf '%s' "$m"
}

cmd_label() {
  local target=${1:-} id=${2:-} harness=${3:-} model=${4:-} effort=${5:-} wt=${6:-}
  local provider='' account
  [ -n "$target" ] && command -v tmux >/dev/null 2>&1 || return 0
  provider=$(fm_quota_provider_for_harness "$harness" "$model") || provider=
  case "$harness" in
    agy) provider=agy ;;
    opencode|pi|pi-signed)
      case "$model" in
        openai/*|openai-codex*/*|codex-native/*) provider=codex ;;
        anthropic/*|claude-bridge/*) provider=claude ;;
        xai/grok-*) provider=grok ;;
        *) provider= ;;
      esac
      ;;
  esac
  account=$(jq -nr --arg harness "$harness" --arg model "$model" \
    "$FM_QUOTA_ROW_JQ quota_lane(\$harness; \$model)") || account=
  [ -n "$account" ] || account=default
  [ "$effort" != default ] || effort=
  tmux set-window-option -t "$target" @fm_state "$STATE" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_task "$(fm_sb_clean "$id" 64)" 2>/dev/null || return 0
  tmux set-window-option -t "$target" @fm_model "$(fm_sb_clean "$(fm_sb_model_label "$model")")" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_effort "$(fm_sb_clean "$effort" 8)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_wt "$(fm_sb_clean "$(fm_sb_wt_label "$wt")" 28)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_provider "$(fm_sb_clean "$provider" 16)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_account "$(fm_sb_clean "$account" 60)" 2>/dev/null || true
  return 0
}

# Detail line, rendered by tmux per client from shared window options.
fm_sb_format() {
  local task model effort wt use wide narrow compact
  task='#{?@fm_task,#{@fm_task},#{window_name}}'
  model='#{?@fm_task,#{?@fm_model,#{@fm_model},?},#{pane_current_command}}'
  effort='#{?@fm_effort,#{@fm_effort},?}'
  wt='#{?@fm_wt,#{@fm_wt},#{b:pane_current_path}}'
  use="#(bash \"$SELF\" --socket \"#{socket_path}\" usage #{window_id})"
  wide="#[bold]#{=24:${task}}#[nobold] | #{=20:${model}} #{=7:${effort}} | #{=22:${wt}}"
  narrow="#{=9:${task}}|#{=10:${model}} #{=4:${effort}}|#{=13:${wt}}"
  compact="#{=3:${task}}|#{=2:${model}} #{=1:${effort}}|#{=2:${wt}}"
  printf '%s' "${use}|#{?#{e|>=:#{pane_width},100},${wide},#{?#{e|>=:#{pane_width},60},${narrow},${compact}}}"
}

fm_sb_tracker_job() {
  local root_q main_q main_state_q main_data_q main_config_q main_projects_q cache_q state_q
  printf -v root_q '%q' "$TRACKER_ROOT"
  printf -v main_q '%q' "$TRACKER_MAIN_HOME"
  printf -v main_state_q '%q' "$TRACKER_MAIN_STATE"
  printf -v main_data_q '%q' "$TRACKER_MAIN_DATA"
  printf -v main_config_q '%q' "$TRACKER_MAIN_CONFIG"
  printf -v main_projects_q '%q' "$TRACKER_MAIN_PROJECTS"
  printf -v cache_q '%q' "$TRACKER_CACHE_DIR"
  printf -v state_q '%q' "$TRACKER_CREW_STATE"
  printf '#(env FM_SB_TRACKER_ROOT=%s FM_SB_TRACKER_MAIN_HOME=%s FM_SB_TRACKER_MAIN_STATE=%s FM_SB_TRACKER_MAIN_DATA=%s FM_SB_TRACKER_MAIN_CONFIG=%s FM_SB_TRACKER_MAIN_PROJECTS=%s FM_SB_TRACKER_CACHE_DIR=%s FM_SB_CREW_STATE_SCRIPT=%s bash "%s" --socket "#{socket_path}" crew-tracker)' \
    "$root_q" "$main_q" "$main_state_q" "$main_data_q" "$main_config_q" "$main_projects_q" "$cache_q" "$state_q" "$SELF"
}

cmd_sync() {
  local meta id win harness model effort wt backend home
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    case "${backend:-tmux}" in tmux) ;; *) continue ;; esac
    win=$(sed -n 's/^window=//p' "$meta" | head -1)
    case "$win" in *:*) ;; *) continue ;; esac
    harness=$(sed -n 's/^harness=//p' "$meta" | head -1)
    model=$(sed -n 's/^model=//p' "$meta" | head -1)
    effort=$(sed -n 's/^effort=//p' "$meta" | head -1)
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
    home=$(sed -n 's/^home=//p' "$meta" | head -1)
    cmd_label "$win" "$id" "$harness" "$model" "$effort" "${home:-$wt}"
  done
  return 0
}

cmd_apply() {
  local ses fmt win group group_id sid member_group target_sid primary=0 requested_primary=0 left hook binding peer_binding sessions job legacy_right
  if [ "${1:-}" = --primary ]; then primary=1; requested_primary=1; shift; fi
  ses=${1:-}
  [ "$#" -eq 1 ] && [ -n "$ses" ] || { echo 'usage: fm-statusbar.sh apply [--primary] <session>' >&2; return 2; }
  command -v tmux >/dev/null 2>&1 || return 0
  group=$(tmux display-message -p -t "$ses" '#{session_group}' 2>/dev/null) || return 0
  [ -n "$group" ] || group=$ses
  target_sid=$(tmux display-message -p -t "$ses" '#{session_id}' 2>/dev/null) || return 0
  sessions=$(tmux list-sessions -F '#{session_id} #{session_group}' 2>/dev/null) || return 0
  binding=
  while read -r sid member_group; do
    [ "$sid" = "$target_sid" ] || [ "$member_group" = "$group" ] || continue
    peer_binding=$(tmux show-options -qv -t "$sid" @fm_fleet_state 2>/dev/null) || peer_binding=
    [ -n "$peer_binding" ] || continue
    # The group owner is write-once, including claims through late views.
    [ "$peer_binding" = "$STATE" ] || return 0
    binding=$peer_binding
  done <<<"$sessions"
  if [ -n "$binding" ] || [ -e "$FM_HOME/.fm-secondmate-home" ]; then
    primary=0
    if [ "$requested_primary" -eq 1 ] && [ -n "$binding" ] && [ ! -e "$FM_HOME/.fm-secondmate-home" ]; then
      legacy_right=$(tmux show-options -qv -t "$target_sid" status-right 2>/dev/null) || legacy_right=
      [ "$legacy_right" != '#{E:pane-border-format}' ] || primary=1
    fi
  fi
  fmt=$(fm_sb_format)
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    tmux set-window-option -t "$win" pane-border-status bottom 2>/dev/null || true
    tmux set-window-option -t "$win" pane-border-format "$fmt" 2>/dev/null || true
  done < <(tmux list-windows -t "$ses" -F '#{window_id}' 2>/dev/null)
  # Pane detail may be refreshed, but an ordinary apply keeps the bound
  # primary's tracker command and grouped-view hook exactly as installed.
  if [ "$primary" -eq 0 ] && [ -n "$binding" ]; then return 0; fi
  left='[#S] '
  while read -r sid member_group; do
    [ "$sid" = "$target_sid" ] || [ "$member_group" = "$group" ] || continue
    tmux set-option -t "$sid" status-right-length 200 2>/dev/null || true
    tmux set-option -t "$sid" status-right "$(fm_sb_tracker_job)" 2>/dev/null || true
    if [ "$primary" -eq 1 ]; then
      tmux set-option -o -t "$sid" @fm_fleet_state "$STATE" 2>/dev/null || true
      tmux set-option -t "$sid" status-left-length 40 2>/dev/null || true
      tmux set-option -t "$sid" status-left "$left" 2>/dev/null || true
    fi
  done <<<"$sessions"
  group_id=${target_sid#\$}
  job=$(fm_sb_tracker_job)
  job=${job//\\/\\\\}
  hook="set-option status-right-length 200; set-option status-right \"${job//\"/\\\"}\""
  if [ "$primary" -eq 1 ]; then
    # Keep the original session's state binding in future grouped view jobs.
    hook="$hook; set-option -o @fm_fleet_state \"${STATE//\"/\\\"}\"; set-option status-left-length 40; set-option status-left \"${left//\"/\\\"}\""
  fi
  # Quote the entire action for if-shell's outer tmux parser.
  hook=${hook//\'/\'\\\'\'}
  tmux set-hook -g "after-new-session[$((10000 + group_id))]" \
    "if-shell -F '#{==:#{session_group},$group}' '$hook'" 2>/dev/null || true
  return 0
}

cmd_fleet() {
  local meta backend win kind crew=0 second=0 live='' target=${1:-}
  if [ -n "${1:-}" ]; then
    case "$target" in id:*) target="\$${target#id:}" ;; esac
    STATE=$(tmux show-options -qv -t "$target" @fm_fleet_state 2>/dev/null) || STATE=
    [ -n "$STATE" ] || { printf 'crew ? | 2nd ?\n'; return 0; }
  fi
  live=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || live=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    win=$(sed -n 's/^window=//p' "$meta" | head -1)
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ -n "$win" ] || continue
    case "$win" in
      remote:*) ;;
      *) case "${backend:-tmux}" in
      tmux) printf '%s\n' "$live" | grep -qxF -- "$win" || continue ;;
      esac ;;
    esac
    if [ "$kind" = secondmate ]; then second=$((second + 1)); else crew=$((crew + 1)); fi
  done
  printf 'crew %d | 2nd %d\n' "$crew" "$second"
}

# Run current-state reads only for task metadata with a live tmux window (or a
# non-tmux backend). Parallel reads are capped at four and each has a hard bound.
fm_sb_tracker_home() {  # <home> <mate-id> <live-windows> <output-file> [state data config projects]
  local home=$1 mate=$2 live=$3 output=$4 state_dir=${5:-$1/state}
  local data_dir=${6:-$1/data} config_dir=${7:-$1/config} projects_dir=${8:-$1/projects}
  local meta id kind backend win state running=0 waiting=0 unknown=0 suffix=
  local -a jobs=()
  local scratch="${output}.tasks"
  [ -d "$state_dir" ] || { printf '%s ?r/?w\n' "$mate" >"$output"; return 0; }
  mkdir -p "$scratch" || return 1
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ "$kind" != secondmate ] || continue
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    win=$(sed -n 's/^window=//p' "$meta" | head -1)
    if [ "${backend:-tmux}" = tmux ]; then
      if [ -z "$win" ] || ! printf '%s\n' "$live" | grep -qxF -- "$win"; then continue; fi
    fi
    (
      fm_run_timed 3 env FM_HOME="$home" FM_STATE_OVERRIDE="$state_dir" \
        FM_DATA_OVERRIDE="$data_dir" FM_CONFIG_OVERRIDE="$config_dir" \
        FM_PROJECTS_OVERRIDE="$projects_dir" TMUX="${FM_SB_SOCKET:+$FM_SB_SOCKET,0,0}" \
        FM_CREW_STATE_NO_FORGE=1 FM_CREW_STATE_NM_TIMEOUT=1 \
        bash "$TRACKER_CREW_STATE" "$id" 2>/dev/null |
        sed -n '1s/^state: \([^ ]*\).*/\1/p' >"$scratch/$id"
    ) &
    jobs+=("$!")
    if [ "${#jobs[@]}" -ge 4 ]; then
      wait "${jobs[0]}" || true
      jobs=("${jobs[@]:1}")
    fi
  done
  for id in "${jobs[@]+"${jobs[@]}"}"; do wait "$id" || true; done
  for meta in "$scratch"/*; do
    [ -f "$meta" ] || continue
    state=$(cat "$meta")
    case "$state" in
      working) running=$((running + 1)) ;;
      parked|paused|blocked) waiting=$((waiting + 1)) ;;
      done|failed) ;;
      *) unknown=$((unknown + 1)) ;;
    esac
  done
  rm -f "$scratch"/*
  rmdir "$scratch" 2>/dev/null || true
  [ "$unknown" -eq 0 ] || suffix="+${unknown}?"
  printf '%s %dr/%dw%s\n' "$mate" "$running" "$waiting" "$suffix" >"$output"
}

fm_sb_tracker_refresh() {
  local live primary_windows tmp home mate label state_dir data_dir config_dir projects_dir remote result='' i=0
  local -a mates=(churchill dev napoleon alexander-media ottersec legion)
  tmp="$TRACKER_CACHE.$$"
  live=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || return 1
  primary_windows=$(tmux list-windows -a -F '#{@fm_task}|#{@fm_state}' 2>/dev/null) || return 1
  for mate in "${mates[@]}"; do
    if [ "$mate" = churchill ]; then
      home="$TRACKER_MAIN_HOME"
      state_dir=$TRACKER_MAIN_STATE
      data_dir=$TRACKER_MAIN_DATA; config_dir=$TRACKER_MAIN_CONFIG; projects_dir=$TRACKER_MAIN_PROJECTS
      remote=
    else
      home=$(sed -n 's/^home=//p' "$TRACKER_MAIN_STATE/$mate.meta" 2>/dev/null | tail -1)
      [ -n "$home" ] || home="$TRACKER_ROOT/fm-homes/$mate"
      state_dir=$home/state
      data_dir=$home/data; config_dir=$home/config; projects_dir=$home/projects
      remote=$(sed -n '/^remote_host=./p; /^remote_backend=./p; /^window=remote:/p' \
        "$TRACKER_MAIN_STATE/$mate.meta" 2>/dev/null | head -1)
    fi
    if [ -n "$remote" ]; then
      printf '%s ?r/?w\n' "$mate" >"$tmp.$i"
    else
      fm_run_timed 27 bash "$SELF" --socket "$FM_SB_SOCKET" \
        crew-tracker-home "$home" "$mate" "$live" "$tmp.$i" "$state_dir" \
          "$data_dir" "$config_dir" "$projects_dir" &
    fi
    if [ "$mate" = churchill ]; then
      label=on
      printf '%s\n' "$primary_windows" | grep -qxF "${home##*/}|$state_dir" || label=off
      printf '%s\n' "$label" >"$tmp.label.$i"
    else
      (
        label=unknown
        if [ -f "$TRACKER_MAIN_STATE/$mate.meta" ]; then
          label=$(fm_run_timed 7 env FM_HOME="$TRACKER_MAIN_HOME" \
            FM_STATE_OVERRIDE="$TRACKER_MAIN_STATE" \
            FM_DATA_OVERRIDE="$TRACKER_MAIN_DATA" \
            FM_CONFIG_OVERRIDE="$TRACKER_MAIN_CONFIG" \
            FM_PROJECTS_OVERRIDE="$TRACKER_MAIN_PROJECTS" \
            TMUX="${FM_SB_SOCKET:+$FM_SB_SOCKET,0,0}" \
            FM_CREW_STATE_NO_FORGE=1 FM_CREW_STATE_NM_TIMEOUT=1 \
            bash "$TRACKER_CREW_STATE" "$mate" 2>/dev/null |
            sed -n '1s/^state: \([^ ]*\).*/\1/p')
        fi
        printf '%s\n' "${label:-unknown}" >"$tmp.label.$i"
      ) &
    fi
    i=$((i + 1))
  done
  wait
  i=0
  for mate in "${mates[@]}"; do
    label=$(cat "$tmp.label.$i" 2>/dev/null) || label=unknown
    rm -f "$tmp.label.$i"
    [ -f "$tmp.$i" ] || printf '%s ?r/?w\n' "$mate" >"$tmp.$i"
    result="${result}${result:+ | }$(sed "s/^$mate /$mate:$label /" "$tmp.$i")"
    rm -f "$tmp.$i"
    rm -f "$tmp.$i.tasks"/* 2>/dev/null || true
    rmdir "$tmp.$i.tasks" 2>/dev/null || true
    i=$((i + 1))
  done
  printf '%s\n' "$result" >"$tmp" && mv -f "$tmp" "$TRACKER_CACHE"
}

cmd_crew_tracker() {
  local now age
  now=$(date +%s)
  if [ -f "$TRACKER_CACHE" ]; then
    cat "$TRACKER_CACHE"
    age=$((now - $(fm_sb_mtime "$TRACKER_CACHE")))
  else
    printf 'crew: loading\n'
    age=$((TRACKER_TTL + 1))
  fi
  [ "$age" -ge "$TRACKER_TTL" ] || return 0
  if [ -f "$TRACKER_ATTEMPT" ] && [ $((now - $(fm_sb_mtime "$TRACKER_ATTEMPT"))) -lt "$TRACKER_TTL" ]; then return 0; fi
  mkdir -p "$TRACKER_CACHE_DIR" 2>/dev/null || return 0
  if [ -d "$TRACKER_LOCK" ] && [ $((now - $(fm_sb_mtime "$TRACKER_LOCK"))) -gt 60 ]; then
    rmdir "$TRACKER_LOCK" 2>/dev/null || true
  fi
  mkdir "$TRACKER_LOCK" 2>/dev/null || return 0
  touch "$TRACKER_ATTEMPT" 2>/dev/null || { rmdir "$TRACKER_LOCK"; return 0; }
  (
    trap 'rmdir "$TRACKER_LOCK" 2>/dev/null' EXIT
    FM_SB_TRACKER_ROOT="$TRACKER_ROOT" FM_SB_TRACKER_MAIN_HOME="$TRACKER_MAIN_HOME" \
      FM_SB_TRACKER_MAIN_STATE="$TRACKER_MAIN_STATE" \
      FM_SB_TRACKER_MAIN_DATA="$TRACKER_MAIN_DATA" \
      FM_SB_TRACKER_MAIN_CONFIG="$TRACKER_MAIN_CONFIG" \
      FM_SB_TRACKER_MAIN_PROJECTS="$TRACKER_MAIN_PROJECTS" \
      FM_SB_TRACKER_CACHE_DIR="$TRACKER_CACHE_DIR" \
      FM_SB_CREW_STATE_SCRIPT="$TRACKER_CREW_STATE" \
      fm_run_timed 35 bash "$SELF" --socket "${FM_SB_SOCKET:-$(tmux display-message -p '#{socket_path}' 2>/dev/null)}" crew-tracker-refresh >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 </dev/null &
}

fm_sb_mtime() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Account-wide percent used per provider from schema 5 and 6 quota rows.
fm_sb_usage_refresh() {
  local out tmp rows
  out=$(fm_run_timed 10 quota-axi 2>/dev/null </dev/null) || return 1
  rows=$(printf '%s\n' "$out" | awk '
    /^quota\[[0-9]+\]\{provider,/ {
      keyed = index($0, "provider,accountKey,") > 0; in_quota = 1; in_attention = 0; next
    }
    /^attention\[[0-9]+\]\{provider,accountKey,/ { in_quota = 0; in_attention = 1; next }
    in_quota && !/^  / { in_quota = 0 }
    in_attention && !/^  / { in_attention = 0 }
    in_quota && /^  / {
      sub(/^  /, ""); n = split($0, row, ","); scope = row[2 + keyed]; rem = row[3 + keyed]
      if (scope ~ /^".*"$/) scope = substr(scope, 2, length(scope) - 2)
      if (n < 3 + keyed || (scope != "all_models" && scope != "all_products" && scope !~ /^model:.+/ && scope !~ /^product:.+/)) next
      used = scope == "all_models" && rem ~ /^[0-9]+(\.[0-9]+)?$/ && rem + 0 <= 100 ? sprintf("%.15g", 100 - rem) : "?"
      printf "%s\t%s\t%s\n", row[1], keyed ? row[2] : "*", used
    }
    in_attention && /^  / {
      sub(/^  /, ""); n = split($0, row, ",")
      if (n >= 3 && row[1] != "" && row[2] != "") printf "%s\t%s\t?\n", row[1], row[2]
    }
  ')
  [ -n "$rows" ] || return 1
  tmp="$USAGE_CACHE.$$"
  printf '%s\n' "$rows" >"$tmp" && mv -f "$tmp" "$USAGE_CACHE"
}

fm_sb_usage_display() {  # <window>
  local provider account
  provider=$(tmux show-options -wqv -t "$1" @fm_provider 2>/dev/null) || provider=
  account=$(tmux show-options -wqv -t "$1" @fm_account 2>/dev/null) || account=
  [ -n "$provider" ] && [ -f "$USAGE_CACHE" ] || { printf 'u ?\n'; return 0; }
  awk -F '\t' -v provider="$provider" -v account="$account" '
    $1 == provider && ($2 == account || $2 == "*") { exact_exists = 1 }
    $1 == provider && $3 ~ /^[0-9]+(\.[0-9]+)?$/ {
      if ($2 == account || $2 == "*") {
        if (!matched || $3 + 0 > used) { used = $3 + 0; key = $2 }
        matched = 1
      } else if ($2 == "default") {
        if (!fallback || $3 + 0 > fallback_used) fallback_used = $3 + 0
        fallback = 1
      }
    }
    END {
      if (!exact_exists && fallback) { used = fallback_used; key = "default"; matched = 1 }
      if (!matched) { print "u ?"; exit }
      code = provider == "claude" ? "cl" : provider == "codex" ? "cx" : provider == "grok" ? "gk" : substr(provider, 1, 2)
      label = length(key) <= 14 ? key : substr(key, 1, 6) "~" substr(key, length(key) - 6)
      if (used > 0 && used < 0.05) value = "<0.1"
      else if (used < 100 && used >= 99.95) value = ">99.9"
      else { value = sprintf("%.1f", used); sub(/\.0$/, "", value) }
      printf "u %s:%s%s%%\n", code, label, value
    }
  ' "$USAGE_CACHE"
}

cmd_usage() {
  local age now state target=${1:-}
  [ -n "$target" ] || return 2
  [ -n "$(tmux show-options -wqv -t "$target" @fm_provider 2>/dev/null)" ] || { printf 'u ?\n'; return 0; }
  state=$(tmux show-options -wqv -t "$target" @fm_state 2>/dev/null) || state=
  if [ -n "$state" ]; then
    STATE=$state
    USAGE_CACHE="$STATE/statusbar-usage.txt"
    USAGE_ATTEMPT="$STATE/.statusbar-usage-attempt"
    USAGE_LOCK="$STATE/.statusbar-usage.lock"
  fi
  now=$(date +%s)
  if [ -f "$USAGE_CACHE" ]; then
    age=$((now - $(fm_sb_mtime "$USAGE_CACHE")))
  else
    age=$((USAGE_TTL + 1))
  fi
  if [ "$age" -lt "$USAGE_TTL" ]; then
    fm_sb_usage_display "$target"
  else
    printf 'u ?\n'
  fi
  [ "$age" -ge "$USAGE_TTL" ] || return 0
  if [ -f "$USAGE_ATTEMPT" ] && [ $((now - $(fm_sb_mtime "$USAGE_ATTEMPT"))) -lt "$USAGE_TTL" ]; then
    return 0
  fi
  command -v quota-axi >/dev/null 2>&1 || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  # A lock directory older than two minutes belongs to a dead refresher.
  if [ -d "$USAGE_LOCK" ] && [ $((now - $(fm_sb_mtime "$USAGE_LOCK"))) -gt 120 ]; then
    rmdir "$USAGE_LOCK" 2>/dev/null || true
  fi
  mkdir "$USAGE_LOCK" 2>/dev/null || return 0
  touch "$USAGE_ATTEMPT" 2>/dev/null || { rmdir "$USAGE_LOCK" 2>/dev/null; return 0; }
  (
    trap 'rmdir "$USAGE_LOCK" 2>/dev/null' EXIT
    fm_sb_usage_refresh >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 </dev/null &
  return 0
}

# Same liveness rule as cmd_fleet: a tmux record counts only while its window
# exists; any other backend counts while the record exists; remote: windows
# count without a probe.
fm_sb_record_live() {  # <window> <backend> <live-windows>
  local win=$1 backend=${2:-tmux} live=$3
  [ -n "$win" ] || return 1
  case "$win" in
    remote:*) return 0 ;;
  esac
  case "$backend" in
    tmux) printf '%s\n' "$live" | grep -qxF -- "$win" ;;
    *) return 0 ;;
  esac
}

fm_sb_meta_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# Newest active task in one mate home: "<name> <verb>" or "idle".
# Reads only that home's meta and status files. A missing or unreadable home
# is idle, never a failure.
fm_sb_mate_task() {  # <home> <live-windows>
  local home=$1 live=$2 state_dir
  state_dir=$home/state
  local meta id kind backend win status line verb mtime best_m=0 best_id='' best_verb=''
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] && [ -r "$state_dir" ] || { printf 'idle\n'; return 0; }
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    kind=$(fm_sb_meta_field "$meta" kind)
    [ "$kind" = secondmate ] && continue
    backend=$(fm_sb_meta_field "$meta" backend)
    win=$(fm_sb_meta_field "$meta" window)
    fm_sb_record_live "$win" "${backend:-tmux}" "$live" || continue
    status=$state_dir/$id.status
    verb=
    line=
    if [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ]; then
      line=$(status_current_line "$status" "$kind" 2>/dev/null) || line=
      status_line_verb "$line" verb || verb=
    fi
    case "$verb" in
      working|paused|blocked|needs-decision|parked) ;;
      *) continue ;;
    esac
    mtime=$(fm_sb_mtime "$status")
    [ "$mtime" != 0 ] || mtime=$(fm_sb_mtime "$meta")
    if [ "$mtime" -ge "$best_m" ]; then
      best_m=$mtime
      best_id=$id
      best_verb=$verb
    fi
  done
  if [ -n "$best_id" ]; then
    printf '%s %s\n' "$(fm_sb_clean "$best_id" 12)" "$(fm_sb_clean "$best_verb" 16)"
  else
    printf 'idle\n'
  fi
}

fm_sb_count_holds() {  # <state-dir>
  local dir=$1 n=0 task key verb _
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] || { printf '0\n'; return 0; }
  while IFS=$'\t' read -r task key verb _; do
    [ "$verb" = needs-decision ] || continue
    n=$((n + 1))
  done < <(scan_open_decisions "$dir" 2>/dev/null || true)
  printf '%s\n' "$n"
}

fm_sb_claude_fleet_refresh() {
  local data_dir reg live tmp seg='' holds=0 count=0 extra=0 piece
  local meta id kind backend win home task remote state_real mate_real mate_holds
  local -A mate_home=()
  local -a pieces=()
  data_dir=${FM_DATA_OVERRIDE:-$FM_HOME/data}
  mkdir -p "$STATE" 2>/dev/null || return 0
  reg=$data_dir/secondmates.md
  tmp="$FLEET_CACHE.$$"
  if [ -e "$reg" ] && { [ -L "$reg" ] || [ ! -r "$reg" ]; }; then
    printf '\n' >"$tmp" && mv -f "$tmp" "$FLEET_CACHE"
    return 0
  fi
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  if secondmate_on_demand_unreadable "$data_dir"; then
    printf '\n' >"$tmp" && mv -f "$tmp" "$FLEET_CACHE"
    return 0
  fi
  if [ -f "$reg" ] && [ ! -L "$reg" ]; then
    while IFS= read -r piece || [ -n "$piece" ]; do
      secondmate_registry_parse_line "$piece" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
      mate_home[$SECONDMATE_REGISTRY_ID]=$SECONDMATE_REGISTRY_HOME
    done <"$reg"
  fi
  # fm_run_timed runs the probe outside this shell, so the socket has to be an
  # argument rather than the tmux() wrapper above.
  if [ -n "$FM_SB_SOCKET" ]; then
    live=$(fm_run_timed 2 command tmux -S "$FM_SB_SOCKET" list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || live=
  else
    live=$(fm_run_timed 2 tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || live=
  fi
  holds=$(fm_sb_count_holds "$STATE") || holds=0
  state_real=$(cd "$STATE" 2>/dev/null && pwd -P) || state_real=$STATE
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    kind=$(fm_sb_meta_field "$meta" kind)
    [ "$kind" = secondmate ] || continue
    if secondmate_on_demand "$data_dir" "$id"; then
      continue
    fi
    backend=$(fm_sb_meta_field "$meta" backend)
    win=$(fm_sb_meta_field "$meta" window)
    fm_sb_record_live "$win" "${backend:-tmux}" "$live" || continue
    remote=$(fm_sb_meta_field "$meta" remote_host)
    [ -n "$remote" ] || remote=$(fm_sb_meta_field "$meta" remote_backend)
    case "$win" in remote:*) remote=${remote:-remote} ;; esac
    if [ -n "$remote" ]; then
      pieces+=("$(fm_sb_clean "$id" 12):remote")
      continue
    fi
    home=${mate_home[$id]-}
    [ -n "$home" ] || home=$(fm_sb_meta_field "$meta" home)
    if [ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ] && [ -r "$home" ]; then
      task=$(fm_sb_mate_task "$home" "$live") || task=idle
      mate_real=$(cd "$home/state" 2>/dev/null && pwd -P) || mate_real=
      if [ -n "$mate_real" ] && [ "$mate_real" != "$state_real" ]; then
        mate_holds=$(fm_sb_count_holds "$home/state") || mate_holds=0
        holds=$((holds + mate_holds))
      fi
    else
      task=idle
    fi
    pieces+=("$(fm_sb_clean "$id" 12):$task")
  done
  while IFS= read -r piece; do
    [ -n "$piece" ] || continue
    count=$((count + 1))
    if [ "$count" -le 4 ]; then
      seg="${seg}${seg:+, }$piece"
    else
      extra=$((extra + 1))
    fi
  done < <(printf '%s\n' "${pieces[@]+"${pieces[@]}"}" | LC_ALL=C sort)
  [ "$extra" -eq 0 ] || seg="${seg}${seg:+, }+$extra"
  [ "${#seg}" -le 160 ] || seg="${seg:0:157}..."
  [ "$holds" -eq 0 ] || seg="${seg}${seg:+, }hold $holds"
  printf '%s\n' "$seg" >"$tmp" && mv -f "$tmp" "$FLEET_CACHE"
}

# Start <fn> in the background unless a refresh was attempted inside <ttl>
# seconds or another is running. A lock older than <lock-max> seconds belongs
# to a dead refresher.
fm_sb_cache_kick() {  # <attempt> <lock> <ttl> <lock-max> <fn>
  local attempt=$1 lock=$2 ttl=$3 lock_max=$4 fn=$5 now
  now=$(date +%s) || return 0
  if [ -f "$attempt" ] && [ $((now - $(fm_sb_mtime "$attempt"))) -lt "$ttl" ]; then
    return 0
  fi
  mkdir -p "$STATE" 2>/dev/null || return 0
  if [ -d "$lock" ] && [ $((now - $(fm_sb_mtime "$lock"))) -gt "$lock_max" ]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null || return 0
  touch "$attempt" 2>/dev/null || { rmdir "$lock" 2>/dev/null; return 0; }
  (
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    "$fn" >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 </dev/null &
  return 0
}

fm_sb_claude_fleet_kick() {
  fm_sb_cache_kick "$FLEET_ATTEMPT" "$FLEET_LOCK" "$FLEET_TTL" 30 fm_sb_claude_fleet_refresh
}

# Warm path: print the cached segment, or nothing when it is missing.
# A stale cache is still printed; the refresh is never waited on.
fm_sb_claude_fleet_segment() {
  local now age seg=''
  now=$(date +%s) || { printf ''; return 0; }
  if [ -f "$FLEET_CACHE" ] && [ ! -L "$FLEET_CACHE" ] && [ -r "$FLEET_CACHE" ]; then
    seg=$(head -n 1 "$FLEET_CACHE" 2>/dev/null) || seg=
    age=$((now - $(fm_sb_mtime "$FLEET_CACHE")))
  else
    age=$((FLEET_TTL + 1))
  fi
  [ "$age" -lt "$FLEET_TTL" ] || fm_sb_claude_fleet_kick || true
  printf '%s' "$seg"
}

# Subscription usage segment: one cached quota-axi read per source.

# The two Claude config directories to read.
fm_sb_cusage_claude_dirs() {
  local list d
  local -a dirs=()
  list=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/statusline-claude-accounts
  if [ -f "$list" ] && [ ! -L "$list" ] && [ -r "$list" ]; then
    while IFS= read -r d || [ -n "$d" ]; do
      case "$d" in ''|'#'*) continue ;; esac
      dirs+=("${d%/}")
    done <"$list"
  else
    dirs=("$HOME/.claude-accounts/gmail" "$HOME/.claude-accounts/second")
  fi
  printf 'gmail\t%s\nsecond\t%s\n' "${dirs[0]:--}" "${dirs[1]:--}"
}

# "<pct>\t<resetsAt>" of one provider's intended account-wide row in default
# TOON on stdin, or nothing when it has none.
fm_sb_cusage_row() {  # <provider> <account>
  awk -v want="$1" -v account="$2" '
    /^quota\[[0-9]+\]\{provider,/ { keyed = index($0, "provider,accountKey,") > 0; in_quota = 1; next }
    in_quota && !/^  / { in_quota = 0 }
    in_quota && !done {
      sub(/^  /, ""); n = split($0, row, ",")
      key = keyed ? row[2] : account; scope = row[2 + keyed]
      gsub(/"/, "", key); gsub(/"/, "", scope); reset = row[n]; gsub(/"/, "", reset)
      if (row[1] != want || (scope != "all_models" && scope != "all_products")) next
      if (key == account) { done = 1; printf "%s\t%s\n", row[3 + keyed], reset }
    }
  '
}

fm_sb_cusage_attention() {  # <provider> <account>
  local toon=$3 counted inline
  counted=$(printf '%s\n' "$toon" | awk -v want="$1" -v account="$2" '
    /^attention\[[0-9]+\]\{provider,/ { keyed = index($0, "provider,accountKey,") > 0; in_attention = 1; next }
    in_attention && !/^  / { in_attention = 0 }
    in_attention {
      sub(/^  /, ""); split($0, row, ",")
      key = keyed ? row[2] : account; gsub(/"/, "", key)
      if (row[1] == want && key == account) {
        kind = row[3 + keyed]; gsub(/"/, "", kind)
        found = 1
        if (kind != "unmeasurable") result = "?"
        else if (result == "") result = "n/a"
      }
    }
    END { if (found) print result }
  ')
  if [ -n "$counted" ]; then printf '%s' "$counted"; return 0; fi
  inline=$(printf '%s\n' "$toon" | sed -n 's/^attention: //p' | head -n 1)
  [ -n "$inline" ] || return 0
  printf '%s' "$inline" | jq -r --arg provider "$1" --arg account "$2" '
    [.[] | select(.provider == $provider and (.accountKey // $account) == $account)] |
    if length == 0 then empty elif any(.[]; .kind != "unmeasurable") then "?" else "n/a" end
  ' 2>/dev/null || true
}

# ISO-8601 UTC instant to epoch seconds, or nothing.
fm_sb_cusage_epoch() {  # <iso>
  local iso
  iso=$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/')
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 0 ;;
  esac
  date -u -d "$iso" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$iso" +%s 2>/dev/null || true
}

# One cache line: "<label>\t<pct|n/a|?>\t<reset epoch|->".
fm_sb_cusage_line() {  # <label> <provider> <account> <ok> <toon>
  local label=$1 provider=$2 account=$3 ok=$4 toon=$5 row pct reset epoch attention
  if [ "$ok" != 1 ]; then
    printf '%s\t?\t-\n' "$label"
    return 0
  fi
  row=$(printf '%s\n' "$toon" | fm_sb_cusage_row "$provider" "$account")
  if [ -z "$row" ]; then
    attention=$(fm_sb_cusage_attention "$provider" "$account" "$toon")
    if [ -z "$attention" ]; then
      case "$provider" in muse) attention=n/a ;; *) attention='?' ;; esac
    fi
    printf '%s\t%s\t-\n' "$label" "$attention"
    return 0
  fi
  IFS=$'\t' read -r pct reset <<< "$row"
  if ! [[ $pct =~ ^[0-9]+(\.[0-9]+)?$ ]] || [ "$(awk -v p="$pct" 'BEGIN { print (p + 0 <= 100) }')" != 1 ]; then
    printf '%s\t?\t-\n' "$label"
    return 0
  fi
  epoch=$(fm_sb_cusage_epoch "$reset")
  printf '%s\t%s\t%s\n' "$label" "$pct" "${epoch:--}"
}

fm_sb_claude_usage_refresh() {
  local tmp toon ok=1 ok_main=1 dir label dirs main
  command -v quota-axi >/dev/null 2>&1 || return 1
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp="$CUSAGE_CACHE.$$"
  main=$(fm_run_timed 20 quota-axi --provider muse,grok,codex 2>/dev/null </dev/null) || ok_main=0
  dirs=$(fm_sb_cusage_claude_dirs)
  if ! {
    fm_sb_cusage_line mu muse default "$ok_main" "$main"
    fm_sb_cusage_line gk grok default "$ok_main" "$main"
    while IFS=$'\t' read -r label dir; do
      label="cl-$label"
      if [ "$dir" != - ] && [ -d "$dir" ]; then
        ok=1
        toon=$(fm_run_timed 20 env "CLAUDE_CONFIG_DIR=$dir" quota-axi --provider claude --profile-only 2>/dev/null </dev/null) || ok=0
        fm_sb_cusage_line "$label" claude default "$ok" "$toon"
      else
        fm_sb_cusage_line "$label" claude default 0 ''
      fi
    done <<< "$dirs"
    fm_sb_cusage_line cx codex codex-home "$ok_main" "$main"
  } >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$CUSAGE_CACHE"; then
    rm -f "$tmp"
    return 1
  fi
}

# Seconds to "2d", "1d6h", "4h12m" or "35m"; nothing when not in the future.
fm_sb_cusage_eta() {  # <seconds>
  local s=$1 d h m
  [ "$s" -gt 0 ] 2>/dev/null || return 0
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if [ "$d" -ge 2 ]; then printf '%sd' "$d"
  elif [ "$d" -ge 1 ]; then printf '%sd%sh' "$d" "$h"
  elif [ "$h" -ge 1 ]; then printf '%sh%sm' "$h" "$m"
  else printf '%sm' "$m"
  fi
}

# Warm path: render the cache, never waiting on quota-axi. Prints nothing when
# the cache is missing, unreadable or over an hour old.
fm_sb_claude_usage_segment() {  # <line-prefix>
  local prefix=$1 now age seg='' timed='' label pct reset eta shown stale='' separator=
  now=$(date +%s) || return 0
  if [ -f "$CUSAGE_CACHE" ] && [ ! -L "$CUSAGE_CACHE" ] && [ -r "$CUSAGE_CACHE" ]; then
    age=$((now - $(fm_sb_mtime "$CUSAGE_CACHE")))
  else
    age=$((CUSAGE_TTL + 1))
  fi
  if [ "$age" -ge "$CUSAGE_TTL" ]; then
    fm_sb_cache_kick "$CUSAGE_ATTEMPT" "$CUSAGE_LOCK" "$CUSAGE_TTL" 180 fm_sb_claude_usage_refresh
  fi
  [ "$age" -le 3600 ] && [ -f "$CUSAGE_CACHE" ] && [ -r "$CUSAGE_CACHE" ] || return 0
  while IFS=$'\t' read -r label pct reset; do
    [ -n "$label" ] || continue
    label=$(fm_sb_clean "$label" 14)
    case "$pct" in
      n/a|'?') shown=$pct; eta= ;;
      *) shown=$(LC_ALL=C awk -v p="$pct" 'BEGIN {
           if (p > 0 && p < 1) print "<1%"
           else if (p > 99 && p < 100) print ">99%"
           else printf "%.0f%%", p
         }')
         eta=
         [[ $reset =~ ^[0-9]+$ ]] && eta=$(fm_sb_cusage_eta $((reset - now))) ;;
    esac
    seg="${seg}${seg:+, }${label} ${shown}"
    timed="${timed}${timed:+, }${label} ${shown}${eta:+ $eta}"
  done <"$CUSAGE_CACHE"
  [ -n "$seg" ] || return 0
  [ "$age" -le 600 ] || stale=' (stale)'
  [ -z "$prefix" ] || separator=' | '
  if [[ ${COLUMNS:-} =~ ^[0-9]+$ ]] &&
    [ $(( ${#prefix} + ${#separator} + ${#timed} + ${#stale} )) -le "$COLUMNS" ]; then
    seg=$timed
  fi
  seg="$seg$stale"
  printf '%s' "$seg"
}

cmd_claude_segments() {
  local fleet usage out=
  [ "$#" -eq 0 ] || return 2
  fleet=$(fm_sb_claude_fleet_segment) || fleet=
  [ -z "$fleet" ] || out=$fleet
  usage=$(fm_sb_claude_usage_segment "$out") || usage=
  [ -z "$usage" ] || out="${out}${out:+ | }$usage"
  printf '%s\n' "$out"
}

cmd_claude_line() {
  local task json parts model effort ctx limits wt fleet usage out
  [ "$#" -eq 2 ] && [ "$1" = --task ] && [ -n "$2" ] || return 2
  task=$2
  fleet=$(fm_sb_claude_fleet_segment) || fleet=
  command -v jq >/dev/null 2>&1 || {
    out="? ? | $(fm_sb_clean "$task" 32)"
    [ -z "$fleet" ] || out="? ? | $fleet | $(fm_sb_clean "$task" 32)"
    usage=$(fm_sb_claude_usage_segment "$out") || usage=
    [ -z "$usage" ] || out="$out | $usage"
    printf '%s\n' "$out"
    return 0
  }
  json=$(cat)
  # Whitelist: model, effort, context percent, rate-limit windows, workspace name.
  parts=$(printf '%s' "$json" | jq -r '
    def pct: if . == null then "" else (. | floor | tostring) + "%" end;
    [ (.model.display_name // .model.id // ""),
      (.effort.level // ""),
      (if .context_window.used_percentage == null then "" else "Ctx " + (.context_window.used_percentage | pct) end),
      ([if .rate_limits.five_hour.used_percentage == null then empty else "5h " + (.rate_limits.five_hour.used_percentage | pct) end,
        if .rate_limits.seven_day.used_percentage == null then empty else "7d " + (.rate_limits.seven_day.used_percentage | pct) end] | join(" ")),
      (if .workspace.git_worktree != null then .workspace.git_worktree
       elif .workspace.project_dir != null then (.workspace.project_dir | split("/") | last)
       else "" end)
    ] | map(tostring) | join("\u001f")' 2>/dev/null) || parts=
  IFS=$'\037' read -r model effort ctx limits wt <<< "$parts"
  model=$(fm_sb_clean "$model" 24)
  effort=$(fm_sb_clean "$effort" 8)
  ctx=$(fm_sb_clean "$ctx" 12)
  limits=$(fm_sb_clean "$limits" 20)
  wt=$(fm_sb_clean "$wt" 24)
  out="${model:-?} ${effort:-?}"
  [ -z "$ctx" ] || out="$out | $ctx"
  [ -z "$fleet" ] || out="$out | $fleet"
  out="$out | $(fm_sb_clean "$task" 32)"
  [ -z "$wt" ] || out="$out | $wt"
  [ -z "$limits" ] || out="$out | $limits"
  usage=$(fm_sb_claude_usage_segment "$out") || usage=
  [ -z "$usage" ] || out="$out | $usage"
  printf '%s\n' "$out"
}

# Source paths enter both a tmux string and a shell command. Spaces are safe
# inside double quotes; reject characters which either parser could expand.
fm_sb_source_line() {
  case "$SCRIPT_DIR" in
    *[\'\"\\\$\`\#]* | *[[:cntrl:]]*)
      echo "statusbar: unsupported characters in installation path" >&2
      return 1 ;;
  esac
  printf 'source-file "%s/fm-statusbar.tmux"\n' "$SCRIPT_DIR"
}

cmd_config() { # install|check [config-file]
  local mode=$1 config=${2:-$HOME/.tmux.conf} line
  [ "$#" -le 2 ] || return 2
  line=$(fm_sb_source_line) || return 1
  if [ -f "$config" ] && grep -Fxq -- "$line" "$config"; then
    printf 'statusbar: sourced by %s\n' "$config"
    return 0
  fi
  if [ "$mode" = check ]; then
    printf 'statusbar: not sourced by %s; add:\n%s\n' "$config" "$line"
    return 1
  fi
  # Start a new line even if the existing file lacks its final newline.
  printf '\n%s\n' "$line" >>"$config" || return 1
  printf 'statusbar: installed in %s (live server unchanged)\n' "$config"
}

cmd_theme() {
  [ -n "$FM_SB_SOCKET" ] || { echo 'statusbar: theme requires --socket' >&2; return 2; }
  fm_sb_source_line >/dev/null || return 1
  tmux set-option -g status on &&
    tmux set-option -g status-style 'bg=colour234,fg=colour250' &&
    tmux set-option -g status-left-length 40 &&
    tmux set-option -g status-left '[#S] ' &&
    tmux set-option -g status-right-length 200 &&
    tmux set-option -g status-right "$(fm_sb_tracker_job)" &&
    tmux set-window-option -g window-status-format ' #I:#{?@fm_label,#{@fm_label},#W} ' &&
    tmux set-window-option -g window-status-current-format ' #I:#{?@fm_label,#{@fm_label},#W} ' &&
    tmux set-window-option -g window-status-current-style 'bg=colour24,fg=colour255,bold' &&
    tmux set-window-option -g pane-border-format "$(fm_sb_format)"
}

sub=${1:-}
[ $# -eq 0 ] || shift
case "$sub" in
theme) cmd_theme ;;
crew-tracker) cmd_crew_tracker ;;
crew-tracker-refresh) fm_sb_tracker_refresh ;;
crew-tracker-home) fm_sb_tracker_home "$@" ;;
install|check) cmd_config "$sub" "$@" ;;
source-line) fm_sb_source_line ;;
label) cmd_label "$@" ;;
apply) cmd_apply "$@" ;;
sync) cmd_sync ;;
usage) cmd_usage "$@" ;;
fleet) cmd_fleet "$@" ;;
claude-fleet-refresh) fm_sb_claude_fleet_refresh ;;
claude-line) cmd_claude_line "$@" ;;
claude-segments) cmd_claude_segments "$@" ;;
*)
  echo "usage: fm-statusbar.sh label|sync|apply|fleet|crew-tracker|usage|claude-line|claude-segments|theme|install|check|source-line" >&2
  exit 2
  ;;
esac
