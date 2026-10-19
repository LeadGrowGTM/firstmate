#!/usr/bin/env bash
# fm-boat-spend-check.sh - daily read-only Boat spend check.
#
# Usage:
#   fm-boat-spend-check.sh [check]
#   fm-boat-spend-check.sh arm
#   fm-boat-spend-check.sh disarm
#   fm-boat-spend-check.sh --help
#
# `check` prints one line only when Boat is outside what config/boat-spend.json
# says was agreed, and prints nothing at all otherwise, so it composes with the
# watcher's custom state-check contract: `arm` writes state/boat-spend.check.sh
# and binds its bytes with fm-check-register.sh, the watcher runs it on its
# FM_CHECK_INTERVAL cadence, and its one line becomes a `check:` wake. `disarm`
# removes the shim, its trust binding, and both records. A home with no
# config/boat-spend.json is not checked: `check` is silent and `arm` refuses.
#
# A recurring custom check is used rather than the process-event quota watch
# (fm-procevent-quota.sh) because that source fires at most once and then
# retires, while this one must keep polling and stay quiet until something
# drifts. The tool-update and startup-growth checks are the same shape.
#
# Conditions reported, joined into the one line:
#   spend    the billing-period spend (creditUsedSeconds / creditSecondsPerDollar)
#            is over the ceiling, or is projected to pass it by the end of the
#            period at the last-24-hour run rate
#   running  more sandboxes are in an active state than expected
#   size     an active sandbox's size is not on the allow list
#   no-stop  an active sandbox has no auto-stop deadline and is not on the
#            always-on list
#   refill   auto-refill is enabled
#   period   the trial or plan end is within 3 days
#   health   a sandbox reports health other than ok, carries a restore error,
#            or is an active sandbox that has not finished restoring its disk
#            (hydrated is false at this daily evaluation)
#   expiry   a stopped sandbox is within 3 days of Boat deleting its stopped
#            disk (14 days after it stopped), or is already past that point;
#            this is the one stopped-sandbox condition ever reported
# account_seconds_per_24h and box_seconds_per_24h are accepted and ignored.
# fm-boat-send.sh owns those reservation ceilings. resume_ttl_seconds and
# idle_grace_seconds are accepted and ignored here; fm-boat-send.sh owns the
# short resume timer and fm-boat-idle-check.sh owns the idle grace.
#   read     the check could not see everything (missing jq or CLI, timeout,
#            malformed JSON, an invalid config, an unreadable field, a sandbox
#            list with more pages), because a check that cannot see is not
#            quiet; every such cause is consolidated into one part of the line
#
# Boat is only ever read. Exactly three commands are run, each with the CLI's
# global --no-update flag and --json, and nothing else is ever passed:
#   boat --no-update limits --json
#   boat --no-update list --all --json
#   boat --no-update billing status --json
# It never creates, resumes, stops, deletes, extends, or reconfigures a sandbox
# and never touches billing; it reports and a person acts.
#
# The CLI comes from FM_BOAT_BIN, else "boat_bin" in the config, else `boat` on
# PATH. An evaluation that read everything is recorded and the next one is due
# 86400 seconds later; polls inside that day stay silent, and a condition that
# persists is reported again at every due evaluation. An evaluation that could
# not read everything is not recorded, so the next poll tries again, and its
# line is printed at most once per 86400 seconds until a read succeeds. Each
# Boat call is bounded to 9 seconds so the whole evaluation finishes inside the
# watcher's per-check bound. docs/configuration.md owns the config schema.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/boat-spend.json"
CHECK_ID=boat-spend
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.boat-spend-check"
FAILURE_RECORD="$STATE/.boat-spend-check-failed"
RECORD_SCHEMA=fm-boat-spend-check-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1000
PERIOD_WARN_DAYS=3
INTERVAL=86400
PROBE_SECS=9

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,60{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-boat-spend-check: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

now_epoch() {
  case "${FM_BOAT_SPEND_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_BOAT_SPEND_NOW" ;;
  esac
}

# Validate the config and leave it normalized, defaults applied, as one JSON
# object in CONFIG_NORMALIZED (a global, because a problem is reported through
# CONFIG_PROBLEM and neither survives a command substitution). An unknown key
# is refused so a misspelled ceiling cannot silently fall back to the default,
# and "boat_bin" must name an existing executable file by absolute path.
CONFIG_PROBLEM=
CONFIG_NORMALIZED=
config_normalized() {
  local out bin
  out=$(jq -sc '
    def numpos: type == "number" and . > 0;
    def strs: type == "array" and all(.[]; type == "string" and length > 0);
    if length != 1 or (.[0] | type) != "object" then error("must be one JSON object")
    else
      .[0] |
      (keys - ["ceiling_usd", "expected_running", "allowed_sizes", "always_on", "boat_bin", "account_seconds_per_24h", "box_seconds_per_24h", "resume_ttl_seconds", "idle_grace_seconds"]) as $extra |
      if ($extra | length) > 0 then error("unknown key " + ($extra[0] | tojson))
      elif has("ceiling_usd") and (.ceiling_usd | numpos | not) then error("ceiling_usd must be a number above 0")
      elif has("expected_running") and (.expected_running | (type == "number" and . >= 0 and . == floor) | not) then error("expected_running must be a whole number, 0 or more")
      elif has("allowed_sizes") and (.allowed_sizes | strs | not) then error("allowed_sizes must be a list of size names")
      elif has("always_on") and (.always_on | strs | not) then error("always_on must be a list of sandbox ids")
      elif has("boat_bin") and (.boat_bin | (type == "string" and startswith("/")) | not) then error("boat_bin must be an absolute path")
      elif has("account_seconds_per_24h") and (.account_seconds_per_24h | (type == "number" and . >= 1 and . == floor) | not) then error("account_seconds_per_24h must be a whole number, 1 or more")
      elif has("box_seconds_per_24h") and (.box_seconds_per_24h | (type == "number" and . >= 1 and . == floor) | not) then error("box_seconds_per_24h must be a whole number, 1 or more")
      else {
        ceiling_usd: (.ceiling_usd // 30),
        expected_running: (.expected_running // 1),
        allowed_sizes: (.allowed_sizes // ["small", "default"]),
        always_on: (.always_on // []),
        boat_bin: (.boat_bin // "")
      }
      end
    end' "$CONFIG" 2>&1) || {
    CONFIG_PROBLEM=$(printf '%s' "$out" | sed -e 's/^jq: error (at [^)]*): //' -e 's/^jq: error: //' | head -n 1)
    [ -n "$CONFIG_PROBLEM" ] || CONFIG_PROBLEM="unreadable"
    return 1
  }
  bin=$(printf '%s' "$out" | jq -r '.boat_bin')
  if [ -n "$bin" ] && { [ ! -f "$bin" ] || [ ! -x "$bin" ]; }; then
    CONFIG_PROBLEM="boat_bin must be an existing executable file"
    return 1
  fi
  CONFIG_NORMALIZED=$out
}

# boat_read <limits|list|billing>
# The only place a Boat command line is built; there is no other path to the
# CLI, so no argument beyond these three fixed read shapes can ever be passed.
# Exit status: 0 prints JSON; 1 timed out; 2 missing; 3 other failure or output
# that is not JSON.
BOAT_BIN=
boat_read() {
  local out rc=0
  local -a args
  case "$1" in
    limits)  args=(--no-update limits --json) ;;
    list)    args=(--no-update list --all --json) ;;
    billing) args=(--no-update billing status --json) ;;
    *) return 3 ;;
  esac
  command -v "$BOAT_BIN" >/dev/null 2>&1 || return 2
  out=$(fm_run_timed "$PROBE_SECS" "$BOAT_BIN" "${args[@]}" 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_timed_out "$rc" && return 1
    return 3
  fi
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || return 3
  printf '%s\n' "$out"
}

read_failure_text() {  # <what> <status>
  case "$2" in
    1) printf 'boat %s timed out' "$1" ;;
    2) printf 'the Boat CLI is missing' ;;
    *) printf 'boat %s did not return readable JSON' "$1" ;;
  esac
}

# findings <config> <limits> <list> <billing> <now>
# The first line is "ok" when every consumed field was readable and "blind"
# otherwise; each line after it is one finding, from one jq program so the
# arithmetic has one owner. Every unreadable field lands in the one last line.
findings() {
  jq -nr --argjson cfg "$1" --argjson limits "$2" --argjson list "$3" \
    --argjson billing "$4" --argjson now "$5" --argjson warn_days "$PERIOD_WARN_DAYS" '
    def usd: (. * 100 | round) / 100;
    def ts: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
    def month_end($t): ($t | gmtime) as $g |
      (if $g[1] == 11 then [$g[0] + 1, 0] else [$g[0], $g[1] + 1] end) as $n |
      ([$n[0], $n[1], 1, 0, 0, 0, 0, 0] | mktime);
    def strs: type == "array" and all(.[]; type == "string");
    def has_state: type == "object" and (.state | type) == "string";
    $limits.activeStates as $states |
    (if $states | strs then $states else [] end) as $active |
    ($list.sandboxes | if type == "array" then . else [] end) as $boxes |
    [$boxes[] | select(has_state) | select(.state as $s | $active | index($s))] as $live |
    $limits.creditSecondsPerDollar as $spd |
    $limits.creditUsedSeconds as $used |
    $limits.last24hUsageSeconds as $day |
    (($spd | type) == "number" and $spd > 0 and ($used | type) == "number") as $spend_ok |
    ($limits.subscriptionCurrentPeriodEnd | ts) as $period_end |
    ($limits.subscriptionTrialEndsAt | ts) as $trial_end |
    (if $period_end != null and $period_end > $now then $period_end else month_end($now) end) as $horizon |
    [
      (if $spend_ok then empty else "spend" end),
      (if ($day | type) == "number" then empty else "last-24-hour usage" end),
      (if $states | strs then empty else "active states" end),
      (if $limits.subscriptionCurrentPeriodEnd != null and $period_end == null then "plan end" else empty end),
      (if $limits.subscriptionTrialEndsAt != null and $trial_end == null then "trial end" else empty end),
      (if ($list.sandboxes | type) == "array" then empty else "sandbox list" end),
      (if all($boxes[]; has_state) then empty else "a sandbox state" end),
      (if ($list.pageInfo.hasMore | type) != "boolean" then "sandbox list paging"
       elif $list.pageInfo.hasMore then "sandbox list past its first page"
       else empty end),
      (if ($billing.prepaid.enabled | type) == "boolean" then empty else "auto-refill state" end)
    ] as $unread |
    (if ($unread | length) > 0 then "blind" else "ok" end),
    (if $spend_ok then
       ($used / $spd) as $spent |
       (((if ($day | type) == "number" then $day else 0 end) / $spd) * (($horizon - $now) / 86400)) as $more |
       if $spent > $cfg.ceiling_usd
       then "spend $\($spent | usd) is over the $\($cfg.ceiling_usd) ceiling"
       elif ($spent + $more) > $cfg.ceiling_usd
       then "spend $\($spent | usd) projects to $\(($spent + $more) | usd) by period end, over the $\($cfg.ceiling_usd) ceiling"
       else empty end
     else empty end),
    (if ($live | length) > $cfg.expected_running
     then "\($live | length) sandboxes active, expected \($cfg.expected_running) (\([$live[] | .id] | join(",")))"
     else empty end),
    ([$live[] | select(.type as $t | $cfg.allowed_sizes | index($t) | not)] | .[] |
      "sandbox \(.id) is size \(.type // "unknown"), not on the allow list (\($cfg.allowed_sizes | join(",")))"),
    ([$live[] | select(.archiveAfter == null and (.id as $i | $cfg.always_on | index($i) | not))] | .[] |
      "sandbox \(.id) has no auto-stop deadline and is not on the always-on list"),
    (if $billing.prepaid.enabled == true then "auto-refill is enabled" else empty end),
    ([$trial_end, $period_end] | map(select(. != null and . >= $now and . <= $now + $warn_days * 86400)) | min |
      if . != null then "trial or plan ends \(strftime("%Y-%m-%d")) UTC, within \($warn_days) days" else empty end),
    ($boxes[] | select(.health != null and .health != "ok") |
      "sandbox \(.id) health is \(.health)"),
    ($boxes[] | select(.error != null and .error != "") |
      "sandbox \(.id) has a restore error: \(.error[0:80])"),
    ($live[] | select(.hydrated == false) |
      "sandbox \(.id) has not finished restoring its disk"),
    ($boxes[] | select(.state == "stopped") |
      ((.stop.endedAt | ts) // (.updatedAt | ts)) as $stopped_at |
      if $stopped_at == null then empty
      else ($stopped_at + 14 * 86400) as $disk_end |
        if $disk_end <= $now
        then "stopped sandbox \(.id) disk expired \($disk_end | strftime("%Y-%m-%d")) UTC (14 days after it stopped)"
        elif $disk_end <= $now + $warn_days * 86400
        then "stopped sandbox \(.id) disk expires \($disk_end | strftime("%Y-%m-%d")) UTC, within \($warn_days) days"
        else empty end
      end),
    (if ($unread | length) > 0 then "read failed: unreadable \($unread | join(", "))" else empty end)'
}

record_due() {  # <file> <now>
  local file=$1 now=$2 last
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  [ "$(sed -n 1p "$file" 2>/dev/null)" = "schema	$RECORD_SCHEMA" ] || return 0
  last=$(awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$file" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ "$last" -le "$now" ] || return 0
  [ $((now - last)) -ge "$INTERVAL" ]
}

record_write() {  # <file> <now>
  local file=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.boat-spend-check.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'schema\t%s\nlast_eval\t%s\n' "$RECORD_SCHEMA" "$2" > "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$file" "$(fm_pr_file_device "$STATE")" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

report() {  # <joined findings>
  fm_cap_line "boat-spend: $1" "$MAX_LINE"
}

# evaluate <now>
# Leaves the report text, empty when there is nothing to say, in EVAL_LINE (a
# global, because the exit status is taken too). Exit status: 0 everything was
# read; 1 something could not be read.
EVAL_LINE=
evaluate() {
  local now=$1 cfg limits list billing rc found
  EVAL_LINE=
  command -v jq >/dev/null 2>&1 || { EVAL_LINE="read failed: jq is missing"; return 1; }
  if ! config_normalized; then
    EVAL_LINE="config/boat-spend.json is invalid: $CONFIG_PROBLEM"
    return 1
  fi
  cfg=$CONFIG_NORMALIZED
  BOAT_BIN=${FM_BOAT_BIN:-$(printf '%s' "$cfg" | jq -r '.boat_bin')}
  [ -n "$BOAT_BIN" ] || BOAT_BIN=boat
  limits=$(boat_read limits) || { rc=$?; EVAL_LINE="read failed: $(read_failure_text limits "$rc")"; return 1; }
  list=$(boat_read list) || { rc=$?; EVAL_LINE="read failed: $(read_failure_text list "$rc")"; return 1; }
  billing=$(boat_read billing) || { rc=$?; EVAL_LINE="read failed: $(read_failure_text billing "$rc")"; return 1; }
  found=$(findings "$cfg" "$limits" "$list" "$billing" "$now" 2>/dev/null) || {
    EVAL_LINE="read failed: Boat output had an unexpected shape"
    return 1
  }
  EVAL_LINE=$(printf '%s\n' "$found" | sed 1d | paste -sd ';' - | sed 's/;/; /g')
  [ "$(printf '%s\n' "$found" | sed -n 1p)" = ok ]
}

run_check() {
  local now
  [ -f "$CONFIG" ] || return 0
  now=$(now_epoch)
  record_due "$RECORD" "$now" || return 0
  if evaluate "$now"; then
    record_write "$RECORD" "$now" || true
    rm -f -- "$FAILURE_RECORD"
    [ -n "$EVAL_LINE" ] || return 0
  else
    record_due "$FAILURE_RECORD" "$now" || return 0
    record_write "$FAILURE_RECORD" "$now" || true
  fi
  report "$EVAL_LINE"
}

SHIM_TMP=
ARM_BACKUP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.boat-spend-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.boat-spend-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# A shim without a matching trust binding is rejected by the watcher on every
# cycle, so a failed or interrupted arm keeps only a shim that is still bound.
arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

arm() {
  local state_device home want
  [ -f "$CONFIG" ] || fail "no Boat spend config at $CONFIG"
  config_normalized >/dev/null || fail "$CONFIG_PROBLEM ($CONFIG)"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-boat-spend-check.sh") check")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD" "$FAILURE_RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || die_usage; run_check ;;
  arm) [ "$#" -eq 1 ] || die_usage; arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage; disarm ;;
  -h|--help|help) usage ;;
  *) die_usage ;;
esac
