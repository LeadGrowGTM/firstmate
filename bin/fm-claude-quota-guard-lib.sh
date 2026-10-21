#!/usr/bin/env bash
# Decide whether one fresh Claude ship or scout launch may spend the
# subscription. bin/fm-claude-quota-guard.sh is the command tests and
# bin/fm-spawn.sh call. docs/configuration.md "Claude quota guard" owns the
# config file. This file owns the decision: read quota-axi, refuse Opus for
# configured task types, reroute when weekly usage is ahead of the window, and
# defer when this home is already at its Claude worker cap.
#
# An absent config file turns the guard on with the built-in defaults. The
# subscription was spent while no file existed, so a file that must be created
# before anything is protected would leave that hole open.
#
# Missing quota evidence never refuses a launch. The command prints one gap
# line and continues with the Opus-type and concurrency checks, which do not
# need a usage reading. A malformed config file or an unreadable task record
# refuses the launch instead of guessing.

# Built-in defaults. A present key replaces that default.
FM_CQG_DEFAULT_MARGIN=10
FM_CQG_DEFAULT_CAP=4
FM_CQG_DEFAULT_WINDOW=604800
FM_CQG_DEFAULT_TYPES=$'writing\nexecution\ncopy-draft\nlist-build\nbison-launch'

# Stable supervisor lines. The text is the retry identity: a later attempt for
# the same launch appends nothing when this line is already in the status file.
# bin/fm-classify-lib.sh status_event_recorded owns that comparison.
FM_CQG_PACE_STATUS='working [key=claude-quota-pace]: claude weekly usage is ahead of the window, so this launch was routed off the requested claude model'
FM_CQG_CAP_STATUS='paused [key=claude-quota-cap]: claude worker cap deferred this launch'
FM_CQG_ROUTE_STATUS='paused [key=claude-quota-route]: claude weekly usage is ahead of the window, and the selected dispatch rule allows no alternate worker, so this launch was deferred'

# Same deferral as project capacity, so a batch keeps the item queued.
FM_CQG_DEFER_EXIT=75

fm_cqg_die() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# fm_cqg_load <config-dir>
# Sets FM_CQG_MARGIN, FM_CQG_CAP, FM_CQG_WINDOW, and FM_CQG_TYPES. Returns 1 when the file is present and
# unusable. An absent file keeps the defaults and returns 0.
fm_cqg_load() {
  local dir=$1 file
  FM_CQG_MARGIN=$FM_CQG_DEFAULT_MARGIN
  FM_CQG_CAP=$FM_CQG_DEFAULT_CAP
  FM_CQG_WINDOW=$FM_CQG_DEFAULT_WINDOW
  FM_CQG_TYPES=$FM_CQG_DEFAULT_TYPES
  file=$dir/claude-quota-guard.json
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    fm_cqg_die "config/claude-quota-guard.json must be a readable regular file"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_cqg_die "config/claude-quota-guard.json cannot be read because jq is not installed"
    return 1
  fi
  local parsed
  if ! parsed=$(jq -ces '
    def num: type == "number" and (isinfinite | not) and (isnan | not);
    def whole: num and . == floor;
    if length != 1 then error("expected one JSON object") else .[0] end |
    if type != "object" then error("expected a JSON object")
    elif (keys - ["pace_margin_points","concurrent_claude_cap","weekly_window_seconds","opus_refused_types"]) != []
      then error("unknown key")
    else
      {
        margin: (if has("pace_margin_points") then (if (.pace_margin_points | num) and .pace_margin_points >= 0 then .pace_margin_points else error("pace_margin_points") end) else 10 end),
        cap: (if has("concurrent_claude_cap") then (if (.concurrent_claude_cap | whole) and .concurrent_claude_cap >= 1 then .concurrent_claude_cap else error("concurrent_claude_cap") end)
              else 4 end),
        window: (if has("weekly_window_seconds") then (if (.weekly_window_seconds | whole) and .weekly_window_seconds >= 1 then .weekly_window_seconds else error("weekly_window_seconds") end) else 604800 end),
        types_set: has("opus_refused_types"),
        types: (if has("opus_refused_types") then
                  (if (.opus_refused_types | type) == "array" and (.opus_refused_types | length) > 0
                     and all(.opus_refused_types[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
                   then .opus_refused_types else error("opus_refused_types") end)
                else ["writing","execution","copy-draft","list-build","bison-launch"] end)
      }
    end
  ' "$file" 2>/dev/null); then
    fm_cqg_die "config/claude-quota-guard.json is malformed; see docs/configuration.md \"Claude quota guard\""
    return 1
  fi
  FM_CQG_MARGIN=$(jq -r '.margin' <<<"$parsed")
  FM_CQG_CAP=$(jq -r '.cap' <<<"$parsed")
  FM_CQG_WINDOW=$(jq -r '.window' <<<"$parsed")
  if [ "$(jq -r '.types_set' <<<"$parsed")" = true ]; then
    FM_CQG_TYPES=$(jq -r '.types[]' <<<"$parsed")
  fi
}

# fm_cqg_task_type <brief>
# Prints the Name: value from the brief's Task type section, or nothing when
# the brief or the section is absent. A missing brief is an untyped launch.
fm_cqg_task_type() {
  local brief=$1 body line value
  [ -f "${brief:-}" ] || return 0
  body=$(fm_brief_task_heading_body "$brief" "## Task type") || true
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'Name: '*)
        value=${line#'Name: '}
        value=${value%%[[:space:]]*}
        printf '%s' "$value"
        return 0
        ;;
    esac
  done <<<"$body"
}

# True when the requested model is an Opus model. Empty and "default" are not.
fm_cqg_model_is_opus() {
  local model=${1,,}
  case "$model" in
    '' | default) return 1 ;;
    *opus*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_cqg_type_refused() {
  local want=$1 one
  [ -n "$want" ] || return 1
  while IFS= read -r one || [ -n "$one" ]; do
    [ -n "$one" ] || continue
    [ "$one" = "$want" ] && return 0
  done <<<"$FM_CQG_TYPES"
  return 1
}

fm_cqg_iso_epoch() {
  local raw=$1 base
  case "$raw" in
    *.*)
      base=${raw%%.*}
      case "$raw" in
        *Z) case "$base" in *Z) ;; *) base=${base}Z ;; esac ;;
      esac
      raw=$base
      ;;
  esac
  date -u -d "$raw" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$raw" +%s 2>/dev/null
}

# fm_cqg_toon_weekly <toon-text>
# Prints remaining, limitedBy, and resetsAt for the tightest Claude all_models
# row, separated by tabs. Prints nothing when that row is absent.
fm_cqg_toon_weekly() {
  awk '
    function split_csv(line, out,    i, n, c, q, cur) {
      n = 0
      q = 0
      cur = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") {
          q = !q
          continue
        }
        if (c == "," && !q) {
          out[++n] = cur
          cur = ""
          continue
        }
        cur = cur c
      }
      out[++n] = cur
      return n
    }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN { count = -1; k = 0 }
    {
      line = trim($0)
      if (count < 0 && line ~ /^quota\[[0-9]+\]\{/) {
        if (index(line, "{provider,accountKey,") > 0) k = 1
        header = line
        sub(/^quota\[/, "", header)
        sub(/\].*/, "", header)
        count = header + 0
        next
      }
      if (count > 0 && seen < count) {
        seen++
        n = split_csv(line, f)
        provider = f[1]
        scope = f[2 + k]
        remaining = f[3 + k]
        limited = f[7 + k]
        reset = f[8 + k]
        if (provider == "claude" && scope == "all_models" && remaining ~ /^-?[0-9]+(\.[0-9]+)?$/) {
          if (!picked || remaining + 0 < best + 0) {
            picked = 1
            best = remaining + 0
            best_limited = limited
            best_reset = reset
          }
        }
      }
    }
    END {
      if (picked) printf "%s\t%s\t%s\n", best, best_limited, best_reset
    }
  ' <<<"$1"
}

# fm_cqg_json_weekly <json>
# Prints percentRemaining and resetsAt for the tightest Claude seven_day
# window, or a weekly-kind window when seven_day is absent.
fm_cqg_json_weekly() {
  jq -r '
    def rows(which):
      [.providers[]? | select(.provider == "claude") | .windows[]?
        | select(which)
        | select(.percentRemaining | type == "number")
        | select(.resetsAt | type == "string")
        | {rem: .percentRemaining, reset: .resetsAt}];
    (rows(.id == "seven_day")) as $named
    | (if ($named | length) > 0 then $named else rows(.kind == "weekly") end)
    | min_by(.rem) // empty
    | if . == null then "" else "\(.rem)\t\(.reset)" end
  ' <<<"$1" 2>/dev/null || true
}

# fm_cqg_read_weekly
# Prints "remaining<TAB>resetsAt" for the Claude weekly window, or nothing
# when quota-axi cannot report it. Never returns a hard failure for missing
# data. Callers treat an empty print as the gap: this function runs inside a
# command substitution, so a flag set here would not reach them.
fm_cqg_read_weekly() {
  local toon rc=0 row limited rem reset json
  if ! command -v quota-axi >/dev/null 2>&1; then
    return 0
  fi
  toon=$(fm_run_timed 20 quota-axi --provider claude --no-credential-refresh 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$toon" ]; then
    return 0
  fi
  row=$(fm_cqg_toon_weekly "$toon") || true
  if [ -n "$row" ]; then
    rem=${row%%$'\t'*}
    limited=${row#*$'\t'}
    limited=${limited%%$'\t'*}
    reset=${row##*$'\t'}
    case "$limited" in
      seven_day | weekly)
        printf '%s\t%s\n' "$rem" "$reset"
        return 0
        ;;
    esac
  fi
  rc=0
  json=$(fm_run_timed 20 quota-axi --provider claude --json --no-credential-refresh 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    return 0
  fi
  row=$(fm_cqg_json_weekly "$json") || true
  if [ -z "$row" ]; then
    return 0
  fi
  printf '%s\n' "$row"
}

# fm_cqg_ahead <percent-remaining> <resetsAt>
# Prints how many points used-percent is ahead of elapsed-percent. Returns 2
# when the window cannot be placed on the clock.
fm_cqg_ahead() {
  local rem=$1 reset=$2 now epoch remain ahead
  now=$(date +%s) || return 2
  epoch=$(fm_cqg_iso_epoch "$reset") || return 2
  remain=$((epoch - now))
  [ "$remain" -ge 0 ] || return 2
  ahead=$(awk -v rem="$rem" -v remain="$remain" -v window="$FM_CQG_WINDOW" 'BEGIN {
    if (window + 0 <= 0) exit 2
    if (rem + 0 < 0 || rem + 0 > 100) exit 2
    used = 100 - (rem + 0)
    elapsed = (window - remain) / window * 100
    printf "%.6f\n", used - elapsed
  }') || return 2
  printf '%s\n' "$ahead"
}

fm_cqg_ahead_of_margin() {
  awk -v ahead="$1" -v margin="$FM_CQG_MARGIN" 'BEGIN { exit !(ahead + 0 > margin + 0) }'
}

# First allowed, installed preference. Client data never selects grok.
# bin/fm-muse-client-lib.sh owns that decision. Sonnet needs no extra binary
# because the launch is already Claude.
fm_cqg_pick_route() {
  local home=$1 brief=$2 config=$3 rule=$4 model=${5:-default} effort=${6:-default} plan=$7 profiles='' choice selection source='' tried='[]'
  # An empty launch model is the dispatch checker's "default". FM_CQG_TRIED is
  # this scheduled episode's already-tried profiles; a repeated destination is skipped.
  if [ -n "${FM_CQG_TRIED:-}" ]; then
    tried=$(jq -ce 'if type == "array" and all(.[]; type == "object") then . else empty end' <<<"${FM_CQG_TRIED}") || return 2
  fi
  if [ -n "$plan" ]; then
    profiles=$(jq -ces 'if length != 1 then error("expected one scheduled plan") else .[0] end | select(.authorized == true and (.profiles | type) == "array" and (.profiles | length) > 0) | .profiles' "$plan" 2>/dev/null) || return 1
  elif [ -f "$config/crew-dispatch.json" ]; then
    selection=$(jq -ce --arg rule "$rule" --arg model "$model" --arg effort "$effort" '
      def profiles: if type == "array" then . else [.] end;
      (if $rule != "" then ($rule | fromjson) else null end) as $selected |
      ([.rules // [] | to_entries[] | {key:{rule:("rule_" + ((.key + 1) | tostring))}, items:(.value.use | profiles)}]
       + (if has("default") then [{key:{default:true}, items:(.default | profiles)}] else [] end)) |
      if $selected != null then map(select(.key == $selected))
      else map(select(any(.items[]; .harness == "claude" and (.model // "default") == $model and (.effort // "default") == $effort))) end |
      if length != 1 then error("selected dispatch rule is unavailable") else .[0] end
    ' "$config/crew-dispatch.json" 2>/dev/null) || return 1
    profiles=$(jq -c '.items' <<<"$selection") || return 1
    source=$(jq -c '.key' <<<"$selection") || return 1
  fi
  if [ -n "$profiles" ]; then
    profiles=$(jq -c --argjson tried "$tried" '
      [.[] | . as $profile | select(any($tried[];
        .harness == $profile.harness and
        (.model // "default") == ($profile.model // "default") and
        (.effort // "default") == ($profile.effort // "default")) | not)]
    ' <<<"$profiles") || return 1
    if ! fm_muse_carries_client_data "$home" "$brief" && command -v grok >/dev/null 2>&1; then
      choice=$(jq -r '[.[] | select(.harness == "grok")] | if length == 0 then empty else .[0] | [.harness, (.model // "default"), (.effort // "default")] | @tsv end' <<<"$profiles")
      [ -z "$choice" ] || { printf '%s\t%s\n' "$choice" "$source"; return 0; }
    fi
    if command -v muse >/dev/null 2>&1; then
      choice=$(jq -r '[.[] | select(.harness == "muse")] | if length == 0 then empty else .[0] | [.harness, (.model // "default"), (.effort // "default")] | @tsv end' <<<"$profiles")
      [ -z "$choice" ] || { printf '%s\t%s\n' "$choice" "$source"; return 0; }
    fi
    choice=$(jq -r '[.[] | select(.harness == "claude" and ((.model // "") | ascii_downcase | contains("sonnet")))] | if length == 0 then empty else .[0] | [.harness, .model, (.effort // "default")] | @tsv end' <<<"$profiles")
    [ -z "$choice" ] || { printf '%s\t%s\n' "$choice" "$source"; return 0; }
    return 1
  fi
  if ! fm_muse_carries_client_data "$home" "$brief" && command -v grok >/dev/null 2>&1; then
    printf 'grok\t\t\t\n'
    return 0
  fi
  if command -v muse >/dev/null 2>&1; then
    printf 'muse\t\t\t\n'
    return 0
  fi
  printf 'claude\tsonnet\t\t\n'
}

# fm_cqg_count <state-dir> <self-id>
# Sets FM_CQG_OCCUPANTS to Claude ship/scout records in this home whose
# recorded endpoint has not been proven dead. Returns 1 when a record cannot be read.
fm_cqg_count() {
  local state=$1 self=$2 list f id harness kind backend target socket alive proof spawn_pid spawn_identity current_identity reserved
  FM_CQG_OCCUPANTS=0
  if [ ! -d "$state" ] || [ ! -r "$state" ]; then
    fm_cqg_die "cannot count Claude workers because the state directory is unreadable"
    return 1
  fi
  if ! list=$(find "$state" -maxdepth 1 \( -type f -o -type l \) -name '*.meta' -print); then
    fm_cqg_die "cannot count Claude workers because the state directory is unreadable"
    return 1
  fi
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    if [ ! -r "$f" ]; then
      fm_cqg_die "cannot count Claude workers because a task record is unreadable"
      return 1
    fi
    id=$(basename "$f" .meta)
    [ "$id" = "$self" ] && continue
    harness=$(fm_meta_get "$f" harness)
    [ "$harness" = claude ] || continue
    kind=$(fm_meta_get "$f" kind)
    case "$kind" in
      '' | ship | scout) ;;
      *) continue ;;
    esac
    spawn_pid=$(fm_meta_get "$f" quota_spawn_pid)
    spawn_identity=$(fm_meta_get "$f" quota_spawn_identity)
    reserved=0
    if grep -qE '^quota_spawn_(pid|identity)=' "$f"; then
      reserved=1
      case "$spawn_pid" in
        ''|0*|*[!0-9]*) fm_cqg_die "cannot count Claude workers because a launch reservation is malformed"; return 1 ;;
      esac
      if [ -z "$spawn_identity" ] || [ "${#spawn_pid}" -gt 12 ] ||
        [ "$(grep -c '^quota_spawn_pid=' "$f")" != 1 ] ||
        [ "$(grep -c '^quota_spawn_identity=' "$f")" != 1 ]; then
        fm_cqg_die "cannot count Claude workers because a launch reservation is malformed"
        return 1
      fi
      if fm_pid_alive "$spawn_pid" &&
        current_identity=$(fm_pid_identity "$spawn_pid" 2>/dev/null) &&
        [ "$current_identity" = "$spawn_identity" ]; then
        FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1))
        continue
      fi
    fi
    backend=$(fm_backend_of_meta "$f")
    target=$(fm_backend_target_of_meta "$f")
    socket=$(fm_meta_get "$f" tmux_socket)
    if [ "$backend" = tmux ] && grep -q '^tmux_socket=' "$f"; then
      alive=$(fm_backend_agent_state "$backend" "$target" "$socket")
    else
      alive=$(fm_backend_agent_state "$backend" "$target")
    fi
    case "$alive" in
      dead) continue ;;
      alive) FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1)); continue ;;
    esac
    [ "$reserved" = 0 ] || continue
    case "$alive" in
      missing)
        proof=$(fm_control_endpoint_absence_verdict "$backend" "$target" "$f")
        case "${proof%%$'\t'*}" in gone|dead) continue ;; esac
        ;;
    esac
    FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1))
  done <<<"$list"
}

fm_cqg_status_once() {
  local state=$1 id=$2 line=$3 file stamped
  [ "${FM_CQG_APPLY_STATUS:-0}" = 1 ] || return 0
  file=$state/$id.status
  if status_event_recorded "$file" "$line"; then
    return 0
  fi
  stamped=$(status_stamp_line "$line") || return 1
  printf '%s\n' "$stamped" >>"$file"
}

fm_cqg_write_verdict() {
  local path=$1 action=$2 harness=$3 model=$4 effort=${5:-} rule=${6:-}
  printf 'action=%s\nharness=%s\nmodel=%s\neffort=%s\n' "$action" "$harness" "$model" "$effort" >"$path" || return 1
  [ -z "$rule" ] || printf 'rule=%s\n' "$rule" >>"$path"
}

# fm_cqg_decide <config-dir> <state-dir> <home> <id> <brief> <model> <verdict>
# Exit 0 proceed or reroute, 1 refuse or bad config or unreadable records,
# 75 defer. Notices on stdout. Refusals and deferrals on stderr.
fm_cqg_decide() {
  local config=$1 state=$2 home=$3 id=$4 brief=$5 model=$6 verdict=$7
  local weekly rem reset ahead route route_model route_effort route_rule type_name route_rc
  if ! fm_cqg_load "$config"; then
    return 1
  fi
  if [ "${FM_CQG_REFUSAL_ONLY:-0}" = 1 ]; then
    if fm_cqg_model_is_opus "$model"; then
      type_name=$(fm_cqg_task_type "$brief") || true
      if fm_cqg_type_refused "$type_name"; then
        printf 'refused: Opus is not allowed for task type %s; task %s was not launched\n' "$type_name" "$id" >&2
        return 1
      fi
    fi
    fm_cqg_write_verdict "$verdict" proceed claude "$model"
    return 0
  fi
  weekly=$(fm_cqg_read_weekly) || weekly=
  route=
  if [ -z "$weekly" ]; then
    printf '%s\n' "claude-quota-guard: quota-axi could not report Claude weekly usage; this launch continues without a pace check"
  else
    rem=${weekly%%$'\t'*}
    reset=${weekly#*$'\t'}
    ahead=$(fm_cqg_ahead "$rem" "$reset") || ahead=
    if [ -z "$ahead" ]; then
      printf '%s\n' "claude-quota-guard: quota-axi could not report Claude weekly usage; this launch continues without a pace check"
    elif fm_cqg_ahead_of_margin "$ahead"; then
      route_rc=0
      route=$(fm_cqg_pick_route "$home" "$brief" "$config" "${FM_CQG_DISPATCH_RULE:-}" "$model" "${FM_CQG_EFFORT:-default}" "${FM_CQG_SCHEDULED_PLAN:-}") || route_rc=$?
      if [ "$route_rc" -eq 2 ]; then
        fm_cqg_die "scheduled tried profiles could not be read"
        return 1
      fi
      if [ "$route_rc" -ne 0 ]; then
        fm_cqg_status_once "$state" "$id" "$FM_CQG_ROUTE_STATUS" || return 1
        printf 'deferred: selected dispatch rule allows no alternate worker for task %s\n' "$id" >&2
        return "$FM_CQG_DEFER_EXIT"
      fi
    fi
  fi
  if [ -z "$route" ] && fm_cqg_model_is_opus "$model"; then
    type_name=$(fm_cqg_task_type "$brief") || true
    if fm_cqg_type_refused "$type_name"; then
      printf 'refused: Opus is not allowed for task type %s; task %s was not launched\n' "$type_name" "$id" >&2
      return 1
    fi
  fi
  route_rule=${route##*$'\t'}
  route=${route%$'\t'*}
  route_model=${route#*$'\t'}
  route_effort=${route_model#*$'\t'}
  route_model=${route_model%%$'\t'*}
  route=${route%%$'\t'*}
  if [ "$route" = grok ] || [ "$route" = muse ]; then
    fm_cqg_status_once "$state" "$id" "$FM_CQG_PACE_STATUS" || return 1
    printf 'claude-quota-guard: weekly usage is ahead of the window; routing this launch to %s\n' "$route"
    fm_cqg_write_verdict "$verdict" reroute "$route" "$route_model" "$route_effort" "$route_rule"
    return 0
  fi
  if ! fm_cqg_count "$state" "$id"; then
    return 1
  fi
  if [ "$FM_CQG_OCCUPANTS" -ge "$FM_CQG_CAP" ]; then
      fm_cqg_status_once "$state" "$id" "$FM_CQG_CAP_STATUS" || return 1
      printf 'deferred: this home already holds %s Claude worker(s) and the cap is %s; task %s was not launched and its backlog item stays queued\n' \
        "$FM_CQG_OCCUPANTS" "$FM_CQG_CAP" "$id" >&2
      return "$FM_CQG_DEFER_EXIT"
  fi
  if [ "$route" = claude ]; then
    fm_cqg_status_once "$state" "$id" "$FM_CQG_PACE_STATUS" || return 1
    printf '%s\n' "claude-quota-guard: weekly usage is ahead of the window; routing this launch to claude sonnet"
    fm_cqg_write_verdict "$verdict" reroute claude "$route_model" "$route_effort" "$route_rule"
    return 0
  fi
  fm_cqg_write_verdict "$verdict" proceed claude "$model"
  return 0
}
