#!/bin/bash
# Hook: Require user confirmation before creating git tags
# Tags should only be created via /release workflow

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# Only act on git tag commands (not git tag -l or git tag --list)
if ! echo "$command" | grep -qE '^\s*git\s+tag\b'; then
  echo '{}'
  exit 0
fi

# Allow listing tags
if echo "$command" | grep -qE '\-l\b|\-\-list\b'; then
  echo '{}'
  exit 0
fi

# Allow deleting tags
if echo "$command" | grep -qE '\-d\b|\-\-delete\b'; then
  echo '{}'
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: "Creating a git tag — use /release for releases. Approve if this is intentional."
  }
}'
