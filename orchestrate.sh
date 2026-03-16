#!/bin/bash
# ============================================================================
# orchestrate.sh — Build Pipeline Orchestrator
# ============================================================================
# Picks up all "queued" projects from projects.json and runs the build
# pipeline (build-project.sh) on each one in sequence.
# Generates daily report and history summary at end of run.
#
# Usage: ./orchestrate.sh [--project <id>]
#   --project <id>   Build a specific project only (ignores queued status)
#
# Cron: 03 12 * * * cd ~/Code/exploratory/foundry && ./orchestrate.sh >> logs/cron.log 2>&1
# ============================================================================

set -e

# ── CONFIG ───────────────────────────────────────────────────────────────────
ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
CRON_LOCK="$FACTORY_DIR/.orchestrate.lock"

source "$FACTORY_DIR/lib/state.sh"
source "$FACTORY_DIR/lib/report.sh"

mkdir -p "$LOG_DIR"

# ── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[orchestrate]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }

# ── CONCURRENT EXECUTION GUARD ───────────────────────────────────────────────
exec 201>"$CRON_LOCK"
if ! flock -n 201; then
  log "orchestrate.sh already running, exiting"
  exit 0
fi

# ── PARSE ARGS ───────────────────────────────────────────────────────────────
SPECIFIC_PROJECT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) SPECIFIC_PROJECT="$2"; shift 2 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

# ── PRE-FLIGHT CHECKS ────────────────────────────────────────────────────────
log "Pre-flight checks..."

# Auth check
if ! claude --print -p "echo AUTHCHECK" 2>&1 | grep -q "AUTHCHECK"; then
  echo "AUTH FAILED $(date)" >> "$LOG_DIR/alerts.log"
  fail "Claude CLI auth check failed"
fi

# Dependency check
for dep in jq gh node npm; do
  command -v "$dep" >/dev/null 2>&1 || fail "Missing dependency: $dep"
done

ok "Pre-flight checks passed"

# ── DETERMINE PROJECTS TO BUILD ───────────────────────────────────────────────
if [ -n "$SPECIFIC_PROJECT" ]; then
  PROJECTS_TO_BUILD="$SPECIFIC_PROJECT"
  log "Building specific project: $SPECIFIC_PROJECT"
else
  PROJECTS_TO_BUILD=$(projects_by_status "queued")
  if [ -z "$PROJECTS_TO_BUILD" ]; then
    log "No queued projects to build"
    REPORT_FILE=$(generate_daily_report)
    log "Daily report: $REPORT_FILE"
    generate_history_summary > /dev/null
    exit 0
  fi
  log "Queued projects: $(echo "$PROJECTS_TO_BUILD" | tr '\n' ' ')"
fi

# ── RUN BUILD PIPELINE ───────────────────────────────────────────────────────
BUILT_COUNT=0
FAILED_COUNT=0

while IFS= read -r project_id; do
  [ -z "$project_id" ] && continue

  echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
  log "Building: $project_id"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"

  # Check build_attempts before starting
  # --project flag bypasses the attempts gate (operator knows what they're doing)
  current_attempts=$(get_project_field "$project_id" ".build_attempts // 0")
  if [ "$current_attempts" -ge 2 ] && [ -z "$SPECIFIC_PROJECT" ]; then
    warn "$project_id has already failed $current_attempts build attempts — marking needs_spec_revision"
    warn "To force a retry: ./orchestrate.sh --project $project_id"
    update_project_field "$project_id" ".status" '"needs_spec_revision"'
    echo "$(date): $project_id skipped after $current_attempts failed attempts" >> "$LOG_DIR/alerts.log"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  elif [ "$current_attempts" -ge 2 ] && [ -n "$SPECIFIC_PROJECT" ]; then
    log "Operator-forced retry for $project_id (previous attempts: $current_attempts) — resetting counter"
    write_projects_json "(.projects[] | select(.id == \"$project_id\") | .build_attempts) = 0"
    write_projects_json "(.projects[] | select(.id == \"$project_id\") | .status) = \"queued\""
    current_attempts=0
  fi

  # Increment build_attempts
  write_projects_json "(.projects[] | select(.id == \"$project_id\") | .build_attempts) += 1"

  # Run build pipeline
  if "$FACTORY_DIR/build-project.sh" "$project_id"; then
    ok "$project_id build complete → status: built"
    BUILT_COUNT=$((BUILT_COUNT + 1))
  else
    warn "$project_id build failed or paused"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi

done <<< "$PROJECTS_TO_BUILD"

# ── POST-RUN REPORT ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
log "Run complete: $BUILT_COUNT built, $FAILED_COUNT failed/paused"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}\n"

REPORT_FILE=$(generate_daily_report)
ok "Daily report written: $REPORT_FILE"

SUMMARY_FILE=$(generate_history_summary)
ok "History summary written: $SUMMARY_FILE"

cat "$REPORT_FILE"
