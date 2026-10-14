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
        about:(.decision.about // null), decide:(.decision.decide // null),
        options:(.decision.options // null), recommended:(.decision.recommended // null),
        report:(.decision.report // .report_path // null),
        pr_url:(.decision.pr_url // .pr_url), stale_reason:null}];
'
