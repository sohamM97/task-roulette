#!/bin/bash
# Hook: Require user confirmation before installing APK on phone
# Prevents accidental installs over production data

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# Only act on adb install commands
if ! echo "$command" | grep -qE '^\s*adb\s+install\b'; then
  echo '{}'
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: "Installing debug APK on phone — this will replace the current app. Approve to proceed."
  }
}'
