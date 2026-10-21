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
# Env-wrapped and compound raw Claude launches, quoted command names, and quoted or escaped leading assignments are not guarded.

# Built-in policy values. Supported config keys can override margin, cap, and types.
FM_CQG_DEFAULT_MARGIN=10
FM_CQG_DEFAULT_CAP=4
FM_CQG_STARTUP_GRACE=90
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
# Sets FM_CQG_MARGIN, FM_CQG_CAP, and FM_CQG_TYPES. Returns 1 when the file is present and
# unusable. An absent file keeps the defaults and returns 0.
fm_cqg_load() {
  local dir=$1 file
  FM_CQG_MARGIN=$FM_CQG_DEFAULT_MARGIN
  FM_CQG_CAP=$FM_CQG_DEFAULT_CAP
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
    elif (keys - ["pace_margin_points","concurrent_claude_cap","opus_refused_types"]) != []
      then error("unknown key")
    else
      {
        margin: (if has("pace_margin_points") then (if (.pace_margin_points | num) and .pace_margin_points >= 0 then .pace_margin_points else error("pace_margin_points") end) else 10 end),
        cap: (if has("concurrent_claude_cap") then (if (.concurrent_claude_cap | whole) and .concurrent_claude_cap >= 1 then .concurrent_claude_cap else error("concurrent_claude_cap") end)
              else 4 end),
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

# fm_cqg_json_weekly <json>
# Prints percentRemaining, resetsAt, and windowSeconds for the tightest Claude seven_day
# window, or a weekly-kind window when seven_day is absent.
fm_cqg_json_weekly() {
  jq -r '
    def rows(which):
      [.providers[]? | select(.provider == "claude" and .state.stale != true) | .windows[]?
        | select(which)
        | select(.percentRemaining | type == "number")];
    (rows(.id == "seven_day")) as $named
    | (if ($named | length) > 0 then $named else rows(.kind == "weekly") end)
    | min_by(.percentRemaining) // empty
    | select(.resetsAt | type == "string")
    | if (.windowSeconds | type) == "number"
        and .windowSeconds > 0
        and (.windowSeconds | isinfinite | not)
        and (.windowSeconds | isnan | not)
      then "\(.percentRemaining)\t\(.resetsAt)\t\(.windowSeconds)"
      elif .id == "seven_day" and (has("windowSeconds") | not)
      then "\(.percentRemaining)\t\(.resetsAt)\t604800"
      else empty end
  ' <<<"$1" 2>/dev/null || true
}

# fm_cqg_read_weekly
# Prints "remaining<TAB>resetsAt<TAB>windowSeconds" for the Claude weekly window, or nothing
# when quota-axi cannot report it. Never returns a hard failure for missing
# data. Callers treat an empty print as the gap: this function runs inside a
# command substitution, so a flag set here would not reach them.
fm_cqg_read_weekly() {
  local json rc=0 row
  local -a quota_env=() quota_args=(--provider claude)
  if ! command -v quota-axi >/dev/null 2>&1; then
    return 0
  fi
  # quota-axi rejects --profile-only unless a credential directory is set.
  # An ordinary pin unsets that directory and uses the default reading.
  if [ "${FM_CQG_PROFILE_SELECTED:-0}" = 1 ]; then
    if [ -n "$FM_CQG_PROFILE_DIR" ]; then
      quota_env=(env "CLAUDE_CONFIG_DIR=$FM_CQG_PROFILE_DIR")
      quota_args+=(--profile-only)
    else
      quota_env=(env -u CLAUDE_CONFIG_DIR)
    fi
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    quota_args+=(--profile-only)
  fi
  json=$(fm_run_timed 20 "${quota_env[@]}" quota-axi "${quota_args[@]}" --json --no-credential-refresh 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    return 0
  fi
  row=$(fm_cqg_json_weekly "$json") || true
  if [ -z "$row" ]; then
    return 0
  fi
  printf '%s\n' "$row"
}

# fm_cqg_ahead <percent-remaining> <resetsAt> <windowSeconds>
# Prints how many points used-percent is ahead of elapsed-percent. Returns 2
# when the window cannot be placed on the clock.
fm_cqg_ahead() {
  local rem=$1 reset=$2 window=$3 now epoch remain ahead
  now=$(date +%s) || return 2
  epoch=$(fm_cqg_iso_epoch "$reset") || return 2
  remain=$((epoch - now))
  [ "$remain" -ge 0 ] || return 2
  ahead=$(awk -v rem="$rem" -v remain="$remain" -v window="$window" 'BEGIN {
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
# Return 0 and print harness, model, effort, and rule, tab-separated.
# Return 1 when a successfully read rule has no remaining alternate.
# Return 2 when FM_CQG_TRIED cannot be read.
# Return 3 after naming a dispatch configuration error on stderr.
fm_cqg_pick_route() {
  local home=$1 brief=$2 config=$3 rule=$4 model=${5:-default} effort=${6:-default} plan=$7 profiles='' choice selection source='' tried='[]' route_err=''
  # An empty launch model is the dispatch checker's "default". FM_CQG_TRIED is
  # this scheduled episode's already-tried profiles; a repeated destination is skipped.
  if [ -n "${FM_CQG_TRIED:-}" ]; then
    tried=$(jq -ce 'if type == "array" and all(.[]; type == "object") then . else empty end' <<<"${FM_CQG_TRIED}") || return 2
  fi
  if [ -n "$plan" ]; then
    route_err=$(mktemp "${TMPDIR:-/tmp}/fm-cqg-route.XXXXXX") || {
      fm_cqg_die "scheduled plan could not be read"
      return 3
    }
    if ! profiles=$(jq -ces 'if length != 1 then error("expected one scheduled plan") else .[0] end | select(.authorized == true and (.profiles | type) == "array" and (.profiles | length) > 0) | .profiles' "$plan" 2>"$route_err"); then
      if [ -s "$route_err" ]; then
        rm -f "$route_err"
        fm_cqg_die "scheduled plan could not be read"
        return 3
      fi
      rm -f "$route_err"
      return 1
    fi
    rm -f "$route_err"
  elif [ -f "$config/crew-dispatch.json" ]; then
    route_err=$(mktemp "${TMPDIR:-/tmp}/fm-cqg-route.XXXXXX") || {
      fm_cqg_die "config/crew-dispatch.json could not be read"
      return 3
    }
    if ! selection=$(jq -ce --arg rule "$rule" --arg model "$model" --arg effort "$effort" '
      def profiles: if type == "array" then . else [.] end;
      (if $rule != "" then ($rule | fromjson) else null end) as $selected |
      ([.rules // [] | to_entries[] | {key:{rule:("rule_" + ((.key + 1) | tostring))}, items:(.value.use | profiles)}]
       + (if has("default") then [{key:{default:true}, items:(.default | profiles)}] else [] end)) |
      if $selected != null then map(select(.key == $selected))
      else map(select(any(.items[]; .harness == "claude" and (.model // "default") == $model and (.effort // "default") == $effort))) end |
      if length != 1 then error("selected dispatch rule is unavailable") else .[0] end
    ' "$config/crew-dispatch.json" 2>"$route_err"); then
      if grep -F -q 'selected dispatch rule is unavailable' "$route_err"; then
        rm -f "$route_err"
        fm_cqg_die "config/crew-dispatch.json: selected dispatch rule is unavailable"
        return 3
      fi
      rm -f "$route_err"
      fm_cqg_die "config/crew-dispatch.json is malformed"
      return 3
    fi
    rm -f "$route_err"
    profiles=$(jq -c '.items' <<<"$selection") || {
      fm_cqg_die "config/crew-dispatch.json is malformed"
      return 3
    }
    source=$(jq -c '.key' <<<"$selection") || {
      fm_cqg_die "config/crew-dispatch.json is malformed"
      return 3
    }
  fi
  if [ -n "$profiles" ]; then
    profiles=$(jq -c --argjson tried "$tried" '
      [.[] | . as $profile | select(any($tried[];
        .harness == $profile.harness and
        (.model // "default") == ($profile.model // "default") and
        (.effort // "default") == ($profile.effort // "default")) | not)]
    ' <<<"$profiles") || {
      fm_cqg_die "dispatch profiles could not be read"
      return 3
    }
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

fm_cqg_mark_observed() {
  local meta=$1 state=$2 spawn_gen=$3 spawn_pid=$4 spawn_identity=$5 lock='' staged='' observed_count result=0
  [ -n "$spawn_gen" ] || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_backlog_record_present "$meta" "task record" "$state" ||
    [ "$(fm_meta_get "$meta" spawn_gen)" != "$spawn_gen" ] ||
    [ "$(fm_meta_get "$meta" quota_spawn_pid)" != "$spawn_pid" ] ||
    [ "$(fm_meta_get "$meta" quota_spawn_identity)" != "$spawn_identity" ]; then
    result=1
  else
    observed_count=$(grep -c '^quota_agent_observed=' "$meta" || true)
    if [ "$observed_count" = 0 ]; then
      staged=$(mktemp "$state/.${meta##*/}.quota-observed.XXXXXX") || result=1
      if [ "$result" = 0 ] &&
        { ! awk -F= '$1 == "pr" && !inserted { print "quota_agent_observed=1"; inserted=1 } { print } END { if (!inserted) print "quota_agent_observed=1" }' "$meta" >"$staged" ||
          ! fm_backlog_atomic_transition publish "$staged" "$meta" "task record" "$state"; }; then
        result=1
      fi
    elif [ "$observed_count" != 1 ] || [ "$(fm_meta_get "$meta" quota_agent_observed)" != 1 ]; then
      result=1
    fi
  fi
  [ -z "$staged" ] || rm -f "$staged" 2>/dev/null || true
  fm_lock_release "$lock" || result=1
  return "$result"
}

# fm_cqg_count <state-dir> <self-id>
# Sets FM_CQG_OCCUPANTS to Claude ship/scout records in this home that still
# hold a seat. An unobserved dead endpoint keeps its seat during startup grace;
# docs/configuration.md owns the full seat-release rules. Returns 1 when a
# record cannot be read.
fm_cqg_count() {
  local state=$1 self=$2 list f id harness kind backend target socket alive proof spawn_pid spawn_identity spawn_gen spawn_epoch now current_identity reserved observed observed_count spawn_live
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
    observed=$(fm_meta_get "$f" quota_agent_observed)
    observed_count=$(grep -c '^quota_agent_observed=' "$f" || true)
    if { [ "$observed_count" != 0 ] && [ "$observed_count" != 1 ]; } ||
      { [ "$observed_count" = 1 ] && [ "$observed" != 1 ]; }; then
      fm_cqg_die "cannot count Claude workers because an agent observation is malformed"
      return 1
    fi
    spawn_pid=$(fm_meta_get "$f" quota_spawn_pid)
    spawn_identity=$(fm_meta_get "$f" quota_spawn_identity)
    reserved=0
    spawn_live=0
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
        spawn_live=1
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
    if [ "$alive" = missing ] && [ "$spawn_live" != 1 ]; then
      proof=$(fm_control_endpoint_absence_verdict "$backend" "$target" "$f")
      proof=${proof%%$'\t'*}
      case "$proof" in
        gone) continue ;;
        alive|dead) alive=$proof ;;
      esac
    fi
    case "$alive" in
      alive)
        if [ "$reserved" = 1 ] && [ "$observed_count" = 0 ]; then
          spawn_gen=$(fm_meta_get "$f" spawn_gen)
          if ! fm_cqg_mark_observed "$f" "$state" "$spawn_gen" "$spawn_pid" "$spawn_identity"; then
            fm_cqg_die "cannot count Claude workers because the agent observation could not be recorded"
            return 1
          fi
        fi
        FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1))
        continue
        ;;
    esac
    if [ "$spawn_live" = 1 ]; then
      FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1))
      continue
    fi
    if [ "$alive" = dead ]; then
      if [ "$observed_count" = 0 ]; then
        spawn_gen=$(fm_meta_get "$f" spawn_gen)
        if [[ $spawn_gen =~ ^s([1-9][0-9]{0,11})\.[0-9]+\.[0-9]+$ ]]; then
          spawn_epoch=${BASH_REMATCH[1]}
          now=$(date +%s)
          if [ "$now" -lt "$((spawn_epoch + FM_CQG_STARTUP_GRACE))" ]; then
            FM_CQG_OCCUPANTS=$((FM_CQG_OCCUPANTS + 1))
          fi
        fi
      fi
      continue
    fi
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
  local weekly rem reset window ahead route route_model route_effort route_rule type_name route_rc
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
    IFS=$'\t' read -r rem reset window <<<"$weekly"
    ahead=$(fm_cqg_ahead "$rem" "$reset" "$window") || ahead=
    if [ -z "$ahead" ]; then
      printf '%s\n' "claude-quota-guard: quota-axi could not report Claude weekly usage; this launch continues without a pace check"
    elif fm_cqg_ahead_of_margin "$ahead"; then
      route_rc=0
      route=$(fm_cqg_pick_route "$home" "$brief" "$config" "${FM_CQG_DISPATCH_RULE:-}" "$model" "${FM_CQG_EFFORT:-default}" "${FM_CQG_SCHEDULED_PLAN:-}") || route_rc=$?
      if [ "$route_rc" -eq 2 ]; then
        fm_cqg_die "scheduled tried profiles could not be read"
        return 1
      fi
      if [ "$route_rc" -eq 3 ]; then
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
  local count_lock=
  if [ "${FM_CQG_ADMISSION_LOCK_HELD:-0}" != 1 ]; then
    count_lock=$state/.claude-quota-guard.lock
    fm_lock_acquire_wait "$count_lock" || return 1
  fi
  if ! fm_cqg_count "$state" "$id"; then
    [ -z "$count_lock" ] || fm_lock_release "$count_lock" || true
    return 1
  fi
  [ -z "$count_lock" ] || fm_lock_release "$count_lock" || return 1
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
