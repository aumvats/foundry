# Build Engine — Current Status

> Last updated: 2026-03-16

## Session Summary

Claude Code (build engine) was initialized and reviewed the full factory system:
- Read `FOUNDRY-GUIDE.md` — understood the two-pass build process, quality bar, deploy pipeline
- Read `projects.json` — checked for queued projects
- Read `build-project.sh` and `run-factory.sh` — confirmed both scripts are operational

## Queue Status

**No projects are queued.** Both existing projects are in `built` status:

| Project   | Status | Repo | Live URL |
|-----------|--------|------|----------|
| DemoSeed  | built  | —    | —        |
| IsItUp    | built  | —    | —        |

Neither has been deployed to GitHub or Vercel yet. They have code locally but no `repo`, `live_url`, or `vercel_project` set.

## Cron Job Active

A system crontab runs the build pipeline daily:
- **Schedule:** Every day at 12:03 PM IST
- **Command:** `cd ~/Code/exploratory/foundry && ./run-factory.sh --build-only >> logs/cron.log 2>&1`
- **Action:** Checks `projects.json` for any project with `"status": "queued"` and runs `build-project.sh` for each (which launches Claude Code CLI via `claude -p`)
- **Scope:** Persistent system crontab — survives session exits and reboots. Requires machine to be awake at 12pm.
- **Logs:** `~/Code/exploratory/foundry/logs/cron.log`

## How to Queue a New Build

For Cowork (or anyone) to trigger a build:

1. Create the project directory at `~/Code/exploratory/<project-id>/`
2. Add the spec file: `<PROJECT-ID>-SPEC.md`
3. Add the build prompt: `CLAUDE-CODE-PROMPT.md`
4. Add an entry to `projects.json` under `"projects"` with `"status": "queued"`
5. The cron will pick it up within the hour, or you can manually invoke Claude Code

## What the Build Engine Does

For each queued project:
1. Reads the full spec (`*-SPEC.md`) and build instructions (`CLAUDE-CODE-PROMPT.md`)
2. **Pass 1:** Builds the complete v1 MVP — all pages, features, data flows
3. **Pass 2:** UI polish — matches Section 5 of spec exactly (colors, fonts, spacing, radii, animations)
4. Verifies `npm run build` passes
5. Deploys: `git init` → GitHub (public) → Vercel (`--prod`)
6. Updates `projects.json` with repo URL, live URL, status `"live"`
7. Pushes the factory repo to update the portfolio page

## Notes for Cowork

- The build engine is ready and waiting. Just queue specs.
- DemoSeed and IsItUp exist as local builds but haven't been deployed. If you want them live, set their status to `"queued"` in `projects.json` (or ask the user to deploy them manually).
- The `run-factory.sh --build-only` script can also be run manually at any time to process the queue.
