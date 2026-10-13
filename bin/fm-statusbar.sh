#!/usr/bin/env bash
# Operator status surfaces for tmux-backed fleets: a detail line on each pane
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
#       Turn the detail line on for windows in <session>. Grouped view sessions
#       share those window options, including views created later.
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
USAGE_ATTEMPT="$STATE/.statusbar-usage-attempt"
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

# Detail line, rendered by tmux per client from shared window options.
fm_sb_format() {
  local task model effort wt use wide narrow compact
  task='#{?@fm_task,#{@fm_task},#{window_name}}'
  model='#{?@fm_model,#{@fm_model},#{?@fm_harness,#{@fm_harness},#{pane_current_command}}}'
  effort='#{?@fm_effort,#{@fm_effort},?}'
  wt='#{?@fm_wt,#{@fm_wt},#{b:pane_current_path}}'
  use="#($SELF usage)"
  wide="#[bold]#{=24:${task}}#[nobold] | #{=20:${model}} #{=7:${effort}} | #{=22:${wt}}"
  narrow="#{=9:${task}}|#{=10:${model}} #{=4:${effort}}|#{=13:${wt}}"
  compact="#{=4:${task}}|#{=6:${model}} #{=3:${effort}}|#{=5:${wt}}"
  printf '%s' "#{?#{e|>=:#{client_width},100},${wide},#{?#{e|>=:#{client_width},60},${narrow},${compact}}}|${use}"
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
  local ses=${1:-} fmt win
  command -v tmux >/dev/null 2>&1 || return 0
  [ -n "$ses" ] || ses=$(tmux display-message -p '#S' 2>/dev/null) || return 0
  fmt=$(fm_sb_format)
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    tmux set-window-option -t "$win" pane-border-status bottom 2>/dev/null || true
    tmux set-window-option -t "$win" pane-border-format "$fmt" 2>/dev/null || true
  done < <(tmux list-windows -t "$ses" -F '#{window_id}' 2>/dev/null)
  return 0
}

fm_sb_mtime() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Percent used per provider from schema 5 and 6 quota rows.
fm_sb_usage_refresh() {
  local out tmp seg
  out=$(quota-axi 2>/dev/null </dev/null) || return 1
  seg=$(printf '%s\n' "$out" | awk '
    /^quota\[[0-9]+\]\{provider,/ {
      keyed = index($0, "provider,accountKey,") > 0; in_quota = 1; next
    }
    in_quota && !/^  / { in_quota = 0 }
    in_quota && /^  / {
      sub(/^  /, ""); n = split($0, row, ","); scope = row[2 + keyed]; rem = row[3 + keyed]
      if (n < 3 + keyed || (scope != "all_models" && scope != "all_products") ||
          rem !~ /^[0-9]+(\.[0-9]+)?$/ || rem + 0 > 100) next
      prov = row[1] == "claude" ? "cl" : row[1] == "codex" ? "cx" : row[1] == "grok" ? "gk" : substr(row[1], 1, 2)
      printf "%s%s%s%%", sep, prov, sprintf("%g", 100 - rem); sep = " "
    }
  ')
  [ -n "$seg" ] || return 1
  tmp="$USAGE_CACHE.$$"
  printf 'u %s\n' "$seg" >"$tmp" && mv -f "$tmp" "$USAGE_CACHE"
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

cmd_claude_line() {
  local task='' kind='' json parts model effort ctx limits wt out
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
    def pct: if . == null then "" else (. | floor | tostring) + "%" end;
    [ (.model.display_name // .model.id // ""),
      (.effort.level // ""),
      (if .context_window.used_percentage == null then "" else "ctx " + (.context_window.used_percentage | pct) end),
      ([if .rate_limits.five_hour.used_percentage == null then empty else "5h " + (.rate_limits.five_hour.used_percentage | pct) end,
        if .rate_limits.seven_day.used_percentage == null then empty else "7d " + (.rate_limits.seven_day.used_percentage | pct) end] | join(" ")),
      (if .workspace.git_worktree != null then .workspace.git_worktree
       elif .workspace.current_dir != null then (.workspace.current_dir | split("/") | last)
       else "" end)
    ] | map(tostring) | join("\u001f")' 2>/dev/null) || parts=
  IFS=$'\037' read -r model effort ctx limits wt <<< "$parts"
  model=$(fm_sb_clean "$model" 24)
  effort=$(fm_sb_clean "$effort" 8)
  ctx=$(fm_sb_clean "$ctx" 12)
  limits=$(fm_sb_clean "$limits" 20)
  wt=$(fm_sb_clean "$wt" 24)
  out=$model
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
usage) cmd_usage ;;
claude-line) cmd_claude_line "$@" ;;
*)
  echo "usage: fm-statusbar.sh label|sync|apply|usage|claude-line" >&2
  exit 2
  ;;
esac
