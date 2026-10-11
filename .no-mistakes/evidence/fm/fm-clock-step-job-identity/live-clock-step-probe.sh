#!/usr/bin/env bash
# Samples one live process for 100s on the real host: the wall-clock ps lstart
# string versus the identity the changed fm_remote_job_process_start returns.
set -u
ROOT=$1
. "$ROOT/bin/fm-remote-job-lib.sh"
sleep 400 & P=$!
trap 'kill $P 2>/dev/null' EXIT
echo "pid=$P kernel=$(uname -r)"
for i in $(seq 1 100); do
  printf '%s | lstart=%s | identity=%s\n' "$(date +%H:%M:%S.%N | cut -c1-12)" "$(/bin/ps -p $P -o lstart=)" "$(fm_remote_job_process_start $P)"
  sleep 1
done > "$2.samples"
echo "distinct ps lstart strings for the one live process:"; sed 's/.*lstart=\(.*\) | identity.*/\1/' "$2.samples" | sort | uniq -c
echo "distinct fm_remote_job_process_start identities for the same process:"; sed 's/.*identity=//' "$2.samples" | sort | uniq -c
