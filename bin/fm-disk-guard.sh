#!/usr/bin/env bash
# fm-disk-guard.sh - sample memory and disk, and pause new spawns before a stall.
#
# Usage:
#   FM_HOME=<home> fm-disk-guard.sh sample
#   fm-disk-guard.sh --help
#
# FM_HOME is required and must be a real directory, not `/` or anything under
# `/mnt`. The pause flag is `state/disk-guard.pause` in the root Firstmate
# home (`fm_firstmate_root_home` in bin/fm-wake-lib.sh).
# bin/fm-spawn.sh owns admission behavior for that flag.
# This script removes a regular pause flag only when every monitored reading
# is present and healthy, and it never removes a symlink.
#
# Optional `config/disk-guard` in the root home replaces any default below.
# One directive per line. `#` comments and blank lines are ignored.
#
#   ram-floor-kib 8388608
#   root-free-floor-kib 104857600
#   c-free-floor-kib 104857600
#   d-free-floor-kib 104857600
#   linux-used-pct 70
#   lead-seconds 1800
#   vhdx <absolute-path>
#
# The floors are KiB. Available RAM below its floor, free space on `/`,
# `/mnt/c`, or `/mnt/d` below that mount's floor, or the Linux filesystem
# that holds FM_HOME at or above linux-used-pct is pressure now. `/mnt/c`
# and `/mnt/d` are monitored only when that path is a real directory.
# Between samples 30 seconds to 2 hours apart, pressure is also true when a
# falling free-space reading or a rising Linux percentage would cross its
# line inside lead-seconds. The comparison is
# `distance * elapsed <= lead * change`, in integers. A missing reading is
# not pressure by itself. When a pause flag already exists and any monitored
# reading is absent, the flag stays and the sample logs action=held-unknown.
# The flag is removed only when every monitored reading is present and
# healthy. The first sample has no projection.
#
# Each `df` read is bounded to 15 seconds through fm_run_timed in
# bin/fm-timeout-lib.sh. A timeout or a failed read is an absent reading.
#
# Each sample appends one line to `$FM_HOME/state/disk-guard.log` and keeps
# the last 2000 lines. A symlink at the log or the previous-sample path is
# left untouched. The line records available RAM, free swap, Linux size,
# used, available, and percent, free space on `/`, `C:`, and `D:`, the
# virtual-disk file size, alert=ok|low|unknown, and the decision.
# alert=low means a free-space floor is already crossed or will be inside
# the lead window. That is the low-disk alert.
#
# Entering pressure appends one `check` wake with key `disk-guard`. That wake
# is the alert. bin/fm-jev-mem-guard.sh only prints a verdict and, with
# `--check`, exits 1 on warning or critical. It is not scheduled. This
# sample's wake is the scheduled alert beside that check.
# The same transition runs `fm-data-manage.sh clean` once when the root
# home's `config/data-management` is regular, adding `--live` only when
# `config/data-management.live-authorized` is also regular. A later healthy
# sample removes a regular flag and wakes once. This script does not trim
# the page cache. It may stat the configured virtual-disk file and read free
# space on `/`, `/mnt/c`, and `/mnt/d`. It does not walk `/mnt`.
#
# Exit 0 means a sample was recorded, or another live run holds the lock.
# Exit 1 means the home, config, or sample could not be trusted. Exit 2
# means the command line was wrong.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -euo pipefail/{ /^#/ {s/^# \{0,1\}//;p;} }' "$0"
}

die() {
  printf 'fm-disk-guard: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

is_uint_token() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

norm_uint() {
  local n=$1
  is_uint_token "$n" || return 1
  while [ "${#n}" -gt 1 ] && [ "${n#0}" != "$n" ]; do
    n=${n#0}
  done
  [ "${#n}" -lt 15 ] || { [ "${#n}" -eq 15 ] && [ "$n" -lt 106751991167301 ]; } || return 1
  printf '%s\n' "$n"
}

LOCK_DIR=
LOCK_FD=
ROOT=
RAM_FLOOR=8388608
ROOT_FLOOR=104857600
C_FLOOR=104857600
D_FLOOR=104857600
LINUX_PCT=70
LEAD=1800
VHDX=
DF_SECONDS=15
RAM_AVAIL=absent
SWAP_FREE=absent
LINUX_PCT_NOW=absent
LINUX_SIZE=absent
LINUX_USED=absent
LINUX_AVAIL=absent
ROOT_FREE=absent
C_FREE=absent
D_FREE=absent
VHDX_BYTES=absent
PREV_AT=
PREV_RAM=
PREV_ROOT=
PREV_C=
PREV_D=
PREV_LINUX=
ALERT=ok
REASONS=
SAMPLE_BLOCKED=0

take_lock() {
  LOCK_DIR="$STATE/disk-guard.lock"
  exec {LOCK_FD}<"$STATE" || die "could not open lock directory $STATE"
  if ! flock -n "$LOCK_FD"; then
    printf 'fm-disk-guard: another run holds %s\n' "$LOCK_DIR" >&2
    LOCK_DIR=
    exit 0
  fi
  if [ -L "$LOCK_DIR" ]; then
    die "lock path is a symlink: $LOCK_DIR"
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    rm -rf -- "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "could not take lock $LOCK_DIR"
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "could not record lock pid"
}

release_lock() {
  local old=
  [ -n "$LOCK_DIR" ] || return 0
  if [ -f "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ]; then
    old=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  fi
  if [ "$old" = "$$" ]; then
    rm -rf -- "$LOCK_DIR"
  fi
  LOCK_DIR=
  [ -z "$LOCK_FD" ] || exec {LOCK_FD}<&-
}

load_guard_config() {
  local file=$ROOT/config/disk-guard line key val nwords
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || die "disk-guard config must be a regular file: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
    esac
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    nwords=$#
    key=$1
    val=${2:-}
    case "$key" in
      ram-floor-kib|root-free-floor-kib|c-free-floor-kib|d-free-floor-kib|linux-used-pct|lead-seconds)
        [ "$nwords" -eq 2 ] || die "disk-guard config directive needs one number: $line"
        val=$(norm_uint "$val") || die "disk-guard config number is invalid: $line"
        ;;
    esac
    case "$key" in
      ram-floor-kib) RAM_FLOOR=$val ;;
      root-free-floor-kib) ROOT_FLOOR=$val ;;
      c-free-floor-kib) C_FLOOR=$val ;;
      d-free-floor-kib) D_FLOOR=$val ;;
      linux-used-pct)
        [ "$val" -ge 1 ] && [ "$val" -le 99 ] || die "linux-used-pct must be 1-99: $line"
        LINUX_PCT=$val
        ;;
      lead-seconds)
        [ "$val" -ge 60 ] && [ "$val" -le 86400 ] || die "lead-seconds must be 60-86400: $line"
        LEAD=$val
        ;;
      vhdx)
        [ "$nwords" -eq 2 ] || die "vhdx takes one path: $line"
        case "$val" in
          /*) ;;
          *) die "vhdx path must be absolute: $line" ;;
        esac
        case "$val" in
          */) die "vhdx path must not end with a slash: $line" ;;
          *[!A-Za-z0-9._/+:@-]*) die "vhdx path has an unsupported character: $line" ;;
        esac
        VHDX=$val
        ;;
      *) die "unknown disk-guard directive: $line" ;;
    esac
  done < "$file"
}

mount_real() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

read_df_fields() {
  local target=$1 kind=$2 line cap used avail size rc=0
  line=$(fm_run_timed "$DF_SECONDS" df -kP "$target" 2>/dev/null | awk 'NR==2 { print }') || rc=$?
  if fm_timed_out "$rc" || [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    return 0
  fi
  size=$(printf '%s\n' "$line" | awk '{ print $2 }')
  used=$(printf '%s\n' "$line" | awk '{ print $3 }')
  avail=$(printf '%s\n' "$line" | awk '{ print $4 }')
  cap=$(printf '%s\n' "$line" | awk '{ print $5 }')
  cap=${cap%\%}
  case "$kind" in
    linux)
      LINUX_SIZE=$(norm_uint "$size" 2>/dev/null || printf 'absent')
      LINUX_USED=$(norm_uint "$used" 2>/dev/null || printf 'absent')
      LINUX_AVAIL=$(norm_uint "$avail" 2>/dev/null || printf 'absent')
      LINUX_PCT_NOW=$(norm_uint "$cap" 2>/dev/null || printf 'absent')
      ;;
    root) ROOT_FREE=$(norm_uint "$avail" 2>/dev/null || printf 'absent') ;;
    c) C_FREE=$(norm_uint "$avail" 2>/dev/null || printf 'absent') ;;
    d) D_FREE=$(norm_uint "$avail" 2>/dev/null || printf 'absent') ;;
  esac
}

load_live_metrics() {
  if [ -r /proc/meminfo ]; then
    RAM_AVAIL=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
    SWAP_FREE=$(awk '/^SwapFree:/ { print $2; exit }' /proc/meminfo)
    RAM_AVAIL=$(norm_uint "$RAM_AVAIL" 2>/dev/null || printf 'absent')
    SWAP_FREE=$(norm_uint "$SWAP_FREE" 2>/dev/null || printf 'absent')
  fi
  read_df_fields / root
  read_df_fields "$FM_HOME" linux
  if mount_real /mnt/c; then
    read_df_fields /mnt/c c
  fi
  if mount_real /mnt/d; then
    read_df_fields /mnt/d d
  fi
  if [ -n "$VHDX" ]; then
    if [ -L "$VHDX" ]; then
      VHDX_BYTES=error
    elif [ -f "$VHDX" ]; then
      VHDX_BYTES=$(stat -c '%s' -- "$VHDX" 2>/dev/null || true)
      VHDX_BYTES=$(norm_uint "$VHDX_BYTES" 2>/dev/null || printf 'error')
    else
      VHDX_BYTES=absent
    fi
  fi
}

load_previous() {
  local file=$STATE/disk-guard.sample line key val
  PREV_AT=
  PREV_RAM=
  PREV_ROOT=
  PREV_C=
  PREV_D=
  PREV_LINUX=
  if [ -L "$file" ]; then
    SAMPLE_BLOCKED=1
    return 0
  fi
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*)
        key=${line%%=*}
        val=${line#*=}
        ;;
      *) continue ;;
    esac
    case "$key" in
      at) PREV_AT=$(norm_uint "$val" 2>/dev/null || true) ;;
      ram_avail_kib) PREV_RAM=$(norm_uint "$val" 2>/dev/null || true) ;;
      root_free_kib) PREV_ROOT=$(norm_uint "$val" 2>/dev/null || true) ;;
      c_free_kib) PREV_C=$(norm_uint "$val" 2>/dev/null || true) ;;
      d_free_kib) PREV_D=$(norm_uint "$val" 2>/dev/null || true) ;;
      linux_used_pct) PREV_LINUX=$(norm_uint "$val" 2>/dev/null || true) ;;
    esac
  done < "$file"
}

crossing_soon() {
  local cur=$1 prev=$2 floor=$3 dt=$4 mode=$5 dist change
  is_uint_token "$cur" || return 1
  is_uint_token "$prev" || return 1
  [ "$dt" -ge 30 ] && [ "$dt" -le 7200 ] || return 1
  if [ "$mode" = low ]; then
    [ "$prev" -gt "$cur" ] || return 1
    [ "$cur" -ge "$floor" ] || return 1
    dist=$((cur - floor))
    change=$((prev - cur))
  else
    [ "$cur" -gt "$prev" ] || return 1
    [ "$cur" -lt "$floor" ] || return 1
    dist=$((floor - cur))
    change=$((cur - prev))
  fi
  [ $((dist * dt)) -le $((LEAD * change)) ]
}

add_reason() {
  if [ -z "$REASONS" ]; then
    REASONS=$1
  else
    REASONS=$REASONS,$1
  fi
}

decide() {
  local now=$1 dt=0
  REASONS=
  if is_uint_token "$PREV_AT"; then
    dt=$((now - PREV_AT))
  fi
  if is_uint_token "$RAM_AVAIL"; then
    if [ "$RAM_AVAIL" -lt "$RAM_FLOOR" ]; then
      add_reason ram
    elif crossing_soon "$RAM_AVAIL" "$PREV_RAM" "$RAM_FLOOR" "$dt" low; then
      add_reason ram-soon
    fi
  fi
  if is_uint_token "$C_FREE"; then
    if [ "$C_FREE" -lt "$C_FLOOR" ]; then
      add_reason c-free
    elif crossing_soon "$C_FREE" "$PREV_C" "$C_FLOOR" "$dt" low; then
      add_reason c-free-soon
    fi
  fi
  if is_uint_token "$D_FREE"; then
    if [ "$D_FREE" -lt "$D_FLOOR" ]; then
      add_reason d-free
    elif crossing_soon "$D_FREE" "$PREV_D" "$D_FLOOR" "$dt" low; then
      add_reason d-free-soon
    fi
  fi
  if is_uint_token "$ROOT_FREE"; then
    if [ "$ROOT_FREE" -lt "$ROOT_FLOOR" ]; then
      add_reason root-free
    elif crossing_soon "$ROOT_FREE" "$PREV_ROOT" "$ROOT_FLOOR" "$dt" low; then
      add_reason root-free-soon
    fi
  fi
  if is_uint_token "$LINUX_PCT_NOW"; then
    if [ "$LINUX_PCT_NOW" -ge "$LINUX_PCT" ]; then
      add_reason linux
    elif crossing_soon "$LINUX_PCT_NOW" "$PREV_LINUX" "$LINUX_PCT" "$dt" high; then
      add_reason linux-soon
    fi
  fi
}

write_pause_flag() {
  local flag=$ROOT/state/disk-guard.pause tmp now=$1
  if [ -L "$ROOT/state" ]; then
    printf 'symlink\n'
    return 0
  fi
  (umask 077; mkdir -p -- "$ROOT/state")
  if [ -L "$flag" ]; then
    printf 'symlink\n'
    return 0
  fi
  if [ -f "$flag" ]; then
    printf 'exists\n'
    return 0
  fi
  tmp=$(mktemp "$ROOT/state/disk-guard.pause.XXXXXX") || return 1
  printf 'paused at=%s reason=%s\n' "$now" "$REASONS" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -e "$flag" ] || [ -L "$flag" ]; then
    rm -f -- "$tmp"
    printf 'exists\n'
    return 0
  fi
  mv -f -- "$tmp" "$flag" || return 1
  printf 'created\n'
}

clear_pause_flag() {
  local flag=$ROOT/state/disk-guard.pause
  if [ -L "$flag" ]; then
    printf 'symlink\n'
    return 0
  fi
  if [ -f "$flag" ]; then
    rm -f -- "$flag"
    printf 'cleared\n'
    return 0
  fi
  printf 'absent\n'
}

announce() {
  local kind=$1 payload=$2 mark=$STATE/disk-guard.announced
  if [ -L "$mark" ]; then
    return 0
  fi
  case "$kind" in
    pause)
      if [ -f "$mark" ] && [ "$(cat "$mark" 2>/dev/null || true)" = "$payload" ]; then
        return 0
      fi
      fm_wake_append check disk-guard "$payload" || return 1
      printf '%s\n' "$payload" > "$mark"
      ;;
    clear)
      fm_wake_append check disk-guard "$payload" || return 1
      [ ! -L "$mark" ] && rm -f -- "$mark"
      ;;
  esac
}

run_cleanup() {
  local cfg=$ROOT/config/data-management marker=$ROOT/config/data-management.live-authorized out=$STATE/disk-guard.cleanup rc=0
  if [ ! -f "$cfg" ] || [ -L "$cfg" ]; then
    printf 'none\n'
    return 0
  fi
  if [ -L "$out" ]; then
    printf 'skipped\n'
    return 0
  fi
  if [ -f "$marker" ] && [ ! -L "$marker" ] && [ ! -L "$ROOT/config" ]; then
    fm_run_timed 900 bash "$SCRIPT_DIR/fm-data-manage.sh" clean --config "$cfg" --live > "$out" 2>&1 || rc=$?
  else
    fm_run_timed 900 bash "$SCRIPT_DIR/fm-data-manage.sh" clean --config "$cfg" > "$out" 2>&1 || rc=$?
  fi
  printf '%s\n' "$rc"
}

append_log() {
  local log=$STATE/disk-guard.log line=$1 lines tmp
  if [ -L "$log" ]; then
    printf 'fm-disk-guard: log is a symlink, not writing\n' >&2
    return 0
  fi
  printf '%s\n' "$line" >> "$log" || return 1
  lines=$(wc -l < "$log")
  lines=${lines//[[:space:]]/}
  if is_uint_token "$lines" && [ "$lines" -gt 2000 ]; then
    tmp=$(mktemp "$STATE/disk-guard.log.XXXXXX") || return 1
    tail -n 2000 "$log" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$log"
  fi
}

write_sample() {
  local file=$STATE/disk-guard.sample tmp now=$1
  if [ "$SAMPLE_BLOCKED" -eq 1 ] || [ -L "$file" ]; then
    return 0
  fi
  tmp=$(mktemp "$STATE/disk-guard.sample.XXXXXX") || return 1
  cat > "$tmp" <<EOF
at=$now
ram_avail_kib=$RAM_AVAIL
swap_free_kib=$SWAP_FREE
linux_used_pct=$LINUX_PCT_NOW
linux_size_kib=$LINUX_SIZE
linux_used_kib=$LINUX_USED
linux_avail_kib=$LINUX_AVAIL
root_free_kib=$ROOT_FREE
c_free_kib=$C_FREE
d_free_kib=$D_FREE
vhdx_bytes=$VHDX_BYTES
EOF
  mv -f -- "$tmp" "$file"
}

reading_incomplete() {
  if [ -r /proc/meminfo ] && ! is_uint_token "$RAM_AVAIL"; then
    return 0
  fi
  is_uint_token "$LINUX_PCT_NOW" || return 0
  is_uint_token "$ROOT_FREE" || return 0
  if mount_real /mnt/c && ! is_uint_token "$C_FREE"; then
    return 0
  fi
  if mount_real /mnt/d && ! is_uint_token "$D_FREE"; then
    return 0
  fi
  return 1
}

pause_present() {
  local flag=$ROOT/state/disk-guard.pause
  [ -f "$flag" ] || [ -L "$flag" ]
}

set_alert() {
  ALERT=ok
  case ",${REASONS:-}," in
    *,c-free,*|*,c-free-soon,*|*,d-free,*|*,d-free-soon,*|*,root-free,*|*,root-free-soon,*)
      ALERT=low
      ;;
    *)
      if reading_incomplete; then
        ALERT=unknown
      fi
      ;;
  esac
}

sample_once() {
  local now flag_state action cleanup_state pressure=no line
  now=$(date +%s)
  load_guard_config
  load_live_metrics
  load_previous
  decide "$now"
  set_alert
  if [ -n "$REASONS" ]; then
    pressure=yes
    flag_state=$(write_pause_flag "$now") || die "could not write the pause flag"
    case "$flag_state" in
      created)
        action=paused
        announce pause "disk-guard pause reasons=$REASONS" || die "could not record the pressure wake"
        cleanup_state=$(run_cleanup) || cleanup_state=failed
        case "$cleanup_state" in
          none) ;;
          *) action="${action}-cleanup-${cleanup_state}" ;;
        esac
        ;;
      exists)
        action="already-paused"
        announce pause "disk-guard pause reasons=$REASONS" || die "could not record the pressure wake"
        ;;
      symlink)
        action="pause-symlink"
        announce pause "disk-guard pause-symlink reasons=$REASONS" || die "could not record the pressure wake"
        ;;
      *) die "could not write the pause flag" ;;
    esac
  elif reading_incomplete && pause_present; then
    action="held-unknown"
  else
    flag_state=$(clear_pause_flag) || die "could not clear the pause flag"
    case "$flag_state" in
      cleared)
        action=cleared
        announce clear "disk-guard clear" || die "could not record the clear wake"
        ;;
      symlink)
        action="pause-symlink"
        announce pause "disk-guard pause-symlink reasons=none" || die "could not record the pressure wake"
        ;;
      *)
        action=none
        if [ -f "$STATE/disk-guard.announced" ] && [ ! -L "$STATE/disk-guard.announced" ]; then
          rm -f -- "$STATE/disk-guard.announced"
        fi
        ;;
    esac
  fi
  line=$(printf '%s ram_avail_kib=%s swap_free_kib=%s linux_used_pct=%s linux_size_kib=%s linux_used_kib=%s linux_avail_kib=%s root_free_kib=%s c_free_kib=%s d_free_kib=%s vhdx_bytes=%s alert=%s pressure=%s reasons=%s action=%s' \
    "$now" "$RAM_AVAIL" "$SWAP_FREE" "$LINUX_PCT_NOW" "$LINUX_SIZE" "$LINUX_USED" "$LINUX_AVAIL" "$ROOT_FREE" "$C_FREE" "$D_FREE" "$VHDX_BYTES" "$ALERT" "$pressure" "${REASONS:-none}" "$action")
  append_log "$line" || die "could not write $STATE/disk-guard.log"
  write_sample "$now" || die "could not write the sample"
  printf '%s\n' "$line"
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    --help|-h|help) usage; exit 0 ;;
    sample) ;;
    '') die_usage ;;
    *) die_usage ;;
  esac
  [ -n "${FM_HOME:-}" ] || die "FM_HOME is required"
  case "$FM_HOME" in
    /*) ;;
    *) die "FM_HOME must be absolute" ;;
  esac
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || die "FM_HOME must be a real directory"
  FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || die "FM_HOME must be a real directory"
  case "$FM_HOME" in
    /|/mnt|/mnt/*) die "FM_HOME is not a home" ;;
  esac
  export FM_HOME
  # A caller environment must not redirect this sample at another home's queue.
  unset STATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  [ -L "$STATE" ] && die "state must not be a symlink"
  ROOT=$(fm_firstmate_root_home "$FM_HOME") || die "could not resolve the root home"
  trap release_lock EXIT
  trap 'exit 1' HUP INT TERM
  take_lock
  sample_once
}

main "$@"
