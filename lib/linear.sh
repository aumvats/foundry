#!/bin/bash
# ============================================================================
# lib/linear.sh — Linear API Integration Helper
# ============================================================================
# Source this after lib/linear-config.sh is loaded (state.sh handles both).
# All functions fail silently — Linear outage never blocks the pipeline.
# ============================================================================

LINEAR_API="https://api.linear.app/graphql"

# ---------------------------------------------------------------------------
# linear_enabled
# Returns 0 if Linear is configured, non-zero otherwise
# ---------------------------------------------------------------------------
linear_enabled() {
  [ -n "${LINEAR_API_KEY:-}" ] && [ -n "${LINEAR_TEAM_ID:-}" ]
}

# ---------------------------------------------------------------------------
# _linear_state_id <state_name>
# Maps a human-readable state name to its UUID from config
# ---------------------------------------------------------------------------
_linear_state_id() {
  case "$1" in
    Todo|todo)                   echo "${LINEAR_STATE_TODO:-}" ;;
    "In Progress"|in_progress)   echo "${LINEAR_STATE_IN_PROGRESS:-}" ;;
    "In Review"|in_review)       echo "${LINEAR_STATE_IN_REVIEW:-}" ;;
    Done|done)                   echo "${LINEAR_STATE_DONE:-}" ;;
    Cancelled|cancelled)         echo "${LINEAR_STATE_CANCELLED:-}" ;;
    *)                           echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# _linear_label_id <label_name>
# Maps a label name to its UUID from config
# ---------------------------------------------------------------------------
_linear_label_id() {
  case "$1" in
    Spec|spec)     echo "${LINEAR_LABEL_SPEC:-}" ;;
    Build|build)   echo "${LINEAR_LABEL_BUILD:-}" ;;
    Deploy|deploy) echo "${LINEAR_LABEL_DEPLOY:-}" ;;
    *)             echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# _linear_graphql <payload_json>
# POST a GraphQL payload to Linear API. Returns raw JSON response.
# ---------------------------------------------------------------------------
_linear_graphql() {
  local payload="$1"
  curl -s \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_API_KEY}" \
    --max-time 15 \
    -d "$payload" \
    "$LINEAR_API" 2>/dev/null
}

# ---------------------------------------------------------------------------
# linear_create_issue <title> <description> <state_name> <label_name>
# Creates a Linear issue. Echoes the issue UUID on success, empty on failure.
# ---------------------------------------------------------------------------
linear_create_issue() {
  local title="$1"
  local description="$2"
  local state_name="$3"
  local label_name="${4:-}"

  linear_enabled || { echo ""; return 0; }

  local state_id; state_id=$(_linear_state_id "$state_name")
  local label_id; label_id=$(_linear_label_id "$label_name")

  # Build input object safely with jq
  local input
  input=$(jq -n \
    --arg teamId "$LINEAR_TEAM_ID" \
    --arg title "$title" \
    --arg description "$description" \
    --arg stateId "$state_id" \
    --arg labelId "$label_id" \
    '{
      teamId: $teamId,
      title: $title,
      description: $description,
      stateId: (if $stateId != "" then $stateId else null end),
      labelIds: (if $labelId != "" then [$labelId] else [] end)
    } | with_entries(select(.value != null and .value != []))') || { echo ""; return 0; }

  local query='mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --argjson input "$input" \
    '{query: $query, variables: {input: $input}}') || { echo ""; return 0; }

  local response
  response=$(_linear_graphql "$payload") || { echo ""; return 0; }

  jq -r '.data.issueCreate.issue.id // empty' <<< "$response" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# linear_update_state <issue_id> <state_name>
# Moves an issue to a new workflow state.
# ---------------------------------------------------------------------------
linear_update_state() {
  local issue_id="$1"
  local state_name="$2"

  linear_enabled || return 0
  [ -z "${issue_id:-}" ] && return 0

  local state_id; state_id=$(_linear_state_id "$state_name")
  [ -z "$state_id" ] && return 0

  local query='mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg id "$issue_id" \
    --arg stateId "$state_id" \
    '{query: $query, variables: {id: $id, input: {stateId: $stateId}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_update_title <issue_id> <new_title>
# Updates the title of an issue (used to correct placeholder names).
# ---------------------------------------------------------------------------
linear_update_title() {
  local issue_id="$1"
  local new_title="$2"

  linear_enabled || return 0
  [ -z "${issue_id:-}" ] && return 0

  local query='mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg id "$issue_id" \
    --arg title "$new_title" \
    '{query: $query, variables: {id: $id, input: {title: $title}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_add_comment <issue_id> <body>
# Appends a Markdown comment to a Linear issue.
# ---------------------------------------------------------------------------
linear_add_comment() {
  local issue_id="$1"
  local body="$2"

  linear_enabled || return 0
  [ -z "${issue_id:-}" ] && return 0

  local query='mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg issueId "$issue_id" \
    --arg body "$body" \
    '{query: $query, variables: {input: {issueId: $issueId, body: $body}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_create_project <name> <description> <state>
# Creates a Linear Project. state: planned | started | completed | cancelled
# Echoes the project ID on success, empty on failure.
# ---------------------------------------------------------------------------
linear_create_project() {
  local name="$1"
  local description="$2"
  local state="${3:-started}"

  linear_enabled || { echo ""; return 0; }

  local query='mutation($input: ProjectCreateInput!) { projectCreate(input: $input) { success project { id } } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg teamId "$LINEAR_TEAM_ID" \
    --arg name "$name" \
    --arg description "$description" \
    --arg state "$state" \
    '{query: $query, variables: {input: {name: $name, teamIds: [$teamId], description: $description, state: $state}}}') || { echo ""; return 0; }

  local response
  response=$(_linear_graphql "$payload") || { echo ""; return 0; }

  jq -r '.data.projectCreate.project.id // empty' <<< "$response" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# linear_assign_to_project <issue_id> <project_id>
# Assigns an issue to a Linear Project.
# ---------------------------------------------------------------------------
linear_assign_to_project() {
  local issue_id="$1"
  local project_id="$2"

  linear_enabled || return 0
  [ -z "${issue_id:-}" ] || [ -z "${project_id:-}" ] && return 0

  local query='mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg id "$issue_id" \
    --arg projectId "$project_id" \
    '{query: $query, variables: {id: $id, input: {projectId: $projectId}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_complete_project <project_id>
# Marks a Linear Project as completed.
# ---------------------------------------------------------------------------
linear_complete_project() {
  local project_id="$1"

  linear_enabled || return 0
  [ -z "${project_id:-}" ] && return 0

  local query='mutation($id: String!, $input: ProjectUpdateInput!) { projectUpdate(id: $id, input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg id "$project_id" \
    '{query: $query, variables: {id: $id, input: {state: "completed"}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_set_description <project_id> <description_markdown>
# Updates the description of a Linear Project.
# ---------------------------------------------------------------------------
linear_set_description() {
  local project_id="$1"
  local description="$2"

  linear_enabled || return 0
  [ -z "${project_id:-}" ] && return 0

  local query='mutation($id: String!, $input: ProjectUpdateInput!) { projectUpdate(id: $id, input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg id "$project_id" \
    --arg description "$description" \
    '{query: $query, variables: {id: $id, input: {description: $description}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_post_update <project_id> <body_markdown> <health>
# Posts a Project Update (appears in the Updates tab timeline).
# health: onTrack | atRisk | offTrack
# ---------------------------------------------------------------------------
linear_post_update() {
  local project_id="$1"
  local body="$2"
  local health="${3:-onTrack}"

  linear_enabled || return 0
  [ -z "${project_id:-}" ] && return 0

  local query='mutation($input: ProjectUpdateCreateInput!) { projectUpdateCreate(input: $input) { success projectUpdate { id } } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg projectId "$project_id" \
    --arg body "$body" \
    --arg health "$health" \
    '{query: $query, variables: {input: {projectId: $projectId, body: $body, health: $health}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_add_project_link <project_id> <url> <label>
# Adds a named link to the project sidebar (Resources section).
# ---------------------------------------------------------------------------
linear_add_project_link() {
  local project_id="$1"
  local url="$2"
  local label="$3"

  linear_enabled || return 0
  [ -z "${project_id:-}" ] || [ -z "${url:-}" ] && return 0

  local query='mutation($input: ProjectLinkCreateInput!) { projectLinkCreate(input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg projectId "$project_id" \
    --arg url "$url" \
    --arg label "$label" \
    '{query: $query, variables: {input: {projectId: $projectId, url: $url, label: $label}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}

# ---------------------------------------------------------------------------
# linear_link_issues <blocking_id> <blocked_id>
# Creates a "blocks" relation: blocking_id → blocks → blocked_id
# ---------------------------------------------------------------------------
linear_link_issues() {
  local blocking_id="$1"
  local blocked_id="$2"

  linear_enabled || return 0
  [ -z "${blocking_id:-}" ] || [ -z "${blocked_id:-}" ] && return 0

  local query='mutation($input: IssueRelationCreateInput!) { issueRelationCreate(input: $input) { success } }'
  local payload
  payload=$(jq -n \
    --arg query "$query" \
    --arg issueId "$blocking_id" \
    --arg relatedIssueId "$blocked_id" \
    '{query: $query, variables: {input: {issueId: $issueId, relatedIssueId: $relatedIssueId, type: "blocks"}}}') || return 0

  _linear_graphql "$payload" > /dev/null || true
}
