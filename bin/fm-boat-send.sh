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
# directory, one bx_[23456789abcdefghjkmnpqrstuvwxyz]{8} id per line, with an
# optional final newline. One id is the historical file. More ids are allowed
# up to expected_running in config/boat-spend.json (1 when the file or key is
# absent). Missing, duplicate, or extra ids refuse before Boat contact.
# That spend file is the one fm-boat-spend-check.sh reads, resolved the same
# way (FM_CONFIG_OVERRIDE, else $FM_HOME/config/boat-spend.json). Absent keys
# keep today's reservation: below $20 (2000000 credit seconds at the required
# 100000 credit seconds per dollar), below 60000 account seconds per rolling
# 24h, and below a 43000 box-second sum (usage + timer reaching it is refused).
# A new resume reserves only the short on-demand timer (resume_ttl_seconds,
# 3600 when absent, capped by the plan timer), never the whole plan timer.
# ceiling_usd and account_seconds_per_24h use that same sum: used + timer
# reaching the ceiling is refused. Those two checks, and the balance check,
# also add the remaining timers of the other active listed boxes. An active
# listed box with no readable timer refuses the reservation. When
# box_seconds_per_24h is set, the per-box rule refuses only when rolling
# usage is already above it (usage > box_seconds_per_24h), so usage + the
# one reserved timer may reach that ceiling plus that timer, including the
# equal sum. A task recorded in state/.boat-task-box is dispatched only to
# that box. Dispatch writes that record for one listed box too. Teardown
# with more than one listed box uses the record, or the receipt when the
# receipt names exactly one listed box.
# An active sandbox that is not listed, or more active sandboxes than the cap,
# refuses dispatch. Listed active sandboxes do not. With more than one listed
# box, dispatch tries a listed box that can take another worker, preferring one
# already running, and moves on only when that box reports the three-worker cap.
# Box creation stays out of this command. The selected id is written to
# state/.boat-route-box for later boat-eng checks, and state/.boat-task-box
# records the box a task was sent to.
# Reads are fresh, bounded limits, list, info, and rolling-24-hour usage calls.
# Unavailable readings or exhausted caps refuse dispatch.
# Resume uses --environment fm-code and the short on-demand timer
# (resume_ttl_seconds, 3600 when absent, capped by the plan timer), so a box
# runs only long enough for its workers rather than the whole plan timer.
# state/.boat-environment binds each selected box id, boot instance, and
# fm-code. The old .boat-no-env receipt cannot authorize a send.
# Running metadata must name environment fm-code; a present noEnv flag must
# be false. Permanently no-env boxes refuse dispatch.
# A running box must already have a readable timer within that budget window;
# this command never extends it. fm-boat-idle-check.sh owns the PC-side
# extend while workers are live and the idle stop after its grace. No box
# creation/deletion/sharing, billing, plan, credit, environment editing, or
# merge command exists here.
#
# Requests never carry Git identity or credentials. The worker derives its
# identity from the GitHub connection injected on the box by fm-code.
# Dispatch returns success only after the remote worker confirms fresh status.
# FM_BOAT_BIN selects the CLI (boat); fm-boat-alias-refresh.sh owns SSH refresh,
# and a stop made here parks the boat-prove alias at once through its --park.
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
# shellcheck source=bin/fm-boat-budget-lib.sh
. "$SCRIPT_DIR/fm-boat-budget-lib.sh"
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
fm_boat_load_reservation || die "invalid config/boat-spend.json${FM_BOAT_SPEND_PROBLEM:+: $FM_BOAT_SPEND_PROBLEM}"
BOX_CONFIG="$FM_HOME/config/boat-box-id"
BOX_ID_TEXT=$(fm_boat_read_box_ids "$BOX_CONFIG" 2>&1) || die "${BOX_ID_TEXT:-invalid config/boat-box-id}"
mapfile -t BOX_IDS <<< "$BOX_ID_TEXT"
if [ "${#BOX_IDS[@]}" -eq 1 ]; then
  MULTI=0
  BOX=${BOX_IDS[0]}
else
  MULTI=1
  BOX=
fi
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
    grep -Fxq -- "$BOX $1 fm-code" "$ENV_RECEIPT"
}
receipt_drop_box() {
  local kept
  [ -f "$ENV_RECEIPT" ] && [ ! -L "$ENV_RECEIPT" ] || return 0
  kept=$(awk -v id="$BOX" '$1 != id' "$ENV_RECEIPT") || return 1
  if [ -n "$kept" ]; then
    printf '%s\n' "$kept" > "$ENV_RECEIPT"
  else
    rm -f -- "$ENV_RECEIPT"
  fi
}
receipt_store() {
  if [ "$MULTI" -eq 1 ]; then
    receipt_drop_box || return 1
    printf '%s %s fm-code\n' "$BOX" "$instance" >> "$ENV_RECEIPT"
  else
    printf '%s %s fm-code\n' "$BOX" "$instance" > "$ENV_RECEIPT"
  fi
}
publish_route_box() {
  local dest
  [ "$MULTI" -eq 1 ] || return 0
  [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || die 'unsafe state directory'
  dest="$FM_HOME/state/.boat-route-box"
  if [ -e "$dest" ] && { [ -L "$dest" ] || [ ! -f "$dest" ]; }; then
    die 'unsafe route box record'
  fi
  printf '%s\n' "$BOX" > "$dest"
}
record_task_box() {
  local id file tmp
  id=$(jq -r .id "$TMP/request")
  file="$FM_HOME/state/.boat-task-box"
  [ ! -L "$file" ] || die 'unsafe task box record'
  tmp="$TMP/task-box"
  if [ -f "$file" ]; then
    awk -v id="$id" '$1 != id' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s %s\n' "$id" "$BOX" >> "$tmp"
  mv "$tmp" "$file"
}
stop_current_instance() {
  local current
  current=$(boat_instance) && [ "$current" = "$instance" ] && receipt_matches "$current" || return 1
  fm_run_timed 30 "$BOAT_BIN" --no-update stop "$BOX" --json >/dev/null || return 1
  if [ "$MULTI" -eq 1 ]; then
    receipt_drop_box || return 1
  else
    rm -f -- "$ENV_RECEIPT"
  fi
  # Park the alias now; fm-on.sh's own check would otherwise do it at the next call.
  FM_BOAT_BIN="$BOAT_BIN" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" --park "$BOX" boat-prove >/dev/null || return 1
}
REG="${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md"
if [ "$PREPARE" -eq 0 ]; then
  [ "$(secondmate_registry_field "$REG" "$ROUTE" host)" = boat-prove ] || die 'boat-eng must use boat-prove'
  REMOTE_HOME=$(secondmate_registry_field "$REG" "$ROUTE" home) || die 'missing boat-eng home'
  case "$REMOTE_HOME" in /home/user/*) ;; *) die 'boat-eng must have a dedicated sandbox home' ;; esac
  [ "$REMOTE_HOME" != /home/user/fm-home ] || die 'the earlier proof mate home is not an overflow home'
fi
if [ -n "$TEARDOWN_ID" ]; then
  if [ "$MULTI" -eq 1 ]; then
    BOX=
    if [ -L "$FM_HOME/state/.boat-task-box" ]; then
      die 'unsafe task box record'
    elif [ -f "$FM_HOME/state/.boat-task-box" ]; then
      BOX=$(awk -v id="$TEARDOWN_ID" '$1 == id { print $2; exit }' "$FM_HOME/state/.boat-task-box" 2>/dev/null || true)
    fi
    if [ -z "$BOX" ]; then
      [ ! -L "$ENV_RECEIPT" ] || die 'unsafe environment receipt path'
      if [ -f "$ENV_RECEIPT" ]; then
        BOX=$(awk 'NF { print $1 }' "$ENV_RECEIPT" | sort -u)
      fi
      case "$BOX" in
        *$'\n'*) die 'task box is not recorded' ;;
      esac
    fi
    [ -n "$BOX" ] || die 'task box is not recorded'
    printf '%s\n' "${BOX_IDS[@]}" | grep -Fxq -- "$BOX" || die 'task box is not an approved box'
    publish_route_box
  fi
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
    stop_current_instance >/dev/null || die "$1; dispatch refused (current-instance stop unavailable)"
    die "$1; dispatch refused (stopped $BOX)"
  fi
  die "$1; dispatch refused"
}
read_boat() {
  fm_run_timed 15 "$BOAT_BIN" --no-update "$@" --json > "$TMP/$1" 2>/dev/null || stop_refuse "Boat $1 read unavailable"
  jq -e 'type == "object"' "$TMP/$1" >/dev/null 2>&1 || stop_refuse "Boat $1 returned invalid JSON"
}
read_boat_soft() {
  fm_run_timed 15 "$BOAT_BIN" --no-update "$@" --json > "$TMP/$1" 2>/dev/null || return 1
  jq -e 'type == "object"' "$TMP/$1" >/dev/null 2>&1
}
reserve_ttl() {
  jq -nr --slurpfile l "$TMP/limits" --slurpfile b "$TMP/list" \
    --slurpfile i "$TMP/info" --slurpfile u "$TMP/usage" --arg box "$BOX" --argjson now "$(date +%s)" \
    --argjson monthly_usd "$FM_BOAT_MONTHLY_USD" --argjson account "$FM_BOAT_ACCOUNT_SECONDS" \
    --argjson box_seconds "$FM_BOAT_BOX_SECONDS" --argjson box_legacy "$FM_BOAT_BOX_LEGACY" \
    --argjson max_boxes "$FM_BOAT_MAX_BOXES" --argjson short "$FM_BOAT_RESUME_TTL" \
    --argjson allowed "$(printf '%s\n' "${BOX_IDS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
    def nonneg: type == "number" and . >= 0;
    $l[0] as $l | $b[0] as $b | $i[0].sandbox as $i | $u[0] as $u |
    (if $l.billingStatus == "active" then 14400 elif $l.billingStatus == "trialing" then 7200 else error("plan is off") end) as $max_ttl |
    (if $short < $max_ttl then $short else $max_ttl end) as $new_ttl |
    (if $i.state == "stopped" then $new_ttl
     elif ($i.state | IN("ready", "idle", "running")) and ($i.archiveAfter | type) == "string" then
       ($i.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now
     else error("unreadable Boat timer") end) as $ttl |
    (if ($b.sandboxes | type) == "array" and ($l.activeStates | type) == "array" then
       [ $b.sandboxes[] | select(.state as $s | ($l.activeStates | index($s)) != null) ]
     else [] end) as $live |
    ([ $live[] | select(.id != $box) |
       if (.archiveAfter | type) != "string" then error("unreadable Boat timer")
       else (.archiveAfter | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now
       end | if . > 0 then . else 0 end
     ] | add // 0) as $others |
    if $ttl <= 0 or $ttl > $max_ttl or ($i.state == "stopped" and $l.canStart != true) or $l.creditSecondsPerDollar != 100000 or
       ($l.creditUsedSeconds | nonneg | not) or ($l.last24hUsageSeconds | nonneg | not) or
       ($l.creditBalanceSeconds | nonneg | not) or
       $b.pageInfo.hasMore != false or ($b.sandboxes | type) != "array" or
       ($l.activeStates | type) != "array" or
       any($b.sandboxes[]; (.state | type) != "string") or
       ($live | length) > $max_boxes or any($live[]; .id as $id | ($allowed | index($id)) == null) or
       $i.id != $box or $i.type != "default" or
       $u.sandboxId != $box or $u.sandboxType != "default" or $u.secondsPerDollar != 100000 or
       $u.billingMultiplier != 1 or ($u.seconds | nonneg | not)
    then error("unreadable or unsafe Boat state")
    elif $l.creditUsedSeconds + $ttl + $others >= ($monthly_usd * $l.creditSecondsPerDollar) or
         $l.last24hUsageSeconds + $ttl + $others >= $account or
         (if $box_legacy == 1 then $u.seconds + $ttl >= $box_seconds else $u.seconds > $box_seconds end) or
         $l.creditBalanceSeconds < ($ttl + $others)
    then error("spend cap would be exceeded")
    else $ttl end'
}
dispatch_prepared_box() {
  case "$STATE" in
    stopped)
      fm_run_timed 120 "$BOAT_BIN" --no-update resume "$BOX" --environment fm-code --ttl "$TTL" --json > "$TMP/resume" || stop_refuse 'Boat resume failed'
      STOP_ON_REFUSAL=1
      instance=$(boat_instance) || stop_refuse 'Boat instance identity is unavailable'
      if ! { [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] && [ ! -L "$ENV_RECEIPT" ] &&
        { [ ! -e "$ENV_RECEIPT" ] || [ -f "$ENV_RECEIPT" ]; }; }; then
        stop_refuse 'unsafe environment receipt path'
      fi
      receipt_store || stop_refuse 'unsafe environment receipt path'
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
  publish_route_box
  FM_BOAT_BIN="$BOAT_BIN" "$SCRIPT_DIR/fm-boat-alias-refresh.sh" "$BOX" boat-prove || stop_refuse 'SSH refresh or hydration failed'
  if [ "$PREPARE" -eq 1 ]; then
    printf 'prepared: %s route=%s (no worker dispatched)\n' "$BOX" "$ROUTE"
    exit 0
  fi
  record_task_box
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
  if [ "$MULTI" -eq 1 ] && [ "$DISPATCH_STATUS" -eq 75 ]; then
    return 0
  fi
  exit "$DISPATCH_STATUS"
}
if [ "$MULTI" -eq 1 ]; then
  read_boat limits
  read_boat list --all
  order=$(jq -nr --slurpfile b "$TMP/list" --slurpfile l "$TMP/limits" \
    --argjson ids "$(printf '%s\n' "${BOX_IDS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
      def live($s): ($l[0].activeStates | type) == "array" and (($l[0].activeStates | index($s)) != null);
      [ $ids | to_entries[] | . as $e |
        ([ $b[0].sandboxes[]? | select(.id == $e.value) ] | first) as $s |
        {id: $e.value, ord: $e.key,
         rank: (if $s != null and ($s.state | type) == "string" and live($s.state) then 0 else 1 end)}
      ] | sort_by(.rank, .ord) | .[].id
    ' 2>/dev/null) || stop_refuse 'Boat safety or spend reservation failed'
  PINNED=
  if [ -L "$FM_HOME/state/.boat-task-box" ]; then
    die 'unsafe task box record'
  elif [ -f "$FM_HOME/state/.boat-task-box" ]; then
    PINNED=$(awk -v id="$(jq -r .id "$TMP/request")" '$1 == id { print $2; exit }' "$FM_HOME/state/.boat-task-box")
  fi
  if [ -n "$PINNED" ]; then
    printf '%s\n' "${BOX_IDS[@]}" | grep -Fxq -- "$PINNED" || die 'task box is not an approved box'
    order=$PINNED
  fi
  while IFS= read -r BOX; do
    [ -n "$BOX" ] || continue
    STOP_ON_REFUSAL=0
    read_boat_soft info "$BOX" || continue
    STATE=$(jq -r '.sandbox.state // empty' "$TMP/info")
    jq -e '.sandbox.noEnv == true' "$TMP/info" >/dev/null 2>&1 && continue
    case "$STATE" in stopped|ready|idle|running) ;; *) continue ;; esac
    read_boat_soft usage "$BOX" --since "$(( $(date +%s) - 86400 ))" || continue
    TTL=$(reserve_ttl 2> "$TMP/reason") || continue
    if [ "$STATE" != stopped ]; then
      inst=$(boat_instance) || continue
      receipt_matches "$inst" || continue
    fi
    dispatch_prepared_box
  done <<< "$order"
  if [ -n "${PINNED:-}" ]; then
    die "assigned box $PINNED cannot take this task; dispatch refused"
  fi
  die 'no listed box has spend room and worker capacity; dispatch refused'
fi
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
TTL=$(reserve_ttl 2> "$TMP/reason") || stop_refuse 'Boat safety or spend reservation failed'
dispatch_prepared_box
