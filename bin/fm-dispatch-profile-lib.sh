#!/usr/bin/env bash
# Concrete dispatch-policy guard shared by spawn and control's pre-stop check.
# fm_dispatch_profile_check <config-file> <prior-meta-or-empty> <harness>
#   <model> <effort> <rule-or-empty> <reason-or-empty> <scheduled-plan-or-empty>
# Returns a JSON receipt in FM_DISPATCH_PROFILE_RECEIPT; no writes or routing.
# docs/configuration.md "Crew dispatch profiles" owns the policy and schema.
# The rule argument is a JSON rule key.
# Rule identity and reasons are JSON-encoded in metadata to preserve newlines.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-quota-axi-lib.sh"

# Supported effort mapping shared by the guard, launch flags and receipt,
# including model-bound OpenCode variants and Rovo's config override.
# Unmapped axes realize default.
fm_dispatch_realized_effort() {
  local harness=$1 model=$2 effort=${3:-default}
  case "$harness:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max|\
    codex:low|codex:medium|codex:high|codex:xhigh|\
    grok:low|grok:medium|grok:high|agy:low|agy:medium|agy:high|\
    pi:low|pi:medium|pi:high|pi:xhigh|pi:max|\
    pi-signed:low|pi-signed:medium|pi-signed:high|pi-signed:xhigh|pi-signed:max|\
    omp:low|omp:medium|omp:high|omp:xhigh|omp:max|\
    muse:low|muse:medium|muse:high|muse:xhigh|muse:max|\
    rovo:low|rovo:medium|rovo:high|rovo:max) printf '%s' "$effort"; return ;;
    codex:max) [ "$model" != gpt-5.6-luna ] || { printf '%s' "$effort"; return; } ;;
    pi:ultra|pi-signed:ultra) case "$model" in codex-native/?*) printf '%s' "$effort"; return ;; esac ;;
    commandcode:low|commandcode:high|commandcode:max)
      case "$model" in deepseek/deepseek-v4.1-flash) printf '%s' "$effort"; return ;; esac ;;
    opencode:*) case "$model:$effort" in
      anthropic/*:high|anthropic/*:max|openai/*:low|openai/*:medium|openai/*:high|openai/*:xhigh) printf '%s' "$effort"; return ;;
    esac ;;
  esac
  printf default
}

fm_dispatch_rule_fingerprint() {
  local canonical hash
  canonical=$(jq -ceS --argjson source "$1" '
    def listed: if type == "array" then . elif type == "object" then [.] else empty end;
    if $source == {default:true} then
      if has("default") then ["default", (.default | listed)] else empty end
    elif ($source.rule | type) == "string" and ($source.rule | test("^rule_[1-9][0-9]*$")) then
      (.rules // [])[($source.rule | ltrimstr("rule_") | tonumber) - 1] |
      select(type == "object") | [.when, (.use | listed)]
    else empty end
  ') || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$canonical" | shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$canonical" | sha256sum) || return 1
  else
    echo 'error: SHA-256 tool is required for dispatch rule fingerprints' >&2
    return 1
  fi
  hash=${hash%% *}
  [[ $hash =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s' "$hash"
}

fm_dispatch_profile_check() {
  local config=$1 prior=$2 harness=$3 model=${4:-default} effort=${5:-default}
  local rule=$6 reason=$7 scheduled_plan=${8:-} scheduled=false
  local old_h='' old_m=default old_e=default source='' class='' prior_reason='' prior_fingerprint=''
  local config_snapshot='' has_config=false current_fingerprint='' selected_source='' task='' receipt
  FM_DISPATCH_PROFILE_RECEIPT='{}'
  if [ -n "$scheduled_plan" ]; then
    [ -f "$scheduled_plan" ] && [ ! -L "$scheduled_plan" ] || {
      echo "error: scheduled worker plan is unavailable: $scheduled_plan" >&2
      return 1
    }
    config=$scheduled_plan
    scheduled=true
  fi
  if [ -f "$config" ]; then
    config_snapshot=$(<"$config") || return 1
    has_config=true
  fi
  if [ -n "$prior" ]; then
    old_h=$(fm_meta_get "$prior" harness)
    old_m=$(fm_meta_get "$prior" model); old_m=${old_m:-default}
    old_e=$(fm_meta_get "$prior" effort); old_e=${old_e:-default}
    source=$(fm_meta_get "$prior" dispatch_rule)
    class=$(fm_meta_get "$prior" reasoning_class)
    prior_reason=$(fm_meta_get "$prior" fallback_reason)
    prior_fingerprint=$(fm_meta_get "$prior" dispatch_rule_fingerprint)
  fi
  local changed=0
  if [ -n "$prior" ] && { [ "$harness" != "$old_h" ] || [ "$model" != "$old_m" ] || [ "$effort" != "$old_e" ]; }; then
    changed=1
  fi
  if [ -n "$prior_fingerprint" ] && [ "$scheduled" = false ]; then
    task=$(fm_meta_get "$prior" endpoint_task_id)
    task=${task:-${prior##*/}}
    if [ -z "$source" ] || [ "$has_config" = false ] || ! current_fingerprint=$(fm_dispatch_rule_fingerprint "$source" <<< "$config_snapshot"); then
      echo "error: dispatch rule changed since launch for task $task; refusing relaunch" >&2
      return 1
    fi
    if [ "$current_fingerprint" != "$prior_fingerprint" ]; then
      echo "error: dispatch rule changed since launch for task $task; refusing relaunch" >&2
      return 1
    fi
  fi
  if [ "$has_config" = false ]; then
    if [ "$scheduled" = true ]; then
      echo "error: scheduled worker plan is unavailable: $config" >&2
      return 1
    fi
    if [ -n "$rule" ] || { [ "$changed" = 1 ] && [ -n "$source" ]; }; then
      echo "error: dispatch fallback requires the recorded rule in $config; no configuration is available" >&2
      return 1
    fi
    # Unconfigured manual replacements retain the existing control contract.
    FM_DISPATCH_PROFILE_RECEIPT=$(jq -cn --argjson source "${source:-null}" --arg class "$class" \
      --arg reason "$reason" --argjson prior_reason "${prior_reason:-null}" --argjson changed "$changed" \
      '{source:$source, class:$class, reason:(if $changed == 1 then (if $reason == "" then "explicit-profile-change" else $reason end) else ($prior_reason // (if $reason == "" then null else $reason end)) end)}') || return 1
    return 0
  fi
  receipt=$(jq -ce --argjson scheduled "$scheduled" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" --arg h "$harness" --arg m "$model" --arg e "$effort" \
    --arg oh "$old_h" --arg om "$old_m" --arg oe "$old_e" \
    --argjson source "${source:-null}" --arg old_class "$class" \
    --arg rule "$rule" --arg reason "$reason" --argjson prior_reason "${prior_reason:-null}" --argjson changed "$changed" '
    def profiles: if type == "array" then . elif type == "object" then [.] else error("profile set must be an object or non-empty array") end;
    def matches($h; $m; $e): .harness == $h and (.model // "default") == $m and (.effort // "default") == $e;
    def safe_provider: if (.provider | type) == "string" and (.provider | test($provider_re)) then .provider else "" end;
    (if $rule == "" then null else ($rule | fromjson) end) as $selected_rule |
    (if $scheduled then
      .reasoning_class as $plan_class |
      if type != "object" or .authorized != true or (.reasoning_class | type) != "string"
        or (.profiles | type) != "array" or (.profiles | length) == 0
        or any(.profiles[]; .reasoning_class != $plan_class)
      then error("invalid scheduled worker plan") else [{key:null,items:.profiles}] end
     else
      if type != "object" or ((.rules // []) | type) != "array" then error("malformed dispatch configuration") else . end |
      [(.rules // []) | to_entries[] | . as $entry | $entry.value |
        if type != "object" or (.when | type) != "string" or (.when | length) == 0 then error("rule needs when and use")
        else {key:{rule:("rule_" + (($entry.key + 1) | tostring))}, items:(.use | profiles)} end]
      + (if has("default") then [{key:{default:true},items:(.default | profiles)}] else [] end)
     end) as $groups |
    if any($groups[]; (.items | length) == 0) or any($groups[].items[];
      type != "object" or (.harness | type) != "string" or (.harness | length) == 0
      or (has("model") and ((.model | type) != "string" or (.model | length) == 0))
      or (has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
      or (has("reasoning_class") and ((.reasoning_class | type) != "string" or (.reasoning_class | test(if $scheduled then "^[A-Za-z0-9][A-Za-z0-9._/-]*\\z" else "^[A-Za-z0-9][A-Za-z0-9._-]*\\z" end)) == false)))
    then error("malformed dispatch profiles or reasoning_class") else . end |
    (if $source != null then [$groups[] | select(.key == $source)]
     elif $changed == 1 then [$groups[] | select(any(.items[]; matches($oh;$om;$oe)))]
     elif $rule != "" then [$groups[] | select(.key == $selected_rule)]
     else [$groups[] | select(any(.items[]; matches($h;$m;$e)))] end) as $sets |
    if ($sets | length) > 1 then error("ambiguous dispatch rule; select --dispatch-rule at intake")
    elif $changed == 1 and ($sets | length) != 1 then error("fallback has no uniquely recorded dispatch rule")
    elif $rule != "" and ($sets | length) != 1 then error("unknown dispatch rule")
    elif $scheduled and ($sets | length) == 0 then error("scheduled worker profile is not listed in the authorized plan")
    elif ($sets | length) == 0 then {source:$source,class:$old_class,reason:($prior_reason // ($reason | if . == "" then "explicit-profile" else . end))}
    else $sets[0] as $set |
      [$set.items[] | select(matches($h;$m;$e))] as $next |
      [$set.items[] | select(matches($oh;$om;$oe))] as $old |
      if ($next | length) > 1 or ($old | length) > 1 then error("duplicate dispatch profile")
      elif $changed == 1 and ($next | length) != 1 then error("fallback profile is not listed for the recorded dispatch rule")
      elif $rule != "" and ($next | length) != 1 then error("selected profile is not listed for --dispatch-rule")
      elif $changed == 0 then {source:$set.key,class:(if $old_class != "" then $old_class else ($next[0].reasoning_class // "") end),provider:($next[0] | safe_provider),reason:($prior_reason // ($reason | if . == "" then "resolved-profile" else . end))}
      elif $reason == "" then error("fallback requires --fallback-reason (control uses --note)")
      else (if $old_class != "" then $old_class else ($old[0].reasoning_class // "") end) as $required |
        ($next[0].reasoning_class // "") as $equivalent |
        if ($required != "" and $required == $equivalent)
          or ($h == $oh and $m == $om and $required == "" and $equivalent == ""
              and (["low","medium","high","xhigh","max","ultra"] | index($oe)) != null
              and (["low","medium","high","xhigh","max","ultra"] | index($e)) != null
              and (["low","medium","high","xhigh","max","ultra"] | index($e)) >= (["low","medium","high","xhigh","max","ultra"] | index($oe)))
        then {source:$set.key,class:$equivalent,provider:($next[0] | safe_provider),reason:$reason}
        else error("fallback would lower or change the recorded reasoning class; declare equivalent reasoning_class profiles in the same rule") end
      end
    end
  ' <<< "$config_snapshot") || return 1
  if [ "$scheduled" = false ]; then
    selected_source=$(jq -c '.source // empty' <<< "$receipt") || return 1
    if [ -n "$selected_source" ]; then
      if [ -z "$current_fingerprint" ] || [ "$selected_source" != "$source" ]; then
        current_fingerprint=$(fm_dispatch_rule_fingerprint "$selected_source" <<< "$config_snapshot") || {
          [ -n "$prior" ] && [ -z "$prior_fingerprint" ] || return 1
          current_fingerprint=''
        }
      fi
      if [ -n "$current_fingerprint" ]; then
        receipt=$(jq -c --arg fingerprint "$current_fingerprint" '. + {rule_fingerprint:$fingerprint}' <<< "$receipt") || return 1
      fi
    fi
  fi
  # shellcheck disable=SC2034 # Public receipt consumed by the sourcing caller.
  FM_DISPATCH_PROFILE_RECEIPT=$receipt
  if { [ "$changed" = 1 ] || [ "$(jq -r '.class // ""' <<< "$receipt")" != "" ]; } \
     && [ "$(fm_dispatch_realized_effort "$harness" "$model" "$effort")" != "$effort" ]; then
    echo "error: $harness cannot realize effort '$effort' for '$model'; refusing the configured reasoning class or fallback" >&2
    return 1
  fi
}
