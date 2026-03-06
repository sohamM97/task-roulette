#!/bin/bash
# Hook: Require user confirmation before merging PRs
# PRs should never be merged without explicit user approval

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

if ! echo "$command" | grep -qE '^\s*gh\s+pr\s+merge\b'; then
  echo '{}'
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: "Merging a PR — make sure you have reviewed the changes. Approve if ready to merge."
  }
}'
