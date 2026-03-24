# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**Test output:** Run `flutter test` directly — do NOT redirect output to files (triggers unresolvable permission prompts in Claude Code). For targeted runs: `flutter test --plain-name 'test name'` or `flutter test path/to/test.dart`.

## Architecture

- **App shell:** `AppShell` in `main.dart` hosts a 3-tab `PageView` (Today, Starred, All Tasks) with `NavigationBar`. Completed tasks are accessed via archive icon in each tab's AppBar. Tabs use `AutomaticKeepAliveClientMixin` to preserve state across switches. `TaskProvider` manages a navigation stack (`_parentStack`) for drill-down within All Tasks.
- **DB schema:** Core tables: `tasks`, `task_relationships` (parent_id, child_id), `task_dependencies` (blocker relationships), `todays_five_state` (daily pin state), `task_schedules` (recurring), `sync_queue` (pending mutations). Multi-parent DAG with cycle prevention via recursive CTE (`DatabaseHelper.hasPath()`).
- **DB migrations:** Sequential `onUpgrade` in `DatabaseHelper` (currently at v22, constant `_dbVersion`). Foreign keys via `PRAGMA foreign_keys = ON`. **NEVER modify a released migration** — if a previous version shipped with migration N, new DDL must go in migration N+1 or later. Retroactive changes to released migrations are silently skipped on devices already past that version. Also update `_validateBackup` version check (uses `_dbVersion` automatically) and the backup version test.
- **Cloud sync:** Optional Google Sign-In + Firestore via REST APIs (no Firebase SDK). `SyncService` orchestrates push/pull; mutations queued in `sync_queue` table and debounced. **Mutation flow:** `TaskProvider.onMutation` callback → `SyncService.schedulePush()` (5s debounce) → batch REST calls to Firestore. Pull runs on startup + every 5 min.
- **When adding a column to `tasks`:** Also add to `Task` model (`toMap`/`fromMap`/`copyWith`), `taskToFirestoreFields`, and `taskFromFirestoreDoc` in `firestore_service.dart`.
- **Provider pattern:** 3 providers (`TaskProvider`, `AuthProvider`, `ThemeProvider`) + `SyncService` via `ProxyProvider<AuthProvider, SyncService>`. `TaskProvider._refreshCurrentList()` reloads children only, NOT `_currentParent` — see gotcha below.
- **Shared utilities:** `display_utils.dart` has `showInfoSnackBar(context, message, {onUndo})` — use this for all snackbars (includes close icon, undo support, proper duration). Don't create raw `SnackBar` objects.
- Tests use `sqflite_common_ffi` with `inMemoryDatabasePath` and reset DB in `setUp()`. No mocking — real SQL against in-memory SQLite.

### Known Gotcha: Stale `_currentParent`

When mutating a task that is `_currentParent` (e.g. rename, start, unstart), the provider must rebuild `_currentParent` as a new `Task` object. `_refreshCurrentList()` only refreshes `_tasks` (children). Without this, leaf detail view shows stale data.

## Design Philosophy

**Minimal cognitive load.** Every feature should reduce friction. Prefer sensible defaults over configuration. Avoid jargon like "DAG", "node", "parent" in UI — use natural alternatives like "listed under", "show under". Material 3 theming throughout.

## Skills & Hooks

- Skills in `.claude/skills/` are auto-invokable — **always use the relevant skill** instead of doing things manually (e.g. `/commit` instead of raw git commands, `/feature` instead of manual branch creation).
- `/code-review` and `/sec-review` have `disable-model-invocation: true` — **always run in a fresh session**.
- `/code-review-fix` and `/sec-review-fix` — can run in any session **except** the one where the corresponding review was run.
- Hooks in `.claude/hooks/` enforce guardrails automatically (analyze before commit, confirm before tag/merge/install, block `flutter run` without `-d linux`, auto-inject `--dart-define` for APK builds).

## Development Preferences

- **Verify before documenting.** Before writing any factual claim in a doc (docs/, CHANGELOG, comments), verify it exists in the codebase first — grep for the feature, check the model, read the code. Do not rely on memory, TODO lists, or stale branch knowledge. If it's not in the code on the current branch, don't claim it exists.
- **When asked what's pending in a branch**, always check memory (TODO.md and other memory files) for previously discussed next steps — not just the git diff.
- **Before exiting plan mode**, ask the user if they want to create a feature branch first (via `/feature`).
- **Always ask for confirmation before committing.** Never run `/commit` or `git commit` without explicit user approval first.
- Remind user about committing occasionally — don't wait until asked. Remind them to run `/test-suite` first, then review changes before committing.
- When a bug is found and confirmed reproducible, always add a test case for it.
- **Bug fix code comments**: When adding code changes for bug fixes, include a comment documenting the exact bug — behaviour before the fix vs after the fix.
- **Confirm flow/functionality changes**: If a bug fix involves changing the flow or functionality itself (not just fixing broken code), always ask the user before implementing. Don't unilaterally make radical design decisions like removing auto-pin or changing weighting strategies.
- When writing tests in bulk, use `flutter test --coverage` to find gaps. Parse `coverage/lcov.info` directly (`genhtml` may not be installed).
- Capture any user-mentioned future work items as todo tasks immediately.
- **When changing weighting logic**, update `docs/TODAYS_FIVE_ALGORITHM.md` to keep the algorithm doc in sync.
- When setup instructions change (new deps, build steps), ask user if they want to update README.
- **Widget tests with sqflite_ffi**: `testWidgets` runs in `FakeAsync` — use `databaseFactoryFfiNoIsolate` in `setUpAll`. Use shared helpers from `test/helpers/async_pump.dart` (`pumpAndLoad`, `pumpAsync`) for async loading. Provide `AuthProvider` and `SyncService` in MultiProvider for screens that need them.

## Mobile Debugging & Testing

- **Don't jump to fixes** when something fails on phone — ask user if they want to troubleshoot with ADB/logcat first.
- Before pushing a new version, remind user to **test on phone** and **export their data** first.

## Android Signing

- Debug and release builds use the same keystore (`android/upload-keystore.jks`).
- `upload-keystore.jks` and `key.properties` are **gitignored**. Same keystore in `KEYSTORE_BASE64` GitHub Actions secret.
- **On a new machine:** Check if keystore files exist before building for Android. Without them, signature mismatch will prevent install over existing app.

## GitHub

- Repo: sohamM97/task-roulette
- **Releases:** Auto-created via GitHub Actions on tag push. Use `/release` to tag. Don't use `gh release create`.
- Hooks enforce confirmation prompts for `git tag` and `gh pr merge`.
