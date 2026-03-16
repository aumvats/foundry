# Foundry — Pipeline Architecture

> This document captures the full discussion between Aum (operator), Claude Cowork (strategist), and Claude Code (build engine) about how the factory pipeline should actually work. It's written so Cowork can pick up the thread and understand every decision that was made.

---

## 1. Cowork's Honest Assessment (The Starting Point)

Cowork reviewed the factory system end-to-end and raised critical concerns. Here's what was flagged:

### What's Actually Built

- **DemoSeed (~75% of spec):** Core works — 3 templates, 5 locales, 2 scenarios, virtualized grid with 1000+ rows, CSV/JSON export, confetti on first export, command palette. Auth scaffolded but disabled. No payment enforcement. Client-side generation works perfectly.

- **IsItUp (~70% of spec):** Landing page with live URL checker, dashboard with sparklines, site detail with Catmull-Rom response time charts, uptime timeline, email + SMS alerts, Stripe checkout, uptime badge. Two critical gaps: auth is not implemented (routes exposed publicly) and the monitoring cron runs once daily instead of every 1-5 minutes (Vercel Cron limitation).

- **The Factory itself:** Portfolio page, projects.json, build script, runner script, factory guide — all exist as files but have never been test-run as an end-to-end pipeline.

### Cowork's Concerns (All Valid)

**1. `claude -p` for full app builds (The Big Risk)**
The `build-project.sh` script runs `claude -p "giant prompt"` which sends a single prompt to Claude Code in non-interactive "print" mode. Building a full Next.js app from a spec is a 30-60 minute interactive session with dozens of tool calls, file reads, npm installs, and error corrections. The `-p` flag is designed for quick one-shot tasks, not multi-hour builds. It will likely time out, hit context limits, or produce incomplete builds.

**2. No error recovery in the pipeline**
The script uses `set -e` (exit on first error). If Claude Code's build fails halfway, the whole pipeline stops. There's no retry, no partial recovery, no "resume from where it left off."

**3. Vercel deploy without env vars**
Both projects need Supabase keys, SendGrid keys, Twilio keys, Stripe keys. The script deploys with `vercel --prod --yes` but doesn't set environment variables. Every new project will deploy but crash on first API call.

**4. Two Claude Code sessions can't run simultaneously**
Sequential builds mean the schedule drifts. If Cowork generates specs at 11:15 and the build starts at 11:30 but takes 45 minutes, the second project waits.

**5. No build verification**
The script doesn't run `npm run build` to check if the project actually compiles before pushing to GitHub and deploying to Vercel.

### Cowork's Recommendation

Cowork suggested a semi-automated approach: Cowork generates specs on crons (fully automated), but Claude Code runs interactively with the operator kicking it off once daily. The rationale: Claude Code is at its best when it can interact — read error messages, adjust, retry.

---

## 2. What We Discussed and Decided

### The `-p` flag misconception (resolved)

Cowork's concern about `claude -p` was valid for the OLD pipeline. But `claude --print` (same flag) combined with `--dangerously-skip-permissions` and `--max-budget-usd` actually gives the agent a multi-turn autonomous loop with full tool access. It's not "one prompt and done" — it runs until the agent decides it's finished or the budget runs out. The key is splitting the work into focused agents with clear scope.

### Semi-automated, not fully lights-off

We agreed: builds run automatically, but **deployment requires operator approval**. The operator (Aum) checks once daily, reviews what was built, provides corrections, and says "deploy" explicitly. Nothing broken goes live.

### Multi-agent pipeline (the big decision)

Instead of one monolithic `claude -p "build everything"` call, each project goes through **6 specialized agents** in sequence:

1. **Planner** — converts Cowork's spec into a technical implementation plan
2. **Builder** — executes the plan, builds the app
3. **QA** — thorough error checking, fixes bugs
4. **Designer** — UI polish pass (the Linear/Vercel quality bar)
5. **Optimizer** — performance, accessibility, branding
6. **Deployer** — git + GitHub + Vercel (only after operator approval)

### Master Orchestrator as an agent

The orchestrator itself is a well-defined agent — not just a dumb loop. It has rules, decision trees, and a "Daily Evolution" section where new rules are added over time as we learn what works and what breaks. The operator and orchestrator evolve the system daily.

### Project independence and failure handling

If Project 1 gets stuck at any stage, the orchestrator pauses it, logs exactly what went wrong, and moves to Project 2. Project 2 runs through the same full pipeline independently. When the operator checks in, they see which projects shipped, which are stuck, and what needs fixing.

---

## 3. The Architecture

### High-Level Flow

```
Cowork (Claude Desktop, scheduled tasks)     Orchestrator (system crontab, 12:03 PM IST)
  ├─ 11:04 — Generate idea 1, write spec       ├─ Reads projects.json for "queued"
  ├─ 11:18 — Generate idea 2, write spec       ├─ Reads state/ for in-progress projects
  └─ 11:29 — Build queue summary               │
                                                ├─ Project 1:
                                                │   ├─ Planner  → IMPLEMENTATION-PLAN.md
                                                │   ├─ Builder  → working Next.js app
                                                │   ├─ QA       → bugs fixed, QA-REPORT.md
                                                │   ├─ Designer → polished UI
                                                │   ├─ Optimizer → perf + branding
                                                │   └─ ⏸️ PAUSE → wait for operator
                                                │
                                                ├─ If stuck → pause, move to Project 2
                                                │   └─ Project 2: (same pipeline)
                                                │
                                                └─ Daily Report

Operator (Aum, once daily)
  ├─ Read daily report
  ├─ Fix stuck projects (add env vars, clarify specs)
  ├─ Review builds, provide corrections
  └─ Approve deploys → Deployer agent runs
```

### How Agents Are Spawned

Each agent runs as a separate Claude Code CLI invocation:

```bash
claude --print \
  --agent <agent-name> \
  --dangerously-skip-permissions \
  --max-budget-usd <cap> \
  --add-dir <project-directory> \
  --model claude-sonnet-4-6 \
  "<project-specific prompt>"
```

This gives each agent:
- Full tool access (Bash, Edit, Write, Read, Glob, Grep) in a multi-turn loop
- A focused system prompt defining its role
- A budget cap (prevents runaway costs)
- Access to the project directory

### Directory Structure (Target)

```
~/Code/exploratory/foundry/
├── agents/
│   ├── MASTER-ORCHESTRATOR.md    ← rules, decision trees, daily evolution log
│   ├── agents.json               ← machine-readable agent registry
│   ├── rules.json                ← evolved rules (auto-appended to prompts)
│   ├── planner.md                ← Planner agent definition
│   ├── builder.md                ← Builder agent definition
│   ├── qa.md                     ← QA agent definition
│   ├── designer.md               ← Designer agent definition
│   ├── optimizer.md              ← Optimizer agent definition
│   └── deployer.md               ← Deployer agent definition
├── state/
│   └── <project-id>-state.json   ← per-project pipeline state
├── lib/
│   ├── state.sh                  ← shell functions for state management
│   └── report.sh                 ← daily report generator
├── logs/
│   ├── cron.log                  ← crontab output
│   └── daily-report-YYYY-MM-DD.md
├── orchestrate.sh                ← main entry point (replaces run-factory.sh)
├── approve.sh                    ← operator helper for deploy approval
├── build-project.sh              ← kept as reference
├── run-factory.sh                ← kept as reference
├── projects.json
├── index.html
├── FOUNDRY-GUIDE.md
├── BUILD-ENGINE-STATUS.md
└── PIPELINE-ARCHITECTURE.md      ← this file
```

---

## 4. Agent Definitions

Each agent has a markdown file with: Role, Input/Output, Success Criteria, Failure Modes, and a Prompt Template that the orchestrator extracts and fills with project-specific context.

### Agent 1: Planner

| Field | Value |
|-------|-------|
| File | `agents/planner.md` |
| Input | `*-SPEC.md`, `CLAUDE-CODE-PROMPT.md` |
| Output | `IMPLEMENTATION-PLAN.md` in project directory |
| Model | sonnet |
| Budget | $2 |
| Tools | Read, Glob, Grep (read-only — no edits) |

**What it produces:** Tech stack decisions, exact directory tree, numbered build order, page-by-page component breakdown, API integration details, complete env var list, risk assessment.

**Success:** Plan exists, >2000 words, covers every route from spec's Section 6.

**Failure → Pause if:** Spec too vague — adds a "NEEDS CLARIFICATION" section with specific questions for the operator.

### Agent 2: Builder

| Field | Value |
|-------|-------|
| File | `agents/builder.md` |
| Input | `IMPLEMENTATION-PLAN.md`, `*-SPEC.md` |
| Output | Complete Next.js app, `npm run build` passes |
| Model | sonnet |
| Budget | $15 |
| Tools | All (Bash, Edit, Write, Read, Glob, Grep) |

**Execution rules:** Follow the implementation plan as a blueprint. Install all deps at once. Write complete files (no TODOs). Run `npm run build` when done. Do NOT do UI polish (Designer's job). Do NOT deploy (Deployer's job).

**Success:** Build passes, all routes exist, `.env.example` present.

**Failure → Retry once, then pause if:** Build fails after 3 fix rounds, or external API requires key not available.

### Agent 3: QA

| Field | Value |
|-------|-------|
| File | `agents/qa.md` |
| Input | Built app, spec, plan |
| Output | Bugs fixed in-place, `QA-REPORT.md` |
| Model | sonnet |
| Budget | $8 |
| Tools | All |

**QA checklist (in order):**
1. `npm run build` — fix until it passes
2. Lint check (if eslint configured)
3. Route check — every route from plan has a page file
4. Import check — no broken imports
5. Type check — `npx tsc --noEmit`
6. Env check — every env var in code is in `.env.example`
7. Error handling — no unhandled promise rejections
8. Empty states — no blank pages when data is empty
9. Console cleanup — remove `console.log` (keep `console.error`)
10. Dependency audit — no unused deps, no missing ones

**Success:** Build passes, QA report written.

**Failure → Pause if:** Architectural issues that require Builder-level changes.

### Agent 4: Designer

| Field | Value |
|-------|-------|
| File | `agents/designer.md` |
| Input | QA-passed app, Section 5 of spec |
| Output | Polished UI in-place, build still passes |
| Model | sonnet |
| Budget | $8 |
| Tools | All |

**Design checklist:**
1. Extract exact design tokens from Section 5 (hex colors, fonts, sizes, spacing, radii, animation timings)
2. Audit every color — replace anything off-brand
3. Audit typography — correct fonts, sizes, weights, line-heights
4. Audit spacing — matches spec's scale (usually 4px base)
5. Audit border radii — exact match
6. Audit animations — all under 300ms with ease-out
7. Loading states — skeleton screens, not spinners
8. Empty states — illustration + text + CTA
9. Error states — human-readable, retry buttons
10. Responsive — works at 390px width
11. Microinteractions — hover, focus, press feedback
12. Verify `npm run build` still passes

**Quality bar: Linear/Vercel-level.** If it doesn't look like a premium product, it's not done.

### Agent 5: Optimizer

| Field | Value |
|-------|-------|
| File | `agents/optimizer.md` |
| Input | Polished app, Section 9 of spec |
| Output | Optimized app in-place, build passes |
| Model | sonnet |
| Budget | $5 |
| Tools | All |

**Optimization checklist:**
1. Bundle analysis — replace heavy deps with lighter alternatives
2. Image optimization — use `next/image`, WebP/AVIF
3. Code splitting — `next/dynamic` for heavy components
4. Metadata — proper `<title>`, OG tags, favicon (NOT Next.js default)
5. Accessibility — alt text, aria-labels, color contrast, keyboard nav
6. Server components — `use client` only where needed
7. Security — no API keys in client bundles
8. SEO — robots.txt, heading hierarchy
9. Dead code — remove unused imports, commented-out blocks

### Agent 6: Deployer

| Field | Value |
|-------|-------|
| File | `agents/deployer.md` |
| Input | Finished app, project metadata from projects.json |
| Output | GitHub repo (public), Vercel deployment, updated projects.json |
| Model | sonnet |
| Budget | $3 |
| Tools | Bash, Read, Edit, Write |

**Only runs after operator explicitly approves deployment.**

**Steps:** git init → .gitignore → commit → `gh repo create --public` → `vercel --prod` → update projects.json → push factory repo.

**Failure → Pause if:** gh/vercel CLI not authenticated, missing env vars.

---

## 5. State Management

### Per-project state: `state/<project-id>-state.json`

```json
{
  "project_id": "example",
  "status": "in_progress",
  "current_step": "builder",
  "pipeline_started_at": "2026-03-17T12:03:00Z",
  "pipeline_updated_at": "2026-03-17T12:28:00Z",
  "steps": {
    "planner":   { "status": "complete", "retries": 0, "started_at": "...", "completed_at": "...", "budget_used_usd": 0.85, "output": {} },
    "builder":   { "status": "in_progress", "retries": 0, "started_at": "...", "completed_at": null, "budget_used_usd": null, "output": null },
    "qa":        { "status": "pending", "retries": 0 },
    "designer":  { "status": "pending", "retries": 0 },
    "optimizer": { "status": "pending", "retries": 0 },
    "deployer":  { "status": "pending", "retries": 0 }
  },
  "paused": false,
  "pause_reason": "",
  "operator_approved_deploy": false,
  "total_budget_used_usd": 0.85,
  "errors": []
}
```

**Key rule:** State is written by `orchestrate.sh` only — never by the agents themselves. This prevents state corruption.

**Valid status transitions:**
```
queued → planning → building → qa → designing → optimizing → ready_to_deploy → deploying → live
                                                                    ↑
Any step can branch to: paused (with reason) ────── operator fix ───┘
Any step can branch to: failed (after max retries)
```

---

## 6. The Orchestrator (`orchestrate.sh`)

### Core Logic

```
1. Read projects.json → find all "queued" projects
2. Read state/ → find any in-progress or paused-but-resumed projects
3. For each project:
   a. Load or create state file
   b. Determine next step (resume from where left off)
   c. If next step is "deployer" and not approved → set "ready_to_deploy", skip
   d. Extract prompt template from agents/<step>.md
   e. Fill placeholders (project dir, spec file, project name, etc.)
   f. Spawn: claude --print --agent <step> --dangerously-skip-permissions \
        --max-budget-usd <cap> --add-dir <project-dir> --model sonnet "<prompt>"
   g. Parse last line of output for JSON status
   h. On success → advance step, loop back to (b)
   i. On failure → retry once, then pause + move to next project
4. Generate daily report → logs/daily-report-YYYY-MM-DD.md
5. Exit
```

### Error Handling

| Scenario | Action |
|----------|--------|
| Agent exits 0 + JSON `"status": "complete"` | Advance to next step |
| Agent exits 0 + JSON `"status": "failed"` | Retry once, then pause |
| Agent exits non-zero (crash) | Log stderr, retry once, then pause |
| Agent produces no JSON output | Check for expected output files, infer result |
| Agent runs for 45+ min with no progress | Kill process, pause with "timeout" |
| Project paused | Log reason clearly, move to next project |

### Budget Per Project

| Agent | Cap |
|-------|-----|
| Planner | $2 |
| Builder | $15 |
| QA | $8 |
| Designer | $8 |
| Optimizer | $5 |
| Deployer | $3 |
| **Total max** | **$41** |

---

## 7. Operator Daily Workflow

```bash
# 1. Check what happened
cat ~/Code/exploratory/foundry/logs/daily-report-$(date +%Y-%m-%d).md

# 2. If something is stuck
cat state/<project-id>-state.json | jq '{status, current_step, pause_reason}'

# 3. Fix the issue (add env vars, clarify spec, etc.)

# 4. Resume a paused project
jq '.paused = false | .status = "in_progress"' state/<id>-state.json > tmp && mv tmp state/<id>-state.json

# 5. Approve a deploy
./approve.sh <project-id>

# 6. Re-run (or wait for tomorrow's cron)
./orchestrate.sh
```

### Daily Report Format

```markdown
## Factory Run — 2026-03-17

### Completed
- ✅ DemoSeed — built, polished, ready to deploy ($32.50 spent)

### Paused
- ⏸️ IsItUp — stuck at QA (auth not implemented, spec requires Supabase auth)
  → Needs: Supabase project URL + anon key in .env

### Waiting for Approval
- 🟡 DemoSeed — ready to deploy. Run: ./approve.sh demoseed

### Budget
- Total spent today: $32.50
- DemoSeed: $32.50 (planner: $1.20, builder: $14.80, qa: $6.50, designer: $5.80, optimizer: $4.20)
- IsItUp: $0.00 (paused before build)
```

---

## 8. Daily Evolution

This is what makes the system get better over time instead of repeating the same failures.

### How It Works

1. The orchestrator runs, produces a daily report
2. The operator reads the report, identifies patterns
3. New rules are added to `MASTER-ORCHESTRATOR.md` under the "Rules Log" section
4. Machine-enforceable rules also go into `agents/rules.json` — the orchestrator reads this file and auto-appends triggered rules to agent prompts before spawning

### Rule Format

```markdown
### Rule: [short name]
- **Added:** [date]
- **Trigger:** [when this rule applies]
- **Action:** [what the orchestrator or agent should do]
- **Why:** [what happened that prompted this rule]
- **Implemented in:** [orchestrate.sh / agents/<name>.md / rules.json]
```

### `agents/rules.json` (Machine-Readable Rules)

```json
[
  {
    "id": "rule-001",
    "added": "2026-03-18",
    "trigger": "builder_agent",
    "append_to_prompt": "Use @import 'tailwindcss' not @tailwind directives. Tailwind v4 uses CSS-first config, not tailwind.config.js.",
    "active": true
  }
]
```

The orchestrator reads this file before spawning each agent and appends any matching rules to the prompt. This means the system learns without needing to edit the core agent definitions.

### What Cowork Can Evolve

Cowork can propose new rules based on patterns it sees in specs that consistently cause build failures. For example:
- "Specs that reference more than 3 external APIs should flag the Builder for extra budget"
- "Auth specs should always include the exact Supabase project URL"
- "Section 5 should always include a dark-mode-only or light-mode-only flag"

These go into the Rules Log and get implemented in the next daily cycle.

---

## 9. What Needs to Be Built

### Build Order

| # | File | Description |
|---|------|-------------|
| 1 | `lib/state.sh` | State management shell functions (foundation) |
| 2 | `agents/planner.md` | Planner agent definition with prompt template |
| 3 | `agents/builder.md` | Builder agent definition (most complex) |
| 4 | `agents/qa.md` | QA agent definition with checklist |
| 5 | `agents/designer.md` | Designer agent definition |
| 6 | `agents/optimizer.md` | Optimizer agent definition |
| 7 | `agents/deployer.md` | Deployer agent definition |
| 8 | `agents/agents.json` | Machine-readable agent registry |
| 9 | `agents/MASTER-ORCHESTRATOR.md` | Rewrite with state machine + decision trees |
| 10 | `orchestrate.sh` | Main orchestrator script |
| 11 | `lib/report.sh` | Daily report generator |
| 12 | `approve.sh` | Operator deploy approval helper |
| 13 | `BUILD-ENGINE-STATUS.md` | Update for new architecture |
| 14 | System crontab | Point to `orchestrate.sh` |

### Testing Plan

1. **Dry run:** Queue a project, run `./orchestrate.sh` manually, verify each agent spawns correctly
2. **Agent isolation:** Test each agent standalone via `claude --print --agent <name> ...`
3. **Failure handling:** Break a spec intentionally, verify orchestrator pauses and moves on
4. **Resume:** Pause mid-pipeline, re-run, verify it picks up from the right step
5. **Deploy approval:** Run `./approve.sh`, verify deployer runs on next orchestration

---

## 10. For Cowork: What This Means for Spec Writing

The multi-agent pipeline places specific demands on spec quality:

1. **Section 5 (UI/UX) must have exact values** — hex colors, font sizes in px, spacing in px, border radii in px, animation durations in ms. The Designer agent matches these literally. Vague specs ("use a nice blue") will cause pauses.

2. **Section 6 (Routes) must be complete** — the Planner counts routes and builds a page-by-page plan. Missing routes = missing pages.

3. **Section 9 (Technical Constraints) matters** — the Optimizer reads this. Include performance targets, data handling rules (client-side vs server), security requirements.

4. **API details must be accurate** — the Builder will try to call these APIs. Include: exact endpoint URLs, auth method (API key? OAuth? None?), rate limits, whether the API is actually free.

5. **Auth requirements should be explicit** — "use Supabase auth with Google OAuth" is good. "add authentication" is not.

The better the spec, the fewer pauses and the faster the pipeline runs. A well-written spec can go from queued to ready-to-deploy in a single daily run (~$41 max spend).
