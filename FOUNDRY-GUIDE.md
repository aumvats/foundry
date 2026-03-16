# Foundry — Claude Code Guide

## What Is This?

You are the build engine for a Foundry — an autonomous pipeline that creates, builds, and deploys micro-SaaS products. Each product is a focused wrapper around free public APIs, targeting $1M ARR.

**Your role:** Run the multi-agent build pipeline. Each project goes through 6 specialized agents in sequence: Planner → Builder → QA → Designer → Optimizer → Deployer.

**You do NOT need to:** Generate ideas, write specs, or make product decisions. That's handled by Claude Cowork (the strategist). You receive complete specs.

---

## Directory Structure

```
~/Code/exploratory/
├── foundry/             # Factory control center
│   ├── FOUNDRY-GUIDE.md            # ← YOU ARE HERE. Read this first.
│   ├── projects.json               # Registry of all projects + statuses
│   ├── build-project.sh            # Multi-agent build pipeline script
│   ├── run-factory.sh              # Full factory runner (queue processing)
│   ├── index.html                  # Portfolio webpage (lists all projects)
│   ├── agents/                     # Agent definitions (READ THESE)
│   │   ├── MASTER-ORCHESTRATOR.md  # Your decision-making rules
│   │   ├── planner.md              # Agent 1: Spec → implementation plan
│   │   ├── builder.md              # Agent 2: Plan → working app
│   │   ├── qa.md                   # Agent 3: Bug fixes + verification
│   │   ├── designer.md             # Agent 4: UI polish to spec
│   │   ├── optimizer.md            # Agent 5: Perf, SEO, a11y
│   │   └── deployer.md             # Agent 6: Git → GitHub → Vercel
│   ├── state/                      # Per-project build state (auto-generated)
│   └── logs/                       # Build logs
│
├── demoseed/                       # Project: DemoSeed (status: built)
│   ├── DEMOSEED-SPEC.md            # Product spec (10 sections)
│   ├── CLAUDE-CODE-PROMPT.md       # Legacy build instructions
│   ├── plan/                       # ← Planner agent writes here
│   └── (project files)             # Next.js app
│
├── isitup/                         # Project: IsItUp (status: built)
│   ├── ISITUP-SPEC.md
│   ├── CLAUDE-CODE-PROMPT.md
│   ├── plan/
│   └── (project files)
│
└── <new-project>/                  # Future projects follow the same pattern
    ├── *-SPEC.md                   # Written by Claude Cowork
    ├── CLAUDE-CODE-PROMPT.md       # Written by Claude Cowork
    ├── plan/                       # Written by Planner agent
    └── (you build the rest)
```

---

## The Multi-Agent Pipeline

Every project runs through 6 agents in order. Read each agent's definition in `agents/` for full details.

```
Queue → Planner → Builder → QA → Designer → Optimizer → [PAUSE] → Deployer
```

| Step | Agent | What It Does | Output File |
|------|-------|-------------|-------------|
| 1 | **Planner** | Reads spec → writes implementation plan | `plan/<id>-plan.md` |
| 2 | **Builder** | Follows plan → builds full Next.js app | `BUILDER-NOTES.md` |
| 3 | **QA** | Verifies build, fixes bugs, security check | `QA-REPORT.md` |
| 4 | **Designer** | Matches UI to spec Section 5 exactly | `DESIGN-NOTES.md` |
| 5 | **Optimizer** | SEO metadata, a11y, error boundaries, perf | `OPTIMIZER-NOTES.md` |
| 6 | **Deployer** | Git init → GitHub repo → Vercel deploy → update portfolio | `DEPLOY-NOTES.md` |

**Key rule: The pipeline PAUSES after Optimizer. Deployer only runs with operator approval.**

---

## How to Run

### Option A: Automated pipeline (recommended)

```bash
cd ~/Code/exploratory/foundry

# Full pipeline — runs agents 1-5, pauses before deploy
./build-project.sh <project-id>

# Resume from a specific agent (if pipeline paused)
./build-project.sh <project-id> --resume-from qa

# Deploy after operator approves
./build-project.sh <project-id> --deploy
```

### Option B: Process the entire queue

```bash
# Build all queued projects
./run-factory.sh --build-only

# Generate ideas + build queue
./run-factory.sh --generate 2
```

### Option C: Run agents manually

If you want more control, run each agent yourself by reading the agent definition in `agents/<name>.md` and following its instructions directly. This is useful for debugging a stuck project.

```bash
# 1. Read the agent definition
cat agents/planner.md

# 2. Navigate to the project
cd ~/Code/exploratory/<project-id>

# 3. Do what the agent definition says
```

---

## State Management

Each project's pipeline state is tracked in `state/<project-id>-state.json`. This tells you exactly which agent the project is on, which have completed, and whether it's paused.

```json
{
  "project_id": "demoseed",
  "current_step": "qa",
  "status": "in_progress",
  "started_at": "2026-03-17T12:03:00",
  "steps": {
    "planner":   { "status": "complete", "duration": "3m", "notes": "" },
    "builder":   { "status": "complete", "duration": "25m", "notes": "" },
    "qa":        { "status": "in_progress", "duration": "", "notes": "" },
    "designer":  { "status": "pending" },
    "optimizer": { "status": "pending" },
    "deployer":  { "status": "pending" }
  },
  "errors": [],
  "paused": false,
  "pause_reason": ""
}
```

---

## Build Standards

Every project must meet these standards (enforced by QA + Optimizer agents):

### Code Quality
- Clean TypeScript with no `any` types in critical paths
- Environment variables for all API keys (never hardcode)
- `.env.example` documenting all required vars
- `.gitignore` covering node_modules, .env, .next, .vercel

### UI/UX Quality
- **Section 5 of the spec is law.** Exact hex colors, font families, border radii, animation timings.
- Quality bar: Linear, Vercel, Raycast
- Mobile-responsive (390px)
- Three states for every page: loading (skeleton), error (friendly message + retry), empty (illustration + CTA)
- All animations under 300ms with ease-out easing

### Technical Standards
- Next.js 16 + App Router + Tailwind CSS
- `npm run build` must exit 0
- All API calls have error handling and fallbacks
- No secrets in code (QA agent greps for them)

---

## projects.json Format

```json
{
  "id": "project-slug",
  "name": "Display Name",
  "tagline": "Short tagline under 60 chars",
  "description": "2-3 sentence description",
  "status": "live",
  "spec_dir": "project-slug",
  "repo": "https://github.com/username/project-slug",
  "live_url": "https://project-slug.vercel.app",
  "pricing": "$XX/mo Pro",
  "category": "Developer Tools",
  "color": "#8B5CF6",
  "built_at": "2026-03-15"
}
```

Status flow: `queued` → `building` → `built` → `live` (or `paused` / `failed`)

---

## Decision Rules (from MASTER-ORCHESTRATOR.md)

### When to pause
- Agent fails twice on the same step
- `npm run build` fails after QA pass
- Spec is ambiguous (needs operator clarification)
- Missing API keys or env vars
- Agent runs > 45 min without progress

### When to retry
- `npm install` fails → clear node_modules, retry once
- Build fails with clear error → QA agent fixes, retry build
- Max 2 retries per agent per project

### When to escalate
- ANY pause — always tell the operator why
- Missing env vars for deployment
- Ambiguous design decisions
- Two projects conflicting on API rate limits

---

## Quick Start Checklist

When starting a new session, do this:

1. **Read this file** (you're doing that now)
2. **Check the queue**: `cat projects.json | jq '.projects[] | select(.status == "queued")'`
3. **Check state**: `ls state/` — see if any projects are mid-pipeline
4. **Pick up where you left off**: If a project is paused, read its state file and resume
5. **If queue is empty**: Report back. Claude Cowork will generate more specs.
