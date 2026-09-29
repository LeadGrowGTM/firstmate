# Orca runtime backend

Orca is an experimental runtime backend. FirstMate owns each linked Git checkout; Orca supplies its Git Bash terminal.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca only for a Windows Git Bash installation where Orca is already running and the project ignores `.worktrees/`.
The current Windows path is explicit-only and does not support secondmate spawns. The former macOS Orca-owned checkout flow is not this contract.

Prerequisites:

- The Orca app running with its `orca` CLI on `PATH`.
- Git Bash with `cygpath`, Git, and a target repository that ignores `.worktrees/`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, FirstMate requires `orca status --json` to report `reachable=true` and `state="ready"`.
FirstMate creates the linked checkout at `<project>/.worktrees/<task-id>`, refusing an existing path or unignored directory. It verifies the Git common directory and exact registration, then registers the project with `orca repo add --path` only after a structured `repo_not_found` response.
`orca worktree show --worktree path:<native-path>` must resolve that existing checkout. Orca never creates the checkout.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one FirstMate-owned linked Git worktree and one Orca Git Bash terminal.
`fm-spawn.sh` does not call Treehouse or `orca worktree create` for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<resolved Orca id or linked>::<absolute Git Bash checkout path>
worktree=<absolute Git Bash checkout path>
```

`window=` remains the caller-facing FirstMate alias.
`terminal=` is the exact Orca handle; `orca_worktree_id=` retains the checkout path for recovery. If Orca's id contains the `::` separator, FirstMate stores `linked::<path>` rather than embedding an ambiguous id.
The checkout path and Orca's `worktree show` path must agree before a terminal opens.

## Current lifecycle and safety

Spawn first creates and verifies the linked checkout, then resolves its native Windows path through Orca. Before creating a terminal it durably records the checkout, resolved Orca worktree id, and unique terminal title in `state/<id>.orca-create`. It creates one `--shell git-bash --title <unique-title>` terminal at that path and accepts the handle only if `terminal.worktreeId` matches the prior `worktree show` id. The shared POSIX send path launches the harness in that terminal.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.
After successful task metadata publication, FirstMate retires the creation intent. If creation returns an ambiguous outcome, abort attempts a complete `terminal list` for that exact checkout and accepts only one matching title and worktree id; otherwise it retains the intent and recovery metadata without retrying creation. A later teardown may bind that uniquely identified handle under the task metadata lock, then still blocks after close. If the process stops before recovery metadata is published, the intent alone remains for operator reconciliation; it does not authorize a fresh terminal or checkout removal.

`fm-peek.sh` reads with `orca terminal read`.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery.
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
The composer read is one bounded tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before closing, teardown verifies the recorded Orca checkout path against `worktree show`; unreadable or mismatched identity preserves metadata.
It closes only the exact recorded terminal. A successful close, including `ptyKilled:true`, does not prove the agent child process tree is dead (`stop_unverified`). Teardown returns a blocked result under `--force` too, retaining the checkout, metadata, and backlog item. It neither removes Git worktrees nor calls `orca worktree rm` or prune.
A failed close is also reported and blocked; an absent CLI is not evidence that the endpoint is gone. An existing pending backlog-close marker blocks Orca teardown before terminal close, and the blocked Orca path never stages a new replayable close marker.
Reconcile the terminal and process tree before any separate qualified cleanup. [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the synthetic and real terminal evidence.

## Active limits

- The changed checkout and Git Bash terminal flow is qualified on Windows only; macOS is not requalified.
- The app must be running and report ready; production activation also needs a pinned, requalified Orca version.
- Secondmate spawns and Escape are unsupported.
- `terminal create` returns a handle and `terminal.worktreeId`, not a `worktree.path`; FirstMate requires that id to match the prior path-resolved worktree.
- No automatic checkout cleanup exists while Orca can only report `stop_unverified`. Operators must retain both checkout and metadata until independent process-tree proof and a separate cleanup contract exist.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
tests/fm-teardown-endpoint-safety.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
