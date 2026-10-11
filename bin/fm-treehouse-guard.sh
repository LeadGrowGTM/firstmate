#!/usr/bin/env bash
# fm-treehouse-guard.sh - keep treehouse worktree pools from sprawling.
#
# Usage:
#   fm-treehouse-guard.sh prune [--locked] <project-dir>
#   fm-treehouse-guard.sh sweep
#   fm-treehouse-guard.sh [check]
#   fm-treehouse-guard.sh arm
#   fm-treehouse-guard.sh disarm
#   fm-treehouse-guard.sh --help
#
# Treehouse already reuses returned copies, caps a pool (max_trees in that
# repository's treehouse.toml), and has a safe prune.  It does not run that
# prune on its own and does not warn on total size.  This script adds exactly
# those two things and nothing else: it never decides what is stale.  Only
# treehouse does, through `treehouse prune --yes`, which removes a copy only
# when it is merged, clean, idle, and unleased.
#
# The flags are fixed.  A copy is removed only by `treehouse prune --yes` run
# from one project clone, which scopes it to that project's pool.  This script
# never passes --prune-orphans, --include-unlanded, --include-in-use, or
# --include-leased, never combines --all with --yes, and never runs
# `treehouse destroy`.
#
# `prune <project-dir>` runs that safe prune for one project's pool.
# bin/fm-teardown.sh calls it after a successful cleanup.  It refuses a
# directory that is not the root of its own git clone, because treehouse
# resolves the pool from the working directory and would otherwise act on the
# enclosing repository.  It runs under the shared Treehouse project lock
# (fm_treehouse_project_lock_path), so it never overlaps a launch or cleanup
# allocating or returning a copy in the same pool; `--locked` says the caller
# already holds that lock.  A pool another launch or cleanup is using is
# skipped silently, exit 0.  Any other prune that did not run prints one
# `warning:` line and exits 1, which a caller is free to ignore.
#
# One thing treehouse cannot know is which Firstmate task a copy belongs to.
# A worker whose window died leaves its copy idle, and when that copy holds no
# changes treehouse counts it stale although the task record still names it.
# So before pruning, the pool is read with `treehouse status --json`, and a
# pool holding a copy that is neither in use nor leased yet still carries a
# Firstmate slot-owner claim (fm_treehouse_slot_owner_state) is not pruned at
# all; the warning names the copy and the claiming task.  A status that cannot
# be read is treated the same way rather than assumed clear.
#
# `sweep` does the daily work for this home only.  It prunes the pool of each
# clone root under this home's projects directory, so a pool reachable only
# from another home's clones is never pruned from here.  Two homes that clone
# the same origin under the same directory name share one pool by treehouse's
# own design; git still refuses to remove a copy backed by the other clone.
# It then measures the user-level treehouse root ($HOME/.treehouse) with
# du(1), and reads orphaned pools from the report of a `treehouse prune --all`
# dry run, which deletes nothing.  Orphaned pools are reported, never removed.
# The result is one finding line in state/.treehouse-guard.result, also
# printed.  A prune that did not run, a size that could not be measured, and a
# dry run that failed are findings too, never read as "nothing to report".
#
# The size limit is a whole number of gigabytes in the local, gitignored
# config/treehouse-size-limit; absent means 5.  docs/configuration.md owns
# that file and the max_trees guidance.
#
# `check` is the watcher poll.  It prints one line when the last finished
# sweep has a finding that was not reported yet and prints nothing otherwise,
# and it starts a sweep at most once every 86400 seconds.  The sweep runs
# detached in its own process group, because the watcher bounds a check to
# FM_CHECK_TIMEOUT and kills the check's whole group afterwards, and a prune
# cut off part way through is exactly what this guard must not cause.  A
# finding is therefore reported on the poll after its sweep finishes.
#
# `arm` writes state/treehouse-guard.check.sh and binds its bytes with
# fm-check-register.sh so the existing watcher slow-check cadence runs the
# daily gate.  `disarm` removes the shim, its trust binding, and both records.
#
# Each treehouse call is bounded so a hung binary cannot hold the project lock
# or a sweep forever: FM_TREEHOUSE_GUARD_PRUNE_SECS (default 600) for a prune,
# the dry run, or the size measurement, FM_TREEHOUSE_GUARD_PROBE_SECS (default
# 60) for the status read.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CHECK_ID=treehouse-guard
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.treehouse-guard"
RESULT="$STATE/.treehouse-guard.result"
SCHEMA_LINE=$'schema\tfm-treehouse-guard-v1'
SIZE_LIMIT_FILE="$CONFIG_DIR/treehouse-size-limit"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
INTERVAL=86400
DEFAULT_SIZE_LIMIT_GB=5
MAX_LINE=1000

usage() {
  sed -n '2,76{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-check}" in
  -h|--help|help) usage; exit 0 ;;
  check|sweep|arm|disarm|prune) ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

fail() {
  printf 'fm-treehouse-guard: %s\n' "$1" >&2
  exit 1
}

bound_secs() {  # <variable-name> <default>
  local value=${!1:-$2}
  case "$value" in
    ''|*[!0-9]*|0) fail "$1 must be a whole number of seconds from 1 to 3600" ;;
  esac
  [ "$value" -le 3600 ] || fail "$1 must be a whole number of seconds from 1 to 3600"
  printf '%s\n' "$value"
}

PRUNE_SECS=$(bound_secs FM_TREEHOUSE_GUARD_PRUNE_SECS 600) || exit 1
PROBE_SECS=$(bound_secs FM_TREEHOUSE_GUARD_PROBE_SECS 60) || exit 1

now_epoch() {
  case "${FM_TREEHOUSE_GUARD_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TREEHOUSE_GUARD_NOW" ;;
  esac
}

# Git discovery walks up from a directory, so a plain directory under projects/
# resolves to the enclosing repository - in a Firstmate home, the home itself.
project_is_clone_root() {  # <dir>
  local dir=$1 top abs
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  abs=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  [ -n "$top" ] && [ "$top" -ef "$abs" ]
}

# Print "copy <slot> (task <id>)" for every copy treehouse could remove - one
# it reports as neither in use nor leased - that a Firstmate task still claims.
# Nonzero when the pool cannot be read, so the caller never prunes unverified.
claimed_idle_copies() {  # <project-dir>
  local project=$1 json paths path found=''
  json=$(cd "$project" && fm_run_timed "$PROBE_SECS" treehouse status --json 2>/dev/null) || return 1
  # shellcheck disable=SC2016  # single quotes are deliberate: this is JavaScript.
  paths=$(printf '%s' "$json" | node -e '
    let text = "";
    process.stdin.on("data", (chunk) => { text += chunk; }).on("end", () => {
      let rows;
      try { rows = JSON.parse(text); } catch (error) { process.exit(1); }
      if (!Array.isArray(rows)) process.exit(1);
      for (const row of rows) {
        if (!row || typeof row.path !== "string" || typeof row.status !== "string") process.exit(1);
        if (row.path.includes("\n")) process.exit(1);
        if (row.status !== "in-use" && row.status !== "leased") console.log(row.path);
      }
    });' 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    fm_treehouse_slot_owner_state "$path" ""
    [ "$FM_TREEHOUSE_SLOT_OWNER" != absent ] || continue
    found="${found:+$found, }copy $(basename "$(dirname "$path")") (task ${FM_TREEHOUSE_SLOT_OWNER_ID:-unreadable claim})"
  done <<EOF
$paths
EOF
  printf '%s\n' "$found"
}

# Run treehouse's safe prune for one project's pool.  Returns 0 when it ran, 2
# when the pool is in use by a launch or cleanup, and 1 otherwise with the
# reason in GUARD_NOTE.
GUARD_NOTE=
prune_project() {  # <project-dir> <caller-holds-lock:0|1>
  local project=$1 locked=$2 lock='' claims out rc=0
  GUARD_NOTE=
  command -v treehouse >/dev/null 2>&1 || { GUARD_NOTE="treehouse is not installed"; return 1; }
  project_is_clone_root "$project" || { GUARD_NOTE="it is not the root of its own git clone"; return 1; }
  if [ "$locked" != 1 ]; then
    lock=$(fm_treehouse_project_lock_path "$project") \
      || { GUARD_NOTE="its project lock cannot be resolved"; return 1; }
    fm_lock_try_acquire "$lock" || return 2
  fi
  if ! claims=$(claimed_idle_copies "$project"); then
    GUARD_NOTE="its pool could not be read with treehouse status"
    rc=1
  elif [ -n "$claims" ]; then
    GUARD_NOTE="a task still claims an idle copy: $claims"
    rc=1
  else
    out=$(cd "$project" && fm_run_timed "$PRUNE_SECS" treehouse prune --yes 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      if fm_timed_out "$rc"; then
        GUARD_NOTE="treehouse prune did not finish in ${PRUNE_SECS}s"
      else
        out=$(printf '%s\n' "$out" | awk 'NF { last = $0 } END { print last }')
        GUARD_NOTE="treehouse prune exited $rc${out:+: $out}"
      fi
      rc=1
    fi
  fi
  [ -z "$lock" ] || fm_lock_release "$lock" || true
  return "$rc"
}

run_prune() {  # [--locked] <project-dir>
  local locked=0 rc=0
  if [ "${1:-}" = --locked ]; then
    locked=1
    shift
  fi
  [ "$#" -eq 1 ] && [ -n "$1" ] || { usage >&2; exit 2; }
  prune_project "$1" "$locked" || rc=$?
  case "$rc" in
    0|2) return 0 ;;
  esac
  printf 'warning: treehouse prune did not run for %s: %s\n' "$1" "$GUARD_NOTE" >&2
  return 1
}

FINDINGS=
append_finding() {
  FINDINGS="${FINDINGS:+$FINDINGS; }$1"
}

sweep_prunes() {
  local project rc
  [ -d "$PROJECTS" ] || return 0
  command -v treehouse >/dev/null 2>&1 || { append_finding "treehouse is not installed, so no pool was pruned"; return 0; }
  for project in "$PROJECTS"/*/; do
    project=${project%/}
    project_is_clone_root "$project" || continue
    rc=0
    prune_project "$project" 0 || rc=$?
    case "$rc" in
      0|2) ;;
      *) append_finding "prune did not run for $(basename "$project") ($GUARD_NOTE)" ;;
    esac
  done
}

size_limit_gb() {
  local value
  if [ ! -e "$SIZE_LIMIT_FILE" ] && [ ! -L "$SIZE_LIMIT_FILE" ]; then
    printf '%s\n' "$DEFAULT_SIZE_LIMIT_GB"
    return 0
  fi
  [ -f "$SIZE_LIMIT_FILE" ] || return 1
  value=$(tr -d '[:space:]' < "$SIZE_LIMIT_FILE" 2>/dev/null) || return 1
  case "$value" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  [ "${#value}" -le 6 ] || return 1
  printf '%s\n' "$value"
}

sweep_size() {
  local root limit out kib rc=0
  [ -n "${HOME:-}" ] || return 0
  root="$HOME/.treehouse"
  [ -d "$root" ] || return 0
  if ! limit=$(size_limit_gb); then
    append_finding "config/treehouse-size-limit is not a whole number of gigabytes, so size was not checked"
    return 0
  fi
  out=$(fm_run_timed "$PRUNE_SECS" du -sk "$root" 2>/dev/null) || rc=$?
  kib=$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')
  case "$kib" in
    ''|*[!0-9]*)
      append_finding "size of $root could not be measured (du exited $rc)"
      return 0
      ;;
  esac
  [ "$kib" -gt $((limit * 1048576)) ] || return 0
  append_finding "worktree copies use $(awk -v k="$kib" 'BEGIN { printf "%.1f", k / 1048576 }') GB under $root (limit $limit GB)"
}

# Orphaned pools come from treehouse's own dry-run report: under a category
# line naming orphans, each copy line carries a path below the treehouse root,
# whose first component is the pool.
sweep_orphans() {
  local out rc=0 pools count
  command -v treehouse >/dev/null 2>&1 || return 0
  out=$(cd / && fm_run_timed "$PRUNE_SECS" treehouse prune --all 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    append_finding "orphaned pools could not be checked (treehouse prune --all dry run exited $rc)"
    return 0
  fi
  pools=$(printf '%s\n' "$out" | awk '
    /^[ \t]+[^ \t].*:$/ { orphans = ($0 ~ /orphaned/) ? 1 : 0; next }
    /^[ \t]/ {
      if (orphans && match($0, /\/\.treehouse\/[^\/]+\//)) print substr($0, RSTART + 12, RLENGTH - 13)
      next
    }
    { orphans = 0 }' | sort -u)
  [ -n "$pools" ] || return 0
  count=$(printf '%s\n' "$pools" | awk 'END { print NR }')
  append_finding "$count orphaned pool(s) with a missing backing repository, left in place: $(printf '%s\n' "$pools" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')"
}

write_atomically() {  # <tmp> <destination>
  local tmp=$1 dest=$2 state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$state_device" || return 1
  mv -f -- "$tmp" "$dest"
}

record_value() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r line < "$file" || return 0
  [ "$line" = "$SCHEMA_LINE" ] || return 0
  awk -F '\t' -v k="$key" '$1 == k { print substr($0, index($0, "\t") + 1); exit }' "$file" 2>/dev/null || true
}

GUARD_TMP=
publish_record() {  # <destination> <line>...
  local dest=$1
  shift
  GUARD_TMP=$(umask 077; mktemp "$STATE/.treehouse-guard-tmp.XXXXXX") || exit 1
  trap 'rm -f -- "$GUARD_TMP"' EXIT
  printf '%s\n' "$SCHEMA_LINE" "$@" > "$GUARD_TMP" || exit 1
  write_atomically "$GUARD_TMP" "$dest" || fail "could not publish state/${dest##*/}"
  GUARD_TMP=
  trap - EXIT
}

run_sweep() {
  local lines=()
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  FINDINGS=
  sweep_prunes
  sweep_size
  sweep_orphans
  FINDINGS=${FINDINGS//[$'\t\r\n']/ }
  lines=("$(printf '%s\t%s' swept "$(now_epoch)")")
  [ -z "$FINDINGS" ] || lines+=("$(printf '%s\t%s' finding "$FINDINGS")")
  publish_record "$RESULT" "${lines[@]}"
  [ -z "$FINDINGS" ] || fm_cap_line "treehouse-guard: $FINDINGS" "$MAX_LINE"
}

# Its own process group and no inherited stdio: see the header for why the
# sweep must outlive the watcher's bound on this check.
launch_sweep() {
  set -m 2>/dev/null || true
  FM_HOME="$FM_HOME" nohup "$SCRIPT_DIR/fm-treehouse-guard.sh" sweep >/dev/null 2>&1 </dev/null &
  set +m 2>/dev/null || true
}

# The report line goes out before the record advances, so a failed publication
# can repeat a finding but never swallow one.
run_check() {
  local now launched reported finding due=0 changed=0 age lines=()
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  now=$(now_epoch)
  launched=$(record_value "$RECORD" launched)
  reported=$(record_value "$RECORD" reported)
  if [ -n "$(record_value "$RESULT" swept)" ]; then
    finding=$(record_value "$RESULT" finding)
    if [ "$finding" != "$reported" ]; then
      [ -z "$finding" ] || fm_cap_line "treehouse-guard: $finding" "$MAX_LINE"
      reported=$finding
      changed=1
    fi
  fi
  case "$launched" in
    ''|*[!0-9]*) due=1 ;;
    *)
      age=$((now - launched))
      if [ "$age" -lt 0 ] || [ "$age" -ge "$INTERVAL" ]; then
        due=1
      fi
      ;;
  esac
  if [ "$due" -eq 1 ]; then
    launched=$now
    changed=1
  fi
  [ "$changed" -eq 1 ] || return 0
  lines=("$(printf '%s\t%s' launched "$launched")")
  [ -z "$reported" ] || lines+=("$(printf '%s\t%s' reported "$reported")")
  publish_record "$RECORD" "${lines[@]}"
  [ "$due" -eq 0 ] || launch_sweep
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
  SHIM_TMP=$(umask 077; mktemp "$STATE/.treehouse-guard-shim.XXXXXX" 2>/dev/null) || return 1
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
  tmp=$(umask 077; mktemp "$STATE/.treehouse-guard-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

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
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-treehouse-guard.sh") check")
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
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD" "$RESULT"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    run_check
    ;;
  sweep)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    run_sweep
    ;;
  prune)
    shift
    run_prune "$@"
    ;;
  arm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm
    ;;
esac
