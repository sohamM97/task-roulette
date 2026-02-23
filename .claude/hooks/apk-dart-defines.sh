#!/bin/bash
# Hook: Auto-inject --dart-define flags into flutter build apk commands
# Reads Firebase config from google-services.json and OAuth secrets from .env

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# Only act on commands that start with "flutter build apk" (not just contain it in text)
if ! echo "$command" | grep -qE '^\s*flutter build apk'; then
  echo '{}'
  exit 0
fi

# If dart-define flags already present, nothing to do
if echo "$command" | grep -q '\-\-dart-define'; then
  echo '{}'
  exit 0
fi

# Build dart-define flags
PROJECT_DIR=$(echo "$input" | jq -r '.cwd')
GS_JSON="$PROJECT_DIR/android/app/google-services.json"
ENV_FILE="$PROJECT_DIR/.env"

DART_DEFINES=""

if [ -f "$GS_JSON" ]; then
  FIREBASE_PROJECT_ID=$(jq -r '.project_info.project_id' "$GS_JSON")
  FIREBASE_API_KEY=$(jq -r '.client[0].api_key[0].current_key' "$GS_JSON")
  DART_DEFINES="--dart-define=FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID --dart-define=FIREBASE_API_KEY=$FIREBASE_API_KEY"
fi

if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    [ -z "$key" ] || [[ "$key" == \#* ]] && continue
    DART_DEFINES="$DART_DEFINES --dart-define=$key=$value"
  done < "$ENV_FILE"
fi

if [ -z "$DART_DEFINES" ]; then
  echo '{}'
  exit 0
fi

# Inject dart-defines into the command
new_command="$command $DART_DEFINES"

jq -n --arg cmd "$new_command" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecisionReason: "Auto-injected --dart-define flags from google-services.json and .env",
    updatedInput: {
      command: $cmd
    }
  }
}'
