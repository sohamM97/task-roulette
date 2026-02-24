# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flutter app — a DAG-based task manager where tasks can have multiple parents/children. Runs on Linux desktop and Android. Vibe-coded: planned/ideated by a human, implemented with AI.

## Tech Stack

- **Framework:** Flutter (SDK at `~/flutter`, added to PATH via `~/.zshrc`)
- **State management:** Provider + ChangeNotifier
- **Persistence:** sqflite with `sqflite_common_ffi` for desktop SQLite support
- **DB location:** `~/.local/share/com.taskroulette.task_roulette/task_roulette.db` (via `path_provider`)

## Build, Run & Test

```bash
# Linux desktop deps (Ubuntu/Debian)
sudo apt install -y clang ninja-build lld libsqlite3-dev inotify-tools

flutter pub get

# Run (preferred — auto hot-reloads on save, reads Firebase config from google-services.json)
./dev.sh

# Run without auto-reload
flutter run -d linux

# Lint
flutter analyze

# Test
flutter test
flutter test test/path/to/file.dart          # single file
flutter test --coverage                       # with coverage (writes lcov.info)
```

## Architecture

- Tasks are stored in `tasks` table, relationships in `task_relationships` (parent_id, child_id)
- Root tasks = tasks with no entry as child_id in task_relationships
- Multi-parent DAG: a task can appear under multiple parents
- Cycle prevention via recursive CTE query (`DatabaseHelper.hasPath()`)
- Navigation uses a parent stack for back navigation + breadcrumb
- **Database migrations:** Sequential `onUpgrade` in `DatabaseHelper` (currently at v13). New columns added via ALTER TABLE. Foreign keys enabled via `PRAGMA foreign_keys = ON`.
- **Cloud sync layer:** Optional Google Sign-In + Firestore via REST APIs (no Firebase SDK). `SyncService` orchestrates push/pull; mutations are queued in `sync_queue` table and debounced.
- **Provider pattern:** `TaskProvider._refreshCurrentList()` reloads children of `_currentParent` from DB, concurrently fetches blocked-task info, sorts, then calls `notifyListeners()`. It does NOT refresh `_currentParent` itself — see gotcha below.

### Known Gotcha: Stale `_currentParent`

When mutating a task that is `_currentParent` (e.g. rename, start, unstart), the provider must update `_currentParent` by constructing a new `Task` object. `_refreshCurrentList()` only refreshes `_tasks` (children), not `_currentParent`. Without this, the leaf detail view shows stale data until the user navigates away and back. Always check `_currentParent?.id == taskId` and rebuild the Task object when mutating task fields.

## Key Files

- `lib/data/database_helper.dart` — all SQLite operations, schema, migrations
- `lib/providers/task_provider.dart` — state management, navigation stack, DAG operations
- `lib/screens/task_list_screen.dart` — main screen with grid, breadcrumb, FAB
- `lib/widgets/task_card.dart` — card with long-press menu (unlink, add parent, delete)
- `lib/widgets/task_picker_dialog.dart` — search/filter dialog for linking tasks
- `lib/services/sync_service.dart` — cloud sync orchestration (push/pull/migration)
- `lib/services/auth_service.dart` — Google Sign-In + Firebase Auth REST API
- `docs/DESIGN_PSYCHOLOGY.md` — ADHD-friendly design rationale and weighted random selection algorithm
- `docs/PERFORMANCE.md` — database optimizations and performance considerations
### Test Setup

Tests use `sqflite_common_ffi` with `inMemoryDatabasePath` and reset DB in `setUp()` for isolation. No mocking of the DB layer — tests run real SQL against in-memory SQLite.

## Design Philosophy

The goal of this app is **minimal cognitive load**. The user wants a quick place to note down pending tasks in a structured way — but too much hierarchy/linking complexity can become a distraction from the actual tasks. Every feature should reduce friction, not add it. When making design decisions, always ask: "Does this make the user think less or more?"

**Too many choices = cognitive overload.** Don't present the user with options they don't need. Prefer sensible defaults over configuration. If a feature requires the user to make decisions unrelated to their tasks, it's adding friction.

## UI Conventions

- Do NOT use the word "parent" in any user-facing text. This is a task organizer, not a family tree. Use natural alternatives like "listed under", "show under", etc.
- Avoid jargon like "DAG", "node", "link" in UI — keep it simple for end users.
- Material 3 theming throughout.

## Slash Commands

- `/code-review` and `/sec-review` — **always run these in a fresh Claude Code session**, not the current one. They need a clean context window for thorough review. Remind the user if they try to run them mid-session.
- `/code-review-fix` and `/sec-review-fix` — can run in any session **except** the one where the corresponding `/code-review` or `/sec-review` was run.

## Development Preferences

- Ask user about committing and pushing occasionally — don't wait until asked. But first remind them to review the changes and test on Linux (via `./dev.sh`, not `flutter build`) before committing.
- Before pushing a new release (tagging a version), remind the user to test on their phone first.
- **Always update `version:` in `pubspec.yaml`** to match the tag version before committing and tagging a release.
- When setup instructions change (new deps, build steps), ask user if they want to update README.
- Capture any user-mentioned future work items as todo tasks immediately.
- Keep a persistent TODO list in the Claude memory directory.
- **Before exiting plan mode to implement**, ask the user if they want to create a feature branch first (via `/feature`). If the task warranted a plan, it likely warrants its own branch.
- After completing a new feature, ask the user if they want to add test cases for it.
- When a bug is found and confirmed reproducible, always add a test case for it.
- When writing tests in bulk, run `flutter test --coverage` and check `lcov.info` to identify remaining gaps. Use `genhtml` or similar to inspect per-file line coverage.

## Mobile Debugging & Testing

- When something doesn't work on the user's phone, **don't jump to fixes**. First ask the user if they want to troubleshoot using ADB, logcat, etc.
- **`flutter run` on Android is blocked by a hook** (`.claude/hooks/block-flutter-run-android.sh`) — signature mismatch with a release build will uninstall the app and wipe user data. Use `flutter build apk --debug` + sideload instead.
- **`--dart-define` flags are auto-injected by a hook** (`.claude/hooks/apk-dart-defines.sh`) when running `flutter build apk`. The hook reads Firebase config from `google-services.json` and OAuth secrets from `.env`. No manual flag construction needed.
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
