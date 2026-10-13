#!/usr/bin/env bash
# Operator status surfaces for tmux-backed fleets: a detail line under the tmux
# window list and a compact Claude Code statusLine, both fed by durable
# per-window data instead of per-refresh probes.
#
# Usage:
#   fm-statusbar.sh label <target> <id> <kind> <harness> <model> <effort> <worktree>
#       Record the task's facts as window user options (@fm_task, @fm_kind,
#       @fm_harness, @fm_model, @fm_effort, @fm_wt) on one tmux window. fm-spawn
#       calls it for every tmux spawn and relaunch. Never fails the caller.
#   fm-statusbar.sh sync
#       Label every tmux window recorded in this home's state/*.meta, for
#       windows spawned before the labels existed. Idempotent.
#   fm-statusbar.sh apply [session]
#       Turn the detail line on for <session> and every session grouped with it
#       (the Orca view sessions), session scope only. Default: the current
#       session. Idempotent; never touches windows, panes, or attachments.
#   fm-statusbar.sh reset [session]
#       Unset exactly what apply set, restoring tmux's own defaults.
#   fm-statusbar.sh usage
#       Print the cached plan-usage segment, for example "used cl 32% cx 15%",
#       and refresh it from `quota-axi` in the background at most once a minute.
#       The cache holds percentages only and is never built from a credential.
#   fm-statusbar.sh claude-line [--task <id>] [--kind <kind>]
#       The Claude Code statusLine command: reads Claude's statusLine JSON on
#       stdin and prints one short line (model and effort, context, rate-limit
#       windows, task). Only whitelisted fields are ever printed.
#
# Environment: FM_STATE_OVERRIDE selects the state directory (default
# $FM_HOME/state); FM_STATUSBAR_USAGE_TTL overrides the 60 second refresh floor.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
USAGE_CACHE="$STATE/statusbar-usage.txt"
USAGE_LOCK="$STATE/.statusbar-usage.lock"
USAGE_TTL="${FM_STATUSBAR_USAGE_TTL:-60}"
SELF="$SCRIPT_DIR/fm-statusbar.sh"

# One value, one line, no tmux style or format metacharacters, bounded length.
fm_sb_clean() {  # <value> [max]
  local v=${1-} max=${2:-60}
  v=$(printf '%s' "$v" | tr -d '\000-\037\177' | tr -d '#{}[]\\"'\''`$;')
  printf '%s' "${v:0:$max}"
}

# <project>/<slot> for a leased pool path ending <project>-<hash>/<slot>/<name>;
# otherwise the final path component, which names a secondmate home.
fm_sb_wt_label() {  # <path>
  local p=${1%/} base parent slot
  [ -n "$p" ] || return 0
  base=${p##*/}
  parent=${p%/*}
  slot=${parent##*/}
  case "$slot" in
  '' | *[!0-9]*) printf '%s' "$base" ;;
  *) printf '%s/%s' "$base" "$slot" ;;
  esac
}

# Short model: drop vendor prefixes and context-window suffixes.
fm_sb_model_label() {  # <model-id>
  local m=${1-}
  m=${m#claude-}
  m=${m%%\[*}
  printf '%s' "$m"
}

cmd_label() {
  local target=${1:-} id=${2:-} kind=${3:-} harness=${4:-} model=${5:-} effort=${6:-} wt=${7:-}
  [ -n "$target" ] && command -v tmux >/dev/null 2>&1 || return 0
  tmux set-window-option -t "$target" @fm_task "$(fm_sb_clean "$id" 40)" 2>/dev/null || return 0
  tmux set-window-option -t "$target" @fm_kind "$(fm_sb_clean "$kind" 12)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_harness "$(fm_sb_clean "$harness" 12)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_model "$(fm_sb_clean "$(fm_sb_model_label "$model")" 24)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_effort "$(fm_sb_clean "$effort" 8)" 2>/dev/null || true
  tmux set-window-option -t "$target" @fm_wt "$(fm_sb_clean "$(fm_sb_wt_label "$wt")" 28)" 2>/dev/null || true
  return 0
}

# Detail line, rendered by tmux per client from window options; an unlabeled
# window (the primary) falls back to its live command and directory. Fields drop out
# below 100 and 70 columns so a narrow pane keeps task and model first.
fm_sb_format() {
  local task model wt use
  task='#{?@fm_task,#{=24:@fm_task},#{=24:window_name}}'
  model='#{?@fm_model,#{=20:@fm_model}#{?@fm_effort, #{@fm_effort},},#{?@fm_harness,#{@fm_harness},#{pane_current_command}}}'
  wt='#{?#{e|>=:#{client_width},70}, | #{=-22:#{?@fm_wt,#{@fm_wt},#{b:pane_current_path}}},}'
  use="#{?#{e|>=:#{client_width},100}, | #($SELF usage),}"
  printf '%s' "#[bold]${task}#[nobold]#{?@fm_kind, (#{@fm_kind}),} | ${model}${wt}${use}"
}

fm_sb_group_sessions() {  # <session>
  local ses=$1 grp name g
  grp=$(tmux display-message -p -t "$ses" '#{session_group}' 2>/dev/null) || return 0
  [ -n "$grp" ] || { printf '%s\n' "$ses"; return 0; }
  tmux list-sessions -F '#{session_name}	#{session_group}' 2>/dev/null |
    while IFS=$'\t' read -r name g; do
      [ "$g" = "$grp" ] && printf '%s\n' "$name"
    done
}

cmd_sync() {
  local meta id win harness kind model effort wt backend home
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    case "${backend:-tmux}" in tmux) ;; *) continue ;; esac
    win=$(sed -n 's/^window=//p' "$meta" | head -1)
    case "$win" in *:*) ;; *) continue ;; esac
    harness=$(sed -n 's/^harness=//p' "$meta" | head -1)
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    model=$(sed -n 's/^model=//p' "$meta" | head -1)
    effort=$(sed -n 's/^effort=//p' "$meta" | head -1)
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -1)
    home=$(sed -n 's/^home=//p' "$meta" | head -1)
    cmd_label "$win" "$id" "$kind" "$harness" "$model" "$effort" "${home:-$wt}"
  done
  return 0
}

cmd_apply() {
  local ses=${1:-} fmt line0 s
  command -v tmux >/dev/null 2>&1 || return 0
  [ -n "$ses" ] || ses=$(tmux display-message -p '#S' 2>/dev/null) || return 0
  fmt=$(fm_sb_format)
  # A session-scope array replaces the global one wholesale, so line 0 (the
  # window list) must be carried over or it would render empty.
  line0=$(tmux show-options -gv 'status-format[0]' 2>/dev/null)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    tmux set-option -t "$s" status 2 2>/dev/null || continue
    [ -z "$line0" ] || tmux set-option -t "$s" 'status-format[0]' "$line0" 2>/dev/null || true
    tmux set-option -t "$s" 'status-format[1]' "$fmt" 2>/dev/null || true
  done < <(fm_sb_group_sessions "$ses")
  return 0
}

cmd_reset() {
  local ses=${1:-} s
  command -v tmux >/dev/null 2>&1 || return 0
  [ -n "$ses" ] || ses=$(tmux display-message -p '#S' 2>/dev/null) || return 0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    tmux set-option -u -t "$s" status 2>/dev/null || true
    tmux set-option -u -t "$s" status-format 2>/dev/null || true
  done < <(fm_sb_group_sessions "$ses")
  return 0
}

fm_sb_mtime() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Percent used per provider from quota-axi's default output: rows are
# provider,scope,effectivePercentRemaining,... under the quota[...] table.
fm_sb_usage_refresh() {
  local out line prov scope rem tmp seg=
  out=$(quota-axi 2>/dev/null </dev/null) || return 1
  while IFS= read -r line; do
    prov=${line%%,*}
    scope=${line#*,}
    scope=${scope%%,*}
    rem=${line#*,*,}
    rem=${rem%%,*}
    case "$scope" in all_models | all_products) ;; *) continue ;; esac
    case "$rem" in '' | *[!0-9]*) continue ;; esac
    case "$prov" in
    claude) prov=cl ;; codex) prov=cx ;; grok) prov=gk ;; *) prov=${prov:0:2} ;;
    esac
    seg="$seg${seg:+ }$prov $((100 - rem))%"
  done < <(printf '%s\n' "$out" | sed -n 's/^  \([a-z][a-z0-9-]*,[a-z_]*,[0-9]*,.*\)$/\1/p')
  [ -n "$seg" ] || return 1
  tmp="$USAGE_CACHE.$$"
  printf 'used %s\n' "$seg" >"$tmp" && mv -f "$tmp" "$USAGE_CACHE"
}

cmd_usage() {
  local age now
  now=$(date +%s)
  if [ -f "$USAGE_CACHE" ]; then
    age=$((now - $(fm_sb_mtime "$USAGE_CACHE")))
    cat "$USAGE_CACHE" 2>/dev/null
  else
    age=$((USAGE_TTL + 1))
  fi
  [ "$age" -ge "$USAGE_TTL" ] || return 0
  command -v quota-axi >/dev/null 2>&1 || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  # A lock directory older than two minutes belongs to a dead refresher.
  if [ -d "$USAGE_LOCK" ] && [ $((now - $(fm_sb_mtime "$USAGE_LOCK"))) -gt 120 ]; then
    rmdir "$USAGE_LOCK" 2>/dev/null || true
  fi
  mkdir "$USAGE_LOCK" 2>/dev/null || return 0
  # Touch the cache first so concurrent renders and a slow or failing quota-axi
  # still wait a full TTL before the next attempt.
  [ -f "$USAGE_CACHE" ] && touch "$USAGE_CACHE" 2>/dev/null
  (
    trap 'rmdir "$USAGE_LOCK" 2>/dev/null' EXIT
    fm_sb_usage_refresh >/dev/null 2>&1 || true
  ) >/dev/null 2>&1 </dev/null &
  return 0
}

cmd_claude_line() {
  local task='' kind='' json parts
  while [ $# -gt 0 ]; do
    case "$1" in
    --task) task=${2:-}; shift ;;
    --kind) kind=${2:-}; shift ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "$(fm_sb_clean "$task")"; return 0; }
  json=$(cat)
  # Whitelist: model, effort, context fill, rate-limit windows, workspace name.
  parts=$(printf '%s' "$json" | jq -r '
    def pct: if . == null then empty else (. | floor | tostring) + "%" end;
    [ (.model.display_name // .model.id // empty),
      (.effort.level // empty),
      (.context_window.used_percentage | pct | select(. != null) | "ctx " + .),
      ((.rate_limits.five_hour.used_percentage | pct) as $f
        | (.rate_limits.seven_day.used_percentage | pct) as $w
        | if $f then "5h " + $f + (if $w then " 7d " + $w else "" end) else empty end),
      (.workspace.git_worktree // (.workspace.current_dir // empty | split("/") | last))
    ] | map(tostring) | join("\u001f")' 2>/dev/null) || parts=
  local IFS=$'\037' model effort ctx limits wt
  # shellcheck disable=SC2086
  set -- $parts
  model=$(fm_sb_clean "${1:-}" 24)
  effort=$(fm_sb_clean "${2:-}" 8)
  ctx=$(fm_sb_clean "${3:-}" 12)
  limits=$(fm_sb_clean "${4:-}" 20)
  wt=$(fm_sb_clean "${5:-}" 24)
  local out=$model
  [ -z "$effort" ] || out="$out $effort"
  [ -z "$task" ] || out="$out | $(fm_sb_clean "$task" 32)${kind:+ ($(fm_sb_clean "$kind" 12))}"
  [ -z "$wt" ] || out="$out | $wt"
  [ -z "$ctx" ] || out="$out | $ctx"
  [ -z "$limits" ] || out="$out | $limits"
  printf '%s\n' "$out"
}

sub=${1:-}
[ $# -eq 0 ] || shift
case "$sub" in
label) cmd_label "$@" ;;
apply) cmd_apply "$@" ;;
sync) cmd_sync ;;
reset) cmd_reset "$@" ;;
usage) cmd_usage ;;
claude-line) cmd_claude_line "$@" ;;
format) fm_sb_format; echo ;;
*)
  echo "usage: fm-statusbar.sh label|sync|apply|reset|usage|claude-line|format" >&2
  exit 2
  ;;
esac
