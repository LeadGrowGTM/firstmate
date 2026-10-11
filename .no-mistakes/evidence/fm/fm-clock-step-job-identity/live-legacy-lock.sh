#!/usr/bin/env bash
# Adversarial: a worker.lock left in the old wall-clock (ps lstart) format that
# names a LIVE unrelated process. The real worker must not treat that record as
# the live owner, must never signal that process, and must still serve jobs.
set -u
REPO=$1 REV=$2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-legacy.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
REMOTE_ROOT=$TMP/remote-root REMOTE_HOME=$TMP/remote-home ACCOUNT_HOME=$TMP/account
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME"
for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
  git -C "$REPO" show "$REV:bin/$f" > "$REMOTE_ROOT/bin/$f"
done
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
printf '#!/bin/bash\nsleep "$1"\nprintf "ran\\n" > "$2"\n' > "$REMOTE_ROOT/bin/fm-delay-job.sh"
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" -c user.email=t@example.com -c user.name=T add AGENTS.md bin
git -C "$REMOTE_ROOT" -c user.email=t@example.com -c user.name=T commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT=$TMP/state FM_ROOT_OVERRIDE=$REMOTE_ROOT
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=60
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
sleep 600 & BYSTANDER=$!
WPID=
cleanup() {
  [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ] && fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" 2>/dev/null
  [ -z "$WPID" ] || kill "$WPID" 2>/dev/null; kill "$BYSTANDER" 2>/dev/null; rm -rf -- "$TMP"
}
trap cleanup EXIT
# Let a real worker create the state layout, then stop it and plant the record.
HOME="$ACCOUNT_HOME" bash "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP/worker0.log" 2>&1 & WPID=$!
for i in $(seq 1 100); do [ -f "$TMP/state/worker.lock/start" ] && break; sleep 0.1; done
echo "real worker's own lock record: pid=$(cat "$TMP/state/worker.lock/pid") start='$(cat "$TMP/state/worker.lock/start")'"
fm_remote_job_stop_worker_tree "$(cat "$TMP/state/worker.pid")" 2>/dev/null; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
rm -rf "$TMP/state/worker.lock"; mkdir -m 700 "$TMP/state/worker.lock"
LEGACY=$(/bin/ps -p "$BYSTANDER" -o lstart=)
printf '%s\n' "$BYSTANDER" > "$TMP/state/worker.lock/pid"
fm_remote_job_process_command "$BYSTANDER" > "$TMP/state/worker.lock/command"
printf '%s\n' "$LEGACY" > "$TMP/state/worker.lock/start"
echo "planted lock: pid=$BYSTANDER (live bystander) command='$(cat "$TMP/state/worker.lock/command")' start='$LEGACY' (old ps lstart format)"
echo "bystander's current identity: $(fm_remote_job_process_start "$BYSTANDER")"
if fm_remote_job_recorded_owner_alive "$TMP/state/worker.lock"; then echo "recorded_owner_alive: ACCEPTED the lstart record"; else echo "recorded_owner_alive: rejected the lstart record"; fi
HOME="$ACCOUNT_HOME" bash "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP/worker.log" 2>&1 & WPID=$!
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-delay-job.sh 2 "$TMP/ran" </dev/null >/dev/null \
  || { echo "stage failed: $FM_REMOTE_JOB_ERROR"; exit 2; }
fm_remote_job_wait "$ACCOUNT_HOME" "$FM_REMOTE_JOB_ID"; wrc=$?
echo "job: wait_rc=$wrc exit=${FM_REMOTE_JOB_EXIT:-} stderr='$(cat "${FM_REMOTE_JOB_STDERR:-/dev/null}" 2>/dev/null)' side_effect=$([ -e "$TMP/ran" ] && echo present || echo MISSING)"
echo "lock after new worker started: pid=$(cat "$TMP/state/worker.lock/pid" 2>/dev/null) start='$(cat "$TMP/state/worker.lock/start" 2>/dev/null)'"
if kill -0 "$BYSTANDER" 2>/dev/null; then echo "bystander pid $BYSTANDER: still alive (never signalled)"; b=0; else echo "bystander pid $BYSTANDER: KILLED"; b=1; fi
echo "worker.log:"; sed 's/^/  /' "$TMP/worker.log" | tail -10
[ "$b" = 0 ] && [ "${FM_REMOTE_JOB_EXIT:-x}" = 0 ]
