#!/usr/bin/env bash
# Drives the real fm-remote-job-worker.sh (bin files taken from git rev $2) in a
# disposable fixture: stages one job that runs $3 seconds, long enough to span
# this host's ~32s wall-clock step, and reports how the worker published it.
set -u
REPO=$1 REV=$2 SECS=$3
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-job.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
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
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=300
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  [ -f "$FM_REMOTE_JOB_STATE_ROOT/worker.pid" ] && fm_remote_job_stop_worker_tree "$(cat "$FM_REMOTE_JOB_STATE_ROOT/worker.pid")" 2>/dev/null
  kill "$WPID" 2>/dev/null; rm -rf -- "$TMP"
}
trap cleanup EXIT
echo "rev=$(git -C "$REPO" rev-parse --short "$REV") job_seconds=$SECS started=$(date +%T)"
HOME="$ACCOUNT_HOME" bash "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP/worker.log" 2>&1 &
WPID=$!
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-delay-job.sh "$SECS" "$TMP/ran" </dev/null >/dev/null \
  || { echo "stage failed: $FM_REMOTE_JOB_ERROR"; exit 2; }
( sleep 5; echo "recorded process identities 5s into the job:"
  find "$TMP/state" "$ACCOUNT_HOME" -name start -type f 2>/dev/null | while read -r s; do echo "  ${s#$TMP/} = $(cat "$s")"; done ) &
IDPID=$!
fm_remote_job_wait "$ACCOUNT_HOME" "$FM_REMOTE_JOB_ID"; wrc=$?
wait "$IDPID"
echo "finished=$(date +%T) wait_rc=$wrc job_exit=${FM_REMOTE_JOB_EXIT:-} wait_error=${FM_REMOTE_JOB_ERROR:-}"
echo "job_stderr=$(cat "${FM_REMOTE_JOB_STDERR:-/dev/null}" 2>/dev/null)"
echo "job_side_effect_file=$([ -e "$TMP/ran" ] && echo present || echo MISSING)"
echo "worker.log:"; sed 's/^/  /' "$TMP/worker.log" | tail -20
[ "${FM_REMOTE_JOB_EXIT:-x}" = 0 ] && [ -e "$TMP/ran" ]
