#!/usr/bin/env bash
# Send one explicitly Boat-selected, code-only task through the boat-eng route.
# Usage: fm-boat-send.sh [--prepare] --code-only < request.json
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
# The one approved box is bx_ahnbu3qr. Reads are fresh, bounded limits, list,
# info, and rolling-24-hour usage calls. Unavailable readings or exhausted caps
# stop that box and refuse dispatch. The entire auto-stop window is reserved
# below $20/month, 60000 account seconds/day, and 43000 box seconds/day ($0.43).
# Resume uses --no-env and an explicit timer (4 hours paid, 2 hours trial).
# A running box must already have a readable timer within that budget window;
# this command never extends it. No box creation/deletion/sharing, billing,
# plan, credit, environment injection, or merge command exists here.
#
# FM_BOAT_BIN selects the CLI (boat); fm-boat-alias-refresh.sh owns SSH refresh.
# On transport failure, remote completion is unknown: reconcile the SAME task
# with fm-on.sh boat-eng fm-crew-state.sh <id>, never automatically resend.
# Status, steering, and reports use existing fm-on.sh commands against boat-eng;
# no PC worker endpoint or worktree is allocated. The operator stops the box
# after work completes (or after 20 idle minutes), and rechecks caps before any
# extension. Auto-stop is the hard upper bound even if the controller disappears.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
BOAT_BIN=${FM_BOAT_BIN:-boat}
BOX=bx_ahnbu3qr
ROUTE=boat-eng
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
[ "${1:-}" != --help ] || { sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p;}' "$0"; exit 0; }
PREPARE=0
if [ "${1:-}" = --prepare ]; then PREPARE=1; shift; fi
[ "$#" -eq 1 ] && [ "$1" = --code-only ] || die 'explicit --code-only attestation required'
for tool in jq "$BOAT_BIN"; do command -v "$tool" >/dev/null || die "$tool is required"; done
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-boat-send.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
head -c 65537 > "$TMP/request"
[ "$(wc -c < "$TMP/request")" -le 65536 ] || die 'request exceeds 65536 bytes'
# Both ends use the same validator; no remote contact occurs before validation.
"$SCRIPT_DIR/fm-boat-worker.sh" validate < "$TMP/request"
REG="$FM_HOME/data/secondmates.md"
[ "$(secondmate_registry_field "$REG" "$ROUTE" host)" = boat-prove ] || die 'boat-eng must use boat-prove'
REMOTE_HOME=$(secondmate_registry_field "$REG" "$ROUTE" home) || die 'missing boat-eng home'
case "$REMOTE_HOME" in /home/user/*) ;; *) die 'boat-eng must have a dedicated sandbox home' ;; esac
[ "$REMOTE_HOME" != /home/user/fm-home ] || die 'the earlier proof mate home is not an overflow home'
stop_refuse() {
  fm_run_timed 30 "$BOAT_BIN" --no-update stop "$BOX" --json >/dev/null 2>&1 || true
  die "$1; dispatch refused (stop requested for $BOX)"
}
read_boat() {
  fm_run_timed 15 "$BOAT_BIN" --no-update "$@" --json > "$TMP/$1" 2>/dev/null || stop_refuse "Boat $1 read unavailable"
  jq -e 'type == "object"' "$TMP/$1" >/dev/null 2>&1 || stop_refuse "Boat $1 returned invalid JSON"
}
read_boat limits
read_boat list --all
read_boat info "$BOX"
read_boat usage "$BOX" --since "$(( $(date +%s) - 86400 ))"
NO_ENV_RECEIPT="$FM_HOME/state/.boat-no-env"
# Reserve the whole timer rather than trusting a worker's runtime estimate.
TTL=$(jq -nr --slurpfile l "$TMP/limits" --slurpfile b "$TMP/list" \
  --slurpfile i "$TMP/info" --slurpfile u "$TMP/usage" --arg box "$BOX" '
  def nonneg: type == "number" and . >= 0;
  $l[0] as $l | $b[0] as $b | $i[0].sandbox as $i | $u[0] as $u |
  (if $l.billingStatus == "active" then 14400 elif $l.billingStatus == "trialing" then 7200 else error("plan is off") end) as $ttl |
  if $l.canStart != true or $l.creditSecondsPerDollar != 100000 or
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
STATE=$(jq -r '.sandbox.state' "$TMP/info")
case "$STATE" in
  stopped)
    "$BOAT_BIN" --no-update resume "$BOX" --no-env --ttl "$TTL" --json > "$TMP/resume" || stop_refuse 'Boat resume failed'
    [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] && [ ! -L "$NO_ENV_RECEIPT" ] || stop_refuse 'unsafe no-env receipt path'
    printf '%s\n' "$BOX" > "$NO_ENV_RECEIPT"
    read_boat info "$BOX"
    ;;
  ready|idle|running)
    [ -f "$NO_ENV_RECEIPT" ] && [ ! -L "$NO_ENV_RECEIPT" ] &&
      [ "$(cat "$NO_ENV_RECEIPT")" = "$BOX" ] || stop_refuse 'running box has no successful --no-env resume receipt'
    ;;
  *) stop_refuse 'box is in an unsupported state' ;;
esac
jq -e --argjson ttl "$TTL" --argjson now "$(date +%s)" '
  .sandbox | .type == "default" and
  (.state == "ready" or .state == "idle" or .state == "running") and
  (.archiveAfter | type) == "string" and
  ((.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now > 0) and
  ((.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now <= $ttl)
' "$TMP/info" >/dev/null 2>&1 || stop_refuse 'box auto-stop timer is unavailable or exceeds the reserved budget'
FM_BOAT_BIN="$BOAT_BIN" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" "$BOX" boat-prove || stop_refuse 'SSH refresh or hydration failed'
if [ "$PREPARE" -eq 1 ]; then
  printf 'prepared: %s route=%s (no worker dispatched)\n' "$BOX" "$ROUTE"
  exit 0
fi
# Stdin and argv reuse the existing remote job lane, environment scrub, and
# exit-255 contract. An uncertain launch is deliberately not retried or stopped.
"$SCRIPT_DIR/fm-on.sh" --stdin "$ROUTE" fm-boat-worker.sh spawn < "$TMP/request"
