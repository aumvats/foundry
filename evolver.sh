#!/bin/bash
# ============================================================================
# evolver.sh — Nightly Rule Evolution Runner
# ============================================================================
# Runs the Evolver agent to analyze today's runs and propose new rules.
#
# Cron: 00 23 * * * cd ~/Code/exploratory/foundry && ./evolver.sh >> logs/evolver.log 2>&1
# ============================================================================

set -e

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
EVOLVER_LOCK="$FACTORY_DIR/.evolver.lock"

source "$FACTORY_DIR/lib/state.sh"
source "$FACTORY_DIR/lib/report.sh"

mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[evolver]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }

# ── CONCURRENT EXECUTION GUARD ───────────────────────────────────────────────
exec 202>"$EVOLVER_LOCK"
if ! flock -n 202; then
  log "evolver.sh already running, exiting"
  exit 0
fi

# ── PRE-FLIGHT ───────────────────────────────────────────────────────────────
log "Evolver starting: $(date)"

if ! claude --print -p "echo AUTHCHECK" 2>&1 | grep -q "AUTHCHECK"; then
  echo "AUTH FAILED $(date)" >> "$LOG_DIR/alerts.log"
  fail "Claude CLI auth check failed"
fi

# ── GENERATE HISTORY SUMMARY ─────────────────────────────────────────────────
log "Generating history summary for Evolver context..."
generate_history_summary > /dev/null
if [ -f "/tmp/factory-history-summary.json" ]; then
  ok "History summary at /tmp/factory-history-summary.json"
else
  warn "History summary generation failed — Evolver will have no historical context"
fi

# ── RUN EVOLVER AGENT ────────────────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)

EVOLVER_PROMPT="You are the Evolver agent. Read agents/evolver.md from the factory directory for your full instructions.

Today's date: $TODAY
Factory directory: $FACTORY_DIR

Read these files (using --add-dir access):
- logs/spec-creation-${TODAY}.md (today's spec pipeline results)
- state/ directory files updated today
- Any BUILDER-NOTES.md, QA-REPORT.md, DESIGN-NOTES.md from project directories updated today
- /tmp/factory-history-summary.json (compact historical summary)
- agents/rules.json (existing active rules — do NOT re-propose these)
- logs/rule-proposals-*.md from the last 7 days (avoid re-proposing pending rules)

Write your proposals to: $LOG_DIR/rule-proposals-${TODAY}.md"

log "Running Evolver agent (timeout: 1800s, budget: \$2.00)..."

timeout 1800 claude \
  --dangerously-skip-permissions \
  --model claude-opus-4-6 \
  --max-budget-usd 2 \
  --add-dir "$FACTORY_DIR" \
  --add-dir "$ROOT_DIR" \
  -p "$EVOLVER_PROMPT" 2>&1

EXIT_CODE="${PIPESTATUS[0]}"

if [ "$EXIT_CODE" -eq 124 ]; then
  warn "Evolver timed out"
elif [ "$EXIT_CODE" -ne 0 ]; then
  warn "Evolver failed with exit code $EXIT_CODE"
fi

# Check output
PROPOSAL_FILE="$LOG_DIR/rule-proposals-${TODAY}.md"
if [ -f "$PROPOSAL_FILE" ]; then
  PROPOSAL_COUNT=$(grep -c "^###" "$PROPOSAL_FILE" 2>/dev/null || echo 0)
  ok "Evolver complete: $PROPOSAL_COUNT rule proposal(s) written to $PROPOSAL_FILE"
else
  warn "Evolver did not write a proposals file"
  echo "EVOLVER_NO_OUTPUT $(date)" >> "$LOG_DIR/alerts.log"
fi

log "Evolver done: $(date)"
