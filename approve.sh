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

FORCE_YES=false
for arg in "$@"; do [ "$arg" = "--yes" ] && FORCE_YES=true; done

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
  if [ "$FORCE_YES" = true ]; then
    warn "Proceeding anyway (--yes flag)"
  else
    read -p "Deploy anyway? [y/N] " FORCE
    [[ "$FORCE" =~ ^[Yy]$ ]] || { log "Cancelled"; exit 0; }
  fi
fi

log "Build previously verified by build-project.sh — skipping re-build"

# Confirm with operator
echo ""
if [ "$FORCE_YES" = false ]; then
  read -p "Deploy $PROJECT_ID to GitHub + Vercel? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled"; exit 0; }
fi

# Run deployer agent
log "Running deployer agent..."
DEPLOY_ISSUE_ID=$(get_project_field "$PROJECT_ID" ".linear.deploy_issue_id // empty")
LINEAR_PROJECT_ID=$(get_project_field "$PROJECT_ID" ".linear.project_id // empty")
linear_update_state "$DEPLOY_ISSUE_ID" "In Progress" || true
linear_post_update "$LINEAR_PROJECT_ID" "🚀 **Deploying** to GitHub + Vercel...\n\nDeployer agent running." "onTrack" || true

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

unset CLAUDECODE
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
  notify "⚠️ Foundry — Deploy Failed" "$PROJECT_ID deployer agent failed. Check: $DEPLOY_LOG" "urgent"
  emit_event "deploy_failed" "project_id=$PROJECT_ID" "project_name=$PROJECT_NAME"
  append_history "💥" "DEPLOY_FAIL" "$PROJECT_NAME — deployer agent failed"
  linear_update_state "$DEPLOY_ISSUE_ID" "In Review" || true
  linear_add_comment "$DEPLOY_ISSUE_ID" "💥 Deploy failed — check log: \`$DEPLOY_LOG\`" || true
  linear_post_update "$LINEAR_PROJECT_ID" "💥 **Deploy failed**\n\nDeployer agent exited with error.\n**Log:** \`${DEPLOY_LOG}\`\n**Retry:** \`./approve.sh ${PROJECT_ID}\`" "offTrack" || true
  exit 1
fi

# Read deployed URL if written
DEPLOYED_URL=""
if [ -f "$PROJECT_DIR/.deployed-url" ]; then
  DEPLOYED_URL=$(cat "$PROJECT_DIR/.deployed-url" | tr -d '[:space:]')
fi

# Post-deploy HTTP smoke test
if [ -n "$DEPLOYED_URL" ]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$DEPLOYED_URL" 2>/dev/null || echo "000")
  if [ "$HTTP_STATUS" = "200" ]; then
    ok "Post-deploy smoke test: $DEPLOYED_URL → HTTP $HTTP_STATUS ✓"
  else
    warn "Post-deploy smoke test: $DEPLOYED_URL returned HTTP $HTTP_STATUS — deployment may be broken"
    warn "Do not assume the site is working. Check manually before marking live."
  fi
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

DISPLAY_NAME=$(echo "$PROJECT_NAME_FULL" | sed 's/PROJECT-[0-9]* — //')
REPO_URL=$(get_project_field "$PROJECT_ID" ".repo")
if [ -n "$DEPLOYED_URL" ]; then
  notify "Foundry — Live 🚀" "$DISPLAY_NAME is deployed. $DEPLOYED_URL"
else
  notify "Foundry — Live 🚀" "$DISPLAY_NAME is deployed to Vercel."
fi
emit_event "deployed" "project_id=$PROJECT_ID" "project_name=$DISPLAY_NAME" "url=${DEPLOYED_URL:-unknown}" "repo=${REPO_URL:-unknown}"
append_history "🚀" "LIVE" "$DISPLAY_NAME → ${DEPLOYED_URL:-unknown}"

# Linear: Deploy → Done, complete project, add live URL comment
linear_update_state "$DEPLOY_ISSUE_ID" "Done" || true
linear_complete_project "$LINEAR_PROJECT_ID" || true
_LINEAR_COMMENT="🚀 **Live!**"
[ -n "$DEPLOYED_URL" ] && _LINEAR_COMMENT="$_LINEAR_COMMENT\n\n**URL:** $DEPLOYED_URL"
[ -n "$REPO_URL" ] && _LINEAR_COMMENT="$_LINEAR_COMMENT\n**Repo:** $REPO_URL"
linear_add_comment "$DEPLOY_ISSUE_ID" "$_LINEAR_COMMENT" || true

_DEPLOY_UPDATE="🚀 **Live!**"
[ -n "$DEPLOYED_URL" ] && _DEPLOY_UPDATE="${_DEPLOY_UPDATE}\n\n**URL:** ${DEPLOYED_URL}"
[ -n "$REPO_URL" ] && _DEPLOY_UPDATE="${_DEPLOY_UPDATE}\n**Repo:** ${REPO_URL}"
_DEPLOY_UPDATE="${_DEPLOY_UPDATE}\n**Deployed:** $(date +%Y-%m-%d)"
linear_post_update "$LINEAR_PROJECT_ID" "$_DEPLOY_UPDATE" "onTrack" || true

# Add resource links to project sidebar
[ -n "$DEPLOYED_URL" ] && linear_add_project_link "$LINEAR_PROJECT_ID" "$DEPLOYED_URL" "🌐 Live App" || true
[ -n "$REPO_URL" ] && linear_add_project_link "$LINEAR_PROJECT_ID" "$REPO_URL" "🐙 GitHub Repo" || true

# Update project description to reflect live status
_LIVE_DESC="${DISPLAY_NAME}\n\n**Status:** Live 🟢\n**Deployed:** $(date +%Y-%m-%d)"
[ -n "$DEPLOYED_URL" ] && _LIVE_DESC="${_LIVE_DESC}\n**Live URL:** ${DEPLOYED_URL}"
[ -n "$REPO_URL" ] && _LIVE_DESC="${_LIVE_DESC}\n**Repo:** ${REPO_URL}"
linear_set_description "$LINEAR_PROJECT_ID" "$_LIVE_DESC" || true
