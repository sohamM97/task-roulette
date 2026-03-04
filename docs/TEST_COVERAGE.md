# Test Coverage Inventory

Last updated: 2026-03-04

## Summary

~300+ tests across 22 test files. Models and data layer are well-covered. Screens and services have significant gaps.

## Covered

### Models (complete)
- **test/models/task_test.dart** (~120 tests) — Construction, defaults, all timestamps, state flags, priority/difficulty, sync fields, `toMap`/`fromMap`/`copyWith` round-trips.
- **test/models/task_relationship_test.dart** (4 tests) — Construction, `toMap`, `fromMap`, round-trip.

### Data Layer (excellent)
- **test/data/database_helper_test.dart** (~200+ tests) — Task CRUD, completion, start/unstart, skip/archive, dependencies (add/remove/blocking/paths), cycle detection (`hasPath`, `wouldRelationshipCreateCycle`, `wouldDependencyCreateCycle`), DAG ops (`getAllLeafTasks`, `deleteTaskAndReparentChildren`, `deleteTaskSubtree`), ancestry paths, repeating tasks, worked-on tracking, field updates, sync fields/dirty tracking/sync queue, import/export validation, Today's 5 state (save/load/pin/sync merge via `upsertTodaysFiveFromRemote` with OR-merge, cap-at-5, skip-unresolvable, empty-no-op, remote-replaces-local, keeps-local-pinned), leaf descendants, started descendants, pin business rules, `deleteAllLocalData`.
- **test/data/todays_five_pin_helper_test.dart** (~80 tests) — `togglePin`, `pinNewTask`, `togglePinInPlace`, `trimExcess`, bottom sheet and add dialog gates, max constraints.

### Providers (good)
- **test/providers/task_provider_test.dart** (~100+ tests) — Navigation (load/into/back/toTask), completion (with nav, without nav, leaf handling), start/unstart with `_currentParent` freshness, dependencies (add/remove/cycle prevention), random pick, deletion (single/with-relationships/subtree/restore), rename, field updates (URL/priority/quickTask) all with `_currentParent` freshness, worked-on, multi-parent DAG (link/unlink), Today's 5 leaf filtering (`getAllLeafTasks`, `pickWeightedN`), undo/restore.
- **test/providers/theme_provider_test.dart** (8 tests) — Toggle, persistence, icons, listener notifications.
- **test/providers/auth_provider_test.dart** (6 tests) — `setSyncStatus` updates/notifications, `isConfigured`, initial state.

### Screens (partial)
- **test/screens/todays_five_screen_test.dart** (~20 tests) — Empty state, task rendering (max 5, leaf-only, blocked excluded), bottom sheet options, swap/navigate buttons, progress bar, priority icon, refresh dialog, DB state restore, SharedPrefs→DB migration, sync reload (task list replacement, completed status from remote).
- **test/screens/completed_tasks_screen_test.dart** (~15 tests) — Empty state, completed/skipped display, today/older labels, restore/delete buttons, parent context, AppBar title.

### Services (minimal)
- **test/services/notification_service_test.dart** (13 tests) — `nextEightAM` (before/after/at 8 AM, midnight, month/year rollover, DST spring-forward, timezone preservation), `onNotificationTap` callback (null default, set and invoke, pendingTap drain on register, no spurious invoke without pending).
- **test/services/firestore_service_test.dart** (~20 tests) — `taskToFirestoreFields` (all fields), `taskFromFirestoreDoc` (parsing, sync_id extraction), relationship doc parsing.

### Widgets (good)
- **test/widgets/task_picker_dialog_test.dart** (~30 tests) — Priority sorting (tiers), preserved relative order, search filtering, parent context.
- **test/widgets/leaf_task_detail_test.dart** (~30 tests) — Name display, rename, URL icon states, Done/Skip buttons, Start/Stop buttons, priority/quick indicators.
- **test/widgets/pin_button_test.dart** (~15 tests) — Pin/unpin icons, tooltips, max-pins disabled, muted alpha, callbacks.
- **test/widgets/small_widgets_test.dart** (~30 tests) — `EmptyState` (root/non-root), `DeleteTaskDialog` (cancel/keep-subtrees/delete-everything), `AddTaskDialog` (partial), `BrainDumpDialog` (partial).
- **test/widgets/task_card_icons_test.dart** (~12 tests) — Pin vs fire icon, color/size.
- **test/widgets/task_card_test.dart** (~20 tests) — In-progress icon, long-press menu, parent tags, pin+priority coexistence.
- **test/widgets/completion_animation_test.dart** (3 tests) — Overlay render, checkmark, IgnorePointer.
- **test/widgets/profile_icon_test.dart** (2 tests) — Hidden when unconfigured, sync badge.
- **test/widgets/random_result_dialog_test.dart** (~15 tests) — Layout, Go Deeper button, result enum.

### Other
- **test/utils/display_utils_test.dart** (~50 tests) — `normalizeUrl`, `isAllowedUrl`, `displayUrl`.
- **test/platform/platform_utils_native_test.dart** (7 tests) — Platform detection, home dir, file ops.
- **test/app/app_test.dart** (1 test) — App renders with tabs.

## NOT Covered

### Screens (high priority)
- **task_list_screen.dart** (1122 lines) — NO TESTS. Main nav screen: task hierarchy, search, filtering, add/rename/delete, link/unlink, context menu.
- **dag_view_screen.dart** (797 lines) — NO TESTS. Force-directed graph, node selection, pinch-to-zoom/pan.

### Services (high priority)
- **sync_service.dart** (496 lines) — NO TESTS. Push/pull orchestration, debouncing, conflict resolution, queue processing. Hard to unit test (creates own `_db` and `_firestore` internally — no DI). Would need refactoring or integration-style tests.
- **auth_service.dart** (356 lines) — NO TESTS. Google Sign-In, OAuth redirect, credential management. Requires HTTP mocking.
- **backup_service.dart** (130 lines) — NO TESTS. File I/O for import/export. Logic partially covered indirectly via `database_helper_test.dart` import/export tests.

### Services (partial)
- **firestore_service.dart** (512 lines) — Only serialization helpers tested. REST API calls (create/update/delete docs, batch ops, error handling) NOT tested. Requires HTTP mocking.

### Utils
- **force_directed_layout.dart** (369 lines) — NO TESTS. Graph layout algorithm. Could unit test node positioning/convergence.

### Widgets (incomplete)
- **leaf_task_detail.dart** — ~30 tests but file is 451 lines. NOT tested: worked-on badge, repeat task UI, dependency markers, URL opening, priority/difficulty pickers.
- **add_task_dialog.dart** — Only partial coverage in `small_widgets_test.dart`.
- **brain_dump_dialog.dart** — Only partial coverage in `small_widgets_test.dart`.

### Low priority (not worth testing)
- **theme/app_colors.dart** — Just constants.
- **platform/platform_utils.dart** — Conditional import wrapper, tested via `platform_utils_native_test.dart`.
- **main.dart** — 1 basic test exists. Deep testing (dark mode toggle, tab switching, app lifecycle) would be complex widget tests with minimal ROI.

## Testing Caveats

- **Async screens with loading spinners**: `pumpAndSettle` hangs on `CircularProgressIndicator`. Use the `pumpAndLoad` pattern: `runAsync(Future.delayed(10ms)) + pump()` in a loop (20 rounds).
- **sqflite in widget tests**: Must use `databaseFactoryFfiNoIsolate` (not `databaseFactoryFfi`) because `testWidgets` runs in `FakeAsync` where isolate-port I/O stalls.
- **DB inserts in widget tests**: Wrap in `tester.runAsync(() async { ... })`.
- **MultiProvider for screens**: Screens with `ProfileIcon` need `AuthProvider` and `SyncService` in the provider tree.
- **SyncService is not injectable**: Creates its own `DatabaseHelper` and `FirestoreService` internally. Testing push/pull logic directly requires refactoring or testing at integration level (e.g., test the DB merge logic separately in `database_helper_test.dart`).
