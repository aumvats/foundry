#!/bin/bash
# ============================================================================
# briefing.sh — Morning summary fired at 8am via launchd
# Reads events.jsonl for the last 24h, notifies user with a digest.
# ============================================================================

FACTORY_DIR="$HOME/Code/exploratory/foundry"
LOG_DIR="$FACTORY_DIR/logs"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
EVENTS_FILE="$LOG_DIR/events.jsonl"
TODAY=$(date +%Y-%m-%d)
BRIEFING_FILE="$LOG_DIR/briefing-$TODAY.md"

# macOS: 24h ago in UTC ISO format
CUTOFF=$(date -u -v-24H "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "24 hours ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2000-01-01T00:00:00Z")

count_events() {
  local type="$1"
  if [ ! -f "$EVENTS_FILE" ]; then echo 0; return; fi
  grep "\"type\":\"$type\"" "$EVENTS_FILE" | awk -F'"ts":"' '{print $2}' | cut -d'"' -f1 | \
    awk -v cutoff="$CUTOFF" '$1 >= cutoff' | wc -l | tr -d ' '
}

SPECS_RUN=$(count_events "spec_started")
SPECS_KILLED=$(count_events "spec_killed")
SPECS_QUEUED=$(count_events "spec_queued")
BUILDS_DONE=$(count_events "build_complete")
DEPLOYED=$(count_events "deployed")

# Pending from projects.json
BUILT_PENDING=0
QUEUED_PENDING=0
if [ -f "$PROJECTS_JSON" ] && command -v jq >/dev/null 2>&1; then
  BUILT_PENDING=$(jq '[.projects[] | select(.status=="built")] | length' "$PROJECTS_JSON" 2>/dev/null || echo 0)
  QUEUED_PENDING=$(jq '[.projects[] | select(.status=="queued")] | length' "$PROJECTS_JSON" 2>/dev/null || echo 0)
fi

# Rule proposals
PENDING_RULES=$(ls "$LOG_DIR"/rule-proposals-*.md 2>/dev/null | wc -l | tr -d ' ')

# Build notification message
PARTS=()
[ "$SPECS_QUEUED" -gt 0 ]   && PARTS+=("${SPECS_QUEUED} idea(s) queued")
[ "$BUILDS_DONE" -gt 0 ]    && PARTS+=("${BUILDS_DONE} built")
[ "$DEPLOYED" -gt 0 ]        && PARTS+=("${DEPLOYED} deployed")
[ "$BUILT_PENDING" -gt 0 ]   && PARTS+=("${BUILT_PENDING} awaiting deploy ←")
[ "$PENDING_RULES" -gt 0 ]   && PARTS+=("${PENDING_RULES} rule proposals")
[ "${#PARTS[@]}" -eq 0 ]     && PARTS+=("Factory ran idle overnight")

MSG=$(IFS=', '; echo "${PARTS[*]}")

# Write briefing file
{
  echo "# Foundry Morning Briefing — $TODAY"
  echo ""
  echo "Generated: $(date '+%H:%M %Z')"
  echo ""
  echo "## Last 24 Hours"
  echo "| Metric | Count |"
  echo "|---|---|"
  echo "| Ideas generated | $SPECS_RUN |"
  echo "| Ideas killed by Critic | $SPECS_KILLED |"
  echo "| Ideas queued for build | $SPECS_QUEUED |"
  echo "| Builds completed | $BUILDS_DONE |"
  echo "| Products deployed | $DEPLOYED |"
  echo ""
  echo "## Needs Your Attention"
  if [ "$BUILT_PENDING" -gt 0 ]; then
    echo "- **$BUILT_PENDING product(s) built**, awaiting deploy approval"
    if command -v jq >/dev/null 2>&1 && [ -f "$PROJECTS_JSON" ]; then
      jq -r '.projects[] | select(.status=="built") | "  → ./approve.sh \(.id)   # \(.name)"' "$PROJECTS_JSON" 2>/dev/null | \
        sed 's/PROJECT-[0-9]* — //'
    fi
  fi
  if [ "$QUEUED_PENDING" -gt 0 ]; then
    echo "- **$QUEUED_PENDING spec(s) queued**, will build at noon today"
  fi
  if [ "$PENDING_RULES" -gt 0 ]; then
    echo "- **$PENDING_RULES rule proposal file(s)** to review in logs/ — open dashboard Rules tab"
  fi
  if [ "$BUILT_PENDING" -eq 0 ] && [ "$QUEUED_PENDING" -eq 0 ] && [ "$PENDING_RULES" -eq 0 ]; then
    echo "- Nothing pending — all clear ✓"
  fi
  echo ""
  echo "## Recent History"
  if [ -f "$LOG_DIR/history.md" ]; then
    tail -15 "$LOG_DIR/history.md"
  else
    echo "No history yet."
  fi
} > "$BRIEFING_FILE"

# Fire macOS notification
command -v osascript >/dev/null 2>&1 && \
  osascript -e "display alert \"☀️ Foundry — Good Morning\" message \"$MSG\" as informational" 2>/dev/null &

echo "Briefing written: $BRIEFING_FILE"
echo "Summary: $MSG"
