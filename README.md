# TaskRoulette

A DAG-based task manager built with Flutter. Tasks can have multiple parents and children, forming a directed acyclic graph. Navigate the hierarchy and randomly pick a task at any level.

> **Note:** This app was vibe-coded — planned and ideated by a human, implemented with AI assistance.

## Features

- Hierarchical task management (DAG structure)
- Random task selection with "Go Deeper" for recursive picks
- SQLite persistence
- Material 3 UI

## Setup

### Prerequisites

1. **Flutter SDK**
   ```bash
   git clone --depth 1 --branch stable https://github.com/flutter/flutter.git ~/flutter
   echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```

2. **Linux desktop dependencies** (Ubuntu/Debian)
   ```bash
   sudo apt install -y clang ninja-build lld libsqlite3-dev inotify-tools
   ```

3. **Android build dependencies** (optional, for APK builds)
   ```bash
   sudo apt install -y openjdk-17-jdk lib32stdc++6 lib32z1
   ```
   Then install the Android SDK command-line tools from https://developer.android.com/studio (under "Command line tools only") and set up:
   ```bash
   mkdir -p ~/Android/Sdk/cmdline-tools
   # Extract downloaded zip, move contents to ~/Android/Sdk/cmdline-tools/latest/
   export ANDROID_HOME=$HOME/Android/Sdk
   export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
   sdkmanager "platform-tools" "platforms;android-36" "build-tools;35.0.0" "build-tools;28.0.3"
   flutter config --android-sdk $HOME/Android/Sdk
   flutter doctor --android-licenses
   ```

### Install dependencies (first time only)

```bash
flutter pub get
```

### Run

```bash
./dev.sh
```

This starts the app and watches `lib/` for `.dart` file changes, triggering hot reload automatically — no need to press anything.

To run without auto-reload:

```bash
flutter run -d linux
```

Then press `r` for hot reload or `R` for hot restart manually.

### Build debug APK (Android)

```bash
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk` — transfer to your phone and install.

### Test

```bash
flutter test
```

Run this before committing to catch regressions. Tests cover the Task model, database operations (using sqflite_ffi in-memory), and widget rendering.

To run a specific test file:

```bash
flutter test test/models/task_test.dart
```

## Project Structure

```
lib/
├── main.dart                 # App entry, theme, Provider setup
├── models/
│   ├── task.dart             # Task model
│   └── task_relationship.dart # Parent-child relationship model
├── data/
│   └── database_helper.dart  # SQLite database operations
├── providers/
│   └── task_provider.dart    # State management (ChangeNotifier)
├── screens/
│   └── task_list_screen.dart # Main screen
└── widgets/
    ├── task_card.dart        # Task grid card (tap, long-press for actions)
    ├── task_picker_dialog.dart # Search/filter dialog for linking tasks
    ├── leaf_task_detail.dart  # Leaf task detail view with Done action
    ├── empty_state.dart      # Empty state placeholder
    ├── add_task_dialog.dart  # New task dialog
    └── random_result_dialog.dart # Random pick result

test/
├── models/
│   └── task_test.dart        # Task model unit tests
├── data/
│   └── database_helper_test.dart # DB completion/filtering tests
└── widgets/
    └── leaf_task_detail_test.dart # Leaf detail widget tests
```
