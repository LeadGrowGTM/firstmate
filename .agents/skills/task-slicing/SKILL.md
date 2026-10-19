---
name: task-slicing
description: >-
  Agent-only rule for cutting a multi-part ask into tasks.
  Load before splitting a multi-part ask into tasks, and before planning the build that follows a scout.
user-invocable: false
metadata:
  internal: true
---

# task-slicing

This skill is the single owner of how a multi-part ask is cut into tasks.
When one ask has several parts, cut it into thin end-to-end tracer-bullet slices before filing or dispatching those parts.
Each slice is a complete path through every layer it touches, and each slice is independently mergeable and verifiable.
Size each slice to fit one worker session.
On a tasks-axi backend, record blockers with `bin/fm-tasks-axi.sh block <id> --by <blocker>` and dispatch from `bin/fm-tasks-axi.sh ready`; on a manual backend, put each `blocked-by: <blocker>` on the blocked task's title line and dispatch only after all blockers close.
A wide refactor that cannot be cut into those slices goes expand-contract: add the new path in one PR, migrate callers in independently mergeable PRs each sized for one worker session, then remove the old path in a final PR.
Tracer-bullet slices and expand-contract come from https://github.com/mattpocock/skills/blob/main/skills/engineering/to-tickets/SKILL.md.
