# CLAUDE.md

## Project Overview

Flutter app — a DAG-based task manager where tasks can have multiple parents/children. Runs on Linux desktop, Android, and web. Vibe-coded: planned/ideated by a human, implemented with AI.

## Tech Stack

- **Framework:** Flutter (SDK at `~/flutter`, added to PATH via `~/.zshrc`)
- **State management:** Provider + ChangeNotifier
- **Persistence:** sqflite with `sqflite_common_ffi` for desktop SQLite support
- **DB location:** `~/.local/share/com.taskroulette.task_roulette/task_roulette.db` (via `path_provider`)

## Build, Run & Test

```bash
sudo apt install -y clang ninja-build lld libsqlite3-dev libsecret-1-dev inotify-tools
flutter pub get
./dev.sh                                          # preferred — auto hot-reloads, reads Firebase config
flutter run -d linux                              # without auto-reload
flutter analyze                                   # lint — fix ALL issues including info-level
flutter test                                      # test
flutter test --coverage                           # with coverage
```

## Architecture

- Tasks in `tasks` table, relationships in `task_relationships` (parent_id, child_id). Multi-parent DAG with cycle prevention via recursive CTE (`DatabaseHelper.hasPath()`).
- **DB migrations:** Sequential `onUpgrade` in `DatabaseHelper` (currently at v17, constant `_dbVersion`). Foreign keys via `PRAGMA foreign_keys = ON`. **NEVER modify a released migration** — if a previous version shipped with migration N, new DDL must go in migration N+1 or later. Retroactive changes to released migrations are silently skipped on devices already past that version. Also update `_validateBackup` version check (uses `_dbVersion` automatically) and the backup version test.
- **Cloud sync:** Optional Google Sign-In + Firestore via REST APIs (no Firebase SDK). `SyncService` orchestrates push/pull; mutations queued in `sync_queue` table and debounced.
- **When adding a column to `tasks`:** Also add to `Task` model (`toMap`/`fromMap`/`copyWith`), `taskToFirestoreFields`, and `taskFromFirestoreDoc` in `firestore_service.dart`.
- **Provider pattern:** `TaskProvider._refreshCurrentList()` reloads children only, NOT `_currentParent` — see gotcha below.
- Tests use `sqflite_common_ffi` with `inMemoryDatabasePath` and reset DB in `setUp()`. No mocking — real SQL against in-memory SQLite.

### Known Gotcha: Stale `_currentParent`

When mutating a task that is `_currentParent` (e.g. rename, start, unstart), the provider must rebuild `_currentParent` as a new `Task` object. `_refreshCurrentList()` only refreshes `_tasks` (children). Without this, leaf detail view shows stale data.

## Design Philosophy

**Minimal cognitive load.** Every feature should reduce friction. Prefer sensible defaults over configuration. Avoid jargon like "DAG", "node", "parent" in UI — use natural alternatives like "listed under", "show under". Material 3 theming throughout.

## Slash Commands

- Each command in `.claude/commands/` is self-documenting — read the file for details.
- `/code-review` and `/sec-review` — **always run in a fresh session**, not the current one.
- `/code-review-fix` and `/sec-review-fix` — can run in any session **except** the one where the corresponding review was run.

## Hooks

Hooks in `.claude/hooks/` enforce guardrails automatically:
- **`pre-commit-analyze.sh`** — blocks `git commit` if `flutter analyze` fails
- **`guard-git-tag.sh`** — requires user confirmation for `git tag` (use `/release`)
- **`guard-pr-merge.sh`** — requires user confirmation for `gh pr merge`
- **`block-flutter-run-android.sh`** — blocks `flutter run` without `-d linux`
- **`apk-dart-defines.sh`** — auto-injects `--dart-define` flags into `flutter build apk`
- **`guard-adb-install.sh`** — requires user confirmation for `adb install`

## Development Preferences

- **Before exiting plan mode**, ask the user if they want to create a feature branch first (via `/feature`).
- Ask user about committing and pushing occasionally — don't wait until asked. Remind them to review changes and test on Linux (via `./dev.sh`) first.
- After completing a new feature, ask the user if they want to add test cases for it.
- When a bug is found and confirmed reproducible, always add a test case for it.
- When writing tests in bulk, use `flutter test --coverage` + `genhtml` to find gaps.
- Capture any user-mentioned future work items as todo tasks immediately.
- When setup instructions change (new deps, build steps), ask user if they want to update README.
- **Widget tests with sqflite_ffi**: `testWidgets` runs in `FakeAsync` — use `databaseFactoryFfiNoIsolate` in `setUpAll`. Wrap DB inserts in `tester.runAsync()`. For widget loading, use `runAsync(Future.delayed(10ms)) + pump()` cycles. Provide `AuthProvider` and `SyncService` in MultiProvider for screens that need them.

## Mobile Debugging & Testing

- **Don't jump to fixes** when something fails on phone — ask user if they want to troubleshoot with ADB/logcat first.
- Use `/debug-build` to build and sideload. Hooks block `flutter run` on Android and auto-inject `--dart-define` flags.
- Before pushing a new version, remind user to **test on phone** and **export their data** first.

## Android Signing

- Debug and release builds use the same keystore (`android/upload-keystore.jks`).
- `upload-keystore.jks` and `key.properties` are **gitignored**. Same keystore in `KEYSTORE_BASE64` GitHub Actions secret.
- **On a new machine:** Check if keystore files exist before building for Android. Without them, signature mismatch will prevent install over existing app.

## GitHub

- Repo: sohamM97/task-roulette
- **Releases:** Auto-created via GitHub Actions on tag push. Use `/release` to tag. Don't use `gh release create`.
- Hooks enforce confirmation prompts for `git tag` and `gh pr merge`.
