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
- **DB migrations:** Sequential `onUpgrade` in `DatabaseHelper` (currently at v14). Foreign keys via `PRAGMA foreign_keys = ON`.
- **Cloud sync:** Optional Google Sign-In + Firestore via REST APIs (no Firebase SDK). `SyncService` orchestrates push/pull; mutations queued in `sync_queue` table and debounced.
- **Provider pattern:** `TaskProvider._refreshCurrentList()` reloads children only, NOT `_currentParent` — see gotcha below.
- Tests use `sqflite_common_ffi` with `inMemoryDatabasePath` and reset DB in `setUp()`. No mocking — real SQL against in-memory SQLite.

### Known Gotcha: Stale `_currentParent`

When mutating a task that is `_currentParent` (e.g. rename, start, unstart), the provider must rebuild `_currentParent` as a new `Task` object. `_refreshCurrentList()` only refreshes `_tasks` (children). Without this, leaf detail view shows stale data.

## Design Philosophy

**Minimal cognitive load.** Every feature should reduce friction. Prefer sensible defaults over configuration. Avoid jargon like "DAG", "node", "parent" in UI — use natural alternatives like "listed under", "show under". Material 3 theming throughout.

## Slash Commands

- `/code-review` and `/sec-review` — **always run in a fresh session**, not the current one.
- `/code-review-fix` and `/sec-review-fix` — can run in any session **except** the one where the corresponding review was run.

## Development Preferences

- **Always run `flutter analyze` before committing** — fix all issues including `info`-level. Exits non-zero on any issue.
- **Always update `version:` in `pubspec.yaml`** to match the tag version before tagging a release.
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
- **`flutter run` on Android is blocked by a hook** — use `flutter build apk --debug` + `adb install` instead.
- **`--dart-define` flags are auto-injected by a hook** when running `flutter build apk` (reads from `google-services.json` and `.env`).
- Before pushing a new version, remind user to **test on phone** and **export their data** first.

## Android Signing

- Debug and release builds use the same keystore (`android/upload-keystore.jks`).
- `upload-keystore.jks` and `key.properties` are **gitignored**. Same keystore in `KEYSTORE_BASE64` GitHub Actions secret.
- **On a new machine:** Check if keystore files exist before building for Android. Without them, signature mismatch will prevent install over existing app.

## GitHub

- Repo: sohamM97/task-roulette
- **Releases:** Auto-created via GitHub Actions on tag push. **Never tag or push a release unless the user runs `/release`.** Don't use `gh release create`.
- **Never merge PRs without explicit user approval.** Creating PRs is fine, but always ask before running `gh pr merge`.
