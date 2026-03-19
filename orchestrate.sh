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

# Allow nested claude invocations (CLAUDECODE blocks them when run inside Claude Code)
unset CLAUDECODE

# Ensure Homebrew tools (flock, timeout) are in PATH for cron
export PATH="/opt/homebrew/bin:$PATH"

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

BUILD_RUN_LOG="$LOG_DIR/build-run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$BUILD_RUN_LOG") 2>&1
ls -t "$LOG_DIR"/build-run-*.log 2>/dev/null | tail -n +15 | xargs rm -f 2>/dev/null || true

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
  notify "⚠️ Foundry — Auth Failed" "Claude CLI auth check failed. Build pipeline aborted." "urgent"
  fail "Claude CLI auth check failed"
fi

# Dependency check
for dep in jq gh node npm; do
  command -v "$dep" >/dev/null 2>&1 || fail "Missing dependency: $dep"
done

ok "Pre-flight checks passed"

# ── STALE PROJECT SCAN ────────────────────────────────────────────────────────
CUTOFF=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null)
STALE=$(jq -r --arg cutoff "$CUTOFF" '
  .projects[] |
  select(.status == "needs_review" or .status == "needs_spec_revision") |
  select(.created_at <= $cutoff) |
  .id
' "$PROJECTS_JSON" 2>/dev/null)
if [ -n "$STALE" ]; then
  STALE_NAMES=$(echo "$STALE" | while read -r sid; do get_project_field "$sid" ".name"; done | tr '\n' ', ' | sed 's/,$//')
  warn "Stale projects (>7 days in stuck state): $STALE_NAMES"
  notify "⚠️ Foundry — Stale Projects" "Projects stuck >7 days: $STALE_NAMES" "urgent"
fi

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
  emit_event "build_run_started" "projects=$(echo "$PROJECTS_TO_BUILD" | tr '\n' ',' | sed 's/,$//')"
fi

# ── RUN BUILD PIPELINE ───────────────────────────────────────────────────────
BUILT_COUNT=0
FAILED_COUNT=0

# ── RETRY STUCK DEPLOYS ───────────────────────────────────────────────────────
STUCK_BUILT=$(projects_by_status "built")
if [ -n "$STUCK_BUILT" ]; then
  log "Found projects stuck in 'built' — retrying deploy..."
  while IFS= read -r stuck_id; do
    [ -z "$stuck_id" ] && continue
    log "Retrying deploy for $stuck_id"
    if "$FACTORY_DIR/approve.sh" "$stuck_id" --yes; then
      ok "$stuck_id deployed on retry"
    else
      warn "$stuck_id deploy retry failed — check logs"
    fi
  done <<< "$STUCK_BUILT"
fi

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
    ok "$project_id build complete → auto-deploying"
    BUILT_COUNT=$((BUILT_COUNT + 1))
    # Auto-deploy: no manual approval needed if build passed
    if "$FACTORY_DIR/approve.sh" "$project_id" --yes; then
      ok "$project_id deployed successfully"
    else
      warn "$project_id deploy failed — project is built, retry: ./approve.sh $project_id"
      notify "⚠️ Foundry — Deploy Failed" "$project_id built but deploy failed. Run: ./approve.sh $project_id" "urgent"
    fi
  else
    warn "$project_id build failed or paused"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    notify "⚠️ Foundry — Build Paused" "$project_id pipeline paused. Run: ./build-project.sh $project_id --resume-from <agent>" "urgent"
  fi

done <<< "$PROJECTS_TO_BUILD"

# ── POST-RUN REPORT ───────────────────────────────────────────────────────────
echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
log "Run complete: $BUILT_COUNT built, $FAILED_COUNT failed/paused"
emit_event "build_run_complete" "built=$BUILT_COUNT" "failed=$FAILED_COUNT"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}\n"

REPORT_FILE=$(generate_daily_report)
ok "Daily report written: $REPORT_FILE"

SUMMARY_FILE=$(generate_history_summary)
ok "History summary written: $SUMMARY_FILE"

# Compose deploy queue for notification
DEPLOY_QUEUE=$(jq -r '[.projects[] | select(.status=="built") | .name] | join(", ")' "$PROJECTS_JSON" 2>/dev/null | sed 's/PROJECT-[0-9]* — //g' | cut -c1-80)
if [ "$FAILED_COUNT" -eq 0 ]; then
  notify "Foundry — Builds Complete ✅" "$BUILT_COUNT built. Ready to deploy: $DEPLOY_QUEUE" 
else
  notify "⚠️ Foundry — Run Done (issues)" "$BUILT_COUNT built, $FAILED_COUNT failed/paused. Check dashboard." "urgent"
fi

cat "$REPORT_FILE"
