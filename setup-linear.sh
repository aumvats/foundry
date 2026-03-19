#!/bin/bash
# ============================================================================
# setup-linear.sh — One-time Linear workspace configuration
# ============================================================================
# Run once to connect Foundry to your Linear workspace.
# Writes foundry/lib/linear-config.sh with team IDs, state IDs, label IDs.
#
# Usage: ./setup-linear.sh
# ============================================================================

set -e

export PATH="/opt/homebrew/bin:$PATH"

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
CONFIG_FILE="$FACTORY_DIR/lib/linear-config.sh"
LINEAR_API="https://api.linear.app/graphql"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[setup-linear]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }

gql() {
  local key="$1"
  local payload="$2"
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: $key" \
    --max-time 15 \
    -d "$payload" \
    "$LINEAR_API" 2>/dev/null
}

echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Foundry × Linear — Setup${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}\n"

# ── STEP 1: API KEY ──────────────────────────────────────────────────────────
echo "1. Go to: https://linear.app → Settings → API → Personal API Keys"
echo "   Create a key with full access."
echo ""
read -p "Paste your Linear API key: " LINEAR_API_KEY
echo ""
[ -z "$LINEAR_API_KEY" ] && fail "No API key provided"

# Verify key works
log "Verifying API key..."
ME=$(gql "$LINEAR_API_KEY" '{"query": "{ viewer { id name email } }"}')
ME_NAME=$(echo "$ME" | jq -r '.data.viewer.name // empty' 2>/dev/null)
[ -z "$ME_NAME" ] && fail "API key invalid or request failed. Response: $ME"
ok "Authenticated as: $ME_NAME"

# ── STEP 2: PICK TEAM ────────────────────────────────────────────────────────
log "Fetching teams..."
TEAMS_RESP=$(gql "$LINEAR_API_KEY" '{"query": "{ teams { nodes { id name key } } }"}')
TEAMS=$(echo "$TEAMS_RESP" | jq -r '.data.teams.nodes[] | "\(.key)  \(.name)  [\(.id)]"' 2>/dev/null)

if [ -z "$TEAMS" ]; then
  warn "No teams found. Create a team in Linear first (Settings → Teams → Add team)."
  fail "No teams available"
fi

echo ""
echo "Available teams:"
echo "$TEAMS" | nl -w2 -s". "
echo ""
read -p "Enter team number (or paste team ID directly): " TEAM_INPUT

# Check if it's a number or a UUID
if [[ "$TEAM_INPUT" =~ ^[0-9]+$ ]]; then
  TEAM_LINE=$(echo "$TEAMS" | sed -n "${TEAM_INPUT}p")
  LINEAR_TEAM_ID=$(echo "$TEAM_LINE" | grep -oE '\[[a-f0-9-]{36}\]' | tr -d '[]')
  LINEAR_TEAM_KEY=$(echo "$TEAM_LINE" | awk '{print $1}')
else
  # Direct UUID input
  LINEAR_TEAM_ID="$TEAM_INPUT"
  LINEAR_TEAM_KEY=$(echo "$TEAMS_RESP" | jq -r --arg id "$TEAM_INPUT" '.data.teams.nodes[] | select(.id == $id) | .key' 2>/dev/null || echo "FND")
fi

[ -z "$LINEAR_TEAM_ID" ] && fail "Could not determine team ID"
ok "Team: $LINEAR_TEAM_KEY ($LINEAR_TEAM_ID)"

# ── STEP 3: WORKFLOW STATES ──────────────────────────────────────────────────
log "Fetching workflow states for team $LINEAR_TEAM_KEY..."
STATES_PAYLOAD=$(jq -n --arg teamId "$LINEAR_TEAM_ID" \
  '{"query": "query($teamId: ID!) { workflowStates(filter: {team: {id: {eq: $teamId}}}) { nodes { id name type } } }", "variables": {"teamId": $teamId}}')
STATES_RESP=$(gql "$LINEAR_API_KEY" "$STATES_PAYLOAD")

echo ""
echo "Available workflow states:"
echo "$STATES_RESP" | jq -r '.data.workflowStates.nodes[] | "  \(.type)\t\(.name)\t[\(.id)]"' 2>/dev/null | sort
echo ""

# Auto-map standard Linear state names
_get_state() {
  local name_pattern="$1"
  echo "$STATES_RESP" | jq -r --arg pat "$name_pattern" \
    '.data.workflowStates.nodes[] | select(.name | test($pat; "i")) | .id' 2>/dev/null | head -1
}

LINEAR_STATE_TODO=$(_get_state "^(todo|backlog)$")
LINEAR_STATE_IN_PROGRESS=$(_get_state "^in.?progress$")
LINEAR_STATE_IN_REVIEW=$(_get_state "^in.?review$")
LINEAR_STATE_DONE=$(_get_state "^done$")
LINEAR_STATE_CANCELLED=$(_get_state "^cancelled?$")

# Report and prompt for any missing
_require_state() {
  local var_name="$1"
  local display="$2"
  local current="${!var_name}"
  if [ -z "$current" ]; then
    warn "Could not auto-detect state: $display"
    echo "  Paste the state ID for '$display' (from the list above):"
    read -p "  > " current
    eval "$var_name=\"$current\""
  else
    ok "State '$display' → $current"
  fi
}

_require_state LINEAR_STATE_TODO "Todo"
_require_state LINEAR_STATE_IN_PROGRESS "In Progress"
_require_state LINEAR_STATE_IN_REVIEW "In Review"
_require_state LINEAR_STATE_DONE "Done"
_require_state LINEAR_STATE_CANCELLED "Cancelled"

# ── STEP 4: LABELS ───────────────────────────────────────────────────────────
log "Setting up labels (Spec, Build, Deploy)..."
LABELS_PAYLOAD=$(jq -n --arg teamId "$LINEAR_TEAM_ID" \
  '{"query": "query($teamId: ID!) { issueLabels(filter: {team: {id: {eq: $teamId}}}) { nodes { id name } } }", "variables": {"teamId": $teamId}}')
LABELS_RESP=$(gql "$LINEAR_API_KEY" "$LABELS_PAYLOAD")

_get_or_create_label() {
  local label_name="$1"
  local color="$2"

  # Try to find existing label
  local existing_id
  existing_id=$(echo "$LABELS_RESP" | jq -r --arg n "$label_name" \
    '.data.issueLabels.nodes[] | select(.name == $n) | .id' 2>/dev/null | head -1)

  if [ -n "$existing_id" ]; then
    ok "Label '$label_name' exists → $existing_id"
    echo "$existing_id"
    return
  fi

  # Create label
  local create_payload
  create_payload=$(jq -n \
    --arg teamId "$LINEAR_TEAM_ID" \
    --arg name "$label_name" \
    --arg color "$color" \
    '{"query": "mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id } } }", "variables": {"input": {"teamId": $teamId, "name": $name, "color": $color}}}')

  local create_resp
  create_resp=$(gql "$LINEAR_API_KEY" "$create_payload")
  local new_id
  new_id=$(echo "$create_resp" | jq -r '.data.issueLabelCreate.issueLabel.id // empty' 2>/dev/null)

  if [ -n "$new_id" ]; then
    ok "Label '$label_name' created → $new_id"
    echo "$new_id"
  else
    warn "Failed to create label '$label_name'. You can add it manually in Linear later."
    echo ""
  fi
}

LINEAR_LABEL_SPEC=$(_get_or_create_label "Spec" "#6366F1")
LINEAR_LABEL_BUILD=$(_get_or_create_label "Build" "#F59E0B")
LINEAR_LABEL_DEPLOY=$(_get_or_create_label "Deploy" "#10B981")

# ── STEP 5: WRITE CONFIG ─────────────────────────────────────────────────────
log "Writing config to $CONFIG_FILE..."
cat > "$CONFIG_FILE" << EOF
# ============================================================================
# lib/linear-config.sh — Linear API Configuration
# Generated by setup-linear.sh on $(date)
# DO NOT EDIT MANUALLY — re-run ./setup-linear.sh to reconfigure
# ============================================================================

LINEAR_API_KEY="$LINEAR_API_KEY"
LINEAR_TEAM_ID="$LINEAR_TEAM_ID"
LINEAR_TEAM_KEY="$LINEAR_TEAM_KEY"

# Workflow state UUIDs
LINEAR_STATE_TODO="$LINEAR_STATE_TODO"
LINEAR_STATE_IN_PROGRESS="$LINEAR_STATE_IN_PROGRESS"
LINEAR_STATE_IN_REVIEW="$LINEAR_STATE_IN_REVIEW"
LINEAR_STATE_DONE="$LINEAR_STATE_DONE"
LINEAR_STATE_CANCELLED="$LINEAR_STATE_CANCELLED"

# Label UUIDs
LINEAR_LABEL_SPEC="$LINEAR_LABEL_SPEC"
LINEAR_LABEL_BUILD="$LINEAR_LABEL_BUILD"
LINEAR_LABEL_DEPLOY="$LINEAR_LABEL_DEPLOY"
EOF

chmod 600 "$CONFIG_FILE"  # Protect API key

# ── STEP 6: SMOKE TEST ───────────────────────────────────────────────────────
log "Running smoke test — creating a test issue..."

source "$CONFIG_FILE"
source "$FACTORY_DIR/lib/linear.sh"

TEST_ID=$(linear_create_issue "Foundry — Linear integration test" "This issue was created by setup-linear.sh to verify the integration. You can delete it." "Todo" "Spec")

if [ -n "$TEST_ID" ]; then
  ok "Test issue created: $TEST_ID"
  # Clean up — cancel the test issue
  linear_update_state "$TEST_ID" "Cancelled"
  ok "Test issue cancelled (cleanup done)"
else
  warn "Smoke test issue creation failed — check your API key and team permissions"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Linear integration configured ✓               ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Team:    ${GREEN}$LINEAR_TEAM_KEY ($LINEAR_TEAM_ID)${NC}"
echo -e "${BOLD}║${NC}  Config:  ${BLUE}lib/linear-config.sh${NC}"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  The pipeline will now create Linear issues for every"
echo -e "${BOLD}║${NC}  project as it moves through Spec → Build → Deploy."
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
