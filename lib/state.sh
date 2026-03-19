#!/bin/bash
# ============================================================================
# lib/state.sh — Shared flock-safe state helpers
# Source this file: source "$FACTORY_DIR/lib/state.sh"
# ============================================================================

# Requires: FACTORY_DIR, PROJECTS_JSON, LOCK_FILE already set by caller

# Source Linear integration if configured (silently skip if not set up yet)
if [ -f "${FACTORY_DIR}/lib/linear-config.sh" ]; then
  source "${FACTORY_DIR}/lib/linear-config.sh"
fi
if [ -f "${FACTORY_DIR}/lib/linear.sh" ]; then
  source "${FACTORY_DIR}/lib/linear.sh"
fi

# ---------------------------------------------------------------------------
# notify <title> <message> [urgent]
# Persistent macOS alert dialog — stays until user clicks OK.
# Pass "urgent" as 3rd arg to use critical (red) style, otherwise informational.
# Runs in background (&) so it never blocks the pipeline.
# Falls back silently if osascript is unavailable (e.g. SSH sessions).
# ---------------------------------------------------------------------------
notify() {
  local title="$1"
  local msg="$2"
  local style="informational"
  [ "${3:-}" = "urgent" ] && style="critical"
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display alert \"$title\" message \"$msg\" as $style" 2>/dev/null &
}

# ---------------------------------------------------------------------------
# emit_event <type> [key=value ...]
# Appends a structured JSON line to logs/events.jsonl
# Example: emit_event "spec_killed" "project_id=$ID" "project_name=Foo" "score=31"
# Requires: LOG_DIR set by caller
# ---------------------------------------------------------------------------
emit_event() {
  local type="$1"; shift
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local json="{\"ts\":\"$ts\",\"type\":\"$type\""
  while [ $# -gt 0 ]; do
    local pair="$1"; shift
    local key="${pair%%=*}"
    local val="${pair#*=}"
    val=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
    json="$json,\"$key\":\"$val\""
  done
  json="$json}"
  echo "$json" >> "$LOG_DIR/events.jsonl"
}

# ---------------------------------------------------------------------------
# append_history <icon> <label> <detail>
# Appends a human-readable line to logs/history.md
# Example: append_history "❌" "KILLED" "PulseCheck — API economics"
# Requires: LOG_DIR set by caller
# ---------------------------------------------------------------------------
append_history() {
  local icon="$1"
  local label="$2"
  local detail="$3"
  local ts; ts=$(date "+%Y-%m-%d %H:%M")
  printf "%s  %-10s  %s  %s\n" "$ts" "$label" "$icon" "$detail" >> "$LOG_DIR/history.md"
}

# ---------------------------------------------------------------------------
# write_projects_json <jq-filter>
# Thread-safe projects.json update via flock
# ---------------------------------------------------------------------------
write_projects_json() {
  local filter="$1"
  (
    flock -x 200
    jq "$filter" "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" \
      && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON"
  ) 200>"$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# update_project_field <project-id> <field-path> <value>
# e.g. update_project_field demoseed .status '"built"'
# ---------------------------------------------------------------------------
update_project_field() {
  local pid="$1"
  local field="$2"
  local value="$3"
  write_projects_json "(.projects[] | select(.id == \"$pid\") | $field) = $value"
}

# ---------------------------------------------------------------------------
# get_project_field <project-id> <field-path>
# e.g. get_project_field demoseed .status
# ---------------------------------------------------------------------------
get_project_field() {
  local pid="$1"
  local field="$2"
  jq -r ".projects[] | select(.id == \"$pid\") | $field" "$PROJECTS_JSON" 2>/dev/null
}

# ---------------------------------------------------------------------------
# add_project_to_json <json-object-string>
# Thread-safe append to .projects array
# ---------------------------------------------------------------------------
add_project_to_json() {
  local obj="$1"
  (
    flock -x 200
    jq ".projects += [$obj]" "$PROJECTS_JSON" > "${PROJECTS_JSON}.tmp" \
      && mv "${PROJECTS_JSON}.tmp" "$PROJECTS_JSON"
  ) 200>"$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# projects_by_status <status>
# Returns newline-separated list of project IDs with given status
# ---------------------------------------------------------------------------
projects_by_status() {
  local status="$1"
  jq -r ".projects[] | select(.status == \"$status\") | .id" "$PROJECTS_JSON" 2>/dev/null
}
