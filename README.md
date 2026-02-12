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
    ├── empty_state.dart      # Empty state placeholder
    ├── add_task_dialog.dart  # New task dialog
    └── random_result_dialog.dart # Random pick result
```
