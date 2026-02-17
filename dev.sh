#!/bin/bash
# Auto-hot-reload dev script for TaskRoulette
# Watches lib/ for .dart file changes and triggers hot reload automatically.
# Requires: inotify-tools (sudo apt install -y inotify-tools)

PID_FILE="/tmp/flutter-taskroulette.pid"

cleanup() {
  echo "Stopping..."
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" 2>/dev/null
  fi
  if [ -n "$FLUTTER_PID" ]; then
    kill "$FLUTTER_PID" 2>/dev/null
  fi
  rm -f "$PID_FILE"
  exit 0
}

trap cleanup SIGINT SIGTERM

# Load Firebase/OAuth secrets for cloud sync (optional)
DART_DEFINES=""
if [ -f ".env" ]; then
  while IFS='=' read -r key value; do
    [ -z "$key" ] || [[ "$key" == \#* ]] && continue
    DART_DEFINES="$DART_DEFINES --dart-define=$key=$value"
  done < .env
fi

# Start Flutter in the background with a PID file
flutter run -d linux --pid-file "$PID_FILE" $DART_DEFINES &
FLUTTER_PID=$!

# Wait for the PID file to appear (Flutter takes a moment to start)
echo "Waiting for Flutter to start..."
while [ ! -f "$PID_FILE" ]; do
  sleep 1
  # Check if Flutter exited early
  if ! kill -0 "$FLUTTER_PID" 2>/dev/null; then
    echo "Flutter failed to start."
    exit 1
  fi
done

DART_PID=$(cat "$PID_FILE")
echo "Flutter running (PID: $DART_PID). Watching lib/ for changes..."

# Watch for .dart file changes and send SIGUSR1 (hot reload)
inotifywait -m -r -e close_write,moved_to,create --include '\.dart$' lib/ | while read -r; do
  echo "[$(date +%H:%M:%S)] Change detected — hot reloading..."
  kill -USR1 "$DART_PID" 2>/dev/null
done &
WATCHER_PID=$!

# Wait for Flutter to finish
wait "$FLUTTER_PID"
cleanup
