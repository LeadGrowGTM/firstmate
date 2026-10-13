# shellcheck shell=bash
# Structured decision inventory shared by Bearings and home summaries.
# Usage: source this file and prepend FM_BEARINGS_DECISIONS_JQ_DEFS to jq.
# shellcheck disable=SC2034
FM_BEARINGS_DECISIONS_JQ_DEFS='
  def bearings_decisions:
    [.[] | select(.structured and .hold_bucket != null)
     | {id, title, repo, reason:.hold_reason,
        priority, origin:.hold_origin, hold_set,
        bucket:.hold_bucket, until:.hold_until,
        pr_url, stale_reason:null}];
'
