# shellcheck shell=bash
# Boat dispatch reservation read from config/boat-spend.json and config/boat-box-id.
# Usage: . bin/fm-boat-budget-lib.sh
#
# docs/configuration.md owns the spend-file schema. fm-boat-spend-check.sh owns
# the daily report. This file owns the sender's reservation defaults and the
# box-list read, so fm-boat-send.sh and fm-on.sh do not each invent a parser.
#
# An absent file, or an absent key, keeps the historical reservation:
#   below $20 (ceiling_usd 20 times the plan's 100000 credit seconds),
#   below 60000 account seconds per rolling 24 hours,
#   below a 43000 box-second sum (usage + timer reaching 43000 is refused),
#   and one listed box.
# A new resume reserves only the short on-demand timer (resume_ttl_seconds,
# 3600 when absent), never the whole plan timer. A present
# box_seconds_per_24h is a rolling-usage ceiling. The sender refuses
# when usage is already above it, so usage + the one timer being reserved may
# reach that ceiling plus that timer, including the equal sum.
# expected_running is the cap on listed ids and on active sandboxes.
# idle_grace_seconds is validated here so every reader agrees on it, and is
# otherwise owned by fm-boat-idle-check.sh. The file read is bounded to
# 65536 bytes, and the id file to at most 4096 bytes or expected_running
# times 12, whichever is smaller.

FM_BOAT_RENEW_TIMEOUT=$((25 + 6 + 6 + 4 + 5 + 6 + 60))

fm_boat_spend_config_path() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/boat-spend.json"
}

# Sets FM_BOAT_MONTHLY_USD, FM_BOAT_ACCOUNT_SECONDS, FM_BOAT_BOX_SECONDS,
# FM_BOAT_BOX_LEGACY (1 = historical sum, 0 = rolling-usage ceiling),
# FM_BOAT_MAX_BOXES, FM_BOAT_RESUME_TTL, FM_BOAT_IDLE_GRACE, and
# FM_BOAT_SPEND_PROBLEM when the file is unusable.
fm_boat_load_reservation() {
  FM_BOAT_MONTHLY_USD=20
  FM_BOAT_ACCOUNT_SECONDS=60000
  FM_BOAT_BOX_SECONDS=43000
  FM_BOAT_BOX_LEGACY=1
  FM_BOAT_MAX_BOXES=1
  FM_BOAT_RESUME_TTL=3600
  FM_BOAT_IDLE_GRACE=900
  FM_BOAT_SPEND_PROBLEM=
  local path out bin ceiling expected account boxsec ttl grace
  path=$(fm_boat_spend_config_path)
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || {
    FM_BOAT_SPEND_PROBLEM='unsafe config/boat-spend.json'
    return 1
  }
  [ "$(wc -c < "$path")" -le 65536 ] || {
    FM_BOAT_SPEND_PROBLEM='config/boat-spend.json is too large'
    return 1
  }
  out=$(jq -sc '
    def numpos: type == "number" and . > 0;
    def whole: type == "number" and . >= 0 and . == floor;
    def wholepos: type == "number" and . >= 1 and . == floor;
    def strs: type == "array" and all(.[]; type == "string" and length > 0);
    if length != 1 or (.[0] | type) != "object" then error("must be one JSON object")
    else .[0] |
      (keys - ["ceiling_usd", "expected_running", "allowed_sizes", "always_on", "boat_bin", "account_seconds_per_24h", "box_seconds_per_24h", "resume_ttl_seconds", "idle_grace_seconds"]) as $extra |
      if ($extra | length) > 0 then error("unknown key " + ($extra[0] | tojson))
      elif has("ceiling_usd") and (.ceiling_usd | numpos | not) then error("ceiling_usd must be a number above 0")
      elif has("expected_running") and (.expected_running | (whole and . <= 3) | not) then error("expected_running must be a whole number, 0 to 3")
      elif has("allowed_sizes") and (.allowed_sizes | strs | not) then error("allowed_sizes must be a list of size names")
      elif has("always_on") and (.always_on | strs | not) then error("always_on must be a list of sandbox ids")
      elif has("boat_bin") and (.boat_bin | (type == "string" and startswith("/")) | not) then error("boat_bin must be an absolute path")
      elif has("account_seconds_per_24h") and (.account_seconds_per_24h | wholepos | not) then error("account_seconds_per_24h must be a whole number, 1 or more")
      elif has("box_seconds_per_24h") and (.box_seconds_per_24h | wholepos | not) then error("box_seconds_per_24h must be a whole number, 1 or more")
      elif has("resume_ttl_seconds") and (.resume_ttl_seconds | (type == "number" and . >= 1800 and . <= 14400 and . == floor) | not) then error("resume_ttl_seconds must be a whole number of seconds, 1800 to 14400")
      elif has("idle_grace_seconds") and (.idle_grace_seconds | (type == "number" and . >= 0 and . <= 86400 and . == floor) | not) then error("idle_grace_seconds must be a whole number of seconds, 0 to 86400")
      elif (.idle_grace_seconds // 900) >= ([.resume_ttl_seconds // 3600, 3600] | min) then error("idle_grace_seconds " + ((.idle_grace_seconds // 900) | tostring) + " must be shorter than min(resume_ttl_seconds " + ((.resume_ttl_seconds // 3600) | tostring) + ", fallback 3600)")
      else {
        ceiling_usd: (if has("ceiling_usd") then .ceiling_usd else null end),
        expected_running: (if has("expected_running") then .expected_running else null end),
        account_seconds_per_24h: (if has("account_seconds_per_24h") then .account_seconds_per_24h else null end),
        box_seconds_per_24h: (if has("box_seconds_per_24h") then .box_seconds_per_24h else null end),
        resume_ttl_seconds: (if has("resume_ttl_seconds") then .resume_ttl_seconds else null end),
        idle_grace_seconds: (if has("idle_grace_seconds") then .idle_grace_seconds else null end),
        boat_bin: (.boat_bin // "")
      }
      end
    end' "$path" 2>&1) || {
    FM_BOAT_SPEND_PROBLEM=$(printf '%s' "$out" | sed -e 's/^jq: error (at [^)]*): //' -e 's/^jq: error: //' | head -n 1)
    [ -n "$FM_BOAT_SPEND_PROBLEM" ] || FM_BOAT_SPEND_PROBLEM=unreadable
    return 1
  }
  bin=$(printf '%s' "$out" | jq -r '.boat_bin')
  if [ -n "$bin" ] && { [ ! -f "$bin" ] || [ ! -x "$bin" ]; }; then
    FM_BOAT_SPEND_PROBLEM='boat_bin must be an existing executable file'
    return 1
  fi
  ceiling=$(printf '%s' "$out" | jq -r '.ceiling_usd // empty')
  expected=$(printf '%s' "$out" | jq -r '.expected_running // empty')
  account=$(printf '%s' "$out" | jq -r '.account_seconds_per_24h // empty')
  boxsec=$(printf '%s' "$out" | jq -r '.box_seconds_per_24h // empty')
  ttl=$(printf '%s' "$out" | jq -r '.resume_ttl_seconds // empty')
  grace=$(printf '%s' "$out" | jq -r '.idle_grace_seconds // empty')
  # shellcheck disable=SC2034 # Read by fm-boat-send.sh after this function returns.
  [ -z "$ceiling" ] || FM_BOAT_MONTHLY_USD=$ceiling
  [ -z "$expected" ] || FM_BOAT_MAX_BOXES=$expected
  # shellcheck disable=SC2034 # Read by fm-boat-send.sh after this function returns.
  [ -z "$account" ] || FM_BOAT_ACCOUNT_SECONDS=$account
  # shellcheck disable=SC2034 # Read by fm-boat-send.sh and fm-boat-idle-check.sh.
  [ -z "$ttl" ] || FM_BOAT_RESUME_TTL=$ttl
  # shellcheck disable=SC2034 # Read by fm-boat-idle-check.sh after this function returns.
  [ -z "$grace" ] || FM_BOAT_IDLE_GRACE=$grace
  if [ -n "$boxsec" ]; then
    # shellcheck disable=SC2034 # Read by fm-boat-send.sh after this function returns.
    FM_BOAT_BOX_SECONDS=$boxsec
    # shellcheck disable=SC2034 # Read by fm-boat-send.sh after this function returns.
    FM_BOAT_BOX_LEGACY=0
  fi
}

fm_boat_revisit_seconds() {
  local count=$1 interval=${FM_CHECK_INTERVAL:-300}
  case "$interval" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( (10#$interval + FM_BOAT_RENEW_TIMEOUT) * count ))"
}

# fm_boat_read_box_ids <path>
# Prints one approved id per line. On refusal sets FM_BOAT_BOX_PROBLEM and
# returns 1. Requires fm_boat_load_reservation to have set FM_BOAT_MAX_BOXES.
fm_boat_read_box_ids() {
  local path=$1 bytes_cap ids
  FM_BOAT_BOX_PROBLEM=
  [ -d "$(dirname "$path")" ] && [ ! -L "$(dirname "$path")" ] &&
    [ -f "$path" ] && [ ! -L "$path" ] || {
    FM_BOAT_BOX_PROBLEM='safe config/boat-box-id is required'
    return 1
  }
  bytes_cap=$((FM_BOAT_MAX_BOXES * 12))
  [ "$bytes_cap" -le 4096 ] || bytes_cap=4096
  [ "$(wc -c < "$path")" -le "$bytes_cap" ] || {
    FM_BOAT_BOX_PROBLEM='invalid config/boat-box-id'
    return 1
  }
  ids=$(jq -Rser --argjson max "$FM_BOAT_MAX_BOXES" '
    split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end |
    if length < 1 or length > $max then error("count")
    elif any(.[]; test("\\Abx_[23456789abcdefghjkmnpqrstuvwxyz]{8}\\z") | not) then error("id")
    elif (unique | length) != length then error("dup")
    else .[]
    end' "$path" 2>/dev/null) || {
    # shellcheck disable=SC2034 # Read by the caller after a non-zero return.
    FM_BOAT_BOX_PROBLEM='invalid config/boat-box-id'
    return 1
  }
  printf '%s\n' "$ids"
}

fm_boat_validate_cadence() {
  local ids=$1 count revisit minimum effective_ttl
  count=$(printf '%s\n' "$ids" | wc -l)
  revisit=$(fm_boat_revisit_seconds "$count") || {
    FM_BOAT_BOX_PROBLEM='FM_CHECK_INTERVAL must be a whole number of seconds'
    printf '%s\n' "$FM_BOAT_BOX_PROBLEM" >&2
    return 1
  }
  minimum=$((3 * revisit + FM_BOAT_RENEW_TIMEOUT))
  effective_ttl=$FM_BOAT_RESUME_TTL
  [ "$effective_ttl" -le 3600 ] || effective_ttl=3600
  if [ "$effective_ttl" -lt "$minimum" ]; then
    FM_BOAT_BOX_PROBLEM="resume_ttl_seconds $FM_BOAT_RESUME_TTL with fallback 3600 gives an effective timer shorter than ${minimum}s required for $count listed boxes at FM_CHECK_INTERVAL ${FM_CHECK_INTERVAL:-300}"
    printf '%s\n' "$FM_BOAT_BOX_PROBLEM" >&2
    return 1
  fi
}
