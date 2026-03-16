#!/bin/bash
# ============================================================================
# review-spec.sh — Operator helper for needs_review specs
# ============================================================================
# Usage:
#   ./review-spec.sh --list              Show all specs needing review
#   ./review-spec.sh <project-id>        Review and re-validate a specific spec
# ============================================================================

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"

source "$FACTORY_DIR/lib/state.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[review]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }

if [ $# -eq 0 ]; then
  echo "Usage: ./review-spec.sh --list | <project-id>"
  exit 1
fi

# ── --list ───────────────────────────────────────────────────────────────────
if [ "$1" = "--list" ]; then
  echo -e "\n${BOLD}Specs needing review:${NC}"

  NEEDS_REVIEW_FILE="$LOG_DIR/needs-review-queue.md"
  if [ ! -f "$NEEDS_REVIEW_FILE" ] || [ ! -s "$NEEDS_REVIEW_FILE" ]; then
    ok "No specs in needs-review queue"
    exit 0
  fi

  echo -e "\n${YELLOW}From needs-review-queue.md:${NC}"
  cat "$NEEDS_REVIEW_FILE"

  echo -e "\n${YELLOW}From projects.json (status: needs_review):${NC}"
  jq -r '.projects[] | select(.status == "needs_review") | "  \(.id): \(.name) — \(.spec_pipeline.critic_verdict // "no verdict")"' "$PROJECTS_JSON" 2>/dev/null || echo "  (none)"
  echo ""
  exit 0
fi

# ── Review specific project ───────────────────────────────────────────────────
PROJECT_ID="$1"
PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"

if [ ! -d "$PROJECT_DIR" ]; then
  echo -e "${RED}Project directory not found: $PROJECT_DIR${NC}"
  exit 1
fi

SPEC_FILE=$(find "$PROJECT_DIR" -name "*SPEC.md" -maxdepth 1 | head -1)
VALIDATION_FILE="$PROJECT_DIR/SPEC-VALIDATION.json"

echo -e "\n${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}Review: $PROJECT_ID${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}\n"

# Show failing checks
if [ -f "$VALIDATION_FILE" ]; then
  echo -e "${YELLOW}Failing checks:${NC}"
  jq -r '.failing_checks[]? | "  ✗ \(.)"' "$VALIDATION_FILE"
  echo ""
fi

# Show critic review if exists
if [ -f "$PROJECT_DIR/CRITIC-REVIEW.md" ]; then
  echo -e "${YELLOW}Critic Review summary:${NC}"
  grep -A2 "^| \*\*TOTAL\*\*" "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | head -5 || true
  echo ""
fi

# Open spec in editor
if [ -f "$SPEC_FILE" ]; then
  log "Opening spec in \$EDITOR (${EDITOR:-vi})..."
  ${EDITOR:-vi} "$SPEC_FILE"
fi

# Re-run Validator after edits
echo ""
read -p "Re-run Validator now? [y/N] " RUN_VAL
if [[ "$RUN_VAL" =~ ^[Yy]$ ]]; then
  log "Running Validator..."

  VALIDATOR_PROMPT="You are the Validator agent. Read agents/validator.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read REFINEMENT-LOG.md if it exists in $PROJECT_DIR.
Write ONLY SPEC-VALIDATION.json to: $PROJECT_DIR/
Do NOT modify any other file. Do NOT touch projects.json."

  timeout 900 claude \
    --dangerously-skip-permissions \
    --model claude-sonnet-4-6 \
    --max-budget-usd 0.50 \
    --add-dir "$PROJECT_DIR" \
    --add-dir "$FACTORY_DIR" \
    -p "$VALIDATOR_PROMPT" 2>&1

  # Check result
  RECOMMENDED=$(jq -r '.recommended_status // "needs_review"' "$VALIDATION_FILE" 2>/dev/null)
  if [ "$RECOMMENDED" = "queued" ]; then
    ok "Validation passed! Updating status to queued..."
    update_project_field "$PROJECT_ID" ".status" '"queued"'
    ok "$PROJECT_ID is now queued for build"
  else
    FAILING=$(jq -r '.failing_checks | join(", ")' "$VALIDATION_FILE" 2>/dev/null)
    warn "Still failing: $FAILING"
    warn "Fix and re-run: ./review-spec.sh $PROJECT_ID"
  fi
fi
