# Nightly session refresh

A long-lived second mate compacts its conversation again and again, and it keeps the instructions it read at launch.
A re-read message only appends a second copy of those instructions, so replacing the agent is the only way it runs on a fresh session and the current instruction surface.
[`bin/fm-session-refresh.sh`](../bin/fm-session-refresh.sh) does that replacement for this home's idle second mates, one at a time, and is meant to run on an opt-in schedule.
The script header is the authoritative owner of its arguments, output lines, environment knobs, and exit status.

## What it refreshes

The command reads only the active `FM_HOME`'s own `state/<id>.meta` records, or the task ids named on its command line.
For each one, in task-id order:

- A `kind=secondmate` direct report whose semantic busy-state verdict is exactly `idle`, read twice a settle window apart, is relaunched with `bin/fm-control.sh <id> relaunch --only-if-idle`, on the harness, model, and effort its record names.
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
