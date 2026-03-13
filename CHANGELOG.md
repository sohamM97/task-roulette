# Changelog

## v1.2.0 — Web platform, scheduled priorities & DAG overhaul (2026-03-12)

### Web Platform
- **Web version** with GitHub Pages deployment — use TaskRoulette from a browser.
- Platform-specific utilities for file operations and platform detection.

### Scheduled Priorities
- **Scheduled priorities** — set a task's priority to change on a schedule (e.g., bump to High every Monday). Supports inheritance and manual override.
- **Scheduled priorities table** (`task_schedules`) with DB migration and full sync support.

### DAG View Overhaul
- **Force-directed layout** — physics-based graph visualization with draggable nodes.
- **Multi-parent positioning** and cluster tuning for better readability.
- **Improved zoom controls** and performance optimizations.

### Staleness & Someday
- **Logarithmic staleness curve** — task selection weight grows with days since last worked on, using a log curve to avoid runaway staleness.
- **Someday flag** — mark tasks you don't want picked right now. They stay in the hierarchy but skip the staleness boost in Today's 5 selection.

### Today's 5 Improvements
- **Sync Today's 5 across devices** via Firestore — selections persist across phone and web.
- **Pin state preserved** on completed tasks and across tab switches.
- **Eager pin transfer** for subtasks — completing a pinned subtask transfers the pin smartly.
- **Brain dump pin transfer** uses ID-based diffing instead of name matching.
- **Midnight refresh** — Today's 5 resets correctly at midnight.
- **Sync-on-open** — pulls remote state immediately on app launch.

### Notifications
- **Daily 8 AM notification** on Android reminding you to check Today's 5. Uses exact alarms.

### UI & Polish
- **URL field on Add Task dialog** — attach a link when creating a task, with shared `UrlTextField` widget.
- **"Also done today" box** fully tappable for expand/collapse.
- **Pick Another** option in the random pick dialog.
- Centralized `launchSafeUrl` helper for consistent URL opening with error handling.

### Data & Sync
- **Pull reconciliation fix** — no longer deletes unpushed local relationships during sync.
- **Silent partial-pull data loss fixed** — paginated pull methods now throw on non-200 responses.
- **Sync queue consistency** — `onMutation` called after all local mutations, preventing stalls.
- **Repair migration** for `task_schedules` table for v1.1.6 upgraders.

### Quality
- **831 automated tests** — up from 395, covering schedule DB queries, schedule dialog, task card menu, leaf detail, and many more gaps.
- **Code review Rounds 8–9** and **Security review Rounds 4–5** — all actionable findings fixed.
- **Guardrail hooks** for `adb install`, `flutter run` on Android, `git tag`, and `gh pr merge`.
- `mounted` checks added consistently after all async operations.
- All `debugPrint` calls gated behind `kDebugMode`.

---

## v1.1.0 — Cloud sync, pinned tasks & polish (2026-02-26)

### Cloud Sync
- **Google Sign-In + Firestore sync** — optionally sign in to sync tasks across devices via REST APIs (no Firebase SDK). Mutations are queued locally and debounced.
- **Encrypted token storage** — auth tokens stored securely rather than in plain text.
- Sync resilience improvements: dropped push fix, undo-delete sync safety, pull-side relationship reconciliation, sync queue data loss prevention.

### Pinned Tasks
- **Pin tasks in Today's 5** — pin important tasks so they always appear in your daily list. Pin state persists in SQLite.
- **"Must do" section** — pinned tasks shown separately at the top of Today's 5.
- **Smart replacement** — unpinning a task shrinks the list back; pinning at max greys out the button.
- Pin/unpin available from both task cards and the bottom sheet.

### Today's 5 Improvements
- **"Also done today" section** — see other tasks you completed today, with collapsible UI, chip tooltips, and header toggle.
- **Today's 5 state moved to SQLite** — more reliable than SharedPreferences.
- **Hierarchy path on cards** — see where each task lives, truncated from the beginning for readability.
- **Dependent task grouping** — dependent tasks shown next to their blockers in the grid.
- **Auto-unblock** — dependent tasks unblocked when their dependency is worked on today.
- **"Go to task" fix** — fixed race condition on first use when navigating from Today's 5.

### UI Polish
- **Parent name tags** on task cards and leaf detail view.
- **Compact AppBar** — single-row layout with action icons in bottom row to prevent title truncation.
- **New app icon** — purple-teal gradient variant.
- **Theme toggle** on Today's 5 screen.
- Fire icon for Today's 5 indicator on task cards.

### Data & Privacy
- **Export fix** — fixed export failing on Android 11+ due to scoped storage restrictions.
- Removed in-progress propagation from parent/ancestor tasks.
- Input validation hardening from security review.

### Quality
- **3 additional rounds of code review** (Rounds 5–7) and **1 additional security review** (Round 3) — all findings fixed.
- **100+ new tests** added, covering auth provider, Firestore edge cases, widgets, and regression cases.
- R8 code shrinking and resource shrinking enabled for release builds.

---

## v1.0.0 — First stable release (2026-02-17)

TaskRoulette is a DAG-based task manager designed for minimal cognitive load. Break big goals into smaller tasks, organize them in a flexible hierarchy (tasks can live under multiple parents), and let the app pick what to work on next.

### Core Features

- **DAG task hierarchy** — tasks can have multiple parents, forming a directed acyclic graph instead of a rigid tree. Cycle prevention built in.
- **Today's 5** — each day, the app picks 5 actionable leaf tasks using weighted random selection. Swap individual tasks, refresh the whole set, or mark them done as you go.
- **Weighted random selection** — task picking factors in priority, difficulty, started state, staleness (days since last worked on), and recency.
- **"Done today" vs "Done for good!"** — partial work counts. "Done today" resets the staleness clock so the task comes back later. "Done for good!" archives it permanently.
- **In-progress tracking** — mark tasks as "in progress" to boost their weight in random selection and see them at a glance.
- **Global search** — find any task from anywhere in the hierarchy and navigate directly to it.

### Task Management

- **Create, rename, delete** — with full undo support on delete.
- **Mid-hierarchy delete** — choose to reparent children or delete the entire subtree.
- **Move tasks** — relocate a task from one parent to another.
- **"Also show under..."** — add a task under multiple parents without duplicating it.
- **Brain dump mode** — long-press the add button to rapidly enter multiple tasks at once.
- **Priority** (Normal / High) and **Difficulty** (Easy / Medium / Hard) fields on leaf tasks.
- **URL field** — attach a link to any task, opens in browser.
- **Task dependencies** — soft "do this first" nudges between tasks.
- **Skip task** — dismiss a task without completing it.

### Views

- **All Tasks tab** — browse the full hierarchy with breadcrumb navigation and colored task cards.
- **Today's 5 tab** — daily focus view with progress bar and completion tracking.
- **Swipe between tabs** for quick switching.
- **DAG graph visualization** — see the full task graph with draggable nodes, zoom controls, and tap-to-navigate.
- **Archive screen** — view completed/skipped tasks, permanently delete, or restore with undo.

### Data & Privacy

- **Fully offline** — all data stored locally in SQLite. No accounts, no cloud, no tracking.
- **Export/import backup** — save your entire database to a file and restore it anytime. Share via Android share sheet or save to Downloads.
- **Input validation and backup file verification** — protects against corrupt or malicious imports.

### Platform Support

- **Android** (APK via GitHub Releases)

### Design

- **Dark and light themes** with persistent preference.
- **Material 3** theming throughout.
- **ADHD-friendly design philosophy** — minimal choices, sensible defaults, reduce friction not add it.
- **Custom app icon** — dark roulette wheel with checkmark.

### Quality

- **295 automated tests** — covering database operations, provider logic, models, widgets, and utilities.
- **2 rounds of code review** + **2 rounds of security review** — with all actionable findings fixed.
- **Performance optimized** — batch DB operations, cached lookups, indexed queries, consolidated state refreshes.
