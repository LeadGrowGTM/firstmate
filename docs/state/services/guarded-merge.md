---
id: guarded-merge
title: Guarded merge
kind: statechart
status: implemented
summary: A GitHub or GitLab landing is checked live and then confirmed, a Gerrit change is never submitted, and a local-only branch fast-forwards only when it is a clean descendant and its hold is released.
parent: fleet-runtime
sources:
  - bin/fm-pr-merge.sh
  - bin/fm-merge-local.sh
  - bin/fm-dod-lib.sh
  - docs/architecture.md
diagramLinks: {}
diagramDetails:
  - diagram: 0
    node: Github
    section: GitHub checks are live
  - diagram: 0
    node: Local
    section: Local-only is a fast-forward
  - diagram: 0
    node: GerritStop
    section: Gerrit is not submitted
---

# Guarded merge

Delivery mode and merge authority are different choices.
no-mistakes runs the full review pipeline and ends at a pull request.
direct-PR opens a pull request without that pipeline.
local-only stops on a local branch and lands with a fast-forward.
yolo decides who may merge green, in-scope work.
It does not make a red pull request mergeable, and it does not apply to Gerrit.
The chart starts after a task is ready and a URL or a local branch exists.

```mermaid
stateDiagram-v2
    [*] --> Chosen
    Chosen --> Github: GitHub pull request
    Chosen --> Gitlab: GitLab merge request
    Chosen --> GerritStop: Gerrit change
    Chosen --> Local: local-only branch
    Github --> Stopped: a live check fails or the merge command fails
    Gitlab --> Accepted: glab merge accepted
    Gitlab --> Stopped: a live condition fails or the merge command fails
    Accepted --> Recorded: read-back shows merged
    Local --> Landed: fast-forward succeeds
    Local --> Stopped: hold open, checkout not clean or not on default, or not a fast-forward
    GerritStop --> Stopped: submit refused
```

Unverified: the chart does not include a GitHub acceptance state or a GitLab unconfirmed result, because those edges were not confirmed.

## GitHub checks are live

bin/fm-pr-merge.sh records the pull request URL before it calls the forge.
The GitHub path then reads the pull request again.
It must be open, not a draft, mergeable, and free of conflicts.
Every unwaived check must be green at the current head, and every unwaived required check must have reported.
The script passes that head to gh pr merge as --match-head-commit.
A push that arrives between the read and the merge fails the merge instead of landing unchecked commits.
The default method is squash when the caller did not pass one.
While an away record exists, the authority read and the forge command share that record's lock.
A required check that has not reported is missing, not red.
An attended merge may waive one red check with --allow-red and one unreported required check with --allow-missing, each by exact name.
Both are refused while an away record exists and are not accepted on GitLab.

## The merge is bound to the commit that was checked

If the merge command itself fails, the script exits with the command's status and records no landed outcome.
That failure is the GitHub stop for a merge command, distinct from a live check that never issues the command.
After the command returns success, the script reads the pull request again.
Unverified: what the script does when that read-back cannot be read was not confirmed.
A read-back that shows merged continues to the outcome record.
A read-back that shows only queued exits 0 and records no landed outcome.
A read-back that is neither merged nor queued is refused and names the state it saw.
Unverified: whether docs/architecture.md states that confirmation rule for a merge a later poll discovers was not confirmed.

## GitLab

The GitLab path is a merge request URL merged through glab, with the instance taken from the URL.
Passing the live checks only precedes the merge command.
docs/architecture.md says the live read must show the request open, mergeable, conflict-free, with blocking discussions resolved and a successful pipeline at the current head.
The call is glab mr merge with the project URL, --sha set to the verified head, and --yes.
If that command fails, the script exits with the command's status.
If the command succeeds, landing is known only after gitlab_confirm_merged reads the request back.
A read-back that shows merged continues to the outcome record.
If the merge cannot be confirmed, the script exits 0 and records no landed outcome.

## Gerrit is not submitted

If the provider parsed from the URL is gerrit, bin/fm-pr-merge.sh exits with an error before a metadata read or a forge write.
The message says submitting would require an attributed human approval the tool must not manufacture.
The change can still be watched and recorded.
A person submits it on the server.
Spawn also refuses yolo on for a project registered as Gerrit.

## Local-only is a fast-forward

bin/fm-merge-local.sh runs only for a local-only task, and only when the held decision is already released.
The project checkout must be on its default branch and clean.
The default branch must be an ancestor of the ship branch.
The merge is git merge --ff-only.
A diverged branch is refused with a note to rebase and retry.
A checkout that is dirty or on another branch is refused before that merge.
The script prints the short hashes before and after when the fast-forward succeeds.

## After landing

A confirmed GitHub or GitLab merge writes a durable outcome through the shared merge-outcome helper rather than leaving the fact in the merging agent's memory.
A local-only fast-forward writes no merge outcome.
It prints the hashes and appends to the optional fleet ledger.
Cleanup then runs bin/fm-teardown.sh's landed-work test, described on the task lifecycle page.
A request that is queued or whose merge cannot be confirmed records no landed outcome and leaves its poll armed.
A red request is refused by the live check before any merge command.
That refusal records no landed outcome and does not change the poll.
The poll stays armed because the request was registered, not because the refusal re-armed it.
bin/fm-merge-outcome-lib.sh owns the outcome's destination and deduplication.
The merge script's header and docs/architecture.md name it as the publisher.
