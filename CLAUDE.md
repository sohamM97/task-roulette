# TaskRoulette — Claude Code Instructions

## Project Overview

Flutter app — a DAG-based task manager where tasks can have multiple parents/children. Runs on Linux desktop (Android planned). Vibe-coded: planned/ideated by a human, implemented with AI.

## Tech Stack

- **Framework:** Flutter (SDK at `~/flutter`, added to PATH via `~/.zshrc`)
- **State management:** Provider + ChangeNotifier
- **Persistence:** sqflite with `sqflite_common_ffi` for desktop SQLite support
- **DB location:** `.dart_tool/sqflite_common_ffi/databases/task_roulette.db`

## Build & Run

```bash
# Linux desktop deps (Ubuntu/Debian)
sudo apt install -y clang ninja-build lld libsqlite3-dev

flutter pub get
flutter run -d linux
```

## Architecture

- Tasks are stored in `tasks` table, relationships in `task_relationships` (parent_id, child_id)
- Root tasks = tasks with no entry as child_id in task_relationships
- Multi-parent DAG: a task can appear under multiple parents
- Cycle prevention via recursive CTE query (`DatabaseHelper.hasPath()`)
- Navigation uses a parent stack for back navigation + breadcrumb

## Key Files

- `lib/data/database_helper.dart` — all SQLite operations
- `lib/providers/task_provider.dart` — state management, navigation stack, DAG operations
- `lib/screens/task_list_screen.dart` — main screen with grid, breadcrumb, FAB
- `lib/widgets/task_card.dart` — card with long-press menu (unlink, add parent, delete)
- `lib/widgets/task_picker_dialog.dart` — search/filter dialog for linking tasks

## Design Philosophy

The goal of this app is **minimal cognitive load**. The user wants a quick place to note down pending tasks in a structured way — but too much hierarchy/linking complexity can become a distraction from the actual tasks. Every feature should reduce friction, not add it. When making design decisions, always ask: "Does this make the user think less or more?"

## UI Conventions

- Do NOT use the word "parent" in any user-facing text. This is a task organizer, not a family tree. Use natural alternatives like "listed under", "show under", etc.
- Avoid jargon like "DAG", "node", "link" in UI — keep it simple for end users.
- Material 3 theming throughout.

## Development Preferences

- Ask user about committing and pushing occasionally — don't wait until asked.
- When setup instructions change (new deps, build steps), ask user if they want to update README.
- Capture any user-mentioned future work items as todo tasks immediately.
- Keep a persistent TODO list in the Claude memory directory.
- After completing a new feature, ask the user if they want to add test cases for it.

## GitHub

- Repo: sohamM97/task-roulette
- Branch: main
