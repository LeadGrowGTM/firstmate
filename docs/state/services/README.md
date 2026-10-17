---
id: fleet-runtime
title: Fleet runtime
kind: service
status: implemented
summary: Scripts and on-disk records keep launch, supervision, routing, and merge from depending on chat memory.
parent: firstmate
sources:
  - docs/architecture.md
  - bin/fm-spawn.sh
  - bin/fm-watch.sh
  - bin/fm-wake-lib.sh
  - bin/fm-send.sh
diagramLinks:
  Lifecycle: task-lifecycle
  Wakes: wake-cycle
  Routing: secondmate-routing
  Merge: guarded-merge
  Dispatch: dispatch-resolution
diagramDetails:
  - diagram: 0
    node: Records
    section: On-disk records
---

# Fleet runtime

The fleet runtime is the set of bash scripts and files that survive a restarted chat.
The first mate follows them.
A worker cannot invent a second copy of the rules in its own window and have that copy win.

```mermaid
flowchart LR
    Dispatch[Dispatch choice] --> Lifecycle[Task lifecycle]
    Lifecycle --> Wakes[Wake handling]
    Wakes --> Merge[Guarded merge]
    Routing[Second-mate routing] --> Wakes
    Records[On-disk records] --> Lifecycle
    Records --> Wakes
    Records --> Routing
    Records --> Merge
```

The arrows are relationships.
A wake is not a step inside a merge, and a merge is not a step inside dispatch.

## On-disk records

Each task has a status log and a metadata file under the home's state directory.
The status log is an append-only history of events, not the current truth.
bin/fm-crew-state.sh is the owner of current-state reconciliation.
docs/architecture.md states that, and this page does not restate the reconciler's code.
The wake queue is state/.wake-queue.
Second-mate reply expectations are state/pending-replies/.
Those paths are private to the home and are not part of the git project the worker edits.
