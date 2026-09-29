---
name: firstmate-orca
description: Agent-only operator checklist for Firstmate's Orca runtime backend. Use when switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
user-invocable: false
metadata:
  internal: true
---

# firstmate-orca

Use this as the operator checklist for Firstmate's experimental Orca runtime backend.
It does not replace `AGENTS.md`, `docs/orca-backend.md`, or `harness-adapters`.

Orca is a runtime backend, not an agent harness.
Orca owns the terminal endpoint; FirstMate owns the linked task checkout under the project's ignored `.worktrees/` directory.
The harness is the agent process launched inside that endpoint, such as `omp`, `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, or `kimi`.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, and limitations live in `docs/orca-backend.md`.
`docs/verification/runtime-backends.md` "Orca" owns active smoke evidence.
Prefer the `bin/fm-*` helpers over raw `orca` commands.
Use raw `orca` only when the helper surface cannot answer the inspection question, and keep the recorded firstmate metadata as the task identity.

## Preflight

Work from the current firstmate home or repo root.
If `FM_HOME` is set, remember that operational state lives under `$FM_HOME` while the helper scripts still run from this repo's `bin/`.

Before switching or spawning against Orca:

- Confirm Orca is intentionally selected through `--backend orca`, `FM_BACKEND=orca`, or local `config/backend`.
- Confirm the Orca app is running and the backend readiness checks pass before expecting spawn to work.
- Confirm this is the qualified Windows Git Bash path and the target repository ignores `.worktrees/`. Do not infer compatibility from app readiness alone.
- Inspect active `state/*.meta` records before changing backend selection.
- Treat a backend switch as affecting future spawns only; existing tasks keep their recorded backend.
- Reconcile watcher wakes before unrelated work, especially if Orca tasks are already in flight.

## Spawn

Use `bin/fm-spawn.sh` so firstmate creates the brief, worktree, terminal, metadata, status file, and watcher surface together.
Pass `--backend orca` for a one-off Orca task, or rely on the already-selected Orca backend when that selection is intentional.

After spawn, check the task with firstmate helpers:

- `bin/fm-peek.sh fm-<id>` for launch failures, trust dialogs, or first output.
- `state/<id>.meta` for `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`.
- `bin/fm-crew-state.sh <id>` when the current run state matters.
- `bin/fm-watch.sh` whenever there are tasks in flight and this session owns supervision.

Do not use `orca worktree create`, `orca worktree rm`, or Git worktree removal for a normal FirstMate Orca task.
Do not manually patch metadata to make an externally-created Orca terminal look like a FirstMate task.

## Supervision

Use `bin/fm-peek.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` for routine operation.
For steer messages, use `bin/fm-send.sh <id> '...'`; the stable `fm-<id>` alias also works, and ordinary local text steers may contain newlines because they ride the durable inbox.
Keep initial scope in the task brief; a temporary file remains useful when the instruction includes supporting material the worker should inspect separately.

When supervising, treat `state/<id>.meta` as the routing record and Orca's own ids as backend implementation details.
The stable firstmate alias is `fm-<id>`.
The recorded `terminal=` and `orca_worktree_id=` fields are what backend helpers use under the hood.

If an ordinary steer fails to enqueue, or a typed-plane `fm-send` fails to submit, do not immediately repeat the instruction.
Read the reported failure and peek first, then decide whether the record exists or the target is busy, waiting on a prompt, stuck behind a popup, or genuinely wedged.
For harness-specific interrupts or exits, load `harness-adapters`.

## Recovery

For a messy Orca-backed task:

1. Read `state/<id>.meta`, `state/<id>.orca-create` when present, and the relevant status tail first.
2. Confirm the task is actually Orca-backed before using Orca-specific assumptions.
3. Use the recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as the task identity. If creation was ambiguous, the sidecar's unique title and resolved worktree id are recovery evidence, not permission to launch another terminal.
4. Prefer firstmate helpers for peek, send, state, and teardown.
5. Avoid raw deletion of Orca worktrees or manual branch cleanup.
6. Stop and inspect if the recorded checkout path, Orca worktree id, or project Git common directory no longer matches expectations.

For a partial recovery record without `terminal=`, teardown binds a handle only after a complete exact-worktree terminal inventory yields one title/id match. Zero, duplicate, truncated, or failed inventory leaves both records untouched. An intent without task metadata requires operator reconciliation; never infer that the terminal was not created.

Teardown remains governed by the normal firstmate landing rules.
Scout work can be torn down after the report exists and the `captain-hold-lifecycle` completion gate passes.
Ship work can be torn down only after the work is landed by its project mode.
Orca terminal close reports `stop_unverified`, not whole-process-tree absence. Teardown blocks and retains the checkout, task metadata, and backlog identity even with `--force`; a pending backlog-close marker is a refusal before close. Never delete or prune the checkout without a separate, qualified process-tree and cleanup contract.

## Smoke Test

Keep Orca smoke tests focused on lifecycle plumbing, using a disposable linked checkout and a harmless Git Bash marker. Before real agent deployment:

1. Confirm Orca's installed version and exact path selector in the disposable project.
2. Create one Git Bash terminal through Orca, confirm its returned `terminal.worktreeId` matches `worktree show`, send and read a harmless marker, then close that exact handle.
3. Expect a blocked teardown and retain checkout and metadata; `ptyKilled:true` is not proof the agent process tree is dead.
4. Qualify the stop, guard, approval, and rollback boundaries separately before launching an actual FirstMate worker.

Do not mix a backend smoke test with unrelated feature work.
