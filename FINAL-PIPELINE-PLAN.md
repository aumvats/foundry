# Foundry — Final Pipeline Plan

> **Status:** Merged plan from Claude Code (architecture) + Claude Cowork (agent definitions + scripts)
> **Date:** 2026-03-17
> **Purpose:** Single source of truth for building and running the factory pipeline

---

## 1. How We Got Here

### The Problem
The factory had a working portfolio page, two built projects (DemoSeed, IsItUp), and shell scripts that used `claude -p` in single-shot mode. Cowork flagged 5 critical issues:

1. `claude -p` can't handle complex multi-file builds (it was single-shot, no tool access)
2. No error recovery — `set -e` kills the pipeline on first failure
3. Vercel deploys without env vars = apps crash on first API call
4. Sequential builds with no parallelism or independence
5. No build verification before deploying

### The Solution
We designed a multi-agent pipeline where each project goes through 6 specialized agents. Key insight from Claude Code: **`claude --print` with `--dangerously-skip-permissions` gives full multi-turn autonomous tool access** — the agent runs a complete loop (read files, write code, run bash, fix errors) until it's done or hits the timeout. This solves issue #1 entirely. All agents run under the Claude Code subscription — no per-API-call costs.

### What Each Side Contributed

**Claude Code designed:**
- The multi-agent architecture and pipeline flow
- `rules.json` for machine-readable evolved rules
- State management owned by orchestrator (not agents) to prevent corruption
- The `orchestrate.sh` + `approve.sh` script approach
- The correct CLI invocation with `--dangerously-skip-permissions`

**Claude Cowork built:**
- All 6 agent definition files with detailed prompts, checklists, and output formats
- Each agent writes a report file (BUILDER-NOTES.md, QA-REPORT.md, etc.) — audit trail
- Updated `build-project.sh` with `--resume-from` and `--deploy` flags
- Updated `FOUNDRY-GUIDE.md` with multi-agent documentation
- The `plan/` subdirectory concept for Planner output

**Both independently arrived at:**
- The same 6-agent sequence (Planner → Builder → QA → Designer → Optimizer → Deployer)
- Pause before deploy, operator approval required
- Per-project state tracking in `state/<id>-state.json`
- Decision rules: pause after 2 failures, 45min timeout, escalate to operator
- Daily evolution system with rules log
- Project independence (if one fails, move to the next)

---

## 2. Final Architecture

```
Cowork (Claude Desktop, scheduled tasks)     Orchestrator (system cron, 12:03 PM IST)
  ├─ 11:04 — Generate idea 1, write spec       ├─ orchestrate.sh reads projects.json
  ├─ 11:18 — Generate idea 2, write spec       ├─ For each "queued" project:
  └─ 11:29 — Build queue summary               │   ├─ Planner   → IMPLEMENTATION-PLAN.md
                                                │   ├─ Builder   → working app + BUILDER-NOTES.md
                                                │   ├─ QA        → fixes + QA-REPORT.md
                                                │   ├─ Designer  → polished UI + DESIGN-NOTES.md
                                                │   ├─ Optimizer → prod-ready + OPTIMIZER-NOTES.md
                                                │   └─ ⏸️ PAUSE → wait for operator
                                                │
                                                ├─ If stuck → pause, log, move to next project
                                                └─ Daily Report → logs/daily-report-YYYY-MM-DD.md

Operator (Aum, once daily)
  ├─ Read daily report
  ├─ Fix stuck projects (add env vars, clarify specs)
  ├─ Review builds, provide corrections
  └─ ./approve.sh <project-id> → Deployer runs
```

### How Each Agent Is Spawned

```bash
claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$PROJECT_DIR" \
  -p "$AGENT_PROMPT_WITH_CONTEXT"
```

This gives each agent:
- **Full tool access** (Bash, Edit, Write, Read, Glob, Grep) in a multi-turn autonomous loop
- **Scoped directory access** to the project being built
- **Sonnet model** for fast execution
- **No cost concerns** — runs under Claude Code subscription
- **Timeout** (45 min) is the only hard limit per agent

---

## 3. Directory Structure (Final)

```
~/Code/exploratory/
├── foundry/                    # Factory control center
│   ├── FOUNDRY-GUIDE.md                   # Quick-start guide (Cowork wrote, keep as-is)
│   ├── PIPELINE-ARCHITECTURE.md           # System design doc (Claude Code wrote)
│   ├── FINAL-PIPELINE-PLAN.md             # ← THIS FILE — merged plan
│   ├── CLAUDE-CODE-REVIEW.md              # Claude Code's review of Cowork's work
│   ├── BUILD-ENGINE-STATUS.md             # Current status snapshot
│   ├── projects.json                      # Project registry
│   ├── index.html                         # Portfolio page
│   │
│   ├── orchestrate.sh                     # NEW — main entry point (replaces run-factory.sh for builds)
│   ├── approve.sh                         # NEW — operator deploy approval helper
│   ├── build-project.sh                   # Cowork's version — UPDATE with correct CLI flags
│   ├── run-factory.sh                     # Keep for idea generation, UPDATE queue processing
│   │
│   ├── agents/                            # Agent definitions (Cowork wrote, keep as-is)
│   │   ├── MASTER-ORCHESTRATOR.md         # Orchestrator rules + daily evolution log
│   │   ├── planner.md                     # Agent 1: Spec → implementation plan
│   │   ├── builder.md                     # Agent 2: Plan → working app
│   │   ├── qa.md                          # Agent 3: Bug fixes + verification
│   │   ├── designer.md                    # Agent 4: UI polish
│   │   ├── optimizer.md                   # Agent 5: Perf, SEO, a11y
│   │   ├── deployer.md                    # Agent 6: Git → GitHub → Vercel
│   │   ├── agents.json                    # NEW — machine-readable agent registry (models, timeouts)
│   │   └── rules.json                     # NEW — evolved rules (auto-appended to prompts)
│   │
│   ├── lib/                               # NEW — shared shell functions
│   │   ├── state.sh                       # State management helpers
│   │   └── report.sh                      # Daily report generator
│   │
│   ├── state/                             # Per-project pipeline state (auto-generated)
│   │   └── <project-id>-state.json
│   │
│   └── logs/                              # Build logs + daily reports
│       ├── <project-id>-YYYYMMDD-HHMMSS.log
│       └── daily-report-YYYY-MM-DD.md
│
├── <project-id>/                          # Each project
│   ├── *-SPEC.md                          # Product spec (written by Cowork)
│   ├── CLAUDE-CODE-PROMPT.md              # Build instructions (written by Cowork)
│   ├── IMPLEMENTATION-PLAN.md             # Written by Planner agent
│   ├── BUILDER-NOTES.md                   # Written by Builder agent
│   ├── QA-REPORT.md                       # Written by QA agent
│   ├── DESIGN-NOTES.md                    # Written by Designer agent
│   ├── OPTIMIZER-NOTES.md                 # Written by Optimizer agent
│   ├── DEPLOY-NOTES.md                    # Written by Deployer agent
│   └── (project source files)             # Next.js app
```

### Naming Convention Resolution
- **Planner output:** `IMPLEMENTATION-PLAN.md` in project root (not `plan/<id>-plan.md`)
  - Simpler, no subdirectory needed, consistent with other agent output files
  - Cowork's agent definitions need updating to reference this path

---

## 4. Agent Definitions (Final)

Cowork's `agents/*.md` files are the executable prompts. They're well-written and stay as-is, with these adjustments:

### Adjustments Needed

| Agent | File | Change Needed |
|-------|------|---------------|
| Planner | `agents/planner.md` | Output path: `plan/<id>-plan.md` → `IMPLEMENTATION-PLAN.md` |
| Builder | `agents/builder.md` | Input path: `plan/<id>-plan.md` → `IMPLEMENTATION-PLAN.md` |
| All | All agent files | No other changes — the prompts, checklists, rules, failure modes, and success criteria are solid |

### Agent Timeout Map

| Agent | Timeout | Rationale |
|-------|---------|-----------|
| Planner | 45 min | Read-only, should finish in ~5 min |
| Builder | 45 min | Heaviest agent — may need full 45 min for complex apps |
| QA | 45 min | Reads all code, runs builds, fixes bugs |
| Designer | 45 min | Touches many component files |
| Optimizer | 45 min | Targeted changes, usually fast |
| Deployer | 45 min | Mostly bash commands, usually fast |

All agents run under the Claude Code subscription — no per-call costs. The timeout is the only hard limit.

### Agent Output Files (Audit Trail)

Each agent writes a report file in the project root. The next agent in the pipeline reads the previous agent's report for context. This is Cowork's addition and it's excellent:

```
Planner  → IMPLEMENTATION-PLAN.md  (read by Builder)
Builder  → BUILDER-NOTES.md        (read by QA)
QA       → QA-REPORT.md            (read by Designer)
Designer → DESIGN-NOTES.md         (read by Optimizer)
Optimizer→ OPTIMIZER-NOTES.md      (read by Deployer)
Deployer → DEPLOY-NOTES.md         (read by operator)
```

---

## 5. State Management (Final)

### Per-project state: `state/<project-id>-state.json`

Merged format combining both designs:

```json
{
  "project_id": "demoseed",
  "status": "in_progress",
  "current_step": "qa",
  "pipeline_started_at": "2026-03-17T12:03:00Z",
  "pipeline_updated_at": "2026-03-17T12:28:00Z",
  "steps": {
    "planner": {
      "status": "complete",
      "started_at": "2026-03-17T12:03:00Z",
      "completed_at": "2026-03-17T12:06:30Z",
      "duration_seconds": 210,
      "retries": 0,
      "notes": ""
    },
    "builder": {
      "status": "complete",
      "started_at": "2026-03-17T12:06:35Z",
      "completed_at": "2026-03-17T12:31:00Z",
      "duration_seconds": 1465,
      "retries": 0,
      "notes": ""
    },
    "qa":        { "status": "in_progress", "retries": 0 },
    "designer":  { "status": "pending", "retries": 0 },
    "optimizer": { "status": "pending", "retries": 0 },
    "deployer":  { "status": "pending", "retries": 0 }
  },
  "paused": false,
  "pause_reason": "",
  "operator_approved_deploy": false,
  "errors": []
}
```

**Key rule (from Claude Code):** State is written by the orchestrator script only — never by agents. This prevents state corruption if an agent crashes mid-write.

### Valid Status Transitions

```
queued → planner → builder → qa → designer → optimizer → ready_to_deploy → deployer → live
                                                                ↑
Any step can branch to: paused (with reason) ── operator fix ───┘
Any step can branch to: failed (after max retries exhausted)
```

---

## 6. The Orchestrator Script (`orchestrate.sh`)

This is the main entry point. It replaces `run-factory.sh` for build processing.

### Core Logic

```
orchestrate.sh
  1. Source lib/state.sh and lib/report.sh
  2. Read projects.json → find all "queued" projects
  3. Read state/ → find any in-progress or paused-but-resumed projects
  4. For each project (in order):
     a. Load or create state file
     b. Determine next step (resume from where left off)
     c. If next step is "deployer" and not approved → set "ready_to_deploy", skip
     d. Read agents/rules.json → find rules that apply to this agent
     e. Read agents/<step>.md → extract prompt content
     f. Build full prompt: agent definition + project context + triggered rules
     g. Spawn:
        claude --print \
          --dangerously-skip-permissions \
          --model claude-sonnet-4-6 \
          --add-dir $PROJECT_DIR \
          -p "$FULL_PROMPT"
     h. On success → update state, advance to next step, loop to (b)
     i. On failure → increment retries
        - If retries < 2 → re-run same agent
        - If retries >= 2 → pause project, log reason, move to next project
  5. After all projects: generate daily report → logs/daily-report-YYYY-MM-DD.md
  6. Exit
```

### Build Verification Gates (from Cowork)

After Builder and QA agents, the orchestrator runs `npm run build` independently to verify. If the build fails:
- After Builder → pause with "build failed after builder"
- After QA → pause with "build failed after QA"

This catches cases where an agent reports success but the build is actually broken.

### Timeout Handling

Each agent gets 45 minutes max (AGENT_TIMEOUT=2700 seconds). If exceeded:
- Kill the process
- Pause the project with reason "timeout after 45 minutes on <agent>"
- Move to next project

---

## 7. Error Handling (Final)

### Per-Agent Error Handling

| Scenario | Action |
|----------|--------|
| Agent exits 0 + expected output files exist | SUCCESS → advance to next step |
| Agent exits 0 + output files missing | AMBIGUOUS → check build status, retry once |
| Agent exits non-zero | FAILURE → log stderr, retry once, then pause |
| Agent times out (45 min) | TIMEOUT → kill, pause with "timeout" reason |
| `npm run build` fails after Builder/QA | BUILD GATE → pause, don't continue |
| Project paused | LOG + MOVE ON → start next project immediately |

### How We Determine Agent Success

Each agent writes a report file (Cowork's design). The orchestrator checks:
1. Did the report file get created? (e.g., `BUILDER-NOTES.md` exists)
2. Does `npm run build` pass? (for Builder, QA, Designer, Optimizer)
3. Did the agent exit with code 0?

All three must be true for success.

---

## 8. `approve.sh` — Operator Deploy Helper

```bash
#!/bin/bash
# approve.sh — Approve and deploy a built project
#
# Usage:
#   ./approve.sh <project-id>          # Approve and deploy
#   ./approve.sh --status              # Show what's waiting for approval
#   ./approve.sh --status <project-id> # Show specific project state

FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$FACTORY_DIR/state"

if [ "$1" = "--status" ]; then
  if [ -n "$2" ]; then
    cat "$STATE_DIR/$2-state.json" | jq '{status, current_step, pause_reason, operator_approved_deploy}'
  else
    echo "Projects waiting for deploy approval:"
    for f in "$STATE_DIR"/*-state.json; do
      [ -f "$f" ] || continue
      status=$(jq -r '.status' "$f")
      id=$(jq -r '.project_id' "$f")
      if [ "$status" = "ready_to_deploy" ]; then
        echo "  🟡 $id"
      elif [ "$status" = "paused" ]; then
        reason=$(jq -r '.pause_reason' "$f")
        echo "  ⏸️  $id — $reason"
      fi
    done
  fi
  exit 0
fi

PROJECT_ID="${1:?Usage: ./approve.sh <project-id>}"
STATE_FILE="$STATE_DIR/${PROJECT_ID}-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found for $PROJECT_ID"
  exit 1
fi

# Set approval flag and run deployer
jq '.operator_approved_deploy = true' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
echo "✅ Approved $PROJECT_ID for deployment"
echo "Running deployer..."
./build-project.sh "$PROJECT_ID" --deploy
```

---

## 9. `agents/agents.json` — Machine-Readable Agent Registry

```json
{
  "planner": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": false,
    "expected_output": "IMPLEMENTATION-PLAN.md",
    "description": "Reads spec, produces technical implementation plan"
  },
  "builder": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": true,
    "expected_output": "BUILDER-NOTES.md",
    "description": "Follows plan, builds complete Next.js app"
  },
  "qa": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": true,
    "expected_output": "QA-REPORT.md",
    "description": "Finds and fixes bugs, verifies build"
  },
  "designer": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": true,
    "expected_output": "DESIGN-NOTES.md",
    "description": "UI polish to Linear/Vercel quality"
  },
  "optimizer": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": true,
    "expected_output": "OPTIMIZER-NOTES.md",
    "description": "Performance, SEO, accessibility, deployment readiness"
  },
  "deployer": {
    "model": "claude-sonnet-4-6",
    "timeout_seconds": 2700,
    "max_retries": 2,
    "verify_build_after": false,
    "expected_output": "DEPLOY-NOTES.md",
    "description": "Git, GitHub, Vercel deploy, portfolio update"
  }
}
```

The orchestrator reads this file to get model, timeout, and success criteria for each agent. This means you can tune agent behavior (switch a specific agent to Opus for better reasoning, extend timeout) by editing one JSON file — no script changes needed.

---

## 10. `agents/rules.json` — Evolved Rules

Starts empty. Rules are added as we learn what breaks:

```json
[]
```

Example after first few runs:
```json
[
  {
    "id": "rule-001",
    "added": "2026-03-18",
    "applies_to": ["builder"],
    "append_to_prompt": "IMPORTANT: Tailwind v4 uses @import 'tailwindcss' in globals.css, NOT @tailwind base/components/utilities directives. Config is CSS-first — use @theme in globals.css, not tailwind.config.js.",
    "active": true,
    "reason": "Builder failed on first 3 projects because it used Tailwind v3 patterns"
  },
  {
    "id": "rule-002",
    "added": "2026-03-19",
    "applies_to": ["builder", "qa"],
    "append_to_prompt": "Both DemoSeed and IsItUp use Next.js 16 with App Router. The project uses the latest React 19 features. Use 'use client' only where needed.",
    "active": true,
    "reason": "Builder was scaffolding with Next.js 14 patterns"
  },
  {
    "id": "rule-003",
    "added": "2026-03-20",
    "applies_to": ["deployer"],
    "append_to_prompt": "Before running vercel --prod, check if env vars need to be set. Read .env.example and list any vars that need manual configuration in the Vercel dashboard. Include this list in DEPLOY-NOTES.md.",
    "active": true,
    "reason": "First deploy crashed because Supabase keys weren't set in Vercel"
  }
]
```

The orchestrator reads this before spawning each agent and appends matching rules to the prompt. This is how the system learns without editing agent definition files.

---

## 11. Daily Report Format

Generated by `lib/report.sh`, written to `logs/daily-report-YYYY-MM-DD.md`:

```markdown
## Factory Run — 2026-03-17

### Summary
- Projects processed: 2
- Completed (ready to deploy): 1
- Paused (needs attention): 1

### Completed
- ✅ **DemoSeed** — all 5 agents passed, ready to deploy
  - Planner: 3m | Builder: 25m | QA: 12m | Designer: 10m | Optimizer: 8m
  - Run `./approve.sh demoseed` to deploy

### Paused
- ⏸️ **IsItUp** — stuck at QA agent (attempt 2/2)
  - Reason: Auth not implemented. Spec requires Supabase auth but no Supabase project configured.
  - To fix: Create Supabase project, add SUPABASE_URL and SUPABASE_ANON_KEY to .env, then resume:
    `./orchestrate.sh` (will auto-resume from QA)

### Waiting for Approval
- 🟡 **DemoSeed** — `./approve.sh demoseed`

### Active Rules
- rule-001: Tailwind v4 CSS-first config (applied to: builder)

### Next Run
- Scheduled: 2026-03-18 at 12:03 PM IST
- IsItUp will resume from QA step if .env is configured
- Any new queued projects will start from Planner
```

---

## 12. Operator Daily Workflow

```bash
# 1. Check what happened (read the report)
cat ~/Code/exploratory/foundry/logs/daily-report-$(date +%Y-%m-%d).md

# 2. See what needs attention
./approve.sh --status

# 3. If a project is stuck, check details
cat state/<project-id>-state.json | jq '{status, current_step, pause_reason}'

# 4. Fix the issue (add env vars, clarify spec, etc.)
# Then resume — the orchestrator will pick it up on next run automatically
# Or run manually:
./orchestrate.sh

# 5. Approve a completed build for deployment
./approve.sh <project-id>

# 6. Add new rules based on what you learned
# Edit agents/rules.json, add to MASTER-ORCHESTRATOR.md Rules Log
```

---

## 13. Spec Requirements for Cowork

The multi-agent pipeline places specific demands on spec quality. Better specs = fewer pauses = faster builds.

### Must-Haves in Every Spec

1. **Section 5 (UI/UX) must have exact values** — hex colors, font sizes in px, spacing in px, border radii in px, animation durations in ms, easing functions. The Designer agent matches these literally. "Use a nice blue" → pause. "#3B82F6 for primary actions" → builds.

2. **Section 6 (Routes) must be complete** — the Planner counts routes and builds a page-by-page plan. Missing routes = missing pages = QA finds gaps = pause.

3. **Section 9 (Technical Constraints) matters** — the Optimizer reads this. Include: performance targets, data handling rules (client-side vs server), security requirements, which APIs are free vs need keys.

4. **API details must be verified** — the Builder will try to call these APIs. Include: exact base URL, auth method (API key? OAuth? None?), rate limits, whether it's actually free. Dead API = builder fails = pause.

5. **Auth requirements must be explicit** — "Use Supabase Auth with Google OAuth" is actionable. "Add authentication" is not. If auth is v2, say "Auth is deferred to v2 — all routes are public for MVP."

6. **Dark/light mode must be declared** — "Dark mode first" or "Light mode only." The Designer needs this to audit consistency.

### Nice-to-Haves

7. **Tailwind config snippet** — if the spec includes the exact `theme.extend` block, the Planner can copy it directly and the Builder won't guess wrong.

8. **Component inventory** — listing every custom component with its name, props, and behavior makes the Planner's job trivial and the Builder's job faster.

---

## 14. What Needs to Be Built (Execution Plan)

### Files Claude Code Builds

| # | File | Description | Depends On |
|---|------|-------------|------------|
| 1 | `lib/state.sh` | State management shell functions | Nothing |
| 2 | `agents/agents.json` | Agent registry with models/timeouts | Nothing |
| 3 | `agents/rules.json` | Empty scaffold for evolved rules | Nothing |
| 4 | `orchestrate.sh` | Main orchestrator script | #1, #2, #3 |
| 5 | `lib/report.sh` | Daily report generator | #1 |
| 6 | `approve.sh` | Operator deploy helper | #4 |

### Files Cowork Updates

| # | File | Change |
|---|------|--------|
| 7 | `agents/planner.md` | Output path: `plan/<id>-plan.md` → `IMPLEMENTATION-PLAN.md` |
| 8 | `agents/builder.md` | Input path: `plan/<id>-plan.md` → `IMPLEMENTATION-PLAN.md` |
| 9 | `FOUNDRY-GUIDE.md` | Fix "Next.js 14" → "Next.js 16" |

### Files to Update Together

| # | File | Change |
|---|------|--------|
| 10 | `build-project.sh` | Fix `claude -p` → add `--dangerously-skip-permissions` |
| 11 | `run-factory.sh` | Update queue processing to use new build-project.sh |
| 12 | System crontab | Point to `orchestrate.sh` |
| 13 | `BUILD-ENGINE-STATUS.md` | Reflect final architecture |

### Testing Plan

1. **Agent invocation test:** Run `claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 -p "Read ~/Code/exploratory/demoseed/DEMOSEED-SPEC.md and list all routes from Section 6"` — verify it runs autonomously with tool access
2. **State management test:** Run `orchestrate.sh` with DemoSeed set to "queued" — verify state file creates and updates correctly
3. **Failure test:** Break a spec, run orchestrate — verify it pauses and moves to next project
4. **Resume test:** Pause mid-pipeline, re-run — verify it resumes from correct step
5. **Approve test:** Run `./approve.sh demoseed` — verify deployer runs
6. **Report test:** Run full pipeline — verify daily report generates correctly

---

## 15. Open Questions for Operator

1. **Should we do a dry run with DemoSeed first?** It's already built — we could run just the QA → Designer → Optimizer agents as a test before processing new specs.

2. **GitHub username?** `projects.json` has `github_username: ""`. We need this for `gh repo create`. What's the GitHub username to use?

3. **Supabase projects?** Both DemoSeed and IsItUp reference Supabase. Are there Supabase projects created for them? If not, do we skip auth for v1 deploys?

4. **Vercel team/org?** Should projects deploy under a Vercel team or personal account?

5. **Rate limits?** Claude Code subscription has usage limits. At 2 projects/day with 6 agents each (12 agent sessions), are we comfortable with that throughput or should we limit to 1 project/day?
