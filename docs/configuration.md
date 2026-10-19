# Configuration

Configure where Firstmate keeps its files, which tools launch workers, and how supervision runs.
Start with the directory layout, then use the setting reference for the behavior you want to change.

## Find a setting

| What you want to configure | Start here |
| --- | --- |
| Firstmate's code, private files, or project location | [FM_HOME](#fm_home) and [operational home layout](#operational-home-layout-and-state) |
| Task windows and worker tools | [Runtime backend](#runtime-backend-configbackend--fm_backend), [captain tmux session](#captain-tmux-session-configcaptain-tmux-session), [crew tmux session](#crew-tmux-session-configcrew-tmux-session), [crew names](#crew-names-configmate-short-name), and [harness support](#harness-support) |
| Worker permissions, accounts, or environment | [Claude permission mode](#claude-permission-mode-configclaude-permission-mode), [Grok permission mode](#grok-permission-mode), [Muse permission mode](#muse-permission-mode), [worker account pin](#worker-account-pin-configclaude-account-configpi-account), [worker tool exclusions](#worker-tool-exclusions-configcrew-exclude-tools), and [worker launch environment](#worker-launch-environment-configlaunch-env-allowlist) |
| Backlog, preferences, and memory | [Backlog backend](#backlog-backend-taskstoml--configbacklog-backend), [captain preferences](#captain-preferences-datacaptainmd--datacaptain-sharedmd), and [startup memory budget](#startup-memory-budget-configstartup-memory-budget) |
| Supervision and presentation | [Pi supervision branch](#pi-supervision-branch), [supervision host](#supervision-host-configsupervision-host), and [Calm preference](#calm-preference-configcalm) |
| Automatic reversible work and numeric goals | [Idle sweep and standing targets](#idle-sweep-and-standing-targets) |
| Persistent secondmates | [Secondmate routes](#secondmate-routes-datasecondmatesmd), [Claude Remote Control](#claude-remote-control-configclaude-remote-control), and [Orca view tabs](#orca-view-tabs-configorca-view-tabs) |
| Worktree copies and disk use | [Project capacity](#project-capacity-configproject-capacity), [worktree pool guard](#worktree-pool-guard), [data management](#data-management-configdata-management), and [disk guard](#disk-guard-configdisk-guard) |
| Recurring specialist types for one domain | [Task types](#task-types-configtask-typesjson) |
| Opt-in recurring task intake | [Recurring intake](#recurring-intake-configschedulesjson) |
| Per-run overrides and tuning | [Environment variables](#environment-variables) |

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.

| Location | What it contains | Default relationship |
| --- | --- | --- |
| Firstmate repo root | Shared code, including the scripts in this repo's `bin/` | Most scripts also use this as the operational home when `FM_HOME` is unset. |
| Operational home | Private `state/`, `data/`, `config/`, and `projects/` | Selected by `FM_HOME`. |
| Projects directory | Local project clones | Under the operational home; `FM_PROJECTS_OVERRIDE` can select a different directory for tests and specialized harness setup. |

When `FM_HOME` is unset, most scripts use the repo root as the home.
When it is set, scripts still run from this repo's `bin/`, while `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.

### Root and directory overrides

`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.

`bin/fm-send.sh` requires `FM_HOME` to be set before resolving a target.
Unlike most scripts, it does not use the general fallback, because a steer must not silently resolve against the wrong home.
These variables override individual operational directories for tests and specialized harness setup:

| Variable | Directory selected |
| --- | --- |
| `FM_STATE_OVERRIDE` | Runtime state |
| `FM_DATA_OVERRIDE` | Durable private records |
| `FM_PROJECTS_OVERRIDE` | Local project clones |
| `FM_CONFIG_OVERRIDE` | Local configuration |

### Relative paths and lifecycle safety

Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` saves a path or passes it to another process, it handles each applicable `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory as follows:

- Resolve relative directories against the caller's working directory.
- Preserve accepted absolute spellings unchanged.
- Reject an unresolvable relative directory and name the offending variable.

`fm-spawn.sh` additionally rejects control bytes in those raw directory inputs before shell or filesystem normalization can change which path the backlog gate checks.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured data or state root, and a final-component symlink is refused even when its target remains within that root.

Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim.
Other transient consumers retain their existing shell-relative behavior.

### Backend labels and containers

| Backend | Effect of the operational home |
| --- | --- |
| herdr | `FM_HOME` determines the adapter's workspace label. |
| zellij | `FM_HOME` determines the readable home prefix in visible tab titles, but does not split containers; use `FM_ZELLIJ_SESSION` for a separate session; the full home label also includes a short hash of the resolved `FM_ROOT` path. |
| cmux | `FM_HOME` determines the default config path and readable home prefix in workspace titles; `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read; the full home label also includes a short hash of the resolved `FM_ROOT` path; there is no per-home container split. |

## Operational home layout and state

This section is the single owner of the top-level operational-home layout.
Producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains shared instructions, skills, documentation, workflows, and `bin/`.
Each effective `FM_HOME` contains private operational directories.

`data/` holds durable private fleet records:

- Project and secondmate registries.
- Captain preferences and optional shared captain preferences.
- Learnings, backlog, briefs, scout reports, and the optional per-task no-mistakes pipeline-spend ledger.
- Explicitly installed content-addressed extension packages under `data/extensions/packages/`.

`state/` holds runtime records:

- Task metadata, append-only status events, and endpoint signals.
- Watcher and wake-queue coordination, away-mode state, and generated Relay artifacts.
- Inactive terminal-outcome receipts under `state/terminal-outcomes/`.
- Enabled extension working namespaces under `state/extensions/`.
- Parent-side remote ledger copies under `state/secondmate-summary-cache/`.
- One-shot Bearings reconcile requests under `state/reconcile-notify/`.
- Private secondmate config-reread generations with their retry and quarantine state.
- Per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`).
- Parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).

`config/` holds local gitignored operating choices, including explicit extension bindings under `config/extensions.d/`.

`projects/` holds local project clones.
Firstmate reads these clones, but changes them only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based secondmate sync guards treat a home as dirty.

### Format and lifecycle references

- `bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.

- `bin/fm-contributions.sh` owns durable published-contribution records under each task, observation bounds, equivalent triage-label configuration, and the authenticated contribution check.

- The producing PR and Relay helpers own the fields they append, [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns status-event vocabulary, optional emission-time syntax, and legacy unknown-time handling, and `bin/fm-crew-state.sh` owns current-state reconciliation.

- The [`bin/fm-fleet-snapshot.sh` header](../bin/fm-fleet-snapshot.sh) owns the snapshot's event-time and age fields, including secondmate parent-event projections.

- Wake, watcher, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

### Session-start references

- `bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.

- `bin/fm-startup-network.sh`'s header owns the deferred startup stage that keeps every external-network call and the potentially slow inactive-outcome scan off that digest's blocking path, including its state files and the safety argument for running them later.

- `docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.

- `AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.

- Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md).
Edit it like any prompt when the fleet is empty.
While tasks are in flight, dispatch shared-repo edits to a crewmate.

## Calm preference (config/calm)

The Pi Calm extension and the Claude Code Calm mod share the local, gitignored `config/calm` preference under the effective Firstmate home.
One `/calm` choice therefore applies on either harness.
Both resolve the home in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from their own path under it.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.

### Values and default

| Value or file state | Result |
| --- | --- |
| `on` | Calm on. |
| `off` | Calm off. |
| Absent, unreadable, or unrecognized | Defaults to off. |

Both written values end with one newline.
`max` is a legacy value from a removed third presentation level.
Its behavior is now ordinary Calm, so it is still read as `on`.
A home upgraded from `max` keeps Calm on rather than dropping to off.

### Saving and reloading the preference

Each `/calm` command saves the new choice before changing live presentation.
A failed write leaves the current choice unchanged and is not reported as a saved preference.
Pi replaces the file atomically; the Claude Code mod uses the plugin API's plain file write.
The Pi extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.

The Claude Code mod reloads it on every `session.start`, including same-process session replacement.
It also loads the preference lazily before any row that can draw ahead of that event, including during `claude --continue` restoration.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Idle sweep and standing targets

The idle sweep runs inside the existing watcher's supervision heartbeat, across all primary harnesses, without another daemon.
It runs by default and reads only this home's backlog, prepared briefs, recorded worker endpoints, and project clones.
A marked live-lab home requires its recorded private tmux socket; a caller inside tmux must also be in that lab's pane.
Secondmate endpoints are supervisors and do not count as local workers; no child home is inspected.
Runtime backends without the canonical recovery-grade agent classifier conservatively hold the sweep when they have a recorded worker.

This section owns the `config/targets.json` schema for numeric limits per home.
An absent file uses these defaults; a partial object overrides only the supplied fields:

```json
{
  "open_prs": 4,
  "red_default_branches": 0,
  "stale_backlog": 0,
  "stale_days": 14
}
```

All limits are nonnegative integers; `stale_days` must be positive, and unknown fields are refused.
`open_prs` is an inclusive maximum, so the default implements fewer than five open PRs.
The forge metrics cover the authenticated GitHub user's open PRs and default-branch failures in the immediate local clones under this home's projects directory.
Non-GitHub clones and symlinked project entries are outside these GitHub metrics; unavailable evidence for a GitHub clone makes them unknown.
Default-branch failures include failed commit statuses and completed unsuccessful check runs on the current head; pending checks alone are not red.
The local backlog metric counts unfinished structured rows unchanged for at least `stale_days`, including held rows for visibility, without authorizing work on them.
The initial implementation supports the local markdown backlog; another tasks-axi backend is refused explicitly.
The heartbeat records each row's section state, content, and last observed change in `state/idle-sweep-backlog.json`.
The first observation establishes the age baseline; row creation dates are not used as evidence of last change.
The evaluator reports unknown before a row is observed or after its content changes between observations.

`bin/fm-targets.sh` prints each target's current value, limit, and nonnegative gap without writing state or contacting other homes.
Its `--json` output also lists per-project forge values and known stale row IDs.
Missing forge or observation evidence remains unknown.
Portable behavior fixtures live in `tests/fm-idle-sweep.test.sh`.

An absent `config/idle-sweep.json` enables the sweep with the limits from `config/targets.json`, or the defaults when that file is absent, and considers prepared queued tasks with a reversible brief and delivery contract.
An indented `Idle target: red_default_branches`, `Idle target: open_prs`, or `Idle target: stale_backlog` line in a backlog row associates that task with one standing target; an untagged row remains ordinary backlog work.
The file can switch the sweep off:

```json
{
  "enabled": false
}
```

Prepare queued tasks and their normal briefs with the right authority and permissions.
Free-form backlog titles alone never confer reversible-work authority.
Each prepared brief must contain these exact lines in its Firstmate specification:

```text
Never merge, deploy, spend money, contact a client, answer a captain decision, or alter a captain-held item.
If the task needs one of those actions, report needs-decision to firstmate and stop.
```

Set `enabled: false` to stop future automatic batches; existing workers continue normally.
The sweep derives scout delivery from a scout row and ship delivery from the brief's `Delivery contract: mode=` line.
Unknown fields are refused.
Each backlog row supplies the local project clone and must be unheld, unblocked, queued ordinary work with no metadata record or open task decision.
Targeted work runs only while its gap is positive; red-branch work must name a red project and stale-backlog work must name a stale row.
Before targeted dispatch, the sweep rechecks the target's current gap and project or row match.
An open-PR step should prepare a review or fix, since meeting that target may still require a captain-approved merge.

The sweep starts a batch only when no ordinary worker is live and all effective Codex account windows report known, fresh remaining quota strictly above 15 percent.
It rechecks home idleness, quota, complete backlog row, brief boundary, and open decisions before each start, selects at most three steps, and orders red-branch work before other target work, then ready backlog work in backlog order.
Unmeasured red-branch evidence holds the batch rather than allowing backlog work to outrank an unknown failure.
Dispatch uses the normal `bin/fm-spawn.sh` path with Codex `gpt-6.1-sol`, the prepared delivery mode and branch contract, and yolo off; backend refusals stop the batch without a fallback.
The sweep reads briefs without editing them and refuses work whose prepared brief lacks the reversible-work boundary above.
Successful starts produce one named status line in `state/idle-sweep.status`; concurrent heartbeat invocations share a local lock, and existing task metadata prevents redispatch.
Target collection has a shared 120 second budget across the batch; a started `bin/fm-spawn.sh` launch runs to completion under its own lifecycle guards.
A configuration or dispatch failure returns a normal `check: idle-sweep` wake to supervision, and that wake carries the one-line reason recorded in `state/idle-sweep.status`.
That delivery accounts for the new refusal record, so supervision is not asked about the same refusal again.
Script headers and help own the executable mechanics.

## Pi supervision branch

On a Pi primary, an in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews.
Main-only rows stay on the captain-facing path.
[docs/pi-supervision-branch.md](pi-supervision-branch.md) defines its conversation lifecycle, row eligibility, mixed-queue dispatch, heartbeat routing, and pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.

Bash absorbs a genuinely no-op heartbeat before it reaches Pi.
Every watcher-failure alarm stays on the captain-facing main path.
If the branch breaks, wakes still fall back to main in both postures.
The legacy `state/.afk` daemon flag has no effect on Pi.

### Attended and away authority

While the away-posture record `state/.afk-contract` exists:

- The branch takes every actionable row.
- No processing turn opens on the parked main.
- Main's standing authority moves to the branch through the guarded scripts, each retaining its own gate.

[docs/pi-supervision-branch.md](pi-supervision-branch.md#postures) defines that posture.

While attended, the branch cannot merge a PR, land local work, freshly spawn, or answer a decision.
These are the bounds set by the captain-approved architecture.
Every existing captain gate remains unchanged in either posture.
Homes on other primary harnesses do not load the Pi branch extension; shared per-task lease behavior is owned by `bin/fm-lease-lib.sh`.

`AGENTS.md`'s `state/` inventory routes the branch's runtime files to their format and lifecycle owners.

### Outcome delivery and acknowledgement

While attended, a captain-facing branch outcome (verdict `captain`) is saved as one exact visible transcript entry keyed by sequence.
It then opens one processing turn on main for that sequence.
The turn stays open until main acknowledges the sequence through its `fm_branch_processed` tool.
While away, the entry is saved, but processing waits until the away-posture record is archived.
The branch prompt's "Verdict: routine or captain" section owns the distinction between captain-facing, unsolicited routine, and unchanged-review outcomes.

The generated [Pi supervision protocol](supervision-protocols/pi.md) owns main's event ownership, acknowledgement duty, and conversational treatment for merged outcomes, while the persisted entry itself owns captain visibility.
A task-level routine no-change outcome or a no-change heartbeat explicitly reported with `silent=true` is delivered without a rendered note; the branch prompt owns task-level eligibility, and every other routine outcome still appends a rendered, sailboat-prefixed note.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

The branch can run on a cheaper model than main because supervision is an easier job than the captain's own conversation.
It can also use a lower reasoning effort because supervision needs less reasoning than that conversation.

### Choose a model and effort

The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.

The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.

Both picks change the supervision branch alone and never the captain's own conversation model or effort.

### Saved settings and available models

The command saves the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`.
Both live under the effective Firstmate home, resolved in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.
Firstmate keeps no model catalog of its own.
The list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.

A provider that exists only because an extension registered it inside the captain's session, such as pi-devin-auth's `devin`, is offered and can be pinned or followed like any other; [pi-supervision-branch.md](pi-supervision-branch.md#cost-model-and-the-byte-stable-prefix) owns how that registration reaches the isolated branch runtime.
Stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.

### Model file format and default

The model file holds one `<provider>/<model-id>` line followed by one newline.
Parsing splits at the first `/`, so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin.
The branch then follows main's current model, applied explicitly and live whenever main changes models mid-session.

### Following a native Codex model

When main uses `codex-native`, following main explicitly selects the same model through ordinary Pi's `openai-codex` provider, so the background branch owns an independent Pi conversation.
If that ordinary Pi model is unavailable, the branch refuses to build and returns the notification to main; it never inherits the main native thread or silently selects a different model.

Picking "Follow main" under a `codex-native` main reports that same `openai-codex` model, or that same refusal, because the command and the branch build share one follow rule.
A `codex-native` branch pin is refused and excluded from the picker.

### Applying and changing a model pin

A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.

The file decides the branch model on every build: the new conversation opened at each main session start, and a reopen after a model or effort change within a session.
It overrides the model Pi would otherwise restore from the reopened branch session, so the choice survives both cases.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.

### Unavailable models

For ordinary Pi providers, an unpinned build passes no model override only when main's model is unknown or this home's stored credentials cannot run it in the isolated branch runtime.
This preserves the behavior from before the file existed.
Model choice never loses the wake.
If main's model could not be applied, the command reports that failure instead of reporting a change that did not take effect.
If a pin names a model Pi cannot return because it is unknown or has no configured credentials, the branch refuses to build.
It sends the accepted wake back to the watcher's captain-facing main path, as any other unreachable branch does.
It never silently falls back to main's model.

Picking also releases the live branch so the next wake reopens this session's own branch conversation under the new model without waiting for a session replacement.

### Effort file format and available levels

The effort file holds one Pi thinking level followed by one newline.
Model and effort pins are independent: a captain may pin either, both, or neither.
The effort step follows the model step because the effective branch model determines which levels exist.
The menu uses Pi's own supported-level list.
Models without extended levels do not offer them; a non-reasoning model offers only `off`.

The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the most recent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.

### Applying and changing an effort pin

An absent, unreadable, or unrecognized file means no effort pin.
The branch then follows main's current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.

Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.

Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.

### Unsupported effort levels

Pi maps an unsupported pinned level to the branch model's nearest supported level.
Effort never causes the branch to refuse a build.
The captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will actually use.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

### Cancellation and inheritance

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick from the same run.
The command's closing message reports both choices as they will take effect.

Both choices are local to each Firstmate home and are not part of secondmate inherited configuration, the same as the Calm preference; a secondmate home pins its own supervision model and effort with its own `/supervision-model`.

## Supervision host (config/supervision-host)

Two optional local, gitignored files control the supervision host for this home: `config/supervision-host-off` opts the home out, and `config/supervision-host` opts a home in and selects its engine.
The host runs the supervision branch's contract on a headless engine session beside a non-Pi primary.
[docs/supervision-host.md](supervision-host.md) defines its design, current scope, and verified engines.
A Claude, Cursor, OpenCode, omp, Grok, or Codex primary can run the host.

A present `config/supervision-host-off`, whatever it holds, opts the home out on every primary.
Otherwise a Claude primary runs the host by default: with no `config/supervision-host` it runs exactly as with an empty one, at the Claude engine's default model.
A Cursor, OpenCode, omp, Grok, or Codex primary runs the host only while `config/supervision-host` exists and the home is not opted out.
A home that does not run the host behaves exactly as it does without it, and a Pi primary keeps its in-process supervision branch whatever either file says.
`fm_supervision_host_enabled` in `bin/fm-supervision-engine-lib.sh` implements this gate for every reader.

While the home runs the host, the primary's arm owner runs it in place of the watcher arm.
The host handles wakes on the engine under the [posture rules](supervision-host.md#postures), including an away record and attended operation on a Claude or Cursor primary with a verified dialog mirror.
On that home, `/afk` launches no away daemon; see [Quiet mode](supervision-host.md#quiet-mode) for `/quiet`'s attended statement and fallback.
The same gate governs the primary's dialog-mirror hooks (`bin/fm-host-mirror.sh`), which record on a Claude or Cursor primary ([supervision-host.md](supervision-host.md#the-dialog-mirror)).
Grok's arm command is rendered at session start, so a change to its host mode takes effect at its next session start; the other arm owners check the gate at every arm.

### Engine selection

`config/supervision-host` may be empty or hold one line `<engine> [<model>]`:

- empty or `default` selects the primary harness's own engine at that engine's default model (`sonnet` for the Claude engine);
- `<engine> [<model>]` names a verified engine, currently only `claude`, and optionally the engine's own model name or alias; `default <model>` selects the primary harness's engine with that model.

Only Claude has a verified engine of its own, so a Cursor, OpenCode, omp, Grok, or Codex home names `claude` in the file.

### Failures, when changes apply, and inheritance

An unverified engine, a primary without a verified engine, or a malformed line leaves the host without an engine.
It takes no wake, so every wake reaches main as it would without the host.
Each away-posture wake includes a line naming the problem.
The running host reads both files at every wake, so an engine change or an opt-out takes effect at the next wake without a restart.

The opt-out is inherited into secondmate homes: a primary that opts out also opts its secondmates out, and clearing it restores each mate's own host setting at its next spawn or convergence.
The primary-authoritative propagation contract, including removal of a mate's local opt-out when the primary has none, is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
`config/supervision-host` is local to each home and not inherited, because each home's engine and model are its own choice.
While the home runs the host, main's lease-checked commands also take the per-task lease lock, so a claim by the host's engine cannot race a mutation main already started (`bin/fm-lease-lib.sh`).

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
A home may instead select another tasks-axi adapter such as Beads through its own `.tasks.toml` or `TASKS_AXI_BACKEND`; firstmate still uses only tasks-axi verbs for routine backlog reads and mutations, and the adapter maps `start` and evidence-bearing `done` transitions to its native statuses and evidence fields.
The [captain-hold lifecycle mechanism](captain-hold-lifecycle.md#creating-a-hold-hold) owns task option projection into Bearings, which currently supports markdown backlogs only.

### Captain holds on Beads

Captain-hold row creation is owned by [`bin/fm-captain-hold.sh`](../bin/fm-captain-hold.sh) `hold`: when no work item exists, it creates an ordinary backlog row (`--kind captain` metadata; Beads native type `task`) and then applies the captain hold.
Captain rows have no Beads due semantics, so that create path waives a Beads `due.required` setting rather than passing a synthetic `--due`; `--until` remains the optional hold deferral.

Do not register a Beads `types.custom` `captain` type for this: captain is a hold kind, and the fleet Beads `due.required` policy for ordinary work stays in the federated beads config.

### Automatic dispatch and completion

When the automatic transition gate applies, dispatch and completion each move the work item in the same run that creates or removes its task record.
The ordinary successful path therefore keeps the backlog and live task set in sync ([`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh)).
Under that gate, dispatch accepts only an unheld, unblocked Queued or In flight item in this home; a missing, Done, held, or dependency-blocked item is refused before any endpoint or local copy is created.

[`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh) refuses `add --start` and its `create --start` alias.
Either would place a row In flight without a task record, status file, or inbox, counting it as live work that nobody is doing.
The wrapper still passes through the documented direct transition `tasks-axi start <id>`.
Completion refuses to report success until the item is closed, and session start reconciles this home's own books after an interrupted run.

When a spawn is interrupted after launch delivery began, its exit path re-reads the paired task record and the backlog row under the same per-task lock as the commit, repairs a row the commit believed it had moved, and reports only what was verified or honestly attempted, never intent phrased as outcome ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh); [`tests/fm-backlog-atomicity.test.sh`](../tests/fm-backlog-atomicity.test.sh)).

### Which backlog receives a transition

Automatic transitions run from the configured data directory's parent, letting that home's effective tasks-axi configuration address its selected adapter while keeping relative scout-report links rooted there.
A markdown backlog is additionally addressed by an explicit `--file` at `<data>/backlog.md`, so the change lands in the home that owns the task regardless of the caller's working directory.

Any other configured adapter is addressed by that root alone, because `--file` would override the adapter's own workspace path.

### Exemptions and refusal conditions

The gate does not apply to persistent secondmates, manual-backend homes, or markdown homes without a backlog file.
Those retain their existing persistent-agent, manual, or ad-hoc lifecycle behavior.
Configured non-markdown adapters remain active without that file.
Migrated-hold resolution on a beads home reads its graph path, binary, and prefix from the root `.tasks.toml` `[beads]` section only, and refuses (rc=2) when the beads backend is selected elsewhere (a `TASKS_AXI_BACKEND` override or user-level config) with no root-level `[beads]` section.

On an automatic-backend home, missing or incompatible `tasks-axi`, an unresolvable configured data directory, or one containing a control byte fails lifecycle work before mutation.
An unreadable backend configuration can refuse lifecycle work before the no-backlog exemption applies; repair the configuration named in the diagnostic ([backend resolution contract](../bin/fm-tasks-axi-lib.sh)).

### Handoffs between homes

Secondmate handoffs bypass that routine-backend choice: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and delegates the item move to `tasks-axi mv`; its [script header](../bin/fm-backlog-handoff.sh) owns route-specific wake outcomes and remote outbox release.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.

Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.

### Required tools and manual mode

Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.

Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
A `manual` home owns its backlog file outright: the lifecycle transitions above are skipped there, dispatch and completion never fail over the file's contents, and a completed teardown prints the hand edit that is owed instead.

Absent or `tasks-axi` selects the tasks-axi path.
On the default markdown adapter, tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

### Using a separate operational home

The tracked `.tasks.toml` paths resolve against the directory tasks-axi runs in, not `FM_HOME`, so a bare `tasks-axi` run from the code root addresses the code root's `data/` whenever the home lives elsewhere.
tasks-axi replaces its target by renaming a temporary file over it.
If the target is a symlink, the write replaces it with a regular file.
Linking the code-root copy into the home therefore forks the queue on the first write instead of keeping the copies in sync.

Run every routine Firstmate backlog command through [`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh).
Like lifecycle transitions, it addresses this home's backlog and archive from any working directory.
Bootstrap reports a code-root `data/backlog.md` or `data/done-archive.md` that is not this home's own file as a `BACKLOG_RECONCILE: code-root ...` line, even in a read-only session.

## Crew names (config/mate-short-name)

By default every tmux task window shows `fm-<task-id>` and every ship branch is `fm/<task-id>`, so a second mate's crew reads as the first mate's own.
Set `config/mate-short-name` in a home to the short form of the mate that owns it, for example `nap` in Napoleon's home or `chu` in the main home.
New work that home starts then reads as that mate's crew:

| What | Unset | Set to `nap` |
| --- | --- | --- |
| Worker or scout window label | `fm-<task-id>` | `nap-crew-<task-id>` |
| Window label of a second mate this home launches | `fm-<id>` | `<id>`, its plain name |
| Default ship branch | `fm/<task-id>` | `nap/crew/<task-id>` |

The file holds one short form of 1-16 lowercase letters, digits, and inner dashes, on one line with an optional final newline.
A missing or empty file keeps today's names exactly.
Invalid content never blocks work: the operation prints one warning naming the file and falls back to the unset names, `fm/` branches and no label.
[`bin/fm-crew-name-lib.sh`](../bin/fm-crew-name-lib.sh) implements this format and the resulting names.

The branch is only a default: a project's registered `branch=<prefix>` and an explicit `--branch-prefix` still win, and `bin/fm-project-mode.sh --branch-prefix <project>` reports the resolved prefix.
The label is display only.
Scripts keep addressing every task window by its `fm-<task-id>` name, so steering, peeking, monitoring, and recovery are unchanged.
Only the tmux backend shows the label.
Firstmate records each label on the task window as the `@fm_label` window option.
Spawning a labeled task leaves tmux's built-in and operator custom status formats unchanged; formats that render the window name keep displaying `fm-<task-id>`.
Firstmate's status theme (`bin/fm-statusbar.sh theme`, loaded by the tracked `fm-statusbar.tmux` snippet) shows the label when loaded before or after the worker is spawned.
The window name reported by `tmux list-windows` remains `fm-<task-id>` in every case.
Herdr, zellij, cmux, and Orca keep their current tab names, because those backends also use the tab name to find and recover a task.
Existing branches, pull requests, and live windows are never renamed.
A relaunch restores a new task's recorded label on its tmux window, whether it reuses that window or must replace it; older tasks without a recorded label keep their original names.
A second mate's respawn keeps its recorded label even if this home's short form changes.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.

| Runtime backend | Verification status | Reference |
| --- | --- | --- |
| `tmux` | Verified reference backend | [`docs/tmux-backend.md`](tmux-backend.md) |
| `herdr` | Has its own required CI lane | [`docs/herdr-backend.md`](herdr-backend.md) |
| `zellij` | Experimental; no dedicated real-backend CI lane | [`docs/zellij-backend.md`](zellij-backend.md) |
| `orca` | Experimental; no dedicated real-backend CI lane | [`docs/orca-backend.md`](orca-backend.md) |
| `cmux` | Experimental; no dedicated real-backend CI lane | [`docs/cmux-backend.md`](cmux-backend.md) |

Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.

### Backend selection order

New spawns choose the backend in this order:

1. An explicit `--backend` flag authorized for that exact task by a present captain instruction or the task's own accepted brief.
   A later task cannot inherit that authority by analogy.
2. `FM_BACKEND`.
3. The first non-empty line of local, gitignored `config/backend`.
4. Runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals.
5. Default `tmux`.

If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.

Auto-detected Herdr stays silent like tmux, while auto-detected cmux prints a stderr notice naming `config/backend` and `--backend tmux` because cmux remains experimental.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.

### Accepted backends and secondmate limits

Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.

`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.

### Liveness classification

The session-start secondmate liveness sweep and the watcher's secondmate liveness tick use the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.

The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.

### Dependency and socket checks

- A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.

- A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.

- A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.

A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.

### Task metadata

Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.

- Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.

- A tmux task records `tmux_socket=`, the socket path its tmux server reported at spawn, which the endpoint-absence proof reads; an older record without it is still accepted.

- A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.

- A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
- An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.

- A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.

### Task selectors

Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.

Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.

Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These rules are the single owner of the task-selector vocabulary.
Backend guides and other documents refer here instead of restating the resolution order.

### Teardown identity checks

`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.

Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.

### Herdr homes and presentation

`FM_HOME` determines Herdr's home label: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.

The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.

### Zellij sessions

For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.

Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.

### cmux workspaces

cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.

Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Captain tmux session (config/captain-tmux-session)

The optional local, gitignored `config/captain-tmux-session` file names the tmux session that receives every new second-mate window created on the tmux backend.

When [crew tmux session](#crew-tmux-session-configcrew-tmux-session) is unset, the same file also receives new ship and scout windows.

The file holds one session name on one line, with an optional final newline.
A name is 1 to 64 characters: a letter or digit, then letters, digits, underscores, or dashes.
An absent file, or a file that is empty or only a newline, keeps today's placement.
Today, a launcher that is already inside tmux uses that pane's session, and a grouped session resolves to its base session when the base still exists.
A launcher outside tmux creates or reuses a detached session named `firstmate`.

When the file names a session, the new window is created in that exact session on the tmux server the launcher is already using.
Firstmate creates the named session when it is missing, without attaching, switching the current client, or changing any existing window.
An unreadable file, a directory, more than one line, or a name tmux would reject stops the launch and names the file.
It does not choose a different session.

A local secondmate home with no file of its own reads `config/captain-tmux-session` from the absolute `parent_home` in its `.fm-secondmate-parent` record.
A secondmate home that sets its own file uses that name.
A remote secondmate record has no local parent home, so an unset file keeps today's placement on that remote server.
Herdr, zellij, cmux, Orca, and Boat launches do not read this file.

The recorded endpoint is the session and window that were created, plus the socket path that tmux server reports.
A relaunch that finds the recorded window still present adopts that window where it is.
A relaunch that has to create a window, because the recorded one is gone, uses this same rule.
Existing live windows are never moved or killed by this setting.

## Crew tmux session (config/crew-tmux-session)

The optional local, gitignored `config/crew-tmux-session` file names the tmux session that receives every new ship window and scout window created on the tmux backend.

The file format, parent inheritance, launch refusal, and detached session creation are the same rules as [captain tmux session](#captain-tmux-session-configcaptain-tmux-session), read from `config/crew-tmux-session` instead of `config/captain-tmux-session`.
An absent, empty, or newline-only file keeps that captain-session placement for ship and scout windows.
A remote secondmate record does not read a local parent file, same as the captain file.

Firstmate chooses which file to read from the task kind it is already launching.
A second-mate charter reads only the captain file.
A ship or scout reads the crew file, then the captain placement when the crew file is unset.
The window name is not part of that choice.

A relaunch that creates a replacement window uses this same choice, and a relaunch that finds the recorded window still present adopts that window where it is.
This setting does not move or kill an existing window.
`bin/fm-crew-session-migrate.sh` moves one home's live ship and scout windows into the crew session named here, and its header owns the dry-run default, the refusal rules, and the exact invocation.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.

Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.

That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.

Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.

### Channels and overrides

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.

Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.

A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.

### Precedence and session boundary

`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.

### Secondmate propagation

When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.

The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Fleet activity ledger (config/fleet-ledger)

See [`fleet-ledger.md`](fleet-ledger.md) for the opt-in setup, record contract, and limits.

## Waiting worker spends no turns (config/wait-no-turns)

The optional local, gitignored `config/wait-no-turns` presence flag opts this home into keeping a waiting worker from spending turns until it is answered.
With it present, ship and scout briefs gain the `# Waiting` section and the foreground no-mistakes drive text, every brief's inbox section keeps the natural-checkpoint check and adds that a waiting worker does not poll or list its inbox because a waiting instruction rings, a pending-reply recovery waits while that mate has its own open decision or blocker, and a fire-and-forget steer whose doorbell did not land gets one later ring.
With the file absent, generated briefs omit the waiting section and the no-poll inbox line, the drive text backgrounds the call, recovery sends during an open decision, and a fire-and-forget steer is not owed a retry ring.
The flag is a home-local preference and is not inherited by secondmate homes.

## No-mistakes pipeline spend (config/pipeline-spend)

The optional local, gitignored `config/pipeline-spend` presence flag opts this home into recording per-task no-mistakes pipeline spend in `data/pipeline-spend.jsonl` during teardown.
When the flag is absent, teardown skips recording and the recorder exits before reading task metadata, no-mistakes state, or the spend ledger.
An existing ledger is left untouched while recording is disabled.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional local, gitignored `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it present, every referenced task must independently show positive work evidence, and an eligible bare turn-ended task that lacks authoritative proof may satisfy that requirement when its pane content changed since the previous poll.

### Evidence and time limit

It stays opt-in because the other two proofs read a verdict the harness itself vouches for while this one infers execution from rendered bytes; with the flag absent triage behaves exactly as it did before.
`FM_TURNEND_CHURN_ABSORB_SECS` is a positive integer number of seconds, defaults to `900`, and bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway.

An invalid value fails closed and surfaces the wake.
The bound is required rather than cosmetic because churn and pane staleness read the same pane.

The flag is a home-local supervision-noise preference and is not inherited by secondmate homes, which run their own crew mix.
[`architecture.md`](architecture.md) owns the triage contract and `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed boundaries.

## Parked-gate wait deferral (config/wedge-defer-parked-gate)

The optional local, gitignored `config/wedge-defer-parked-gate` presence flag opts this home into a default-off second form of wait evidence in the watcher's wedge timer.

### When a waiting gate defers an alarm

With it present, a provably-working pane about to escalate is also deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's own current state is a validation gate whose answer is owed to the supervisor and whose decision for that run is still open, and the recheck names the supervisor and the action that clears the lane instead of reporting a suspected wedge.
It stays opt-in because the other evidence is the worker's own declaration about its own silence, while this is derived from a pipeline's gate state, so which lanes give up the escalation ladder for it is a home's choice.

With the flag absent the wedge timer spends no fold or current-state read for it, writes no record, and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes, which supervise their own crew and own that trade separately.

[`architecture.md`](architecture.md) owns the wait-evidence contract and which records may take the ladder away; `bin/fm-watch.sh`'s `wedge_wait_evidence` owns the exact derivation and its fail-closed boundaries.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` sets `test.evidence.store_in_repo: true` and pins `commands.lint` to `bin/fm-lint.sh`, the same owner CI invokes.
Storing evidence in the repo publishes each run's test artifacts to the orphan `no-mistakes/evidence` branch and links them from the PR body, instead of keeping them on local disk under the no-mistakes home.

That branch shares no history with code branches, so evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
The [`firstmate-coding-guidelines` skill](../.agents/skills/firstmate-coding-guidelines/SKILL.md#no-mistakes-test-configuration) owns why `commands.test` stays absent and targeted validation belongs to the evidence path.

`commands.test` executes code, so no-mistakes honors it only from the default-branch copy of `.no-mistakes.yaml`; a pushed branch cannot change what the gate runs.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.

Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.

Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.

There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.

### Set and validate the budget

To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.

### Accounting and curation

Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.

An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.

The helper's header owns exact parsing, publication, and report output mechanics.

### Daily startup growth check

A home can arm a lightweight daily growth monitor with `bin/fm-startup-growth-check.sh arm`.
It writes `state/startup-growth.check.sh` and binds it through the existing authenticated watcher-check mechanism, so no extra daemon or scheduler is installed.
Registering it is a reason to watch on the same terms as the [watched-tool check](#watched-tool-updates-configwatched-toolsjson), so an armed home keeps needing a watcher after its last task is torn down.
Use `bin/fm-startup-growth-check.sh disarm` to remove the check and its local report record.

The check evaluates at most once per day and stays silent when nothing meaningful changed.
A due evaluation uses file metadata and byte sizes before any content inspection: it asks `bin/fm-startup-memory-budget.sh report` for the budget verdict over `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, watches the `data/projects.md` and `data/secondmates.md` that session start also prints in full for growth without entering that budget total, and separately watches the tracked startup/instruction owner files described by the script header.
`bin/fm-startup-memory-budget.sh` remains the sole owner of the budget total and its verdict, so the check never re-derives either: when that owner annotates an overrun caused by the primary-owned `data/captain-shared.md` alone, a secondmate home is not woken about an overrun it cannot act on.
A secondmate home is likewise not notified about per-file growth of that same primary-owned `data/captain-shared.md`, which it receives read-only; the growth is still observed and recorded, and a primary home reports it normally.
Those tracked bytes are code and instruction-surface size, not prompt-memory cost.
The check does not run session-start, bootstrap, network checks, model calls, repository refreshes, `/stow`, or full preference/learnings rereads.

Growth is measured against a per-file baseline retained in the check's own state record, so accumulation that stays under one day's threshold is still caught once it adds up; reporting a file rebases its baseline to the reported size, so accepted growth then stays silent.
A surface observed for the first time is baselined silently, including the first content of an optional file that did not exist yet when the check was armed, and an established baseline survives that file disappearing and coming back.
The fixed growth thresholds are inspectable in the script header: 2048 bytes for tracked startup/instruction files and 250 estimated tokens for the printed startup-memory files.
Budget overrun, unsafe or unreadable inputs, missing required tracked owner files, or material growth are reported once and deduplicated until the finding changes or clears; the report line is delivered before the check advances its own record, so a state-publication failure can repeat a finding but never swallow one.
That one line goes out through the shared per-line digest cut, so an over-long finding set carries the repo's `[truncated]` marker instead of ending mid-finding, while deduplication keeps comparing the full uncapped set.
Older bulk learning files remain reference-only; this monitor neither loads nor merges them.
A reported review need is only a recommendation, not cleanup authority.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.

With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.

The flag is per home and is not inherited by secondmate homes, because stow cadence is a property of the home doing the stowing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.

The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.

### On-demand mates

`data/secondmate-on-demand` sits beside the registry and selects mates that stay down until work is routed to them.
[`bin/fm-secondmate-registry-lib.sh`](../bin/fm-secondmate-registry-lib.sh) owns the file format and read rules.
Session-start recovery, the liveness check, and secondmate restart leave a listed mate stopped.
The Claude status line omits a listed mate.
When routing work to a stopped local mate, start its recorded home with `bin/fm-spawn.sh <id> --secondmate` before handoff, which needs a live receiver endpoint.
This example is documentation only:

```
health
lead-haven
```

### Claude status line

When Claude uses `bin/fm-statusbar.sh claude-line --task <id>` as its `statusLine` command, the line keeps the model and `Ctx %` readout and places a compact live-secondmate summary beside it.
Visible local mate entries show an id and latest active task state, while remote mate entries say remote.
The summary counts open captain decisions in the primary and eligible live local mate homes, and reads durable records through a short background cache so rendering does not wait for fleet probes.
Firstmate adds the command to spawned Claude workers when neither their account nor project already defines a `statusLine`; the main Claude session needs its own `statusLine` setting pointing to this command to show the summary.
When its cache is available, the line ends with compact remaining quota for Muse, Grok, the separately labelled Claude gmail and second accounts, and Codex.
The `claude-segments` command supplies the mate and usage segments to custom `statusLine` wrappers.
The command's [header](../bin/fm-statusbar.sh) owns the exact fields, account sources, unavailable states, truncation, reset times, and refresh behavior.
This Claude line is separate from the [primary tmux session bar](tmux-backend.md#watching-the-crew), which continues to show live crew and secondmate counts.

### Remote routes and validation

A remote route adds `host:` and `root:` before the existing fields and places the whole secondmate home on that SSH host; the bounded [Boat overflow sender](remote-secondmates.md#code-only-boat-overflow) can dispatch code-only workers through its purpose-built route.
[`remote-secondmates.md`](remote-secondmates.md) owns current remote setup, operation, and safety behavior.

Use `fm-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.

### Provision a local home

Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local firstmate worktree for the secondmate home.
For remote provisioning, including supplied project origins, follow [Remote second mates](remote-secondmates.md#provision-a-route).

Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.

A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.

The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.

### Project modes and backlog handoff

Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it refuses In flight, Done, or non-secondmate homes, and its [script header](../bin/fm-backlog-handoff.sh) owns route-specific wake outcomes and retries.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.

### Identity markers and upgrades

Each seed writes an `.fm-secondmate-home` identity marker at the home root, alongside a durable `.fm-secondmate-parent` record of the home's route to its parent (see "Provision a route" in [`docs/remote-secondmates.md`](remote-secondmates.md)).
The tracked root `.gitignore` ignores both markers, so validation can read them without making a freshly seeded home appear dirty to porcelain-based safety checks.

This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.

A local standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## Orca view tabs (config/orca-view-tabs)

The optional local, gitignored `config/orca-view-tabs` file gives each secondmate on the tmux backend an Orca desktop tab that views its window.
It accepts one line containing `on` to open new tabs or `off` to prevent them, with surrounding whitespace ignored; an absent file also means `off`.
Turning it off prevents future automatic tabs and leaves existing tabs open for the operator.
Any other content is treated as `off` with a one-line warning, so the file never stops a spawn.
The home that spawns the secondmate reads the switch, and secondmate homes do not inherit it.

The optional home-local `config/orca-view-project` file selects the Orca project for both automatic tabs and the public `open` and `window` helpers.
It contains one nonempty Orca worktree selector, passed as a single `--worktree` argument, preserving Windows paths and spaces.
An absent file defaults to the `firstmate` project's worktree `33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate`.
An unreadable, empty, or multiline file reports a note and skips opening a tab.
This selection is independent of the Firstmate code root, so a WSL checkout path does not select the unrelated `mitch/project` entry.
With the switch on, every secondmate spawn or relaunch opens one Orca terminal, titled with the secondmate id, on that selected Orca project.
The tab attaches a grouped tmux view session that shows exactly that secondmate's window, so each tab follows its own window without moving any other viewer.
It prefers `fmview-<id>` and chooses a distinct name when a candidate is occupied by any unrecorded session or another task's view.
A recorded view for this secondmate is reused only while it still tracks this secondmate's window.
The six hand-opened `orca-*` sessions are never selected or tracked by automatic opening.
It never adopts a view recorded for another secondmate.
Tracking appends an identifiable hook without replacing existing local or inherited hook entries; untracking removes only that entry.
The view session tracks the window by its stable tmux window id, never by index or name, and returns to it whenever it is moved off it, such as after a relaunch or another window closes.
When the secondmate's window itself is gone, the view detaches and removes its tracking instead of displaying another agent's window.
The base session itself is never accepted as a view or given view tracking.
The tab's Orca identity is forwarded into the secondmate's launch, so Orca shows the secondmate as working, waiting on you, or done on that tab.
Each opening uses a unique identity handoff and accepts only the tab identity returned for its fresh terminal handle.
Waiting covers a permission prompt and a question the agent asks.
Those states come from Orca's Claude hooks, so they appear only for a Claude configuration directory Orca has installed its hooks into.
A secondmate relaunch, including a subscription switchover, opens a fresh tab and leaves the previous tab open.
If a fresh tab cannot open, the relaunch keeps the previous recorded tab and its identity.
Firstmate never closes view tabs or kills their grouped tmux sessions, including failed opens, replacement, teardown, switch-off, and recursive cleanup.
Unused views remain for the operator or ordinary tmux session cleanup; orphaned views detach when their tracked window disappears.
When Orca, its command line, or the Orca project is unavailable, the spawn continues without a new tab and prints one note.
Ship and scout workers never get a tab, and other runtime backends ignore the switch.

The primary session is not spawned by Firstmate.
To give it the same kind of tab, run `bin/fm-orca-view.sh open --target <session>:<window> --view-session fmview-main` once from the primary's home.
That tab shows the primary's window, but its states need the primary's own launch to carry the tab's identity, which this command does not change.

Any home, the primary or a secondmate, can also pop open a tab on one window of its own tmux server with `bin/fm-orca-view.sh window <@N>`, naming the window by its stable tmux id.
It needs no switch, reuses the same tab-opening code and window-following view, and reaches Orca on WSL through an interop socket it proves live rather than the one the tmux server inherited.
When Orca is unreachable it says why and exits without a tab.
`bin/fm-orca-view.sh --help` owns the command line lookup, the tab command, and the identity it forwards.

### Giving already-running sessions their identity

Sessions launched before the switch was turned on carry no Orca identity, so Orca never shows them as working or waiting.
They get one at their next relaunch, and nothing here stops or interrupts a running session.
For secondmates, set `FM_HOME` to the home that spawned them, turn on its switch, then run [session refresh](session-refresh.md) with their ids.
Its [idle and eligibility guards](session-refresh.md#what-it-refreshes) determine which agents relaunch; a successful Orca opening gives each replacement a fresh tab identity.
For the primary, open its tab with `bin/fm-orca-view.sh open --target <session>:<window> --view-session fmview-main --identity-file <home>/state/fmview-main.identity`, then save the identity with `bin/fm-orca-view.sh identity --file <identity_file returned by open> --tab-id <tab_id returned by open> > <home>/state/fmview-main.env`.
At the primary's next restart, at a moment it is idle, run `. <home>/state/fmview-main.env` in its window's shell before starting it again.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and omp are empirically verified for crewmate and secondmate launches; gemini is verified for crewmate and scout launches only, and [README requirements](../README.md#requirements) own the set supported for the primary session.

### Harness restrictions and credentials

`fm-spawn.sh` refuses kimi on cmux and Orca at preflight, because answering Kimi's folder-trust dialog needs a verified viewport-only capture those backends lack; [its adapter reference](../.agents/skills/harness-adapters/references/harness/kimi.md#readiness-gated-start) owns the trust-dialog handling.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](supervision-protocols/cursor.md) owns its supervision protocol.

Cursor typed-submit confirmation is verified on tmux and Herdr only.
On Zellij, cmux, and Orca a typed-plane Cursor send (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.

muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.

gemini is likewise refused for secondmates because it has no primary supervision protocol; [its adapter reference](../.agents/skills/harness-adapters/references/harness/gemini.md) owns the credential precondition, canonical-launch wiring, and raw-launch limitations.
rovo is likewise verified for crewmate and scout launches ONLY, refused for a secondmate for the same reason - no turn-end hook and no primary supervision protocol; [`docs/verification/rovo.md`](verification/rovo.md) owns that evidence, including the OAuth token's silent background refresh from a stored refresh token and both tmux and herdr pane liveness (herdr placement is verified live, with a Herdr-side agent-detection gap left open for recovery classification).

agy is likewise verified for crewmate and scout launches ONLY, refused for a secondmate for the same reason - no hook surface and no primary supervision protocol; [`docs/verification/agy.md`](verification/agy.md) owns that evidence, including the spawn-time worktree trust pre-registration through `bin/fm-agy-trust.sh` and Herdr's native agy pane recognition.
devin is verified for crewmate and scout launches only; a secondmate is refused because Devin has no verified primary supervision protocol.

Its private worker config disables Claude Code imports (including the captain's hooks) and, unless the home sets `config/keep-ai-trailers` (see "Commit attribution"), Devin commit attribution without editing user or project config; [`fm-devin-config.sh`](../bin/fm-devin-config.sh) owns these enforced settings and [Devin verification](verification/devin.md) owns the live evidence and observed model availability.

### Verification and primary supervision

New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in the skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).

The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
A Claude worker's launch brief is published as an operational record in the receiving home's state and delivered as a printable doorbell; if publication fails, the spawn reports the failure and launches nothing rather than sending a marker that Claude Code would strip.
Other harnesses retain the typed operational-marker launch path.

Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).

Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).

Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, omp uses its own two tracked `.omp/extensions/` files with a blocking `session_stop` turn-end hook, and OpenCode uses its TUI plugin.

### Choose the worker harness

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.

Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.

### Choose the secondmate harness

`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line that is not a per-secondmate override is parsed as `<harness> [<model>] [<effort>]`.

A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.

Any other line may give one second mate its own model and effort as `<id>: <model|-> [<effort|->]`, for example `alexander-media: opus low`.
That line refines the pin above for that mate only: `-` or an omitted effort keeps the pin's own token for that axis, the first line for an id wins, and the harness itself never changes.
Like the pin's own tokens, an override applies only when the pin names a concrete harness.
Each default-profile launch of that mate re-resolves the file - first spawn, recovery, the watcher's and session start's automatic relaunch, a control-plane relaunch, and a restart - so the choice survives every respawn.

`fm-harness.sh secondmate-model [<id>]` and `fm-harness.sh secondmate-effort [<id>]` expose only the optional tokens from `config/secondmate-harness`, with that mate's override applied when an id is given; `config/crew-harness` remains a bare adapter-name file.
Changing this file affects the next secondmate spawn or control-plane relaunch; the relaunch profile rules are owned by [`docs/agent-control.md`](agent-control.md#transactional-relaunch).

### Per-launch overrides and inherited defaults

An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.

Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.

The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.

`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.

### Installed hooks and launch details

For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.

Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.

Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree, plus the per-task busy-state extension from `state/`.
Pi-family secondmates can start unattended in Firstmate-seeded homes without accepting project trust manually; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the capability requirement, session-only approval scope, and older-version fallback, with [regression evidence](verification/runtime-backends.md#pi-seeded-secondmate-project-trust).

For omp secondmate launches, `fm-spawn.sh` names only the per-task busy-state extension from `state/` with `-e`: omp auto-discovers the home's tracked `.omp/extensions/` with no trust gate, and naming a discovered file with `-e` as well loads it twice; every omp launch instead carries the tracked `.omp/fm-worker-overlay.yml` posture overlay through `--config`, which [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns.

## Claude permission mode (config/claude-permission-mode)

The optional local, gitignored `config/claude-permission-mode` selects the permission flags for every Claude worker launch: crewmates, scouts, Claude secondmates, and control-plane relaunches.

### Accepted values and refusals

The token is the file's content with all whitespace removed.

| Token | Launch permission flags |
| --- | --- |
| `bypass` | `--dangerously-skip-permissions` |
| `auto` | `--permission-mode auto` |

An absent file launches every Claude worker with `--allow-dangerously-skip-permissions --permission-mode auto`, so bypass is available but not active.
Auto is Claude Code's classifier-reviewed permission mode; with the file absent, bypass stays reachable through the session's shift+tab mode cycle, while explicit `auto` removes it from that cycle for a captain who refuses bypass mode entirely.
`bypass` starts the worker with every permission check skipped.
Only the permission flags change between the modes.
The environment prefix, inline settings, model, effort flags, and the task-channel `--add-dir` grant below stay the same in every mode.

Every Claude launch, in every mode, also passes `--add-dir` for exactly this task's Firstmate channel directories, resolved to real paths: a secondmate gets the parent home's `state/<id>.inbox` it reads its steers from; a ship or scout worker gets this home's `state/operational-inbox` (its launch record), `state/<id>.inbox` (its steers), `data/<id>` (its brief and report), and the code root's `.agents/skills`.
The grant exists because Claude Code path-checks the Read/Glob/Grep file tools against cwd plus `--add-dir`, and since 2.1.257 the first outside read in `auto` mode parks the pane on a one-time interactive question, while a "Block" answer there writes `permissions.blockReadsOutsideWorkingDirectories` into user settings and then refuses the same reads under bypass too.
It never covers the whole `state/` or anything wider.

Any other value or an unreadable file refuses every spawn from that home, whichever harness it would launch.
This happens before any endpoint, worktree, or task record exists.
The diagnostic names the accepted values; Firstmate never falls back to a permission posture the captain did not choose.

### When changes apply and inheritance

`bin/fm-spawn.sh` reads the file on every spawn and relaunch, so a change takes effect at the next launch without a restart.
The file is a captain-wide safety preference, so it is inherited into secondmate homes under the [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) inherited-local-material contract; a secondmate's own Claude crewmates then launch on the same posture.

The [Claude adapter reference](../.agents/skills/harness-adapters/references/harness/claude.md) records the permission-mode observations and the distinct startup dialogs.

## Grok permission mode

Every Grok worker launch - crewmates, scouts, Grok secondmates, and control-plane relaunches - runs with `--permission-mode bypassPermissions`, Grok's approval-skipping mode, by captain exception (2026-10-16).
No configuration file selects it, and no narrower Grok posture runs a worker unattended: every other mode, allow rule, and sandbox still puts a shell redirect on an interactive approval prompt.
The exception is the Grok counterpart of [Claude permission mode](#claude-permission-mode-configclaude-permission-mode)'s bypass setting.
The safety boundary lives in the worker's instructions instead: no merges, deploys, spend, client sends, or destructive actions without the captain's word.
Client data never goes to a Grok worker.
The [Grok adapter reference](../.agents/skills/harness-adapters/references/harness/grok.md) records the verified launch shape and the narrower postures that failed.

## Muse permission mode

Every Muse worker launch - crewmates and scouts - runs with `--yolo`, by captain exception (2026-10-16).
`--yolo` is the single flag that makes a Muse pane viable: Muse ships approval prompts and a filesystem and network sandbox on by default and gates a fresh workspace behind a trust dialog, so the one flag disables approval, disables the sandbox so git and network work, and trusts the workspace so no dialog appears on the fresh per-task worktree (verified reason recorded above the muse launch case in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh)).
The exception is the Muse counterpart of [Claude permission mode](#claude-permission-mode-configclaude-permission-mode)'s bypass setting and [Grok permission mode](#grok-permission-mode).
The safety boundary lives in the worker's instructions instead: no merges, deploys, spend, client sends, or destructive actions without the captain's word.
Client repos, client data, secrets, and the captain's Gmail never go to a Muse worker.
The [Muse adapter reference](../.agents/skills/harness-adapters/references/harness/muse.md) records the verified launch shape.

## Claude Remote Control (config/claude-remote-control)

Claude Code's [Remote Control](https://code.claude.com/docs/en/remote-control) lets a session be seen and steered from the Claude mobile app or claude.ai while it keeps running on its own machine.
Firstmate turns it on for the sessions a captain talks to: the primary session and every Claude secondmate, on this machine or on a [remote host](remote-secondmates.md).
A ship or scout task worker never carries it, so tasks do not add entries to the captain's session list.

### Secondmates

Every Claude secondmate launch and relaunch carries `--remote-control 'fm-<id>'`, so the session is listed as `fm-<id>`, matching Firstmate's stable task address for that secondmate.
The optional local, gitignored `config/claude-remote-control` is the switch.

| Token | Claude secondmate launch |
| --- | --- |
| `on` | carries `--remote-control 'fm-<id>'` |
| `off` | carries no Remote Control flag |

An absent file means `on`, and the token is the file's whitespace-trimmed content.
Any other value or an unreadable file refuses every spawn from that home before any endpoint, worktree, or task record exists.
The file is read on every spawn and relaunch, so a change reaches a secondmate at its next launch and never touches a running session.
It is inherited by secondmate homes, which is where a remote host's own launch reads it.
Secondmates on other harnesses are unaffected.

### The primary session

Firstmate does not launch the primary session, so the launch line carries the flag instead:

```sh
claude --remote-control firstmate
```

Always give the flag a name.
Its name is optional, so a bare `--remote-control` followed by a prompt would take the prompt as the name.

### A session that is already running

Typing `/remote-control <name>` into a running Claude Code session connects it in place and keeps the conversation.
Until Remote Control's one-time confirmation has been accepted on that machine, the command first opens a dialog that a person answers.

### Requirements and limits

- The account must be signed in through claude.ai on a Pro, Max, Team, or Enterprise plan, with the full login from `claude auth login` or `/login`; on Team and Enterprise an Owner must also enable Remote Control for the organization.
- An API key, a long-lived token from `claude setup-token`, Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry, and a custom `ANTHROPIC_BASE_URL` cannot use it.
- A launch that cannot use Remote Control still starts and works normally without it, so the default needs no change on such an account.
- The session makes outbound HTTPS requests only and opens no inbound port.
- While a session is connected, its transcript is stored on Anthropic's servers; choose `off` for secondmates whose conversations must stay on their own machine.
- A relaunched session registers again under the same name, and its earlier entry shows as offline.
  For a remote secondmate, every launch and relaunch [reports the link of the session that is live now](remote-secondmates.md#the-remote-control-link).

[`verification/runtime-backends.md`](verification/runtime-backends.md#claude-remote-control-launch-flag) records what was observed for the launch flag and what is still unverified.

## Worker tool exclusions (config/crew-exclude-tools)

The optional local, gitignored `config/crew-exclude-tools` hides named tools from this home's ship and scout workers, for example to keep an MCP server's write tools out of reach while its read tools stay available.
The contract is runtime-neutral: a runtime must support hiding the listed tool names or refuse the launch, and a non-empty list is never silently ignored.
With no file, or a file with no entries, every launch on every runtime is unchanged.

Create the file with one tool name per line, such as `mcp__<server>__<tool>` for an MCP tool.
Blank lines and lines beginning with `#` are allowed, and surrounding whitespace on a line is trimmed; a trailing comment on an entry line is not allowed.
The file is read from this home's own configuration directory on every launch, so a change reaches the next worker or relaunch without a restart.
It is not in the inherited configuration set, so no other home, including a secondmate home, receives it; create the file in each home that wants it.
It does not apply to a secondmate's own agent, which neither reads nor refuses on it.

### Runtime support

| Runtime | With a non-empty list |
| --- | --- |
| `pi`, `pi-signed` | Hides listed tool names, MCP tools included, on every ship and scout spawn and relaunch. |
| Every other runtime, and a raw launch command | The launch refuses with an error naming `config/crew-exclude-tools`, because that runtime has no verified way to hide tools. |

A relaunch validates the list and the replacement runtime's support before stopping the running worker, so an exclusion-list refusal preserves the running agent.

### Validation

An entry may use only `A-Z`, `a-z`, `0-9`, `_`, `.`, and `-`.
An entry with any other character, including internal whitespace, a comma, or a `*`, refuses the launch and names the offending entry.
An unreadable or nonregular file, or a path inspection error, also refuses and names the configuration file.
For a new worker, these checks run before its endpoint, local copy, or task record is created; Firstmate never launches with a partial list.
Only exact tool names are accepted, not wildcard patterns.
Firstmate checks syntax and runtime support before launch but never runs `pi mcp list` or otherwise connects to servers to validate names.
When its first agent run starts, after Pi's startup tool-loading boundary, the worker extension compares the launch's exclusion list with its own loaded-tool registry and appends a timestamped warning note to `state/<task-id>.status` naming the configuration file and every unmatched entry for the supervisor.
The check runs before worker actions so it cannot supersede a terminal status emitted during the turn.
An unmatched entry is reported as **unverified**, not valid: Pi versions that omit excluded tools from the registry cannot distinguish a correct exclusion from a typo, and a server that has not connected cannot verify its tools either.
Names present in the registry produce no report; unknown or unverified names do not refuse the launch.
Each relaunch installs a fresh worker extension with the home's current list, so the replacement performs the same check.

[`bin/fm-exclude-tools-lib.sh`](../bin/fm-exclude-tools-lib.sh) implements parsing and pre-launch validation for this contract; [`bin/fm-spawn.sh`](../bin/fm-spawn.sh)'s header owns the launch-flag mechanics.

## Worker account pin (config/claude-account, config/pi-account)

A home that mixes accounts for one runner, such as a work login and a personal one, can pin the account its own Claude and Pi workers launch on.
The pin is opt-in: with neither file, every launch is unchanged, and Claude workers keep receiving firstmate's own `CLAUDE_CONFIG_DIR` when it is set.

Both files are local and gitignored.

| Runner | File | Variable the launch receives | `ordinary` means |
| --- | --- | --- | --- |
| `claude` | `config/claude-account` | `CLAUDE_CONFIG_DIR` | the variable unset, so Claude uses its default login |
| `pi`, `pi-signed` | `config/pi-account` | `PI_CODING_AGENT_DIR` | `~/.pi/agent` |

### File format and provider selection

`config/claude-account` holds one line: `ordinary`, or the absolute path of an existing Claude config directory.
`config/pi-account` holds that same root on line 1 and, on line 2, the providers this home may spend, separated by spaces, for example `openai-codex anthropic`.

A final newline is optional; any other line, a relative path, or a control character such as a CR refuses.
For Claude, `ordinary` unsets `CLAUDE_CONFIG_DIR` rather than pointing it at `~/.claude`, because Claude reads `$CLAUDE_CONFIG_DIR/.claude.json` and keys its macOS Keychain entry to any directory that is set ([authentication, "Credential management"](https://code.claude.com/docs/en/authentication#credential-management)).

A Pi root can hold several provider logins at once, so the root alone does not say which account a launch spends.
A pinned Pi launch therefore needs `--model <provider>/<id>` naming a declared provider, and Firstmate also passes `--provider <that provider>` so Pi cannot resolve the model under another signed-in provider.

An unqualified model, an undeclared provider, or a raw Pi launch command, which cannot receive that flag, refuses; Firstmate never guesses a provider.

### Launch scope and sign-in checks

When a file is present, every launch of that runner from this home uses it: ships, scouts, local secondmate agents, raw Claude launch commands, and relaunches.
A raw Claude launch command refuses if its leading assignments set `CLAUDE_CONFIG_DIR` or a credential that a pinned launch unsets, such as `ANTHROPIC_API_KEY`.
The assignment would override the pin.
The refusal names the variable; remove that assignment from the raw command, or change or remove `config/claude-account`.

Before any worker endpoint, local copy, or task record exists, and before a relaunch stops the running worker, Firstmate asks the runner itself whether the pinned account is signed in: `claude auth status` for Claude, and `pi auth check --provider <provider> --json --no-refresh` for Pi.
Pi uses `pi --list-models <provider>` only when the auth check positively identifies an extension-registered provider or reports the exact unsupported-command response from an older Pi; a timeout, empty response, or malformed response leaves sign-in inconclusive even if a model listing is available.
For explicit scheduled fallback, only a proven signed-out account permits selection of another already-authorized profile; an inconclusive check requires reconciliation and never changes the pin.
The check runs with only `HOME`, `PATH`, `TMPDIR`, `USER`, `LOGNAME`, and the pinned root in its environment, so a credential variable in firstmate's own environment cannot answer for an empty root.

A pinned Claude launch also unsets the environment credentials Claude ranks above a stored login, such as `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, and the Bedrock and Vertex switches ([authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)).
Pi ranks a root's stored logins above environment variables, so a pinned Pi launch unsets nothing.

A home that authenticates Claude through environment credentials on purpose should leave the pin absent.

### Failures, reporting, and inheritance

A malformed file, a root that is not a readable directory, or a signed-out account refuses the launch and names the file to fix; Firstmate never falls back to the ambient account and never changes a global login or copies a credential.
The spawn prints the pin as `account=` (plus `account_provider=` for Pi) and records the same fields in the task record, so the session-start digest shows which account each worker launched on.

Pins are not inherited into secondmate homes: a local secondmate agent launches on the launching home's pin, while the secondmate's own workers read the secondmate home's files.
A remote secondmate is launched on its host from its own home's configuration, so create the file in that remote home.

[`bin/fm-worker-account-lib.sh`](../bin/fm-worker-account-lib.sh) owns parsing, the sign-in check, and the full list of credentials a Claude launch unsets; [runtime backend verification](verification/runtime-backends.md#worker-account-pin-sign-in-check) records the check against the real runners.

## Lavish server address (config/lavish-axi-host)

The optional local, gitignored `config/lavish-axi-host` contains one non-empty address without whitespace for the per-machine Lavish server.
`fm-spawn.sh` exports that address into every new worker and relaunch for opening boards, and the file is inherited into secondmate homes through the primary-authoritative configuration contract.

Once a board exists, the process-event adapter derives the polling address from that board's own saved Lavish session instead; its header owns the lookup contract.
When the file is absent, worker launches do not add a board address and retain the existing ambient-environment behavior.

Malformed or unreadable values refuse the launch before the worker starts.
The address selects the existing shared server; it does not authorize starting or stopping the server, and the Lavish startup crash remains a vendor-tool concern.

## Lavish page browser (config/lavish-orca-worktree)

Lavish pages open through [`bin/fm-lavish-open.sh`](../bin/fm-lavish-open.sh), which sends live session URLs to Orca.
Orca tabs default to the captain's firstmate project at `id:33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate`.
The optional `config/lavish-orca-worktree` overrides that destination with another `id:<repo-id>::C:\...` Windows worktree selector; path selectors and WSL paths are refused.
If `orca-ide` is unavailable, the opener prints the page URL and a note for manual opening without launching a browser.
An invalid destination or failed Orca open reports an error.
The override file is local, gitignored, and inherited into secondmate homes through the primary-authoritative configuration contract.
Opening a page grants no authority to drive logged-in sites.

## Home brief include (config/brief-include.md)

The optional local, gitignored `config/brief-include.md` adds standing worker instructions to every ship and scout brief.
This keeps private brief content out of tracked files.
When the file exists, `bin/fm-brief.sh` appends its text verbatim as the scaffold's last section, `# Home brief additions`, which defers to every other section of the brief, including the ship contract a later scout promotion appends below it.

An absent or blank file changes nothing, while a present path that is not a readable regular file, or text carrying its own `Delivery contract: mode=` line, stops the scaffold before anything is written.
The text is static and never executed or expanded; secondmate charters never take it, and the file is local to each home rather than part of secondmate inherited configuration.

`bin/fm-brief.sh`'s header owns the placement rule and its safety argument.

## Worker launch environment (config/launch-env-allowlist)

The optional local, gitignored `config/launch-env-allowlist` limits the ambient environment passed to newly launched workers, scouts, and secondmates, including relaunches.
With no file, ambient inheritance remains unfiltered: selected harness markers are cleared, while the provider, long-lived terminal daemon, and shell initialization determine which other variables reach the worker.

Do not assume every worker inherits the invoking Firstmate process's current environment.
The file is inherited into secondmate homes through the [primary-authoritative configuration contract](../.agents/skills/secondmate-provisioning/SKILL.md).

Changes apply to subsequent launches; existing processes keep their environment.

### Allowlist format

Create the file with one environment variable **name** per line, never credential values, assignments, wildcards, or shell commands.
Blank lines and lines beginning with `#` are allowed.

Invalid names, an unreadable or nonregular file, or a path inspection error (including an inaccessible configuration directory) stop the launch.
An empty file enables filtering with only Firstmate's operational floor.

For example, a provider using `OPENAI_API_KEY` and Git using an SSH agent could use:

```text
# Provider credential already available in the destination pane
OPENAI_API_KEY
# Git over SSH using an existing agent
SSH_AUTH_SOCK
```

### Variables retained and where values come from

Firstmate retains basic home, executable search, terminal, locale, temporary-directory, and backend routing variables, plus its explicit launch assignments, its ship and scout task marker, the compact-adviser kill switch described below, and enabled task trace.
[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact retained names and parsing mechanics.

Other ambient names must be listed explicitly, including custom credential-store locations, proxy settings, and certificate overrides when required by the selected tools.
The command shell and worker may still create their own variables.

Allowed values come from the destination pane at execution time; they are neither copied from the invoking Firstmate process nor written into the launch command.
Listing a name does not provision it in a daemon's environment or transfer credentials to another machine.

### Authentication requirements

Choose the minimum additions for the authentication method actually in use:

| Provider or Git transport | Additional names needed |
| --- | --- |
| Provider login stored under the normal home directory | None for the environment contract; the same user still has access to that provider's stored login. |
| Provider configured through environment variables | The exact credential and endpoint names required by that provider, for example `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`; a multi-provider tool needs each provider it will actually use. |
| Custom provider store | Its configured location variables, such as `CODEX_HOME`, `GROK_HOME`, or `XDG_CONFIG_HOME`; Firstmate's existing explicit Claude and Muse store assignments still apply. |
| Muse environment authentication | `META_API_KEY`, already present in the target tmux session environment; Firstmate's preflight requires the stored-login path on other backends. |
| Git over SSH with an agent | `SSH_AUTH_SOCK`; add `GIT_SSH_COMMAND` only if the chosen transport requires that override. |
| Git over SSH with a key file | No credential variable when normal SSH configuration selects the key; file permissions and any passphrase handling still apply. |
| Git over HTTPS with a credential helper | Whatever the configured helper requires; a GitHub CLI helper using an environment token needs its selected `GH_TOKEN` or `GITHUB_TOKEN`. |

### Validation and security limits

Verify the selected provider login and Git transport after opting in; Firstmate does not infer credentials from model names or install a secret manager.
Raw launch commands run under noninteractive POSIX `sh` with this option and must use compatible syntax.

The filter runs at the worker command boundary, after the terminal daemon and pane shell have started; it does not scrub either of those processes.
This is not a sandbox: it cannot revoke same-user access to credential files, prevent tools or later shells from loading credentials again, or isolate processes from the same user's other processes.

Regression coverage executes emitted launch commands with synthetic nonsecret values in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).

### Compact adviser setting

Every crewmate, scout, and secondmate Firstmate launches starts with `COMPACT_ADVISER_DISABLE=1` in its environment, on a fresh spawn and on a relaunch alike, so an unattended session never activates the compact adviser.
This guarantee also covers raw launch commands, remote secondmates, and launches filtered by `config/launch-env-allowlist`; it does not depend on the destination environment already containing the variable.

Firstmate provides no configuration or flag to change this value.
This applies only to agents Firstmate launches; the captain's own primary Firstmate session is never given the variable.

[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the delivery mechanics, with focused regression coverage in [`tests/fm-spawn-compact-adviser-disable.test.sh`](../tests/fm-spawn-compact-adviser-disable.test.sh) and [`tests/fm-spawn-compact-adviser-disable-remote.test.sh`](../tests/fm-spawn-compact-adviser-disable-remote.test.sh).

### Commit attribution

The optional local, gitignored `config/keep-ai-trailers` presence flag opts this home into keeping AI co-author trailers on its launched workers.
With the flag absent, every standard Claude launch's inline `--settings` JSON carries `"attribution":{"commit":"","pr":"","sessionUrl":false}`, every Devin worker config sets `"attribution": false`, and every fleet launch receives a pane-scoped `GIT_CONFIG` `core.hooksPath` pointing at `state/<id>.git-hooks`, where git's `commit-msg` hook strips known AI trailers even when a runtime injects them after the typed message.
When the flag is present, Claude launches omit those attribution-off settings, Devin worker configs keep the user config's `attribution` setting (Devin's default is on), and fleet launches do not install or select the strip hooks, so Git uses the repository's configured hooks directly.
`bin/fm-git-strip-ai-trailers.sh` owns the identities, the install, and chaining the hooks of whichever repository git is running in, including when `git -c core.hooksPath` supplies the pane's hook override, so a project hook such as husky still runs when stripping is enabled.
A repository whose config sets `core.hooksPath` to the empty string runs no project hook, as in plain git; if the wrapper otherwise cannot resolve that repository's hooks directory, the git operation fails rather than silently skipping a project hook such as a pre-push guard.
When stripping is enabled, the hooks directory is read-only, so a hook manager run inside a fleet pane (lefthook's npm postinstall, `pre-commit install`) fails instead of displacing the strip; install a project's hooks from outside the pane, where the wrappers chain them.
The flag is a home-wide attribution choice, so it is inherited into secondmate homes under the [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) inherited-local-material contract and a secondmate's own workers keep AI trailers too.
Per-machine Cursor `cli-config.json` attribution-off is not this contract: it does not travel with Firstmate, defaults back to on when unset, and only feeds the CLI's request to the server, so it suppresses the trailer rather than preventing it.

## Claude second-mate launch overrides (config/skill-overrides.json)

The optional local, gitignored `config/skill-overrides.json` controls skill, plugin, and subagent availability for a Claude second mate through per-launch settings.
It must contain one JSON object with at least one of these recognized settings:

- `skillOverrides`: an object of skill name to visibility.
- `enabledPlugins`: an object of plugin ID to boolean, such as `{"charlesdr-dev-loop@charlesdr-dev-loop": false}`.
- `permissions.deny`: an array of strings, such as `["Agent(harness-checker)"]`, which hides the named subagent from the Agent tool.

Firstmate checks these types and requires every `enabledPlugins` value to be a boolean and every `permissions.deny` entry to be a string; Claude Code interprets the settings' contents.
Only those three settings are forwarded; other properties, including other `permissions` keys, are ignored.

When a Claude second mate is launched or relaunched, Firstmate reads this file from that second mate's own home and adds only those properties to the launch's inline `--settings` JSON.
`skillOverrides` replaces any existing value, while `enabledPlugins` and `permissions.deny` merge into the settings' existing ones, with the file's plugin values winning.
Raw Claude commands with a leading assignment containing quoted spaces are not recognized as Claude launches and do not receive the override; use the standard Claude launch template for those sessions.
An absent file changes nothing.
A file that is unreadable, contains zero or multiple JSON documents, is not valid JSON, has none of the three properties, or has one of them with the wrong type is skipped whole with a one-line note on stderr, and the launch proceeds without it.
Ship and scout workers never receive it, nor does any non-Claude harness.
Firstmate reads but never edits the override file; existing Claude launch wiring separately regenerates `.claude/settings.local.json` for control hooks.

The file is per home because each second mate can use different settings, and it is not inherited from the primary home.
[`fm-spawn.sh`](../bin/fm-spawn.sh) owns the delivery, with regression coverage in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).

## Claude plugin directories (config/claude-plugin-dirs.json)

The optional local, gitignored `config/claude-plugin-dirs.json` contains a nonempty JSON array of absolute plugin directory paths, such as `["/home/user/fm-home/data/plugins/example"]`.
For each Claude ship, scout, or relaunch, Firstmate reads the spawning home's file and adds one session-only `--plugin-dir` flag per directory.
For a Claude second-mate launch or relaunch, Firstmate reads the second mate's own home instead.
The directories must exist at launch time; an unreadable or invalid file, a missing directory, or a path containing control characters skips the entire file with one note on stderr.
An absent file and every non-Claude launch remain unchanged.
This setting does not install plugins into either Claude account and does not change `config/skill-overrides.json` or user-level skill availability.
[`fm-spawn.sh`](../bin/fm-spawn.sh) owns delivery, with regression coverage in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).

## Project capacity (config/project-capacity)

The optional local, gitignored `config/project-capacity` tells Firstmate how many workers a project can run at once on this machine, for a project whose machine-local resource - a heavy test suite, a local editor stack, a device - only serves a few workers at a time.
Without it, dispatch stays uncapped as `AGENTS.md` section 7 describes, and a surplus worker is launched only to spend full-context turns waiting for the resource.
The file lives in the machine's root Firstmate home, so every local secondmate home reads the same limit, and it holds one line per project:

```text
# heavy suite serves two workers
my-project 2
```

The name is the project's registered name, which is its clone directory name and may contain spaces, and the number, the last field on the line, is a positive integer.
A line that is only `#`, or that begins with `#` followed by whitespace, is a comment, as is a `#` line whose last field is not an integer.
A project name may begin with `#` when that `#` is written immediately against the rest of the name and the line ends with the project's capacity.
A name that is `#`, or that begins with `#` and a space, cannot be declared, because that line is a comment.
A place is held by every ship or scout on that project in the root home or any local secondmate home registered under it, including one working in a separate clone of the same origin, until its ready PR is recorded or it is cleaned up; a local-only ship or a scout holds its place until cleanup.
The declaration is matched by the spawning clone's directory name, so clones of the same origin share the cap only when they use that same directory name.
A clone of that origin under a different directory name finds no declaration and is not capped, though its workers are still counted as holders for a same-origin clone that is capped.
When every place is held, `bin/fm-spawn.sh` launches nothing, creates no record, leaves the backlog item queued, prints one `deferred:` line naming the holders, and exits 75, so Firstmate dispatches the item again once a place frees.
A malformed or unreadable file refuses every fresh ship or scout spawn until it is fixed, rather than guessing the intended limit, and so does a local home's state directory or task record that cannot be read while counting a capped project's holders.
Firstmate cannot see which part of a worker's life uses the resource, so the number bounds whole workers from launch to handoff, and the tightest resource every worker needs should decide it.
[`bin/fm-project-capacity-lib.sh`](../bin/fm-project-capacity-lib.sh) owns the file format, what holds a place, and why concurrent spawns cannot both take the last one.

## Automatic deadweight cleanup

Every home's normal supervision watcher runs a daily deadweight sweep by default.
No check shim or separate scheduler needs arming.
The sweep runs while the normal supervision cycle is active, starts at most once per day, and reports its result on the next slow-check poll.
[`bin/fm-deadweight-sweep.sh`](../bin/fm-deadweight-sweep.sh) owns the schedule, state records, output, and safety gates.
It uses teardown's landed-work and completion checks, preserves captain holds and secondmates, and delegates pool removal to treehouse's safe prune.
It keeps uncertain work, including ignored or operator-edited files, unmerged recorded PRs, and remote branches whose status cannot be verified; only exact Firstmate-generated wiring is exempt from the file check.
When a worker copy is missing, its record remains unless the recorded remote branch is confirmed merged or absent.
Automatic teardown requires a proven dead or missing endpoint.
Alive workers remain in place and appear as `idle-left` in the one-line report when the semantic busy classifier confirms idle.
Backends without reliable death proof also remain in place.

## Worktree pool guard

Treehouse reuses returned worktree copies, caps each repository's pool with `max_trees`, and prunes only copies that are merged, clean, idle, and unleased.
It never prunes on its own, never prunes by age, and never warns about total size.
[`bin/fm-treehouse-guard.sh`](../bin/fm-treehouse-guard.sh) adds only those missing triggers, and leaves every decision about what is safe to remove to treehouse.
Its header owns the exact treehouse flags, exit codes, record files, and time bounds.

### Prune after cleanup

After ordinary cleanup returns a copy to a pool, Firstmate asks Treehouse to safe prune the project's configured pool and, when a per-home slot is detected, attempts a second prune.
Automatic deadweight teardown defers pool pruning to its sweep, which skips a project's pool while a retained ship or scout task in this home still has a copy there.
A failed or timed-out prune prints one warning and never fails ordinary cleanup, which has already finished.
A pool that another launch or cleanup is using at that moment is skipped silently and can be reclaimed by a later cleanup or sweep while it remains in the guard's selected location.
Because a returned copy whose work has landed is exactly what treehouse prunes, the next launch on that project usually creates a fresh copy instead of reusing a returned one.

### Optional daily treehouse pool sweep

A home arms the daily check with `bin/fm-treehouse-guard.sh arm`.
It writes `state/treehouse-guard.check.sh` and binds it through the same authenticated watcher-check mechanism as the [daily startup growth check](#daily-startup-growth-check), so no extra daemon or scheduler is installed and an armed home keeps needing a watcher after its last task is cleaned up.
Use `bin/fm-treehouse-guard.sh disarm` to remove the check and its records.

At most once a day the check starts a sweep in the background, and a later poll reports its result as one line.
The sweep runs the same safe prune for each project clone under this home's `projects/`, then reports when:

- the worktree copies under `~/.treehouse`, or under the per-home pool path computed in the sweep's environment, use more than 5 GB;
- that size could not be measured;
- a prune did not run, with the reason.

A finding is reported once and stays silent until it changes or clears.
A reported finding is a recommendation, not cleanup authority.

### What the guard never does

- It never asks treehouse to remove a copy that is unlanded, in use, or leased, and it never prunes by age.
- It does not scan another home's project clones or per-home pool directories.
  It invokes prune from this home's project clones, with a second call when a per-home slot is detected; a clone-local root can redirect both invocations.
- It never makes a machine-wide treehouse call: each treehouse command is `treehouse prune --yes` run from a project clone.
  The size checks are read-only measurements taken with `du`.

Treehouse still keys its default pool by directory name plus origin, so two clones with the same name and origin are offered one pool.
After the [pool placement check](#pool-selection-limits), a fresh launch asks Treehouse for a copy and keeps it only when it is a worktree of the spawning clone.
When treehouse hands it another clone's idle copy, the launch leaves that copy at once and attempts to lease a worktree of its own clone using this home's per-home pool folder.
The per-home pool folder is named under `${XDG_STATE_HOME:-~/.local/state}/firstmate/<home>-<hash>/.treehouse/`; a clone-local `treehouse.toml` root can select a different Treehouse location.
`<home>` is the home's folder name and `<hash>` is the first six hex digits of the sha256 of the home's physical path, so two homes with one folder name stay apart.
On a fallback path that passes the custody check, treehouse resets the idle copy it offered to the default branch before handing it over, and takes it back unleased when the launch leaves it; no copy is added there.
Treehouse reads its default pool location from `HOME`, so that lease and its prune run treehouse with `HOME` set to the pool folder, while every git process it starts keeps the operator's `HOME`, git configuration, and credential helpers.
The user-level treehouse configuration therefore does not apply to this pool; a `treehouse.toml` in the clone still does.
The lease is bounded to 600 seconds, and a fetch that would prompt for credentials fails instead of waiting.
A launch that still cannot get a worktree of its own clone stops before the worker starts.
Relaunch resumes in the recorded worktree only when no other reachable local task record or conflicting slot claim still reserves it; a Claude relaunch also refuses an old record whose worktree belongs to another clone and names both the worktree and recorded project.
Non-Claude relaunches continue to use their recorded worktree after that custody check.
If a clone-local `treehouse.toml` root redirects the fallback lease to another clone's copy, the launch refuses it and does not force-return that foreign copy.
An abort before worker launch returns its own clone's lease from the recorded project clone only after proving it has no uncommitted work or commits absent from its remotes.
Leases containing work, leases whose safety checks fail, and leases used by a launched worker stay in place for teardown, even if the worker endpoint closes.
The attempted `get --lease` may already have marked that foreign copy leased, so the refusal leaves its Treehouse state for the pool owner to inspect.
Git still refuses to remove a worktree from a clone that does not own it, so a shared pool is not cleared by the other home.
The optional pool sweep's extra per-home prune and size checks use the pool path computed in its own environment.

### Pool-selection limits

Before asking Treehouse for a copy, Firstmate refuses an idle pooled copy still reserved by a reachable local task record or slot claim.
Unreadable custody or process evidence also refuses allocation; reconcile the reservation or use guarded `--retire-claim` teardown for a proven-stopped worker.
Before the initial `treehouse get`, Firstmate resolves the pool inside the pane using that pane's HOME and configuration.
Before a fallback lease, it resolves the pool using the lease HOME.
It refuses either allocation when the resolved pool is inside the spawning home or project clone.
Every pool placement check requires `python3`; when a repository or user Treehouse TOML config exists, `python3` with `tomllib` is required to verify the treehouse pool location.
A spawn is refused when the applicable requirement is unavailable.
After either allocation, Firstmate resolves the worktree and refuses to launch a worker there if it is inside either boundary; [`bin/fm-wake-lib.sh`](../bin/fm-wake-lib.sh) owns both path checks.
It also checks the returned copy for another task's record, a retained slot claim, or a surviving process before refreshing its base or launching the worker.
For a refused initial interactive copy, Firstmate confirms that the pane left it and that plain `treehouse status` reports that exact copy available; otherwise the spawn reports an unconfirmed return for Treehouse prune.
An untouched same-clone fallback lease is returned by the existing abort cleanup.
If a clone-local `treehouse.toml` root is added after a per-home pool already exists, the guard's extra per-home prune follows the new root and can prune that configured pool twice while leaving the earlier pool unpruned.
The per-home size check still measures the computed folder and can miss an external configured root.
If a launch sets `XDG_STATE_HOME` only for that command and the armed watcher runs without it, the watcher computes a different per-home folder and misses the launch's pool during prune and size checks.

### Copies outside the guard

Secondmate home copies and a retired secondmate's child copies are outside this guard.
Retiring a secondmate returns its home copy, and the copies of its child tasks, to their pools without pruning those pools, and the optional pool sweep does not reach the pool behind secondmate homes.
Such a copy counts against that pool's cap until treehouse's safe prune is run for that pool by hand.
Run `treehouse prune --yes` from the root of the clone that owns that pool, which is the Firstmate repository root for secondmate home copies.
`treehouse prune` without `--yes` shows what would be removed first.

### Per-repository caps (max_trees)

Treehouse reads `max_trees` from the `treehouse.toml` at the root of the clone it runs in.
For the default pool, when that clone has no `treehouse.toml`, the whole configuration, `max_trees` included, comes from the user-level `~/.config/treehouse/config.toml` if that file exists.
The built-in limit of 16 copies applies to the default pool when neither file exists, and to this home's own pool when the clone has no `treehouse.toml`.

```toml
max_trees = 2
```

| Repository | `max_trees` | Where it is set |
| --- | --- | --- |
| Firstmate | 16 | The [`treehouse.toml`](../treehouse.toml) committed at the root of this repository |
| `gtm-orchestrator` | 2 | Recommended; set in that repository |
| Client repositories | 1 | Recommended; set in each client repository |

`treehouse.toml` is a file in each project repository, so setting a cap is that project's own change, delivered the way that project delivers any other change.
Firstmate writes it into no other repository.

This repository's `treehouse.toml` holds only the cap, and changing it is a one-line change to that file.
The Firstmate pool also holds the leased copies behind local secondmate homes, and each of them counts against the cap.
The configured cap matches how the pool actually runs.
Once a repository has its own `treehouse.toml`, treehouse takes `max_trees` and `root` for that repository from it and no longer from `~/.config/treehouse/config.toml`.
A user who set a user-level `root` must therefore expect this repository's pool to use the default root.
User-level hooks still apply to the default pool.

A launch into a pool that is already at its cap is refused at once rather than waiting for a copy: `treehouse get` and `treehouse get --lease` both exit 1 with a message naming `max_trees`.
[Project capacity](#project-capacity-configproject-capacity) does not prevent that on its own, because a place frees when a PR is ready while the copy stays held until cleanup.
Choose a cap that covers the workers running at once plus the finished work still waiting to be merged and cleaned up.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
Firstmate chooses the best matching rule with judgment; shell scripts do not match the natural-language rules.
Firstmate resolves the rule's profile object or array under `AGENTS.md` section 4 and `quota-array-dispatch`, then passes concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`; its help owns the optional rule selector and fallback-reason flags.

**Spawn requirements**

- When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
- Batch spawns satisfy the same requirement with a shared `--harness`.
- Secondmate spawns are exempt and resolve through the [secondmate harness configuration](#choose-the-secondmate-harness).

**Contract owners**

This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "approval": "captain",
      "min_confidence": 0.85,
      "floor": { "scope": "<quota-axi scope>", "min_percent": 20, "provider": "<quota-axi provider>" },
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max|ultra, optional>", "provider": "<optional quota-axi provider>", "floor": { "scope": "<quota-axi scope>", "min_percent": 50 } }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

**Required and optional fields**

| Field | Requirement |
| --- | --- |
| `rules` | May be absent or empty for a default-only configuration. |
| Rule `when` and `use` | Required for each rule. |
| `use` and optional top-level `default` | Accept one profile object or a non-empty array of profile objects; the single-object form remains fully backward-compatible. |
| Profile `harness` | Required in every profile. |
| Profile `model` and `effort`; rule `why` | Optional. |
| Profile `reasoning_class` | Optional non-empty label containing letters, digits, dots, underscores, or plain dashes, beginning with a letter or digit; matching labels declare equivalent reasoning classes across profiles. |

**Fields applied only by typed resolution**

Rule `approval`, `min_confidence`, and `floor`, and profile `provider` and `floor` are optional declarations that only [typed dispatch resolution](#typed-dispatch-resolution-env-typesafe_api_key) applies in code; without that opt-in they are inert, and firstmate's own intake reads them as ordinary hints.
The resolver supplies the fixed neutral Choice option `No listed rule applies to this task.` for work that matches no listed rule.

- `approval` accepts only `"captain"` and means a task the rule matches is never dispatched from the tool's answer alone.

`min_confidence` is a number from 0 through 1.
The rule's own probability in the answer must reach it, replacing the resolver's global 0.6 floor on the answer's confidence.
Set it high when a wrong pick is costly and low when the rule is a safe runner-up.

**Rule quota floors**

- A rule `floor` names the quota-axi `provider` and `scope` whose `effectivePercentRemaining` must be at least `min_percent` for the rule's profiles to apply.
- A provider-only rule floor on an expanded provider binds to its `default` account row.
- An absent or unknown row or unmeasured provider makes the floor unverifiable and escalates without authorizing default routing.
- A known percentage below the floor makes the tool resolve among `default` profiles instead.

**Provider identifiers and mappings**

A profile `provider` optionally names the quota-axi provider family whose rows apply to that profile; when present, profile and rule-floor provider IDs must match the strict whole-string pattern `^[a-z0-9]+(-[a-z0-9]+)*\z`.
Bootstrap validates resolver-only `approval`, `min_confidence`, `floor`, and present `provider` values only while typed resolution is active; without the key those inert fields and the pre-existing verified-harness baseline preserve bootstrap behavior.

Typed resolution additively recognizes `gemini` because AGENTS.md section 4 verifies it for crewmate and scout dispatch.

| Harness | Provider declaration on the opted-in resolver path |
| --- | --- |
| `claude`, `codex`, `grok`, `kimi`, `cursor`, `agy`, `muse` | The resolver has an authoritative single-provider mapping. |
| Every other verified harness | Must declare `provider` explicitly; this includes multi-provider `pi`, `pi-signed`, `omp`, and `opencode`, and unmapped `gemini`, `rovo`, and `devin`; omission is an actionable configuration error before any request. |

This single-provider table is separate from the frozen legacy mapping used by `fm-quota-choose.sh`, so additions cannot alter no-key routing.

**Profile quota floors**

- A profile `floor` contains only `scope` and `min_percent`, always uses that profile's provider and matched account, and makes that one candidate ineligible below `min_percent` on the named scope.
- An absent or unknown named row also makes the candidate unrankable and is reported as an unverifiable floor, not as a known shortfall.

**Model, effort, and fallback behavior**

- `ultra` is native-only: the model-aware validation contract and launch mapping are owned by `bin/fm-harness.sh validate-native-effort` and `bin/fm-spawn.sh` respectively.
- Codex `max` is valid when the profile selects `gpt-5.6-luna`, whose installed catalog entry supports that reasoning level.
- An omitted model or effort means the selected harness uses its own default for that axis.
- OpenCode receives the effort as its default `build` agent's `variant`, keyed to the resolved model, inside the `OPENCODE_CONFIG_CONTENT` JSON its launch already writes (the per-model reasoning-effort field of the config schema, verified on opencode 1.18.32); with no model resolved, the effort is recorded in task metadata but omitted from the launch.
- Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
- If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
- Except for `ultra`, which refuses unsupported profiles under the native-effort contract above, an effort value the chosen harness does not accept is recorded as `effort=` in task meta for traceability but omitted from the launch flags.
- Bootstrap reports unsupported harness/model/effort combinations as a `CREW_DISPATCH` diagnostic when they are visible in the file.

Spawn records the uniquely selected profile set as JSON-encoded `dispatch_rule` (`{"rule":"rule_1"}` for the first rule or `{"default":true}`), a SHA-256 `dispatch_rule_fingerprint` of its condition and use list (or the default use list), its optional `reasoning_class` and `dispatch_provider`, and the JSON-encoded `fallback_reason` in task metadata.
An ambiguous set requires an explicit selector at intake; scripts never choose among natural-language rules.
An explicit profile outside the configuration remains an intake override, with no recorded rule authorizing subsequent fallback.
Ship and scout relaunches preserve the recorded model and effort when omitted, including direct spawn relaunches, and preserve the chosen class and fallback rationale on an unchanged profile.
A crew-dispatch replacement must be listed in that same rule in the current configuration; removing the rule or its configuration cannot authorize a replacement.
For records with a rule fingerprint, changing or reordering that rule refuses relaunch before stopping the worker, even when the replacement remains listed at the saved position.
Different models or adapters require matching declared `reasoning_class` labels, rather than treating equal effort tokens as evidence of equal model capability.
Without declared labels, the same adapter and model may retain or increase its explicit effort, but may not lower it or replace it with an unknown default.
Legacy task records recover a rule only when their recorded profile identifies exactly one current set; ambiguous or unlisted records refuse fallback.
Control checks the same guard before stopping an agent and uses its progress note as the fallback reason; direct spawn replacements require an explicit reason.
This guard does not select a fallback or change quota/account policy.
Unconfigured manual replacements and configured secondmate pins retain their existing control contracts.

`harness` records the realized harness; `realized_model` records a model supplied to the canonical launch and is absent when the harness chooses its default; `realized_effort` records the applied effort or `default`, while raw-command model and effort record `unknown`.
These fields describe the launch request, not unobservable model substitutions inside a vendor service.
A declared reasoning class or configured fallback refuses an effort the adapter would omit, and a raw command cannot claim a configured profile.
Public-interface regression coverage lives in `tests/fm-spawn-dispatch-profile.test.sh` and `tests/fm-control-relaunch.test.sh`.

See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`; its Pi default declares the `claude` provider required for typed resolution of that Anthropic model.

**Validation and diagnostics**

- When the file exists, bootstrap validates it with `jq`.
- Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
- Malformed JSON, malformed rules, an empty or malformed profile array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`.
- While typed resolution is active, malformed `approval`, `min_confidence`, `floor`, and present `provider` declarations receive the same diagnostic; without the key those inert declarations preserve the pre-existing bootstrap behavior.
- Missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
- While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.

**Inheritance**

Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Domain evidence collection (config/domain-freshness.json)

The optional home-local `config/domain-freshness.json` declares the permitted inputs for manual domain evidence collection.
Absent configuration makes `collect` a silent no-op; an existing `enabled: false` configuration does the same after Python validates it.
The `enabled` flag gates `collect` only; explicit `inventory` reads a declared local source independently.
If Python is unavailable, the command fails closed because it cannot safely identify a valid disabled JSON configuration.
Machine-specific inventory paths are local choices and must not be inherited across hosts.
[`bin/fm-domain-freshness.sh`](../bin/fm-domain-freshness.sh) owns collection commands, evidence/cursor formats, publication order, read limits, and exit statuses.
Daily intake is a separate integration; this collector neither schedules work nor changes installations or operational instructions.
[`bin/fm-domain-proposal.sh`](../bin/fm-domain-proposal.sh) provides manual main-home handoff for currently registered local mates using a collected bundle; remote handoff is unsupported.
One ordinary queued task per proposal cycle records pending before/after confirmation outside categorized captain holds.
The script header and `--help` own the request, proposal, confirmation, approval, and receipt protocol; the command does not schedule or apply changes.

This section owns the version 1 configuration schema:

| Field | Meaning |
| --- | --- |
| `version` | Exactly `1`. |
| `enabled` | Required boolean, default posture is off. |
| `sources` | Up to 100 source objects, each with a unique safe `id` and one `kind` below. |

| Source kind | Required fields and coverage |
| --- | --- |
| `repository` | `repo: "owner/repository"`; read newly merged PRs and newly created issues across that repository, preserving actual PR base/head, changed-file metadata, and bounded before/after content from the effective merged commit and its first parent for changed instruction files. |
| `skills` | Absolute `root`; discover `SKILL.md` content beneath it, including additions and removals. |
| `plugin-files` | Absolute `root` and nonempty `files` array of relative `path` plus file `kind`; explicitly declare the installed manifest and optional version manifests. |
| `remote-inventory` | `route` is a registered remote secondmate id and `source` is a local inventory source id in that home's configuration. |
| `unavailable` | Nonempty `reason`; disclose an unavailable home/host or input instead of treating it as current. |

Ambiguous merged PR history leaves repository coverage incomplete.
If a fork's merged instruction blob is unavailable from the base repository, its after-content records `content unavailable` while the event remains covered.
Missing plugin manifest declarations leave plugin coverage incomplete.
The parent requests a remote source's bounded read-only snapshot through `fm-on.sh`.
Inventory sources optionally declare absolute `symlink_roots` for permitted external symlink targets.
Declare only specific safe roots and manifest files; skills are read only from `SKILL.md` files.
A resolved target outside the declared roots fails coverage, and the collector never discovers or reads another home's endpoints.
An unreachable or unreadable remote inventory fails that source's coverage without advancing its checkpoint.
A remote source needs a corresponding configured `skills` or `plugin-files` source in its owning home.
A change to that source's root or file list starts a fresh baseline.
Forge feed pages are read twice with a fixed internal 20-page bound; a changed feed or exhausted bound fails coverage.

The `plugin-files` file kinds are `plugin-manifest` (installed plugin names and versions) and `plugin-version` (name/version).
Only those manifest fields are retained; unrelated settings fields are excluded from fingerprints and evidence.
Inventory coverage names the observed surfaces and explicitly leaves session visibility unmeasured; a cache version alone does not establish effective installation.
Instruction excerpts disclose truncation while their digest covers the full file.
First inventory observations are explicit baselines rather than historical change claims.

When present, the current secondmate registry supplies domain id/home/scope/host context; an absent registry is recorded with no domains.
All collected sources remain available to scope judgment, including effects that cross department boundaries; collection does not assign repositories exclusively to one mate.
Repository events include active linked contribution observations when available, without limiting repository-wide discovery.
The collector makes no model calls, parent requests, or review cards on complete unchanged observations.

An off example, to adapt only after the separate activation approval:

```json
{
  "version": 1,
  "enabled": false,
  "sources": [
    { "id": "firstmate", "kind": "repository", "repo": "owner/firstmate" },
    { "id": "local-skills", "kind": "skills", "root": "/absolute/safe/skills" },
    { "id": "remote-inventory", "kind": "remote-inventory", "route": "remote-mate-id", "source": "local-skills" }
  ]
}
```

## Task types (config/task-types.json)

The optional local, gitignored `config/task-types.json` lists the recurring specialist types for this home.
One home is one domain.
An absent file changes nothing: briefs scaffold as they do today, and `bin/fm-brief.sh --list-types` prints nothing.
[`docs/examples/task-types.json`](examples/task-types.json) is a copyable example and is never loaded.
`bin/fm-brief.sh` owns the `--type` and `--list-types` flags, and [`bin/fm-task-type-lib.sh`](../bin/fm-task-type-lib.sh) owns the checks and the lines they print.
This section owns the file format.

A type is a handful of pointers.
The supervisor passes `--type <name>` when scaffolding a ship or scout brief, and writes only the task itself.
The scaffold checks the name and renders one fixed `## Task type` section from the entry.
An unknown name, a malformed file, a file that is not a readable regular file, or a type whose `projects` list omits the brief's project refuses with a plain reason and writes nothing.
The scaffold never picks a different type.
`--list-types` prints `<name>: <use>` for each entry, in file order, and takes no other arguments.

```json
{
  "types": [
    {
      "name": "<slug>",
      "use": "<one line>",
      "skills": ["<skill name or repo-relative path>"],
      "agents": ["<agent name or repo-relative path>"],
      "tools": ["<tool or CLI name>"],
      "check": "<command>",
      "hand_back": "<one line>",
      "model": "<optional model token>",
      "effort": "<optional low|medium|high|xhigh|max|ultra>",
      "touch": "<paths or one boundary line>",
      "projects": ["<optional registered project name>"]
    }
  ]
}
```

| Field | Requirement |
| --- | --- |
| `name` | Required lowercase slug (`^[a-z0-9]+(-[a-z0-9]+)*$`). |
| `use` | Required one line saying when to pick this type. |
| `skills`, `agents` | Optional arrays of names or repo-relative paths the worker resolves in the project, never absolute paths and never copied text. |
| `tools` | Optional array of the named tools or CLIs the worker uses for this type, in the same form; the brief tells the worker to name any substitute when it hands back. |
| `check` | Optional one-line command, omitted when the type has no check. |
| `hand_back` | Required one line describing what the worker hands back. |
| `touch` | Required one-line boundary, recorded in the brief and not enforced. |
| `model` | Optional token with no whitespace or `=`, surfaced for `fm-spawn.sh --model`. |
| `effort` | Optional `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`, the difficulty class `fm-spawn.sh --effort` already accepts. |
| `projects` | Optional registered project names. Omit it and the type applies to every project. A brief for any other project is refused. |

Unknown fields are refused, so a typo cannot be skipped.
`model` and `effort` are printed on one `type-profile:` line when the entry sets them, and are not written into the brief section.
The routing precedence in `AGENTS.md` section 4 stays the single owner of the launch profile: an explicit captain instruction for the task, then the matched dispatch rule or resolver profile, then the configured default.
That line's `model` and `effort` only fill an axis none of those resolved, passed to `fm-spawn.sh` as `--model` and `--effort`.
They are never mixed into a profile a rule already resolved, so a rule's harness never runs with a type's model.
The type does not select a harness or a dispatch rule.
The example therefore pins only `effort`, since a model token belongs to one harness.
[`bin/fm-dispatch-resolve.sh`](../bin/fm-dispatch-resolve.sh) does not read the task-type section.

The file is local to each home, like [`config/brief-include.md`](#home-brief-include-configbrief-includemd).
It is not on the inherited-local-material allowlist owned by [`bin/fm-config-inherit-lib.sh`](../bin/fm-config-inherit-lib.sh), and this adds no sync.
A secondmate home and a Boat-hosted home each read only the catalog in their own config directory, so the file must be placed in each home that uses it.
The format and behavior are the same there, and a home without the file lists nothing and refuses `--type`.
`FM_CONFIG_OVERRIDE` selects the config directory, as it does for the other files `bin/fm-brief.sh` reads.

Regression coverage is in [`tests/fm-brief.test.sh`](../tests/fm-brief.test.sh).

## Recurring intake (config/schedules.json)

The optional home-local, gitignored `config/schedules.json` declares enqueue-only recurring intent.
It is not inherited, and an absent file or disabled entries cause no new detections.
Nothing in a checkout automatically writes this file, arms a check, or enables a host timer.
[`bin/fm-schedule-check.sh`](../bin/fm-schedule-check.sh) owns due calculation, occurrence identity, journal receipts, bounded execution, replay, and explicit arm/disarm commands.
The existing authenticated watcher check cadence supplies the poll; no vendor scheduler or new daemon is needed.
Python 3.9 or newer with IANA timezone data must be available in the watcher's environment.

```json
{
  "version": 1,
  "schedules": [
    {
      "id": "domain-freshness",
      "enabled": false,
      "home": "/absolute/owning/firstmate-home",
      "project": "firstmate",
      "delivery": "scout",
      "intent": "Collect permitted domain freshness evidence for review",
      "brief": "/absolute/owning/firstmate-home/data/domain-freshness-brief.md",
      "cadence": {
        "kind": "daily-local",
        "at": "07:00",
        "timezone": "America/Toronto"
      }
    }
  ]
}
```

This section owns the configuration format.
The root requires exactly integer `version: 1` and `schedules`, an array of at most 100 entries.
Each entry requires the fields shown, selecting exactly one absolute `brief` pointer or lowercase `task_type` slug.
The check freezes a home-data brief's bytes or the existing task-type owner's rendered brief section as request input, and never executes input commands.
An absolute `brief` must remain inside the effective home's data directory and name a regular single-link file of at most 64 KiB.
Worker profiles are omitted from task-type snapshots so current routing still governs intake.
`id` is a unique lowercase identifier of at most 63 characters using letters, digits and plain dashes, beginning with a letter or digit.
`enabled` is an explicit boolean, `home` must exactly match the absolute effective `FM_HOME`, and `project` names the project to resolve through normal intake.
`delivery` is the intended `no-mistakes`, `direct-PR`, `local-only`, or knowledge-only `scout` path, subject to the existing task lifecycle's authority.
`intent` is the authorized recurring task description, not authority for additional external actions.
The string fields are nonempty single lines of at most 4096 characters.
Daily-local cadence requires exactly `kind`, valid 24-hour `at` (`HH:MM`), and an IANA `timezone`.
An interval cadence instead requires exactly `kind` and integer `seconds` from 60 through 31536000 (for example, `{"kind":"interval","seconds":7200}`); interval slots use UTC epoch arithmetic.
Unknown fields, duplicate ids, invalid timezone data, unsafe files, or malformed entries refuse the entire check before new publication.
The configuration is bounded to 1 MiB and the journal to 16 MiB, including frozen brief snapshots; both must be regular single-link files.
Commands, credentials, accounts, harnesses, worker models and vendor trigger ids are not accepted fields.
The owning supervisor uses current routing and quota evidence at intake rather than freezing a worker subscription in the schedule.

Due occurrences are filed or reused through [`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh) as ordinary Queued items containing the frozen brief pointer and occurrence digest.
The existing task lifecycle owns supervisor judgement, dispatch, capacity and completion; no new skill or always-loaded rule is needed.
Disabling a schedule or removing the configuration stops new detections, but subsequent checks still observe dispatch and completion of occurrences in the journal.
Disarming removes the automatic watcher check without deleting the journal or already filed tasks.
An attempted task that disappears from the active backlog is retained pending for ordinary custody reconciliation, including a task completed and archived between polls, rather than recreated.
Activation requires a separate approved home-local configuration and explicit check arming; this feature supplies no branch-write or operational-update authority.
Enqueue-only intake does not implement worker failover, PR updates, or domain collection.
Regression coverage is in [`tests/fm-schedule-check.test.sh`](../tests/fm-schedule-check.test.sh).

## Typed dispatch resolution (.env TYPESAFE_API_KEY)

`bin/fm-dispatch-resolve.sh` resolves one concrete crewmate or scout profile from a written brief with typesafe.ai's System One model (Jev), so the rule match that firstmate otherwise reasons out in its own context becomes one short tool turn.
It is off unless `TYPESAFE_API_KEY` is non-empty in the calling environment or the home's gitignored `.env` holds a `TYPESAFE_API_KEY=` line; the environment wins, matching the Relay and mail-plane contracts, and the Relay accessor in `bin/fm-env-lib.sh` reads the line.

Off means one `dispatch-resolve: off` line on stderr, nothing on stdout, exit 0, and no network call, so firstmate dispatches exactly as it does without the tool.
This section is the single owner of the tool's operator contract; the script header owns its exact flags and output lines, and "Crew dispatch profiles" above owns the declared rule and profile fields it applies.

Rules come only from the effective home's `config/crew-dispatch.json`; `FM_CONFIG_OVERRIDE` selects the config directory for tests and specialized setup like the other scripts.

```sh
bin/fm-dispatch-resolve.sh data/<id>/brief.md --project <name>        # TOON block on stdout
```

**When firstmate invokes the resolver**

Firstmate invokes the resolve path directly after writing the brief, without a preflight; the absent-key off line is handled exactly like every other non-clear outcome.

**What the model receives**

When on and at least one rule exists, the tool sends the project name and the brief's task-specific text as state and asks one Choice question whose options are every rule's `when` plus the fixed neutral option for no matching rule; the model never sees quota, catalogs, `why`, `use`, approvals, or confidence floors.
The task-specific text is the brief's `## Captain's intent` and `## Firstmate spec` sections under `# Task` that `bin/fm-brief.sh` scaffolds, read by the same parser that feeds `fm-spawn.sh` validation and the no-mistakes `--intent` contract; a brief with neither section is sent whole.

When the sections are sent from a scout brief, the line `Brief kind: scout (report only)` comes first, taken from the scaffold's scout contract line; ship briefs and briefs sent whole get no kind line.
A ship brief's delivery mode is deliberately not sent, because in live runs naming it pushed a routine ship brief toward the hardest tier (see [the verification record](verification/dispatch-resolve.md)).

The scaffold's standard setup, rules, and definition-of-done text is the same in every brief, so leaving it out keeps its safety language from reading as a signal about the task.

**Never-send list (config/dispatch-never-send)**

The optional local, gitignored `config/dispatch-never-send` keeps values you name from ever leaving the machine in a resolver request.
It has no default entries, and an absent file changes nothing.
Like `config/crew-dispatch.json`, it is inherited into secondmate homes, so a secondmate's resolver withholds the same values.

Each non-blank line not beginning with `#` is one literal value, matched case-insensitively.
Every entry is trimmed of surrounding whitespace, and any run of whitespace, in the entry or in the checked text, counts as one space, so a value the brief wraps across lines still matches.

```text
# Client names
Example Client Ltd
```

Before the request is sent, every string in it is checked: the project name, the task text, each rule's `when`, and the fixed question text.
A match stops the request: the resolver behaves exactly as when it is off, printing one `dispatch-resolve: off (...; nothing sent)` line on stderr and nothing on stdout, making no network or quota call, and exiting 0, so firstmate dispatches through its existing intake.
A list that is present but not a readable regular file also stops the request the same way rather than sending unchecked text.
That one diagnostic names the list line number at most and never prints the listed value or the matching text.

**Missing or invalid rules**

An absent rules file, a default-only file, or `rules: []` returns the non-clear reason `no rules to match` without a model or quota request, leaving firstmate's existing routing in control; an existing but unreadable or malformed rules file, including a broken symlink, remains an actionable exit 2 configuration error.

**Checks performed after the answer**

After the answer, code applies all remaining checks and ranking:

- The confidence floor and the matched rule's `approval` and `floor`.
- Each candidate's `provider` and `floor`.
- Every applicable account-wide and model/product row from one `quota-axi --json` snapshot.
- The numeric `spendPriority` argmax over candidates, using each candidate's limiting row.

The [shared quota library](../bin/fm-quota-axi-lib.sh) accepts schema 5 and schema 6 and implements the [account-matching contract](../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility).

- An expanded provider with no matching account row leaves the candidate eligible but unranked.
- Known applicable rows from a provider with partial quota semantics remain rankable; rows whose own status is not known remain unrankable.

**Confidence and fallback rules**

- A rule that declares `min_confidence` is checked against that rule's own probability, whether it is the picked option or a runner-up, so a runner-up never needs weaker support than it would as the pick.
- A picked rule without `min_confidence`, and the neutral option, keep the global 0.6 floor on the answer's confidence exactly as before, so a file with no declared floors behaves as it did.

When the picked rule declares its own floor but its probability falls below it, the tool checks the other options:

1. Find the most probable other option that clears its own floor: the rule's `min_confidence`, or 0.6 otherwise.
2. Print a `fallback:` line naming both floors and resolve that rule as though it had been picked.

No qualifying option, or two equally probable qualifying options, produces `ambiguous`.

**Candidate eligibility and evidence**

- Any applicable `exhausted_now` row or known zero bound makes that candidate ineligible, and a known profile-floor shortfall does the same before unrelated quota uncertainty is considered.
- Missing or nonnumeric `spendPriority` evidence is never ranked, and every candidate is printed beside its evidence or the reason it was not rankable, including on ambiguous and approval-gated outcomes that emit no profile.
- On the opted-in path, duplicate concrete profiles with the same harness, model, and effort inside one rule or the default array are configuration errors rather than ties.

**Outcomes and exit status**

| Result | Meaning |
| --- | --- |
| `clear` | A `profile:` line ready for `fm-spawn.sh`. |
| `ambiguous` | Confidence below the floor with no runner-up taken. |
| `escalate` | An approval-gated rule, unverifiable rule floor, nothing rankable, or a genuine tie. |
| `error` | API, network, malformed response metadata, rendering, or quota-axi failure. |

Every result above exits 0.
For a `clear` result, the `profile:` line also identifies the selected rule and carries a rationale with the resolver note, provider, and `spendPriority` for the spawn receipt.

- Response probabilities must contain exactly every offered choice, use numeric values from 0 through 1, and sum to approximately 1 within 0.01.
- Only a usage or configuration error exits 2: an unreadable brief, an existing but unreadable or malformed canonical rules file, or missing `jq`, each reported and never selected around.
- Missing `curl` is a normal structured `error` outcome with exit 0 so firstmate uses today's routing.

**Firstmate retains the dispatch decision**

The tool never replaces firstmate's judgment, `quota-array-dispatch`, the captain-approval gate, or `fm-spawn.sh` validation; `AGENTS.md` section 4 owns what firstmate does with each outcome.
By accepted design, a `clear` result does not enforce catalog/authentication, reasoning-class, or completion-runway gates.

Firstmate passes its profile line unless it states a reason to override, such as the brief's reasoning class or an eligible-unranked-candidate note; every non-clear result returns to the full existing intake.

**Key handling and fixed settings**

- The resolver and bootstrap copy an environment-provided key into a non-exported private variable and unset `TYPESAFE_API_KEY` before launching child processes, so the secret is absent from child environments.
- The resolver sends the key to `curl` only as a header read from a file descriptor, never on argv, and nothing prints, logs, or writes it.
- The resolver fixes the endpoint at `https://api.typesafe.ai`, model at `jev-latest`, default confidence floor at 0.6, and request timeout at 5 seconds; `TYPESAFE_API_KEY` is its only resolver-specific environment setting.

The live rule-match evidence is recorded in [`verification/dispatch-resolve.md`](verification/dispatch-resolve.md).

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.

Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.

**Universal requirements**

Every home requires:

- node and git.
- gh, with GitHub authentication through `gh auth login`.
- no-mistakes v1.46.0 or newer.
- Compatible gh-axi.
- chrome-devtools-axi.
- Compatible tasks-axi, as specified in "Backlog backend" above.
- Compatible quota-axi.

[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.

In that list, no-mistakes runs the validation pipeline, gh-axi and chrome-devtools-axi cover GitHub and browser operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
Lavish is used only for presentation; visual, report, and review pages use it or a local HTML page.
Report files and chat text remain available, and scouts deliver text reports when Lavish is unavailable.
The [Claude harness reference](../.agents/skills/harness-adapters/references/harness/claude.md#claudeai-publishing-tools) covers publishing-tool limits for launched workers and secondmates.

**Backend requirements**

The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
`fm_backend_required_tools` in `bin/fm-backend.sh` owns the backend additions:

| Resolved backend | Additional tools |
| --- | --- |
| `tmux` | `tmux`, `treehouse` |
| `herdr` | `herdr`, `jq`, `treehouse` |
| `zellij` | `zellij`, `jq`, `treehouse` |
| `orca` | `orca` |
| `cmux` | `cmux`, `jq`, `treehouse` |

The JSON-emitting adapters (`herdr`, `zellij`, `cmux`) need `jq` because their spawn and liveness paths parse backend JSON.
Every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`) uses `treehouse` for worktrees.

Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.

Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.

**Feature-specific requirements**

- When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
- When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.

**Missing-tool diagnostics**

`tasks-axi` and `quota-axi` are essential bootstrap tools in every profile.

- An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual`, a home with a configured non-markdown adapter or a markdown backlog refuses lifecycle mutation until compatible `tasks-axi` is on `PATH`, while a manual-backend home keeps its backlog hand-edited.
- An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
- An absent or board-incompatible `lavish-axi` reports `PRESENTATION_UNAVAILABLE` with the 0.1.77 compatibility floor, install command, and explicit text fallback; compatible versions below 0.1.80 retain legacy board replies and report an upgrade recommendation for synchronous acceptance, while [`bootstrap-diagnostics`](../.agents/skills/bootstrap-diagnostics/SKILL.md) owns diagnostic handling.
- An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.

**Checkout diagnostics**

Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.

**Project refresh at startup**

The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.

- It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
- Normal completed runs keep local-only and no-origin skips silent.
- If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.

**Stale Git lock recovery**

A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.

It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.

**Secondmate sync at startup**

The same deferred network stage performs guarded tracked-file sync and propagates declared inherited local material into each validated live home under that sequencing contract.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.

- It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
- When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
- If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
- The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.

**Push inherited configuration during a session**

For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap; its [help](../bin/fm-config-push.sh) owns reporting and exit semantics, and [`fm_config_inherit_items`](../bin/fm-config-inherit-lib.sh) declares the inherited items.

- When an allowlisted config item changes for an already-running local home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
- A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
- The locked bootstrap inheritance pass uses the same placement-specific behavior; see `secondmate-provisioning` for the single contract owner.
- That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
- Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.

The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs, updates, fetches, or changes `PATH`, a version manager, or any installed tool.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

**Entry fields and probe behavior**

- Each entry needs a `name` and at least one of `command` or `git`; an entry may carry both.
- A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reads the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
- The announcement counts as `update available` only when the version it names is newer than the newest installed copy found; a version already installed is reported only as `update not in effect`, so one completed install does not report both in the same sweep. An announcement naming no readable version is reported as an available update as before.
- A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
- `announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
- An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
- A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
- An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.

Both probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
See [`docs/examples/watched-tools.json`](examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

**Arm, edit, and disarm**

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.

- That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
- Registering the check is itself a reason to watch, so the home keeps a watcher for it after the last task is torn down, and `disarm` is what ends that need.
- `bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.

**Repeat reporting and inheritance**

- The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
- A changed or returning condition is reported again.
- Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.
- This file is not inherited by secondmate homes, so each home watches the tools it actually depends on.

**Probe timing and limits**

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_TOOL_UPDATE_INTERVAL` | 900 seconds | Time between probes; `0` probes on every run. |
| `FM_TOOL_UPDATE_PROBE_SECS` | 5 | Bounds one probe. |
| `FM_TOOL_UPDATE_BUDGET_SECS` | 20 | Bounds a whole sweep. |

- A sweep that runs out of budget says which tool it did not reach rather than reporting the rest as current.
- The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills prints nothing and records nothing and would then repeat that silence on every poll.
- So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
- A budget that is not a whole number from 1 to 120 is still refused outright.

## Direct-PR freshness (config/pr-autoupdate.json)

The optional home-local `config/pr-autoupdate.json` enables [`bin/fm-pr-autoupdate.sh`](../bin/fm-pr-autoupdate.sh).
An absent file or `enabled: false` keeps the updater off, and no startup path arms it automatically.
This file is not inherited to child homes.
Each home owns only its explicitly linked task PRs; the script header and help own cadence, receipts, continuation, locks, and failure handling.

```json
{
  "enabled": false,
  "write_scope": []
}
```

The object accepts exactly `enabled` (boolean) and `write_scope` (array).
Each grant has exactly `pr` (a canonical GitHub PR URL), `head_repo` (`owner/repository`), and `head_ref` (the exact task branch).
A grant permits base-into-head updates of that PR only while its observed head repository and branch still match.
Fork heads require their own exact grant; repository-wide and implicit default-branch grants are unsupported.
For example, an approved grant can be `{"pr":"https://github.com/example/repo/pull/123","head_repo":"example/repo","head_ref":"fm/example-task"}`.
Unknown keys and malformed grants refuse rather than broadening scope.

Activation is a separate approval for the exact home and branch-write scope.
Updates write remote commits and may trigger CI, notifications, compute spend, deployment, or publication workflows.
Exclude any branch whose workflow has an unapproved outward effect until that effect has explicit approval.
After approval, set `enabled: true` with the exact grants and invoke `bin/fm-pr-autoupdate.sh arm` with explicit `FM_HOME`.
The authenticated shim runs through the existing watcher; no cron, host timer, pinned model, or worker subscription is needed.
`disarm` removes that shim and trust binding while preserving pending receipts.
`status` prints the coverage journal without contacting the forge.

Direct-PR ships need their canonical task metadata, recorded ready head, clean task copy, confirmed done worker, and positive absence of pipeline custody.
The updater uses `gh-axi`, `jq`, Git, and the installed no-mistakes read surface to establish those preconditions.
Pipeline-owned tasks are deferred pending a pipeline-native freshness feature; an unknown owner, unavailable read, or unsupported forge remains visibly incomplete.
An accepted request records the PR, expected old head, and request time, then leaves the resulting head and its checks to the task delivery path and normal contribution observer.
The updater never publishes `pr_head`, confirms a resulting SHA, or grants review or merge authority.
After an accepted request, shared contribution readiness remains invalid until the delivery owner records the changed head and a later normal observation validates it.
An uncertain request stays pending and keeps readiness invalid without a repeated write; the delivery owner must resolve that evidence.

Fixture regression: `bash bin/fm-test-run.sh tests/fm-pr-autoupdate.test.sh`.
This regression exercises local doubles and does not prove live GitHub asynchronous update behavior.
Live write verification requires a separately authorized disposable PR before enabling real fleet writes.

## Boat spend check (config/boat-spend.json)

`config/boat-spend.json` is an optional local, gitignored file that turns on the daily Boat spend check.
With no file the check is off: [`bin/fm-boat-spend-check.sh`](../bin/fm-boat-spend-check.sh) prints nothing and never calls Boat, and `arm` refuses.
The check only reads Boat: `boat --no-update limits --json`, `boat --no-update list --all --json`, and `boat --no-update billing status --json`, which is the only place Boat shows whether auto-refill is on.
It never runs any other Boat command, so it cannot create, resume, stop, or delete a sandbox or change billing.

This section is the single owner of the schema.
`bin/fm-boat-spend-check.sh` owns the conditions, cadence, and report line.

```json
{
  "ceiling_usd": 30,
  "expected_running": 1,
  "allowed_sizes": ["small", "default"],
  "always_on": ["<sandbox id that is meant to run with no auto-stop>"],
  "boat_bin": "<optional absolute path to the Boat CLI>",
  "resume_ttl_seconds": 3600,
  "idle_grace_seconds": 900
}
```

- Every field is optional.
  The check's defaults are the values above, with an empty `always_on` and no `boat_bin`.
  `account_seconds_per_24h` and `box_seconds_per_24h` are optional whole numbers of seconds, 1 or more, and are omitted by default.
  `resume_ttl_seconds` is an optional whole number of seconds from 1800 to 14400, and `idle_grace_seconds` is an optional whole number of seconds from 0 to 86400 that must be shorter than both the configured resume timer and the 3600-second renewal fallback, including when either uses its default.
  [Boat idle check](#boat-idle-check) owns the timer and cadence requirement.
- `account_seconds_per_24h` and `box_seconds_per_24h` are for dispatch, not for this check.
  The check accepts them and does not report on them.
  [`bin/fm-boat-send.sh`](../bin/fm-boat-send.sh) owns how they reserve spend, including the historical ceilings it keeps when the file or a key is absent.
- `resume_ttl_seconds` is the short timer a new resume starts with, capped by the plan timer, and the sender reserves only that timer.
  Extends use the same cap.
  Dispatch to a running box is refused when its remaining timer is below the [renewal threshold](#boat-idle-check); a stopped box resumes with a fresh timer.
  After SSH hydration, the sender rechecks the timer and extends it within the plan cap before spawning a worker if it has fallen below that threshold.
  A failed extend refuses the spawn.
  `idle_grace_seconds` is how long a listed running box may report no workers before the idle check stops it.
  The spend check accepts both and does not report on them; [Boat idle check](#boat-idle-check) owns them.
- `expected_running` is also the sender's cap on how many box ids `config/boat-box-id` may list and how many sandboxes may be active together; the supported range is 0 to 3.
  A fleet that runs up to three default boxes all day sets `ceiling_usd` to 100, `expected_running` to 3, `account_seconds_per_24h` to 259200 (3 times 86400), and `box_seconds_per_24h` to 86400.
  With `box_seconds_per_24h` set, a box whose rolling usage is still within that value may reserve one more timer, so usage plus that timer may reach the value plus the timer.
  The account, monthly, and balance checks also add the remaining timers of the other active listed boxes.
  An active listed box with no readable timer refuses the reservation.
- An unknown key, a value of the wrong type, or a file that is not exactly one JSON object (an empty file included) is refused, and the check reports the file as invalid rather than falling back to defaults.
- `boat_bin` exists because the watcher runs the check with its own environment, where `boat` is usually not on `PATH` and no `FM_BOAT_BIN` persists, so the file is the one durable place to name the CLI.
  It must be an absolute path to an existing executable file; anything else makes the file invalid, and an invalid file runs nothing.
- `FM_BOAT_BIN` wins over `boat_bin`, and `boat` on `PATH` is the last resort.
- The file is not inherited by secondmate homes.

**What is reported**

The check prints one `boat-spend:` line, joining every condition that is outside what the file says, and prints nothing otherwise.

- Spend this billing period is over `ceiling_usd`, or projects over it by the period's end at the last-24-hour rate.
  Spend is `creditUsedSeconds` over `creditSecondsPerDollar`, so it trusts Boat's own counter; whether that counter resets at each renewal is confirmed at the first renewal, not assumed.
- More sandboxes are in an active state than `expected_running`.
- An active sandbox is a size not in `allowed_sizes`.
- An active sandbox has no auto-stop deadline and is not in `always_on`.
- Auto-refill is enabled.
- The trial or plan end is within 3 days, which also gives a renewal reminder each month.
- A sandbox reports health other than ok, carries a restore error, or is an active sandbox that has not finished restoring its disk at the daily evaluation.
- A stopped sandbox is within 3 days of Boat deleting its stopped disk, 14 days after it stopped, or is already past that point.
  This expiry warning is the one stopped-sandbox condition the check reports.
- The check could not see everything, because a check that cannot see is reported rather than treated as quiet.
  That covers a missing `jq` or Boat CLI, a timed-out call, malformed JSON, an invalid `config/boat-spend.json`, a sandbox list with more pages than were read, and a field that is missing or not readable: spend, last-24-hour usage, active states, a plan or trial end, the sandbox list, a sandbox's state, or the auto-refill state.
  Every such cause in one run is consolidated into a single `read failed:` part of the line (an invalid file is named as such instead), not one part per cause.

Stopped sandboxes are otherwise never reported, because Boat bills only while a sandbox runs.

**Arm, cadence, and disarm**

Arm the check once per home with `bin/fm-boat-spend-check.sh arm`.

- That writes `state/boat-spend.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it and turns its one line into a `check:` wake; no separate schedule is involved.
- An evaluation that read everything is recorded, and the next one is due 24 hours later; a condition that persists is reported again at each due evaluation.
- An evaluation that could not see everything is not recorded, so the next watcher poll tries again and a passing failure does not cost the day's check.
  Its line is printed at most once per 24 hours while the failure lasts, and that limit is lifted as soon as a read succeeds.
- Each Boat call is bounded to 9 seconds so the three together fit inside `FM_CHECK_TIMEOUT`.
- Registering the check is a reason to watch on the same terms as the [watched-tool check](#watched-tool-updates-configwatched-toolsjson), and `bin/fm-boat-spend-check.sh disarm` removes the shim, its trust binding, and both records.

## Boat idle check

With the idle check armed, [`bin/fm-boat-idle-check.sh`](../bin/fm-boat-idle-check.sh) checks listed worker boxes from the PC, so a down box watcher does not matter.
While `fm-boat-worker.sh idle` reports live workers it starts a detached renewal when the remaining timer is below twice the box revisit interval plus the 122-second total renewal timeout, and once a listed running box reports no worker records or endpoints for `idle_grace_seconds` it stops that box with the Boat CLI's stop command, keeping the snapshot and never deleting.
Scheduled work still resumes only through the sender when a Boat-eligible task is actually queued; nothing here is always-on, and worker boxes stay off the `always_on` list.
This section owns the behavior; the script's header owns the exact commands, bounds, and records.

**Safety**

- A box with a live worker is never stopped, and a box not listed in `config/boat-box-id` is never touched.
- An unreadable idle report or instance is treated as busy when the box's running state and timer are known, and can trigger renewal. An unreadable state or timer prevents an explicit stop but cannot guarantee renewal.
- The send lock covers each state read, worker probe, timer extension, and stop, so a concurrent dispatch or teardown cannot change a box between its liveness report and action.
- With several boxes, each sweep starts where the last one left off, so a slow box cannot starve the rest of extends and stops.
- The supported fleet has at most three listed boxes.
  `FM_CHECK_INTERVAL` must be a whole number from 0 to 3600 seconds (300 seconds by default).
  The worst-case revisit interval is the number of listed boxes times (`FM_CHECK_INTERVAL` plus the 30-second per-box check budget).
  An effective timer of `min(resume_ttl_seconds, 3600)` shorter than three revisit intervals plus the 122-second total renewal timeout is refused.
  With three boxes, the default 300-second poll and a configured 3600-second timer are accepted.
  Recovery reads of the box allowlist remain available if the cadence becomes unsafe.
- Idle grace belongs to the current box instance. A new boot instance starts a fresh grace, and a successful `--prepare` resume clears that box's old idle record.
- `FM_CHECK_TIMEOUT` must be at least 30 seconds for this check to run, which is also the default.
- Extend skips its spend reservation on purpose, because a live worker must not lose its box to a ceiling; the spend check stays the ceiling watchdog.

**What is reported**

The check prints one `boat-idle:` line only when firstmate should wake, and prints nothing otherwise.

- Every box it stopped, with how long the box had been idle.
- A failed extend after two consecutive attempts, once until an extend succeeds, and a failed stop at most once per hour per box.
- An invalid config, a missing CLI, or a missing box list, at most once per 24 hours.
- A poll killed at `FM_CHECK_TIMEOUT` prints nothing and resumes next cadence from the durable idle-since records.

**Arm and disarm**

Arm the check once per home with `bin/fm-boat-idle-check.sh arm`, which refuses without a spend config or a readable box list.

- That writes `state/boat-idle.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it and turns its one line into a `check:` wake; no separate schedule is involved.
- `bin/fm-boat-idle-check.sh disarm` removes the shim, its trust binding, and both records.

## Idle session exit

A worker that reported done, or that is parked on a decision, keeps its agent session and that session's MCP children alive until someone exits it, although the work already sits in its worktree, branch, report, and pipeline run.
[`bin/fm-idle-exit.sh`](../bin/fm-idle-exit.sh) ends those sessions and keeps everything else.
It is off until armed.

**What it does**

- It reads each direct ship or scout task in this home, never a secondmate and never a remotely placed task.
- A task's activity is the newest mtime of its status, turn-ended, and meta files and its inbox.
- A task that `bin/fm-crew-state.sh` reads as `done` is exited after `FM_IDLE_EXIT_DONE_SECS` (default 600) idle seconds; one read as `parked` is exited after `FM_IDLE_EXIT_PARKED_SECS` (default 3600) only when its status has an open decision or the attributed pipeline gate awaits a human answer.
- Every other state (working, paused, blocked, failed, unknown) is left alone.
- The exit is `bin/fm-control.sh <id> exit --only-if-idle`, so a turn that is not idle at the exit point is refused with exit 3 and left running, and the endpoint, worktree, and every uncommitted change are kept.
- It never tears down, discards, relaunches, or removes a worktree.
- At most one agent is exited per run, which keeps the run inside `FM_CHECK_TIMEOUT`; the next poll takes the next candidate.
- An exit outcome is recorded in `state/.idle-exit/<id>` against its activity stamp; successful exits are not probed again until new activity, failed exits are retried on later polls but reported only once per activity stamp, and a record whose task is gone is pruned.

An exited worker stays supervised.
A steer sent to it with `bin/fm-send.sh` is recorded durably, and the usual [relaunch](agent-control.md) resumes it when an answer arrives.

**Report line**

The check prints `idle-exit: exited <id> (<state>, idle <n>m); endpoint, worktree, and work kept` when it stopped an agent, `idle-exit: exit of <id> ... failed: <reason>` once per activity stamp when an exit could not be proven, and nothing otherwise.

**Arm and disarm**

Arm it once per home with `bin/fm-idle-exit.sh arm`.
That writes `state/idle-exit.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the watcher runs it on its `FM_CHECK_INTERVAL` cadence.
`bin/fm-idle-exit.sh disarm` removes the shim, its trust binding, and the records.

## Clutter check

[`bin/fm-clutter-check.sh`](../bin/fm-clutter-check.sh) is a daily read-only check for machine-wide clutter that slows the whole fleet.
It never kills, deletes, or moves anything; it reports and a person acts.
Because it reads the whole machine, `arm` refuses in a secondmate home, and it is armed in the root home only.

**What is reported**

The check prints one `clutter:` line, joining every condition past its threshold, and prints nothing otherwise.
Long copy lists show up to two names per finding and count the rest, so the line retains the pool, log, and disk findings.

- Treehouse worktree pools under `FM_CLUTTER_POOLS_ROOT` (default `~/.treehouse`) totalling more than `FM_CLUTTER_POOLS_MB` (default 5120).
- No-mistakes pipeline copies under `FM_CLUTTER_WORKTREES_ROOT` (default `~/.no-mistakes/worktrees`) totalling more than `FM_CLUTTER_WORKTREES_MB` (default 20480), or a single repository/run copy over `FM_CLUTTER_COPY_MB` (default 3072).
- Archived no-mistakes logs under `FM_CLUTTER_LOGS_ROOT` (default `~/.no-mistakes/logs`) totalling more than `FM_CLUTTER_LOGS_MB` (default 5120).
- The Linux root filesystem with more than `FM_CLUTTER_ROOT_USED_MB` (default 153600) in use.
- `/mnt/c` with less than `FM_CLUTTER_WINDOWS_FREE_PCT` (default 10) percent free.
- A measurement that could not finish, because a check that cannot see is not quiet.

**Cadence**

- An evaluation is due 24 hours after the last one; polls inside that day stay silent, and a condition that persists is reported again at each due evaluation.
- Sizing every pipeline copy at once can outlast `FM_CHECK_TIMEOUT`, so each copy's size is cached in `state/.clutter-check/sizes` and a poll sizes the copies not yet measured within a budget of `FM_CLUTTER_MEASURE_BUDGET_SECS` (default 14, at most 16) seconds.
- A due evaluation waits until every copy has a size from since it fell due, and a copy that outlasts the whole budget is reported as a read failure rather than blocking every poll.
- Each `df` is bounded to 3 seconds, and the pool and log measurements are each bounded to 2 seconds.

**Arm and disarm**

Arm it in the root home with `bin/fm-clutter-check.sh arm`, which writes `state/clutter.check.sh` and binds its bytes with `bin/fm-check-register.sh`.
`bin/fm-clutter-check.sh disarm` removes the shim, its trust binding, and the records.

## Data management (config/data-management)

[`bin/fm-data-manage.sh`](../bin/fm-data-manage.sh) measures the homes, pool roots, and stores named in the optional local `config/data-management`, then plans retention cleanup.
Dry-run is the default.
Live deletion requires `--live` on `clean`.
It also requires a regular `config/data-management.live-authorized` file in the first configured home, which must be the root Firstmate home.
Create that marker only after reviewing the dry-run report; the tool checks its existence and does not create it.
The script header owns the config grammar, the protected-path rules, the landed-work classification, and the output records.
Category totals overlap, so a home is not added to its children.

A worktree directory is never removed by this script.
A landed, clean, idle pool slot is handed to [`bin/fm-treehouse-guard.sh`](../bin/fm-treehouse-guard.sh) `prune`, and only in live mode.
Copies named by a task record stay in place.
Stopped workers remain the job of [`bin/fm-deadweight-sweep.sh`](../bin/fm-deadweight-sweep.sh).
[`bin/fm-clutter-check.sh`](../bin/fm-clutter-check.sh) remains the read-only threshold check.

The script does not delete `data/` records, home `config/`, live task records, secrets, dotenv files, browser profiles, SSH or cloud CLI configuration, or anything under `/mnt`.
A file inside any checkout or task-named copy is left in place when a deletion root contains it.
A `cache` deletion root removes aged regular files, so it must not point at a package-manager store or a session store.
`cache-tool` runs that tool's own purge, bound to the configured directory, and skips stores with an open file, protected path, or checkout.
`claude-sessions` removes only old session logs, and `codex-sessions` runs `codex-session-prune` when it is installed.
`procevent-result` removes only an old handled result group whose source is no longer registered.
The script header owns which files those directives can touch.
Docker is measured when the client answers and is never pruned.

Copy [`fm-data-manage.service`](examples/data-management/fm-data-manage.service) and [`fm-data-manage.timer`](examples/data-management/fm-data-manage.timer) from [`docs/examples/data-management/`](examples/data-management/) into `~/.config/systemd/user/`, replace the path placeholders, then enable the timer.
The shipped service runs a dry-run.
After reviewing the dry-run report, create the authorization marker and add `--live` to that `ExecStart`, then run `systemctl --user daemon-reload` to enable scheduled deletion.

## Disk guard (config/disk-guard)

[`bin/fm-disk-guard.sh`](../bin/fm-disk-guard.sh) samples available RAM, free swap, Linux disk, free space on `/`, `C:`, and `D:`, and an optional virtual-disk file.
It is the predictive check for this machine.
The script header owns the floors, the lead window, the projection, the log line, when the pause flag is written or removed, and when pressure wakes are sent.
The defaults are 8 GiB of available RAM, 100 GiB free on `/`, `C:`, and `D:`, 70 percent of the Linux filesystem that holds the home, and a 30 minute lead.
`/mnt/c` and `/mnt/d` are checked only when that path is a real directory.
The script header owns the optional `FM_DISK_GUARD_ROOT`, `FM_DISK_GUARD_C`, and `FM_DISK_GUARD_D` path overrides.
Optional `config/disk-guard` in the root Firstmate home replaces any of those and names the virtual-disk file.
The guard writes `state/disk-guard.pause` in that root home when a floor is already crossed or the lead window says it will be.
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh) refuses a fresh ship or scout while a regular pause file or symlink exists at that path: it launches nothing, creates no record, leaves the backlog item queued, and exits 75 until the flag is repaired or removed.
A relaunch and a secondmate are not deferred.
The guard removes a regular pause flag only when every monitored reading is present and healthy, and it does not follow a symlink there.
An absent or timed-out reading is not pressure by itself.
When a pause flag already exists and a monitored reading is absent, the flag stays and the sample logs `action=held-unknown`.
Each `df` read stops after 15 seconds.
Low free space on `/`, `C:`, or `D:` sets `alert=low` and is pressure, so the same `disk-guard` wake is the low-disk alert.
[`bin/fm-jev-mem-guard.sh`](../bin/fm-jev-mem-guard.sh) is the read-only memory check beside this timer.
It prints a verdict and, with `--check`, exits 1 on warning or critical.
It does not schedule itself.
The sample that first writes the flag runs [`bin/fm-data-manage.sh`](../bin/fm-data-manage.sh) `clean` once when the root home's `config/data-management` is regular, adding `--live` only when the authorization marker is regular too.
The nightly data-management timer stays a dry-run until its own service command gains `--live`.
The guard does not trim the page cache.
The machine's existing root cron owns that trim.
The guard may stat the configured virtual-disk file and read free space on `/`, `/mnt/c`, and `/mnt/d`, and it never walks `/mnt`.
Copy [`docs/examples/data-management/fm-disk-guard.service`](examples/data-management/fm-disk-guard.service) and [`fm-disk-guard.timer`](examples/data-management/fm-disk-guard.timer) into `~/.config/systemd/user/`, replace `FM_HOME` and `ExecStart` with the root home and the installed script, then enable the timer.
Enable it only after this change has landed on the default branch.

```sh
mkdir -p ~/.config/systemd/user
cp docs/examples/data-management/fm-disk-guard.service ~/.config/systemd/user/fm-disk-guard.service
cp docs/examples/data-management/fm-disk-guard.timer ~/.config/systemd/user/fm-disk-guard.timer
systemctl --user daemon-reload
systemctl --user enable --now fm-disk-guard.timer
```

The timer is a sample every 10 minutes.
The example service sets `TimeoutStartSec=20min`, which is longer than the 900 second cleanup bound.
A oneshot unit has no start timeout unless that setting is present.
It is not an installer.

## Mail plane (.env)

The mail plane (bin/fm-mail.sh) reads unseen IMAP messages and sends one SMTP message.

**Polling and delivery guarantees**

Its `poll` command surfaces each new message as a durable `check: mail <uid>` wake, which is also what the standing received-mail check runs each watcher cycle.
Poll emission is exactly-once-recovering: a published wake always carries a durable journal record, and a poll interrupted before recording its uid is healed from that journal, so inbound mail is never silently missed.

A duplicate wake is possible if the process is killed between the queue append and the journal write and the drain acknowledges that row before the next poll heals it, or under a triple write fault that leaves a queued row with no durable record; neither case drops mail.

**Connection and activation**

IMAP and SMTP use implicit TLS on the default ports 993 and 465 (`IMAP4_SSL` / `SMTP_SSL`).
STARTTLS and port 587 are not supported.

It is off unless the home's gitignored `.env` provides the connection values.
This section is the single owner of the mail-plane configuration schema; for direct invocations, environment values override `.env`, matching the Relay contract.

Required, in the home's gitignored `.env`:

```sh
FM_MAIL_USER=   # IMAP/SMTP login
FM_MAIL_PASS=   # IMAP/SMTP password
FM_IMAP_HOST=   # IMAP server hostname
FM_SMTP_HOST=   # SMTP server hostname
```

`FM_IMAP_PORT` (default 993), `FM_SMTP_PORT` (default 465), `FM_MAIL_TIMEOUT` (default 20 seconds), and `FM_MAIL_POLL_MAX_WAKES` (default 20, valid 1..200) are optional.
The per-poll wake cap bounds the wakes of one `poll` run; header fetches scan a larger bounded window of new unseen uids plus already-surfaced retry-set uids, so a flood or large backlog still makes bounded progress every poll, keeping the durable wake queue bounded without ever dropping mail.

**Unfetchable headers**

A message whose header cannot be fetched is surfaced with a degraded summary instead of being skipped, so it is never missed and cannot block later mail.
A later poll retries that fetch and, on success, surfaces the real sender and subject; a persistently unfetchable message stays degraded without repeating that wake.

**Arm unattended polling**

A home that wants mail polled unattended arms the standing check in the live home: `bin/fm-mail-check.sh arm`.
Arming writes `state/mail.check.sh` and registers it with the watcher's slow-check cadence (`FM_CHECK_INTERVAL`), so the plane's `poll` runs on its own: new mail still surfaces as `check: mail <uid>` wakes from the poll, and the standing check itself also prints a line (and the watcher turns that line into a wake) unless the poll is a proven no-op.

Same-line silence is only for a proven no-op: a successful poll with no new mail, or a repeated identical pre-wake failure that cannot have queued mail.
A fail-closed poll that already queued a wake, and a timeout, always print so the watcher wakes to drain it.

`FM_MAIL_CHECK_BUDGET` (default 15, valid 5..25) bounds one standing poll and is cut down to fit `FM_CHECK_TIMEOUT`.
`bin/fm-mail-check.sh disarm` removes the standing check.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.

Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.

**Activation, consent, and routing**

It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.

Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.

**Endpoint and environment overrides**

`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.

`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.

3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

**Generated state and watcher cadence**

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.

The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section owns the Relay cadence contract:

- A Relay instance polls every 30 seconds instead of the default 300.
- A non-Relay home has no `config/x-mode.env`, so its cadence does not change.
- When that file exists, the session-start supervision operating block includes the cadence instruction.

The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.

**Apply cadence changes**

Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While a legacy daemon flag is active the daemon owns the watcher and its default cadence applies; on Pi the away-posture record alone leaves the ordinary Relay watcher cadence active, and daemon-backed Relay cadence remains a deferred follow-up.

When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.

Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

**Poll and deduplicate mentions**

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.

A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.

Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.

**Conversation context and media**

The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first conversation transcript.
Each entry has the shape `{author_handle, text, unavailable, images, attachments}` and may include `kind`:

| `kind` | Meaning |
| --- | --- |
| `reply` | A reply ancestor. |
| `thread_starter` | The message a thread grew from. |
| `history` | A recent nearby message. |
| Absent | A legacy reply-ancestor or thread-starter entry. |

The chain is untrusted third-party public input.
It is often absent today: the relay currently sends it only for Discord reply chains and thread starters.
Consumers must treat it as strictly optional, tolerate unknown or missing fields, and treat `unavailable: true` as a gap rather than content.
The `fmx-respond` skill owns how firstmate uses the chain to resolve references.

The mention and its chain entries may also carry attached media as image or file URLs, in fields such as `images` and `attachments`, either as bare URL strings or as objects with a `url`; a mention whose own media is empty can still have screenshots on its `thread_starter` entry.
The poll preserves those URLs in the stashed object and never downloads them, so nothing is fetched on the polling path: the responding agent retrieves and views the media with its own tools when it handles the mention.

The `fmx-respond` skill owns which hosts that fetch is restricted to and the untrusted-content handling that applies to whatever comes back.

**Durable reply context**

The same authoritative relay payload also supplies durable per-request reply context at `state/x-context/<request_id>.json`, with shape `{request_id, platform, reply_max_chars, recorded_at}`.
The poll writes this best-effort record keyed by `request_id`, so concurrent requests never overwrite each other.
It survives inbox cleanup after acknowledgement, allowing a delayed follow-up to recover the original platform and split budget even without a task link.

- `recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
- A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
- Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
- The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.

**Handle requests and acknowledgements**

The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.

- Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
- If the work completes in that turn, the public reply reports the outcome.
- If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work.
  When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
- That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.

**Resolve the reply platform and budget**

Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` consults these sources in order:

1. The durable per-request registry.
2. The still-present inbox payload.
3. For a follow-up posted live by request_id only, an authoritative relay lookup through `POST /connector/request-context`: `{request_id}` in, `{platform, reply_max_chars}` back.

This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.

**Link tasks and handle missing context**

The link lives in the current home's `state/<task-id>.meta`.
Work routed to a secondmate has no record here, so `bin/fm-x-link.sh` refuses to link it.
When possible, the refusal names the registered secondmate home containing the task.

It also points to `bin/fm-public-followup.sh register ... --work-home secondmate:<id>`.
This promised-final path is the only follow-up mechanism that binds work in another home.
`bin/fm-x-link.sh` uses the same order when recording a fresh link's context and requires `jq`.
Its request-context lookup is best-effort.
Any of these conditions leaves the context unknown:

- No token or `curl`.
- A non-2xx response.
- An unresolved response.
- A relay version without that endpoint.

The link is still recorded, but `bin/fm-x-link.sh` prints a loud warning.
If either the follow-up platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses with fail-safe exit 8.
Firstmate holds the follow-up and retries once both values are recoverable; it never posts with a local default.

**Carry a link to a successor task**

Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.

**Dismiss mentions**

Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.

**Poll errors**

Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.

**Post replies and follow-ups**

Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.

Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.

**Follow-up success, expiry, and retry**

- A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
- The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
- `fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
- It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
- Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.

**Split replies by platform**

- Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
- An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
- If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
- When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.

**Reply and follow-up limits**

| Setting | Default | Limit or behavior |
| --- | --- | --- |
| `FMX_X_REPLY_MAX_CHARS` | 280 | Clamps to a minimum of 50. |
| `FMX_DISCORD_REPLY_MAX_CHARS` | 1900 | Clamps to a minimum of 50; values above Discord's 2000-character limit reset to 1900. |
| `FMX_X_THREAD_MAX` | 25 | Caps oversized reply threads on every platform; truncation marks the last retained message with an ellipsis. |
| `FMX_FOLLOWUP_MAX_AGE_SECS` | 604800 (7 days) | Local completion follow-up window. |
| `FMX_FOLLOWUP_MAX_COUNT` | 3 | Local follow-up cap. |

**Preview with dry-run**

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.

- In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
- When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
- In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
- The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
- These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned entirely by `tasks-axi public-followup`, while the full private conversation context stays only in `state/x-context/`.

Firstmate's bounded registration retains the obligation's public-safe request binding so a delivered loop can be rechained without the original inbox.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop.

Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

**Private transport records**

Registration creates this home's private transport under `state/public-followup/` with mode 0700:

| Entry | Purpose and retention |
| --- | --- |
| `registry/` | Bounded private binding for each open public loop; survives delivery with `state=delivered`; only `retire` removes it. |
| `events/` | Typed terminal results awaiting reconciliation. |
| `consumed/` | Accepted-event ledger. |
| `rejected/` | Refusals retained with a one-line reason. |
| `rejection-wakes/` | Each refusal's not-yet-raised wake. |
| `retired/` | Mode-0600 reason-and-time receipt written before removal. |
| `surfaced` | The poll's last-surfaced signature. |
| `outbox/` | Also created in a work home that reports across a machine boundary; described below. |

**Which home posts the reply**

The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; when writing directly into the owning home, that emitter refuses a home with no registration for the named obligation.

**Prepare and validate terminal results**

`bin/fm-public-followup.sh brief` pre-fills every deliverable value the binding determines, such as `report_path=data/<work-id>/report.md`, and states the accepted format of every value it cannot know.

- The emitter validates deliverable values and known required keys before publishing, including the relative `report_path` format, and names correctable mistakes at the work home.
- A direct emit reads the obligation from `tasks-axi`; a staged emit cannot read that remote record, so `brief` supplies its required keys in the printed command.
- If those flags are omitted from a staged command, it still checks values but cannot detect missing keys until the owning home's `consume` rejects the event and queues a rejection wake.
- The [emitter header](../bin/fm-public-followup-emit.sh) and its `--help` own the exact flags and outcome-dependent validation rules.

**Clear legacy links in remote homes**

When that work lives in a REMOTE secondmate home, delivery clears its bound legacy link after validating the public receipt, while retirement clears the link before closing the loop, and both clears run over that route's SSH transport.
Readable remote state proving that no link exists succeeds without a write.
A present link is cleared only when its Relay request identity matches the registration and the state is writable.
Any of these conditions retains the loop for reconciliation:

- An identity mismatch.
- Unreadable or unsafe state.
- An unavailable write or lock.
- An older remote copy.
- A host that never confirms the clear.

**Duplicate and failed results**

A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.
When bound work ends failed or parked, its typed failed result remains deliverable even when the promised final expected a merged pull request, so the owed reply carries the honest failure instead of remaining stranded.

**Collect results across machines**

Work bound to a REMOTE secondmate home reports across a machine boundary, where no local path reaches the owning home.

- `bin/fm-public-followup.sh brief` therefore prints that worker the route's own code root and home with `--stage-in`, so the typed result is staged in `outbox/` in the home where the work actually runs rather than written to a path that only exists on the owning machine.
- The owning home collects staged results for open registrations over the same SSH route it reaches that secondmate on, because that transport only runs in the outbound direction: `consume` pulls them into its own `events/` and then reconciles them exactly as it reconciles a local report.
- Non-open registrations owe no result, so `consume` skips them without contacting their routes; an open registration whose reachable route has nothing staged remains pending without an error.
- Collection is non-destructive until the result is durably held, and the staged copy is retired only afterwards, so a dropped connection can never lose a terminal result.
- For an open registration, a work home that cannot be reached is named in `consume`'s output and keeps the promise open; it is never reported as an empty inbox.

Run `bin/fm-public-followup-collect.sh --help` for the staged-result commands the owning home runs over that route.

**Activation and idle cost**

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.

- A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
- Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
- A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.

**Wake on new or rejected results**

Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.

- A terminal event `tasks-axi` refuses during `consume` is quarantined with a reason naming the specific deliverable, outcome, or missing key where one is identifiable, and the same poll wakes the owning home with a `public-followup rejected <event-id> ...` line carrying that reason.
- The refused event stays pending until that wake is recorded, and a queued wake survives a failed read or write to poll output.
- That makes the wake at-least-once rather than exactly-once: a cleanup that fails after the line was already raised - a wake directory that cannot be written, or a refused event that could not be drained - raises the same refusal again on a later poll.
- A repeat carries the same event id and the same reason as the quarantined rejection, which is how an already-handled refusal is recognized.
- Acknowledge it without re-acting; re-emitting an already accepted corrected result is harmless but redundant because its derived event id is already in the accepted ledger.

**Startup, teardown, and retries**

The session-start digest separately prints a "Public commitments" subsection from disk when, and only when, this home is relay-active and still holds an open public loop (a reply still owed, or a delivered loop with nothing owed), so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.

`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind restart recovery, failed terminal outcomes, retained-loop disposition, and the relay-disabled zero-overhead guarantee.

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.

[`extension-bindings.md`](extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own exact command mechanics.

**Discovery and disabled behavior**

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, environment payloads, and Pi packages are never searched for extensions.

When the directory is absent, ordinary process-event commands perform only a bounded absence check, create no package or extension state, and preserve every built-in adapter path.

**Bind a trusted package**

Binding separates the package's own manifest from this home's explicit enablement.
`bind` performs these steps:

1. Validate the source package and compute every digest.
2. Copy the complete tree into the read-only content-addressed `data/extensions/packages/` store.
3. Perform the live handshake.
4. Atomically publish the enabled adapter-name subset.

The operator supplies trust and required consent facts, not hashes.

**Working state and cleanup**

`state/extensions/<extension-id>/` is created when binding performs its initial handshake and is that package's home-local working namespace for later verification and invocation.
`state/extension-invocations/` contains private host-owned exact process-group cleanup records only while an enabled package invocation is starting or running; retirement and reconciliation retain their existing owners until those records prove the group extinct.

This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

Use an absent destination for the copy so the source identity remains inspectable and reproducible.
For a non-default home, set `FM_HOME=<that-home>` on every command; local and remote secondmate homes bind the package independently, and bindings are not inherited.

**Bind on a remote secondmate**

For a configured remote secondmate, keep the package at the controller and transfer it through the authenticated `fm-on` route:

```sh
bin/fm-extension.sh remote-bind <secondmate-id> \
  /absolute/controller/path/to/file-signal \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
```

The command serializes only the validated extension package, stages it below the addressed remote home's fixed extension staging root, binds it there, and prints transfer and binding digests.
Registration uses `bin/fm-on.sh <secondmate-id> fm-procevent.sh ...`.

**Retire a binding**

After retiring every registration with its printed owner token and handling every captured result, retire the enabled remote binding and its exact staged transfer together with `bin/fm-on.sh <secondmate-id> fm-extension.sh retire-transfer <extension-id> --if-transfer-digest <transfer-digest> --if-binding-digest <binding-digest>`.
For a direct local binding, use `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>` after the same process-event retirement and handling steps.

Both commands retain the retired identity reversibly and leave unrelated bindings and content-addressed installed packages unchanged.

**Register a completion source**

Register one file completion source with a path-safe source id and an explicit non-secret source configuration reference.
Credential values never belong in that reference, command argv, or a process-event result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the new registration's owner token and exact owner-matched retirement command.

**Classify and acknowledge results**

The source waits outside the conversational turn, and its completed result arrives through the existing process-event `check` path.
Classify the captured result through its immutable package identity with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with the existing `handled` command only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.

**Keep blocking sources out of the turn**

Never run the registered blocking source command directly in a conversational turn.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; built-in adapters retain their tracked `bin/fm-procevent-<adapter>.sh` commands, while an explicitly bound external adapter routes through the trusted host contract above.

`bin/fm-procevent-lavish.sh` is the first built-in adapter and wraps the published `lavish-axi poll` interface plus `lavish-axi reply` when the installed version supports synchronous reply acceptance.

**Open the Lavish artifact first**

Before arming any Lavish source, open its artifact with `bin/fm-lavish-open.sh` so the saved session identifies the board's server; reply and poll attempts derive their host and port from that session and refuse missing or invalid session evidence before posting or consuming a staged worker reply.

**Retry interrupted Lavish polls**

That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times with poll starts at least 5 seconds apart, so an internal retry never reaches the runner as a captured result.
This start-to-start governor is a no-op after a normally blocking poll but caps an immediately returning poll under the shipped defaults independently of the owner lease and registration launch pacing.

Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 1 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so retire the source, then arm it again to adopt this retry policy.

### Crew-hosted Lavish review boards

**Arm and confirm a listener**

A live task that hosts a Lavish board owns its listener, so firstmate must never arm that board.
After opening the artifact as required above, the worker arms it with `bin/fm-procevent-lavish.sh arm <artifact.html> --for <task-id>` and never runs `lavish-axi poll` itself.

`arm` prints `armed` only after the process-event owner confirms this registration generation's listener is running, and otherwise returns nonzero without that line.

- The confirmation is the same live claim or launch-stamp evidence `reconcile` already uses, bounded by `FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS`, and a failed confirmation retires a source that never started unless `retire` refuses because something may still own it, in which case the registration stays for `reconcile` or a human.
- An earlier registration's listener that releases the board inside the confirm window lets the new registration start, and `arm` then reports `armed` as usual.
- When a live listener from an earlier registration of the same board still holds it when the window ends, `arm` exits zero with `still-listening` instead of `armed`, because that earlier listener keeps serving the board and the new registration takes effect only after the source is retired and armed again.
- The arm is refused unless that task id has valid, identity-matching endpoint metadata, because a board whose owner has no endpoint would collect feedback nobody can be told about.

**Acknowledge a round by re-arming**

The registration persists as one task-owned source record, while each captured nonterminal round remains open until the worker re-arms and the existing handled marker acknowledges that round.
Re-arm acknowledges that round and registers the next listener: the board is armed once while no record exists, and a further arm by the same owner is refused unless an unacknowledged nonterminal round is waiting, so an open round is never replaced before its owner acknowledges it.

**Post an agent reply**

Re-arm never acquires, releases, or hands off the source claim.
It may carry `--agent-reply-file <path>`.
With lavish-axi 0.1.80 or newer, the reply is posted through `lavish-axi reply` under the source lock only after the arm passes its endpoint, ownership, and pending-round checks, and the server's acceptance is awaited before the listener is registered or armed.
An arm refused for endpoint, ownership, or pending-round eligibility never posts the reply, and a failed or timed-out reply stops the arm before it registers a listener or acknowledges the round, so the worker cannot hand the board back as ready and can retry the same arm.
If Lavish accepts the reply but the local registration then fails, retrying the arm posts that reply again; this rare duplicate is a known, benign limitation.

Older compatible Lavish versions keep the prior behavior: the reply is staged into the listener and sent through `poll --agent-reply`, which cannot confirm acceptance before its long-poll returns.
That compatibility path does not provide the synchronous handoff guarantee: a crash after the listener consumes its staged reply but before its poll posts it can lose that round's reply.
Only a version probe that confirms an older compatible release selects that path.
When `lavish-axi` is missing, its version cannot be read, or it is below the board floor, a reply-carrying arm fails without posting or registering a new listener; the worker's original reply file remains available for retry.
The Lavish version floors and feature probe are owned by `bin/fm-bootstrap.sh`.

**Deliver feedback to the worker**

- The captured result is stored with immutable task-owner routing evidence and delivered directly to that task's steering inbox, without a firstmate `check` wake for the captain's words.
- The doorbell rings only when that idempotent write creates a fresh inbox record; filing the note into `handled/` is the worker's own acknowledgement of the delivery, so a later reconcile never moves an already-filed note back into the active inbox or re-rings its owner, and re-delivery of a note still open in the inbox is left to the steering inbox's own re-ring ladder.
- A task-owned source with an unhandled capture is not relaunched, so delivery failure cannot consume a round and start another poll.
- That record is the only ownership evidence there is, so while any captured round of it is unacknowledged every retirement path refuses - the runner's own terminal retirement and an explicit `retire` alike - and the refusal names the acknowledgement that releases it.

**Conclude a terminal round**

- A terminal result, including `session_ended`, an empty End, or missing, is delivered to the owner with an explicit stop-and-conclude instruction and is never auto-rearmed.
- That round keeps the board with its owner: the source record is not retired while the terminal capture is unacknowledged, so no second armer can take the board, and acknowledging it with `bin/fm-procevent.sh handled <source-id> <sequence>` is what concludes and retires it.
- That conclude retains the registration it is retiring, removes it, then records the acknowledgement and restores the registration if that record cannot be written, so a failed conclude never leaves the round open with its owner gone.
- An interruption between those two durable steps leaves the board unregistered with its terminal round still open, which nothing relaunches and the same `handled` call finishes.
- It concludes only a round that is still open, so a repeated acknowledgement of an already-closed round reports `already-handled` and never touches whatever registration holds the board by then.

**Ownership and recovery**

- A second armer is refused with the current owner named, and the source list derives `listening`, `round-open`, or `dead` from the claim and handled captures without a second ownership record.
- If the hosting worker cannot be recovered, relaunch a worker to re-host first; guarded firstmate adoption is an explicit last resort only after the old claim is proved dead.
- The cross-home gap between worker rounds remains an accepted residual until lavish-axi's exclusive listener lands.
- The interim crew instruction emitted by `bin/fm-brief.sh` points workers at this arm-and-acknowledge contract.

**Register deterministic condition and action watches**

The `when` adapter (`bin/fm-procevent-when.sh`) registers a deterministic condition and action once.
Its blocking child polls the condition without waking firstmate.
A stable true fires the action at most once.
One terminal outcome is then durably captured and published as a wake, which remains eligible for re-announcement until handled.

The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs, and that binding is reloaded from disk immediately before each fire rather than trusted from when polling started.
A repo update that fast-forwards an in-repo action's bytes in place would otherwise desync every already-armed watch's trust binding with no tampering involved; `bin/fm-procevent-when.sh rebind-all` re-hashes and republishes the binding for every registered watch whose action lives under `FM_ROOT`, including one already polling, so it keeps firing across such an update instead of being refused on its next fire.

Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

**Capture and publish results**

This section is the single owner of the runner's operating contract.

- Process-event commands resolve the state root to its physical directory before validating it and deriving paths, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target directory remains refused.
- Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
- By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
- The self-announcing adapter exception and its fail-safe ordering are defined below.
- The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
- A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
- A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.
- By default, a runner releases its claim after one poll; an adapter that opts into `relisten` keeps that runner and claim across empty waits and captured results, adopting a replacement registration only when the registered command is unchanged and the claim still belongs to it.
  A failed relisten check releases the claim; the runner never refreshes its own home lease.
  The `bin/fm-procevent.sh` header owns the exact seam, and [remote secondmates](remote-secondmates.md#how-remote-lines-are-mirrored) owns the reply listener's behavior.

**Reconcile sources**

Discovery is never a timer.
Each registered source has its own child process blocking on that source.
On every cycle, the watcher's `reconcile`:

- Republishes every captured result without a durable handled acknowledgement, regardless of earlier publication.
- Restarts a source whose owner is gone.
- Stops this home's runner if its registration disappeared unexpectedly.

In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

**Suppress only adapter-confirmed no-op results**

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.

- Before publishing, the runner asks the immutable captured owner through the built-in `silent` command or external `result.silent` operation and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
- The task-owned terminal exception is evaluated first, so an empty terminal board round goes to its owner's steering inbox for the required conclusion instead of entering this generic silence path.
- A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
- For built-ins, silence remains independent of the keyed-answer feed below: suppressing an announcement never suppresses the captain's own answer.

**Lavish silence rules**

- For Lavish that verdict covers two shapes - a session the adapter classifies `ended` that carries no queued content block at all, which is a review surface closed with nothing said, and `browser_disconnected` (classified `disconnected`), which carries no answer while the session remains open.
- Any recognized top-level `prompts` or `feedback` block counts as content regardless of its declared count, and a malformed header makes the result indeterminate rather than empty.
- A `Send & End` close carrying the captain's answer arrives as `status: feedback` with `session_ended`, so it classifies `feedback` and is announced unchanged, as is any `ended` result that still carries content, and every `waiting`, `missing`, `unknown`, or unreadable result.

**Retire terminal sources**

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture, the runner asks the immutable captured owner whether the result is terminal.
It uses the built-in `terminal` command or external `result.terminal` operation.
Under the default ordering, this happens after the initial `check` publication.

- Exit 0 retires the registration.
  The exception is a task-owned board, whose owner must first acknowledge the round as defined above.
- Retirement drops only the exact registration generation captured by the claim.
  Under one source boundary, it releases that claim only after removal succeeds.
- A missing command, an error, or any other exit keeps the source armed.
  An adapter with no notion of ending needs no change.

- A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
- Any registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending; replacement becomes eligible only after that generation is proved gone or its terminal retirement completes.
- A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work.
- For ordinary sources, explicit `retire` stays the supported and idempotent path afterwards; a task-owned board instead refuses `retire` until its owner concludes the open terminal round with `handled`.
- For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

**Apply built-in results automatically**

Applying a captured result through code is a built-in adapter seam, and some built-in results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the built-in adapter apply and acknowledge its own result.

That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.

**Adapter-controlled announcement order**

The built-in `bin/fm-procevent-<adapter>.sh self-announcing` command declares announcement order:

| Response | Runner behavior |
| --- | --- |
| Exit 0 | The adapter declares that every result its autohandle fully applies is announced through its own durable downstream channel; the runner applies first, then publishes a `check` wake only for results still unhandled. |
| Any other response | Keep strict publish-before-apply ordering; autohandle runs only after this capture's own wake was successfully appended to the durable queue. |

The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.
The [remote-secondmate channel contract](remote-secondmates.md#normal-operation) owns replay suppression and its bounded upgrade exception; a replay that adds no mirror bytes stays quiet.

**Feed keyed captain answers**

Keyed captain answers from built-in adapters use one more seam of the same kind, and the runner still decides nothing about them.
Some built-in sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.

- A built-in source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
- A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
- The built-in adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future built-in answer source needs nothing here beyond an `answers` command and a binding.

**Reconcile selections and handling boundaries**

- The reserved Reconcile selection uses the parallel optional `reconciles` adapter command and binding-verified `reconcile-requests` intake rather than entering keyed answers; [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md#reconcile-re-check-reality-never-a-blind-close) owns those semantics.
- Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer or request is transcription while acting on it is firstmate's judgement.
- An unbound built-in source, a built-in adapter without the corresponding command, and a failure on either side all leave the capture untouched and still announced.
- External binding responses never enter either authority-bearing intake.

**Machine-wide source ownership**

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.

- Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
- Each claim binds its caller-reported home and runner PID to a process identity, unique claim generation, exact registration-file generation, and resolved state-root identity.
- Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
- A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.

**Prove ownership before stopping a runner**

- Every stop proves ownership before its first signal: the live runner's recorded process identity must match and it must still lead its process group.
- Once that stop has proved ownership and sent TERM, its own escalation to KILL checks only whether the proved group still has members; it does not re-read the leader's identity or group membership, which can change or become unreadable as TERM ends the leader.
- This proof belongs only to that stop's own escalation and cannot authorize another caller that encounters an unproved group.

**Recover orphaned claims**

A stale claim whose process group still has members is one `reconcile` never displaces, and the two shapes it comes in recover differently.
`reconcile` preserves such a claim without signalling the ambiguous group or starting a replacement: the group check probes the runner's own process group, which contains its polling source child, so surviving members can mean that child is still attached to the session the source collects from, and a replacement would put a second destructive poller on it.

`list` reports both shapes as `orphaned`.

**Reused PID with surviving group members**

When the recorded pid is alive under a different identity but the group still has members, the claim boundary itself does not consult the process group.
In this case, `bin/fm-procevent.sh start <source-id>` reclaims the claim only if it can tidy the dead generation's reservation records.
Otherwise it refuses with `cannot claim source`.

Tidy-up is waived only for a generation proved gone.
This generation does not meet that condition.
That hand-run command is the recovery path, taken by someone who has checked that nothing is still polling the source.

That asymmetry between the automatic path and the deliberate one is the design rather than an inconsistency, and it is not a claim-level invariant: nothing below `reconcile` enforces it.

**Dead leader with surviving group members**

If the leader died from anything other than the stop's own signal and its group still has members, `start` does not reclaim the claim.
It reports `already owned` and changes nothing.

`retire`, `reconcile`, `sweep-home`, and the guard all refuse the surviving group permanently, so the source stops listening.
Recovery there is a human verifying whether the dead runner's polling child is still attached to the source; once that process group is empty the generation reads as gone and the next `reconcile` reclaims the source on its own.

Nothing automatic signals that group, and whether it may ever be signalled remains an open decision; the repaired guard does not close this gap.

**Report stranded claims**

The first `reconcile` that strands either kind of claim generation publishes a durable `check` wake.
It names the source and the recovery step:

- For a reused pid, the `start` command.
- For a leaderless group, the check to make.

Later cycles stay silent for the same generation.
A genuinely new stranded claim announces again.

**Reclaim a generation proved gone**

Reclaiming a generation that IS gone is not gated on tidying anything that generation left behind: its capture-reservation records, its staging file, or the registry directory a claim recorded for them.
Every one of those is keyed by claim token and every replacement claims a fresh one, so a leftover that can no longer be located or removed - a state-root identity a claim recorded before its home was re-created, or a recorded registry directory that no longer resolves to a directory - is stale bytes rather than an ownership hazard.

Making any of them a precondition is what leaves a provably dead runner owning its source permanently, because none of those conditions clears on its own.

- Ordinary release and reclamation still attempt reservation cleanup and require it unless both owner staleness and whole-group absence prove the generation gone.
- The narrow live-owner terminal-self-retirement path also attempts cleanup but tolerates its own still-in-flight reservation, which the runner removes on the normal end-of-capture path; exact home, PID, and claim-token ownership remains mandatory before the claim is released.

**Stop refusals and residual races**

- If identity cannot be established before the first signal, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
- A live PID whose identity no longer matches is refused before the first signal.
- Identity and process-group verification cannot be made atomic with signalling in portable shell: the reaper signals only a target it has verified as the recorded generation, but PID and group reuse remain possible in the narrow interval between verification and the signal.
- Launch pacing is the primary host-wedge protection; watchdog cleanup is a backstop.

**Retire a secondmate home**

- Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
- If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
- If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
- The sweep retires local registrations and machine-wide claims whose recorded state-root identity matches that home's resolved state root through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
- Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.

**Recover from unsupported manual deletion**

Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

The owning-home lease below bounds how long such an orphan can run, but it is a backstop, not a substitute for the supported path.

**Home lease and its limits**

A runner is bound to the HOME that owns it, not to the one session that armed it.
That granularity is deliberate: a persistent source is meant to outlive the turn and the session that armed it, so binding a runner to its arming session would stop exactly the sources this mechanism exists to keep running.

Any activity in the same home refreshes the lease, so a replacement session, another watcher, or an ordinary inspection command keeps a runner of that home alive; a runner whose SOURCE is no longer wanted in a live home is stopped by reconcile when that source is retired, independently of the lease.
The lease is therefore the backstop for a home that is GONE - the torn-down test sandbox this change exists to bound - and not a per-session ownership check.

KNOWN LIMIT: while any activity continues in a home whose original owning session has ended, that activity refreshes the lease and a runner of that home keeps running until its source is retired or the home goes away.

**Keep and guard the lease**

Detaching a runner into its own process group is what lets a persistent source outlive the turn that armed it, and on its own it is also what lets a runner outlive its whole home: reparented to init, it keeps its blocking child - and every process that child spawns - running with nothing left to reap it.

- So a home's process-event state carries a lease that registration, attached start, reconciliation, acknowledgement, and listing refresh, and the watcher's reconcile cycle is what keeps it fresh in a live home.
- An attached public `start` continues refreshing the lease while its caller remains attached.
- Each runner fails closed unless a small guard starts successfully beside it in a separate process group.
- That guard accepts the lease only while the state root retains the device/inode identity recorded by the runner's claim, and initiates the verified stop after two consecutive reads cannot prove that identity and lease freshness, so one unreadable read cannot kill a live runner.
- Those two reads are spaced half a check interval apart, so the pair the debounce requires completes inside one check interval instead of costing two of them.

**Detection and stop timing**

For a runner whose ownership can still be proved, the nominal detection bound is the lease plus one check interval.
The verified stop then runs within its own grace period.
The lease age is compared in whole seconds, so the configured lease is honoured until that age reads one second past it.

Scheduling delays or failed inspection and signalling can extend the whole bound.
That grace is a ceiling rather than a delay every stop pays: two seconds for the ordinary signal and two more for the forced one, spent only by a group that outlives the signal it was sent, which is why a healthy runner's stop completes in a fraction of a second.

The group signal reaches the blocking child and everything under it exactly as retirement does.

**Prevent accidental self-refresh**

- A runner exports the inherited `FM_PROCEVENT_IN_RUNNER` marker and every lease refresh is skipped under it, so a runner and its ordinary children do not certify their own owner, and the next reconcile in a live home simply starts a replacement runner.
- That no-self-refresh rule is CONFUSED-AGENT-GRADE, the same deliberate captain-decided grade `bin/fm-lease-lib.sh` documents: it stops the accidental case this boundary exists for, an orphaned or test-scaffolding source tree that would otherwise keep its own owner alive.
- A source that DELIBERATELY strips the marker from its environment can still refresh the lease, so adversarial-grade unforgeability is explicitly out of scope here and tracked as separate follow-up design work.
- Scope is the owning state root and one runner generation, never a script or process name, so a live source in another home is untouched: that home refreshes its own lease.

**Lease and launch pacing settings**

| Setting | Default | Range | Purpose |
| --- | --- | --- | --- |
| `FM_PROCEVENT_OWNER_LEASE_SECONDS` | 600 | 1..86400 | How long a runner continues without activity in its owning home. |
| `FM_PROCEVENT_OWNER_CHECK_SECONDS` | 15 | 1..3600 | Guard detection interval; it reads the lease and recorded state-root identity twice per interval, half an interval apart, so both debounce reads fit inside one interval. |
| `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` | 1 | 1..3600 | Minimum time between consecutive launches of one registration generation's stored command; bounds immediately returning sources during the lease window. |

The generation's first launch is immediate, later launches share its monotonic pacing timestamp, a timestamp from before a reboot is treated as expired, and replacing the registration starts a fresh pacing generation.

**Confirm detached launches**

`FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` (default 3, range 1..600) bounds how long `reconcile` waits for the runners it just started to prove they are running: never less than the configured value, and at most one second more, because the wait is measured on a whole-second clock.

- Starting a runner is detached and its errors are not visible to the caller, so `reconcile` reports a start only after the source is observed owned or its launch-pacing stamp has advanced or appeared, and reports every unconfirmed launch as `failed=` and a non-zero exit instead.
- Both signals are durable evidence a runner claimed: ownership is the only evidence a runner still blocked on its source ever shows, and the stamp - written after the claim and before the source command runs, and removed only by registration replacement - covers a runner that claimed, ran and exited between two polls.
- A healthy launch therefore confirms on the first poll and the window only bounds a launch that has not yet proved itself - one that died before claiming, or one merely too slow to claim inside the window; confirmation cannot tell those apart, and a launch that proves itself on a later cycle closes its failure episode without a retraction wake.
- All of a cycle's launches share one window, so a home full of sources that cannot start costs the same bounded wait as one.

**Keep confirmation below the watcher interval**

Keep this window well below `FM_POLL`.
`bin/fm-watch.sh` runs `reconcile` once per supervision cycle, so a source that cannot start makes every cycle wait up to the confirm window before the rest of that cycle runs.

Raising the confirm window lengthens every supervision cycle and delays wake delivery by up to that much.

**Report launch failures**

A source that can never start is reported as `failed=` with a non-zero exit on every `reconcile`, rather than counted as `started` and retried silently as though it were healthy, so a wedged source stays visible instead of presenting as armed.
The `failed=` count reaches only the command's caller because `bin/fm-watch.sh` discards `reconcile` output and exit status.
For that reason, `reconcile` also publishes a durable `check` wake once per failure episode, with key `procevent:<id>:launch-failed:<registration-identity>-<episode-nonce>`.
Later cycles stay silent for that episode until a launch confirms.
A later fresh failure gets a fresh key, because the watcher never re-surfaces a key it has already surfaced.

- The announcement changes nothing about the launch: `reconcile` keeps relaunching the source every cycle exactly as before, and nothing is retried differently, throttled, or recovered from that signal.
- The wake reports only the observed failure: the launch did not prove that it took the claim within the window.
- If the failure persists, inspect the source command and adapter binary named in the registration.
  The wake names both, along with the attached `bin/fm-procevent.sh start <source-id>` command that reproduces the refusal on stderr.
  The detached launch discards that output.
- A later cycle that finds the source owned ends the episode automatically.
  A runner that was merely slow to claim needs no operator action.
- A source stranded on a claim nothing may automatically displace is announced the same way, once per stranded claim generation, as described above.
- `bin/fm-watch.sh` surfaces both under their own headlines - `process-event source stranded` and `process-event source failed to start` - rather than as a captured result.

**Reject unusable settings**

A value this command cannot use is refused by name before anything is launched, the same way `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` and `FM_PROCEVENT_MAX_OUTPUT_BYTES` are refused, so a mistyped window can never present as a fleet of sources that cannot start.
`bin/fm-watch.sh` validates the same value when it arms and refuses to arm on an unusable one, naming the variable and the range: under a running watcher that refusal would otherwise repeat on every cycle into a discarded stdout and leave the whole home disarmed while presenting as supervised, whereas a watcher that will not arm is loud through the liveness guard.

**Limit captured output**

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

**Durability guarantees and limits**

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.

- `bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
- Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
- The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
- The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
- Never describe this path as at-least-once, no-loss, or lossless.

`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Spoken interface and captain inbox (config/voice-*, config/inbox-*)

The spoken interface in [`docs/voice-relay.md`](voice-relay.md) and the model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, model id or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, with an environment variable that overrides it for a single run, and a missing required value refuses with the path to write rather than falling back to a value that belongs to another home.

That configuration is the whole opt-in: an unconfigured home cannot start the relay and cannot run `fm-inbox.sh say` or `ask`, while `note`, `announce`, `reply`, `receipts`, `ready`, `status`, `list` and `drain` need no configuration at all because they make no model call.
The voice handover depends on `note`, so it keeps working in a home that has configured nothing.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-region` | `FM_VOICE_REGION` | Bedrock region for the relay's bidirectional session, required by `bin/fm-voice-relay.py`. |
| `config/voice-model` | `FM_VOICE_MODEL` | Speech-to-speech model id, required by `bin/fm-voice-relay.py`. |
| `config/voice-profile` | `FM_VOICE_PROFILE` | AWS profile the relay exports credentials from; absent, or an explicitly empty variable, means it uses only credentials already in its environment. |
| `config/voice-id` | `FM_VOICE_ID` | Output voice id, optional, `matthew` when unset. |
| `config/voice-read-scope` | none | `counts` (the default, and what an absent file means) or `full`; see [`docs/voice-relay.md`](voice-relay.md) for what each scope may say. |
| `config/voice-read-deny` | none | One plain case-insensitive substring per line; a matching open item is withheld from every list and reduced to a count. |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `fm-inbox.sh say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `fm-inbox.sh ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those two calls; absent, or an explicitly empty variable, means whatever credentials are already in the environment. |

**How configuration files are parsed**

Each account, model and voice file above is read as its first line that is not blank and not a `#` comment, so a comment above the value is fine.
The two read files use different parsing rules:

- `config/voice-read-scope` must contain only the bare word with optional blank space around it.
  A comment header causes a refusal rather than being skipped.
- In `config/voice-read-deny`, every line that is neither blank nor a `#` comment adds one substring.

`FM_VOICE_RELAY` and `FM_VOICE_PYTHON` belong to the laptop rather than to a home, so they have no config file: `bin/fm-voice-client.py` requires the relay path as a flag or that variable and carries no default path.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
FM_TASK_ID=             # internal task-worker marker fm-spawn.sh exports into ship and scout panes, never set by hand; bin/fm-test-run.sh refuses to execute in the repository primary checkout while it is set
FM_TASK_INBOX=          # internal: absolute path of the task's steering inbox (state/<id>.inbox) that fm-spawn.sh exports into every ship, scout, and secondmate launch, never set by hand; the steering doorbell names "$FM_TASK_INBOX"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_ORCA_CLI=            # Orca view tabs only: the Orca command line to use instead of the one bin/fm-orca-view.sh finds; see "Orca view tabs"
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/fm-line-cap-lib.sh
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
FM_SESSION_START_ENDPOINT_TIMEOUT=10   # seconds bounding each per-task endpoint liveness read in the session-start digest (bin/fm-session-start.sh); nonpositive or invalid values fall back to 10; a read that hits the bound or dies becomes that task's own `endpoint: error` line and the digest continues
FM_BACKLOG_ROW_TIMEOUT_SECS=10   # seconds bounding each backlog row read (bin/fm-backlog-transition-lib.sh); nonpositive or invalid values fall back to 10; the first bound hit latches the sweep so later reads return immediately, each still naming its own item
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the deferred inactive-outcome scan plus network checks, including the lock waits the worker makes before them; hitting it prints an actionable NETWORK_CHECKS line, and a lock a live process still holds at the deadline ends the worker with a failed-rerun record (publication and delivery are bounded by FM_SESSION_START_TIMEOUT the same way)
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HOME_SUMMARY_INTERVAL=300   # seconds before a live watcher refreshes this home's state/home-summary.json even without a status signal; invalid or zero values use 300
FM_HOME_SUMMARY_TIMEOUT=60     # seconds bounding the complete best-effort home-summary refresh, including lock acquisition, validation, atomic publication, and worker-side failure logging; invalid or zero values use 60
FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES=65536   # approximate size cap for state/.home-summary-refresh.log before it is trimmed to the newest 200 lines; invalid or zero values use 65536
FM_HOME_SUMMARY_FAILURE_REPORT=2   # recorded publication failures since the ledger's own last publication before session start reports a HOME_SUMMARY line; invalid or zero values use 2
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10   # seconds bounding each local per-task current-state read inside bin/fm-fleet-snapshot.sh; remote endpoint liveness is not probed on the snapshot path
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # maximum local tasks whose current-state and endpoint observations are collected concurrently during snapshot composition
FM_SNAPSHOT_BUDGET=5                # one total seconds budget for all concurrent remote home-ledger reads
FM_SNAPSHOT_CACHE_DIR=$FM_HOME/state/secondmate-summary-cache   # private parent-side cache of successfully fetched remote home ledgers
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=14  # floored elapsed-day threshold at which an undated captain hold (no hold-until; age from its UTC hold-set timestamp, falling back to since for legacy unstamped holds) is projected as a Charted Next gate instead of a live Captain's Call; 0 applies once the computed age is non-negative
FM_RECONCILE_REQUEST_MAX_BYTES=1048576   # maximum captured Bearings or fleet snapshot accepted for durable reconcile-notify request publication
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also requests an immediate scan in the deferred worker
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle pane; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_TASK_INBOX_BUSY_MAX=2      # consecutive busy-deferred due polls before a stuck-busy stale wake; 1..999999999, at most 9 decimal digits, otherwise 2; policy: bin/fm-task-inbox-lib.sh
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_MAIL_CHECK_BUDGET=15   # seconds allowed for one standing mail poll; valid 5..25, cut to fit FM_CHECK_TIMEOUT
FM_MAIL_POLL_MAX_WAKES=20   # per-poll wake cap for a mail poll; valid 1..200, keeps a flood from flooding firstmate
FM_MAIL_TIMEOUT=20   # mail-plane IMAP/SMTP socket timeout in seconds; invalid or non-positive values become 20
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_PROCEVENT_OWNER_LEASE_SECONDS=600    # how long a source runner keeps going with no activity in its owning home; 1..86400
FM_PROCEVENT_OWNER_CHECK_SECONDS=15     # a runner guard's detection interval, read twice per interval; 1..3600
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1     # minimum interval between launches of one registration generation's source command; 1..3600
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=3   # how long reconcile waits for the runners it started to prove they are running; 1..600, keep well below FM_POLL
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CODEX_WATCH_CHECKPOINT_AWAY=3600  # requested away checkpoint bound on a home that runs the supervision host; longer of this and attended bound, capped at 27000
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh, and per state-database run-inventory read behind a capped AXI overview
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # plain runs-ledger rows scanned for fallback attribution; does not change the CLI's AXI overview window (selection owner: bin/fm-nm-run-lib.sh)
FM_TEARDOWN_NM_RUNS_LIMIT=200  # recent no-mistakes run rows scanned to prove an unresolved-head parked run belongs to teardown's task
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by watcher triage: the working/paused classification, and the wedge timer's parked-gate wait evidence
FM_MAIL_USER=      # mail-plane IMAP/SMTP login, from .env or environment (docs/configuration.md "Mail plane")
FM_MAIL_PASS=      # mail-plane IMAP/SMTP password
FM_IMAP_HOST=      # mail-plane IMAP server hostname
FM_IMAP_PORT=993   # mail-plane IMAP server port
FM_SMTP_HOST=      # mail-plane SMTP server hostname
FM_SMTP_PORT=465   # mail-plane SMTP server port
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
TYPESAFE_API_KEY=       # typed dispatch resolution opt-in, from the environment or .env; absent means bin/fm-dispatch-resolve.sh is off (docs/configuration.md "Typed dispatch resolution")
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # grace seconds for missing or nonnumeric lock-owner PIDs (minimum 2s); dead numeric PIDs have no age grace
FM_GUARD_GRACE=300      # beacon freshness threshold for guard verdicts, arm health checks, and the primary turn-end guard; see docs/turnend-guard.md for model-aware exceptions
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, an open Stop auto-arm generation claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm follows an attached watcher cycle (bin/fm-watch-arm.sh header)
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCH_EXTENSION_LOG_KEEP_LINES=0   # opt-in Pi extension diagnostic log (state/.watch-extension.log); unset, empty, non-numeric, zero, or negative disables logging, a positive value keeps that many newest rows; logging never changes supervision behavior
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE if set, else the poll-derived grace (docs/turnend-guard.md "Guard grace and the poll cadence"); seconds before a fresh arm refuses a live holder's stale beacon (attached arms: FM_WATCHER_STALL_BOUND)
FM_WATCHER_STALL_BOUND=       # live-holder stall bound; default and arm/re-arm behavior: docs/turnend-guard.md "Guard grace and the poll cadence"
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_WATCHER_CLEANUP_LOCK_BOUND=   # optional watcher EXIT marker-lock wait; default and validation: docs/watcher-continuity.md
FM_TURNEND_CHURN_ABSORB_SECS=900   # longest one endpoint's bare turn-ends may be deferred on pane-churn evidence alone; only consulted when config/turnend-churn-absorb is present
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading declared-wait status verb; bin/fm-classify-lib.sh owns its meaning and legacy external-wait label; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates, unless that pane's own worker declared a wait that has not elapsed, or, where config/wedge-defer-parked-gate arms it, that pane's crew is parked at a validation gate awaiting the supervisor's decision on it that the crew raised under that run's key and nobody has answered yet, either of which takes the FM_PAUSE_RESURFACE_SECS recheck below instead; stale panes whose crew is not provably working surface immediately unless admitted directly to the declared-wait cadence, while a live idle declared wait still surfaces once before that cadence bounds repeats; at that same escalation moment a recovery-grade agent-state probe (docs/architecture.md owns that dead-record contract) reports a pane whose endpoint is proven `dead` or `missing` once and stops re-escalating it while it stays that way
FM_BUSY_TURN_MAX_SECS=3600         # maximum age without a completed turn or explicit native-harness progress (bin/fm-watch.sh owns marker selection), before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait, an attended verified captain-held transfer, or - where config/wedge-defer-parked-gate arms it - a validation gate of the crew's own awaiting the supervisor's still-unanswered decision takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_PAUSE_RESURFACE_SECS=14400      # four hours between bounded rechecks of a declared external wait or verified captain-held transfer, and between repeated new-hash stale alarms for an ordinary crew task with an open backlog captain call; a structured until time can make an external-wait recheck occur sooner but cannot extend this bound; this includes a live idle pane after its first inconclusive stale wake, a provably-working pane whose own unelapsed declared wait or, where config/wedge-defer-parked-gate arms it, unanswered supervisor-owed validation gate defers its FM_STALE_ESCALATE_SECS escalation, and a live busy pane past FM_BUSY_TURN_MAX_SECS, while the away-mode daemon uses the same setting and ages its window against the crew's own latest status line rather than pane busy state; a captain-held transfer is never rechecked while the away-posture record exists, while an armed validation gate awaiting the supervisor's decision keeps this recheck in either posture
FM_SECONDMATE_WAKE_STALL_SECS=180  # minimum interval with no change of the oldest actionable foreign wake-queue row (it advances as the mate drains, and a queue reprovisioned under the same task id starts a fresh interval at whatever sequence it restarts) before an endpoint-recorded local secondmate produces one durable parent wake-loop-stall notification for that no-progress episode; a mate that is provably inside an active turn (an exact busy verdict) does not escalate until that same no-progress interval reaches FM_BUSY_TURN_MAX_SECS above; a mate whose busy class is exactly idle, whose agent is alive, and whose composer is not pending is rung once so its own home can drain, and the parent notification is withheld until that same row stays frozen for another stall interval; unknown or ring-unsafe panes keep the parent alarm; declared external-wait pause rows are excluded, and zero or invalid values use 180
FM_SECONDMATE_LIVENESS_SECS=60   # seconds between watcher checks of each registered secondmate through bin/fm-secondmate-liveness-lib.sh; mates in data/secondmate-on-demand are skipped before an endpoint probe, while eligible mates relaunch only from a positively `dead` or `missing` endpoint through the ordinary guarded fm-spawn.sh --secondmate path and emit exactly one check wake per relaunch; zero or invalid values use 60
FM_SECONDMATE_LIVENESS_TIMEOUT=120   # seconds bounding one watcher-driven relaunch, so a wedged spawn cannot stall the poll; zero or invalid values use 120
FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS=3   # automatic relaunch attempts allowed per mate inside the window before the watcher parks auto-relaunch behind state/.secondmate-relaunch-bound-<id> and escalates once; a later live probe clears the marker and restores the full attempt budget (the ledger keeps its history behind a `rearmed` row); zero or invalid values use 3
FM_SECONDMATE_LIVENESS_WINDOW_SECS=3600   # window the relaunch bound counts state/.secondmate-relaunch-<id> attempt lines over; the file is also the durable per-mate relaunch record; zero or invalid values use 3600
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_MAXDEPTH=6       # depth that same probe walks below the recorded worktree; it runs only at the moment a wedge escalation would otherwise fire, never on every poll; no probe knob applies to a secondmate, whose recorded worktree is a provisioned home the probe skips entirely
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; it no longer bounds the adapter composer state/content reads on tmux or herdr, which supply their bounded visible pane instead, while the cmux, orca, and Zellij adapters use this small window so stale scrollback banners stay out of the candidate set; it still bounds the shared inbox composer read (bin/fm-task-inbox-lib.sh) on every backend, and on herdr it also floors how many Ctrl+U presses a refused leftover may take
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled tmux, herdr, and Zellij reads)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once; agy typed targets use a longer per-harness default owned by bin/fm-send.sh
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after the request turn completes without a correlated parent report before its one recovery repost is eligible, and after the recovery turn completes before the missed-report escalation is eligible; never counted from delivery
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# supervision host (bin/fm-supervision-host.sh); read only in a home that runs it
FM_SUPERVISION_HOST_PARK_SECONDS=27000   # the host ends its park with a cycle-boundary wake after this long, under the Stop hook's 28800 s timeout
FM_SUPERVISION_HOST_TURN_TIMEOUT=1200    # bound on one engine turn; a turn that hits it hands its wake to main
FM_SUPERVISION_HOST_ROTATE_TURNS=20      # the engine conversation starts fresh after this many turns (and at every main session start)
FM_SUPERVISION_ENGINE_GRACE=30           # seconds between TERM and KILL when an engine turn is stopped
# spoken interface and captain inbox; see "Spoken interface and captain inbox" above
FM_VOICE_REGION=        # overrides config/voice-region for one relay run
FM_VOICE_MODEL=         # overrides config/voice-model for one relay run
FM_VOICE_PROFILE=       # overrides config/voice-profile; explicitly empty forces ambient credentials
FM_VOICE_ID=            # overrides config/voice-id; matthew when neither is set
FM_VOICE_RELAY=         # laptop-side path to bin/fm-voice-relay.py on the desktop; required by fm-voice-client.py unless --relay is passed
FM_VOICE_PYTHON=python3 # laptop-side interpreter used to start the relay over ssh
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh say and ask
FM_INBOX_STT_MODEL=     # overrides config/inbox-stt-model for fm-inbox.sh say
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.

`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.

An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).

A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.

The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
