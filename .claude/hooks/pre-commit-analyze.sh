#!/bin/bash
# Hook: Run flutter analyze before git commit to catch lint issues early

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# Only act on git commit commands
if ! echo "$command" | grep -qE '(^|\s*&&\s*|\s*;\s*)git\s+commit\b'; then
  echo '{}'
  exit 0
fi

# Skip if --amend with no other changes (just rewording)
if echo "$command" | grep -qE '\-\-amend'; then
  echo '{}'
  exit 0
fi

# Run flutter analyze
output=$(flutter analyze 2>&1)
exit_code=$?

if [ $exit_code -ne 0 ]; then
  # Extract just the issue lines
  issues=$(echo "$output" | grep -E '^\s*(info|warning|error)\s+•' | head -10)
  jq -n --arg reason "flutter analyze failed. Fix issues before committing:
$issues" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
else
  echo '{}'
fi
