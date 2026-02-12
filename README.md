# TaskRoulette

A DAG-based task manager built with Flutter. Tasks can have multiple parents and children, forming a directed acyclic graph. Navigate the hierarchy and randomly pick a task at any level.

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
   sudo apt install -y clang ninja-build lld libsqlite3-dev
   ```

### Install & Run

```bash
flutter pub get
flutter run -d linux
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
    ├── task_item.dart        # Task row (tap to navigate, swipe to delete)
    ├── add_task_dialog.dart  # New task dialog
    └── random_result_dialog.dart # Random pick result
```
