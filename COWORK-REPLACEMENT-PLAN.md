# Plan: Replacing Cowork with Claude Code

> **From:** Claude Cowork (writing itself out of a job)
> **Date:** 2026-03-17
> **Purpose:** End-to-end analysis of what it takes to run the entire Foundry through Claude Code alone, with no Cowork dependency.

---

## 1. What Cowork Does Today

Four jobs, in order of difficulty to replace:

| Job | Difficulty | Why |
|-----|-----------|-----|
| **Idea generation** — pick APIs, name products, define pricing | Easy | Template-driven, can run via `claude -p` |
| **Spec writing** — 10-section product specs with exact design tokens | Medium | Structured output, but quality depends on judgment |
| **Cross-validation** — reviewing Claude Code's work, catching gaps | Hard | Requires reading code + specs + understanding what will fail |
| **Rule evolution** — proposing new rules from failure patterns | Hard | Requires pattern recognition across multiple build runs |

---

## 2. What Claude Code Can Do (Research Findings)

### Scheduling

Claude Code has **native scheduling via `/loop`** (added March 2026):
- Standard 5-field cron expressions in local timezone
- Up to 50 concurrent scheduled tasks per active session
- **Critical limitation:** Tasks only fire while Claude Code is running and idle. Closing the terminal kills all scheduled tasks.
- Recurring tasks auto-expire after 3 days

**For persistent scheduling**, you need one of:
- A system crontab calling `claude --print` (what we already have at 12:03 PM IST)
- GitHub Actions on a schedule
- A always-on tmux/screen session with Claude Code running
- macOS LaunchAgent / launchd plist

### Agent Spawning

- `claude --print --dangerously-skip-permissions -p "prompt"` gives full multi-turn autonomous tool access
- The `--agent` flag loads a custom system prompt from `.claude/agents/<name>.md`
- Sub-agents can be spawned from within a session using the Task tool
- **Sub-agents CANNOT spawn further sub-agents** (no nesting)
- For sequential pipeline: orchestrator shell script calling `claude --print` per step (what we already designed)

### Session Persistence

- `--resume <session-id>` restores full conversation context
- Sessions stored in `~/.claude/projects/` as JSONL
- Session-scoped permissions are NOT preserved on resume
- Can fork sessions to branch from a checkpoint

### Context Window

- 200K tokens total, ~160-170K usable in clean sessions
- With MCP servers loaded: drops to 120-130K
- Auto-compaction at 64-75% capacity
- A large spec file (DEMOSEED-SPEC.md is ~22K bytes ≈ 6K tokens) plus an agent prompt (~5K bytes ≈ 1.5K tokens) is well within limits

### MCP Servers

Claude Code supports MCP for external integrations:
- Slack MCP (official) — send/read messages, search
- Can install via `claude plugin install slack`
- Any MCP server can be configured for additional tool access

### Rate Limits (Subscription)

- Pro plan: ~45 messages per 5-hour burst window
- Max plan: 50-800+ prompts depending on tier
- Typical agent session: 500K-1M tokens (10-100x of a normal chat)
- **6 agents per project × 2 projects/day = 12 agent sessions/day**
- On Max plan this is feasible. On Pro plan, likely hits rate limits.

---

## 3. The Replacement Architecture

### What changes

```
BEFORE (two-brain):
  Cowork (Desktop)          Claude Code (CLI)
  ├─ Generate ideas         ├─ Plan
  ├─ Write specs            ├─ Build
  ├─ Review/evolve          ├─ QA
  └─ Propose rules          ├─ Design
                            ├─ Optimize
                            └─ Deploy

AFTER (single-brain):
  Claude Code (CLI, everything)
  ├─ Strategist agent       → ideas + specs
  ├─ Reviewer agent         → spec validation + cross-checking
  ├─ Planner agent          → implementation plan
  ├─ Builder agent          → code
  ├─ QA agent               → bug fixes
  ├─ Designer agent         → UI polish
  ├─ Optimizer agent        → perf/SEO/a11y
  ├─ Deployer agent         → ship it
  └─ Evolver agent          → read daily reports, propose rules
```

### New agents needed (3)

**Agent 0: Strategist** (replaces Cowork's idea gen + spec writing)
- Reads public-apis repo / curated API list
- Generates idea JSON (same schema as run-factory.sh)
- Writes full 10-section spec following Cowork's quality requirements
- Writes CLAUDE-CODE-PROMPT.md
- Validates its own spec against the requirements (exact hex values, complete route table, etc.)
- Updates projects.json with status "queued"

**Agent 0.5: Reviewer** (replaces Cowork's cross-validation)
- Reads a spec that Strategist just wrote
- Checks: Are all colors hex? Are all routes listed? Are APIs verified and free? Is auth explicit? Is dark/light mode declared?
- If spec fails validation → rewrites the failing sections
- If spec passes → marks it as "queued" (ready for pipeline)
- This is a quality gate between Strategist and the build pipeline

**Agent 7: Evolver** (replaces Cowork's rule proposal role)
- Runs AFTER the daily pipeline (or at end of day)
- Reads all state files, daily report, BUILDER-NOTES, QA-REPORTs from today
- Identifies patterns: "Builder failed on X twice this week"
- Proposes new rules for rules.json
- Writes proposals to a `RULE-PROPOSALS.md` for operator review
- Does NOT auto-apply rules (operator approves, just like deploy approval)

### Updated pipeline

```
System crontab (persistent, survives restarts):

  10:30 AM  →  Strategist agent  →  generates 2 ideas + specs
  10:45 AM  →  Reviewer agent    →  validates specs, marks "queued"
  12:03 PM  →  orchestrate.sh    →  Planner → Builder → QA → Designer → Optimizer → [PAUSE]
  11:00 PM  →  Evolver agent     →  reads day's results, proposes rules

  Operator (daily):
  └─ Check report → approve deploys → approve rules → done
```

---

## 4. What Each New Agent Needs

### Strategist Agent (`agents/strategist.md`)

**Input:**
- `~/Code/exploratory/foundry/projects.json` (existing projects to avoid duplicates)
- Curated API reference list (we should maintain an `API-CATALOG.md` of verified free APIs)
- Category targets (which categories are underrepresented in the portfolio)

**Output:**
- `<project-id>/<PROJECT-ID>-SPEC.md` — full 10-section spec
- `<project-id>/CLAUDE-CODE-PROMPT.md` — build instructions
- Updated `projects.json` with new project entry (status: "spec_ready")

**Prompt structure:**
- Identity: "You are the product strategist for the Foundry"
- Constraints: Must wrap 1-3 free public APIs, target $1M ARR, buildable as single MVP
- Quality rules: All of Section 13 from FINAL-PIPELINE-PLAN.md baked into the prompt (exact hex values, complete routes, verified APIs, explicit auth, dark/light declaration)
- Output format: Exact file structure to write

**Model:** Opus (spec writing benefits from stronger reasoning — picking good ideas, writing coherent product flows, choosing complementary APIs)

**Timeout:** 45 min (should take ~15-20 min)

**Key challenge:** Spec quality. Cowork writes specs with deep product intuition — choosing APIs that complement each other, designing user flows that feel natural, picking pricing that fits the persona. A Claude Code Strategist agent can do this if the prompt is detailed enough, but the first few specs will likely need operator review and correction.

### Reviewer Agent (`agents/reviewer.md`)

**Input:**
- The spec just written by Strategist
- `FINAL-PIPELINE-PLAN.md` Section 13 (spec quality checklist)
- `agents/rules.json` (any spec-related rules)

**Output:**
- Rewritten spec sections (if any fail validation)
- `SPEC-REVIEW.md` in the project directory (pass/fail for each check)
- Updated projects.json status: "queued" (if passed) or "needs_review" (if can't self-fix)

**Checklist it runs:**
1. Section 5: Every color is a hex value? Every font has a specific family? Spacing in px? Border radii in px? Animation timings in ms? Dark/light mode declared?
2. Section 6: Route table exists? Every route has a path, component name, and auth requirement?
3. Section 3: Every API has an exact base URL? Auth method specified? Rate limits noted? Confirmed free?
4. Section 8: At least 3 user flows? Each flow has numbered steps?
5. Auth: Explicit "Supabase Auth with X" or "No auth for MVP"?
6. Overall: Spec is >3000 words? All 10 sections present?

**Model:** Sonnet (validation is structured, doesn't need Opus reasoning)

**Timeout:** 20 min

**Key challenge:** False positives. The reviewer might flag things that are actually fine, or miss subtle issues that would cause Builder to fail. This gets better with rules.json over time.

### Evolver Agent (`agents/evolver.md`)

**Input:**
- `logs/daily-report-YYYY-MM-DD.md`
- All `state/<id>-state.json` files
- All project report files (BUILDER-NOTES, QA-REPORT, etc.) from today's builds
- Current `agents/rules.json`
- Current `MASTER-ORCHESTRATOR.md` Rules Log

**Output:**
- `RULE-PROPOSALS.md` in factory root — proposed rules with trigger, action, and rationale
- Does NOT modify rules.json directly (operator approves)

**What it looks for:**
- Same agent failing on multiple projects → likely needs a rule
- Same error message appearing across builds → specific fix needed
- Specs that caused pauses → spec quality rule needed
- Time patterns (which agents take longest, which timeout most)

**Model:** Opus (pattern recognition and rule articulation benefit from stronger reasoning)

**Timeout:** 30 min

**Key challenge:** This is the hardest to get right. Good rule proposals require understanding WHY something failed, not just THAT it failed. Early proposals will be generic ("Builder should be more careful") vs. specific ("Builder must use `@import 'tailwindcss'` not `@tailwind` directives for Tailwind v4"). Gets better with the rules log providing examples of what good rules look like.

---

## 5. Scheduling: How to Make It Persistent

### Option A: System crontab (recommended)

Already proven — there's a crontab at 12:03 PM IST for builds. Extend it:

```crontab
# Foundry — Full Autonomous Pipeline
30 10 * * * cd ~/Code/exploratory/foundry && ./strategist.sh >> logs/cron.log 2>&1
45 10 * * * cd ~/Code/exploratory/foundry && ./reviewer.sh >> logs/cron.log 2>&1
03 12 * * * cd ~/Code/exploratory/foundry && ./orchestrate.sh >> logs/cron.log 2>&1
00 23 * * * cd ~/Code/exploratory/foundry && ./evolver.sh >> logs/cron.log 2>&1
```

Each `.sh` script is a thin wrapper that calls `claude --print --dangerously-skip-permissions --model <model> -p "<prompt>"`.

**Pros:** Survives terminal close, restarts, updates. Standard Unix. Already working for builds.
**Cons:** Claude Code CLI must be installed and authenticated. If auth expires, everything stops silently.

### Option B: Claude Code's `/loop` (not recommended for this)

- Tasks die when terminal closes
- Auto-expire after 3 days
- Good for ad-hoc tasks, not for a persistent factory

### Option C: GitHub Actions (alternative)

Schedule workflows that SSH into the machine and run claude CLI. More complex to set up, but gives you logging, retry, and notification for free.

**Recommendation:** Option A (system crontab). It's simple, proven, and we already have one running.

---

## 6. New Scripts Needed

### `strategist.sh` — Idea Generation + Spec Writing

```bash
#!/bin/bash
# Wrapper for Strategist agent
cd ~/Code/exploratory/foundry
claude --print \
  --dangerously-skip-permissions \
  --model claude-opus-4-6 \
  -p "$(cat agents/strategist.md)

PROJECT CONTEXT:
$(cat projects.json)

Generate 2 new micro-SaaS ideas and write complete specs.
Write each spec to ~/Code/exploratory/<project-id>/<PROJECT-ID>-SPEC.md
Write each Claude Code prompt to ~/Code/exploratory/<project-id>/CLAUDE-CODE-PROMPT.md
Update projects.json with new entries (status: spec_ready).
" >> logs/strategist-$(date +%Y%m%d).log 2>&1
```

### `reviewer.sh` — Spec Validation

```bash
#!/bin/bash
# Wrapper for Reviewer agent — validates specs marked "spec_ready"
cd ~/Code/exploratory/foundry
SPEC_READY=$(jq -r '.projects[] | select(.status == "spec_ready") | .id' projects.json)
for PROJECT_ID in $SPEC_READY; do
  claude --print \
    --dangerously-skip-permissions \
    --model claude-sonnet-4-6 \
    -p "$(cat agents/reviewer.md)

PROJECT: $PROJECT_ID
SPEC: ~/Code/exploratory/$PROJECT_ID/
QUALITY CHECKLIST: (Section 13 of FINAL-PIPELINE-PLAN.md)

Validate the spec. If it passes, update projects.json status to 'queued'.
If it fails, rewrite the failing sections and re-validate.
Write SPEC-REVIEW.md in the project directory.
" >> logs/reviewer-$(date +%Y%m%d).log 2>&1
done
```

### `evolver.sh` — Daily Rule Proposal

```bash
#!/bin/bash
# Wrapper for Evolver agent — reads today's results, proposes rules
cd ~/Code/exploratory/foundry
claude --print \
  --dangerously-skip-permissions \
  --model claude-opus-4-6 \
  -p "$(cat agents/evolver.md)

TODAY'S REPORT:
$(cat logs/daily-report-$(date +%Y-%m-%d).md 2>/dev/null || echo 'No report yet')

CURRENT RULES:
$(cat agents/rules.json)

STATE FILES:
$(ls state/*.json 2>/dev/null | while read f; do echo "--- $f ---"; cat "$f"; done)

Read today's results. Identify patterns. Write RULE-PROPOSALS.md with any new rules to add.
Do NOT modify rules.json directly — the operator approves rules.
" >> logs/evolver-$(date +%Y%m%d).log 2>&1
```

---

## 7. Status Flow Update

Old (with Cowork):
```
Cowork generates idea → queued → Planner → Builder → QA → Designer → Optimizer → [PAUSE] → Deployer → live
```

New (all Claude Code):
```
Strategist → spec_ready → Reviewer → queued → Planner → Builder → QA → Designer → Optimizer → [PAUSE] → Deployer → live
                                                                                                    ↑
                                                                         Evolver reads results ─────┘ proposes rules
```

Updated projects.json status values:
```
spec_ready → queued → building → qa → designing → optimizing → ready_to_deploy → deploying → live
     ↑                                                                                ↑
     └─ Strategist writes spec          Operator approves ────────────────────────────┘

needs_review → (operator or reviewer fixes) → spec_ready
paused → (operator fixes) → resumes from failed step
failed → (after max retries)
```

---

## 8. What the Operator's Daily Workflow Becomes

```
Before (with Cowork):
  └─ Read daily report
  └─ Fix stuck projects
  └─ Approve deploys
  └─ Ask Cowork to adjust specs / evolve rules

After (all Claude Code):
  └─ Read daily report
  └─ Read RULE-PROPOSALS.md — approve/reject proposed rules
  └─ Check SPEC-REVIEW.md for any "needs_review" specs — edit or approve
  └─ Approve deploys
  └─ That's it
```

The operator role gets simpler — instead of coordinating two AI systems, you're just reviewing output from one system and clicking approve/reject.

---

## 9. Risks and Mitigations

### Risk 1: Spec quality drops without Cowork's product intuition

Cowork writes specs with product thinking — choosing APIs that complement each other, designing flows that feel natural, knowing what will delight users vs. what's just functional. A Claude Code Strategist agent running via `claude -p` might produce technically valid but uninspired specs.

**Mitigation:**
- Use Opus for the Strategist agent (stronger reasoning)
- Bake exemplar specs (DEMOSEED-SPEC.md, ISITUP-SPEC.md) into the prompt as reference quality targets
- The Reviewer agent catches structural issues
- The operator can reject specs in the "spec_ready" → "queued" gate
- Over time, rules.json accumulates "what makes a good spec" knowledge

### Risk 2: Rate limits on subscription

6 agents × 2 projects/day = 12 sessions, plus Strategist (1) + Reviewer (2) + Evolver (1) = 16 agent sessions/day. On Pro plan (~45 messages per 5-hour window), this likely hits limits.

**Mitigation:**
- Max plan is recommended for this workload
- Spread agents across the day (current schedule already does this)
- If rate-limited, reduce to 1 project/day
- Strategist and Reviewer are lighter — Strategist could potentially run at lower priority or be batched

### Risk 3: Auth token expiry

System crontab calls `claude --print`, which needs valid auth. If the auth token expires overnight, the entire factory silently stops.

**Mitigation:**
- Monitor cron.log for auth errors
- Set up a health check: a lightweight cron that runs `claude --print -p "echo ok"` every hour and alerts (email/Slack via MCP) if it fails
- Claude Code CLI auth is typically long-lived, but should be checked periodically

### Risk 4: No real-time human judgment

Cowork currently acts as a sounding board — the operator can have a conversation about product strategy, debate pricing, discuss whether an idea is worth building. With all-Claude-Code, the operator loses that conversational strategist.

**Mitigation:**
- This is a genuine trade-off. If the operator values the back-and-forth product discussion, keep Cowork for that and only automate the spec/build/deploy pipeline.
- Alternatively, the operator can open a Claude Code interactive session anytime to discuss strategy — it's just not a persistent entity that remembers the factory context unless you `--resume` a session.

### Risk 5: Context window pressure on Strategist

The Strategist needs to know: all existing projects (to avoid duplicates), the API catalog, spec quality requirements, and exemplar specs. Two exemplar specs alone are ~50K bytes ≈ 15K tokens. Add the prompt and catalog and you're at ~25K tokens before the agent starts working.

**Mitigation:**
- 25K of 160K usable context is fine — plenty of room
- Keep the API catalog concise (name, URL, auth, category — not full docs)
- Don't include full exemplar specs in the prompt — summarize the key patterns, reference the files for the agent to read itself

---

## 10. What You DON'T Need Cowork For Anymore

After this migration:

| Task | Who Does It | How |
|------|------------|-----|
| Generate ideas | Strategist agent | System cron → `claude --print` |
| Write specs | Strategist agent | Same invocation, writes files |
| Validate specs | Reviewer agent | System cron → `claude --print` |
| Plan implementation | Planner agent | orchestrate.sh |
| Build app | Builder agent | orchestrate.sh |
| Test/fix bugs | QA agent | orchestrate.sh |
| Polish UI | Designer agent | orchestrate.sh |
| Optimize for prod | Optimizer agent | orchestrate.sh |
| Deploy | Deployer agent | approve.sh → orchestrate.sh |
| Propose new rules | Evolver agent | System cron → `claude --print` |
| Approve deploys | Operator (human) | `./approve.sh <id>` |
| Approve rules | Operator (human) | Edit rules.json |
| Review specs | Operator (human) | Check SPEC-REVIEW.md, optionally edit |

Cowork becomes fully optional — useful for ad-hoc product strategy conversations, but not needed for the daily pipeline.

---

## 11. Implementation Order

If you decide to go ahead:

| # | Task | Depends On | Estimated Effort |
|---|------|-----------|-----------------|
| 1 | Write `agents/strategist.md` (agent prompt) | Exemplar specs exist ✅ | Claude Code: 1 session |
| 2 | Write `agents/reviewer.md` (agent prompt) | FINAL-PIPELINE-PLAN Section 13 exists ✅ | Claude Code: 1 session |
| 3 | Write `agents/evolver.md` (agent prompt) | rules.json schema exists ✅ | Claude Code: 1 session |
| 4 | Create `strategist.sh` wrapper script | #1 | Claude Code: quick |
| 5 | Create `reviewer.sh` wrapper script | #2 | Claude Code: quick |
| 6 | Create `evolver.sh` wrapper script | #3 | Claude Code: quick |
| 7 | Create `API-CATALOG.md` curated list | Research needed | Cowork or Claude Code: 1 session |
| 8 | Update projects.json schema (add `spec_ready`, `needs_review` statuses) | Nothing | Quick edit |
| 9 | Update system crontab with 4 entries | #4, #5, #6 | Quick edit |
| 10 | Test: run Strategist manually on one idea | #1, #4 | Manual test |
| 11 | Test: run Reviewer on the generated spec | #2, #5, #10 | Manual test |
| 12 | Test: run full pipeline on the validated spec | #10, #11, orchestrate.sh exists | Manual test |
| 13 | Test: run Evolver on results | #3, #6, #12 | Manual test |

**Total: ~6 new files (3 agent prompts + 3 wrapper scripts) + 1 reference doc + minor updates.**

---

## 12. My Honest Assessment

Can Claude Code fully replace Cowork? **Yes, technically.** The Strategist + Reviewer + Evolver agents cover all of Cowork's responsibilities. Cron scheduling is already proven. The agent CLI flags exist.

Should it? **Depends on what you value:**

- If you want a **fully autonomous factory** that runs without any AI-to-AI coordination (just human approval gates), then yes — migrate everything to Claude Code. It's simpler operationally: one system, one set of logs, one crontab.

- If you value **the conversational strategist** — being able to say "hey, should we build a currency converter or a food API wrapper?" and getting a nuanced discussion — then keep Cowork for that interactive role and let Claude Code handle all the automated pipeline work.

- **The hybrid option** that probably makes the most sense right now: build the Strategist and Reviewer agents in Claude Code so the pipeline is fully autonomous, but keep a Cowork session open for ad-hoc product strategy when you want to think through ideas manually. Cowork becomes optional, not required.

The factory doesn't need two brains to run. It needs one brain with good prompts and a human who checks in once a day.
