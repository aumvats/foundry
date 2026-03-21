#!/bin/bash
# ============================================================================
# parallel-pipeline.sh — Full Parallel Pipeline Pilot
# ============================================================================
# One-time E2E pilot: spec generation → build → deploy, all in parallel.
#
# Phase 1 (sequential): ./create-spec.sh --count 3
#   — generates 3 new specs one at a time (~9min each, ~27min total)
#   — new project IDs are captured via before/after snapshot of projects.json
#   — new IDs immediately set to parallel_queued to prevent orchestrator pickup
#
# Phase 2 (parallel): build + deploy
#   — ClimateDrift (project-1773988092, already parallel_queued) added to list
#   — all 4 projects spawn simultaneously: build-project.sh && approve.sh --yes
#   — each project's E2E ~81min, all 4 finish in ~81min total
#
# Safety:
#   — Refuses if orchestrate.sh, create-spec.sh, or build-project.sh is running
#     (both flock check AND ps aux process check)
#   — Does NOT restore status to queued before spawning (avoids collision)
#   — Zero changes to existing scripts
#
# Usage: ./parallel-pipeline.sh [--count N]
#   --count N   Number of new specs to generate (default: 3)
# ============================================================================

set -e
unset CLAUDECODE

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
SPEC_LOCK="$FACTORY_DIR/.create-spec.lock"
ORCH_LOCK="$FACTORY_DIR/.orchestrate.lock"

CLIMATE_DRIFT_ID="project-1773988092"

source "$FACTORY_DIR/lib/state.sh"

mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[pipeline]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }
info() { echo -e "${CYAN}[  ·  ]${NC} $1"; }

RUN_TS=$(date +%Y%m%d-%H%M%S)

# ── PARSE FLAGS ───────────────────────────────────────────────────────────────
SPEC_COUNT=3
for arg in "$@"; do
  case "$arg" in
    --count) SPEC_COUNT="${2:-3}" ;;
  esac
done

# ── HEADER ────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Foundry — Parallel Pipeline Pilot  [${RUN_TS}]${NC}"
echo -e "${BOLD}  Phase 1: ${SPEC_COUNT} new specs (sequential)${NC}"
echo -e "${BOLD}  Phase 2: build + deploy all in parallel${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

# ── GUARD: Check for any active conflicting processes ─────────────────────────
log "Safety checks..."

# flock check — orchestrate.sh
if ! flock -n "$ORCH_LOCK" true 2>/dev/null; then
  fail "orchestrate.sh is currently running (flock held). Wait for it to finish first."
fi

# flock check — create-spec.sh
if ! flock -n "$SPEC_LOCK" true 2>/dev/null; then
  fail "create-spec.sh is currently running (flock held). Wait for it to finish first."
fi

# ps aux check — any build-project.sh process
if pgrep -f "build-project.sh" > /dev/null 2>&1; then
  fail "build-project.sh is currently running. Wait for active builds to finish first."
fi

# ps aux check — any orchestrate.sh process
if pgrep -f "orchestrate.sh" > /dev/null 2>&1; then
  fail "orchestrate.sh process detected in ps aux. Wait for it to finish first."
fi

ok "No conflicting processes. Safe to proceed."
echo ""

# ── CHECK EXISTING PARALLEL_QUEUED COUNT ─────────────────────────────────────
EXISTING_PARALLEL=()
while IFS= read -r line; do
  [ -n "$line" ] && EXISTING_PARALLEL+=("$line")
done < <(jq -r '.projects[] | select(.status == "parallel_queued") | .id' "$PROJECTS_JSON" 2>/dev/null)

log "Already parallel_queued: ${#EXISTING_PARALLEL[@]} of ${SPEC_COUNT} needed"

# ── PHASE 1: SPEC GENERATION (skip if already have enough) ────────────────────
NEEDED=$(( SPEC_COUNT - ${#EXISTING_PARALLEL[@]} ))

if [ "$NEEDED" -le 0 ]; then
  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Phase 1: Skipped — already have ${#EXISTING_PARALLEL[@]} parallel_queued${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo ""
  ok "Sufficient specs already queued. Going straight to Phase 2."
  echo ""
else
  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Phase 1: Generating ${NEEDED} new spec(s) (need ${SPEC_COUNT}, have ${#EXISTING_PARALLEL[@]})${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo ""

  # Snapshot existing IDs so we can diff after
  EXISTING_IDS=()
  while IFS= read -r line; do
    [ -n "$line" ] && EXISTING_IDS+=("$line")
  done < <(jq -r '.projects[].id' "$PROJECTS_JSON" 2>/dev/null)

  log "Running: create-spec.sh --count ${NEEDED}"
  log "This will take ~$((NEEDED * 9)) minutes. Logs go to: $LOG_DIR/spec-run-*.log"
  echo ""

  bash "$FACTORY_DIR/create-spec.sh" --count "$NEEDED"
  SPEC_EXIT=$?

  if [ "$SPEC_EXIT" -ne 0 ]; then
    fail "create-spec.sh failed with exit code $SPEC_EXIT — aborting parallel pipeline."
  fi

  echo ""
  ok "Spec generation complete."
  echo ""

  # Find and withdraw new queued specs
  EXISTING_IDS_STR=$(printf '\n%s' "${EXISTING_IDS[@]}")
  log "Withdrawing new specs from sequential queue → parallel_queued..."
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      if ! echo "$EXISTING_IDS_STR" | grep -qxF "$line"; then
        update_project_field "$line" .status '"parallel_queued"'
        info "  $line → parallel_queued"
      fi
    fi
  done < <(jq -r '.projects[] | select(.status == "queued") | .id' "$PROJECTS_JSON" 2>/dev/null)
  echo ""
fi

# ── ASSEMBLE FULL PROJECT LIST (all parallel_queued, capped at SPEC_COUNT) ────
ALL_PROJECT_IDS=()
while IFS= read -r line; do
  [ -n "$line" ] && ALL_PROJECT_IDS+=("$line")
done < <(jq -r '.projects[] | select(.status == "parallel_queued") | .id' "$PROJECTS_JSON" 2>/dev/null)

# Cap at SPEC_COUNT — return extras to queued for sequential pipeline
if [ ${#ALL_PROJECT_IDS[@]} -gt "$SPEC_COUNT" ]; then
  warn "${#ALL_PROJECT_IDS[@]} parallel_queued found — capping at ${SPEC_COUNT}, returning extras to queued"
  i=0
  CAPPED=()
  for pid in "${ALL_PROJECT_IDS[@]}"; do
    if [ $i -lt "$SPEC_COUNT" ]; then
      CAPPED+=("$pid")
    else
      update_project_field "$pid" .status '"queued"'
      info "  $pid → returned to queued (sequential pipeline)"
    fi
    i=$(( i + 1 ))
  done
  ALL_PROJECT_IDS=("${CAPPED[@]}")
fi

if [ ${#ALL_PROJECT_IDS[@]} -eq 0 ]; then
  fail "No parallel_queued projects found. This should not happen."
fi

echo ""
log "Total projects for parallel build+deploy: ${#ALL_PROJECT_IDS[@]}"
for pid in "${ALL_PROJECT_IDS[@]}"; do
  name=$(get_project_field "$pid" ".name")
  info "  $pid — $name"
done
echo ""

# ── PHASE 2: PARALLEL BUILD + DEPLOY ─────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Phase 2: Parallel Build + Deploy  [$(date +%H:%M:%S)]${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

BG_PIDS=()
BG_PROJECT_IDS=()
START_TIMES=()

log "Spawning ${#ALL_PROJECT_IDS[@]} build+deploy jobs in background..."
echo ""

for pid in "${ALL_PROJECT_IDS[@]}"; do
  name=$(get_project_field "$pid" ".name")
  log_file="$LOG_DIR/${pid}-parallel-pilot-${RUN_TS}.log"

  info "Spawning: $pid ($name)"
  info "  Log: $log_file"

  # Spawn: build then auto-approve (no status restore — build-project.sh sets "building" directly)
  (
    bash "$FACTORY_DIR/build-project.sh" "$pid" && \
    bash "$FACTORY_DIR/approve.sh" "$pid" --yes
  ) >> "$log_file" 2>&1 &
  bg_pid=$!

  BG_PIDS+=("$bg_pid")
  BG_PROJECT_IDS+=("$pid")
  START_TIMES+=("$(date +%s)")

  echo ""
done

echo ""
log "All ${#ALL_PROJECT_IDS[@]} jobs spawned. E2E ~81min per project. Wall-clock: ~81min total."
echo ""
echo -e "${YELLOW}  Monitor with:${NC}"
for pid in "${ALL_PROJECT_IDS[@]}"; do
  echo "    tail -f $LOG_DIR/${pid}-parallel-pilot-${RUN_TS}.log"
done
echo ""

# ── WAIT AND COLLECT RESULTS ──────────────────────────────────────────────────
RESULTS=()
DURATIONS=()

for i in "${!BG_PIDS[@]}"; do
  bg_pid="${BG_PIDS[$i]}"
  project_id="${BG_PROJECT_IDS[$i]}"
  start_time="${START_TIMES[$i]}"

  log "Waiting for $project_id (PID $bg_pid)..."
  wait "$bg_pid"
  exit_code=$?

  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))
  minutes=$(( elapsed / 60 ))
  seconds=$(( elapsed % 60 ))
  DURATIONS+=("${minutes}m${seconds}s")

  final_status=$(get_project_field "$project_id" ".status" 2>/dev/null || echo "unknown")

  if [ "$exit_code" -eq 0 ] && [ "$final_status" = "live" ]; then
    RESULTS+=("live")
  elif [ "$exit_code" -eq 0 ]; then
    RESULTS+=("built")   # Built but deploy may have had an issue
  else
    RESULTS+=("failed")
  fi
done

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Parallel Pipeline Results${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

LIVE_COUNT=0
BUILT_COUNT=0
FAILED_COUNT=0

for i in "${!BG_PROJECT_IDS[@]}"; do
  pid="${BG_PROJECT_IDS[$i]}"
  result="${RESULTS[$i]:-unknown}"
  duration="${DURATIONS[$i]:-?}"
  name=$(get_project_field "$pid" ".name")

  case "$result" in
    live)
      echo -e "  ${GREEN}✓ live${NC}    ${pid}  (${duration})"
      info "    $name"
      LIVE_COUNT=$(( LIVE_COUNT + 1 ))
      ;;
    built)
      echo -e "  ${YELLOW}~ built${NC}   ${pid}  (${duration})"
      info "    $name — built but deploy unclear, check log"
      BUILT_COUNT=$(( BUILT_COUNT + 1 ))
      ;;
    *)
      echo -e "  ${RED}✗ failed${NC}  ${pid}  (${duration})"
      info "    $name — check: tail -100 $LOG_DIR/${pid}-parallel-pilot-${RUN_TS}.log"
      FAILED_COUNT=$(( FAILED_COUNT + 1 ))
      ;;
  esac
done

echo ""
ok "Live: $LIVE_COUNT  |  Built (no deploy): $BUILT_COUNT  |  Failed: $FAILED_COUNT"
echo ""

# ── EVENTS + NOTIFICATION ────────────────────────────────────────────────────
project_list=$(IFS=','; echo "${BG_PROJECT_IDS[*]}")
emit_event "parallel_pipeline_complete" \
  "projects=$project_list" \
  "live=$LIVE_COUNT" \
  "built=$BUILT_COUNT" \
  "failed=$FAILED_COUNT"

if [ "$FAILED_COUNT" -eq 0 ]; then
  notify "✅ Foundry Parallel Pipeline" "All $LIVE_COUNT projects live. Pilot successful."
else
  notify "⚠️ Foundry Parallel Pipeline" "Live: $LIVE_COUNT  Built: $BUILT_COUNT  Failed: $FAILED_COUNT" "urgent"
fi
