#!/usr/bin/env bash
# fm-clutter-check.sh - daily read-only machine clutter check.
#
# Usage:
#   fm-clutter-check.sh [check]
#   fm-clutter-check.sh arm
#   fm-clutter-check.sh disarm
#   fm-clutter-check.sh --help
#
# `check` prints one line only when the machine has gathered clutter past a
# threshold, and prints nothing at all otherwise, so it composes with the
# watcher's custom state-check contract: `arm` writes state/clutter.check.sh
# and binds its bytes with fm-check-register.sh, the watcher runs it on its
# FM_CHECK_INTERVAL cadence, and its one line becomes a `check:` wake.
# `disarm` removes the shim, its trust binding, and the records. The check is
# machine-wide, so `arm` refuses in a secondmate home: arm it in the root home.
#
# Conditions reported, joined into the one line:
#   orphans    a gemini -y hello, chrome-devtools-mcp, headless Chrome, or
#              lavish-axi process older than FM_CLUTTER_ORPHAN_SECS (default
#              3600) whose parent is PID 1 or a `systemd --user` subreaper,
#              which is where an exited session's children land
#   worktrees  the no-mistakes pipeline copies under FM_CLUTTER_WORKTREES_ROOT
#              (default ~/.no-mistakes/worktrees) total over
#              FM_CLUTTER_WORKTREES_MB (default 20480), or one copy is over
#              FM_CLUTTER_COPY_MB (default 3072)
#   root       the Linux root filesystem has more than FM_CLUTTER_ROOT_USED_MB
#              (default 153600) in use
#   windows    /mnt/c has less than FM_CLUTTER_WINDOWS_FREE_PCT (default 10)
#              percent free
#   read       a measurement could not finish, because a check that cannot see
#              is not quiet
#
# Nothing is ever killed, deleted, or moved; the check reports and a person
# acts. Measuring every pipeline copy at once can outlast the watcher's
# per-check bound, so each copy's size is cached in state/.clutter-check/sizes
# and a poll measures the copies not yet sized within a budget of
# FM_CLUTTER_MEASURE_BUDGET_SECS (default 18, at most 20) seconds; a copy that
# outlasts the whole budget is a read failure.
# The evaluation is due 86400 seconds after the last one; polls inside that day
# stay silent, a due evaluation waits until every copy has a size measured
# since it fell due, and a condition that persists is reported again at every
# due evaluation. docs/configuration.md "Clutter check" is the operator
# reference.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=clutter
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD_DIR="$STATE/.clutter-check"
RECORD="$RECORD_DIR/last"
SIZES="$RECORD_DIR/sizes"
RECORD_SCHEMA=fm-clutter-check-v1
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1000
INTERVAL=86400
DF_SECS=5
WORKTREES_ROOT="${FM_CLUTTER_WORKTREES_ROOT:-$HOME/.no-mistakes/worktrees}"
WINDOWS_MOUNT="${FM_CLUTTER_WINDOWS_MOUNT:-/mnt/c}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,44{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-clutter-check: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

whole() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$((10#$1))" ;;
  esac
}

ORPHAN_SECS=$(whole "${FM_CLUTTER_ORPHAN_SECS:-}" 3600)
WORKTREES_MB=$(whole "${FM_CLUTTER_WORKTREES_MB:-}" 20480)
COPY_MB=$(whole "${FM_CLUTTER_COPY_MB:-}" 3072)
ROOT_USED_MB=$(whole "${FM_CLUTTER_ROOT_USED_MB:-}" 153600)
WINDOWS_FREE_PCT=$(whole "${FM_CLUTTER_WINDOWS_FREE_PCT:-}" 10)
MEASURE_BUDGET_SECS=$(whole "${FM_CLUTTER_MEASURE_BUDGET_SECS:-}" 18)
[ "$MEASURE_BUDGET_SECS" -ge 1 ] && [ "$MEASURE_BUDGET_SECS" -le 20 ] || MEASURE_BUDGET_SECS=18

now_epoch() {
  case "${FM_CLUTTER_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_CLUTTER_NOW" ;;
  esac
}

gb() {  # <mb>
  awk -v mb="$1" 'BEGIN { printf "%.1f GB", mb / 1024 }'
}

record_dir_ready() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || mkdir -m 700 "$RECORD_DIR" 2>/dev/null
}

replace_file() {  # <file> <content>
  local tmp
  record_dir_ready || return 1
  tmp=$(umask 077; mktemp "$RECORD_DIR/.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$2" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Prints the epoch the current evaluation fell due, nothing when not due.
due_since() {  # <now>
  local now=$1 last
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
    && [ "$(sed -n 1p "$RECORD" 2>/dev/null)" = "schema	$RECORD_SCHEMA" ]; then
    last=$(awk -F '\t' '$1 == "last_eval" { print $2; exit }' "$RECORD" 2>/dev/null)
    case "$last" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$last" -le "$now" ]; then
          [ $((now - last)) -ge "$INTERVAL" ] || return 0
          printf '%s\n' $((last + INTERVAL))
          return 0
        fi
        ;;
    esac
  fi
  printf '0\n'
}

# Orphaned helper processes, as "<label> x<n>" parts joined by ", ".
orphans() {
  ps -eo pid=,ppid=,etimes=,args= 2>/dev/null | awk -v min="$ORPHAN_SECS" '
    {
      pid = $1; ppid[pid] = $2; age[pid] = $3
      args = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, "", args)
      cmd[pid] = args
    }
    END {
      for (pid in cmd) {
        p = ppid[pid]
        if (p != 1 && cmd[p] !~ /(^|\/)systemd --user/) continue
        if (age[pid] < min) continue
        c = cmd[pid]
        if (c ~ /gemini -y hello/) label = "gemini -y hello"
        else if (c ~ /chrome-devtools-mcp/) label = "chrome-devtools-mcp"
        else if (c ~ /lavish-axi/) label = "lavish-axi"
        else if (c ~ /chrom(e|ium)/ && c ~ /--headless/) label = "headless chrome"
        else continue
        n[label]++
      }
      out = ""
      for (l in n) out = out (out == "" ? "" : ", ") l " x" n[l]
      print out
    }'
}

# Measures the stalest pipeline copies not yet measured since <due> within the
# budget, rewriting the size cache. Exit status: 0 every copy has a size from
# since <due>; 1 some copy is still pending or could not be measured.
measure_copies() {  # <due> <now>
  local due=$1 now=$2 started=$SECONDS left name mb rc copies cache next="" pending=0 at
  [ -d "$WORKTREES_ROOT" ] || { replace_file "$SIZES" "" || true; return 0; }
  copies=$(cd "$WORKTREES_ROOT" 2>/dev/null && for name in *; do [ -d "$name" ] && [ ! -L "$name" ] && printf '%s\n' "$name"; done)
  cache=$( [ -f "$SIZES" ] && [ ! -L "$SIZES" ] && cat "$SIZES" 2>/dev/null)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    at=$(printf '%s\n' "$cache" | awk -F '\t' -v n="$name" '$1 == n { print $3; exit }')
    mb=$(printf '%s\n' "$cache" | awk -F '\t' -v n="$name" '$1 == n { print $2; exit }')
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    if [ "$at" -lt "$due" ] || [ "$at" -eq 0 ]; then
      left=$((MEASURE_BUDGET_SECS - (SECONDS - started)))
      if [ "$left" -ge 1 ]; then
        rc=0
        mb=$(fm_run_timed "$left" du -sm -- "$WORKTREES_ROOT/$name" 2>/dev/null </dev/null) || rc=$?
        mb=${mb%%[!0-9]*}
        if [ "$rc" -eq 0 ] && [ -n "$mb" ]; then
          at=$now
        elif [ "$left" -ge "$MEASURE_BUDGET_SECS" ]; then
          mb=timeout
          at=$now
        else
          pending=1
          continue
        fi
      else
        pending=1
        continue
      fi
    fi
    next="$next$name	$mb	$at"$'\n'
  done <<EOF
$copies
EOF
  replace_file "$SIZES" "$next" || true
  [ "$pending" -eq 0 ]
}

worktree_findings() {
  [ -f "$SIZES" ] && [ ! -L "$SIZES" ] || return 0
  awk -F '\t' -v total_max="$WORKTREES_MB" -v copy_max="$COPY_MB" -v budget="$MEASURE_BUDGET_SECS" '
    function gb(mb) { return sprintf("%.1f GB", mb / 1024) }
    $2 == "timeout" { slow = slow (slow == "" ? "" : ", ") $1; next }
    $2 ~ /^[0-9]+$/ {
      total += $2
      if ($2 > copy_max) big = big (big == "" ? "" : ", ") $1 " " gb($2)
    }
    END {
      if (total > total_max) print "no-mistakes worktrees total " gb(total) ", over " gb(total_max)
      if (big != "") print "no-mistakes copies over " gb(copy_max) ": " big
      if (slow != "") print "read failed: could not size " slow " within " budget "s"
    }' "$SIZES"
}

disk_findings() {
  local used free_pct out
  out=$(fm_run_timed "$DF_SECS" df -Pm / 2>/dev/null </dev/null) || out=
  used=$(printf '%s\n' "$out" | awk 'NR == 2 { print $3 }')
  case "$used" in
    ''|*[!0-9]*) echo "read failed: df of / did not answer" ;;
    *) [ "$used" -le "$ROOT_USED_MB" ] || echo "WSL root has $(gb "$used") in use, over $(gb "$ROOT_USED_MB")" ;;
  esac
  [ -d "$WINDOWS_MOUNT" ] || return 0
  out=$(fm_run_timed "$DF_SECS" df -Pm "$WINDOWS_MOUNT" 2>/dev/null </dev/null) || out=
  free_pct=$(printf '%s\n' "$out" | awk 'NR == 2 && $2 > 0 { printf "%d", $4 * 100 / $2 }')
  case "$free_pct" in
    ''|*[!0-9]*) echo "read failed: df of $WINDOWS_MOUNT did not answer" ;;
    *) [ "$free_pct" -ge "$WINDOWS_FREE_PCT" ] || echo "$WINDOWS_MOUNT has ${free_pct}% free, under ${WINDOWS_FREE_PCT}%" ;;
  esac
}

run_check() {
  local now due found orph
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  now=$(now_epoch)
  due=$(due_since "$now")
  [ -n "$due" ] || return 0
  measure_copies "$due" "$now" || return 0
  orph=$(orphans)
  found=$(
    [ -z "$orph" ] || printf 'orphaned processes older than %sm: %s\n' "$((ORPHAN_SECS / 60))" "$orph"
    worktree_findings
    disk_findings
  )
  replace_file "$RECORD" "$(printf 'schema\t%s\nlast_eval\t%s\n' "$RECORD_SCHEMA" "$now")" || true
  [ -n "$found" ] || return 0
  fm_cap_line "clutter: $(printf '%s\n' "$found" | paste -sd ';' - | sed 's/;/; /g')" "$MAX_LINE"
}

SHIM_TMP=

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.clutter-check-shim.XXXXXX" 2>/dev/null) || return 1
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

# A shim without a matching trust binding is rejected by the watcher on every
# cycle, so a failed arm removes both rather than leave one unbound.
arm_failed() {  # <message>
  trap - HUP INT TERM
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  fail "$1"
}

arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  if [ -e "$home/.fm-secondmate-parent" ] || [ -L "$home/.fm-secondmate-parent" ]; then
    fail "this is a secondmate home; the clutter check is machine-wide, arm it in the root home"
  fi
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-clutter-check.sh") check")
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  [ ! -d "$RECORD_DIR" ] || [ -L "$RECORD_DIR" ] || rm -rf -- "$RECORD_DIR"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || die_usage; run_check ;;
  arm) [ "$#" -eq 1 ] || die_usage; arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage; disarm ;;
  -h|--help|help) usage ;;
  *) die_usage ;;
esac
