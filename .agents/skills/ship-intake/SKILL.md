---
name: ship-intake
description: Load at every ship or scout intake before writing the brief, to resolve delivery mode, yolo posture, branch prefix, base branch, and the overlap and serialization judgment.
user-invocable: false
metadata:
  internal: true
---

# Ship intake

`AGENTS.md` section 7 keeps the always-loaded safety facts inline: mode and `yolo` are resolved at intake and passed explicitly because each command refuses to guess, and a project's declared machine capacity bounds dispatch.
This skill owns the rest of the intake resolution.

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <project>`, and pass it explicitly to the brief, ship spawn, and scout promotion as `--branch-prefix` (default `fm/` needs no flag).
When the work must start from and target a branch other than the project's default, such as a named feature or release branch, pass it to the ship or scout brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Write the task-specific brief under `crewmate-briefs` before spawning.
When `config/task-types.json` is present, list types with `bin/fm-brief.sh --list-types` and, when a type fits the task, pass `--type <name>` on the brief so the catalog supplies the type's fields; a task that matches no type keeps an untyped brief.
A printed `type-profile:` model or effort only fills an axis that `AGENTS.md` section 4's routing precedence left unresolved; never mix it into a profile a captain override, matched rule or resolver profile, or configured default already resolved (`docs/configuration.md` owns the catalog).
