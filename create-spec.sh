#!/bin/bash
# ============================================================================
# create-spec.sh — Spec Pipeline Orchestrator
# ============================================================================
# Runs the 4-agent spec pipeline: Ideator → Critic → [Refiner] → Validator
# Hardened against all known failure modes.
#
# Usage: ./create-spec.sh [--count N] [--category <category>]
#   --count N         Number of QUEUED projects to produce (default: 2)
#   --category <cat>  Target category hint for Ideator
#
# The pipeline keeps retrying (up to MAX_ATTEMPTS total Ideator invocations) until
# COUNT projects reach "queued" status. Kills do not count against the quota.
#
# Cron:
#   00 10 * * * cd ~/Code/exploratory/foundry && ./create-spec.sh --count 2
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
SPEC_LOCK="$FACTORY_DIR/.create-spec.lock"

MAX_ATTEMPTS=10       # Global cap: max total Ideator invocations per run (safety net)
IDEATOR_TIMEOUT=1800  # 30 min
CRITIC_TIMEOUT=1200   # 20 min
REFINER_TIMEOUT=1800  # 30 min
VALIDATOR_TIMEOUT=900 # 15 min

source "$FACTORY_DIR/lib/state.sh"

mkdir -p "$LOG_DIR"

SPEC_RUN_LOG="$LOG_DIR/spec-run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$SPEC_RUN_LOG") 2>&1
# Keep only last 14 spec run logs
ls -t "$LOG_DIR"/spec-run-*.log 2>/dev/null | tail -n +15 | xargs rm -f 2>/dev/null || true

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

# Kill orphaned spec pipeline processes from previous sessions (same script, different PID)
SELF_PID=$$
STALE_PIDS=$(pgrep -f "create-spec.sh" | grep -v "^$SELF_PID$" 2>/dev/null)
if [ -n "$STALE_PIDS" ]; then
  log "Cleaning up stale spec-pipeline processes: $STALE_PIDS"
  echo "$STALE_PIDS" | xargs kill -9 2>/dev/null || true
fi

# ── PARSE ARGS ───────────────────────────────────────────────────────────────
COUNT=2
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
  notify "⚠️ Foundry — Auth Failed" "Claude CLI auth check failed. Spec pipeline aborted." "urgent"
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
emit_event "spec_pipeline_started" "target=$COUNT" "max_attempts=$MAX_ATTEMPTS"

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
    --effort high \
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
# Keep generating specs until COUNT projects are queued.
# MAX_ATTEMPTS is the global safety cap (prevents infinite spending on bad ideas).
QUEUED_COUNT=0
TOTAL_ATTEMPTS=0

log "Target: $COUNT queued project(s) (max $MAX_ATTEMPTS total attempts)"

while [ "$QUEUED_COUNT" -lt "$COUNT" ] && [ "$TOTAL_ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
  TOTAL_ATTEMPTS=$((TOTAL_ATTEMPTS + 1))
  emit_event "spec_started" "attempt=$TOTAL_ATTEMPTS" "project_id=${PROJECT_ID:-pending}"
  log "--- Attempt $TOTAL_ATTEMPTS/$MAX_ATTEMPTS (queued: $QUEUED_COUNT/$COUNT) ---"

  # Shell pre-generates the project ID — agent doesn't pick it
  PROJECT_ID="project-$(date +%s)"
  PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"
  RUN_REFINER=false
  LAST_LINE=""
  _SPEC_ISSUE_ID=""

  mkdir -p "$PROJECT_DIR"
  log "Project ID: $PROJECT_ID"

  # Build Ideator prompt — use parameter expansion, not $() subshells, to avoid set -e issues
  _CAT_LINE="${CATEGORY_TARGET:+CATEGORY_TARGET: $CATEGORY_TARGET}"
  _KILL_LINE="${KILL_REASON:+KILL_REASON: Your previous idea was killed for this reason: $KILL_REASON. Generate a completely different concept.}"
  IDEATOR_PROMPT="You are the Ideator agent. Read agents/ideator.md from the factory directory for your full instructions.

PROJECT_ID: $PROJECT_ID
PROJECT_DIR: $PROJECT_DIR
${_CAT_LINE}
${_KILL_LINE}

Read foundry/projects.json and foundry/API-CATALOG.md.
Read foundry/agents/rules.json and apply ALL active rules (active: true) before finalising your spec.
Read demoseed/DEMOSEED-SPEC.md as your quality reference for Section 5.
Write your outputs to: $PROJECT_DIR/"

  # Run Ideator
  if ! run_spec_agent "ideator" "$IDEATOR_TIMEOUT" "3" "claude-opus-4-6" "$PROJECT_ID" "$IDEATOR_PROMPT"; then
    echo "spec_failed:$PROJECT_ID:ideator_invocation_failed" >> "$SPEC_LOG"
    echo "SPEC_FAILED $(date): $PROJECT_ID — ideator invocation failed" >> "$LOG_DIR/alerts.log"
    unset KILL_REASON
    continue
  fi

  # Assert completion sentinel
  if [ ! -f "$PROJECT_DIR/.ideator-done" ]; then
    warn "Ideator sentinel missing for $PROJECT_ID — agent did not complete cleanly"
    echo "spec_failed:$PROJECT_ID:ideator_sentinel_missing" >> "$SPEC_LOG"
    echo "SPEC_FAILED $(date): $PROJECT_ID — .ideator-done not written" >> "$LOG_DIR/alerts.log"
    unset KILL_REASON
    continue
  fi

  # Assert spec file exists and has substance
  SPEC_FILE=$(find "$PROJECT_DIR" -name "*SPEC.md" -maxdepth 1 | head -1)
  SPEC_SIZE=$(wc -c < "$SPEC_FILE" 2>/dev/null || echo 0)
  if [ -z "$SPEC_FILE" ] || [ "$SPEC_SIZE" -lt 1000 ]; then
    warn "Spec file missing or too small ($SPEC_SIZE bytes) for $PROJECT_ID"
    echo "spec_failed:$PROJECT_ID:spec_too_small" >> "$SPEC_LOG"
    echo "SPEC_FAILED $(date): $PROJECT_ID — spec file missing or <1000 bytes" >> "$LOG_DIR/alerts.log"
    unset KILL_REASON
    continue
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
    unset KILL_REASON
    continue
  fi

  # Parse verdict from last non-empty line (handles trailing newlines)
  LAST_LINE=$(grep -v '^[[:space:]]*$' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | tail -1 | tr -d '[:space:]')
  log "Critic verdict: $LAST_LINE"

  case "$LAST_LINE" in
    "VERDICT:KILL")
      KILL_REASON=$(grep -B2 "VERDICT: KILL" "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | head -3 | tail -1 | head -c 200 || echo "no reason provided")
      warn "Critic: KILL (attempt $TOTAL_ATTEMPTS) — $KILL_REASON"
      echo "kill:$PROJECT_ID:$KILL_REASON" >> "$SPEC_LOG"
      emit_event "spec_killed" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "score=${TOTAL_SCORE:-0}" "reason=$KILL_REASON"
      append_history "❌" "KILLED" "${PRODUCT_NAME:-$PROJECT_ID} — score ${TOTAL_SCORE:-?}/50"
      # Linear: create cancelled Spec issue (project dir deleted right after)
      linear_create_issue "${PROJECT_ID} — Spec" "**KILLED** by Critic\n\n**Reason:** ${KILL_REASON}\n\n**Score:** ${TOTAL_SCORE:-?}/50" "Cancelled" "Spec" > /dev/null || true
      rm -rf "$PROJECT_DIR"
      # KILL_REASON stays set — passed to next Ideator invocation
      continue
      ;;

    "VERDICT:REWRITE")
      ok "Critic: REWRITE"
      emit_event "spec_rewrite" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "score=${TOTAL_SCORE:-0}"
      RUN_REFINER=true
      unset KILL_REASON
      # Linear: create In Review Spec issue (will be updated when queued)
      _SPEC_ISSUE_ID=$(linear_create_issue "${PROJECT_ID} — Spec" "**Needs revision** — Refiner will run\n\n**Score:** ${TOTAL_SCORE:-?}/50" "In Review" "Spec") || _SPEC_ISSUE_ID=""
      ;;

    "VERDICT:PROCEED")
      ok "Critic: PROCEED"
      emit_event "spec_approved" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "score=${TOTAL_SCORE:-0}"
      unset KILL_REASON
      # Linear: create In Progress Spec issue (will be updated when queued)
      _SPEC_ISSUE_ID=$(linear_create_issue "${PROJECT_ID} — Spec" "**Approved** by Critic\n\n**Score:** ${TOTAL_SCORE:-?}/50" "In Progress" "Spec") || _SPEC_ISSUE_ID=""
      ;;

    *)
      warn "Critic produced no valid verdict for $PROJECT_ID (got: '$LAST_LINE') — needs_review"
      echo "needs_review:$PROJECT_ID:critic_no_verdict" >> "$LOG_DIR/needs-review-queue.md"
      emit_event "spec_needs_review" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "failing=critic_no_verdict"
      unset KILL_REASON
      continue
      ;;
  esac

  # ── INDEPENDENT SCORE VERIFICATION ────────────────────────────────────────
  # Don't trust the agent's verdict alone — verify scores independently
  # Cap at 5 dimension scores (NR<=5) to prevent stray /10 matches (e.g. from totals like 76/100)
  TOTAL_SCORE=$(grep -oE '\b[0-9]{1,2}/10\b' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | \
    awk -F/ 'NR<=5{sum+=$1} END {print sum+0}')
  MIN_SCORE=$(grep -oE '\b[0-9]{1,2}/10\b' "$PROJECT_DIR/CRITIC-REVIEW.md" 2>/dev/null | \
    awk -F/ 'NR<=5{if(NR==1||$1<min) min=$1} END {print min+0}')

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

  if ! run_spec_agent "validator" "$VALIDATOR_TIMEOUT" "1.00" "claude-sonnet-4-6" "$PROJECT_ID" "$VALIDATOR_PROMPT"; then
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
  # Extract description: first full sentence paragraph in Section 1 (after blockquote/tagline, before next section)
  DESCRIPTION=$(awk '/^## 1\./{found=1;next} found && /^## [0-9]/{exit} found && /^[A-Z]/{print;exit}' "$SPEC_FILE" 2>/dev/null | head -c 300 || echo "")
  CATEGORY_FOUND=$(grep -i "category\|Developer Tools\|SMB Tools\|Creator Tools\|Finance\|Marketing\|Health" "$SPEC_FILE" | head -1 | grep -oE "(Developer|SMB|Creator|Finance|Marketing|Health) Tools?" | head -1 || echo "Developer Tools")

  # Build the projects.json entry
  NEW_ENTRY=$(jq -n \
    --arg id "$PROJECT_ID" \
    --arg name "$PRODUCT_NAME" \
    --arg tagline "$TAGLINE" \
    --arg description "${DESCRIPTION:-}" \
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
      description: $description,
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
    QUEUED_COUNT=$((QUEUED_COUNT + 1))
    ok "$PROJECT_ID → QUEUED for build ($QUEUED_COUNT/$COUNT) (score: ${TOTAL_SCORE:-?}/50, ran_refiner: $RUN_REFINER)"
    echo "queued:$PROJECT_ID:score=${TOTAL_SCORE:-?}:refiner=$RUN_REFINER" >> "$SPEC_LOG"
    emit_event "spec_queued" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-$PROJECT_ID}" "score=${TOTAL_SCORE:-0}" "ran_refiner=$RUN_REFINER"
    append_history "✓" "QUEUED" "${PRODUCT_NAME:-$PROJECT_ID} — score ${TOTAL_SCORE:-?}/50${RUN_REFINER:+ (refined)}"

    # Linear: create Project, finalize Spec issue → Done, create Build issue, link all
    _LINEAR_PROJECT_ID=$(linear_create_project "${PRODUCT_NAME:-$PROJECT_ID}" \
      "${TAGLINE:-Micro-SaaS product built by Foundry.}" "started") || _LINEAR_PROJECT_ID=""
    if [ -n "${_LINEAR_PROJECT_ID:-}" ]; then
      write_projects_json "(.projects[] | select(.id == \"$PROJECT_ID\") | .linear.project_id) = \"$_LINEAR_PROJECT_ID\""
    fi
    if [ -n "${_SPEC_ISSUE_ID:-}" ]; then
      linear_update_title "$_SPEC_ISSUE_ID" "${PRODUCT_NAME:-$PROJECT_ID} — Spec" || true
      linear_update_state "$_SPEC_ISSUE_ID" "Done" || true
      linear_assign_to_project "$_SPEC_ISSUE_ID" "${_LINEAR_PROJECT_ID:-}" || true
    fi
    _BUILD_ISSUE_ID=$(linear_create_issue "${PRODUCT_NAME:-$PROJECT_ID} — Build" \
      "Spec approved, queued for build.\n\n**Score:** ${TOTAL_SCORE:-?}/50\n**Ran Refiner:** ${RUN_REFINER}" \
      "Todo" "Build") || _BUILD_ISSUE_ID=""
    linear_assign_to_project "$_BUILD_ISSUE_ID" "${_LINEAR_PROJECT_ID:-}" || true
    if [ -n "${_SPEC_ISSUE_ID:-}" ] && [ -n "${_BUILD_ISSUE_ID:-}" ]; then
      linear_link_issues "$_SPEC_ISSUE_ID" "$_BUILD_ISSUE_ID" || true
    fi
    if [ -n "${_SPEC_ISSUE_ID:-}" ]; then
      write_projects_json "(.projects[] | select(.id == \"$PROJECT_ID\") | .linear.spec_issue_id) = \"$_SPEC_ISSUE_ID\""
    fi
    if [ -n "${_BUILD_ISSUE_ID:-}" ]; then
      write_projects_json "(.projects[] | select(.id == \"$PROJECT_ID\") | .linear.build_issue_id) = \"$_BUILD_ISSUE_ID\""
    fi

    # Build rich description for Linear project
    _LINEAR_DESC=$(cat << ENDDESC
${TAGLINE:-Micro-SaaS product built by Foundry.}

**Status:** Queued for build ⏳
**Critic Score:** ${TOTAL_SCORE:-?}/50 | Ran Refiner: ${RUN_REFINER}
**Created:** $(date +%Y-%m-%d)

---

### Spec
\`~/Code/exploratory/${PROJECT_ID}/\` — look for *-SPEC.md
ENDDESC
)
    linear_set_description "${_LINEAR_PROJECT_ID:-}" "$_LINEAR_DESC" || true
    linear_post_update "${_LINEAR_PROJECT_ID:-}" "📋 **Spec approved** by Critic\n\n**Score:** ${TOTAL_SCORE:-?}/50 | Ran Refiner: ${RUN_REFINER}\n\nQueued for build. Build pipeline will start shortly." "onTrack" || true
    linear_add_project_link "${_LINEAR_PROJECT_ID:-}" "file://${ROOT_DIR}/${PROJECT_ID}" "📁 Spec Directory" || true
  else
    # Validator failed — auto-run Refiner if not already done, then re-validate
    if [ "$RUN_REFINER" = false ]; then
      warn "$PROJECT_ID → Validator failed ($FAILING_CHECKS) — auto-running Refiner before flagging"
      REFINER_PROMPT="You are the Refiner agent. Read agents/refiner.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read CRITIC-REVIEW.md from $PROJECT_DIR if it exists.
Read SPEC-VALIDATION.json from $PROJECT_DIR — fix all failing_checks listed there.
Overwrite the spec and write REFINEMENT-LOG.md to: $PROJECT_DIR/"

      if run_spec_agent "refiner" "$REFINER_TIMEOUT" "3" "claude-opus-4-6" "$PROJECT_ID" "$REFINER_PROMPT"; then
        RUN_REFINER=true
        # Re-run Validator
        VALIDATOR_PROMPT="You are the Validator agent. Read agents/validator.md from the factory directory for your full instructions.

PROJECT_DIR: $PROJECT_DIR
Read the spec file (ending in -SPEC.md) from $PROJECT_DIR.
Read REFINEMENT-LOG.md if it exists in $PROJECT_DIR.
Read foundry/agents/rules.json if it exists in the factory directory.
Write ONLY SPEC-VALIDATION.json to: $PROJECT_DIR/
Do NOT modify any other file. Do NOT touch projects.json."

        if run_spec_agent "validator" "$VALIDATOR_TIMEOUT" "1.00" "claude-sonnet-4-6" "$PROJECT_ID" "$VALIDATOR_PROMPT"; then
          RECOMMENDED=$(jq -r '.recommended_status // "needs_review"' "$VALIDATION_FILE" 2>/dev/null)
          FAILING_CHECKS=$(jq -r '.failing_checks | join(", ")' "$VALIDATION_FILE" 2>/dev/null || echo "unknown")
          if [ "$RECOMMENDED" = "queued" ]; then
            QUEUED_COUNT=$((QUEUED_COUNT + 1))
            ok "$PROJECT_ID → QUEUED after auto-refine ($QUEUED_COUNT/$COUNT)"
            echo "queued:$PROJECT_ID:score=${TOTAL_SCORE:-?}:refiner=auto" >> "$SPEC_LOG"
            emit_event "spec_queued" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-$PROJECT_ID}" "score=${TOTAL_SCORE:-0}" "ran_refiner=true"
            append_history "✓" "QUEUED" "${PRODUCT_NAME:-$PROJECT_ID} — auto-refined (score ${TOTAL_SCORE:-?}/50)"
            unset RUN_REFINER
            continue
          fi
        fi
      fi
      # Refiner ran but still failing — flag for spec revision
      warn "$PROJECT_ID → needs_spec_revision after auto-refine (failing: $FAILING_CHECKS)"
      jq --arg id "$PROJECT_ID" '(.projects[] | select(.id == $id) | .status) = "needs_spec_revision"' \
        "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON" || true
      echo "needs_spec_revision:$PROJECT_ID:$FAILING_CHECKS" >> "$LOG_DIR/needs-review-queue.md"
      emit_event "spec_needs_revision" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "failing=$FAILING_CHECKS"
    else
      # Refiner already ran and Validator still fails — genuine spec revision needed
      warn "$PROJECT_ID → needs_spec_revision (Refiner already ran, still failing: $FAILING_CHECKS)"
      jq --arg id "$PROJECT_ID" '(.projects[] | select(.id == $id) | .status) = "needs_spec_revision"' \
        "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON" || true
      echo "needs_spec_revision:$PROJECT_ID:$FAILING_CHECKS" >> "$LOG_DIR/needs-review-queue.md"
      emit_event "spec_needs_revision" "project_id=$PROJECT_ID" "project_name=${PRODUCT_NAME:-unknown}" "failing=$FAILING_CHECKS"
    fi
  fi

  unset RUN_REFINER
done

# ── POST-LOOP SUMMARY ─────────────────────────────────────────────────────
if [ "$QUEUED_COUNT" -lt "$COUNT" ] && [ "$TOTAL_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
  warn "Hit attempt cap ($MAX_ATTEMPTS) with only $QUEUED_COUNT/$COUNT projects queued — check alerts.log"
  echo "ATTEMPT_CAP $(date): $QUEUED_COUNT/$COUNT queued after $MAX_ATTEMPTS attempts" >> "$LOG_DIR/alerts.log"
  notify "⚠️ Foundry — Spec Pipeline Stalled" "$QUEUED_COUNT/$COUNT ideas queued after $MAX_ATTEMPTS attempts. Check alerts." "urgent"
else
  notify "Foundry — Specs Ready" "$QUEUED_COUNT idea(s) queued for build in $TOTAL_ATTEMPTS attempt(s)" 
fi

# Auto-trigger build pipeline if we queued any projects
if [ "$QUEUED_COUNT" -gt 0 ]; then
  log "Triggering build pipeline for $QUEUED_COUNT queued project(s)..."
  unset CLAUDECODE
  nohup "$FACTORY_DIR/orchestrate.sh" >> "$LOG_DIR/cron.log" 2>&1 &
  log "Build pipeline started (PID $!)"
fi

log "=== Spec Pipeline complete: $(date) — $QUEUED_COUNT/$COUNT queued in $TOTAL_ATTEMPTS attempt(s) ==="
emit_event "spec_pipeline_complete" "queued=$QUEUED_COUNT" "target=$COUNT" "attempts=$TOTAL_ATTEMPTS"
