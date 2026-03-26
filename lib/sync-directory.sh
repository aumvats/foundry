#!/bin/bash
# ============================================================================
# lib/sync-directory.sh — Sync a deployed project to foundry-hq directory site
# ============================================================================
# Usage: bash sync-directory.sh <project-id>
#   Reads project metadata from projects.json + spec file, updates
#   foundry-hq/src/lib/projects.ts, commits and pushes to trigger Vercel deploy.
# ============================================================================

set -euo pipefail

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"
LOCK_FILE="$FACTORY_DIR/.projects.lock"
HQ_DIR="$ROOT_DIR/foundry-hq"
HQ_PROJECTS_TS="$HQ_DIR/src/lib/projects.ts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[sync-dir]${NC} $1"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $1"; }
err()  { echo -e "${RED}[ err  ]${NC} $1" >&2; }

PROJECT_ID="${1:?Usage: sync-directory.sh <project-id>}"
PROJECT_DIR="$ROOT_DIR/$PROJECT_ID"

# ---------------------------------------------------------------------------
# 1. Read project metadata from projects.json (flock-safe)
# ---------------------------------------------------------------------------
log "Reading metadata for $PROJECT_ID..."

PROJ_META=""
exec 200>"$LOCK_FILE"
flock -s 200
PROJ_META=$(jq -r --arg id "$PROJECT_ID" '.projects[] | select(.id == $id)' "$PROJECTS_JSON")
exec 200>&-

if [ -z "$PROJ_META" ]; then
  err "Project $PROJECT_ID not found in projects.json"
  exit 1
fi

PROJ_NAME=$(echo "$PROJ_META" | jq -r '.name // empty')
PROJ_CATEGORY=$(echo "$PROJ_META" | jq -r '.category // "Developer Tools"')
PROJ_LIVE_URL=$(echo "$PROJ_META" | jq -r '.live_url // empty')
PROJ_COLOR_HEX=$(echo "$PROJ_META" | jq -r '.color // "#6366F1"')

if [ -z "$PROJ_NAME" ]; then
  err "Project name is empty — cannot sync"
  exit 1
fi

# Derive a lowercase slug for the id in projects.ts
# e.g. "BrandScout" -> "brandscout", "CoinTally" -> "cointally"
TS_ID=$(echo "$PROJ_NAME" | tr '[:upper:]' '[:lower:]' | tr -d ' -')

log "Project: $PROJ_NAME (id=$TS_ID, category=$PROJ_CATEGORY)"

# ---------------------------------------------------------------------------
# 2. Check if project already exists in projects.ts
# ---------------------------------------------------------------------------
if grep -q "id: \"$TS_ID\"" "$HQ_PROJECTS_TS" 2>/dev/null; then
  ok "$PROJ_NAME already exists in foundry-hq projects.ts — skipping"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Extract tagline from spec file
# ---------------------------------------------------------------------------
# Spec file path: /Users/aumvats/Code/exploratory/{PROJECT_ID}/PROJECT-{NUMERIC}-SPEC.md
# For project IDs like "project-1774418413", NUMERIC = 1774418413
# For legacy IDs like "demoseed", try to find any SPEC.md in the dir

TAGLINE=""
DESCRIPTION=""

# Extract numeric part if present
NUMERIC_PART=$(echo "$PROJECT_ID" | sed 's/^project-//')
SPEC_FILE="$PROJECT_DIR/PROJECT-${NUMERIC_PART}-SPEC.md"

# Fallback: search for any SPEC.md in the project dir
if [ ! -f "$SPEC_FILE" ]; then
  SPEC_FILE=$(find "$PROJECT_DIR" -maxdepth 1 -name "*SPEC*.md" -print -quit 2>/dev/null || true)
fi

if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
  log "Reading spec: $SPEC_FILE"

  # Tagline: blockquote line (line starting with ">") near the top
  TAGLINE=$(sed -n '/^>/{ s/^> *//; p; q; }' "$SPEC_FILE")

  # Also try **Tagline:** "quoted text" format
  if [ -z "$TAGLINE" ]; then
    TAGLINE=$(sed -n 's/.*\*\*Tagline:\*\* *"\([^"]*\)".*/\1/p' "$SPEC_FILE" | head -1)
  fi

  # Description: first sentence of the Product Overview / What It Does section
  # Look for ## *Overview or ## *What It Does, then grab the first non-empty paragraph
  DESCRIPTION=$(awk '
    /^## .*([Oo]verview|[Ww]hat [Ii]t [Dd]oes)/ { found=1; next }
    found && /^$/ { next }
    found && /^[^#]/ {
      # Get first sentence (up to first period followed by space or end)
      match($0, /[^.]*\./)
      if (RSTART > 0) {
        print substr($0, RSTART, RLENGTH)
      } else {
        print $0
      }
      exit
    }
    found && /^#/ { exit }
  ' "$SPEC_FILE")
else
  warn "No spec file found for $PROJECT_ID"
fi

# Fallback to projects.json tagline/description if spec didn't yield results
if [ -z "$TAGLINE" ]; then
  TAGLINE=$(echo "$PROJ_META" | jq -r '.tagline // empty' | head -c 100)
fi
if [ -z "$DESCRIPTION" ]; then
  DESCRIPTION=$(echo "$PROJ_META" | jq -r '.description // empty' | head -c 200)
fi

# Final fallbacks
if [ -z "$TAGLINE" ]; then
  TAGLINE="Built with Foundry"
fi
if [ -z "$DESCRIPTION" ]; then
  DESCRIPTION="$TAGLINE"
fi

# Trim trailing whitespace and ensure no unescaped quotes
TAGLINE=$(echo "$TAGLINE" | sed 's/[[:space:]]*$//' | sed 's/"/\\"/g')
DESCRIPTION=$(echo "$DESCRIPTION" | sed 's/[[:space:]]*$//' | sed 's/"/\\"/g')

log "Tagline: $TAGLINE"
log "Description: $(echo "$DESCRIPTION" | head -c 80)..."

# ---------------------------------------------------------------------------
# 4. Map hex color to Tailwind color name
# ---------------------------------------------------------------------------
hex_to_tailwind() {
  local hex="$1"
  case "$hex" in
    "#EF4444"|"#DC2626"|"#B91C1C") echo "red" ;;
    "#F97316"|"#EA580C"|"#C2410C") echo "orange" ;;
    "#F59E0B"|"#D97706"|"#B45309") echo "amber" ;;
    "#EAB308"|"#CA8A04"|"#A16207") echo "yellow" ;;
    "#84CC16"|"#65A30D"|"#4D7C0F") echo "lime" ;;
    "#22C55E"|"#16A34A"|"#15803D"|"#10B981"|"#059669") echo "green" ;;
    "#10B981"|"#059669"|"#047857") echo "emerald" ;;
    "#14B8A6"|"#0D9488"|"#0F766E"|"#0D7377") echo "teal" ;;
    "#06B6D4"|"#0891B2"|"#0E7490") echo "cyan" ;;
    "#0EA5E9"|"#0284C7"|"#0369A1") echo "sky" ;;
    "#3B82F6"|"#2563EB"|"#1D4ED8"|"#1E40AF") echo "blue" ;;
    "#6366F1"|"#4F46E5"|"#4338CA") echo "indigo" ;;
    "#8B5CF6"|"#7C3AED"|"#6D28D9") echo "violet" ;;
    "#A855F7"|"#9333EA"|"#7E22CE") echo "purple" ;;
    "#D946EF"|"#C026D3"|"#A21CAF") echo "fuchsia" ;;
    "#EC4899"|"#DB2777"|"#BE185D") echo "pink" ;;
    "#F43F5E"|"#E11D48"|"#BE123C") echo "rose" ;;
    *) echo "indigo" ;;
  esac
}

TW_COLOR=$(hex_to_tailwind "$PROJ_COLOR_HEX")
log "Color: $PROJ_COLOR_HEX -> $TW_COLOR"

# ---------------------------------------------------------------------------
# 5. Compute iconBg and iconFg from the hex color
# ---------------------------------------------------------------------------
# iconBg: rgba version at 0.12 opacity
# iconFg: the hex itself (or a slightly darker shade)

# Convert hex to RGB
hex_r=$(printf "%d" "0x${PROJ_COLOR_HEX:1:2}")
hex_g=$(printf "%d" "0x${PROJ_COLOR_HEX:3:2}")
hex_b=$(printf "%d" "0x${PROJ_COLOR_HEX:5:2}")

ICON_BG="rgba($hex_r, $hex_g, $hex_b, 0.12)"
ICON_FG="$PROJ_COLOR_HEX"

# ---------------------------------------------------------------------------
# 6. Build the new entry and insert into projects.ts
# ---------------------------------------------------------------------------
DEFAULT_ICON='<path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15.59 14.37a6 6 0 01-5.84 7.38v-4.8m5.84-2.58a14.98 14.98 0 006.16-12.12A14.98 14.98 0 009.631 8.41m5.96 5.96a14.926 14.926 0 01-5.841 2.58m-.119-8.54a6 6 0 00-7.381 5.84h4.8m2.581-5.84a14.927 14.927 0 00-2.58 5.84m2.699 2.7c-.103.021-.207.041-.311.06a15.09 15.09 0 01-2.448-2.448 14.9 14.9 0 01.06-.312m-2.24 2.39a4.493 4.493 0 00-1.757 4.306 4.493 4.493 0 004.306-1.758M16.5 9a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z"/>'

# Build the URL line conditionally
URL_LINE=""
if [ -n "$PROJ_LIVE_URL" ]; then
  URL_LINE="    url: \"$PROJ_LIVE_URL\","
fi

# Create the new entry block
NEW_ENTRY="  {
    id: \"$TS_ID\",
    name: \"$PROJ_NAME\",
    tagline: \"$TAGLINE\",
    description:
      \"$DESCRIPTION\",
    category: \"$PROJ_CATEGORY\",
    status: \"live\",
${URL_LINE:+    $URL_LINE
}    color: \"$TW_COLOR\",
    iconBg: \"$ICON_BG\",
    iconFg: \"$ICON_FG\",
    icon: \`$DEFAULT_ICON\`,
  },"

# Fix the URL_LINE insertion (avoid double indent)
if [ -n "$PROJ_LIVE_URL" ]; then
  NEW_ENTRY="  {
    id: \"$TS_ID\",
    name: \"$PROJ_NAME\",
    tagline: \"$TAGLINE\",
    description:
      \"$DESCRIPTION\",
    category: \"$PROJ_CATEGORY\",
    status: \"live\",
    url: \"$PROJ_LIVE_URL\",
    color: \"$TW_COLOR\",
    iconBg: \"$ICON_BG\",
    iconFg: \"$ICON_FG\",
    icon: \`$DEFAULT_ICON\`,
  },"
else
  NEW_ENTRY="  {
    id: \"$TS_ID\",
    name: \"$PROJ_NAME\",
    tagline: \"$TAGLINE\",
    description:
      \"$DESCRIPTION\",
    category: \"$PROJ_CATEGORY\",
    status: \"live\",
    color: \"$TW_COLOR\",
    iconBg: \"$ICON_BG\",
    iconFg: \"$ICON_FG\",
    icon: \`$DEFAULT_ICON\`,
  },"
fi

log "Inserting entry into projects.ts..."

# Insert before the closing "];' of the projects array
# Use a temp file for portability (bash 3.2 safe)
TMPFILE=$(mktemp)
trap "rm -f '$TMPFILE'" EXIT

awk -v entry="$NEW_ENTRY" '
  /^];$/ && !done {
    print entry
    done = 1
  }
  { print }
' "$HQ_PROJECTS_TS" > "$TMPFILE"

cp "$TMPFILE" "$HQ_PROJECTS_TS"

ok "Entry added to projects.ts"

# ---------------------------------------------------------------------------
# 7. Commit and push to trigger Vercel redeploy
# ---------------------------------------------------------------------------
log "Committing and pushing to foundry-hq..."

cd "$HQ_DIR"

git add src/lib/projects.ts

# Check if there are actually staged changes
if git diff --cached --quiet; then
  warn "No changes to commit — projects.ts unchanged"
  exit 0
fi

git commit -m "Add $PROJ_NAME to project directory

Auto-synced by Foundry pipeline after deploy."

git push origin main

ok "foundry-hq updated and pushed — Vercel will auto-deploy"
log "Added: $PROJ_NAME ($TS_ID) to the directory site"
