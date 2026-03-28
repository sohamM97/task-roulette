# Test Coverage Inventory

Last updated: 2026-03-28

## Summary

~1066 tests across 27 test files. Models and data layer are well-covered. Task card at 100%. Screens and services have significant gaps.

## Covered

### Models (complete)
- **test/models/task_test.dart** (~159 tests) — Construction, defaults, all timestamps, state flags, priority, sync fields, someday field (`toMap`/`fromMap`/`copyWith` round-trips, default false, integer serialization), **deadline field** (`toMap`/`fromMap` round-trips, `copyWith` set/clear, `hasDeadline`, `deadlineDate` parsing, `daysUntilDeadline` future/today/overdue), **deadline type** (`deadlineType` default `due_by`, `on` type, `isDeadlineOn`/`isDeadlineDueBy` getters, `toMap`/`fromMap`/`copyWith` round-trips).
- **test/models/task_relationship_test.dart** (4 tests) — Construction, `toMap`, `fromMap`, round-trip.
- **test/models/task_schedule_test.dart** (3 tests) — `isActiveOn` weekly, `toMap`/`fromMap` round-trip, `copyWith`.

### Data Layer (excellent — 94.2%)
- **test/data/database_helper_test.dart** (~366 tests) — Task CRUD, completion, start/unstart, skip/archive, dependencies (add/remove/blocking/paths, **dep removal on complete/skip** with undo restore via `restoredDeps`, `getDependentTaskNames` filtering), cycle detection (`hasPath`, `wouldRelationshipCreateCycle`, `wouldDependencyCreateCycle`), DAG ops (`getAllLeafTasks`, `deleteTaskAndReparentChildren`, `deleteTaskSubtree`), ancestry paths, repeating tasks, worked-on tracking, field updates (including `updateTaskSomeday` set/clear/sync-dirty), sync fields/dirty tracking/sync queue, `getPendingAdds` (relationship/dependency), pull reconciliation (pending-preserved, synced-removed), import/export validation, Today's 5 state (save/load/pin/sync merge via `upsertTodaysFiveFromRemote` with OR-merge, cap-at-5, skip-unresolvable, empty-no-op, remote-replaces-local, keeps-local-pinned), leaf descendants, started descendants, pin business rules, `deleteAllLocalData`, **schedule inheritance** (`getScheduleSources`, `getInheritedScheduleDays`, barrier logic, multi-parent union), **schedule sync helpers** (`getScheduleBySyncId`, `upsertScheduleFromRemote` insert/update/skip-missing, `deleteScheduleBySyncId`, `getAllScheduleSyncIds`, `getAllSchedulesWithTaskSyncIds`), **deadline** (`updateTaskDeadline` set/clear, `getDeadlinePinLeafIds` with ancestor propagation + `on` deadline type, `getInheritedDeadline` nearest ancestor, `getEffectiveDeadlines` batch own+inherited, `getDeadlineBoostedLeafData` with overdue/window + `on` type boost/no-boost/inherited/coexistence), **scheduled source map** (`getScheduledSourceToLeafMap`: direct leaf source, parent→leaf propagation, distinct sources, completed/skipped exclusion, schedule barrier respect, empty when not scheduled today), **effective scheduled today** (`getEffectiveScheduledTodayIds` with inheritance and barriers).
- **test/data/todays_five_pin_helper_test.dart** (~80 tests) — `togglePin`, `pinNewTask`, `togglePinInPlace`, `trimExcess`, bottom sheet and add dialog gates, max constraints.

Note: `database_helper_test.dart` also covers **deadline auto-pin suppression** (`suppressDeadlineAutoPin`/`unsuppressDeadlineAutoPin`/`getDeadlineSuppressedIds`: suppress+retrieve, idempotent insert, unsuppress per date, cross-date isolation, empty for unknown date, cleared by `deleteAllLocalData`).

### Providers (good — 87.3%)
- **test/providers/task_provider_test.dart** (~195 tests) — Navigation (load/into/back/toTask), completion (with nav, without nav, leaf handling), start/unstart with `_currentParent` freshness, dependencies (add/remove/cycle prevention, **dep removal on complete/skip** returning `removedDeps`, undo via `restoredDeps`, `getDependentTaskNames`, `reSkipTask`/`reCompleteTask` discarding deps, `blockedTaskIds` includes `currentParent`), random pick, deletion (single/with-relationships/subtree/restore), rename, field updates (URL/priority/someday) all with `_currentParent` freshness, someday↔priority mutual exclusion, someday weight exclusions (staleness/started/novelty skip, all-boosts-stacked still base weight, someday↔priority mutual exclusion at weight level), worked-on, multi-parent DAG (link/unlink), Today's 5 leaf filtering (`getAllLeafTasks`, `pickWeightedN`), undo/restore, `refreshCurrentView` (root refresh, non-root preserves position, stack depth preserved, no mutation trigger), **deadline** (sort tier ≤3 days at tier 1, overdue tier 1, >3 days normal, `updateTaskDeadline` with `_currentParent` freshness, weight multiplier statistical tests).
- **test/providers/theme_provider_test.dart** (8 tests) — Toggle, persistence, icons, listener notifications.
- **test/providers/auth_provider_test.dart** (6 tests) — `setSyncStatus` updates/notifications, `isConfigured`, initial state.

### Screens (partial)
- **test/screens/todays_five_screen_test.dart** (~54 tests) — Empty state, task rendering (max 5, leaf-only, blocked excluded), bottom sheet options, swap/navigate buttons, progress bar, priority icon, refresh dialog, DB state restore, SharedPrefs→DB migration, sync reload (task list replacement, completed status from remote), **deadline auto-pin override** (unpinned deadline stays unpinned on reload, generate doesn't re-pin suppressed tasks, suppression cleared on re-pin, re-pin persists across reload), **first generation auto-pin** (deadline task auto-pinned, `on` deadline auto-pinned on day, suppressed not pinned, max 5 respected, midnight rollover triggers auto-pin, reroll/New set does NOT auto-pin), **scheduled-today icon** (shown/hidden based on schedule, combined with deadline icon), **backfill params** (restore/refreshSnapshots/pinned-descendant backfill passes schedule+deadline+norm to `pickWeightedN`, lazy `_fetchSelectionContext` in `refreshSnapshots`, `_replaceIfNoLongerLeaf` on uncomplete), **reserved slots** (single scheduled source guaranteed slot, two sources each get a slot, ≥1 general-pool slot always preserved, cap at 4 reserved when 5+ sources).
- **test/screens/completed_tasks_screen_test.dart** (~15 tests) — Empty state, completed/skipped display, today/older labels, restore/delete buttons, parent context, AppBar title.
- **test/screens/starred_screen_test.dart** (27 tests) — Empty state, card display (single/multiple/subtitle/in-progress/tree preview/badge count), long-press navigation, drag handle, **tap expanded view** (dialog open, lazy-expand direct children on tap, collapse hides grandchildren, "No sub-tasks" leaf, star icon confirmation dialog, cancel keeps starred, confirm unstar + undo snackbar, undo re-stars, long-press tree node navigates, tap leaf navigates directly, dismiss by tapping outside, **child count badge**, **no chevron on leaves**, **header navigate icon**, **leaf navigate icon**). **starOrder preservation** (explicit starOrder on re-star, appends to end without).
- **test/screens/task_list_screen_overflow_menu_test.dart** (7 tests) — Overflow menu: root shows export/import only (no task items), non-root with children shows Rename/Do after/Schedule/Delete/export/import, leaf shows "Also show under..." instead of Rename/Do after, "Add link" vs "Edit link" based on URL presence, divider count (2 for non-root, 1 for root on non-web).

### Services (minimal)
- **test/services/notification_service_test.dart** (13 tests) — `nextEightAM` (before/after/at 8 AM, midnight, month/year rollover, DST spring-forward, timezone preservation), `onNotificationTap` callback (null default, set and invoke, pendingTap drain on register, no spurious invoke without pending).
- **test/services/firestore_service_test.dart** (~34 tests) — `taskToFirestoreFields` (all fields), `taskFromFirestoreDoc` (parsing, sync_id extraction), relationship doc parsing, **deadline** (include/omit in Firestore fields, parse from doc, reject >10 chars, round-trip), **deadline type** (`deadline_type` include/omit, parse, default, round-trip), **starred fields** (is_starred/star_order serialization, omission when false/null, parsing, defaults).

### Widgets (good)
- **test/widgets/task_picker_dialog_test.dart** (~19 tests) — Priority sorting (tiers), preserved relative order, search filtering, parent context, search ranking (name matches before context-only matches, stable order within tiers, interaction with priority tiers), **headerAction** (shown when provided, hidden during search, absent when not provided, **remove dependency long-name overflow fix** — Expanded wraps Text in Row, ellipsis+maxLines).
- **test/widgets/leaf_task_detail_test.dart** (~52 tests) — Name display, rename, URL icon states, Done/Skip buttons, Start/Stop buttons, priority/someday toggle icons and callbacks, "Done today"/"Worked on today" toggle, **dependency icon** (add_task vs hourglass, tap navigates to dependency, long-press opens edit picker, **isBlocked color**: primary when blocked, greyed out when resolved), **pin button** (pinned/unpinned/hidden), **"Done today" fallback** to onDone when onWorkedOn null, **formatTimeAgo** (days/minutes).
- **test/widgets/pin_button_test.dart** (~15 tests) — Pin/unpin icons, tooltips, max-pins disabled, muted alpha, callbacks.
- **test/widgets/small_widgets_test.dart** (~27 tests) — `EmptyState` (root/non-root), `DeleteTaskDialog` (cancel/keep-subtrees/delete-everything), `AddTaskDialog` (submit, empty/whitespace rejection, "Add multiple" with text preservation and trimming, pin toggle), `BrainDumpDialog` (line counting, whitespace trimming, submit, disabled state, initialText pre-fill).
- **test/widgets/task_card_icons_test.dart** (~12 tests) — Pin vs fire icon, color/size.
- **test/widgets/task_card_test.dart** (~46 tests, **100% coverage**) — In-progress icon, long-press menu (all 7 options: Rename, Also show under, Do after, Schedule, Move to, Remove from here, Stop working, Delete), parent tags, pin+priority coexistence, someday bedtime badge, **URL display** (link icon + text), **blocked state** ("After:" text + hourglass), **worked-on-today** (check_circle icon), hidden menu items when callbacks null, **deadline icon** (own deadline, inherited via `effectiveDeadline`, no icon when absent, own takes priority for color).
- **test/widgets/schedule_dialog_test.dart** (~25 tests, **87.4% coverage**) — Day chip rendering, Schedule header, Save button enable/disable, pre-selected days, toggle on/off, source labels ("Repeat weekly"/"Inherited from:"/"Custom schedule"), inherited mode (chip selection, tap-to-override, Clear all), override mode (Clear override restores inheritance), ScheduleDialogResult constructor (with deadline field), **deadline section** ("Set deadline" text, formatted date display, inherited deadline read-only with source name, own deadline overrides inherited, Save enabled on deadline-only change).
- **test/widgets/completion_animation_test.dart** (3 tests) — Overlay render, checkmark, IgnorePointer.
- **test/widgets/profile_icon_test.dart** (2 tests) — Hidden when unconfigured, sync badge.
- **test/widgets/random_result_dialog_test.dart** (~15 tests) — Layout, Go Deeper button, result enum.

### Other
- **test/utils/display_utils_test.dart** (~93 tests) — `normalizeUrl`, `isAllowedUrl`, `displayUrl`, `shortenAncestorPath` (single/multi-segment, left-truncation of long ancestors, 4+ segment collapse, immediate parent always preserved, boundary at 12 chars), **`confirmDependentUnblock`** (empty list returns true immediately, dialog content with dependent names, Complete confirms, Cancel returns false, dismiss-by-tap-outside returns false).
- **test/utils/force_directed_layout_test.dart** (~8 tests) — `LayoutNode` serialization round-trip, `ForceDirectedLayout.run` (single node, empty graph, early convergence, adaptive iterations), `runAsync` produces valid result.
- **test/platform/platform_utils_native_test.dart** (7 tests) — Platform detection, home dir, file ops.
- **test/app/app_test.dart** (1 test) — App renders with tabs.

## NOT Covered

### Screens (high priority)
- **task_list_screen.dart** (1122 lines) — PARTIAL (overflow menu only, 7 tests). Main nav screen: task hierarchy, search, filtering, add/rename/delete, link/unlink, context menu. Still untested: search, task card interactions, add/delete dialogs, leaf detail view, navigation, drag reorder.
- **dag_view_screen.dart** (797 lines) — NO TESTS. Force-directed graph, node selection, pinch-to-zoom/pan.

### Services (high priority)
- **sync_service.dart** (496 lines) — NO TESTS. Push/pull orchestration, debouncing, conflict resolution, queue processing. Hard to unit test (creates own `_db` and `_firestore` internally — no DI). Would need refactoring or integration-style tests.
- **auth_service.dart** (356 lines) — NO TESTS. Google Sign-In, OAuth redirect, credential management. Requires HTTP mocking.
- **backup_service.dart** (130 lines) — NO TESTS. File I/O for import/export. Logic partially covered indirectly via `database_helper_test.dart` import/export tests.

### Services (partial)
- **firestore_service.dart** (512 lines) — Only serialization helpers tested. REST API calls (create/update/delete docs, batch ops, error handling) NOT tested. Requires HTTP mocking.

### Widgets (incomplete)
- **leaf_task_detail.dart** — 52 tests but ~77% coverage. NOT tested: URL opening (requires url_launcher mock), editUrlDialog submit/remove flows.
- **schedule_dialog.dart** — 87.4% coverage. NOT tested: Save navigation result (requires bottom sheet host), `show` static method.
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
