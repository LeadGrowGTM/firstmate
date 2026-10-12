#!/usr/bin/env bash
# The remote job process identity stays stable when ps lstart changes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-process-start)
mkdir -p "$TMP_ROOT"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

sleep 300 &
LIVE_PID=$!
GROUP_PGID=
LIVE_GROUP_PGID=
MATCH_PGID=
RECLAIM_WORKER_PID=
cleanup_process_start_fixture() {
  if [ -n "$RECLAIM_WORKER_PID" ]; then
    kill -TERM "$RECLAIM_WORKER_PID" 2>/dev/null || true
    wait "$RECLAIM_WORKER_PID" 2>/dev/null || true
  fi
  [ -z "$GROUP_PGID" ] || kill -KILL -- "-$GROUP_PGID" 2>/dev/null || true
  if [ -n "$LIVE_GROUP_PGID" ]; then
    kill -KILL -- "-$LIVE_GROUP_PGID" 2>/dev/null || true
    wait "$LIVE_GROUP_PGID" 2>/dev/null || true
  fi
  if [ -n "$MATCH_PGID" ]; then
    kill -KILL -- "-$MATCH_PGID" 2>/dev/null || true
    wait "$MATCH_PGID" 2>/dev/null || true
  fi
  kill "$LIVE_PID" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_process_start_fixture EXIT

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

if [ "$(uname -s)" = Linux ]; then
  command -v setsid >/dev/null || fail "setsid is required for the leaderless group fixture"
  GROUP_ROOT="$TMP_ROOT/leaderless"
  mkdir -p "$GROUP_ROOT/account" "$GROUP_ROOT/home" "$GROUP_ROOT/remote/bin"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$GROUP_ROOT/remote/bin/"
  : > "$GROUP_ROOT/remote/AGENTS.md"
  cat > "$GROUP_ROOT/child.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "TERM\n" >> "$FM_TEST_SIGNAL_LOG"' TERM
trap 'printf "HUP\n" >> "$FM_TEST_SIGNAL_LOG"' HUP
printf '%s\n' "$$" > "$FM_TEST_CHILD_PID_FILE"
while :; do sleep 0.1; done
SH
  chmod +x "$GROUP_ROOT/child.sh"
  export FM_TEST_CHILD_PID_FILE="$GROUP_ROOT/child.pid"
  export FM_TEST_SIGNAL_LOG="$GROUP_ROOT/signals"
  # shellcheck disable=SC2016 # The child shell expands $1, not this shell.
  setsid bash -c '"$1" &' _ "$GROUP_ROOT/child.sh" >/dev/null 2>&1 &
  GROUP_PGID=$!
  wait "$GROUP_PGID" || fail "the leaderless group fixture did not launch"
  for _ in $(seq 1 100); do
    [ -f "$FM_TEST_CHILD_PID_FILE" ] && break
    sleep 0.05
  done
  [ -f "$FM_TEST_CHILD_PID_FILE" ] || fail "the group child did not start"
  CHILD_PID=$(cat "$FM_TEST_CHILD_PID_FILE")
  [ "$(fm_remote_job_process_pgid "$CHILD_PID")" = "$GROUP_PGID" ] \
    || fail "the surviving child was not in the leader's process group"
  ! kill -0 "$GROUP_PGID" 2>/dev/null || fail "the group leader did not exit"
  kill -0 -- "-$GROUP_PGID" 2>/dev/null || fail "the leaderless group did not survive"
  [ ! -e "$FM_TEST_SIGNAL_LOG" ] || fail "the group fixture signalled its own child"

  unset FM_REMOTE_JOB_PROC_ROOT
  export FM_REMOTE_JOB_STATE_ROOT="$GROUP_ROOT/state"
  fm_remote_job_prepare_state "$GROUP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
  HOME="$GROUP_ROOT/account" FM_ROOT_OVERRIDE="$GROUP_ROOT/remote" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$GROUP_ROOT/remote/bin/fm-remote-job-worker.sh" --serve \
    > "$GROUP_ROOT/worker.out" 2> "$GROUP_ROOT/worker.err" &
  RECLAIM_WORKER_PID=$!
  SAME_BOOT_ID=$(fm_remote_job_process_boot_id) || fail "could not read the boot id for the same-boot group record"
  for identity in old missing same-boot; do
    job="$FM_REMOTE_JOB_JOBS/job-leaderless-$identity"
    mkdir -m 700 "$job" "$job/.claim"
    : > "$job/stdout"
    : > "$job/stderr"
    printf '%s\n' "$GROUP_PGID" > "$job/.claim/group"
    if [ "$identity" = old ]; then
      printf 'Sun Oct 11 16:26:44 2026\n' > "$job/.claim/group_start"
    elif [ "$identity" = same-boot ]; then
      # This is the record shape that used to authorize a signal: a numeric
      # start tick scoped to the current boot, with the leader already gone.
      printf 'starttime=1 boot_id=%s\n' "$SAME_BOOT_ID" > "$job/.claim/group_start"
    fi
    chmod 600 "$job/stdout" "$job/stderr" "$job/.claim"/*
    fm_remote_job_write_state "$job" running || fail "could not seed the running job"
    for _ in $(seq 1 150); do
      [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] && break
      sleep 0.05
    done
    [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] \
      || fail "the $identity group record was not reclaimed"
    [ "$(cat "$job/exit")" = 125 ] || fail "the $identity group record did not publish exit 125"
    if [ "$identity" = missing ]; then
      [ "$(cat "$job/stderr")" = 'remote job worker stopped before this job completed' ] \
        || fail "the $identity group record published the wrong error"
    else
      [ "$(cat "$job/stderr")" = "remote job worker stopped before this job completed
orphaned helper processes may still be running" ] \
        || fail "the $identity group record did not note that members may still be running: $(cat "$job/stderr")"
    fi
    [ ! -e "$job/.unverified-group" ] || fail "the $identity group record left its internal note behind"
    sleep 0.2
    [ ! -e "$FM_TEST_SIGNAL_LOG" ] || fail "the $identity group record signalled the surviving child"
    state=$(/bin/ps -p "$CHILD_PID" -o state= 2>/dev/null) \
      || fail "the $identity group record killed the surviving child"
    case "$state" in *Z*) fail "the $identity group record killed the surviving child" ;; esac
  done
  pass "leaderless groups are reclaimed without signals, including a same-boot tick"

  setsid sleep 300 >/dev/null 2>&1 &
  LIVE_GROUP_PGID=$!
  [ "$(fm_remote_job_process_pgid "$LIVE_GROUP_PGID")" = "$LIVE_GROUP_PGID" ] \
    || fail "the live group fixture did not start in its own process group"
  live_start=$(fm_remote_job_process_start "$LIVE_GROUP_PGID") \
    || fail "the live group has no process identity"
  live_tick=${live_start#starttime=}
  live_tick=${live_tick%% boot_id=*}
  current_boot_id=$(fm_remote_job_process_boot_id) || fail "the live group has no boot id"
  [ "$current_boot_id" != "$OTHER_BOOT_ID" ] || fail "the different-boot fixture matches this boot"
  for identity in old other-boot; do
    job="$FM_REMOTE_JOB_JOBS/job-live-$identity"
    mkdir -m 700 "$job" "$job/.claim"
    : > "$job/stdout"
    : > "$job/stderr"
    printf '%s\n' "$LIVE_GROUP_PGID" > "$job/.claim/group"
    if [ "$identity" = old ]; then
      printf '%s\n' "$LEGACY_START" > "$job/.claim/group_start"
    else
      printf 'starttime=%s boot_id=%s\n' "$live_tick" "$OTHER_BOOT_ID" > "$job/.claim/group_start"
    fi
    chmod 600 "$job/stdout" "$job/stderr" "$job/.claim"/*
    fm_remote_job_write_state "$job" running || fail "could not seed the running job"
    for _ in $(seq 1 150); do
      [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] && break
      sleep 0.05
    done
    [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] \
      || fail "the $identity live group record was not reclaimed"
    [ "$(cat "$job/exit")" = 125 ] || fail "the $identity live group did not publish exit 125"
    [ "$(cat "$job/stderr")" = 'remote job worker stopped before this job completed' ] \
      || fail "the $identity live group published the wrong error"
    state=$(/bin/ps -p "$LIVE_GROUP_PGID" -o state= 2>/dev/null) \
      || fail "the $identity live group was signalled"
    case "$state" in *Z*) fail "the $identity live group was signalled" ;; esac
  done
  pass "live groups with old or different-boot start records are reclaimed without signals"

  cat > "$GROUP_ROOT/leader.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_TEST_MATCH_PID_FILE"
while :; do sleep 0.1; done
SH
  chmod +x "$GROUP_ROOT/leader.sh"
  export FM_TEST_MATCH_PID_FILE="$GROUP_ROOT/match.pid"
  setsid "$GROUP_ROOT/leader.sh" >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 100); do
    [ -f "$FM_TEST_MATCH_PID_FILE" ] && break
    sleep 0.05
  done
  [ -f "$FM_TEST_MATCH_PID_FILE" ] || fail "the matching leader did not start"
  MATCH_PGID=$(cat "$FM_TEST_MATCH_PID_FILE")
  [ "$(fm_remote_job_process_pgid "$MATCH_PGID")" = "$MATCH_PGID" ] \
    || fail "the matching leader did not start in its own process group"
  kill -0 "$MATCH_PGID" 2>/dev/null || fail "the matching leader exited before reclaim"
  match_start=$(fm_remote_job_process_start "$MATCH_PGID") \
    || fail "the matching leader has no process identity"
  job="$FM_REMOTE_JOB_JOBS/job-live-match"
  mkdir -m 700 "$job" "$job/.claim"
  : > "$job/stdout"
  : > "$job/stderr"
  printf '%s\n' "$MATCH_PGID" > "$job/.claim/group"
  printf '%s\n' "$match_start" > "$job/.claim/group_start"
  chmod 600 "$job/stdout" "$job/stderr" "$job/.claim"/*
  fm_remote_job_write_state "$job" running || fail "could not seed the matching leader job"
  for _ in $(seq 1 150); do
    [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] && break
    sleep 0.05
  done
  [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = "done" ] \
    || fail "the matching leader record was not reclaimed"
  [ "$(cat "$job/exit")" = 125 ] || fail "the matching leader record did not publish exit 125"
  [ "$(cat "$job/stderr")" = 'remote job worker stopped before this job completed' ] \
    || fail "the matching leader record published the wrong error: $(cat "$job/stderr")"
  for _ in $(seq 1 50); do
    kill -0 "$MATCH_PGID" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$MATCH_PGID" 2>/dev/null; then
    fail "the matching leader was not signalled"
  fi
  pass "a live leader whose identity matches the record is signalled"
fi
