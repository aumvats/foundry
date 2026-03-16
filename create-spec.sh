#!/bin/bash
# ============================================================================
# create-spec.sh — Spec Pipeline Orchestrator
# ============================================================================
# Runs the 4-agent spec pipeline: Ideator → Critic → [Refiner] → Validator
# Hardened against all known failure modes.
#
# Usage: ./create-spec.sh [--count N] [--category <category>]
#   --count N         Number of spec slots to run (default: 1)
#   --category <cat>  Target category hint for Ideator
#
# Cron:
#   00 10 * * * cd ~/Code/exploratory/foundry && ./create-spec.sh --count 1
#   35 10 * * * cd ~/Code/exploratory/foundry && ./create-spec.sh --count 1
# ============================================================================

set -e

# ── CONFIG ───────────────────────────────────────────────────────────────────
ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOG_DIR="$FACTORY_DIR/logs"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
SPEC_LOCK="$FACTORY_DIR/.create-spec.lock"

MAX_KILLS=2           # Max consecutive KILLs before flagging for review
IDEATOR_TIMEOUT=1800  # 30 min
CRITIC_TIMEOUT=1200   # 20 min
REFINER_TIMEOUT=1800  # 30 min
VALIDATOR_TIMEOUT=900 # 15 min

source "$FACTORY_DIR/lib/state.sh"

mkdir -p "$LOG_DIR"

TODAY=$(date +%Y-%m-%d)
SPEC_LOG="$LOG_DIR/spec-creation-${TODAY}.md"

# ── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[spec]${NC} $1" | tee -a "$SPEC_LOG"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1" | tee -a "$SPEC_LOG"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1" | tee -a "$SPEC_LOG"; }
fail() { echo -e "${RED}[  ✗  ]${NC} $1" | tee -a "$SPEC_LOG" >&2; exit 1; }

# ── CONCURRENT EXECUTION GUARD ───────────────────────────────────────────────
exec 200>"$SPEC_LOCK"
if ! flock -n 200; then
  log "create-spec.sh already running, exiting"
  exit 0
fi

# ── PARSE ARGS ───────────────────────────────────────────────────────────────
COUNT=1
CATEGORY_TARGET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --count)    COUNT="$2"; shift 2 ;;
    --category) CATEGORY_TARGET="$2"; shift 2 ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

# ── PRE-FLIGHT CHECKS ────────────────────────────────────────────────────────
log "=== Spec Pipeline starting: $(date) ==="
log "Pre-flight checks..."

# Auth check
if ! claude --print -p "echo AUTHCHECK" 2>&1 | grep -q "AUTHCHECK"; then
  echo "AUTH FAILED $(date)" >> "$LOG_DIR/alerts.log"
  fail "Claude CLI auth check failed — aborting spec pipeline"
fi

# Disk space check (abort above 85%)
DISK_PCT=$(df -h ~ | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [ "$DISK_PCT" -gt 85 ]; then
  echo "DISK FULL $(date): ${DISK_PCT}% used" >> "$LOG_DIR/alerts.log"
  fail "Disk usage at ${DISK_PCT}% — aborting spec pipeline"
fi

# Dependency check
for f in \
  "$FACTORY_DIR/agents/ideator.md" \
  "$FACTORY_DIR/agents/critic.md" \
  "$FACTORY_DIR/agents/refiner.md" \
  "$FACTORY_DIR/agents/validator.md" \
  "$FACTORY_DIR/API-CATALOG.md"; do
  [ -f "$f" ] || { echo "MISSING: $f" >> "$LOG_DIR/alerts.log"; fail "Missing required file: $f"; }
done

ok "Pre-flight checks passed"

# ── AGENT RUNNER ─────────────────────────────────────────────────────────────
run_spec_agent() {
  local agent_name="$1"
  local timeout_secs="$2"
  local budget_usd="$3"
  local model="$4"
  local project_id="$5"
  local prompt="$6"
  local project_dir="$ROOT_DIR/$project_id"

  log "Running $agent_name for $project_id (timeout: ${timeout_secs}s, budget: \$$budget_usd)..."

  timeout "$timeout_secs" claude \
    --dangerously-skip-permissions \
    --model "$model" \
    --max-budget-usd "$budget_usd" \
    --add-dir "$project_dir" \
    --add-dir "$FACTORY_DIR" \
    -p "$prompt" 2>&1 | tee -a "$SPEC_LOG"

  local exit_code="${PIPESTATUS[0]}"

  if [ "$exit_code" -eq 124 ]; then
    warn "$agent_name timed out after ${timeout_secs}s"
    return 1
  elif [ "$exit_code" -ne 0 ]; then
    warn "$agent_name failed with exit code $exit_code"
    return 1
  fi
  return 0
}

# ── MAIN SPEC LOOP ──────────────────────────────────────────────────────────
for i in $(seq 1 "$COUNT"); do
  log "--- Spec slot $i/$COUNT ---"

  # Shell pre-generates the project ID — agent doesn't pick it
  PROJECT_ID="project-$(date +%s)"
  PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"
  RUN_REFINER=false
  KILLS=0
  unset KILL_REASON

  # ── KILL LOOP: Ideator + Critic ─────────────────────────────────────────
  while true; do
    mkdir -p "$PROJECT_DIR"
    log "Project ID: $PROJECT_ID"

    # Build Ideator prompt (compact — files read via --add-dir)
    IDEATOR_PROMPT="You are the Ideator agent. Read agents/ideator.md from the factory directory for your full instructions.

PROJECT_ID: $PROJECT_ID
PROJECT_DIR: $PROJECT_DIR
$([ -n "$CATEGORY_TARGET" ] && echo "CATEGORY_TARGET: $CATEGORY_TARGET")
$([ -n "${KILL_REASON:-}" ] && echo "KILL_REASON: Your previous idea was killed for this reason: $KILL_REASON. Generate a completely different concept.")

Read foundry/projects.json and foundry/API-CATALOG.md.
Read demoseed/DEMOSEED-SPEC.md as your quality reference for Section 5.
Write your outputs to: $PROJECT_DIR/"

    # Run Ideator
    if ! run_spec_agent "ideator" "$IDEATOR_TIMEOUT" "3" "claude-opus-4-6" "$PROJECT_ID" "$IDEATOR_PROMPT"; then
      echo "spec_failed:$PROJECT_ID:ideator_invocation_failed" >> "$SPEC_LOG"
      echo "SPEC_FAILED $(date): $PROJECT_ID — ideator invocation failed" >> "$LOG_DIR/alerts.log"
      break  # Skip this slot, continue outer for
    fi

    # Assert completion sentinel
    if [ ! -f "$PROJECT_DIR/.ideator-done" ]; then
      warn "Ideator sentinel missing for $PROJECT_ID — agent did not complete cleanly"
      echo "spec_failed:$PROJECT_ID:ideator_sentinel_missing" >> "$SPEC_LOG"
      echo "SPEC_FAILED $(date): $PROJECT_ID — .ideator-done not written" >> "$LOG_DIR/alerts.log"
      # Update projects.json if entry somehow got added
      break
    fi

    # Assert spec file exists and has substance
    SPEC_FILE=$(find "$PROJECT_DIR" -name "*SPEC.md" -maxdepth 1 | head -1)
    SPEC_SIZE=$(wc -c < "$SPEC_FILE" 2>/dev/null || echo 0)
    if [ -z "$SPEC_FILE" ] || [ "$SPEC_SIZE" -lt 1000 ]; then
      warn "Spec file missing or too small ($SPEC_SIZE bytes) for $PROJECT_ID"
      echo "spec_failed:$PROJECT_ID:spec_too_small" >> "$SPEC_LOG"
      echo "SPEC_FAILED $(date): $PROJECT_ID — spec file missing or <1000 bytes" >> "$LOG_DIR/alerts.log"
      break
    fi
    ok "Ideator complete. Spec: $(basename "$SPEC_FILE") ($SPEC_SIZE bytes)"

    # Run Critic
    CRITIC_PROMPT="You are the Critic agent. Read agents/critic.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read foundry/API-CATALOG.md to verify API claims.
Read foundry/projects.json for portfolio context.
Write your review to: $PROJECT_DIR/CRITIC-REVIEW.md
The LAST LINE of CRITIC-REVIEW.md must be exactly: VERDICT: PROCEED, VERDICT: REWRITE, or VERDICT: KILL"

    if ! run_spec_agent "critic" "$CRITIC_TIMEOUT" "2" "claude-opus-4-6" "$PROJECT_ID" "$CRITIC_PROMPT"; then
      warn "Critic failed for $PROJECT_ID — treating as needs_review"
      echo "needs_review:$PROJECT_ID:critic_invocation_failed" >> "$LOG_DIR/needs-review-queue.md"
      break
    fi

    # Parse verdict from last non-empty line (handles trailing newlines)
    LAST_LINE=$(grep -v '^[[:space:]]*$' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | tail -1 | tr -d '[:space:]')
    log "Critic verdict: $LAST_LINE"

    case "$LAST_LINE" in
      "VERDICT:PROCEED")
        ok "Critic: PROCEED"
        break  # Exit while loop, fall through to Validator
        ;;

      "VERDICT:REWRITE")
        ok "Critic: REWRITE"
        RUN_REFINER=true
        break  # Exit while loop, fall through to Refiner then Validator
        ;;

      "VERDICT:KILL")
        KILLS=$((KILLS + 1))
        KILL_REASON=$(grep -A2 "VERDICT" "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | tail -1 | head -c 200 || echo "no reason provided")
        warn "Critic: KILL ($KILLS/$MAX_KILLS) — $KILL_REASON"
        echo "kill:$PROJECT_ID:$KILL_REASON" >> "$SPEC_LOG"

        # Clean up killed project dir
        rm -rf "$PROJECT_DIR"

        if [ "$KILLS" -ge "$MAX_KILLS" ]; then
          warn "Hit kill limit ($MAX_KILLS) for spec slot $i — flagging for review"
          echo "needs_review:kill-limit-slot-$i-$(date +%s):$MAX_KILLS consecutive kills" >> "$LOG_DIR/needs-review-queue.md"
          echo "KILL_LIMIT $(date): spec slot $i hit $MAX_KILLS kills" >> "$LOG_DIR/alerts.log"
          continue 2  # Skip to next spec slot (outer for loop)
        fi

        # Generate new project ID and retry
        PROJECT_ID="project-$(date +%s)"
        PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"
        ;;

      *)
        warn "Critic produced no valid verdict for $PROJECT_ID (got: '$LAST_LINE') — needs_review"
        echo "needs_review:$PROJECT_ID:critic_no_verdict" >> "$LOG_DIR/needs-review-queue.md"
        break
        ;;
    esac
  done

  # Check if we exited the loop with a valid project (sentinel check)
  if [ ! -f "$PROJECT_DIR/.ideator-done" ]; then
    # Something failed upstream — slot was already logged, move on
    unset RUN_REFINER KILL_REASON
    PROJECT_ID="project-$(date +%s)"  # Reset for next slot
    continue
  fi

  # ── INDEPENDENT SCORE VERIFICATION ────────────────────────────────────────
  # Don't trust the agent's verdict alone — verify scores independently
  TOTAL_SCORE=$(grep -oP '\d+/10' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | \
    awk -F/ '{sum+=$1} END {print sum+0}')
  MIN_SCORE=$(grep -oP '\d+/10' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | \
    awk -F/ '{if(NR==1||$1<min) min=$1} END {print min+0}')

  if [ -n "$TOTAL_SCORE" ] && [ "$TOTAL_SCORE" -gt 0 ]; then
    log "Independent score check: total=$TOTAL_SCORE/50, min=$MIN_SCORE/10"
    if [ "$LAST_LINE" = "VERDICT:PROCEED" ]; then
      if [ "$TOTAL_SCORE" -lt 35 ] || [ "$MIN_SCORE" -lt 6 ]; then
        warn "Score check override: Critic said PROCEED but scores don't support it (total=$TOTAL_SCORE, min=$MIN_SCORE) → forcing REWRITE"
        RUN_REFINER=true
        LAST_LINE="VERDICT:REWRITE"
      fi
    fi
  fi

  # ── REFINER (only if REWRITE) ─────────────────────────────────────────────
  if [ "$RUN_REFINER" = true ]; then
    REFINER_PROMPT="You are the Refiner agent. Read agents/refiner.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read CRITIC-REVIEW.md from $PROJECT_DIR for issues to address.
Read foundry/API-CATALOG.md for API replacements if needed.
Overwrite the spec and write REFINEMENT-LOG.md to: $PROJECT_DIR/"

    if ! run_spec_agent "refiner" "$REFINER_TIMEOUT" "3" "claude-opus-4-6" "$PROJECT_ID" "$REFINER_PROMPT"; then
      warn "Refiner failed for $PROJECT_ID — queuing for needs_review"
      echo "needs_review:$PROJECT_ID:refiner_failed" >> "$LOG_DIR/needs-review-queue.md"
      unset RUN_REFINER KILL_REASON
      continue
    fi
    ok "Refiner complete"
  fi

  # ── VALIDATOR ─────────────────────────────────────────────────────────────
  VALIDATOR_PROMPT="You are the Validator agent. Read agents/validator.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read REFINEMENT-LOG.md if it exists in $PROJECT_DIR.
Read foundry/agents/rules.json if it exists in the factory directory.
Write ONLY SPEC-VALIDATION.json to: $PROJECT_DIR/
Do NOT modify any other file. Do NOT touch projects.json."

  if ! run_spec_agent "validator" "$VALIDATOR_TIMEOUT" "0.50" "claude-sonnet-4-6" "$PROJECT_ID" "$VALIDATOR_PROMPT"; then
    warn "Validator failed for $PROJECT_ID — needs_review"
    echo "needs_review:$PROJECT_ID:validator_failed" >> "$LOG_DIR/needs-review-queue.md"
    unset RUN_REFINER KILL_REASON
    continue
  fi

  # ── SHELL READS VALIDATION RESULT AND UPDATES projects.json ──────────────
  VALIDATION_FILE="$PROJECT_DIR/SPEC-VALIDATION.json"

  if [ ! -f "$VALIDATION_FILE" ]; then
    warn "SPEC-VALIDATION.json not written for $PROJECT_ID — needs_review"
    echo "needs_review:$PROJECT_ID:validation_json_missing" >> "$LOG_DIR/needs-review-queue.md"
    unset RUN_REFINER KILL_REASON
    continue
  fi

  RECOMMENDED=$(jq -r '.recommended_status // "needs_review"' "$VALIDATION_FILE" 2>/dev/null)
  VALIDATION_STATUS=$(jq -r '.status // "failed"' "$VALIDATION_FILE" 2>/dev/null)
  FAILING_CHECKS=$(jq -r '.failing_checks | join(", ")' "$VALIDATION_FILE" 2>/dev/null || echo "unknown")

  # Read spec metadata for projects.json entry
  SPEC_FILE=$(find "$PROJECT_DIR" -name "*SPEC.md" -maxdepth 1 | head -1)
  PRODUCT_NAME=$(head -5 "$SPEC_FILE" | grep -m1 "^#" | sed 's/^#* *//' | head -c 80 || echo "$PROJECT_ID")
  TAGLINE=$(grep -A2 "Product Overview\|tagline" "$SPEC_FILE" | grep -v "^#" | grep -v "^$" | head -1 | head -c 100 || echo "")
  CATEGORY_FOUND=$(grep -i "category\|Developer Tools\|SMB Tools\|Creator Tools\|Finance\|Marketing\|Health" "$SPEC_FILE" | head -1 | grep -oP "(Developer|SMB|Creator|Finance|Marketing|Health) Tools?" | head -1 || echo "Developer Tools")

  # Build the projects.json entry
  NEW_ENTRY=$(jq -n \
    --arg id "$PROJECT_ID" \
    --arg name "$PRODUCT_NAME" \
    --arg tagline "$TAGLINE" \
    --arg category "${CATEGORY_FOUND:-Developer Tools}" \
    --arg status "$RECOMMENDED" \
    --arg spec_dir "$PROJECT_ID" \
    --arg created_at "$(date +%Y-%m-%d)" \
    --arg verdict "$LAST_LINE" \
    --argjson total "${TOTAL_SCORE:-null}" \
    --argjson ran_refiner "$( [ "$RUN_REFINER" = true ] && echo true || echo false)" \
    '{
      id: $id,
      name: $name,
      tagline: $tagline,
      description: "",
      category: $category,
      color: "#6366F1",
      pricing: "",
      status: $status,
      spec_dir: $spec_dir,
      repo: "",
      live_url: "",
      vercel_project: "",
      created_at: $created_at,
      built_at: "",
      deployed_at: "",
      build_attempts: 0,
      spec_pipeline: {
        critic_verdict: $verdict,
        total_score: $total,
        ran_refiner: $ran_refiner
      }
    }')

  # Validate NEW_ENTRY is well-formed JSON before touching projects.json
  if ! echo "$NEW_ENTRY" | jq . > /dev/null 2>&1; then
    warn "projects.json entry for $PROJECT_ID is malformed — skipping append, flagging needs_review"
    echo "needs_review:$PROJECT_ID:malformed_projects_entry" >> "$LOG_DIR/needs-review-queue.md"
    unset RUN_REFINER KILL_REASON
    continue
  fi

  add_project_to_json "$NEW_ENTRY"

  # Write spec pipeline summary file
  jq -n \
    --arg id "$PROJECT_ID" \
    --arg verdict "$LAST_LINE" \
    --argjson total "${TOTAL_SCORE:-null}" \
    --argjson min "${MIN_SCORE:-null}" \
    --argjson ran_refiner "$( [ "$RUN_REFINER" = true ] && echo true || echo false)" \
    --arg status "$RECOMMENDED" \
    '{project_id: $id, critic_verdict: $verdict, total_score: $total, min_score: $min, ran_refiner: $ran_refiner, final_status: $status}' \
    > "$PROJECT_DIR/SPEC-PIPELINE-SUMMARY.json"

  if [ "$RECOMMENDED" = "queued" ]; then
    ok "$PROJECT_ID → QUEUED for build (score: ${TOTAL_SCORE:-?}/50, ran_refiner: $RUN_REFINER)"
    echo "queued:$PROJECT_ID:score=${TOTAL_SCORE:-?}:refiner=$RUN_REFINER" >> "$SPEC_LOG"
  else
    warn "$PROJECT_ID → NEEDS REVIEW (failing: $FAILING_CHECKS)"
    echo "needs_review:$PROJECT_ID:$FAILING_CHECKS" >> "$LOG_DIR/needs-review-queue.md"
    echo "needs_review:$PROJECT_ID:validation_failed:$FAILING_CHECKS" >> "$SPEC_LOG"
  fi

  # Reset for next slot
  unset RUN_REFINER KILL_REASON
done

log "=== Spec Pipeline complete: $(date) ==="
