#!/bin/bash
# Hook: Block 'flutter run' targeting Android devices
# Running flutter run on a phone with a release build causes signature mismatch
# and wipes user data. Use 'flutter build apk --debug' + sideload instead.

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# Only act on commands that start with "flutter run" (not just contain it in text)
if ! echo "$command" | grep -qE '^\s*flutter run'; then
  echo '{}'
  exit 0
fi

# Allow if explicitly targeting linux
if echo "$command" | grep -qE '\-d\s+linux'; then
  echo '{}'
  exit 0
fi

# Block if targeting an Android device (IP address, serial number, emulator)
if echo "$command" | grep -qE '\-d\s+(emulator|android|192\.|[0-9a-fA-F]{8,})'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "BLOCKED: Never run flutter run on Android — signature mismatch will uninstall the app and wipe user data. Use `flutter build apk --debug` instead, then sideload via adb install."
    }
  }'
  exit 0
fi

# If no -d flag, block (could default to phone if connected)
if ! echo "$command" | grep -qE '\-d\s+'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "BLOCKED: flutter run without -d flag may target your Android phone and wipe user data. Use `flutter run -d linux` or `flutter build apk --debug`."
    }
  }'
  exit 0
fi

echo '{}'
