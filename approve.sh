#!/bin/bash
# ============================================================================
# approve.sh — Deploy approval helper
# ============================================================================
# Usage: ./approve.sh <project-id>
#   Verifies build, runs deployer agent, updates status to "live"
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

log()  { echo -e "${BLUE}[approve]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }

PROJECT_ID="${1:?Usage: ./approve.sh <project-id>}"
PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"

if [ ! -d "$PROJECT_DIR" ]; then
  fail "Project directory not found: $PROJECT_DIR"
fi

# Check current status
CURRENT_STATUS=$(get_project_field "$PROJECT_ID" ".status")
PROJECT_NAME=$(get_project_field "$PROJECT_ID" ".name")

echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Approve Deploy: $PROJECT_NAME ($PROJECT_ID)${NC}"
echo -e "${BOLD}  Current status: $CURRENT_STATUS${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}\n"

if [ "$CURRENT_STATUS" != "built" ]; then
  warn "Project status is '$CURRENT_STATUS', not 'built'"
  read -p "Deploy anyway? [y/N] " FORCE
  [[ "$FORCE" =~ ^[Yy]$ ]] || { log "Cancelled"; exit 0; }
fi

# Verify build passes
log "Verifying npm run build..."
cd "$PROJECT_DIR"
if [ -f "package.json" ]; then
  if ! npm run build 2>&1 | tail -10; then
    fail "npm run build failed — fix the build before deploying"
  fi
  ok "Build verified"
fi

# Confirm with operator
echo ""
read -p "Deploy $PROJECT_ID to GitHub + Vercel? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled"; exit 0; }

# Run deployer agent
log "Running deployer agent..."

DEPLOYER_AGENT=$(cat "$FACTORY_DIR/agents/deployer.md" 2>/dev/null || echo "Deploy this project to GitHub and Vercel.")
PROJECT_NAME_FULL=$(get_project_field "$PROJECT_ID" ".name")

DEPLOYER_PROMPT="You are the deployer agent in the Micro-SaaS Factory pipeline.

PROJECT CONTEXT:
- Project ID: $PROJECT_ID
- Project Name: $PROJECT_NAME_FULL
- Project Directory: $PROJECT_DIR
- Factory Directory: $FACTORY_DIR
- GitHub Username: $(jq -r '.factory.github_username' "$PROJECTS_JSON")

YOUR AGENT DEFINITION:
$DEPLOYER_AGENT

INSTRUCTIONS:
You are in the directory: $PROJECT_DIR
Deploy this project: create/push GitHub repo, deploy to Vercel.
After deployment, write the deployed URL to a file: $PROJECT_DIR/.deployed-url"

DEPLOY_LOG="$LOG_DIR/${PROJECT_ID}-deploy-$(date +%Y%m%d-%H%M%S).log"

timeout 1800 claude \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$PROJECT_DIR" \
  --add-dir "$FACTORY_DIR" \
  -p "$DEPLOYER_PROMPT" 2>&1 | tee -a "$DEPLOY_LOG"

EXIT_CODE="${PIPESTATUS[0]}"

if [ "$EXIT_CODE" -ne 0 ]; then
  warn "Deployer agent exited with code $EXIT_CODE"
  warn "Check log: $DEPLOY_LOG"
  exit 1
fi

# Read deployed URL if written
DEPLOYED_URL=""
if [ -f "$PROJECT_DIR/.deployed-url" ]; then
  DEPLOYED_URL=$(cat "$PROJECT_DIR/.deployed-url" | tr -d '[:space:]')
fi

# Update projects.json
update_project_field "$PROJECT_ID" ".status" '"live"'
update_project_field "$PROJECT_ID" ".deployed_at" "\"$(date +%Y-%m-%d)\""
if [ -n "$DEPLOYED_URL" ]; then
  update_project_field "$PROJECT_ID" ".live_url" "\"$DEPLOYED_URL\""
fi

echo -e "\n${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                 DEPLOYMENT COMPLETE                     ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Project: ${GREEN}$PROJECT_NAME_FULL${NC}"
echo -e "${BOLD}║${NC}  Status:  ${GREEN}live${NC}"
if [ -n "$DEPLOYED_URL" ]; then
  echo -e "${BOLD}║${NC}  URL:     ${BLUE}$DEPLOYED_URL${NC}"
fi
echo -e "${BOLD}║${NC}  Log:     ${BLUE}$DEPLOY_LOG${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}\n"
