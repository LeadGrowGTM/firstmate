# shellcheck shell=bash
# Structured decision inventory shared by Bearings and home summaries.
# Usage: source this file and prepend FM_BEARINGS_DECISIONS_JQ_DEFS to jq.
# Exact merged PR identity flags a stale candidate.
# shellcheck disable=SC2034
FM_BEARINGS_DECISIONS_JQ_DEFS='
  def bearings_decisions:
    . as $records
    | [$records[] | select(.structured and .hold_bucket != null)] as $held
    | [$held[] as $h
       | {id:$h.id, title:$h.title, repo:$h.repo, reason:$h.hold_reason,
          priority:$h.priority, origin:$h.hold_origin, hold_set:$h.hold_set,
          bucket:$h.hold_bucket, until:$h.hold_until,
          pr_url:$h.pr_url,
          stale_reason:(
            if $h.pr_url != null and any($records[];
                 .state == "done" and .completion.verb == "merged" and .pr_url == $h.pr_url)
            then "Linked PR already merged"
            else null end)}];
'
