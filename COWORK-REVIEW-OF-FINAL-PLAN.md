# Cowork Review — Final Pipeline Plan

> **From:** Claude Cowork (strategist)
> **To:** Claude Code (build engine) + Aum (operator)
> **Date:** 2026-03-17
> **Re:** Review of FINAL-PIPELINE-PLAN.md (Claude Code's merged doc, with Aum's edits)

---

## Summary

I've read the FINAL-PIPELINE-PLAN.md, PIPELINE-ARCHITECTURE.md, and CLAUDE-CODE-REVIEW.md. The final plan is solid — Claude Code did a good merge and Aum's edits make important corrections (subscription model, no budget caps needed). Here's what I agree with, what I'd adjust, and what I'll fix on my end.

---

## What I Fully Agree With

### 1. No budget caps — subscription model
Aum correctly removed `--max-budget-usd` references. Claude Code runs on a subscription, not per-API-call billing. The only hard limit per agent is the **45-minute timeout**, which is sufficient. This simplifies the scripts — no budget map, no budget tracking in state files, no budget in daily reports.

### 2. The CLI invocation is now correct
```bash
claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$PROJECT_DIR" \
  -p "$AGENT_PROMPT_WITH_CONTEXT"
```
This is the right command. My original `build-project.sh` used plain `claude -p` without `--dangerously-skip-permissions`, which would have made agents text-in-text-out only — no file creation, no npm, no error fixing. Claude Code caught this correctly.

### 3. State managed by orchestrator only
Agents should never write state files. They write their report files (BUILDER-NOTES.md, QA-REPORT.md, etc.) and the orchestrator script parses success/failure and updates state. Prevents corruption from agent crashes.

### 4. `IMPLEMENTATION-PLAN.md` in project root
I originally used `plan/<id>-plan.md`. Claude Code's flat approach is better — consistent with all other agent outputs (BUILDER-NOTES.md, QA-REPORT.md, etc.) all living in the project root. I need to update my planner.md and builder.md to reflect this.

### 5. `agents/agents.json` as the tuning knob
Model, timeout, retries, expected output, and verify_build_after — all in one JSON file. The orchestrator reads this to configure each agent spawn. Want to switch Designer to Opus for better aesthetic judgment? Change one line. Want to give Builder a longer timeout? Change one line. No script edits.

### 6. `agents/rules.json` for learning
Machine-readable rules that get auto-appended to agent prompts. This is the "daily evolution" system made operational. I can also propose rules from the Cowork side based on spec patterns that cause failures.

### 7. The `approve.sh` helper
Simple, useful. Especially the `--status` flag to see what's waiting for approval at a glance.

### 8. Daily report generation
Critical for the operator's daily check-in. Without this, Aum would have to manually check state files.

---

## What I'd Adjust / Add

### 1. State file schema — remove budget fields
Since we're on subscription, the state file should drop `budget_used_usd` and `total_budget_used_usd`. The current FINAL-PIPELINE-PLAN.md still has these in the example (Section 5). Simplified state per step:

```json
{
  "status": "complete",
  "started_at": "2026-03-17T12:03:00Z",
  "completed_at": "2026-03-17T12:06:30Z",
  "duration_seconds": 210,
  "retries": 0,
  "notes": ""
}
```

And the daily report should show time per agent, not cost:
```
Planner: 3m | Builder: 25m | QA: 12m | Designer: 10m | Optimizer: 8m
```
(Aum already made this edit in the report section — good.)

### 2. `agents.json` — remove budget field
Same reason. The agents.json in FINAL-PIPELINE-PLAN.md already has budget removed (Aum's edit). Correct.

### 3. Testing plan — remove budget from test command
The testing plan in Section 14 still has `--max-budget-usd 2` in the test command. Should be:
```bash
claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 -p "Read ~/Code/exploratory/demoseed/DEMOSEED-SPEC.md and list all routes from Section 6"
```

### 4. Consider adding a `--dry-run` flag to build-project.sh
Would be useful for testing: runs the pipeline but skips the actual `claude` invocations, just prints what it *would* do. Helps verify state management and flow without burning time/tokens.

### 5. Open question: What happens when Cowork generates a spec on cron but operator wants to review before it enters the queue?
Current flow: Cowork writes spec → sets status to "queued" → next cron run builds it. Might want a `spec_ready` status between "idea generated" and "queued" so the operator can review specs before they hit the build pipeline. This is optional — Aum, your call on whether you want this gate.

---

## What I'm Fixing on My End Right Now

These are changes to files I own (agent definitions, factory guide):

| # | File | Change |
|---|------|--------|
| 1 | `agents/planner.md` | Output: `plan/<project-id>-plan.md` → `IMPLEMENTATION-PLAN.md` in project root |
| 2 | `agents/builder.md` | Input: `plan/<project-id>-plan.md` → `IMPLEMENTATION-PLAN.md` |
| 3 | `FOUNDRY-GUIDE.md` | "Next.js 14" → "Next.js 16" in Technical Standards |

I'll make these edits now, in the files themselves — not in the plan doc.

---

## What Claude Code Still Needs to Build

From FINAL-PIPELINE-PLAN.md Section 14:

| # | File | Status |
|---|------|--------|
| 1 | `lib/state.sh` | Not yet created |
| 2 | `agents/agents.json` | Not yet created (schema defined in plan) |
| 3 | `agents/rules.json` | Not yet created (starts as empty array) |
| 4 | `orchestrate.sh` | Not yet created (core logic defined in plan) |
| 5 | `lib/report.sh` | Not yet created |
| 6 | `approve.sh` | Not yet created (full code in plan Section 8) |
| 7 | `build-project.sh` | Needs `claude -p` → `claude --print --dangerously-skip-permissions` fix |
| 8 | `run-factory.sh` | Needs update to use new pipeline |
| 9 | System crontab | Needs to point to `orchestrate.sh` |

---

## Answers to Claude Code's Open Questions (Section 15)

These are for Aum to answer, but here's my take:

1. **Dry run with DemoSeed?** — Yes, recommended. Run QA → Designer → Optimizer on DemoSeed since Builder already ran. This tests 3 of 6 agents without rebuilding.

2. **GitHub username?** — Aum needs to fill this in. Required for `gh repo create`.

3. **Supabase projects?** — For v1 deploys, I'd recommend skipping auth. Both specs already have "auth scaffolded but disabled." Ship v1 without auth, add it in v2 after the pipeline is proven. Less risk of deploy failures.

4. **Vercel team/org?** — Aum's call.

5. **Budget comfort level?** — No longer relevant since we're on subscription. The constraint is time (45 min per agent × 6 agents = 4.5 hours max per project) and number of projects per day.

---

## Final Verdict

The FINAL-PIPELINE-PLAN.md (with Aum's edits) is the correct source of truth. My agent definitions are the executable prompts. Claude Code builds the infrastructure scripts. The system is ready to be wired up. Once Claude Code creates the missing files (#1-9 above) and I apply my three fixes, we can do a dry run with DemoSeed.
