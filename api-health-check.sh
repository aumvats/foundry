#!/bin/bash
# ============================================================================
# api-health-check.sh — Weekly API Catalog Health Check
# ============================================================================
# Checks each API in API-CATALOG.md with a HEAD/GET request and flags any
# that return error codes or redirect to payment pages.
#
# Cron: 00 09 * * 1 cd ~/Code/exploratory/foundry && ./api-health-check.sh >> logs/api-health.log 2>&1
# ============================================================================

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
LOG_DIR="$FACTORY_DIR/logs"

mkdir -p "$LOG_DIR"

TODAY=$(date +%Y-%m-%d)
HEALTH_FILE="$LOG_DIR/api-health-${TODAY}.md"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[api-health]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ✓  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ ⚠️  ]${NC} $1"; }

log "API health check starting: $(date)"

# Run a Claude agent to check each API and write the health report
# The agent reads API-CATALOG.md, makes HEAD requests to base URLs,
# and writes a structured health report.

HEALTH_PROMPT="You are an API health checker for the Micro-SaaS Factory.

Read foundry/API-CATALOG.md to get the list of all APIs with their base URLs.

For each API in the catalog:
1. Make a HEAD or GET request to the base URL (use curl or fetch)
2. Check the response: 2xx = healthy, 3xx = check carefully (might be redirect to paywall), 4xx/5xx = unhealthy
3. Look for signs of deprecated endpoints or payment walls in any 3xx redirects
4. Check if the URL still matches the documented domain

Write your health report to: $HEALTH_FILE

Format:
\`\`\`markdown
# API Health Report — $TODAY

## Summary
- Total APIs checked: N
- Healthy: N
- Degraded: N
- Dead: N

## Results

### [API Name]
- URL: [base URL]
- Status: healthy | degraded | dead
- HTTP Code: [code]
- Notes: [any issues found]

[repeat for each API]

## Recommended Actions
[List any APIs that should be removed or updated in API-CATALOG.md]
\`\`\`

After writing the report, if any APIs are dead (5xx, connection refused, redirecting to payment page):
Write their names to: $LOG_DIR/dead-apis-${TODAY}.txt (one per line)

Do not modify API-CATALOG.md directly — that's for the operator to do after reviewing this report."

log "Running API health check agent..."

timeout 1800 claude \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --max-budget-usd 1 \
  --add-dir "$FACTORY_DIR" \
  -p "$HEALTH_PROMPT" 2>&1

if [ -f "$HEALTH_FILE" ]; then
  DEAD_COUNT=$(grep -c "Status: dead" "$HEALTH_FILE" 2>/dev/null || echo 0)
  TOTAL_COUNT=$(grep -c "^### " "$HEALTH_FILE" 2>/dev/null || echo 0)
  ok "Health check complete: $TOTAL_COUNT APIs checked, $DEAD_COUNT dead"

  if [ "$DEAD_COUNT" -gt 0 ]; then
    warn "$DEAD_COUNT dead API(s) found — review $HEALTH_FILE"
    echo "API_HEALTH $(date): $DEAD_COUNT dead APIs found — see $HEALTH_FILE" >> "$LOG_DIR/alerts.log"
  fi
else
  warn "Health check agent did not write a report"
fi

log "API health check done: $(date)"
