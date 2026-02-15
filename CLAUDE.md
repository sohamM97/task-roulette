# TaskRoulette — Claude Code Instructions

## Project Overview

Flutter app — a DAG-based task manager where tasks can have multiple parents/children. Runs on Linux desktop (Android planned). Vibe-coded: planned/ideated by a human, implemented with AI.

## Tech Stack

- **Framework:** Flutter (SDK at `~/flutter`, added to PATH via `~/.zshrc`)
- **State management:** Provider + ChangeNotifier
- **Persistence:** sqflite with `sqflite_common_ffi` for desktop SQLite support
- **DB location:** `~/.local/share/com.taskroulette.task_roulette/task_roulette.db` (via `path_provider`)

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

**Too many choices = cognitive overload.** Don't present the user with options they don't need. Prefer sensible defaults over configuration. If a feature requires the user to make decisions unrelated to their tasks, it's adding friction.

## UI Conventions

- Do NOT use the word "parent" in any user-facing text. This is a task organizer, not a family tree. Use natural alternatives like "listed under", "show under", etc.
- Avoid jargon like "DAG", "node", "link" in UI — keep it simple for end users.
- Material 3 theming throughout.

## Development Preferences

- Ask user about committing and pushing occasionally — don't wait until asked. But first remind them to review the changes and test before committing.
- When setup instructions change (new deps, build steps), ask user if they want to update README.
- Capture any user-mentioned future work items as todo tasks immediately.
- Keep a persistent TODO list in the Claude memory directory.
- After completing a new feature, ask the user if they want to add test cases for it.
- When a bug is found and confirmed reproducible, always add a test case for it.

## Mobile Debugging & Testing

- When something doesn't work on the user's phone, **don't jump to fixes**. First ask the user if they want to troubleshoot using ADB, logcat, etc.
- **NEVER** run `flutter run` on the phone when a release build is installed — the signature mismatch will uninstall the app and wipe user data. Instead, build a debug APK (`flutter build apk --debug`), back up the app data first, then sideload.
- Before pushing a new version/tag, ask the user if they want to test with a debug build on their phone first.
- When pushing a new version, remind the user to **export their data** from the phone app before installing the new version.

## Android Signing

- Both debug and release builds use the same keystore (`android/upload-keystore.jks`) so APKs can be installed over each other without data loss.
- `upload-keystore.jks` and `key.properties` are **gitignored** — they won't be present on a fresh clone.
- The same keystore is stored as `KEYSTORE_BASE64` in GitHub Actions secrets (write-only, can't be downloaded).
- **On a new machine:** Before building for Android, check if `android/upload-keystore.jks` and `android/key.properties` exist. If not, ask the user to provide them (they should have a backup). Without these files, builds fall back to the default Android debug key, causing signature mismatch with any existing install on the phone.

## GitHub

- Repo: sohamM97/task-roulette
- Branch: main
- **Releases:** Auto-created via GitHub Actions on tag push — just push the tag (e.g. `git tag v0.3.0 && git push origin v0.3.0`), don't manually create with `gh release create`.
