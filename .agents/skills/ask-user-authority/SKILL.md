---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill owns finding decisions: firstmate applies judgment within accepted intent and consults the script-owned escalation test before filing a captain call.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate decides findings from the best evidence within accepted intent and records its choice and reason in the task note.
Apply the escalate test in `bin/fm-captain-hold.sh --help` before filing a captain call.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide in-scope findings from the best evidence: restore accepted behavior a bad fix round broke, complete the approved design, or choose the smallest correction required by accepted intent, even when the work is technically difficult.
   Record the choice and reason in the task note before responding to the gate.
4. For ambiguity, an expansion, or repeated same-theme findings, choose an authorized alternative that satisfies accepted intent instead of treating uncertainty as a reason to file a captain call.
   Decline an unneeded expansion; do not authorize new scope merely because the finding proposes it.
   A choice that passes the script-owned escalate test goes to the captain; an explicit confirmation requirement still waits for that confirmation.
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The concrete choice requiring the captain.
3. The smallest authorized alternative that satisfies the accepted contract.
4. The concrete consequences of each option.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof is an unneeded expansion to decline.
- A new finding in the same causal theme calls for the smallest correction to the accepted contract rather than another layer around a questionable abstraction.
- A finding that passes the script-owned escalate test requires the captain even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
