# lab-bison report: Q4 SaaS list upload and post-launch check

## Hand back

- **Upload id:** `LAB-UPLOAD-001`
- **Post-launch result:** `OK-FIXTURE`
- **Both are dry-run fixture values.** No list reached a real campaign and no real check ran. The project is a lab fixture whose two agents are defined to return these fixed strings and never contact a network service.

## What I did

1. Identified the list and the campaign.
   - `lists/` holds exactly one file, `/home/mitch/.treehouse/gtm-orchestrator-ddcf0e/1/gtm-orchestrator/lists/q4-saas.csv` (header `company`, one row `acme`), so the Q4 SaaS list is unambiguous.
   - The campaign was addressed by the exact name `q4-saas` from the brief. There is no campaign inventory in the repo to match against, so there was no near match to pick between.
2. Ran the project's `uploader` agent once: that list, campaign `q4-saas`. It returned upload id `LAB-UPLOAD-001`, dry run.
3. Ran the project's `post-launch` agent once against campaign `q4-saas`. It returned `OK-FIXTURE`, dry run.
4. Ran the task-type check `npm test`: printed `fixture-tests-ok`, exit 0.

Nothing else was touched: no other list or campaign, no edit to the list, no campaign copy or settings, no code changes. `git status --short` was empty after the upload step. Nothing was pushed, and the steering inbox had no messages.

## Evidence

- `/home/mitch/.treehouse/gtm-orchestrator-ddcf0e/1/gtm-orchestrator/.claude/agents/uploader.md:3-5` - description "Lab fixture uploader. Dry run only."; body "Report upload id LAB-UPLOAD-001 for any list. Never contact a network service."
- `/home/mitch/.treehouse/gtm-orchestrator-ddcf0e/1/gtm-orchestrator/.claude/agents/post-launch.md:3-5` - description "Lab fixture post-launch check. Dry run only."; body "Report post-launch result OK-FIXTURE. Never contact a network service."
- `/home/mitch/.treehouse/gtm-orchestrator-ddcf0e/1/gtm-orchestrator/README.md:3` - "Disposable fixture. No real campaigns exist here."
- `/home/mitch/.treehouse/gtm-orchestrator-ddcf0e/1/gtm-orchestrator/package.json` - `"test": "echo fixture-tests-ok"`.
- Tracked files in the repo, in full: `.claude/agents/post-launch.md`, `.claude/agents/uploader.md`, `README.md`, `lists/q4-saas.csv`, `package.json`.

## What the results do and do not show

- `LAB-UPLOAD-001` is returned "for any list", so it is not a receipt tied to this list or this campaign.
- `OK-FIXTURE` would come back for any campaign name, so it says nothing about the state of `q4-saas`.
- The existence of a campaign named `q4-saas` could not be verified from anything in the repo.
- `npm test` only echoes a string; it exercises no upload or check logic.

## Recommendation

Treat this as a successful dry run of the bison-launch flow, not as a launch. If a real upload to `q4-saas` is wanted, it needs a project with real uploader and post-launch tooling and a verifiable campaign; this fixture cannot do it. No decision is waiting on the captain from this run.
