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
# removes the shim, its trust binding, and the record. A home with no
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
#   read     Boat could not be read (missing CLI, timeout, malformed JSON, an
#            unreadable field), because a check that cannot see is not quiet
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
# PATH (the same knob fm-boat-alias-refresh.sh uses). A due evaluation runs at
# most once per FM_BOAT_SPEND_INTERVAL seconds (default 86400, 0 disables the
# gate, otherwise 60..86400) and polls inside that interval stay silent; each
# Boat call is bounded by FM_BOAT_SPEND_PROBE_SECS (default 9, 1..9) so the
# whole evaluation finishes inside the watcher's per-check bound. A condition
# that persists is reported again at every due evaluation. docs/configuration.md
# owns the config schema.
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
RECORD_SCHEMA=fm-boat-spend-check-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1000
PERIOD_WARN_DAYS=3

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,51{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
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

INTERVAL=${FM_BOAT_SPEND_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*) fail "FM_BOAT_SPEND_INTERVAL must be 0 or a whole number from 60 to 86400" ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  fail "FM_BOAT_SPEND_INTERVAL must be 0 or a whole number from 60 to 86400"
fi
PROBE_SECS=${FM_BOAT_SPEND_PROBE_SECS:-9}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0) fail "FM_BOAT_SPEND_PROBE_SECS must be a whole number from 1 to 9" ;;
esac
[ "$PROBE_SECS" -le 9 ] || fail "FM_BOAT_SPEND_PROBE_SECS must be a whole number from 1 to 9"

# Validate the config and leave it normalized, defaults applied, as one JSON
# object in CONFIG_NORMALIZED (a global, because a problem is reported through
# CONFIG_PROBLEM and neither survives a command substitution). An unknown key is refused so a misspelled ceiling cannot silently fall
# back to the default.
CONFIG_PROBLEM=
CONFIG_NORMALIZED=
config_normalized() {
  local out
  out=$(jq -c '
    def numpos: type == "number" and . > 0;
    def strs: type == "array" and all(.[]; type == "string" and length > 0);
    if type != "object" then error("must be a JSON object")
    else
      (keys - ["ceiling_usd", "expected_running", "allowed_sizes", "always_on", "boat_bin"]) as $extra |
      if ($extra | length) > 0 then error("unknown key " + ($extra[0] | tojson))
      elif has("ceiling_usd") and (.ceiling_usd | numpos | not) then error("ceiling_usd must be a number above 0")
      elif has("expected_running") and (.expected_running | (type == "number" and . >= 0 and . == floor) | not) then error("expected_running must be a whole number, 0 or more")
      elif has("allowed_sizes") and (.allowed_sizes | strs | not) then error("allowed_sizes must be a list of size names")
      elif has("always_on") and (.always_on | strs | not) then error("always_on must be a list of sandbox ids")
      elif has("boat_bin") and (.boat_bin | (type == "string" and length > 0) | not) then error("boat_bin must be a non-empty string")
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
# One finding per line, from one jq program so the arithmetic has one owner.
findings() {
  jq -nr --argjson cfg "$1" --argjson limits "$2" --argjson list "$3" \
    --argjson billing "$4" --argjson now "$5" --argjson warn_days "$PERIOD_WARN_DAYS" '
    def usd: (. * 100 | round) / 100;
    def ts: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
    def month_end($t): ($t | gmtime) as $g |
      (if $g[1] == 11 then [$g[0] + 1, 0] else [$g[0], $g[1] + 1] end) as $n |
      ([$n[0], $n[1], 1, 0, 0, 0, 0, 0] | mktime);
    ($limits.activeStates // ["provisioned", "cloning", "ready", "idle", "running"]) as $active |
    [($list.sandboxes // [])[] | select(.state as $s | $active | index($s))] as $live |
    ($limits.creditSecondsPerDollar // 0) as $spd |
    ($limits.creditUsedSeconds // null) as $used |
    ($limits.last24hUsageSeconds // 0) as $day |
    ($limits.subscriptionCurrentPeriodEnd | ts) as $period_end |
    ($limits.subscriptionTrialEndsAt | ts) as $trial_end |
    (if $period_end != null and $period_end > $now then $period_end else month_end($now) end) as $horizon |
    [
      (if ($spd | type) != "number" or $spd <= 0 or ($used | type) != "number"
       then "spend unreadable (limits has no usable creditUsedSeconds/creditSecondsPerDollar)"
       else
         ($used / $spd) as $spent |
         (($day / $spd) * (($horizon - $now) / 86400)) as $more |
         if $spent > $cfg.ceiling_usd
         then "spend $\($spent | usd) is over the $\($cfg.ceiling_usd) ceiling"
         elif ($spent + $more) > $cfg.ceiling_usd
         then "spend $\($spent | usd) projects to $\(($spent + $more) | usd) by period end, over the $\($cfg.ceiling_usd) ceiling"
         else empty end
       end),
      (if ($live | length) > $cfg.expected_running
       then "\($live | length) sandboxes active, expected \($cfg.expected_running) (\([$live[] | .id] | join(",")))"
       else empty end),
      ([$live[] | select(.type as $t | $cfg.allowed_sizes | index($t) | not)] | .[] |
        "sandbox \(.id) is size \(.type // "unknown"), not on the allow list (\($cfg.allowed_sizes | join(",")))"),
      ([$live[] | select(.archiveAfter == null and (.id as $i | $cfg.always_on | index($i) | not))] | .[] |
        "sandbox \(.id) has no auto-stop deadline and is not on the always-on list"),
      (if $list.pageInfo.hasMore == true then "sandbox list is incomplete (more pages exist)" else empty end),
      (if ($billing.prepaid.enabled | type) != "boolean" then "auto-refill state unreadable"
       elif $billing.prepaid.enabled then "auto-refill is enabled"
       else empty end),
      ([$trial_end, $period_end] | map(select(. != null and . >= $now and . <= $now + $warn_days * 86400)) | min |
        if . != null then "trial or plan ends \(strftime("%Y-%m-%d")) UTC, within \($warn_days) days" else empty end)
    ] | .[]'
}

record_due() {  # <now>
  local now=$1 last
  [ "$INTERVAL" -ne 0 ] || return 0
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(sed -n 1p "$RECORD" 2>/dev/null)" = "schema	$RECORD_SCHEMA" ] || return 0
  last=$(awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$RECORD" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ "$last" -le "$now" ] || return 0
  [ $((now - last)) -ge "$INTERVAL" ]
}

record_write() {  # <now>
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.boat-spend-check.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'schema\t%s\nlast_eval\t%s\n' "$RECORD_SCHEMA" "$1" > "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$RECORD" "$(fm_pr_file_device "$STATE")" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

report() {  # <joined findings>
  fm_cap_line "boat-spend: $1" "$MAX_LINE"
}

run_check() {
  local now cfg limits list billing rc found joined
  [ -f "$CONFIG" ] || return 0
  now=$(now_epoch)
  record_due "$now" || return 0
  command -v jq >/dev/null 2>&1 || { record_write "$now" || true; report "read failed: jq is missing"; return 0; }
  if ! config_normalized; then
    record_write "$now" || true
    report "config/boat-spend.json is invalid: $CONFIG_PROBLEM"
    return 0
  fi
  cfg=$CONFIG_NORMALIZED
  BOAT_BIN=${FM_BOAT_BIN:-$(printf '%s' "$cfg" | jq -r '.boat_bin')}
  [ -n "$BOAT_BIN" ] || BOAT_BIN=boat
  limits=$(boat_read limits) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_write "$now" || true
    report "read failed: $(read_failure_text limits "$rc")"
    return 0
  fi
  list=$(boat_read list) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_write "$now" || true
    report "read failed: $(read_failure_text list "$rc")"
    return 0
  fi
  billing=$(boat_read billing) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_write "$now" || true
    report "read failed: $(read_failure_text billing "$rc")"
    return 0
  fi
  found=$(findings "$cfg" "$limits" "$list" "$billing" "$now" 2>/dev/null) || {
    record_write "$now" || true
    report "read failed: Boat output had an unexpected shape"
    return 0
  }
  record_write "$now" || true
  [ -n "$found" ] || return 0
  joined=$(printf '%s\n' "$found" | paste -sd ';' - | sed 's/;/; /g')
  report "$joined"
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
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || die_usage; run_check ;;
  arm) [ "$#" -eq 1 ] || die_usage; arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage; disarm ;;
  -h|--help|help) usage ;;
  *) die_usage ;;
esac
