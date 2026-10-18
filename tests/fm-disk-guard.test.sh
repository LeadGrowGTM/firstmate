#!/usr/bin/env bash
# Disk pressure pauses new spawns before a floor, and only a healthy sample clears it.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TOOL="$ROOT/bin/fm-disk-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-guard)
trap fm_test_cleanup EXIT

home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/config" "$home/.tmp"
stubbin="$TMP_ROOT/bin"
mkdir -p "$stubbin"
real_awk=$(command -v awk)
real_df=$(command -v df)
cat > "$stubbin/awk" <<EOF
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$2" = /proc/meminfo ]; then
  case "\$1" in
    *MemAvailable:*) printf '%s\n' "\$TEST_RAM_AVAIL" ;;
    *SwapFree:*) printf '%s\n' "\$TEST_SWAP_FREE" ;;
    *) exit 1 ;;
  esac
else
  exec "$real_awk" "\$@"
fi
EOF
cat > "$stubbin/df" <<EOF
#!/bin/sh
if [ "\$1" = -kP ] && [ "\$2" = "\$FM_HOME" ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture %s %s %s %s%% %s\n' "\$TEST_LINUX_SIZE" "\$TEST_LINUX_USED" "\$TEST_LINUX_AVAIL" "\$TEST_LINUX_PCT" "\$2"
elif [ "\$1" = -kP ] && [ "\$2" = /mnt/c ]; then
  if [ "\${TEST_C_MODE:-ok}" = fail ]; then
    exit 1
  fi
  if [ "\${TEST_C_MODE:-ok}" = hang ]; then
    sleep 30
    exit 0
  fi
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture 400000000 200000000 %s 50%% /mnt/c\n' "\$TEST_C_FREE"
elif [ "\$1" = -kP ] && [ "\$2" = / ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture 1000000000 100000000 %s 10%% /\n' "\${TEST_ROOT_FREE:-900000000}"
elif [ "\$1" = -kP ] && [ "\$2" = /mnt/d ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'fixture 1000000000 100000000 %s 10%% /mnt/d\n' "\${TEST_D_FREE:-900000000}"
else
  exec "$real_df" "\$@"
fi
EOF
chmod +x "$stubbin/awk" "$stubbin/df"

set_collector_values() {
  export TEST_RAM_AVAIL=$1 TEST_SWAP_FREE=$2 TEST_LINUX_PCT=$3
  export TEST_LINUX_SIZE=$4 TEST_LINUX_USED=$5 TEST_LINUX_AVAIL=$6 TEST_C_FREE=$7
}

run_guard() {
  FM_HOME="$home" PATH="$stubbin:$PATH" bash "$TOOL" sample
}

reset_guard() {
  rm -f "$home/state/disk-guard.pause" "$home/state/disk-guard.announced" \
    "$home/state/disk-guard.sample" "$home/state/disk-guard.log" \
    "$home/state/disk-guard.cleanup" "$home/state/.wake-queue" \
    "$home/state/.wake-queue.seq" "$home/config/disk-guard" \
    "$home/config/data-management" "$home/config/data-management.live-authorized"
  rm -rf "$home/state/disk-guard.lock" "$home/config/data-management.lock"
}

wake_count() {
  local n=0
  if [ -f "$home/state/.wake-queue" ]; then
    n=$(grep -c 'disk-guard' "$home/state/.wake-queue" || true)
  fi
  printf '%s\n' "$n"
}

write_previous() { # <age-seconds> <ram> <c-free> <linux-pct>
  local now at
  now=$(date +%s)
  at=$((now - $1))
  cat > "$home/state/disk-guard.sample" <<EOF
at=$at
ram_avail_kib=$2
c_free_kib=$3
linux_used_pct=$4
EOF
}

bash "$TOOL" --help >/dev/null

rc=0
env -u FM_HOME bash "$TOOL" sample >/dev/null 2>"$TMP_ROOT/nohome.err" || rc=$?
assert_equals 1 "$rc" "a sample without FM_HOME did not fail"
assert_contains "$(cat "$TMP_ROOT/nohome.err")" "FM_HOME is required" "the refusal names FM_HOME"

set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
printf 'ram-floor-kib nope\n' > "$home/config/disk-guard"
rc=0
run_guard >/dev/null 2>"$TMP_ROOT/bad.err" || rc=$?
assert_equals 1 "$rc" "a bad floor did not fail"
assert_absent "$home/state/disk-guard.pause" "a bad config did not pause spawns"
rm -f "$home/config/disk-guard"

printf 'ram-floor-kib 9223372036854775808\n' > "$home/config/disk-guard"
rc=0
run_guard >/dev/null 2>"$TMP_ROOT/oversized.err" || rc=$?
assert_equals 1 "$rc" "an oversized floor did not fail"
assert_absent "$home/state/disk-guard.pause" "an oversized floor did not pause spawns"
rm -f "$home/config/disk-guard"

set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
mkdir "$home/state/disk-guard.lock"
printf '%s\n' "$$" > "$home/state/disk-guard.lock/pid"
out=$(run_guard)
assert_contains "$out" "pressure=no" "a reused PID did not block a sample"
assert_absent "$home/state/disk-guard.lock" "the recovered lock was released"
mkdir "$home/state/disk-guard.lock"
out=$(run_guard)
assert_contains "$out" "pressure=no" "a missing PID did not block a sample"
assert_absent "$home/state/disk-guard.lock" "the incomplete lock was released"
reset_guard

real_mkdir=$(command -v mkdir)
cat > "$stubbin/mkdir" <<EOF
#!/bin/sh
"$real_mkdir" "\$@" || exit \$?
if [ "\${TEST_DELAY_LOCK:-}" = 1 ] && [ "\$1" = "$home/state/disk-guard.lock" ]; then
  : > "$TMP_ROOT/lock-created"
  sleep 1
fi
EOF
chmod +x "$stubbin/mkdir"
export TEST_DELAY_LOCK=1
run_guard > "$TMP_ROOT/first-sample.out" &
first_sampler=$!
i=0
while [ ! -f "$TMP_ROOT/lock-created" ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "the first sampler did not create its lock"
  sleep 0.01
done
out=$(run_guard 2>&1)
wait "$first_sampler"
assert_contains "$out" "another run holds" "a second sampler did not wait for the owner"
assert_equals 1 "$(wc -l < "$home/state/disk-guard.log" | tr -d '[:space:]')" "two samplers recorded a sample"
unset TEST_DELAY_LOCK
rm -f "$stubbin/mkdir" "$TMP_ROOT/lock-created"
reset_guard

out=$(run_guard)
assert_contains "$out" "pressure=no" "a healthy sample is not pressure"
assert_contains "$out" "action=none" "a healthy sample takes no action"
assert_absent "$home/state/disk-guard.pause" "a healthy sample does not pause spawns"
assert_equals 0 "$(wake_count)" "a healthy sample does not wake"

set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "pressure=yes" "RAM below the floor is pressure"
assert_contains "$out" "reasons=ram" "the reason is the RAM floor"
assert_contains "$out" "action=paused" "the first pressure sample pauses"
assert_present "$home/state/disk-guard.pause" "the pause flag exists"
assert_not_contains "$(cat "$home/state/disk-guard.pause")" "secret" "the pause flag is only the reason"
assert_equals 1 "$(wake_count)" "entering pressure wakes once"
assert_contains "$(cat "$home/state/.wake-queue")" "disk-guard pause reasons=ram" "the wake names the reason"
out=$(run_guard)
assert_contains "$out" "action=already-paused" "pressure that continues does not pause again"
assert_equals 1 "$(wake_count)" "a continued pause does not wake again"

set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "action=cleared" "a healthy sample clears the pause"
assert_absent "$home/state/disk-guard.pause" "the pause flag is gone"
assert_equals 2 "$(wake_count)" "clearing the pause wakes once"
assert_contains "$(cat "$home/state/.wake-queue")" "disk-guard clear" "the wake says the pause cleared"

reset_guard
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
rm -f "$home/state/disk-guard.pause"
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "action=none" "a healthy sample sees the removed pause"
assert_absent "$home/state/disk-guard.announced" "the removed pause clears announcement state"
assert_equals 1 "$(wake_count)" "removing the pause adds no wake"
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
assert_equals 2 "$(wake_count)" "pressure after a removed pause wakes again"

reset_guard
write_previous 600 20000000 200000000 30
set_collector_values 9000000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "reasons=ram-soon" "a RAM fall inside the lead window is pressure"
assert_present "$home/state/disk-guard.pause" "the projected fall pauses spawns"

reset_guard
write_previous 600 9000000 200000000 30
set_collector_values 8900000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "pressure=no" "a slow RAM fall outside the lead window is not pressure"
assert_absent "$home/state/disk-guard.pause" "a slow fall does not pause spawns"

reset_guard
write_previous 600 30000000 200000000 50
set_collector_values 30000000 8000000 68 1000000 680000 320000 200000000
out=$(run_guard)
assert_contains "$out" "reasons=linux-soon" "a Linux rise inside the lead window is pressure"
assert_present "$home/state/disk-guard.pause" "the projected rise pauses spawns"

reset_guard
printf 'keep\n' > "$home/state/pause-target"
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
assert_equals 1 "$(wake_count)" "the regular pressure flag wakes once"
rm -f "$home/state/disk-guard.pause"
ln -s pause-target "$home/state/disk-guard.pause"
out=$(run_guard)
assert_contains "$out" "action=pause-symlink" "a replacement symlink is recognized"
assert_equals 2 "$(wake_count)" "a replacement symlink wakes despite unchanged pressure"
assert_contains "$(cat "$home/state/.wake-queue")" "disk-guard pause-symlink reasons=ram" "the replacement wake names the symlink"
run_guard >/dev/null
assert_equals 2 "$(wake_count)" "an unchanged symlink pause does not wake again"

reset_guard
printf 'keep\n' > "$home/state/pause-target"
ln -s pause-target "$home/state/disk-guard.pause"
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "action=pause-symlink" "a symlink pause flag is not replaced"
assert_contains "$(cat "$home/state/pause-target")" "keep" "the symlink target stays"
assert_equals 1 "$(wake_count)" "a symlink pause wakes the supervisor"
rm -f "$home/state/disk-guard.pause"
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
ln -s pause-target "$home/state/disk-guard.pause"
out=$(run_guard)
assert_contains "$out" "action=pause-symlink" "a healthy sample does not remove a symlink flag"
assert_contains "$(cat "$home/state/pause-target")" "keep" "a healthy sample leaves the symlink target"
assert_equals 2 "$(wake_count)" "a healthy sample with a symlink alerts the supervisor"
rm -f "$home/state/disk-guard.pause"

reset_guard
ln -s pause-target "$home/state/disk-guard.pause"
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
rm -f "$home/state/disk-guard.pause"
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
assert_absent "$home/state/disk-guard.announced" "removing a symlink clears announcement state"
ln -s pause-target "$home/state/disk-guard.pause"
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
assert_equals 2 "$(wake_count)" "a new symlink pause wakes after repair"
rm -f "$home/state/disk-guard.pause"

: > "$home/state/disk-guard.log"
i=0
while [ "$i" -lt 2000 ]; do
  printf 'seed\n' >> "$home/state/disk-guard.log"
  i=$((i + 1))
done
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
run_guard >/dev/null
assert_equals 2000 "$(wc -l < "$home/state/disk-guard.log" | tr -d '[:space:]')" "the log keeps the last 2000 lines"
assert_contains "$(tail -n 1 "$home/state/disk-guard.log")" "pressure=no" "the newest sample is the line that remains"

reset_guard
old="$home/.tmp/old.txt"
fresh="$home/.tmp/fresh.txt"
envf="$home/.tmp/.env"
printf 'old\n' > "$old"
printf 'fresh\n' > "$fresh"
printf 'secret\n' > "$envf"
fm_touch_epoch $(($(date +%s) - 3 * 86400)) "$old" "$envf"
home_phys=$(cd "$home" && pwd -P)
cat > "$home/config/data-management" <<EOF
home $home_phys
tmp $home_phys/.tmp 1
EOF
set_collector_values 1000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "action=paused-cleanup-0" "pressure runs the configured cleanup once"
assert_contains "$(cat "$home/state/disk-guard.cleanup")" "mode=dry-run" "pressure without authorization plans cleanup"
assert_present "$old" "pressure without authorization leaves aged files"
reset_guard
: > "$home/config/data-management.live-authorized"
cat > "$home/config/data-management" <<EOF
home $home_phys
tmp $home_phys/.tmp 1
EOF
out=$(run_guard)
assert_contains "$out" "action=paused-cleanup-0" "authorized pressure runs cleanup once"
assert_contains "$(cat "$home/state/disk-guard.cleanup")" "measure	phase=before" "cleanup records before measurement"
assert_contains "$(cat "$home/state/disk-guard.cleanup")" "measure	phase=after" "cleanup records after measurement"
assert_absent "$old" "the cleanup removes an aged temp file"
assert_present "$fresh" "the cleanup leaves a fresh temp file"
assert_present "$envf" "the cleanup leaves a dotenv file"
assert_present "$home/state/disk-guard.pause" "cleanup does not clear the pause"

reset_guard
set_collector_values 30000000 8000000 30 1000000 300000 700000 1000
out=$(run_guard)
assert_contains "$out" "reasons=c-free" "C: below its floor is pressure"
assert_contains "$out" "alert=low" "low free space raises the disk alert"
assert_contains "$out" "action=paused" "low free space pauses spawns"
assert_contains "$(cat "$home/state/.wake-queue")" "disk-guard pause reasons=c-free" "the alert wake names C:"
wakes=$(wake_count)
export TEST_C_MODE=fail
out=$(run_guard)
assert_contains "$out" "c_free_kib=absent" "a failed C: read is an absent reading"
assert_contains "$out" "action=held-unknown" "an absent reading while paused logs held-unknown"
assert_contains "$out" "alert=unknown" "an absent reading does not claim the disk is healthy"
assert_present "$home/state/disk-guard.pause" "an absent reading keeps the pause flag"
assert_equals "$wakes" "$(wake_count)" "holding an unknown reading does not clear or repeat the wake"
unset TEST_C_MODE
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
out=$(run_guard)
assert_contains "$out" "action=cleared" "a complete healthy sample clears a held pause"
assert_absent "$home/state/disk-guard.pause" "the held pause is removed once every reading is healthy"

reset_guard
set_collector_values 30000000 8000000 30 1000000 300000 700000 1000
run_guard >/dev/null
export TEST_C_MODE=hang
start=$(date +%s)
out=$(run_guard)
elapsed=$(( $(date +%s) - start ))
unset TEST_C_MODE
[ "$elapsed" -lt 22 ] || fail "a hung C: read was not bounded (${elapsed}s)"
assert_contains "$out" "c_free_kib=absent" "a timed-out C: read is an absent reading"
assert_contains "$out" "action=held-unknown" "a timed-out reading keeps the pause"
assert_present "$home/state/disk-guard.pause" "a timed-out C: read does not clear the pause"

reset_guard
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
export TEST_ROOT_FREE=1000
out=$(run_guard)
unset TEST_ROOT_FREE
assert_contains "$out" "reasons=root-free" "the Linux root below its floor is pressure"
assert_contains "$out" "alert=low" "low space on / raises the disk alert"
assert_contains "$(cat "$home/state/.wake-queue")" "reasons=root-free" "the alert wake names /"

reset_guard
set_collector_values 30000000 8000000 30 1000000 300000 700000 200000000
if [ -d /mnt/d ] && [ ! -L /mnt/d ]; then
  export TEST_D_FREE=1000
  out=$(run_guard)
  unset TEST_D_FREE
  assert_contains "$out" "reasons=d-free" "D: below its floor is pressure"
  assert_contains "$out" "alert=low" "low space on D: raises the disk alert"
  assert_contains "$(cat "$home/state/.wake-queue")" "reasons=d-free" "the alert wake names D:"
else
  out=$(run_guard)
  assert_contains "$out" "d_free_kib=absent" "a missing D: mount is not a reading"
  assert_not_contains "$out" "d-free" "a missing D: mount is not pressure"
fi

pass "fm-disk-guard pauses on pressure and clears only when the sample is healthy"
