# Nightly session refresh and daily stow

A long-lived second mate compacts its conversation again and again, and it keeps the instructions it read at launch.
A re-read message only appends a second copy of those instructions, so replacing the agent is the only way it runs on a fresh session and the current instruction surface.
[`bin/fm-session-refresh.sh`](../bin/fm-session-refresh.sh) does that replacement for this home's idle second mates, one at a time, and is meant to run on an opt-in schedule.
The script header is the authoritative owner of its arguments, output lines, environment knobs, and exit status.

## What it refreshes

The command reads only the active `FM_HOME`'s own `state/<id>.meta` records, or the task ids named on its command line.
For each one, in task-id order:

- A `kind=secondmate` direct report whose semantic busy-state verdict is exactly `idle`, read twice a settle window apart, is relaunched with `bin/fm-control.sh <id> relaunch --only-if-idle`, which re-resolves its configured harness, model, and effort under the [control-plane profile rules](agent-control.md#transactional-relaunch).
- One whose turn starts after those reads but before its agent is stopped is left running: `--only-if-idle` refuses instead of interrupting it, and it is reported as `skipped (became busy, next night)`.
- A busy one waits for the next run.
- One whose verdict is `unknown` also waits for the next run, because unknown is never idle under the [busy-state contract](../bin/fm-busy-lib.sh).
- A ship or scout task is skipped: it is task-bound work in progress, its replacement would resume its instructions rather than settle idle, and its relaunch would append a progress note to those instructions every night.
- A remotely placed second mate, and one on a runtime backend that cannot prove an agent stopped, are skipped because the control plane refuses them.
- A Pi or pi-signed second mate on Herdr is skipped as `skipped (herdr resumes the Pi session, not a fresh one)`: its relaunch resumes the Pi session the pane already reports ([agent-control.md](agent-control.md#transactional-relaunch) step 6), so it would never reach a fresh session.

After each relaunch the replacement must read idle again, twice across the same settle window, before the next second mate is touched, so a slow host never has two launches in flight.
The first failure - a refused or failed relaunch, or a replacement that does not come back idle in time - stops the run, leaves every later second mate as it was, and exits non-zero with the control plane's own report.
The control plane owns the relaunch checkpoint, journal, and rollback, and a second mate's charter is never rewritten; see [agent-control.md](agent-control.md#transactional-relaunch).

## Why idle is read twice

A Claude turn that a blocking Stop hook continues has already recorded idle, and it reads busy again only at its next tool call.
The second read, after the settle window in the script header, catches such a turn as soon as it calls a tool.
A continued turn that only writes text until its next Stop still reads idle on both reads; that is a limit of the busy-state sources, not of this command.

## Known gap: Codex

The busy-state contract has no verified Codex idle source, so a Codex second mate always reads `unknown`.
This command therefore never refreshes a Codex second mate, and reports it as `idle state unknown, next night`.
A verified Codex source in `bin/fm-busy-lib.sh` would lift that limit without any change here.

## Scheduling it

Nothing schedules the refresh by default.
[`examples/session-refresh/`](examples/session-refresh/) holds an opt-in systemd user service and timer pair; copy both into `~/.config/systemd/user/`, replace the placeholder paths, and enable the timer.
Run it after any scheduled memory pass, so each second mate has written down what it holds before its conversation is replaced.
A failed run leaves the unit failed in `systemctl --user status fm-session-refresh.service`, and the stopped second mate is reconciled by the ordinary recovery path.
Any other scheduler works the same way, as long as it sets `FM_HOME` and a `PATH` that reaches the backend and harness tools an interactive session uses.

## Daily stow before refresh

The optional `fm-daily-stow.service` and `fm-daily-stow.timer` in [the same examples directory](examples/session-refresh/) schedule a request for a main-session memory pass at 01:30 America/Toronto daily.
Select the main operational home in the service: its existing [stow cascade](../.agents/skills/stow/SKILL.md#automatic-cascade-to-secondmates) reaches registered secondmate homes without separate timers.
The trigger uses the [durable inbox](../bin/fm-inbox.sh) check path, so the session handles the instruction at a normal checkpoint after current work.
It never sends terminal keys, interrupts a turn, or starts a replacement worker.
The [script header](../bin/fm-daily-stow.sh) owns eligibility checks, the 20-hour primary-pass guard, retry semantics, and exit status.
The primary records its memory pass through the cascade's `--record-pass` option; that record does not certify secondmate completion or reset safety.
The recipient checks the note's intended home and the primary-pass guard before acting; reading the note in that home's inbox is sufficient evidence of a live session.
A later session in the same home may process a delayed note; a lock holder the host cannot classify may still receive one.
A missing or positively stale main lock, away or quiet posture, or a recent primary pass produces a logged skip rather than a queued instruction.
The 01:30 occurrence exists on the spring daylight-saving transition, and the persistent timer catches up after downtime; a catch-up can run after the 03:00 refresh.
Queueing at 01:30 normally leaves 90 minutes before refresh, but does not guarantee completion when main or a secondmate remains busy.

To install after reviewing the placeholder paths, copy the companion units alongside the refresh units:

```sh
mkdir -p ~/.config/systemd/user
cp docs/examples/session-refresh/fm-daily-stow.service docs/examples/session-refresh/fm-daily-stow.timer ~/.config/systemd/user/
# Edit FM_HOME and ExecStart in ~/.config/systemd/user/fm-daily-stow.service.
systemctl --user daemon-reload
systemctl --user enable --now fm-daily-stow.timer
systemctl --user list-timers fm-daily-stow.timer
journalctl --user -u fm-daily-stow.service
```

Keep the refresh schedule at 03:00 America/Toronto when using this companion on a host whose local timezone differs.
Pre-compaction or pre-reset delivery is a follow-up; this companion implements only the daily occurrence.
Verify the guards and delivery with `bin/fm-test-run.sh tests/fm-daily-stow.test.sh tests/fm-stow-cascade.test.sh tests/fm-inbox.test.sh`.
