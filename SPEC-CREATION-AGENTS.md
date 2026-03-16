# Spec Creation — Multi-Agent Debate Architecture

> **Purpose:** Replace Cowork's spec writing with a multi-agent system where agents debate and iterate until the spec is genuinely great — not just structurally valid.
>
> **Key insight:** The quality of a spec doesn't depend on which Claude instance writes it. It depends on the process. One agent writing alone produces "good enough." Multiple agents challenging each other produce "actually great."

---

## The Problem with Single-Agent Spec Writing

One agent writes a spec → another validates it structurally → done. This catches missing hex values and incomplete route tables, but it doesn't catch:

- A boring product idea nobody would pay for
- APIs that technically work but produce useless data when combined
- Pricing that doesn't match the persona's willingness to pay
- A user flow that's 12 steps when it should be 3
- A feature set that's a clone of 50 existing products with no differentiation
- A Section 5 design system that's technically complete but aesthetically generic

These are judgment calls. A single agent doesn't self-critique judgment — it needs an adversary.

---

## The Architecture: 4 Agents, 2 Rounds

```
Round 1: Generate + Challenge
  [Ideator] → raw idea + draft spec
  [Critic]  → tears it apart, scores it, demands fixes

Round 2: Refine + Validate
  [Refiner] → rewrites spec incorporating Critic's feedback
  [Validator] → structural + technical checklist (the old Reviewer role)

  Result: Final spec → projects.json status: "queued"
```

### Why 4 agents and not 2 or 6?

- **2 (write + review)** = Reviewer only catches structural issues, not quality issues
- **4 (ideate + critique + refine + validate)** = Critic catches quality issues, Refiner incorporates feedback, Validator catches structural gaps
- **6+** = Diminishing returns. The Critic is doing the heavy lifting. Adding more perspectives just adds time without proportional improvement.

---

## Agent Definitions

### Agent S1: Ideator

**Role:** Generate a product idea and write a first-draft spec.

**Identity prompt:**
```
You are a product strategist who finds micro-SaaS opportunities in free public APIs.
You think like an indie hacker — obsessed with finding painful problems that existing
tools solve badly or expensively, then wrapping free APIs into something people will
pay $9-99/month for.

You don't write generic CRUD apps. You find angles. You think about:
- WHO has this pain so badly they'll pay monthly to make it stop?
- WHY hasn't someone built this already? (And if they have, what's your edge?)
- WHAT combination of APIs creates something worth more than any single API?
- HOW does the user feel the first time they use it? (This must be a "holy shit" moment.)
```

**Input:**
- `projects.json` (existing projects — don't duplicate)
- `API-CATALOG.md` (verified free APIs with endpoints, auth, limits)
- Category target (optional — "we need more SMB Tools" or "dealer's choice")

**Output:**
- `<project-id>/<PROJECT-ID>-SPEC.md` — full 10-section spec, first draft
- `<project-id>/CLAUDE-CODE-PROMPT.md` — build instructions

**Key rules:**
1. The "What This Is" section must pass the bar test: can you explain it to a stranger in one sentence and have them say "oh I'd use that"?
2. Pick APIs that create emergent value when combined. Random User + Agify + Genderize → realistic demo personas (more than any one API alone).
3. The pricing must be justified. Don't slap "$29/mo" on everything. Ask: "what does this replace?" and price at 1/10th of that.
4. The onboarding flow must deliver value in under 60 seconds. If the user has to configure anything before seeing the product work, redesign it.
5. Write Section 5 with real aesthetic intention. Don't just pick "dark mode + purple accent" for everything. Match the vibe to the audience. A tool for accountants looks different from a tool for designers.

**Model:** Opus (creative ideation benefits from stronger model)
**Timeout:** 30 min

---

### Agent S2: Critic

**Role:** Read the Ideator's spec and ruthlessly evaluate it. Score it. Demand specific fixes.

**Identity prompt:**
```
You are a brutally honest product advisor. You've seen 500 micro-SaaS launches.
You know which ones make money and which ones rot on Product Hunt with 12 upvotes.

Your job is NOT to be encouraging. Your job is to find every weakness in this
product spec BEFORE it gets built — because building a bad spec wastes 45 minutes
of agent time and produces something nobody wants.

You evaluate on 5 dimensions:
1. MARKET — Is there a real buyer? Would they pay this price? Monthly?
2. DIFFERENTIATION — Does this exist already? What's the angle that makes this one win?
3. PRODUCT FLOW — Is the user journey tight? Can someone get value in under 60 seconds?
4. TECHNICAL FEASIBILITY — Will these APIs actually work as described? Are they reliable? Free?
5. DESIGN COHERENCE — Does the design system match the audience? Is it generic or intentional?

You score each dimension 1-10 and provide specific, actionable feedback.
If any dimension scores below 6, the spec needs a rewrite.
If the total score is below 35/50, the idea should be killed and replaced.
```

**Input:**
- The Ideator's spec
- `API-CATALOG.md` (to verify API claims)
- Existing portfolio (`projects.json`) — to check for differentiation from what we already have

**Output:**
- `<project-id>/CRITIC-REVIEW.md` with:
  - Score per dimension (1-10)
  - Total score (/50)
  - Verdict: PROCEED / REWRITE / KILL
  - For REWRITE: specific numbered fixes required
  - For KILL: why this idea won't work + optional alternative idea suggestion

**Key rules:**
1. Don't be nice. A 7/10 is "solid." An 8/10 is "genuinely good." 9-10 is rare. If everything is 8+, you're not being critical enough.
2. Check every API endpoint the Ideator referenced. Is the URL real? Is the auth method correct? Is it actually free? If you can't verify, flag it.
3. Look for the "so what?" factor. If the product is "we show you exchange rates in a nice UI" — so what? XE.com exists. What's the angle?
4. Count the steps in the onboarding flow. If it's more than 3 clicks to value, flag it.
5. Read Section 5 with designer eyes. Is the color palette coherent? Does the typography choice match the audience? Or is it just "dark mode + Inter font" like every other indie SaaS?
6. Check the pricing math. If the spec claims "$1M ARR" at "$29/mo", that's 2,874 paying customers. Is that realistic for this niche?

**Model:** Opus (critical analysis and judgment)
**Timeout:** 20 min

---

### Agent S3: Refiner

**Role:** Take the Ideator's spec + the Critic's feedback and produce the final spec.

**Identity prompt:**
```
You are a product spec writer who turns rough ideas into build-ready documents.
You just received a first-draft spec and a critic's review with specific scores
and feedback.

Your job: rewrite the spec to address every piece of criticism while keeping
what already works. You don't start from scratch — you surgically improve.

For every fix the Critic demanded, you either:
(a) Implement the fix in the spec, or
(b) Push back with a clear reason why the Critic is wrong (and document your reasoning)

You write specs at a quality level where a build agent can follow them
mechanically and produce a premium product. Every measurement is exact.
Every flow is numbered. Every API is verified.
```

**Input:**
- Original spec from Ideator
- `CRITIC-REVIEW.md` with scores and required fixes
- `API-CATALOG.md` (if APIs need to be swapped)

**Output:**
- Rewritten `<project-id>/<PROJECT-ID>-SPEC.md` (overwrites Ideator's draft)
- Updated `<project-id>/CLAUDE-CODE-PROMPT.md` (if build instructions changed)
- `<project-id>/REFINEMENT-LOG.md` — for each Critic point: what was changed and why, or why it was rejected

**Key rules:**
1. Address EVERY point in CRITIC-REVIEW.md. Don't silently ignore criticisms.
2. If the Critic scored a dimension below 6, that section gets a major rewrite, not a tweak.
3. If the Critic verdicted KILL, you have two choices: (a) make a compelling case for why the idea works despite the criticism, with substantial changes, or (b) generate a completely new idea and spec. Don't polish a dead idea.
4. All Section 5 values must be exact: hex colors, px sizes, ms timings, easing functions.
5. All Section 6 routes must be complete with path, component, and auth requirement.
6. All APIs must have verified base URLs, auth method, and rate limits.
7. The final spec must be >3000 words across all 10 sections.

**Model:** Opus (rewriting with nuance requires strong reasoning)
**Timeout:** 30 min

---

### Agent S4: Validator

**Role:** Structural and technical checklist. Pass/fail gate before the spec enters the build queue.

**Identity prompt:**
```
You are a quality gate. You don't evaluate whether the idea is good — the Critic
already did that. You verify that the spec is structurally complete and technically
ready for the build pipeline.

You run a checklist. Every item is pass or fail. No judgment calls. No opinions.
Just verification.
```

**Input:**
- Final spec from Refiner
- `REFINEMENT-LOG.md` (to verify all Critic points were addressed)
- `agents/rules.json` (any spec-related rules from previous failures)

**Output:**
- `<project-id>/SPEC-VALIDATION.md` — checklist with pass/fail per item
- If ALL pass: update `projects.json` status to `"queued"`
- If ANY fail: update status to `"needs_review"`, list failures for operator or another Refiner pass

**Checklist:**

```
SECTION 1 — What This Is
[ ] One paragraph, clear value proposition
[ ] Target audience identified

SECTION 2 — Target Users
[ ] At least 2 personas
[ ] Each has: name, role, pain point, price sensitivity
[ ] At least one persona would pay the stated price

SECTION 3 — APIs
[ ] At least 1 API listed
[ ] Each API has: exact base URL, auth method, rate limits
[ ] Auth method is one of: none, API key (free tier), OAuth
[ ] No paid-only APIs (unless spec explicitly budgets for it)

SECTION 4 — Product Flow
[ ] Onboarding flow defined (numbered steps)
[ ] Onboarding reaches value in ≤ 3 steps
[ ] Core workflow defined (numbered steps)
[ ] At least 2 distinct user flows

SECTION 5 — UI/UX
[ ] Color palette: all values are hex codes (not names, not Tailwind classes)
[ ] Primary, secondary, background, surface, border, text-primary, text-secondary, accent, success, error, warning — all defined
[ ] Typography: heading font, body font, mono font specified by name
[ ] Font sizes: at least heading (h1-h3) and body sizes in px or rem
[ ] Spacing: base unit declared in px
[ ] Border radii: at least 2 sizes in px
[ ] Animation timing: at least fast + normal in ms
[ ] Easing function specified
[ ] Dark/light mode explicitly declared (not ambiguous)
[ ] At least 1 signature microinteraction described

SECTION 6 — Information Architecture
[ ] Route table exists
[ ] Every route has: path, page name
[ ] At least 3 routes (landing, dashboard/main, at least one feature page)
[ ] Auth-gated vs public distinction noted

SECTION 7 — Pricing
[ ] At least 2 tiers (free + paid, or basic + pro)
[ ] Prices are specific dollar amounts
[ ] Path to revenue explained (not just "people will pay")

SECTION 8 — Key User Flows
[ ] At least 3 flows
[ ] Each flow has numbered steps
[ ] Each step describes what the user sees and does

SECTION 9 — Technical Constraints
[ ] Data handling specified (client-side vs server-side)
[ ] At least 1 performance target
[ ] Security requirements mentioned

SECTION 10 — MVP Scope
[ ] v1 feature list (what gets built now)
[ ] v2 feature list (what's deferred)
[ ] Clear line between v1 and v2

OVERALL
[ ] Total word count > 3000
[ ] All 10 sections present
[ ] REFINEMENT-LOG.md addresses every CRITIC-REVIEW.md point
[ ] No TODO/TBD/placeholder text remaining
```

**Model:** Opus (even validation benefits from stronger reasoning — catching subtle issues like "this API endpoint exists but returns useless data for this use case")
**Timeout:** 15 min

---

## The Full Flow

```
Step 1: Ideator (Opus, 30 min)
  Input:  API catalog + existing projects + category target
  Output: First-draft spec + build prompt

Step 2: Critic (Opus, 20 min)
  Input:  Draft spec + API catalog + existing portfolio
  Output: CRITIC-REVIEW.md (scores, verdict: PROCEED/REWRITE/KILL)

  If KILL and score < 35/50:
    → Loop back to Step 1 with "the last idea was killed because [reason], try something different"
    → Max 2 kills per run. After 2 kills, pause for operator.

  If PROCEED (all dimensions ≥ 6, total ≥ 35):
    → Skip Step 3, go straight to Step 4

  If REWRITE:
    → Continue to Step 3

Step 3: Refiner (Opus, 30 min)
  Input:  Draft spec + CRITIC-REVIEW.md + API catalog
  Output: Rewritten spec + REFINEMENT-LOG.md

Step 4: Validator (Sonnet, 15 min)
  Input:  Final spec + REFINEMENT-LOG.md (if exists) + rules.json
  Output: SPEC-VALIDATION.md (pass/fail)

  If ALL pass:
    → projects.json status: "queued"
    → Spec enters the build pipeline on next cron run

  If ANY fail:
    → projects.json status: "needs_review"
    → Operator reviews, or auto-send back to Refiner (max 1 re-refine)
```

### Time per spec

- **Best case** (Critic says PROCEED): Ideator (15m) + Critic (10m) + Validator (5m) = **~30 min**
- **Typical case** (Critic says REWRITE): Ideator (15m) + Critic (10m) + Refiner (15m) + Validator (5m) = **~45 min**
- **Worst case** (first idea KILLED, second REWRITTEN): 2× Ideator + 2× Critic + Refiner + Validator = **~90 min**

At 2 specs/day, that's 1-3 hours of agent time for spec creation, well before the build pipeline starts at 12:03 PM.

---

## The Wrapper Script: `create-spec.sh`

```bash
#!/bin/bash
# create-spec.sh — Multi-agent spec creation pipeline
# Usage: ./create-spec.sh [--category "SMB Tools"] [--count 2]

FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
CATEGORY="${CATEGORY:-}"
COUNT="${COUNT:-1}"
MAX_KILLS=2

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --category) CATEGORY="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

for i in $(seq 1 $COUNT); do
  echo "═══ Generating spec $i of $COUNT ═══"
  KILLS=0

  # ── STEP 1: IDEATOR ──
  IDEATOR_PROMPT="$(cat $FACTORY_DIR/agents/ideator.md)

EXISTING PROJECTS:
$(cat $FACTORY_DIR/projects.json | jq -r '.projects[] | "- \(.id): \(.name) — \(.tagline)"')

API CATALOG:
$(cat $FACTORY_DIR/API-CATALOG.md)

$([ -n "$CATEGORY" ] && echo "TARGET CATEGORY: $CATEGORY")
$([ -n "$KILL_REASON" ] && echo "IMPORTANT: Your last idea was killed because: $KILL_REASON. Try a completely different angle.")

Generate one micro-SaaS idea. Write the full 10-section spec and Claude Code prompt.
Create the project directory at ~/Code/exploratory/<project-id>/."

  IDEA_RESULT=$(claude --print --dangerously-skip-permissions --model claude-opus-4-6 \
    -p "$IDEATOR_PROMPT" 2>&1)

  # Find the project ID that was just created
  PROJECT_ID=$(ls -td ~/Code/exploratory/*/  | head -1 | xargs basename)

  # ── STEP 2: CRITIC ──
  SPEC_FILE=$(find ~/Code/exploratory/$PROJECT_ID -name "*SPEC.md" | head -1)

  claude --print --dangerously-skip-permissions --model claude-opus-4-6 \
    -p "$(cat $FACTORY_DIR/agents/critic.md)

SPEC TO REVIEW:
$(cat "$SPEC_FILE")

EXISTING PORTFOLIO:
$(cat $FACTORY_DIR/projects.json | jq -r '.projects[] | "- \(.id): \(.name) — \(.tagline)"')

API CATALOG:
$(cat $FACTORY_DIR/API-CATALOG.md)

Write your review to ~/Code/exploratory/$PROJECT_ID/CRITIC-REVIEW.md.
Score each dimension 1-10. Give a verdict: PROCEED, REWRITE, or KILL." 2>&1

  # Parse verdict
  VERDICT=$(grep -i "verdict" ~/Code/exploratory/$PROJECT_ID/CRITIC-REVIEW.md | head -1 | tr '[:lower:]' '[:upper:]')

  if echo "$VERDICT" | grep -q "KILL"; then
    KILLS=$((KILLS + 1))
    if [ $KILLS -ge $MAX_KILLS ]; then
      echo "⏸️ Two ideas killed. Pausing for operator review."
      break
    fi
    KILL_REASON=$(grep -A2 -i "verdict" ~/Code/exploratory/$PROJECT_ID/CRITIC-REVIEW.md | tail -1)
    echo "💀 Idea killed. Reason: $KILL_REASON. Retrying..."
    # Clean up killed project
    rm -rf ~/Code/exploratory/$PROJECT_ID
    continue
  fi

  if echo "$VERDICT" | grep -q "REWRITE"; then
    # ── STEP 3: REFINER ──
    claude --print --dangerously-skip-permissions --model claude-opus-4-6 \
      -p "$(cat $FACTORY_DIR/agents/refiner.md)

ORIGINAL SPEC:
$(cat "$SPEC_FILE")

CRITIC REVIEW:
$(cat ~/Code/exploratory/$PROJECT_ID/CRITIC-REVIEW.md)

API CATALOG:
$(cat $FACTORY_DIR/API-CATALOG.md)

Rewrite the spec at $SPEC_FILE. Address every point from the critic.
Write REFINEMENT-LOG.md to ~/Code/exploratory/$PROJECT_ID/." 2>&1
  fi

  # ── STEP 4: VALIDATOR ──
  claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 \
    -p "$(cat $FACTORY_DIR/agents/validator.md)

SPEC:
$(cat "$SPEC_FILE")

$([ -f ~/Code/exploratory/$PROJECT_ID/REFINEMENT-LOG.md ] && echo "REFINEMENT LOG:" && cat ~/Code/exploratory/$PROJECT_ID/REFINEMENT-LOG.md)

$([ -f $FACTORY_DIR/agents/rules.json ] && echo "ACTIVE RULES:" && cat $FACTORY_DIR/agents/rules.json)

Validate the spec. Write SPEC-VALIDATION.md to ~/Code/exploratory/$PROJECT_ID/.
If all checks pass, update $FACTORY_DIR/projects.json: add this project with status 'queued'.
If any check fails, set status to 'needs_review'." 2>&1

  echo "✅ Spec pipeline complete for $PROJECT_ID"
done

echo "═══ Spec creation done ═══"
```

---

## Updated Crontab

```crontab
# Foundry — Fully Autonomous
00 10 * * * cd ~/Code/exploratory/foundry && ./create-spec.sh --count 2 >> logs/spec-creation.log 2>&1
03 12 * * * cd ~/Code/exploratory/foundry && ./orchestrate.sh >> logs/cron.log 2>&1
00 23 * * * cd ~/Code/exploratory/foundry && ./evolver.sh >> logs/evolver.log 2>&1
```

Specs created at 10:00 AM → built at 12:03 PM → reviewed at 11:00 PM. Operator checks in whenever.

---

## What This Produces Per Spec

```
~/Code/exploratory/<project-id>/
├── <PROJECT-ID>-SPEC.md          # Final spec (written by Ideator, refined by Refiner)
├── CLAUDE-CODE-PROMPT.md         # Build instructions
├── CRITIC-REVIEW.md              # Scores + feedback + verdict
├── REFINEMENT-LOG.md             # How each criticism was addressed (if rewrite happened)
└── SPEC-VALIDATION.md            # Structural checklist pass/fail
```

This is a complete paper trail. If a build fails, you can trace back: was the spec bad (Critic missed something)? Was the criticism ignored (Refiner skipped a point)? Was the validation incomplete (Validator's checklist needs updating)?

---

## Why This Is Better Than One Agent

| Single Strategist | Multi-Agent Debate |
|---|---|
| Writes and self-reviews (confirmation bias) | Separate agents challenge each other |
| "Good enough" specs | Specs scored on 5 dimensions, rewrites demanded for <6/10 |
| Generic ideas (dark mode + purple + Inter) | Critic specifically calls out generic choices |
| No paper trail for failures | CRITIC-REVIEW + REFINEMENT-LOG trace every decision |
| Can't kill bad ideas (sunk cost) | Critic can KILL an idea, force a restart |
| API claims unchecked | Critic verifies every API endpoint |
| One-pass quality | Two-pass minimum (Ideator + Validator), three-pass typical (+ Critic + Refiner) |

---

## Dependency: API-CATALOG.md

The Ideator and Critic need a curated, verified list of free APIs. This should be created once and maintained as new APIs are discovered or old ones die.

Format:
```markdown
## Category: Data Generation
| API | Base URL | Auth | Rate Limit | Notes |
|-----|---------|------|------------|-------|
| RandomUser | https://randomuser.me/api/ | None | Unlimited | Generates realistic user profiles |
| Agify | https://api.agify.io | None | 1000/day free | Predicts age from name |
| ...

## Category: Finance
| API | Base URL | Auth | Rate Limit | Notes |
|-----|---------|------|------------|-------|
| Frankfurter | https://api.frankfurter.app | None | Unlimited | ECB exchange rates, no crypto |
| ...
```

This catalog is the single most important input to the spec creation pipeline. Bad catalog → bad ideas → bad specs → bad builds.

---

## Implementation Order

| # | Task | Who | Effort |
|---|------|-----|--------|
| 1 | Write `API-CATALOG.md` — curated, verified free APIs | Claude Code (research agent) or Cowork | 1 session |
| 2 | Write `agents/ideator.md` | Claude Code | Quick |
| 3 | Write `agents/critic.md` | Claude Code | Quick |
| 4 | Write `agents/refiner.md` | Claude Code | Quick |
| 5 | Write `agents/validator.md` | Claude Code | Quick |
| 6 | Write `create-spec.sh` wrapper | Claude Code | 1 session |
| 7 | Test: run on one idea manually | Operator watches | 1 hour |
| 8 | Test: feed the spec into the build pipeline | Operator watches | 2-3 hours |
| 9 | Iterate: adjust Critic scoring, Ideator prompt based on results | Ongoing | |
