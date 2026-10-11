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

stat_line=$(cat "/proc/$LIVE_PID/stat")
read -r -a stat_fields <<< "${stat_line##*)}"
TICK=${stat_fields[19]}
case "$TICK" in ''|*[!0-9]*) fail "could not read the live process start tick" ;; esac

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
first=$(fm_remote_job_process_start "$LIVE_PID") || fail "monotonic start read failed"
# The wall-clock string changes between the two reads. The stub is what a
# caller that still used lstart would see. This read does not consult it.
FM_REMOTE_JOB_PROC_ROOT=$TMP_ROOT/no-proc fm_remote_job_process_start "$LIVE_PID" >/dev/null \
  || fail "the fallback could not read the simulated lstart"
second=$(fm_remote_job_process_start "$LIVE_PID") || fail "second monotonic start read failed"
[ "$first" = "starttime=$TICK" ] || fail "identity was not the monotonic start tick, got '$first'"
[ "$first" = "$second" ] || fail "identity changed across a moving lstart, first='$first' second='$second'"
[ "$(tr -d '\n' < "$PS_COUNT")" -eq 1 ] || fail "the monotonic read consulted ps"
pass "a moving lstart leaves the monotonic start identity unchanged"

unset FM_REMOTE_JOB_PROC_ROOT
fallback_a=$(FM_REMOTE_JOB_PROC_ROOT="$TMP_ROOT/no-proc" fm_remote_job_process_start "$LIVE_PID") \
  || fail "first fallback read failed"
fallback_b=$(FM_REMOTE_JOB_PROC_ROOT="$TMP_ROOT/no-proc" fm_remote_job_process_start "$LIVE_PID") \
  || fail "second fallback read failed"
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
printf '%s\n' "starttime=$((TICK + 1))" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  && fail "a different monotonic tick was accepted as the live process"
printf '%s\n' "$first" > "$owner/start"
fm_remote_job_recorded_owner_alive "$owner" \
  || fail "an exact monotonic owner identity was rejected"
pass "lock ownership needs the exact monotonic identity and rejects an lstart record"

unset FM_REMOTE_JOB_PS_BIN
fm_remote_job_process_start 2147483647 >/dev/null 2>&1 \
  && fail "a missing process returned an identity"
pass "a missing process has no start identity"
