#!/usr/bin/env bash
# Send one explicitly Boat-selected, code-only task through the boat-eng route.
# Usage: fm-boat-send.sh [--prepare] --code-only < request.json
#        fm-boat-send.sh --teardown <task-id>
# --prepare performs the guarded resume/SSH refresh only, for initial seeding;
# it does not dispatch a worker. The same valid, selected task is required.
#
# Firstmate selects Boat and labels the work at intake under its standing rules;
# this command never evaluates R5 or infers eligibility from prose. request.json
# is owned by fm-boat-worker.sh's header. Only that task envelope crosses the
# existing fm-on transport, never a local home, project tree, or environment.
# The configured boat-eng route must name SSH alias boat-prove and a purpose-built
# home marked boat-eng. Provision it with fm-remote-home-seed.sh, using only
# allowlisted project origins and a new charter, not an existing mate's home.
#
# config/boat-box-id must be a regular non-symlink file in a non-symlink config
# directory, containing exactly one bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}
# (with an optional final newline). Missing or invalid selection refuses before
# Boat contact. Reads are fresh, bounded limits, list, info, and rolling-24-hour
# usage calls. Unavailable readings or exhausted caps refuse dispatch.
# The remaining auto-stop window (full timer on resume) is reserved
# below $20/month, 60000 account seconds/day, and 43000 box seconds/day ($0.43).
# Resume uses --environment fm-code and an explicit timer (4 hours paid,
# 2 hours trial). state/.boat-environment binds the selected box id, boot
# instance, and fm-code. The old .boat-no-env receipt cannot authorize a send.
# Running metadata must name environment fm-code; a present noEnv flag must
# be false. Permanently no-env boxes refuse dispatch.
# A running box must already have a readable timer within that budget window;
# this command never extends it. No box creation/deletion/sharing, billing,
# plan, credit, environment editing, or merge command exists here.
#
# Requests never carry Git identity or credentials. The worker derives its
# identity from the GitHub connection injected on the box by fm-code.
# Dispatch returns success only after the remote worker confirms fresh status.
# FM_BOAT_BIN selects the CLI (boat); fm-boat-alias-refresh.sh owns SSH refresh,
# and a stop made here parks the boat-prove alias at once through its --verify.
# On transport failure, remote completion is unknown: reconcile the SAME task
# with fm-on.sh boat-eng fm-crew-state.sh <id>, never automatically resend.
# A definite spawn refusal stops a box this send resumed only after the
# remote worker lock confirms that no task records or endpoints remain.
# Pre-resume refusals never request a stop; stop authority follows only this
# invocation's successful resume, not an earlier stopped-state observation.
# Status, steering, and reports use existing fm-on.sh commands against boat-eng;
# no PC worker endpoint or worktree is allocated. Last-task teardown stops the
# box; its auto-stop timer is the hard upper bound if teardown cannot complete.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
BOAT_BIN=${FM_BOAT_BIN:-boat}
ROUTE=boat-eng
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
[ "${1:-}" != --help ] || { sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; exit 0; }
PREPARE=0
TEARDOWN_ID=
if [ "${1:-}" = --prepare ]; then PREPARE=1; shift; fi
if [ "${1:-}" = --teardown ]; then
  [ "$PREPARE" -eq 0 ] || die 'prepare cannot teardown a task'
  [ "$#" -eq 2 ] || die 'task id required for teardown'
  TEARDOWN_ID=$2
  case "$TEARDOWN_ID" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) die 'invalid task id' ;; esac
else
  [ "$#" -eq 1 ] && [ "$1" = --code-only ] || die 'explicit --code-only attestation required'
fi
for tool in jq "$BOAT_BIN"; do command -v "$tool" >/dev/null || die "$tool is required"; done
BOX_CONFIG="$FM_HOME/config/boat-box-id"
[ -d "$FM_HOME/config" ] && [ ! -L "$FM_HOME/config" ] &&
  [ -f "$BOX_CONFIG" ] && [ ! -L "$BOX_CONFIG" ] || die 'safe config/boat-box-id is required'
[ "$(wc -c < "$BOX_CONFIG")" -le 12 ] || die 'invalid config/boat-box-id'
BOX=$(jq -Rser 'select(test("\\Abx_[23456789abcdefghjkmnpqrstuvwxyz]{8}\\n?\\z")) | rtrimstr("\n")' "$BOX_CONFIG") || die 'invalid config/boat-box-id'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-boat-send.XXXXXX")
SEND_LOCK=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() { rm -rf -- "$TMP"; [ -z "$SEND_LOCK" ] || fm_lock_release "$SEND_LOCK" || true; }
trap cleanup EXIT
if [ -z "$TEARDOWN_ID" ]; then
  head -c 65537 > "$TMP/request"
  [ "$(wc -c < "$TMP/request")" -le 65536 ] || die 'request exceeds 65536 bytes'
  # Both ends use the same validator; no remote contact occurs before validation.
  "$SCRIPT_DIR/fm-boat-worker.sh" validate < "$TMP/request"
fi
LOCK_PATH="$FM_HOME/state/.boat-send.lock"
fm_lock_acquire_wait "$LOCK_PATH" || die 'Boat send lock unavailable'
SEND_LOCK="$LOCK_PATH"
ENV_RECEIPT="$FM_HOME/state/.boat-environment"
boat_instance() {
  fm_run_timed 45 "$BOAT_BIN" --no-update exec "$BOX" --json -- cat /proc/sys/kernel/random/boot_id > "$TMP/instance" 2>/dev/null || return 1
  jq -er 'select(.exitCode == 0) | .stdout | select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\n?$")) | rtrimstr("\n")' "$TMP/instance"
}
receipt_matches() {
  [ -f "$ENV_RECEIPT" ] && [ ! -L "$ENV_RECEIPT" ] &&
    [ "$(cat "$ENV_RECEIPT")" = "$BOX $1 fm-code" ]
}
stop_current_instance() {
  local current
  current=$(boat_instance) && [ "$current" = "$instance" ] && receipt_matches "$current" || return 1
  fm_run_timed 30 "$BOAT_BIN" --no-update stop "$BOX" --json >/dev/null || return 1
  rm -f -- "$ENV_RECEIPT"
  # Park the alias now; fm-on.sh's own check would otherwise do it at the next call.
  FM_BOAT_BIN="$BOAT_BIN" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" --verify boat-prove >/dev/null 2>&1 || true
}
REG="${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md"
if [ "$PREPARE" -eq 0 ]; then
  [ "$(secondmate_registry_field "$REG" "$ROUTE" host)" = boat-prove ] || die 'boat-eng must use boat-prove'
  REMOTE_HOME=$(secondmate_registry_field "$REG" "$ROUTE" home) || die 'missing boat-eng home'
  case "$REMOTE_HOME" in /home/user/*) ;; *) die 'boat-eng must have a dedicated sandbox home' ;; esac
  [ "$REMOTE_HOME" != /home/user/fm-home ] || die 'the earlier proof mate home is not an overflow home'
fi
if [ -n "$TEARDOWN_ID" ]; then
  instance=$(boat_instance) || die 'approved box instance is unavailable'
  receipt_matches "$instance" || die 'selected box has no current fm-code environment receipt'
  remaining=$("$SCRIPT_DIR/fm-on.sh" "$ROUTE" fm-boat-worker.sh teardown "$TEARDOWN_ID" "$instance") || die 'remote Boat teardown failed; reconcile before stopping'
  case "$remaining" in
    'boat-tasks-remaining: yes') printf 'teardown: %s; other Boat tasks remain\n' "$TEARDOWN_ID" ;;
    'boat-tasks-remaining: no')
      stop_current_instance || die 'last-task teardown completed but current-instance Boat stop failed'
      printf 'teardown: %s; stopped %s\n' "$TEARDOWN_ID" "$BOX"
      ;;
    *) die 'remote Boat teardown result is invalid; reconcile before stopping' ;;
  esac
  exit 0
fi
STOP_ON_REFUSAL=0
instance=
stop_refuse() {
  if [ "$STOP_ON_REFUSAL" -eq 1 ]; then
    stop_current_instance >/dev/null 2>&1 || die "$1; dispatch refused (current-instance stop unavailable)"
    die "$1; dispatch refused (stopped $BOX)"
  fi
  die "$1; dispatch refused"
}
read_boat() {
  fm_run_timed 15 "$BOAT_BIN" --no-update "$@" --json > "$TMP/$1" 2>/dev/null || stop_refuse "Boat $1 read unavailable"
  jq -e 'type == "object"' "$TMP/$1" >/dev/null 2>&1 || stop_refuse "Boat $1 returned invalid JSON"
}
read_boat info "$BOX"
STATE=$(jq -r '.sandbox.state // empty' "$TMP/info")
jq -e '.sandbox.noEnv == true' "$TMP/info" >/dev/null 2>&1 && stop_refuse 'permanently no-env boxes cannot use fm-code; select an environment-capable box'
if [ "$STATE" = stopped ]; then
  rm -f -- "$ENV_RECEIPT"
fi
read_boat limits
read_boat list --all
read_boat usage "$BOX" --since "$(( $(date +%s) - 86400 ))"
# Reserve the existing remaining timer, or the full timer for a new resume.
TTL=$(jq -nr --slurpfile l "$TMP/limits" --slurpfile b "$TMP/list" \
  --slurpfile i "$TMP/info" --slurpfile u "$TMP/usage" --arg box "$BOX" --argjson now "$(date +%s)" '
  def nonneg: type == "number" and . >= 0;
  $l[0] as $l | $b[0] as $b | $i[0].sandbox as $i | $u[0] as $u |
  (if $l.billingStatus == "active" then 14400 elif $l.billingStatus == "trialing" then 7200 else error("plan is off") end) as $max_ttl |
  (if $i.state == "stopped" then $max_ttl
   elif ($i.state | IN("ready", "idle", "running")) and ($i.archiveAfter | type) == "string" then
     ($i.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now
   else error("unreadable Boat timer") end) as $ttl |
  if $ttl <= 0 or $ttl > $max_ttl or ($i.state == "stopped" and $l.canStart != true) or $l.creditSecondsPerDollar != 100000 or
     ($l.creditUsedSeconds | nonneg | not) or ($l.last24hUsageSeconds | nonneg | not) or
     ($l.creditBalanceSeconds | nonneg | not) or
     $b.pageInfo.hasMore != false or ($b.sandboxes | type) != "array" or
     ($l.activeStates | type) != "array" or
     any($b.sandboxes[]; (.state | type) != "string") or
     any($b.sandboxes[]; .state as $s | ($l.activeStates | index($s)) != null and .id != $box) or
     $i.id != $box or $i.type != "default" or
     $u.sandboxId != $box or $u.sandboxType != "default" or $u.secondsPerDollar != 100000 or
     $u.billingMultiplier != 1 or ($u.seconds | nonneg | not)
  then error("unreadable or unsafe Boat state")
  elif $l.creditUsedSeconds + $ttl >= 2000000 or $l.last24hUsageSeconds + $ttl >= 60000 or
       $u.seconds + $ttl >= 43000 or $l.creditBalanceSeconds < $ttl
  then error("spend cap would be exceeded")
  else $ttl end' 2> "$TMP/reason") || stop_refuse 'Boat safety or spend reservation failed'
case "$STATE" in
  stopped)
    fm_run_timed 120 "$BOAT_BIN" --no-update resume "$BOX" --environment fm-code --ttl "$TTL" --json > "$TMP/resume" || stop_refuse 'Boat resume failed'
    STOP_ON_REFUSAL=1
    instance=$(boat_instance) || stop_refuse 'Boat instance identity is unavailable'
    if ! { [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] && [ ! -L "$ENV_RECEIPT" ] &&
      { [ ! -e "$ENV_RECEIPT" ] || [ -f "$ENV_RECEIPT" ]; }; }; then
      stop_refuse 'unsafe environment receipt path'
    fi
    printf '%s %s fm-code\n' "$BOX" "$instance" > "$ENV_RECEIPT"
    read_boat info "$BOX"
    ;;
  ready|idle|running) ;;
  *) stop_refuse 'box is in an unsupported state' ;;
esac
jq -e --arg box "$BOX" '
  .sandbox | .id == $box and .environment == "fm-code" and
  ((has("noEnv") | not) or .noEnv == false)
' "$TMP/info" >/dev/null 2>&1 || stop_refuse 'box metadata does not prove the fm-code environment; permanently no-env boxes cannot be used'
jq -e --argjson ttl "$TTL" --argjson now "$(date +%s)" '
  .sandbox | .type == "default" and
  (.state == "ready" or .state == "idle" or .state == "running") and
  (.archiveAfter | type) == "string" and
  ((.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now > 0) and
  ((.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now <= $ttl)
' "$TMP/info" >/dev/null 2>&1 || stop_refuse 'box auto-stop timer is unavailable or exceeds the reserved budget'
current=$(boat_instance) || stop_refuse 'Boat instance identity is unavailable'
if [ "$STATE" = stopped ]; then
  if [ "$current" != "$instance" ] || ! receipt_matches "$current"; then
    stop_refuse 'Boat instance changed after resume'
  fi
else
  instance=$current
  receipt_matches "$instance" || stop_refuse 'running box has no current fm-code environment receipt'
fi
FM_BOAT_BIN="$BOAT_BIN" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" "$BOX" boat-prove || stop_refuse 'SSH refresh or hydration failed'
if [ "$PREPARE" -eq 1 ]; then
  printf 'prepared: %s route=%s (no worker dispatched)\n' "$BOX" "$ROUTE"
  exit 0
fi
# Stdin and argv reuse the existing remote job lane, environment scrub, and
# exit-255 contract. An uncertain launch is deliberately not retried or stopped.
DISPATCH_STATUS=0
"$SCRIPT_DIR/fm-on.sh" --stdin "$ROUTE" fm-boat-worker.sh spawn "$instance" < "$TMP/request" > "$TMP/dispatch" || DISPATCH_STATUS=$?
cat "$TMP/dispatch"
if [ "$DISPATCH_STATUS" -eq 0 ]; then
  ID=$(jq -r .id "$TMP/request")
  grep -Fxq "boat-started: $ID (fresh worker status)" "$TMP/dispatch" ||
    die "worker start unconfirmed for $ID; reconcile with fm-on.sh boat-eng fm-crew-state.sh $ID before retry"
fi
if [ "$DISPATCH_STATUS" -ne 0 ] && [ "$DISPATCH_STATUS" -ne 255 ] && [ "$STATE" = stopped ]; then
  remaining=$("$SCRIPT_DIR/fm-on.sh" "$ROUTE" fm-boat-worker.sh idle "$instance") || remaining=unknown
  if [ "$remaining" = 'boat-tasks-remaining: no' ]; then
    stop_refuse 'remote worker refused before spawning'
  fi
fi
exit "$DISPATCH_STATUS"
