#!/usr/bin/env bash
# Operator status surfaces for tmux-backed fleets: a detail line on each pane
# and a compact Claude Code statusLine, both fed by durable
# per-window data instead of per-refresh probes.
#
# Usage:
#   fm-statusbar.sh [--socket <path>] theme
#       Load the persistent dark theme on that server. The tracked
#       fm-statusbar.tmux snippet calls this when sourced by tmux.
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
#   fm-statusbar.sh apply <session>
#       Turn the detail line on for windows in <session>. Grouped view sessions
#       share those window options, including views created later.
#   fm-statusbar.sh usage <window>
#       Print the cached plan-usage segment for one window,
#       and refresh it from `quota-axi` in the background at most once a minute.
#       The cache holds account keys and percentages, never credentials.
#   fm-statusbar.sh claude-line --task <id>
#       The Claude Code statusLine command: reads Claude's statusLine JSON on
#       stdin and prints one short line (model and effort, rate-limit
#       windows, task). Only whitelisted fields are ever printed.
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
SELF="$SCRIPT_DIR/fm-statusbar.sh"
FM_SB_SOCKET=
if [ "${1:-}" = --socket ]; then
  [ "$#" -ge 3 ] && [ -n "$2" ] || exit 2
  FM_SB_SOCKET=$2
  shift 2
fi
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
    case "${pool%/*}" in
      */.treehouse) printf '%s/%s' "$base" "$slot" ;;
      *) printf '%s' "$base" ;;
    esac
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
  local ses=${1:-} fmt win group group_id sid member_group target_sid
  [ "$#" -eq 1 ] && [ -n "$ses" ] || { echo 'usage: fm-statusbar.sh apply <session>' >&2; return 2; }
  command -v tmux >/dev/null 2>&1 || return 0
  fmt=$(fm_sb_format)
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    tmux set-window-option -t "$win" pane-border-status bottom 2>/dev/null || true
    tmux set-window-option -t "$win" pane-border-format "$fmt" 2>/dev/null || true
  done < <(tmux list-windows -t "$ses" -F '#{window_id}' 2>/dev/null)
  group=$(tmux display-message -p -t "$ses" '#{session_group}' 2>/dev/null) || return 0
  [ -n "$group" ] || group=$ses
  target_sid=$(tmux display-message -p -t "$ses" '#{session_id}' 2>/dev/null) || return 0
  while read -r sid member_group; do
    [ "$sid" = "$target_sid" ] || [ "$member_group" = "$group" ] || continue
    tmux set-option -t "$sid" status-right-length 200 2>/dev/null || true
    tmux set-option -t "$sid" status-right '#{E:pane-border-format}' 2>/dev/null || true
  done < <(tmux list-sessions -F '#{session_id} #{session_group}' 2>/dev/null)
  group_id=${target_sid#\$}
  tmux set-hook -g "after-new-session[$((10000 + group_id))]" \
    "if-shell -F '#{==:#{session_group},$group}' 'set-option status-right-length 200; set-option status-right \"#{E:pane-border-format}\"'" 2>/dev/null || true
  return 0
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

cmd_claude_line() {
  local task json parts model effort limits wt out
  [ "$#" -eq 2 ] && [ "$1" = --task ] && [ -n "$2" ] || return 2
  task=$2
  command -v jq >/dev/null 2>&1 || { printf '? ? | %s\n' "$(fm_sb_clean "$task" 32)"; return 0; }
  json=$(cat)
  # Whitelist: model, effort, rate-limit windows, workspace name.
  parts=$(printf '%s' "$json" | jq -r '
    def pct: if . == null then "" else (. | floor | tostring) + "%" end;
    [ (.model.display_name // .model.id // ""),
      (.effort.level // ""),
      ([if .rate_limits.five_hour.used_percentage == null then empty else "5h " + (.rate_limits.five_hour.used_percentage | pct) end,
        if .rate_limits.seven_day.used_percentage == null then empty else "7d " + (.rate_limits.seven_day.used_percentage | pct) end] | join(" ")),
      (if .workspace.git_worktree != null then .workspace.git_worktree
       elif .workspace.project_dir != null then (.workspace.project_dir | split("/") | last)
       else "" end)
    ] | map(tostring) | join("\u001f")' 2>/dev/null) || parts=
  IFS=$'\037' read -r model effort limits wt <<< "$parts"
  model=$(fm_sb_clean "$model" 24)
  effort=$(fm_sb_clean "$effort" 8)
  limits=$(fm_sb_clean "$limits" 20)
  wt=$(fm_sb_clean "$wt" 24)
  out="${model:-?} ${effort:-?} | $(fm_sb_clean "$task" 32)"
  [ -z "$wt" ] || out="$out | $wt"
  [ -z "$limits" ] || out="$out | $limits"
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
    tmux set-option -g status-left '' &&
    tmux set-option -g status-right-length 200 &&
    tmux set-option -g status-right '#{E:pane-border-format}' &&
    tmux set-window-option -g window-status-format ' #I:#W ' &&
    tmux set-window-option -g window-status-current-format ' #I:#W ' &&
    tmux set-window-option -g window-status-current-style 'bg=colour24,fg=colour255,bold' &&
    tmux set-window-option -g pane-border-format "$(fm_sb_format)"
}

sub=${1:-}
[ $# -eq 0 ] || shift
case "$sub" in
theme) cmd_theme ;;
install|check) cmd_config "$sub" "$@" ;;
source-line) fm_sb_source_line ;;
label) cmd_label "$@" ;;
apply) cmd_apply "$@" ;;
sync) cmd_sync ;;
usage) cmd_usage "$@" ;;
claude-line) cmd_claude_line "$@" ;;
*)
  echo "usage: fm-statusbar.sh label|sync|apply|usage|claude-line|theme|install|check|source-line" >&2
  exit 2
  ;;
esac
