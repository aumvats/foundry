#!/bin/bash
# ============================================================================
# Foundry — Status Dashboard
# ============================================================================
# Quick overview of all projects and pipeline state.
#
# Usage:
#   ./status.sh              # Full dashboard
#   ./status.sh <project-id> # Detailed view for one project
# ============================================================================

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
STATE_DIR="$FACTORY_DIR/state"
LOG_DIR="$FACTORY_DIR/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# ── SINGLE PROJECT DETAIL VIEW ──────────────────────────────────────────────
if [ -n "$1" ]; then
  PROJECT_ID="$1"
  STATE_FILE="$STATE_DIR/${PROJECT_ID}-state.json"

  PROJECT_NAME=$(jq -r ".projects[] | select(.id == \"$PROJECT_ID\") | .name" "$PROJECTS_JSON" 2>/dev/null || echo "$PROJECT_ID")
  PROJECT_STATUS=$(jq -r ".projects[] | select(.id == \"$PROJECT_ID\") | .status" "$PROJECTS_JSON" 2>/dev/null || echo "unknown")

  echo -e "\n${BOLD}${PURPLE}$PROJECT_NAME${NC} ${DIM}($PROJECT_ID)${NC}"
  echo -e "${DIM}$(printf '%.0s─' {1..50})${NC}"

  # Project metadata
  TAGLINE=$(jq -r ".projects[] | select(.id == \"$PROJECT_ID\") | .tagline" "$PROJECTS_JSON" 2>/dev/null)
  REPO=$(jq -r ".projects[] | select(.id == \"$PROJECT_ID\") | .repo" "$PROJECTS_JSON" 2>/dev/null)
  LIVE_URL=$(jq -r ".projects[] | select(.id == \"$PROJECT_ID\") | .live_url" "$PROJECTS_JSON" 2>/dev/null)

  echo -e "  ${GRAY}Tagline:${NC}  $TAGLINE"
  echo -e "  ${GRAY}Status:${NC}   $PROJECT_STATUS"
  [ -n "$REPO" ] && [ "$REPO" != "" ] && echo -e "  ${GRAY}Repo:${NC}     ${BLUE}$REPO${NC}"
  [ -n "$LIVE_URL" ] && [ "$LIVE_URL" != "" ] && echo -e "  ${GRAY}Live:${NC}     ${GREEN}$LIVE_URL${NC}"

  # Pipeline state
  if [ -f "$STATE_FILE" ]; then
    echo -e "\n  ${BOLD}Pipeline State${NC}"

    PIPELINE_STATUS=$(jq -r '.status' "$STATE_FILE")
    CURRENT_STEP=$(jq -r '.current_step' "$STATE_FILE")
    PAUSED=$(jq -r '.paused' "$STATE_FILE")
    PAUSE_REASON=$(jq -r '.pause_reason' "$STATE_FILE")
    STARTED=$(jq -r '.pipeline_started_at // .started_at // "unknown"' "$STATE_FILE")

    echo -e "  ${GRAY}Pipeline:${NC}  $PIPELINE_STATUS"
    echo -e "  ${GRAY}Current:${NC}   $CURRENT_STEP"
    echo -e "  ${GRAY}Started:${NC}   $STARTED"

    if [ "$PAUSED" = "true" ]; then
      echo -e "  ${YELLOW}⏸️  Paused:${NC}  $PAUSE_REASON"
    fi

    echo ""

    AGENTS=("planner" "builder" "qa" "designer" "optimizer" "deployer")
    for agent in "${AGENTS[@]}"; do
      STEP_STATUS=$(jq -r ".steps.\"$agent\".status // \"pending\"" "$STATE_FILE")
      DURATION=$(jq -r ".steps.\"$agent\".duration // .steps.\"$agent\".duration_seconds // \"\"" "$STATE_FILE")
      RETRIES=$(jq -r ".steps.\"$agent\".retries // 0" "$STATE_FILE")

      case "$STEP_STATUS" in
        complete)     ICON="${GREEN}✅${NC}" ;;
        in_progress)  ICON="${YELLOW}🔨${NC}" ;;
        failed)       ICON="${RED}❌${NC}" ;;
        pending)      ICON="${GRAY}○${NC}"  ;;
        awaiting_approval) ICON="${YELLOW}🟡${NC}" ;;
        *)            ICON="${GRAY}?${NC}"  ;;
      esac

      DETAIL=""
      [ -n "$DURATION" ] && [ "$DURATION" != "" ] && [ "$DURATION" != "null" ] && DETAIL=" ${DIM}(${DURATION})${NC}"
      [ "$RETRIES" != "0" ] && [ "$RETRIES" != "null" ] && DETAIL="$DETAIL ${RED}retries: $RETRIES${NC}"

      printf "  %b  %-12s %s%b\n" "$ICON" "$agent" "$STEP_STATUS" "$DETAIL"
    done

    # Errors
    ERRORS=$(jq -r '.errors[]? // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$ERRORS" ]; then
      echo -e "\n  ${RED}${BOLD}Errors:${NC}"
      echo "$ERRORS" | while read -r err; do
        echo -e "  ${RED}• $err${NC}"
      done
    fi
  else
    echo -e "\n  ${GRAY}No pipeline state found. Project hasn't been through the pipeline yet.${NC}"
  fi

  # Check for agent report files
  PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"
  if [ -d "$PROJECT_DIR" ]; then
    echo -e "\n  ${BOLD}Agent Reports${NC}"
    for report in IMPLEMENTATION-PLAN.md BUILDER-NOTES.md QA-REPORT.md DESIGN-NOTES.md OPTIMIZER-NOTES.md DEPLOY-NOTES.md; do
      if [ -f "$PROJECT_DIR/$report" ]; then
        MOD=$(stat -f "%Sm" -t "%b %d %H:%M" "$PROJECT_DIR/$report" 2>/dev/null || stat -c "%y" "$PROJECT_DIR/$report" 2>/dev/null | cut -d'.' -f1)
        echo -e "  ${GREEN}✓${NC} $report ${DIM}($MOD)${NC}"
      else
        echo -e "  ${GRAY}○ $report${NC}"
      fi
    done
  fi

  echo ""
  exit 0
fi

# ── FULL DASHBOARD ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}${PURPLE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${PURPLE}║           Foundry — Status               ║${NC}"
echo -e "${BOLD}${PURPLE}╚══════════════════════════════════════════╝${NC}\n"

# Stats
TOTAL=$(jq '.projects | length' "$PROJECTS_JSON")
LIVE=$(jq '[.projects[] | select(.status == "live")] | length' "$PROJECTS_JSON")
BUILT=$(jq '[.projects[] | select(.status == "built")] | length' "$PROJECTS_JSON")
BUILDING=$(jq '[.projects[] | select(.status == "building")] | length' "$PROJECTS_JSON")
QUEUED=$(jq '[.projects[] | select(.status == "queued")] | length' "$PROJECTS_JSON")
PAUSED=$(jq '[.projects[] | select(.status == "paused")] | length' "$PROJECTS_JSON")

echo -e "  ${BOLD}$TOTAL${NC} projects  │  ${GREEN}$LIVE live${NC}  │  ${BLUE}$BUILT built${NC}  │  ${YELLOW}$BUILDING building${NC}  │  ${GRAY}$QUEUED queued${NC}  │  ${YELLOW}$PAUSED paused${NC}"
echo -e "${DIM}  $(printf '%.0s─' {1..70})${NC}"

# Project list
jq -r '.projects[] | "\(.id)|\(.name)|\(.status)|\(.tagline)|\(.live_url)|\(.repo)"' "$PROJECTS_JSON" | while IFS='|' read -r id name status tagline live_url repo; do
  case "$status" in
    live)     ICON="${GREEN}●${NC}"; STATUS_COLOR="${GREEN}" ;;
    built)    ICON="${BLUE}●${NC}"; STATUS_COLOR="${BLUE}" ;;
    building) ICON="${YELLOW}●${NC}"; STATUS_COLOR="${YELLOW}" ;;
    queued)   ICON="${GRAY}○${NC}"; STATUS_COLOR="${GRAY}" ;;
    paused)   ICON="${YELLOW}⏸${NC}"; STATUS_COLOR="${YELLOW}" ;;
    failed)   ICON="${RED}●${NC}"; STATUS_COLOR="${RED}" ;;
    *)        ICON="${GRAY}?${NC}"; STATUS_COLOR="${GRAY}" ;;
  esac

  echo -e "\n  ${ICON} ${BOLD}$name${NC}  ${STATUS_COLOR}$status${NC}"
  echo -e "    ${DIM}$tagline${NC}"

  # Show URLs if deployed
  [ -n "$live_url" ] && [ "$live_url" != "" ] && echo -e "    ${GREEN}$live_url${NC}"

  # Show pipeline progress if state file exists
  STATE_FILE="$STATE_DIR/${id}-state.json"
  if [ -f "$STATE_FILE" ]; then
    CURRENT=$(jq -r '.current_step' "$STATE_FILE")
    P_STATUS=$(jq -r '.status' "$STATE_FILE")
    IS_PAUSED=$(jq -r '.paused' "$STATE_FILE")
    PAUSE_REASON=$(jq -r '.pause_reason' "$STATE_FILE")

    # Build progress bar
    AGENTS=("planner" "builder" "qa" "designer" "optimizer" "deployer")
    BAR=""
    for agent in "${AGENTS[@]}"; do
      STEP_STATUS=$(jq -r ".steps.\"$agent\".status // \"pending\"" "$STATE_FILE")
      case "$STEP_STATUS" in
        complete)     BAR="${BAR}${GREEN}█${NC}" ;;
        in_progress)  BAR="${BAR}${YELLOW}▓${NC}" ;;
        failed)       BAR="${BAR}${RED}█${NC}" ;;
        awaiting_approval) BAR="${BAR}${YELLOW}▒${NC}" ;;
        *)            BAR="${BAR}${GRAY}░${NC}" ;;
      esac
    done
    echo -e "    Pipeline: ${BAR}  ${DIM}($CURRENT)${NC}"

    if [ "$IS_PAUSED" = "true" ]; then
      echo -e "    ${YELLOW}⏸️  $PAUSE_REASON${NC}"
    fi
  fi
done

# Queue
QUEUE_COUNT=$(jq '.queue | length' "$PROJECTS_JSON")
if [ "$QUEUE_COUNT" -gt 0 ]; then
  echo -e "\n${DIM}  $(printf '%.0s─' {1..70})${NC}"
  echo -e "  ${BOLD}Queue${NC} ($QUEUE_COUNT pending)"
  jq -r '.queue[] | "  ○ \(.name // .id) — \(.tagline // "no tagline")"' "$PROJECTS_JSON"
fi

# Latest daily report
LATEST_REPORT=$(ls -t "$LOG_DIR"/daily-report-*.md 2>/dev/null | head -1)
if [ -n "$LATEST_REPORT" ]; then
  REPORT_DATE=$(basename "$LATEST_REPORT" | sed 's/daily-report-//' | sed 's/.md//')
  echo -e "\n${DIM}  $(printf '%.0s─' {1..70})${NC}"
  echo -e "  ${GRAY}Latest report: $REPORT_DATE${NC}  ${DIM}(cat $LATEST_REPORT)${NC}"
fi

# Cron status
CRON_COUNT=$(crontab -l 2>/dev/null | grep -c foundry)
if [ "$CRON_COUNT" -gt 0 ]; then
  echo -e "  ${GRAY}Cron: $CRON_COUNT scheduled jobs active${NC}"
  crontab -l 2>/dev/null | grep foundry | while read -r line; do
    TIME=$(echo "$line" | awk '{
      m=$1; h=$2; dow=$5;
      ampm="AM"; if (h+0 >= 12) { ampm="PM"; if (h+0 > 12) h=h-12 }
      if (h+0 == 0) h=12;
      printf "%s:%02d %s", h, m, ampm
    }')
    CMD=$(echo "$line" | sed 's/.*&& //' | sed 's/ >>.*$//')
    echo -e "    ${DIM}$TIME — $CMD${NC}"
  done
else
  echo -e "  ${YELLOW}Cron: not configured${NC}"
fi

echo ""
