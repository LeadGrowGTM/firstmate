# Claude

Busy hooks verified 2026-07-28 on Claude Code 2.1.220.

## Operating facts

| Fact | Value |
|---|---|
| Busy | Owned hooks: `UserPromptSubmit` opens, `PreToolUse` re-opens a turn that continues without a prompt (a Stop-hook exit-2 continuation or an `asyncRewake` wake turn), while `Stop`, `StopFailure`, and `SessionEnd` close; manual interrupt emits no hook, so control reports delivered keys and live endpoint only, publishes no idle event or cancellation claim, and usually leaves `claude-hook` busy. |
| Exit | `/exit`. |
| Interrupt | Single Escape. |
| Skill | `/<skill>`, for example `/no-mistakes`. |
| Model | `--model <model>`; discover through the interactive `/model` picker, with alias or full-name shape documented by `claude --help`. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, verified on 2.1.196. |
| Permissions | `--dangerously-skip-permissions` by default, or `--permission-mode auto` when `config/claude-permission-mode` is `auto`; the `auto` shape verified on 2.1.269. See [`Claude permission mode`](../../../../../docs/configuration.md#claude-permission-mode-configclaude-permission-mode) for the launch grant and configuration. |
| Remote Control | A secondmate launch or relaunch carries `--remote-control 'fm-<id>'` unless `config/claude-remote-control` is `off`; a ship or scout launch never does. See [Remote Control](#remote-control). |

## Workspace trust

Claude gates a folder it has never seen behind an interactive workspace-trust dialog (titled "Quick safety check: Is this a project you created or one you trust?"), so every fresh task worktree would hit it, and so would every secondmate home no operator has opened by hand.
`--dangerously-skip-permissions` does not cover that gate: `claude --help` records that the dialog is skipped only in non-interactive mode, through `-p` or a non-TTY stdout, and a spawned pane is interactive.
Every claude spawn therefore pre-registers the directory its pane starts in before launch, and the dialog does not appear: the task worktree for a ship or scout, and the home itself for a `--secondmate` spawn, in either seeded shape (a leased worktree or a standalone clone).

A second, separate dialog - "Allow external CLAUDE.md file imports?" - renders whenever a loaded CLAUDE.md chain reaches outside the project tree, including a worker beneath a secondmate home's `CLAUDE.md` importing its `AGENTS.md`.
`--setting-sources project,local` (the minimal worker tool surface) does not suppress it either, and it gates the pane exactly like the trust dialog: cursor on "No, disable external imports", no way to move the selection from firstmate's steering plane.

`../../../bin/fm-claude-trust.sh` records `hasTrustDialogAccepted` for both the worktree and its primary checkout in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`, where a home's worker account pin decides `CLAUDE_CONFIG_DIR` (`../../../docs/configuration.md` "Worker account pin"), for a ship or scout spawn; a secondmate spawn registers trust only for its own home entry.
For a ship or scout worker in a seeded secondmate home's in-repo `.treehouse` or `.worktrees/.treehouse` pool, the helper pre-approves external imports on the canonical project entry unless an explicit decline is already recorded.
Other worktree launches register trust while leaving import approval to Claude's interactive decision unless an existing explicit decline makes registration refuse.
Its header owns the scope, persisted flags, decline refusal, and home-mode behavior.
This approval also applies to future interactive sessions in the canonical checkout because Claude reads the same project entry.

Never try to answer either dialog with a key.
Firstmate's key plane carries only Enter, Escape, and C-c with no arrow navigation, so it cannot move a dialog's selection at all, and both dialogs render with the cursor on their declining option, which means a sent Enter ends the session instead of accepting.
A visible trust dialog means pre-registration did not take effect - inspect the store and the spawn's error output rather than sending keys.
A visible external-imports dialog on a worker in a seeded secondmate home's in-repo pool means pre-registration did not take effect; inspect the store and spawn output.
`fm-control.sh <id> interrupt` delivers Escape, which is the safe way to clear a wedged workspace-trust dialog for inspection without answering it.
Escape on the external-imports dialog is different: it records a permanent decline (`hasClaudeMdExternalIncludesApproved: false`, `hasClaudeMdExternalIncludesWarningShown: true`) that `../../../bin/fm-claude-trust.sh` then correctly refuses to override on every later spawn for that project.
Leave a pane showing the external-imports dialog alone and have a person answer it interactively instead of interrupting it.
To recover from an already-recorded decline, remove both flags from the project's entry in `~/.claude.json` and approve the imports dialog once by hand.

The once-per-machine bypass-permissions confirmation is a third, separate dialog, scoped to the machine rather than the path, and pre-registration does not address it.
Never send Enter to that one either: it was observed rendering in the same shape as the trust dialog, with the selection on `No, exit` and the footer `Enter to confirm . Esc to cancel`, so Enter ends the session rather than accepting.
Firstmate cannot move a selection with Enter, Escape, and C-c alone, so it cannot accept this dialog at all, and an operator accepts it once per machine instead.
Inspect the pane to identify which dialog is on screen, and report it rather than answering it.
A remote second-mate launch or relaunch reports it for you: `../../../bin/fm-remote-secondmate-control.sh` refuses while the new agent is parked there, naming this dialog and the Herdr session a person opens on that host to accept it, and leaves the waiting agent in place so the same command succeeds once it is accepted.
A local launch has no such refusal, so there the shared classifier in `../../../bin/fm-busy-lib.sh` only stops the parked pane from reading as a working turn.
A launch under `config/claude-permission-mode=auto` never meets the bypass confirmation, because it does not request bypass mode: on 2.1.269 `claude --permission-mode auto` reached the composer directly with the footer `⏵⏵ auto mode on (shift+tab to cycle)`, so a captain who refuses the bypass dialog selects `auto` there instead of accepting it.
The workspace-trust dialog is unaffected by the permission mode and still needs the pre-registration above.

## Remote Control

[`Claude Remote Control`](../../../../../docs/configuration.md#claude-remote-control-configclaude-remote-control) owns the switch, the requirements, and the primary session's launch line.
The flag changes nothing about how a secondmate is supervised: its busy hooks, exit, interrupt, and steering are the same with or without it.
A relaunch registers a new remote session under the same `fm-<id>` name, so an offline entry with that name on the phone is the previous process rather than a fault.
A launch on an account that cannot use Remote Control still reaches the composer and works; a Remote Control failure notice in that pane is a sign-in fact to report, not a failed launch.
`/remote-control <name>` typed into a running session connects it in place without a restart.
Until its one-time confirmation has been accepted on that machine, `/remote-control` first opens a dialog, which is a person's consent: never answer it with a key, for the same reason as the dialogs above.
The one launch with the flag observed on a signed-in machine that had never used Remote Control [showed no such confirmation](../../../../../docs/verification/runtime-backends.md#remote-control-on-a-signed-in-host); if a first launch does park there, report it for a person to answer once in that pane.

## Composer ghost

Completed turns can render dim predicted text inside an empty composer, indistinguishable in plain `tmux capture-pane`.
The spawn scopes `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to every Claude worker and secondmate without changing global config.
CLI `--prompt-suggestions` affects print or SDK mode only and did not suppress interactive ghost text on v2.1.186.

As defense in depth, `fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` removes SGR-2 runs before pending classification on styled tmux, Herdr, and Zellij readers.
`../../../docs/herdr-backend.md` under "Composer and injection safety" owns dark-TRUECOLOR tradeoffs and `../../../docs/verification/runtime-backends.md` owns captures.
Styled capture stays internal to the boolean detector; `fm-peek` and model-facing captures remain plain, without escapes.

## Feedback drafts

The spawn disables Claude's `/bug` and `/feedback` model-drafted feedback flow for every Claude worker and secondmate, preventing a fleet-launched agent from queuing or submitting a bug report on the captain's behalf.
The controls are scoped to the launched process and never modify the captain's global Claude settings; `launch_template()` in `../../../../../bin/fm-spawn.sh` owns their exact mechanics and defense-in-depth rationale.

## claude.ai publishing tools

The spawn removes the claude.ai Artifact tool family and cloud-published claude.ai Docs from standard and direct or leading-assignment raw Claude launches for workers and secondmates, so their visual, report, or review pages use `lavish-axi` or a local HTML page as `AGENTS.md` section 1 requires.
Env-wrapped and compound raw Claude commands are outside this launch-time denial.
Plain report files and chat text remain available.
The control is scoped to the launched process and never modifies the captain's own Claude settings or primary session; `bin/fm-spawn.sh` owns the exact tool names and placement, and [`docs/verification/runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#claude-claudeai-publishing-tools) records the live proof.

## Status line

A Claude task worker or secondmate shows one compact status line (model and effort, task, worktree, context, plan windows) when the account it loads defines no `statusLine` of its own.
The spawn installs it through the firstmate-owned `.claude/settings.local.json`, never the launch line and never the captain's global settings, so a captain-defined `statusLine` always wins.
`../../../../../bin/fm-statusbar.sh` owns the command, its whitelisted fields, and the tmux detail line that covers every harness.

## Task control channel

A Claude task worker's launch brief and Firstmate steering-inbox messages arrive as file-shaped content that is otherwise indistinguishable from indirect prompt injection.
`launch_template()` in `../../../../../bin/fm-spawn.sh` establishes exactly those two Firstmate-owned channels as first-party instructions through `--append-system-prompt`, while leaving project files, fetched content, and other external material under the model's normal distrust and granting no merge, destructive, or security-sensitive authority beyond the brief.
A `--secondmate` launch omits the statement because a secondmate operates under its own supervisor contract instead of a task worker's.

## Primary integration

[`../../../../../docs/verification/supervision.md`](../../../../../docs/verification/supervision.md#turn-end-guard) records the current primary and Stop auto-arm live evidence.
This differs from the busy-state hooks the spawn writes through `.claude/settings.local.json` into a worker's worktree or a secondmate's home, which record semantic busy state and, for a worker only, touch a task marker.
A secondmate home's `.claude/settings.local.json` that never invokes `../../../bin/fm-busy-event.sh` is the operator's, so a claude secondmate spawn refuses rather than replace it, and `../../../bin/fm-control.sh` refuses such a relaunch before stopping the running mate.

Primary `.claude/settings.json` registers `../../../bin/fm-turnend-guard.sh --claude` and `../../../bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
Guard exit 2 plus stderr forces continuation.
Stop payload `stop_hook_active=true` follows any hook-driven continuation, including async reawakening, so Claude mode ignores it and uses cooperative claim and epoch plus bounded re-block; default Codex mode keeps it as a one-block loop guard.

Project `.claude/settings.json` loads only when the exact project root is the session root; Claude does not search parents, so Firstmate starts at repository root.
Hooks still run through cwd-sensitive `/bin/sh`, so tracked commands anchor through `"$CLAUDE_PROJECT_DIR"/bin/...`.
`../../../docs/turnend-guard.md` owns details.

The Stop-owned watcher hook runs every Stop, foregrounds `../../../bin/fm-watch-arm.sh` only when eligible, and uses exit-2 async reawakening as notification.
The model handles notifications but never routine re-arm.
Unless `config/supervision-host-off` opts the home out, the hook foregrounds the supervision host instead, which also runs Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md#engines) owns the verified engine facts.
Claude's PreToolUse seatbelt blocks directly, and its deny is honored only with empty stdout; `../../../docs/arm-pretool-check.md` owns that contract.

### Delegation guard

Claude delegation, scheduling, and worktree tools can create work without `state/<id>.meta`, making guards unable to count it.
`../../../bin/fm-subagent-pretool-check.sh` denies delegation-shaped tool names.
A primary should also keep an untracked home-local `permissions.deny` for known delegation tools so they disappear from the schema.
Never track it in project `.claude/settings.json`, which is Claude-only and propagates to worker copies where it would disarm legitimate delegation.
`../../../docs/subagent-guard.md` owns the contract, recommendation, `FM_ALLOW_SUBAGENT=1`, and applicability review.

On Claude 2.1.217 the tool presents as `Agent`, and both `Agent` and `Task` worked as deny keys in an A/B with nonsense control.
`permissions.allow` pre-approves rather than controls availability, so no closed positive allowlist exists.
