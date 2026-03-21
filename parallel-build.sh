#!/bin/bash
# ============================================================================
# parallel-build.sh — Parallel Build Pilot
# ============================================================================
# Runs multiple build-project.sh instances simultaneously — one per project.
# Each project progresses sequentially through its own pipeline internally,
# but all projects run in parallel with each other.
#
# Usage:
#   ./parallel-build.sh                        # All parallel_queued projects
#   ./parallel-build.sh <id1> <id2> ...        # Specific project IDs
#
# Safety:
#   - Refuses to run if orchestrate.sh is active (.orchestrate.lock held)
#   - Projects should already be in parallel_queued status (withdrawn from
#     the sequential orchestrator queue before running this script)
# ============================================================================

set -e
unset CLAUDECODE

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
CRON_LOCK="$FACTORY_DIR/.orchestrate.lock"

source "$FACTORY_DIR/lib/state.sh"

mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[parallel]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" >&2; exit 1; }
info() { echo -e "${CYAN}[  ·  ]${NC} $1"; }

RUN_TS=$(date +%Y%m%d-%H%M%S)

# ── PARSE FLAGS ──────────────────────────────────────────────────────────────
FORCE=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

# ── GUARD: refuse if orchestrate.sh holds the lock ───────────────────────────
ORCHESTRATOR_RUNNING=false
if ! flock -n "$CRON_LOCK" true 2>/dev/null; then
  ORCHESTRATOR_RUNNING=true
fi

if [ "$ORCHESTRATOR_RUNNING" = true ]; then
  if [ "$FORCE" = true ]; then
    warn "orchestrate.sh appears to be running (lock held), but --force passed. Proceeding."
  else
    fail "orchestrate.sh is currently running. Wait for it to finish, then run: ./parallel-build.sh"
  fi
fi

echo -e "\n${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Foundry — Parallel Build Pilot  [${RUN_TS}]${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}\n"

# ── DETERMINE PROJECTS TO BUILD ───────────────────────────────────────────────
# Bash 3.2 compatible — no mapfile, no declare -A
PROJECT_IDS=()

if [ ${#ARGS[@]} -gt 0 ]; then
  PROJECT_IDS=("${ARGS[@]}")
  log "Explicit projects: ${PROJECT_IDS[*]}"
else
  while IFS= read -r line; do
    [ -n "$line" ] && PROJECT_IDS+=("$line")
  done < <(jq -r '.projects[] | select(.status == "parallel_queued") | .id' "$PROJECTS_JSON" 2>/dev/null)

  if [ ${#PROJECT_IDS[@]} -eq 0 ]; then
    fail "No parallel_queued projects found. Pass explicit project IDs or withdraw some from the queue first."
  fi
  log "Found ${#PROJECT_IDS[@]} parallel_queued project(s) to build"
fi

# ── LAUNCH ALL BUILDS IN BACKGROUND ──────────────────────────────────────────
# Bash 3.2: use parallel indexed arrays instead of associative arrays
BG_PIDS=()
BG_PROJECT_IDS=()
START_TIMES=()

echo ""
log "Starting ${#PROJECT_IDS[@]} builds in parallel..."
echo ""

for pid in "${PROJECT_IDS[@]}"; do
  name=$(get_project_field "$pid" ".name")
  log_file="$LOG_DIR/${pid}-parallel-${RUN_TS}.log"

  # Restore to queued so build-project.sh picks it up normally
  update_project_field "$pid" .status '"queued"'

  info "Spawning: $pid"
  info "  Log: $log_file"

  bash "$FACTORY_DIR/build-project.sh" "$pid" >> "$log_file" 2>&1 &
  bg_pid=$!

  BG_PIDS+=("$bg_pid")
  BG_PROJECT_IDS+=("$pid")
  START_TIMES+=("$(date +%s)")

  echo ""
done

echo ""
log "All ${#PROJECT_IDS[@]} builds spawned. Waiting for completion..."
echo -e "${YELLOW}  Monitor with:${NC}"
for pid in "${PROJECT_IDS[@]}"; do
  echo "    tail -f $LOG_DIR/${pid}-parallel-${RUN_TS}.log"
done
echo ""

# ── WAIT AND COLLECT RESULTS ─────────────────────────────────────────────────
# Parallel indexed arrays: BG_PIDS[i] → BG_PROJECT_IDS[i] → START_TIMES[i]
RESULTS=()
DURATIONS=()

for i in "${!BG_PIDS[@]}"; do
  bg_pid="${BG_PIDS[$i]}"
  project_id="${BG_PROJECT_IDS[$i]}"
  start_time="${START_TIMES[$i]}"

  wait "$bg_pid"
  exit_code=$?

  end_time=$(date +%s)
  minutes=$(( (end_time - start_time) / 60 ))
  DURATIONS+=("${minutes}m")

  if [ "$exit_code" -eq 0 ]; then
    RESULTS+=("built")
  else
    RESULTS+=("failed")
  fi
done

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Parallel Build Results${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

BUILT_COUNT=0
FAILED_COUNT=0

for i in "${!BG_PROJECT_IDS[@]}"; do
  pid="${BG_PROJECT_IDS[$i]}"
  result="${RESULTS[$i]:-unknown}"
  duration="${DURATIONS[$i]:-?m}"

  if [ "$result" = "built" ]; then
    echo -e "  ${GREEN}✓ built${NC}   ${pid}  (${duration})"
    BUILT_COUNT=$(( BUILT_COUNT + 1 ))
  else
    echo -e "  ${RED}✗ failed${NC}  ${pid}  (${duration})"
    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
  fi
done

echo ""
ok "Built: $BUILT_COUNT  |  Failed: $FAILED_COUNT"
echo ""

if [ "$BUILT_COUNT" -gt 0 ]; then
  log "Projects in 'built' status — run approve.sh <id> to deploy each one."
fi

# ── EVENTS + NOTIFICATION ────────────────────────────────────────────────────
project_list=$(IFS=','; echo "${BG_PROJECT_IDS[*]}")
emit_event "parallel_build_complete" \
  "projects=$project_list" \
  "built=$BUILT_COUNT" \
  "failed=$FAILED_COUNT"

if [ "$FAILED_COUNT" -eq 0 ]; then
  notify "✅ Foundry Parallel Build" "All $BUILT_COUNT projects built successfully."
else
  notify "⚠️ Foundry Parallel Build" "Built: $BUILT_COUNT  Failed: $FAILED_COUNT" "urgent"
fi
