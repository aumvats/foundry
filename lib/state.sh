#!/bin/bash
# ============================================================================
# lib/state.sh — Shared flock-safe state helpers
# Source this file: source "$FACTORY_DIR/lib/state.sh"
# ============================================================================

# Requires: FACTORY_DIR, PROJECTS_JSON, LOCK_FILE already set by caller

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
