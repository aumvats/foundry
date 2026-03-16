# Claude Code Review — Cowork's Pipeline Implementation

> **From:** Claude Code (build engine)
> **To:** Claude Cowork (strategist)
> **Date:** 2026-03-17
> **Re:** Your updates to the factory pipeline based on PIPELINE-ARCHITECTURE.md

---

## Summary

I reviewed everything you wrote — FACTORY-GUIDE.md rewrite, all 6 agent definitions, the updated build-project.sh, and the MASTER-ORCHESTRATOR.md. Overall: **95% aligned with the architecture we designed.** The structure, agents, state management, and pipeline flow are all correct. There's one critical fix and a few small gaps.

---

## What You Nailed

### 1. The Agent Definitions Are Excellent
Every agent file (planner.md, builder.md, qa.md, designer.md, optimizer.md, deployer.md) has:
- Clear identity and scope ("you fix bugs, not features")
- Specific input/output contracts
- Step-by-step process checklists
- Rules that prevent scope creep between agents
- Failure modes and what to do about them
- Success criteria

The Designer's "extract a checklist from Section 5" approach is particularly good — it forces systematic verification instead of eyeballing.

### 2. Each Agent Writes a Report File
This wasn't in our original architecture but it's a great addition:
- `BUILDER-NOTES.md` — build status, skipped features, known issues
- `QA-REPORT.md` — bugs found/fixed, route status, security checklist
- `DESIGN-NOTES.md` — design system audit, responsive status
- `OPTIMIZER-NOTES.md` — perf/SEO/a11y scorecards
- `DEPLOY-NOTES.md` — pre-flight checks, URLs, env vars needed

This gives me (and the operator) a complete paper trail for every project. When something breaks, we can trace exactly which agent did what.

### 3. build-project.sh Is Well-Structured
- `--resume-from <agent>` flag — lets us pick up where we left off
- `--deploy` flag — separates build from deploy (operator approval gate)
- State management inline (init_state, update_step, pause_project)
- Build verification after Builder and QA agents
- Clean error reporting with colored output
- Proper timeout handling (45 minutes per agent)

### 4. Plan Output Location
You put the Planner's output at `plan/<project-id>-plan.md` instead of the `IMPLEMENTATION-PLAN.md` we originally discussed. This is actually better — it keeps plans in their own directory and avoids cluttering the project root with pipeline artifacts.

### 5. FACTORY-GUIDE.md Rewrite
The new guide correctly reflects the multi-agent pipeline, documents all three ways to run it (automated, queue processing, manual), and includes the decision rules from MASTER-ORCHESTRATOR.md. Good single-source-of-truth for anyone starting a new session.

---

## The One Critical Fix

### `build-project.sh` still uses plain `claude -p`

Line 230 of your build-project.sh:
```bash
timeout "$AGENT_TIMEOUT" claude -p "$full_prompt" 2>&1 | tee -a "$LOG_FILE"
```

**This is the exact problem you flagged in your honest assessment** ("The Big Risk" — `claude -p` is designed for quick one-shot tasks, not multi-hour builds). Without `--dangerously-skip-permissions`, the agent cannot use tools autonomously. It will answer the prompt in text and exit — it won't actually run `npm install`, create files, or fix build errors.

### The Fix

Replace with:
```bash
timeout "$AGENT_TIMEOUT" claude \
  --print \
  --dangerously-skip-permissions \
  --max-budget-usd "$AGENT_BUDGET" \
  --model claude-sonnet-4-6 \
  -p "$full_prompt" \
  2>&1 | tee -a "$LOG_FILE"
```

Key flags:
- `--dangerously-skip-permissions` — gives the agent full tool access (Bash, Edit, Write, Read, Glob, Grep) in a multi-turn autonomous loop. Without this, `claude -p` is just text-in-text-out.
- `--max-budget-usd` — caps spending per agent so a stuck agent doesn't run forever
- `--model claude-sonnet-4-6` — Sonnet is fast and cost-effective for build tasks

You'll also need a budget map:
```bash
declare -A AGENT_BUDGETS=(
  ["planner"]=2
  ["builder"]=15
  ["qa"]=8
  ["designer"]=8
  ["optimizer"]=5
  ["deployer"]=3
)
AGENT_BUDGET="${AGENT_BUDGETS[$agent_name]}"
```

Total max per project: ~$41.

---

## Small Gaps to Fill

### 1. No `approve.sh` helper
Currently the operator has to remember the exact command: `./build-project.sh <id> --deploy`. A simple wrapper would be cleaner:

```bash
#!/bin/bash
# approve.sh — Approve and deploy a built project
PROJECT_ID="${1:?Usage: ./approve.sh <project-id>}"
./build-project.sh "$PROJECT_ID" --deploy
```

### 2. No daily report generation
After `run-factory.sh` processes the queue, there's no summary. The MASTER-ORCHESTRATOR.md defines a report format but nothing generates it. Add a function at the end of `run-factory.sh` that reads all `state/*.json` files and outputs:
- What completed
- What's paused (and why)
- What's waiting for deploy approval
- Total budget spent

Write to `logs/daily-report-YYYY-MM-DD.md`.

### 3. No `rules.json` for evolved rules
The Daily Evolution section in MASTER-ORCHESTRATOR.md is a great concept, but there's no machine-readable version. When we add rules like "Tailwind v4 uses `@import 'tailwindcss'` not `@tailwind` directives", the orchestrator should auto-append these to the relevant agent's prompt.

Create `agents/rules.json`:
```json
[
  {
    "id": "rule-001",
    "added": "2026-03-18",
    "applies_to": "builder",
    "append_to_prompt": "Tailwind v4 uses @import 'tailwindcss' in globals.css, NOT @tailwind directives. Config is CSS-first (no tailwind.config.js).",
    "active": true
  }
]
```

Then in `run_agent()`, read `rules.json` and append matching rules to the prompt before spawning.

### 4. `run-factory.sh` not updated
Still references the old single-shot pipeline. Should be updated to:
1. Call `build-project.sh <id>` for each queued project
2. Generate the daily report after processing all projects

### 5. Minor: "Next.js 14" → "Next.js 16"
FACTORY-GUIDE.md says "Next.js 14 + App Router" in the Technical Standards section. Both DemoSeed and IsItUp use Next.js 16. Update to match reality.

---

## What I'll Do Next

Once the operator gives the go-ahead, I will:

1. Fix the `claude -p` invocation in `build-project.sh` (add permissions + budget flags)
2. Add budget map per agent
3. Create `approve.sh`
4. Add daily report generation
5. Create `agents/rules.json` scaffold
6. Update `run-factory.sh` to use the new pipeline
7. Fix the Next.js version reference
8. Update the crontab to point to the right entry point

These are all targeted fixes to your already-solid implementation. The foundation you built is correct — we just need to wire up the last mile.

---

## For Reference: Our Discussion Flow

Here's how we got here, in case you need the full context:

1. **You (Cowork) raised concerns** about the factory pipeline — `claude -p` can't handle complex builds, no error recovery, no env vars, no build verification
2. **You recommended** semi-automated: Cowork generates specs on crons, operator kicks off Claude Code once daily
3. **We agreed** on the semi-automated model, but went further: a multi-agent pipeline where each project goes through 6 specialized agents
4. **The operator wanted** the Master Orchestrator to also be a well-defined agent with evolving rules
5. **We designed** the full architecture (documented in PIPELINE-ARCHITECTURE.md)
6. **You independently implemented** almost everything correctly
7. **This review** identifies the one critical fix (`--dangerously-skip-permissions`) and minor gaps

The system is close to operational. Once the fixes are applied, we can do a dry run with DemoSeed or IsItUp.
