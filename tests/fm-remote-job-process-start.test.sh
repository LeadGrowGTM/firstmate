#!/usr/bin/env bash
# The remote job process identity stays stable when ps lstart changes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-process-start)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null || true; rm -rf -- "$TMP_ROOT"' EXIT

# Field 22 of this fixture is the start tick.
# The live pid is only the filename the reader opens, so the same checks run where /proc is absent.
TICK=4242
BOOT_ID=11111111-1111-1111-1111-111111111111
OTHER_BOOT_ID=22222222-2222-2222-2222-222222222222
PROC_ROOT=$TMP_ROOT/proc
mkdir -p "$PROC_ROOT/$LIVE_PID" "$PROC_ROOT/sys/kernel/random"
printf '%s\n' "$LIVE_PID (sleep) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 $TICK" \
  > "$PROC_ROOT/$LIVE_PID/stat"
printf '%s\n' "$BOOT_ID" > "$PROC_ROOT/sys/kernel/random/boot_id"

PS_BIN="$TMP_ROOT/ps"
PS_COUNT="$TMP_ROOT/ps.count"
printf '0\n' > "$PS_COUNT"
cat > "$PS_BIN" <<'SH'
#!/bin/bash
count_file=$FM_TEST_PS_COUNT
n=$(tr -d '\n' < "$count_file")
printf '%s\n' "$((n + 1))" > "$count_file"
if [ $((n % 2)) -eq 0 ]; then
  printf 'Sun Oct 11 00:00:01 2026\n'
else
  printf 'Sun Oct 11 00:00:00 2026\n'
fi
SH
chmod +x "$PS_BIN"

export FM_REMOTE_JOB_PS_BIN=$PS_BIN
export FM_TEST_PS_COUNT=$PS_COUNT
export FM_REMOTE_JOB_PROC_ROOT=$PROC_ROOT
first=$(fm_remote_job_process_start "$LIVE_PID") || fail "monotonic start read failed"
# The wall-clock string changes between reads.
# A caller that still used lstart would see the stub.
# The monotonic read does not consult it.
# The fallback runs in a subshell so its root cannot replace the fixture.
(
  FM_REMOTE_JOB_PROC_ROOT=$TMP_ROOT/no-proc
  fm_remote_job_process_start "$LIVE_PID" >/dev/null
) || fail "the fallback could not read the simulated lstart"
second=$(fm_remote_job_process_start "$LIVE_PID") || fail "second monotonic start read failed"
[ "$first" = "starttime=$TICK boot_id=$BOOT_ID" ] || fail "identity was not scoped to the current boot and monotonic start tick, got '$first'"
[ "$first" = "$second" ] || fail "identity changed across a moving lstart, first='$first' second='$second'"
[ "$(tr -d '\n' < "$PS_COUNT")" -eq 1 ] || fail "the monotonic read consulted ps"
pass "a moving lstart leaves the monotonic start identity unchanged"

fallback_a=$(
  FM_REMOTE_JOB_PROC_ROOT=$TMP_ROOT/no-proc
  fm_remote_job_process_start "$LIVE_PID"
) || fail "first fallback read failed"
fallback_b=$(
  FM_REMOTE_JOB_PROC_ROOT=$TMP_ROOT/no-proc
  fm_remote_job_process_start "$LIVE_PID"
) || fail "second fallback read failed"
[ "$fallback_a" != "$fallback_b" ] || fail "the simulated lstart did not change between fallback reads"
[ "$fallback_a" = "Sun Oct 11 00:00:00 2026" ] || fail "unexpected first fallback '$fallback_a'"
[ "$fallback_b" = "Sun Oct 11 00:00:01 2026" ] || fail "unexpected second fallback '$fallback_b'"
pass "without a start tick the same process reports the changing lstart"

LEGACY_START="Sun Oct 11 16:26:44 2026"
[ "$first" != "$LEGACY_START" ] || fail "the monotonic identity equals an lstart record"

command=$(fm_remote_job_process_command "$LIVE_PID") || fail "could not read the live command"
owner="$TMP_ROOT/owner"
mkdir -p "$owner"
printf '%s\n' "$LIVE_PID" > "$owner/pid"
printf '%s\n' "$command" > "$owner/command"
printf '%s\n' "$LEGACY_START" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "an lstart record was accepted as the live process"
printf '%s\n' "stale owner identity" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "a stale owner marker was treated as the live process"
printf '%s\n' "starttime=$((TICK + 1)) boot_id=$BOOT_ID" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "a different monotonic tick was accepted as the live process"
printf '%s\n' "starttime=$TICK" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "a tick without a boot id was accepted as the live process"
printf '%s\n' "$first" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  || fail "an exact monotonic owner identity was rejected"
printf '%s\n' "$OTHER_BOOT_ID" > "$PROC_ROOT/sys/kernel/random/boot_id"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "a same-pid same-tick owner from another boot was accepted"
printf '%s\n' "$BOOT_ID" > "$PROC_ROOT/sys/kernel/random/boot_id"
fm_remote_job_recorded_owner_alive "$owner" \
  || fail "the same-boot owner identity was rejected after restoring the boot id"
pass "lock ownership requires the same boot and tick and rejects old records"

mv "$PROC_ROOT/$LIVE_PID/stat" "$PROC_ROOT/$LIVE_PID/stat.saved"
fm_remote_job_process_start "$LIVE_PID" >/dev/null 2>&1 \
  && fail "a Linux process without readable stat fell back to lstart"
mv "$PROC_ROOT/$LIVE_PID/stat.saved" "$PROC_ROOT/$LIVE_PID/stat"

# A missing or unreadable proc stat skips the real-kernel check.
# The field is indexed only after a successful read, so an empty result cannot trip set -u.
kernel_rc=0
kernel_line=$(cat "/proc/$LIVE_PID/stat" 2>/dev/null) || kernel_rc=$?
if [ "$kernel_rc" -ne 0 ] || [ -z "${kernel_line:-}" ]; then
  pass "real kernel start tick (skipped: proc stat is not readable)"
else
  read -r -a kernel_fields <<< "${kernel_line##*)}"
  [ "${#kernel_fields[@]}" -ge 20 ] || fail "a readable proc stat did not contain a start tick"
  kernel_tick=${kernel_fields[19]}
  kernel_boot_id=$(cat /proc/sys/kernel/random/boot_id) || fail "could not read the real kernel boot id"
  case "$kernel_tick" in
    ''|*[!0-9]*) fail "a readable proc stat start tick was not numeric" ;;
  esac
  kernel_id=$(
    unset FM_REMOTE_JOB_PROC_ROOT
    fm_remote_job_process_start "$LIVE_PID"
  ) || fail "could not read the real kernel start identity"
  [ "$kernel_id" = "starttime=$kernel_tick boot_id=$kernel_boot_id" ] \
    || fail "real kernel identity was '$kernel_id', expected starttime=$kernel_tick boot_id=$kernel_boot_id"
  pass "the real kernel start tick and boot id are the process identity"
fi

unset FM_REMOTE_JOB_PS_BIN
fm_remote_job_process_start 2147483647 >/dev/null 2>&1 \
  && fail "a missing process returned an identity"
pass "a missing process has no start identity"
