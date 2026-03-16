#!/bin/bash
# ============================================================================
# lib/report.sh — Daily report generator
# Source this file: source "$FACTORY_DIR/lib/report.sh"
# Call: generate_daily_report
# Requires: FACTORY_DIR, PROJECTS_JSON, ROOT_DIR, LOG_DIR already set
# ============================================================================

generate_daily_report() {
  local today
  today=$(date +%Y-%m-%d)
  local report_file="$LOG_DIR/daily-report-${today}.md"

  # ── Spec pipeline results (from today's spec log) ──────────────────────────
  local spec_log="$LOG_DIR/spec-creation-${today}.md"
  local spec_section=""
  if [ -f "$spec_log" ]; then
    # Pull PROCEED/REWRITE/KILL lines from today's log
    spec_section=$(grep -E "(VERDICT:|queued|needs_review|spec_failed)" "$spec_log" 2>/dev/null | head -20 || echo "  (no spec events today)")
  else
    spec_section="  (spec pipeline did not run today)"
  fi

  # ── Needs-review queue ─────────────────────────────────────────────────────
  local needs_review_count=0
  local needs_review_file="$LOG_DIR/needs-review-queue.md"
  if [ -f "$needs_review_file" ]; then
    needs_review_count=$(grep -c "needs_review:" "$needs_review_file" 2>/dev/null || echo 0)
  fi

  # ── Build pipeline results ─────────────────────────────────────────────────
  local built_projects
  built_projects=$(jq -r '.projects[] | select(.status == "built") | "  \u2705 \(.id): \(.name) — ready to deploy"' "$PROJECTS_JSON" 2>/dev/null)
  local paused_projects
  paused_projects=$(jq -r '.projects[] | select(.status == "paused") | "  \u23f8\ufe0f  \(.id): \(.name) — build paused"' "$PROJECTS_JSON" 2>/dev/null)
  local building_projects
  building_projects=$(jq -r '.projects[] | select(.status == "building") | "  \u23f3 \(.id): \(.name) — building now"' "$PROJECTS_JSON" 2>/dev/null)

  # ── Deploy queue ───────────────────────────────────────────────────────────
  local deploy_queue
  deploy_queue=$(jq -r '.projects[] | select(.status == "built") | "  → \(.id): Run ./approve.sh \(.id) to deploy"' "$PROJECTS_JSON" 2>/dev/null)
  if [ -z "$deploy_queue" ]; then
    deploy_queue="  (nothing ready to deploy)"
  fi

  # ── Rule proposals ─────────────────────────────────────────────────────────
  local proposal_file="$LOG_DIR/rule-proposals-${today}.md"
  local rule_proposals=""
  if [ -f "$proposal_file" ]; then
    local proposal_count
    proposal_count=$(grep -c "^###" "$proposal_file" 2>/dev/null || echo 0)
    rule_proposals="  $proposal_count new proposal(s) in logs/rule-proposals-${today}.md"
  else
    rule_proposals="  (evolver did not run today)"
  fi

  # ── Alerts ─────────────────────────────────────────────────────────────────
  local alerts=""
  local alerts_log="$LOG_DIR/alerts.log"
  if [ -f "$alerts_log" ]; then
    alerts=$(grep "$(date +%Y-%m-%d)" "$alerts_log" 2>/dev/null || echo "")
  fi
  if [ -z "$alerts" ]; then
    alerts="  (none)"
  else
    alerts=$(echo "$alerts" | sed 's/^/  ⚠️  /')
  fi

  # ── Write report ───────────────────────────────────────────────────────────
  cat > "$report_file" << EOF
═══ Foundry — Daily Report ${today} ═══

SPEC PIPELINE
${spec_section}
  📋 Needs Review: $needs_review_count

BUILD PIPELINE
${building_projects:-  (nothing building)}
${built_projects:-  (no completed builds)}
${paused_projects:-}

DEPLOY QUEUE
${deploy_queue}

RULE PROPOSALS
${rule_proposals}

ALERTS
${alerts}

════════════════════════════════════════════════
  Quick commands:
    View needs-review:  ./review-spec.sh --list
    Approve deploy:     ./approve.sh <project-id>
    Resume build:       ./build-project.sh <id> --resume-from <agent>
════════════════════════════════════════════════
EOF

  echo "$report_file"
}

# ---------------------------------------------------------------------------
# generate_history_summary
# Writes a compact 2KB summary of factory history for Evolver context
# ---------------------------------------------------------------------------
generate_history_summary() {
  local summary_file="/tmp/factory-history-summary.json"
  jq '{
    total_projects: (.projects | length),
    by_status: (.projects | group_by(.status) | map({status: .[0].status, count: length})),
    recent: [.projects | sort_by(.created_at) | reverse | .[:5] | .[] | {id, name, status, created_at}],
    categories: (.projects | group_by(.category) | map({category: .[0].category, count: length}))
  }' "$PROJECTS_JSON" > "$summary_file" 2>/dev/null
  echo "$summary_file"
}
