# shellcheck shell=bash
# Shared local target collection for fm-targets.sh and fm-idle-sweep.sh.
# Usage: source bin/fm-targets-lib.sh after setting SCRIPT_DIR.
# docs/configuration.md owns config/targets.json and config/idle-sweep.json.
# All external reads are bounded; unavailable evidence is never a zero.

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

fm_targets_init() {
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-$FM_ROOT}"
  # Used by the sweep consumer, which shares this initialization.
  # shellcheck disable=SC2034
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
  TARGET_LIMITS='{"open_prs":4,"red_default_branches":0,"stale_backlog":0,"stale_days":14}'
  if [ -e "$CONFIG/targets.json" ]; then
    jq -se 'length == 1 and (.[0] | type == "object" and
      (keys - ["open_prs","red_default_branches","stale_backlog","stale_days"] | length == 0) and
      all(.[]; type == "number" and . >= 0 and . == floor) and
      ((.stale_days // 14) > 0))' "$CONFIG/targets.json" >/dev/null || return 1
    TARGET_LIMITS=$(jq -cn --argjson defaults "$TARGET_LIMITS" --slurpfile config "$CONFIG/targets.json" '$defaults + $config[0]') || return 1
  fi
}

fm_targets_backlog() {
  local backend
  backend=$(fm_tasks_axi_backend "$FM_HOME") || return 1
  [ "$backend" = markdown ] || { echo 'fm-targets: only the local markdown backlog is supported' >&2; return 1; }
  fm_run_timed 20 bash "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input
}

# Observe row content at heartbeats, including while work is live. Evaluators
# only read this ledger. First observation establishes a baseline, never age.
fm_targets_observe() {  # <canonical backlog JSON>
  local ledger='{}' tmp
  if [ -e "$STATE/idle-sweep-backlog.json" ]; then
    ledger=$(cat "$STATE/idle-sweep-backlog.json") || return 1
    printf '%s' "$ledger" | jq -e 'type == "object" and all(.[];
      (.content | type) == "string" and (.changed | type) == "number")' >/dev/null || return 1
  fi
  tmp=$(mktemp "$STATE/.idle-sweep-backlog.XXXXXX") || return 1
  if ! jq -n --argjson snapshot "$1" --argjson old "$ledger" --argjson now "$(date +%s)" '
    reduce ($snapshot.backlog.records[] | select(.structured)) as $r ({};
      ($r | [.raw,.body_lines] | tojson) as $content |
      .[$r.id] = {content:$content,changed:
        (if $old[$r.id].content == $content then $old[$r.id].changed else $now end)})
  ' > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if ! mv "$tmp" "$STATE/idle-sweep-backlog.json"; then
    rm -f "$tmp"; return 1
  fi
}

fm_targets_gh() {
  fm_run_timed 15 gh-axi api "$@"
}

# gh-axi renders string scalar API results in its api_response envelope;
# numeric projections are plain scalars. Refuse truncated or ambiguous output.
fm_targets_gh_string() {
  local output value
  output=$(fm_targets_gh "$@") || return 1
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = api_response: ] || return 1
  [ "$(printf '%s\n' "$output" | grep -c '^  body: ')" = 1 ] || return 1
  printf '%s\n' "$output" | grep -Fxq '  truncated: false' || return 1
  value=$(printf '%s\n' "$output" | sed -n 's/^  body: //p')
  case "$value" in
    \"*) printf '%s' "$value" | jq -er 'select(type == "string")' ;;
    '') return 1 ;;
    *) printf '%s\n' "$value" ;;
  esac
}

fm_targets_collect() {  # <canonical backlog JSON>
  local snapshot=$1 ledger='{}' repos='[]' dir remote repo identity info sha statuses checks count red row
  if [ -e "$STATE/idle-sweep-backlog.json" ]; then
    ledger=$(cat "$STATE/idle-sweep-backlog.json") || return 1
  fi
  # Read the authenticated login through the forge, never credential files.
  identity=$(fm_targets_gh_string user --jq .login 2>/dev/null) || identity=''
  for dir in "$PROJECTS"/*; do
    [ -d "$dir" ] || continue
    remote=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || remote=''
    repo=$(printf '%s\n' "$remote" | sed -nE 's#^(https://github.com/|git@github.com:)([^/]+/[^/]+)$#\2#p')
    repo=${repo%.git}
    count=null; red=null
    if [ -n "$repo" ] && [ -n "$identity" ]; then
      count=$(fm_targets_gh "search/issues?q=repo:$repo+is:pr+is:open+author:$identity" --jq .total_count 2>/dev/null) || count=null
      case "$count" in ''|*[!0-9]*) count=null ;; esac
      # jq variables in the query are evaluated by gh-axi.
      # shellcheck disable=SC2016
      if info=$(fm_targets_gh_string "repos/$repo" --jq .default_branch 2>/dev/null) &&
         sha=$(fm_targets_gh_string "repos/$repo/commits/$(printf '%s' "$info" | jq -sRr @uri)" --jq .sha 2>/dev/null) &&
         statuses=$(fm_targets_gh_string "repos/$repo/commits/$sha/status" --jq .state 2>/dev/null) &&
         checks=$(fm_targets_gh "repos/$repo/commits/$sha/check-runs?filter=latest&per_page=100" --paginate --jq '
           if (.check_runs | type) != "array" then error("invalid checks")
           elif any(.check_runs[]; .conclusion as $c | .status == "completed" and
             (["failure","timed_out","cancelled","action_required","startup_failure"] | index($c)) != null)
           then 1 else 0 end' 2>/dev/null); then
        case "$statuses" in
          success|pending|failure|error)
            red=$(printf '%s\n' "$checks" | jq -s --arg status "$statuses" '
                if length > 0 and all(.[]; . == 0 or . == 1) then
                  if $status == "failure" or $status == "error" or any(.[]; . == 1)
                  then 1 else 0 end
                else null end' 2>/dev/null) || red=null
            ;;
        esac
      fi
    fi
    row=$(jq -cn --arg project "${dir##*/}" --arg repo "$repo" --argjson open "$count" --argjson red "$red" '{project:$project,repo:$repo,open_prs:$open,red_default_branches:$red}') || return 1
    repos=$(jq -cn --argjson repos "$repos" --argjson row "$row" '$repos + [$row]') || return 1
  done
  jq -n --argjson snapshot "$snapshot" --argjson repos "$repos" --argjson ledger "$ledger" \
    --argjson limits "$TARGET_LIMITS" --argjson now "$(date +%s)" '
    def count_target($name):
      if any($repos[]; .[$name] == null) then null
      else ([$repos | unique_by(.repo)[] | .[$name]] | add // 0) end;
    [$snapshot.backlog.records[] | select(.structured and .state != "done") |
      . as $r | ($r | [.raw,.body_lines] | tojson) as $content |
      {id:.id, stale:(if $ledger[.id].content == $content and ($ledger[.id].changed | type) == "number"
        then ($now - $ledger[.id].changed >= $limits.stale_days * 86400) else null end)}] as $ages |
    {schema:"fm-targets.v1", repos:$repos, stale_ids:[$ages[] | select(.stale == true) | .id],
     targets:["red_default_branches","open_prs","stale_backlog"]} | .targets |= map(. as $name |
       (if $name == "stale_backlog" then
          if any($ages[]; .stale == null) then null else ([$ages[] | select(.stale)] | length) end
        else count_target($name) end) as $value |
       {id:$name,current:$value,limit:$limits[$name],gap:
         (if $value == null then null else ([$value - $limits[$name],0] | max) end)})
  '
}
