# Test Run 01 — Learnings & Post-Mortem

**Date:** 2026-03-17
**Run IDs:** project-1773693880 (PulseCheck), project-1773694454 (LeadShield)
**Status:** Spec pipeline complete — 2 KILLs, 0 queued. Build pipeline not reached.
**Goal:** First end-to-end live test of the Foundry pipeline

---

## Executive Summary

Four consecutive script failures before the pipeline ran successfully. All failures were macOS environment compatibility issues — none were logic errors in the factory architecture. The architecture held up. The infra assumptions did not. Every failure was silent (no error message, just exit code 1), making diagnosis harder than it needed to be.

**Time lost to debugging:** ~45 minutes
**Root causes:** 3 distinct macOS incompatibilities + 1 bash 3.2 behavior difference
**Time to fix each once identified:** <5 minutes each

---

## Failures & Fixes

### Failure 1 — `flock` not available on macOS

**Symptom:** `create-spec.sh` exited with message `"create-spec.sh already running, exiting"` immediately, even though it wasn't running.
**Root cause:** `flock` is a Linux utility (util-linux). macOS does not ship it. When `flock -n 200` runs, the command is not found, returns exit code 127 (command not found). The concurrent lock check `if ! flock -n 200` treated the non-zero exit as "lock already held" and exited cleanly.
**Why it was silent:** The failure looked like normal behavior — the "already running" message is intentional. It masked the real error.
**Fix:** `brew install flock`
**Prevention:** Add dependency check to pre-flight that explicitly validates `flock` exists before attempting to use it.

---

### Failure 2 — `CLAUDECODE` env var blocks nested `claude` invocations

**Symptom:** Pre-flight auth check `claude --print -p "echo AUTHCHECK"` failed with: `Error: Claude Code cannot be launched inside another Claude Code session.`
**Root cause:** When running inside a Claude Code session (which we always are), the `CLAUDECODE` environment variable is set. The `claude` CLI checks for this and refuses to start to prevent resource conflicts.
**Fix:** Add `unset CLAUDECODE` at the top of every script that invokes `claude`. This unsets it only for the child process — the parent Claude Code session is unaffected.
**Note:** This only affects interactive use (running scripts manually from within Claude Code). Cron jobs don't have `CLAUDECODE` set, so they work fine without the fix. Still worth having for debugging.

---

### Failure 3 — `timeout` not available on macOS

**Symptom:** Script silently exited after `log "Project ID: project-XXXX"` with no error in the log.
**Root cause:** `timeout` is a GNU coreutils command. macOS ships `gtimeout` instead (if coreutils is installed), or nothing at all. When `timeout 1800 claude ...` ran, the `timeout` command was not found (exit code 127). With `set -e`, this caused immediate script exit before any output was written.
**Why it was silent:** The `timeout` command failure happened before `tee -a "$SPEC_LOG"` could capture anything. The failure was upstream of logging.
**Fix:** `brew install coreutils` (installs GNU `timeout` alongside `gtimeout`)
**Prevention:** Add to pre-flight:
```bash
command -v timeout >/dev/null 2>&1 || { echo "timeout not found: brew install coreutils"; exit 1; }
command -v flock   >/dev/null 2>&1 || { echo "flock not found: brew install flock"; exit 1; }
```

---

### Failure 4 — `set -e` + `$([ -n "" ] && ...)` in bash 3.2

**Symptom:** Script exited after `log "Project ID: ..."` with no error message. bash -x trace showed `++ '[' -n '' ']'` twice, then stopped.
**Root cause:** The Ideator prompt was built using `$([ -n "$CATEGORY_TARGET" ] && echo "...")`. When `CATEGORY_TARGET` is empty, `[ -n "" ]` exits 1, the `&&` short-circuits, the subshell exits 1. In bash 3.2 (macOS default), this non-zero exit from a command substitution inside a string assignment triggers `set -e` and kills the script — even though the assignment itself is valid.
**Note:** This behavior was fixed in bash 4+. macOS ships bash 3.2.57 (the last GPLv2 version). This will never self-fix.
**Fix:** Replace `$([ -n "$VAR" ] && echo "text")` with `${VAR:+text}` (bash parameter expansion — no subshell, always returns 0, works in all bash versions).
**General rule:** Never use `$(cmd && echo ...)` patterns inside string assignments when `set -e` is active on bash 3.2. Use `${VAR:+text}` or pre-compute with `if` statements.

---

### Fix Applied Post-Failure — Homebrew PATH not in cron

**Issue (pre-emptive fix):** After installing `flock` and `timeout` via Homebrew, cron jobs would still fail because cron's default PATH is `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` — it does not include `/opt/homebrew/bin`.
**Fix:** Added `export PATH="/opt/homebrew/bin:$PATH"` after the `unset CLAUDECODE` line in all scripts.
**Why important:** Without this, all cron runs at 10:00 AM, 12:03 PM, and 11:00 PM would silently fail the same way `timeout` did.

---

## Environment Baseline (what the system needs)

Confirmed working on macOS 25.3.0 (Darwin arm64):

| Dependency | Source | Version | Install |
|-----------|--------|---------|---------|
| Claude CLI | Anthropic | 2.1.50 | Pre-installed |
| gh CLI | GitHub | — | Pre-installed |
| Vercel CLI | Vercel | 50.4.9 | Pre-installed |
| jq | — | 1.7.1 | Pre-installed |
| Node.js | nvm | v24.11.1 | Pre-installed |
| flock | Homebrew | 0.4.0 | `brew install flock` ← **was missing** |
| timeout | Homebrew/coreutils | 9.10 | `brew install coreutils` ← **was missing** |
| bash | macOS | 3.2.57 | Ships with macOS — cannot upgrade easily |

---

## Agent Quality — Observations

### Ideator Output: Both specs

| Spec | Lines | Size | Sentinel | Time |
|------|-------|------|----------|------|
| PulseCheck (project-1773693880) | 282 | 17KB | ✓ | ~6 min |
| LeadShield (project-1773694454) | ~300 | 19KB | ✓ | ~6 min |

Both specs were structurally complete: sentinel written, CLAUDE-CODE-PROMPT.md written, all 3 outputs correct. The Ideator is working well.

### Critic Output: Both KILLed

| Project | Score | Verdict | Primary kill reason |
|---------|-------|---------|---------------------|
| PulseCheck | 31/50 | KILL | NewsAPI free tier exhausted at ~8 users; $19/mo can't cover $449/mo paid API |
| LeadShield | 30/50 | KILL | Saturated market (NeverBounce/ZeroBounce); EmailRep 100/day rate limit |

**The Critic is working correctly.** Both KILLs were accurate — these are real structural problems, not nitpicks. The gate is doing its job.

**Pattern identified:** The Ideator gravitated toward ideas built on free-tier APIs as core infrastructure. Both products would have failed at commercial scale because the API costs exceed the pricing model. This is a systemic Ideator weakness that the Evolver should address.

### What the Critic caught that the Ideator missed

- **PulseCheck:** The math: 8 Pro subscribers ($19/mo each = $152/mo) vs $449/mo for NewsAPI paid tier = impossible unit economics
- **LeadShield:** EmailRep's 100 req/day free limit means paid customers can't get their "5-signal trust score" reliably; core value prop breaks at scale

### Ideator Behavior to Fix

The Ideator should be required to explicitly verify:
1. Does the free tier of each API support the Free plan described in the spec?
2. What does the paid API tier cost, and does the pricing model support it?
3. Is the market already dominated by well-funded competitors with proprietary infrastructure?

These checks currently live only in the Critic. Moving them upstream to the Ideator would eliminate wasted Critic API calls on structurally broken ideas. Add to `agents/rules.json` when confirmed by Evolver.

---

## Pipeline Timing (Actual vs Estimated)

| Phase | Estimated | Actual |
|-------|-----------|--------|
| Ideator (PulseCheck) | 15–30 min | ~6 min ✓ |
| Critic (PulseCheck) | 10–20 min | ~4 min ✓ |
| Ideator (LeadShield, retry) | 15–30 min | ~6 min ✓ |
| Critic (LeadShield) | 10–20 min | ~3 min ✓ |
| Spec pipeline total (2 kills) | 45–90 min | ~19 min |
| Refiner | 20–30 min (if REWRITE) | Not reached |
| Validator | 5–10 min | Not reached |
| Build pipeline | 90–180 min | Not reached |

**Total wall time from first `create-spec.sh` to pipeline exit:** ~2:14AM → ~2:33AM = **19 minutes** (for 2 full Ideator+Critic cycles). Faster than estimated.

---

## Rules to Add to `agents/rules.json`

These are operationally-discovered rules, not agent-behavior rules. They belong in the pre-flight checks and script hardening, not in agent prompts. Already fixed in code — listed here for traceability.

For actual agent rules (prompt injections), the **Evolver agent** runs tonight at 11PM and will propose rules based on today's spec pipeline logs. Those proposals land in `logs/rule-proposals-2026-03-17.md` — review them tomorrow morning and activate the good ones by adding them to `agents/rules.json` with `"active": true`.

---

## Pre-flight Checks to Add

The following checks should be added to the pre-flight section of `create-spec.sh` (and `orchestrate.sh`) to catch environment issues before wasting agent budget:

```bash
# macOS dependency check (add after existing pre-flight)
for cmd in flock timeout jq node gh; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "MISSING DEPENDENCY: $cmd" >> "$LOG_DIR/alerts.log"
    fail "Required command not found: $cmd. See TEST-RUN-01-LEARNINGS.md for install instructions."
  }
done
```

---

## What Went Right

1. **Architecture is sound.** Once the environment was correct, the pipeline started exactly as designed.
2. **Ideator quality is solid.** 282-line spec in 6 minutes, sentinel written, prompt file written — all three outputs correct.
3. **Dashboard works.** SSE live updates running at localhost:4040, log streaming and project status both updating in real-time.
4. **flock locking works.** Once installed, the concurrent execution guard correctly allows one spec pipeline at a time.
5. **PIPESTATUS fix works.** Exit codes captured correctly through tee pipes.
6. **unset CLAUDECODE fix works.** Nested claude invocations now work when running scripts manually from within Claude Code.

---

## Run Outcome

**Result:** 2 KILLs, 0 queued. The spec pipeline ran correctly but produced no viable ideas.
**Build pipeline:** Not reached — nothing to build.

**What the run proved:**
- ✓ Pipeline architecture works end-to-end (Ideator → Critic → retry → Critic → kill limit exit)
- ✓ Concurrent lock (`flock`) works correctly
- ✓ Kill limit + retry logic works (2 kills → exits cleanly, no infinite loop)
- ✓ Critic quality is high — both kills were accurate
- ✗ Ideator needs stronger API economics constraints to avoid wasting Critic budget on structurally broken ideas

---

## Action Items Before Next Scheduled Run (10:00 AM next day)

- [ ] Add explicit `flock` + `timeout` dependency checks to pre-flight in `create-spec.sh` and `orchestrate.sh`
- [ ] Review Evolver proposals at `logs/rule-proposals-2026-03-17.md` (available after 11PM cron)
- [ ] Add rule to `agents/rules.json`: Ideator must verify API tier costs vs pricing model before writing spec
- [ ] Run `./create-spec.sh --count 1` again to get a viable queued project (scheduled cron at 10AM tomorrow will do this automatically)
- [ ] Once a project reaches `queued` status: run `./orchestrate.sh --project <id>` to test the build pipeline
