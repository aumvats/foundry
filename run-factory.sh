#!/bin/bash
# ============================================================================
# FOUNDRY — Full Pipeline Runner
# ============================================================================
# Runs the complete factory loop:
#   1. Claude Cowork generates a new idea + spec
#   2. build-project.sh builds, deploys, and updates portfolio
#   3. Repeats for the next idea in the queue
#
# Usage:
#   ./run-factory.sh                  # Process all queued projects
#   ./run-factory.sh --generate 3     # Generate 3 new ideas first, then build all
#   ./run-factory.sh --build-only     # Only build queued projects (skip generation)
#
# Prerequisites:
#   - All prerequisites from build-project.sh
#   - claude CLI for both Cowork (idea gen) and Code (building)
# ============================================================================

set -e

ROOT_DIR="$HOME/Code/exploratory"
FACTORY_DIR="$ROOT_DIR/foundry"
PROJECTS_JSON="$FACTORY_DIR/projects.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "\n${BOLD}${PURPLE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${PURPLE}║         FOUNDRY — Runner              ║${NC}"
echo -e "${BOLD}${PURPLE}╚══════════════════════════════════════════════════╝${NC}\n"

# ── PARSE ARGS ──────────────────────────────────────────────────────────────
GENERATE_COUNT=0
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --generate)
      GENERATE_COUNT="$2"
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./run-factory.sh [--generate N] [--build-only]"
      exit 1
      ;;
  esac
done

# ── STEP 1: GENERATE NEW IDEAS (if requested) ──────────────────────────────
if [ "$GENERATE_COUNT" -gt 0 ] 2>/dev/null; then
  echo -e "${BLUE}[factory]${NC} Generating $GENERATE_COUNT new project ideas...\n"

  # Get existing project IDs to avoid duplicates
  EXISTING=$(jq -r '([.projects[].id, .queue[].id] | join(", "))' "$PROJECTS_JSON")

  claude -p "You are the idea generation engine for a Foundry.

CONTEXT:
- We build micro-SaaS products using free public APIs from https://github.com/public-apis/public-apis
- Each product should be a focused wrapper around 1-3 free APIs that solves a real pain point
- Target: \$1M ARR potential at \$9-\$99/mo pricing
- Must be buildable as a complete MVP in a single Claude Code session

EXISTING PROJECTS (do NOT duplicate these):
$EXISTING

TASK:
Generate exactly $GENERATE_COUNT new micro-SaaS project ideas. For each idea, output a JSON object with these fields:
- id: lowercase-hyphenated slug (e.g., 'mail-clean')
- name: Product name (e.g., 'MailClean')
- tagline: One-liner (max 60 chars)
- description: 2-3 sentences explaining what it does
- category: One of: Developer Tools, SMB Tools, Creator Tools, Finance Tools, Health Tools, Marketing Tools
- color: A hex color for the brand (pick something that fits the vibe)
- pricing: Target price point (e.g., '\$29/mo Pro')
- apis: Array of API names to use
- target_user: Who is the buyer in one sentence

Output ONLY a valid JSON array. No markdown, no explanation, just the array." > /tmp/factory-ideas.json

  # Validate and merge into projects.json queue
  if jq -e '.' /tmp/factory-ideas.json > /dev/null 2>&1; then
    # Add each idea to the queue with status 'queued'
    jq -s '.[0].queue += [.[1][] | . + {"status": "queued", "spec_dir": .id, "repo": "", "live_url": "", "vercel_project": "", "built_at": ""}] | .[0]' \
      "$PROJECTS_JSON" /tmp/factory-ideas.json > "${PROJECTS_JSON}.tmp" && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON"
    echo -e "${GREEN}[  ✓  ]${NC} Added $GENERATE_COUNT ideas to the queue"
  else
    echo -e "${RED}[  ✗  ]${NC} Failed to parse generated ideas. Check /tmp/factory-ideas.json"
  fi

  # Now generate specs for each queued idea
  QUEUED_IDS=$(jq -r '.queue[] | select(.status == "queued") | .id' "$PROJECTS_JSON")

  for IDEA_ID in $QUEUED_IDS; do
    echo -e "\n${BLUE}[factory]${NC} Generating spec for: $IDEA_ID"

    IDEA_JSON=$(jq -r ".queue[] | select(.id == \"$IDEA_ID\")" "$PROJECTS_JSON")
    IDEA_DIR="$ROOT_DIR/$IDEA_ID"
    mkdir -p "$IDEA_DIR"

    claude -p "You are a product specification writer for a Foundry.

PROJECT DETAILS:
$IDEA_JSON

TASK:
Write a complete product specification markdown file, following this exact structure. Be thorough and specific — this spec will be fed directly to Claude Code to build the entire product.

Include these sections:
1. What This Is (one paragraph)
2. Target Users (table with persona, pain point, price sensitivity)
3. APIs to Use (table with API name, purpose, auth, rate limit notes)
4. Product Flow — End to End (detailed step-by-step for every user flow: onboarding, core workflow, key features)
5. UI / UX Guidelines (color palette with exact hex codes, typography, spacing, animations, page-by-page layout specs, component library)
6. Information Architecture (route table)
7. Pricing (tier comparison table + path to \$1M ARR math)
8. Key User Flows (3-4 detailed numbered flows)
9. Technical Constraints (performance, data quality, architecture rules)
10. MVP Scope (v1 build list + v2 roadmap)

For the UI guidelines: pick either dark-first or light-first depending on the audience. Specify exact Tailwind color tokens, font sizes, border radii, animation timings. The quality bar is Linear/Vercel-level.

Output ONLY the markdown. No preamble." > "$IDEA_DIR/$(echo "$IDEA_ID" | tr '[:lower:]' '[:upper:]' | tr '-' '')-SPEC.md"

    # Generate Claude Code prompt
    claude -p "You are writing a Claude Code implementation prompt for a micro-SaaS project.

The spec file is at: $IDEA_DIR/

Read these project details:
$IDEA_JSON

Write a clear, actionable prompt that tells Claude Code exactly what to build for the v1 MVP. Include:
1. What to build (list of pages/features)
2. Scope for v1 (be specific)
3. Technical guidance (reference Section 5 of the spec for UI, Section 9 for constraints)
4. What NOT to build (v2 stuff)
5. Stack preference (React/Next.js, Tailwind, Supabase)
6. Quality bar description

The prompt should reference the spec file by name and tell Claude Code to read it first.

Output ONLY the markdown prompt. Start with '# $( jq -r ".queue[] | select(.id == \"$IDEA_ID\") | .name" "$PROJECTS_JSON") — Claude Code Implementation Prompt'" > "$IDEA_DIR/CLAUDE-CODE-PROMPT.md"

    # Move from queue to projects list
    jq "(.queue[] | select(.id == \"$IDEA_ID\") | .status) = \"queued\" |
        .projects += [.queue[] | select(.id == \"$IDEA_ID\")] |
        .queue = [.queue[] | select(.id != \"$IDEA_ID\")]" \
      "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON"

    echo -e "${GREEN}[  ✓  ]${NC} Spec generated for $IDEA_ID"
  done
fi

# ── STEP 2: BUILD ALL QUEUED/UNBUILT PROJECTS ──────────────────────────────
echo -e "\n${BLUE}[factory]${NC} Looking for projects to build..."

# Find all projects with status 'queued' that have spec files
BUILDABLE=$(jq -r '.projects[] | select(.status == "queued" or .status == "specced") | .id' "$PROJECTS_JSON")

if [ -z "$BUILDABLE" ]; then
  echo -e "${YELLOW}[ ⚠️  ]${NC} No queued projects to build."
  echo -e "${BLUE}[factory]${NC} To add projects, run: ./run-factory.sh --generate 3"

  # Show current status
  echo -e "\n${BOLD}Current Factory Status:${NC}"
  jq -r '.projects[] | "  \(.status | ascii_upcase)\t\(.name)\t\(.live_url // "—")"' "$PROJECTS_JSON"
  exit 0
fi

echo -e "${GREEN}[  ✓  ]${NC} Found $(echo "$BUILDABLE" | wc -l | tr -d ' ') projects to build"

for PROJECT_ID in $BUILDABLE; do
  echo -e "\n${PURPLE}${BOLD}════════════════════════════════════════════════════${NC}"
  echo -e "${PURPLE}${BOLD}  Building: $PROJECT_ID${NC}"
  echo -e "${PURPLE}${BOLD}════════════════════════════════════════════════════${NC}\n"

  bash "$FACTORY_DIR/build-project.sh" "$PROJECT_ID" || {
    echo -e "${RED}[  ✗  ]${NC} Build failed for $PROJECT_ID — skipping"
    jq "(.projects[] | select(.id == \"$PROJECT_ID\") | .status) = \"failed\"" \
      "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON"
    continue
  }

  echo -e "${GREEN}[  ✓  ]${NC} $PROJECT_ID built and deployed successfully"
done

# ── SUMMARY ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${PURPLE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${PURPLE}║              FACTORY RUN COMPLETE                ║${NC}"
echo -e "${BOLD}${PURPLE}╠══════════════════════════════════════════════════╣${NC}"
jq -r '.projects[] | "║  \(.status | if . == "live" then "🟢" elif . == "built" then "🔵" elif . == "building" then "🟡" elif . == "failed" then "🔴" else "⚪" end) \(.name)\t\(.live_url // "—")"' "$PROJECTS_JSON" | while read line; do
  echo -e "${BOLD}$line${NC}"
done
echo -e "${BOLD}${PURPLE}╚══════════════════════════════════════════════════╝${NC}\n"
