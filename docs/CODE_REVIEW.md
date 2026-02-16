# TaskRoulette Code Review — Action Plan

This document contains findings from code reviews of the TaskRoulette codebase.
Each item is categorized by severity and includes file paths, line numbers, and suggested fixes.

---

## Round 1 — Initial Review

Items are ordered by priority — work through them top to bottom.

### Round 1 Status

| Item | Status |
|------|--------|
| C1. DB race condition | Fixed |
| C2. Today's 5 bypasses provider | Fixed (but introduced CR-2, see Round 2) |
| C3. `deleteTask` crash | Fixed |
| C4. `_previousLastWorkedAt` | Fixed (but incomplete — see CR-4, Round 2) |
| I1. Foreign keys pragma | Fixed |
| I2. `Task.copyWith()` | Fixed |
| I3. Overlay leak | Fixed |
| I4. Non-random selection | Fixed |
| I5. Shared colors | Fixed |
| M1. `displayUrl` duplicated | Fixed |
| M2. `indicatorStyle` dead code | Fixed (but merge re-introduced — see CR-1, Round 2) |
| M4. `_todayKey()` non-ISO | Fixed |
| M7. `completeRepeatingTask` assert | Fixed |
| I6. Loading indicators | Open |
| M3. TextEditingController leak | Open |
| M5. Hardcoded Android path | Open |
| M6. DAG rotation | Open |
| N1–N4 | Open |

---

## Critical (Round 1 — reference only, all fixed)

### C1. Database singleton race condition
**File:** `lib/data/database_helper.dart:20-24`

The `database` getter is not atomic. If two async callers hit it concurrently before `_database` is assigned, `_initDatabase()` runs twice, opening two DB connections. The second overwrites `_database`, leaving the first dangling.

```dart
// Current (buggy):
Future<Database> get database async {
  if (_database != null) return _database!;
  _database = await _initDatabase();
  return _database!;
}
```

**Fix:** Store the `Future<Database>` itself so concurrent callers share the same initialization:
```dart
Future<Database>? _dbFuture;

Future<Database> get database {
  _dbFuture ??= _initDatabase();
  return _dbFuture!;
}
```
Also update `reset()` and `importDatabase()` to clear `_dbFuture` instead of `_database`.

---

### C2. TodaysFiveScreen bypasses TaskProvider for DB mutations
**File:** `lib/screens/todays_five_screen.dart`
**Lines:** 244, 267, 291-295, 314-317, 357

Methods `_stopWorking`, `_markInProgress`, `_workedOnTask`, `_completeNormalTask`, and `_handleUncomplete` create their own `DatabaseHelper()` and mutate the DB directly, bypassing `TaskProvider`. This means:
- The "All Tasks" tab's in-memory state (`_tasks`, `_startedDescendantIds`, `_blockedByNames`) becomes stale.
- Switching to "All Tasks" after acting in Today's 5 shows outdated data.

**Fix:** Add methods to `TaskProvider` for each action (or reuse existing ones like `startTask`, `unstartTask`, `markWorkedOn`, `completeTask`, `uncompleteTask`) and call those instead of direct DB access. The Today's 5 screen should only read from `DatabaseHelper` for snapshot refreshes, never write.

---

### C3. `deleteTask` crashes on non-child task
**File:** `lib/providers/task_provider.dart:96`

```dart
final task = _tasks.firstWhere((t) => t.id == taskId);
```

`completeTask` (line 173) and `skipTask` (line 184) both check `_currentParent?.id == taskId` before falling through to `_tasks.firstWhere`. `deleteTask` doesn't, so calling it on `_currentParent` throws an unhandled `StateError`.

**Fix:** Add the same guard:
```dart
final task = _currentParent?.id == taskId
    ? _currentParent!
    : _tasks.firstWhere((t) => t.id == taskId);
```

---

### C4. `_previousLastWorkedAt` shared across all tasks — data corruption
**File:** `lib/screens/task_list_screen.dart:35, 211, 234`

A single `_previousLastWorkedAt` field is shared across all tasks. If the user taps "Done today" on task A (storing A's old value), then taps it on task B, then undoes B — B's `lastWorkedAt` gets restored to **A's** previous value.

**Fix:** Capture the previous value in the undo closure instead of storing it as instance state:
```dart
Future<void> _workedOn(Task task) async {
  final previousLastWorkedAt = task.lastWorkedAt; // capture in closure
  // ... rest of method ...
  action: SnackBarAction(
    label: 'Undo',
    onPressed: () => provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt),
  ),
}
```
Then remove the `_previousLastWorkedAt` instance field entirely.

---

## Important

### I1. No `PRAGMA foreign_keys = ON`
**File:** `lib/data/database_helper.dart:47-154`

SQLite has foreign keys OFF by default. The schema declares `ON DELETE CASCADE` but it's never enforced. Orphan rows could accumulate from bugs.

**Fix:** Add `onConfigure` to the `openDatabase` call:
```dart
onConfigure: (db) async {
  await db.execute('PRAGMA foreign_keys = ON');
},
```

---

### I2. Add `Task.copyWith()` to eliminate fragile `_currentParent` reconstruction
**File:** `lib/models/task.dart` (add method)
**File:** `lib/providers/task_provider.dart` (8 call sites to simplify)

Eight methods in TaskProvider manually reconstruct `_currentParent` with all 12 `Task` fields. Some include `skippedAt`, others omit it — a latent bug. Any new field added to `Task` must be added in ~8 places.

**Fix:** Add to `Task`:
```dart
Task copyWith({
  int? id,
  String? name,
  int? createdAt,
  int? Function()? completedAt,
  int? Function()? startedAt,
  String? Function()? url,
  int? Function()? skippedAt,
  int? priority,
  int? difficulty,
  int? Function()? lastWorkedAt,
  String? Function()? repeatInterval,
  int? Function()? nextDueAt,
}) {
  return Task(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    completedAt: completedAt != null ? completedAt() : this.completedAt,
    startedAt: startedAt != null ? startedAt() : this.startedAt,
    url: url != null ? url() : this.url,
    skippedAt: skippedAt != null ? skippedAt() : this.skippedAt,
    priority: priority ?? this.priority,
    difficulty: difficulty ?? this.difficulty,
    lastWorkedAt: lastWorkedAt != null ? lastWorkedAt() : this.lastWorkedAt,
    repeatInterval: repeatInterval != null ? repeatInterval() : this.repeatInterval,
    nextDueAt: nextDueAt != null ? nextDueAt() : this.nextDueAt,
  );
}
```

Then replace all 8 manual reconstructions in `task_provider.dart` (lines ~352, ~373, ~467, ~487, ~507, ~527, ~547, ~568) with e.g.:
```dart
_currentParent = _currentParent!.copyWith(startedAt: () => DateTime.now().millisecondsSinceEpoch);
```

---

### I3. Completion animation overlay can leak/crash
**File:** `lib/widgets/completion_animation.dart:5-17`

If the widget tree is torn down between overlay insertion and the animation's `onDone` callback (e.g., user presses back), `entry.remove()` throws.

**Fix:** Guard the removal:
```dart
entry = OverlayEntry(
  builder: (_) => _CompletionOverlay(
    onDone: () {
      if (entry.mounted) entry.remove();
    },
  ),
);
```

---

### I4. `_showRandomResult` uses non-random selection
**File:** `lib/screens/task_list_screen.dart:526-528`

```dart
final deeper = eligible[
    (eligible.length == 1) ? 0 : DateTime.now().millisecondsSinceEpoch % eligible.length];
```

`millisecondsSinceEpoch % length` is not random — biased and deterministic on rapid calls.

**Fix:** Use the provider's weighted random selection:
```dart
final picked = provider.pickWeightedN(eligible, 1);
if (picked.isNotEmpty) {
  await _showRandomResult(picked.first);
}
```

---

### I5. Extract shared card color constants
**Files:**
- `lib/widgets/task_card.dart:124-143`
- `lib/screens/completed_tasks_screen.dart:20-39`
- `lib/screens/dag_view_screen.dart:62-82`

The exact same `_cardColors`/`_cardColorsDark` arrays are copy-pasted three times.

**Fix:** Create `lib/theme/app_colors.dart`:
```dart
class AppColors {
  static const cardColors = [ /* ... */ ];
  static const cardColorsDark = [ /* ... */ ];

  static Color cardColor(BuildContext context, int taskId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? cardColorsDark : cardColors;
    return colors[taskId % colors.length];
  }
}
```
Then replace all three usages.

---

### I6. No loading indicators for async UI transitions
**File:** `lib/screens/task_list_screen.dart`

`navigateInto`, `_fetchCandidateData`, and picker dialogs all do async work with no loading state. On slow devices, the UI appears frozen.

**Fix:** Show a `CircularProgressIndicator` or similar loading state while awaiting. At minimum, show one while `_fetchCandidateData()` runs before opening picker dialogs.

---

## Minor

### M1. `_displayUrl` logic duplicated
**Files:** `lib/widgets/leaf_task_detail.dart:134-138`, `lib/widgets/task_card.dart:152-156`

Same URL display logic with different truncation lengths (40 vs 30).

**Fix:** Extract to a shared utility, e.g. `String displayUrl(String url, {int maxLength = 40})`.

---

### M2. `indicatorStyle` is dead code
**File:** `lib/widgets/task_card.dart:17, 33, 181, 262, 274`

`indicatorStyle` defaults to `2` and is never overridden. The `== 0` and `== 1` branches are dead code.

**Fix:** Remove the `indicatorStyle` field and the dead branches (styles 0 and 1).

---

### M3. `_renameTask` dialog leaks TextEditingController
**File:** `lib/screens/task_list_screen.dart:169`

The `TextEditingController` created inside the method is never disposed.

**Fix:** Wrap in a `StatefulBuilder` or use a dedicated dialog widget that disposes the controller.

---

### M4. `_todayKey()` produces non-ISO date strings
**File:** `lib/screens/todays_five_screen.dart:27-30`

`'${now.year}-${now.month}-${now.day}'` gives `2026-2-5` instead of `2026-02-05`.

**Fix:** Use `'${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}'` or `DateFormat('yyyy-MM-dd')`.

---

### M5. `BackupService` hardcodes Android download path
**File:** `lib/services/backup_service.dart:27`

`/storage/emulated/0/Download` isn't guaranteed on all Android devices.

**Fix:** Use `getExternalStorageDirectory()` from `path_provider` or `getDownloadsDirectory()` if available.

---

### M6. DAG view doesn't recompute layout on rotation
**File:** `lib/screens/dag_view_screen.dart:182-183`

`_rebuildGraph()` reads `MediaQuery.sizeOf(context)` but is only called from `_loadData` (on init).

**Fix:** Override `didChangeDependencies()` to detect size changes and call `_rebuildGraph()` + `_fitToScreen()`.

---

### M7. `completeRepeatingTask` silently accepts invalid intervals
**File:** `lib/data/database_helper.dart:479-489`

The `default` case falls back to 1-day for unrecognized intervals.

**Fix:** Add an `assert` or log a warning in the default case.

---

## Nit

### N1. Rename `difficulty` field internally
**File:** `lib/models/task.dart:11`

The field semantically means "quick task" but is named `difficulty`. When adding `copyWith()` (I2), rename internally to `isQuickTaskFlag` or similar, keeping the DB column as `difficulty`.

### N2. `TaskPickerDialog` filtering has no debounce
**File:** `lib/widgets/task_picker_dialog.dart:79`

Every keystroke recomputes `_filtered` with `.toLowerCase()` calls. Could jank with hundreds of tasks. Consider a 200ms debounce.

### N3. Missing `const` on widget trees
Multiple `Icon(...)` and `Padding(...)` widgets across `task_card.dart`, `leaf_task_detail.dart`, and `todays_five_screen.dart` could be `const` but aren't.

### N4. `priority` default inconsistency across schema versions
**File:** `lib/data/database_helper.dart:60` vs `105`

`onCreate` uses `DEFAULT 0` but the v6 migration used `DEFAULT 1`. The v8 migration remaps, but edge-case databases may have inconsistent defaults.

---

## Round 1 — Suggested Implementation Order (reference only, all done)

1. **C4** — Fix `_previousLastWorkedAt` (5 min, isolated change)
2. **C3** — Fix `deleteTask` crash (2 min, one-line fix)
3. **I2** — Add `Task.copyWith()` (30 min, touches `task.dart` + `task_provider.dart`)
4. **C1** — Fix DB singleton race (10 min, `database_helper.dart` only)
5. **I1** — Enable foreign keys pragma (2 min, `database_helper.dart` only)
6. **C2** — Route Today's 5 mutations through TaskProvider (1-2 hr, largest refactor)
7. **I3** — Guard overlay removal (5 min)
8. **I4** — Fix random selection (5 min)
9. **I5** — Extract shared colors (20 min)
10. **Minor/Nit items** — as time permits

---
---

## Round 2 — Post-Fix Review + New Code

Review of 3 new commits on main (`80ad48b`, `f10db4a`, `0398cc0`) plus verification
that Round 1 fixes didn't introduce regressions. Conducted after merging main into
the code-review branch.

---

### Critical

#### CR-1. Build broken: merge re-introduced dead `indicatorStyle` references
**File:** `lib/widgets/task_card.dart:225, 237`

The Round 1 fix removed the `indicatorStyle` field entirely. But the merge from main
brought back code that references it — **the app won't compile**.

Lines 225 and 237 reference `indicatorStyle` which no longer exists as a field:
```dart
if (showIndicator && indicatorStyle == 0)  // line 225 — compile error
if (showIndicator && indicatorStyle == 2)  // line 237 — compile error
```

**Fix:** Remove the `indicatorStyle == 0` block entirely (lines 225–236, it was dead
code — never triggered). Change the `indicatorStyle == 2` condition to just
`if (showIndicator)`:
```dart
// Delete lines 225-236 (the indicatorStyle == 0 dot branch)
// Change line 237 from:
if (showIndicator && indicatorStyle == 2)
// To:
if (showIndicator)
```

---

#### CR-2. `_completeNormalTask` in Today's 5 triggers unintended `navigateBack()`
**File:** `lib/screens/todays_five_screen.dart:318`

The C2 fix correctly routes mutations through TaskProvider. But `provider.completeTask()`
(`task_provider.dart:172-181`) calls `navigateBack()`, which pops the **All Tasks**
navigation stack. When the user completes a task from the Today's 5 tab, this silently
changes the All Tasks navigation state — the user might be 3 levels deep, and completing
a task on "Today" pops them up a level.

On undo, `uncompleteTask()` doesn't navigate forward again, so the state is permanently
altered.

**Fix:** Add a provider method that completes without navigating:
```dart
/// Completes a task without navigating back. Used by Today's 5 screen
/// which manages its own UI state separately.
Future<void> completeTaskOnly(int taskId) async {
  await _db.completeTask(taskId);
  await _refreshCurrentList();
}
```
Then call `provider.completeTaskOnly(task.id!)` from `_completeNormalTask` in
`todays_five_screen.dart` instead of `provider.completeTask()`.

Similarly, the undo handler should use `uncompleteTask` (which already doesn't navigate),
so that part is fine.

---

#### CR-3. `_workedOn` undo doesn't restore `isStarted` state
**File:** `lib/screens/task_list_screen.dart:240, 252-254`

`_workedOn` auto-starts the task if not already started (line 240:
`if (!task.isStarted) await provider.startTask(task.id!)`). But the undo handler
(lines 252-254) only calls `unmarkWorkedOn` — it never calls `unstartTask`. So:

1. User has a not-started task
2. Taps "Done today" → task gets marked worked-on AND auto-started
3. Taps "Undo" → worked-on is removed, but task stays started

The user can't recover the original not-started state.

**Fix:** Capture `wasStarted` and restore on undo:
```dart
final wasStarted = task.isStarted;
// ... existing markWorkedOn + startTask logic ...
onPressed: () async {
  await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
  if (!wasStarted) await provider.unstartTask(task.id!);
},
```

---

#### CR-4. `onUndoWorkedOn` in leaf detail view doesn't pass `restoreTo`
**File:** `lib/screens/task_list_screen.dart:478-481`

The leaf detail's "Worked on today" button undo calls `unmarkWorkedOn(task.id!)` with
no `restoreTo` argument, which sets `lastWorkedAt` to `null`. But the snackbar undo
(line 253) correctly passes `previousLastWorkedAt`. So undoing from the button vs the
snackbar produces different results — the button always wipes the previous timestamp.

**Fix:** Capture `task.lastWorkedAt` before it's overwritten and pass it:
```dart
onUndoWorkedOn: () async {
  final provider = context.read<TaskProvider>();
  // task.lastWorkedAt here is already the NEW value (today's timestamp),
  // so we need the ORIGINAL value. Capture it when building the widget
  // or pass it through the callback.
  await provider.unmarkWorkedOn(task.id!, restoreTo: /* original value */);
},
```

The cleanest approach: store the pre-mutation `lastWorkedAt` when `_workedOn` is
called (it's already captured as `previousLastWorkedAt` there), and make it available
to the leaf detail rebuild. One way: add a `Map<int, int?> _preWorkedOnTimestamps`
that the leaf detail view can read from.

---

### Important

#### I-7. `getAncestorPath` picks MIN(parent_id) — may not match user expectation
**File:** `lib/data/database_helper.dart:284-304`

For multi-parent (DAG) tasks, the CTE always picks the parent with the lowest ID.
If a task is under both "Personal" (id=2) and "Work" (id=10), "Go to task" always
navigates through "Personal". The user might have intended the "Work" path.

Not a bug — the behavior is deterministic and well-tested. But worth noting for
future UX improvement (e.g., prefer the path the user last navigated through).

---

#### I-8. `_refreshCurrentList` sort is not guaranteed stable
**File:** `lib/providers/task_provider.dart:636-640`

```dart
_tasks.sort((a, b) {
  final aWorked = a.isWorkedOnToday ? 1 : 0;
  final bWorked = b.isWorkedOnToday ? 1 : 0;
  return aWorked.compareTo(bWorked);
});
```

Dart's `List.sort` is not documented as stable. Tasks with the same `isWorkedOnToday`
status could have their relative order changed between calls. In practice Dart uses
a stable merge sort, but relying on this is technically undefined behavior.

**Fix (optional):** Preserve original index as a tiebreaker, or accept the pragmatic
risk since Dart's sort is stable in all current runtimes.

---

### Minor

#### M8. `getRootTaskIds` fetches full Task objects just to extract IDs
**File:** `lib/providers/task_provider.dart:602-605`

```dart
final tasks = await _db.getRootTasks();
return tasks.map((t) => t.id!).toList();
```

Deserializes all columns for all root tasks, then throws away everything except IDs.

**Fix:** Add a dedicated query: `SELECT id FROM tasks WHERE id NOT IN (SELECT child_id FROM task_relationships) AND completed_at IS NULL AND skipped_at IS NULL`.

---

#### M9. N+1 queries in `_addParent` for parent siblings
**File:** `lib/screens/task_list_screen.dart:154-157`

```dart
for (final gpId in grandparentIds) {
  final gpChildren = await provider.getChildIds(gpId);
  parentSiblingIds.addAll(gpChildren);
}
```

One query per grandparent. Unlikely to matter in practice (most tasks have 1-2 parents).

**Fix (optional):** Batch with `WHERE parent_id IN (...)`.

---

## Round 2 — Suggested Implementation Order

1. **CR-1** — Fix compile errors in `task_card.dart` (must fix, app won't build)
2. **CR-2** — Add `completeTaskOnly` for Today's 5 (10 min)
3. **CR-3** — Fix `_workedOn` undo not restoring `isStarted` (5 min)
4. **CR-4** — Fix `onUndoWorkedOn` missing `restoreTo` (15 min)
5. **Remaining Round 1 open items** (I6, M3, M5, M6, N1–N4) — as time permits
