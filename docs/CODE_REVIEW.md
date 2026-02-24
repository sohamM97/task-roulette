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

---
---

## Round 3 (2026-02-16)

Full codebase review after Round 2 fixes were merged. Verified all Round 2
critical items, identified new state-synchronization bugs in the "Done today"
undo flow and Today's 5 task snapshot management.

---

### Previous Round Verification

- [x] CR-1: Build broken — merge re-introduced dead `indicatorStyle` — verified fixed, all references removed from `task_card.dart`
- [x] CR-2: `_completeNormalTask` triggers `navigateBack()` — verified fixed, `completeTaskOnly()` added at `task_provider.dart:208` and used at `todays_five_screen.dart:337`
- [x] CR-3: `_workedOn` undo doesn't restore `isStarted` — verified fixed, `wasStarted` captured at `task_list_screen.dart:246` and restored at line 265
- [x] CR-4: `onUndoWorkedOn` missing `restoreTo` — verified fixed, `_preWorkedOnTimestamps` map added at line 38, populated at line 247, consumed at line 492
- [x] M-8: `getRootTaskIds` fetched full Task objects — verified fixed, `database_helper.dart:301-312` now has a dedicated ID-only query

### Round 1 Items Still Open

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- N1–N4: All still open

---

### Important

#### I-9. `unmarkWorkedOn` doesn't refresh `_tasks` — stale grid after undo on already-started tasks
**File:** `lib/providers/task_provider.dart:483-498`

Both `markWorkedOn` and `unmarkWorkedOn` call only `notifyListeners()`, not
`_refreshCurrentList()`. The `_tasks` list retains stale `Task` objects with
outdated `lastWorkedAt` values.

In the normal "Done today" flow, `navigateBack()` or `startTask()` eventually
calls `_refreshCurrentList()`, masking the issue. But the undo path is
different:

1. User views a leaf task that is **already started**
2. Taps "Done today" → `markWorkedOn` + `navigateBack` (refresh happens)
3. Grid shows task as "worked on today" (correct — fresh data)
4. User taps "Undo" → `unmarkWorkedOn` is called
5. Because `wasStarted == true`, `unstartTask` is **not** called
6. **Only `notifyListeners()` fires — `_tasks` is NOT refreshed from DB**
7. Grid still shows the task as "worked on today" and sorted to the bottom

The task stays visually "done" until the user navigates away and back.

**Fix:** Change `markWorkedOn` and `unmarkWorkedOn` to call
`_refreshCurrentList()` instead of `notifyListeners()`:
```dart
Future<void> markWorkedOn(int taskId) async {
  await _db.markWorkedOn(taskId);
  if (_currentParent?.id == taskId) {
    _currentParent = _currentParent!.copyWith(
      lastWorkedAt: () => DateTime.now().millisecondsSinceEpoch,
    );
  }
  await _refreshCurrentList(); // was: notifyListeners()
}
```
Same for `unmarkWorkedOn`.

---

#### I-10. Today's 5 `_workedOnTask` doesn't refresh task snapshot after mutation
**File:** `lib/screens/todays_five_screen.dart:311-331`

After `markWorkedOn` and `startTask`, the task object in `_todaysTasks` is not
re-fetched from the DB. Compare with `_stopWorking` (line 267) and
`_markInProgress` (line 291), which both re-fetch the fresh task via
`DatabaseHelper().getTaskById()` and update `_todaysTasks[idx]`.

The stale task object has outdated `startedAt` and `lastWorkedAt` fields. This
means:
- The play icon may not appear immediately
- `isWorkedOnToday` on the stale object returns false (it reflects the old
  `lastWorkedAt`), which could cause inconsistent UI behavior if the
  `_completedIds` set and the task object disagree

**Fix:** Re-fetch the task after mutation, consistent with the other methods:
```dart
await provider.markWorkedOn(task.id!);
if (!task.isStarted) await provider.startTask(task.id!);
final fresh = await DatabaseHelper().getTaskById(task.id!);
if (fresh != null && mounted) {
  final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
  if (idx >= 0) _todaysTasks[idx] = fresh;
}
setState(() { _completedIds.add(task.id!); });
```

---

#### I-11. Today's 5 `_completeNormalTask` undo leaves stale task — navigate button hidden
**File:** `lib/screens/todays_five_screen.dart:349-356`

The undo handler calls `provider.uncompleteTask(task.id!)` and removes the ID
from `_completedIds`, but does **not** refresh the `Task` object in
`_todaysTasks`. The stale object still has `completedAt` set.

In `_buildTaskCard` (line 665):
```dart
if (widget.onNavigateToTask != null && !task.isCompleted)
```
After undo, `task.isCompleted` still returns `true` on the stale object, so the
"Go to task" navigate button stays hidden even though the task was uncompleted
in the DB.

**Fix:** Re-fetch the task in the undo handler:
```dart
onPressed: () async {
  await provider.uncompleteTask(task.id!);
  final fresh = await DatabaseHelper().getTaskById(task.id!);
  if (!mounted) return;
  setState(() {
    _completedIds.remove(task.id!);
    if (fresh != null) {
      final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
      if (idx >= 0) _todaysTasks[idx] = fresh;
    }
  });
  await _persist();
},
```

---

#### I-12. Today's 5 "Done today" has no undo support
**File:** `lib/screens/todays_five_screen.dart:322-330`

The "Done today" action in the All Tasks leaf view provides an undo SnackBar
(`task_list_screen.dart:261-266`). But in Today's 5, the snackbar after "Done
today" (line 323-330) has **no undo action**:

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text('"${task.name}" — nice work! ...'),
    showCloseIcon: true,
    // No action: SnackBarAction(label: 'Undo', ...)
  ),
);
```

If the user accidentally marks the wrong task as "done today" in Today's 5,
they have to switch to All Tasks, find the task, and undo it from there.

**Fix:** Add an undo action that calls `unmarkWorkedOn` and (if auto-started)
`unstartTask`, similar to the All Tasks implementation. Also remove the task
from `_completedIds` and re-fetch the snapshot.

---

### Minor

#### M-10. `showEditUrlDialog` leaks TextEditingController
**File:** `lib/widgets/leaf_task_detail.dart:78`

Same pattern as M3. The static method creates a `TextEditingController` inside
a `showDialog` callback. When the dialog is dismissed, the controller is never
disposed. Flutter's `AlertDialog` does not own or dispose it.

**Fix:** Either use a `StatefulBuilder` that disposes the controller, or
extract into a small `StatefulWidget` dialog.

---

#### M-11. Double `_refreshCurrentList()` call in `_workedOn` flow
**File:** `lib/screens/task_list_screen.dart:250-252`

```dart
await provider.markWorkedOn(task.id!);     // notifyListeners()
if (!task.isStarted) await provider.startTask(task.id!);  // _refreshCurrentList()
await provider.navigateBack();              // _refreshCurrentList()
```

When `startTask` is called, it triggers `_refreshCurrentList()`. Then
`navigateBack()` immediately triggers it again. Two consecutive DB round-trips
and widget rebuilds for no benefit.

**Fix:** If I-9 is fixed (markWorkedOn calls `_refreshCurrentList`), then this
becomes three consecutive refreshes. Consider a batch method:
```dart
Future<void> markWorkedOnAndNavigateBack(int taskId) async {
  await _db.markWorkedOn(taskId);
  if (_currentParent?.id == taskId) {
    final wasStarted = _currentParent!.isStarted;
    if (!wasStarted) await _db.startTask(taskId);
  }
  await navigateBack(); // single _refreshCurrentList()
}
```

---

#### M-12. Repeating task code is dead code
**Files:**
- `lib/data/database_helper.dart:538-577` (`updateRepeatInterval`, `completeRepeatingTask`)
- `lib/models/task.dart:41-42` (`isRepeating`, `isDue` getters)

The DB schema has `repeat_interval` and `next_due_at` columns (added in v11
migration), and the model has fields and getters. But no code in the provider
or UI layer references these methods or getters. This is scaffolding for an
unimplemented feature.

Not harmful (the columns are populated as NULL for all tasks), but worth
noting to avoid confusion. Either implement the feature or remove the dead
code to keep the codebase clean.

---

## Round 3 — Suggested Implementation Order

1. **I-9** — Fix `markWorkedOn`/`unmarkWorkedOn` to call `_refreshCurrentList()` (5 min, `task_provider.dart` only)
2. **I-10** — Re-fetch task snapshot in Today's 5 `_workedOnTask` (5 min, consistency fix)
3. **I-11** — Re-fetch task in `_completeNormalTask` undo handler (5 min, fixes hidden navigate button)
4. **I-12** — Add undo support to Today's 5 "Done today" (15 min, matches All Tasks behavior)
5. **M-11** — Consolidate triple refresh into single batch (10 min, depends on I-9)
6. **Remaining open items** from Round 1/2 (I6, M3, M5, M6, M9, M10, N1–N4) — as time permits

---
---

## Round 4 (2026-02-17)

Full codebase review after Round 3 fixes and new feature commits (release version
check, archive button for completed tasks in Today's 5, move task fix) were merged.
Verified all Round 3 items. Found stale-snapshot bugs in Today's 5 completion
flows and a data-loss issue in the archive permanent-delete undo.

---

### Previous Round Verification

- [x] I-9: `markWorkedOn`/`unmarkWorkedOn` now call `_refreshCurrentList()` — verified fixed at `task_provider.dart:489-513`
- [x] I-10: Today's 5 `_workedOnTask` re-fetches task snapshot — verified fixed at `todays_five_screen.dart:322-327`
- [x] I-11: `_completeNormalTask` undo re-fetches task — verified fixed at `todays_five_screen.dart:375-378`
- [x] I-12: Today's 5 "Done today" undo action added — verified fixed at `todays_five_screen.dart:338-351`
- [x] M-11: Triple refresh consolidated into `markWorkedOnAndNavigateBack` — verified fixed at `task_provider.dart:499-505`, called at `task_list_screen.dart:250-253`

### Round 1/2 Items Still Open

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- M-10: `showEditUrlDialog` leaks TextEditingController — still open
- M-12: Repeating task code is dead code — still open
- N1–N4: All still open

---

### Important

#### I-13. `_completeNormalTask` doesn't update task snapshot — wrong buttons shown after "Done for good!"
**File:** `lib/screens/todays_five_screen.dart:357-365`

After "Done for good!" in Today's 5, the task object in `_todaysTasks` is NOT
re-fetched from the DB. The `_completedIds` set correctly tracks the visual
"done" state, but the task object is stale — its `completedAt` field is still
`null` (never updated from the pre-completion snapshot).

The trailing button logic at lines 692–708 uses `task.isCompleted` from the
stale object:
```dart
if (widget.onNavigateToTask != null && !task.isCompleted)
    IconButton(... icon: Icons.open_in_new ...),  // "Go to task"
if (task.isCompleted)
    IconButton(... icon: archiveIcon ...),  // "View in archive"
```

Since `task.isCompleted` is `false` on the stale object:
- **"Go to task" button SHOWS** — tapping it navigates to a completed task,
  which shows the leaf detail view with action buttons (Done today, Skip, etc.)
  for an already-completed task. Confusing and can lead to double-mutations.
- **"View in archive" button HIDDEN** — the new archive button (from commit
  `327f165`) is never visible after completing via "Done for good!".

**Fix:** Re-fetch the task snapshot after completion, same as `_workedOnTask`:
```dart
await provider.completeTaskOnly(task.id!);
final fresh = await DatabaseHelper().getTaskById(task.id!);
if (!mounted) return;
final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
setState(() {
  _completedIds.add(task.id!);
  if (fresh != null && idx >= 0) _todaysTasks[idx] = fresh;
});
```

---

#### I-14. `_handleUncomplete` doesn't revert "Done today" state — task bounces back to "done" on tab switch
**File:** `lib/screens/todays_five_screen.dart:400-443`

When a user taps a "done" task to uncomplete it, `_handleUncomplete` always
calls `provider.uncompleteTask(task.id!)` — which clears `completedAt`. This
works for "Done for good!" tasks, but for "Done today" tasks, `completedAt`
was never set (it's already null). The real state that needs reverting is
`lastWorkedAt` and (potentially) `startedAt`.

**Reproduction:**
1. In Today's 5, tap a task → choose "Done today"
2. Let the undo snackbar auto-dismiss
3. Tap the now-done task to uncomplete it → visual checkmark removed
4. Switch to All Tasks tab and back → task reappears as "done"

**Root cause:** After step 3, the task still has `lastWorkedAt = today` and
`startedAt` set in the DB. On `refreshSnapshots()`, the external detection
at line 128 re-adds it to `_completedIds`:
```dart
if (fresh.isWorkedOnToday && !_completedIds.contains(fresh.id)) {
  _completedIds.add(fresh.id!);
}
```

**Fix:** Track the completion type so `_handleUncomplete` can revert correctly.
One approach: add a `Set<int> _workedOnIds` that tracks which tasks were marked
"Done today" vs "Done for good!":
```dart
final Set<int> _workedOnIds = {};

// In _workedOnTask: _workedOnIds.add(task.id!);
// In _completeNormalTask: ensure task.id NOT in _workedOnIds

Future<void> _handleUncomplete(Task task) async {
  final provider = context.read<TaskProvider>();
  if (_workedOnIds.contains(task.id)) {
    // "Done today" — revert worked-on + auto-start
    await provider.unmarkWorkedOn(task.id!);
    // Note: original lastWorkedAt value is lost if snackbar was dismissed.
    // This is an acceptable trade-off.
    _workedOnIds.remove(task.id);
  } else {
    await provider.uncompleteTask(task.id!);
  }
  // ... rest of existing logic (remove from _completedIds, leaf check, etc.)
```

---

#### I-15. `_permanentlyDeleteTask` undo overwrites original completion timestamp
**File:** `lib/screens/completed_tasks_screen.dart:92-104`

When undoing a permanent delete from the archive, the undo handler:
1. Calls `restoreTask(deleted.task, ...)` — inserts the task with its original
   `completedAt`/`skippedAt` timestamp via `task.toMap()`
2. Then calls `reCompleteTask(task.id!)` or `reSkipTask(task.id!)` — which
   overwrites the timestamp with `DateTime.now()`

This means the original completion date (e.g., "Completed Jan 15") is replaced
with "Completed today". The information is permanently lost.

**Fix:** Remove the redundant `reCompleteTask`/`reSkipTask` calls. The task
is already restored with the correct `completedAt`/`skippedAt` from step 1:
```dart
onPressed: () async {
  await provider.restoreTask(
    deleted.task,
    deleted.parentIds,
    deleted.childIds,
    dependsOnIds: deleted.dependsOnIds,
    dependedByIds: deleted.dependedByIds,
  );
  // task.toMap() already includes the original completedAt/skippedAt.
  // No need to re-complete or re-skip.
  await _loadData();
},
```

---

### Minor

#### M-13. `_navigateToTask` in DAG view doesn't await async `navigateToTask`
**File:** `lib/screens/dag_view_screen.dart:281-283`

```dart
void _navigateToTask(Task task) {
  context.read<TaskProvider>().navigateToTask(task);
  Navigator.pop(context);
}
```

`navigateToTask` is async (returns `Future<void>`), but it's called without
`await`, and `Navigator.pop` fires immediately. If `navigateToTask` throws
(e.g., DB error), the error is silently swallowed. In practice this works
because the Consumer on the All Tasks tab rebuilds when `notifyListeners()`
fires, but it's fragile — an error during navigation would leave the provider
in a partially-modified state (stack changed, children not loaded).

**Fix:**
```dart
Future<void> _navigateToTask(Task task) async {
  await context.read<TaskProvider>().navigateToTask(task);
  if (mounted) Navigator.pop(context);
}
```

---

## Round 4 — Suggested Implementation Order

1. **I-13** — Re-fetch task snapshot in `_completeNormalTask` (5 min, `todays_five_screen.dart`)
2. **I-15** — Remove redundant `reCompleteTask`/`reSkipTask` in archive undo (2 min, `completed_tasks_screen.dart`)
3. **I-14** — Track completion type in Today's 5 for correct undo (20 min, `todays_five_screen.dart`)
4. **M-13** — Await async `navigateToTask` in DAG view (2 min, `dag_view_screen.dart`)
5. **Remaining open items** from Round 1/2/3 (I6, M3, M5, M6, M9, M-10, M-12, N1–N4) — as time permits

---
---

## Round 5 (2026-02-24)

Full codebase review after Pinned Tasks Phase 2 merge, cloud sync/auth feature
addition, and version bump to 1.0.10. Verified all Round 4 items. Major focus
on the new sync/auth layer and interactions with existing state management.

---

### Round 5 Status

| Item | Status |
|------|--------|
| CR-5. Sort tier bug | Invalid — by design (worked-on-today tasks should sink regardless of pin) |
| CR-6. Sync queue data loss | Fixed |
| CR-7. Token expiry | Fixed |
| I-16. Missing HTTP status checks | Fixed |
| I-17. Sync concurrency guard | Fixed |
| I-18. Missing `mounted` checks | Fixed |
| I-19. Pin state cleanup | Fixed |
| I-20. Unsafe JSON cast | Fixed |
| I-21. Transactional sync queue ops | Fixed |
| I-22. Silent catch blocks | Fixed |
| M-14. Firestore integerValue | Open |
| M-15. Refresh token plaintext | Open (future) |
| M-16. No error handling in load | Open |
| M-17. `navigateToLevel` bounds check | Fixed |

### Previous Round Verification

- [x] I-13: `_completeNormalTask` re-fetches task snapshot — verified fixed, `_markDone` calls `_refreshTaskSnapshot` at `todays_five_screen.dart:559`
- [x] I-14: Track completion type for correct undo — verified fixed, `_workedOnIds` and `_autoStartedIds` sets at `todays_five_screen.dart:27-31`, used in `_handleUncomplete` at line 618
- [x] I-15: Archive undo no longer calls `reCompleteTask`/`reSkipTask` — verified fixed at `completed_tasks_screen.dart:101-111`
- [x] M-13: `_navigateToTask` awaits async call — verified fixed at `dag_view_screen.dart:281-284`

### Round 1/2/3 Items Still Open

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- M-10: `showEditUrlDialog` leaks TextEditingController — still open
- M-12: Repeating task code is dead code — still open
- N1–N4: All still open

---

### Critical

#### CR-5. Sort tier bug — pinned tasks pushed to end when worked on today
**File:** `lib/providers/task_provider.dart:651-657`

The `sortTier()` function checks `isWorkedOnToday` BEFORE `pinnedIds.contains()`.
Any pinned task that the user marks as "Done today" gets demoted to tier 4
(bottom of list), defeating the purpose of pinning:

```dart
int sortTier(Task t) {
  if (t.isWorkedOnToday) return 4;          // ← checked FIRST
  if (pinnedIds.contains(t.id)) return 0;   // ← never reached if worked on
  if (t.isHighPriority) return 1;
  if (todaysFiveIds.contains(t.id)) return 2;
  return 3;
}
```

**Reproduction:**
1. Pin a task in Today's 5
2. Mark it "Done today"
3. Navigate to All Tasks → pinned task is at the bottom instead of the top

**Fix:** Check pinned status first:
```dart
int sortTier(Task t) {
  if (pinnedIds.contains(t.id)) return 0;  // Pinned always on top
  if (t.isWorkedOnToday) return 4;
  if (t.isHighPriority) return 1;
  if (todaysFiveIds.contains(t.id)) return 2;
  return 3;
}
```

---

#### CR-6. Sync queue drained before processing — data loss on partial push failure
**File:** `lib/services/sync_service.dart:251-284`

`push()` calls `drainSyncQueue()` (line 251), which atomically deletes ALL queue
entries and returns them. Then it processes them one-by-one (lines 252-284).
If processing fails midway (network error, expired token on the 5th of 10
entries), the remaining entries are permanently lost — they were already deleted
from the queue.

```dart
// Line 251: ALL entries deleted from DB here
final queue = await _db.drainSyncQueue();
for (final entry in queue) {
  // Lines 258-283: process one at a time — if this throws,
  // remaining entries are gone forever
  switch (entityType) {
    case 'relationship':
      await _firestore.pushRelationships(...);  // network call — can fail
    // ...
  }
}
```

**Impact:** Relationship additions/removals, dependency changes, and task
deletions can be silently lost during sync failures. The local DB is correct,
but the cloud never receives the changes, causing permanent divergence.

**Fix:** Process queue entries individually, deleting each only after
successful push:
```dart
final queue = await _db.peekSyncQueue(); // read without deleting
for (final entry in queue) {
  // ... process entry ...
  await _db.deleteSyncQueueEntry(entry['id'] as int); // delete after success
}
```

---

#### CR-7. `_getValidToken()` doesn't check token expiry — sync silently fails after 1 hour
**File:** `lib/services/sync_service.dart:354-361`

Firebase ID tokens expire after 1 hour. `_getValidToken()` only checks if the
token is non-null — it doesn't check whether it's expired:

```dart
Future<String?> _getValidToken() async {
  if (_authProvider.firebaseIdToken != null) {
    return _authProvider.firebaseIdToken;  // returns expired token
  }
  final success = await _authProvider.refreshToken();
  return success ? _authProvider.firebaseIdToken : null;
}
```

After 1 hour, the token remains in memory (non-null) but is expired. All sync
API calls receive 401 errors. Combined with CR-6, this means the sync queue
gets drained and lost on the first push attempt after token expiry.

**Fix:** Track token expiry time in `AuthService` and proactively refresh:
```dart
DateTime? _tokenExpiresAt;

Future<String?> _getValidToken() async {
  final token = _authProvider.firebaseIdToken;
  if (token != null && _authProvider.tokenExpiresAt.isAfter(DateTime.now())) {
    return token;
  }
  final success = await _authProvider.refreshToken();
  return success ? _authProvider.firebaseIdToken : null;
}
```

Firebase's token response includes `expires_in` (seconds). Parse it at sign-in
and store `DateTime.now().add(Duration(seconds: expiresIn - 60))` (with 60s
buffer).

---

### Important

#### I-16. `pushRelationships` and `pushDependencies` don't check HTTP response status
**File:** `lib/services/firestore_service.dart:82-86, 115-119`

Both methods fire Firestore `:commit` requests but never check the response
status code. Compare with `pushTasks()` (line 51) which correctly throws on
non-200:

```dart
// pushTasks (correct):
if (response.statusCode != 200) {
  throw FirestoreException('Push tasks failed: ${response.statusCode}');
}

// pushRelationships (line 82-86 — no check):
await http.post(commitUrl, headers: _headers(idToken), body: ...);
// Silent — could be 401, 403, 500, etc.
```

**Impact:** Sync reports "synced" status even when relationships/dependencies
failed to push. Cloud data silently diverges from local.

**Fix:** Add the same status code check as `pushTasks()`:
```dart
final response = await http.post(commitUrl, ...);
if (response.statusCode != 200) {
  throw FirestoreException('Push relationships failed: ${response.statusCode}');
}
```

---

#### I-17. No concurrency guard on sync operations
**File:** `lib/services/sync_service.dart`

`push()`, `pull()`, `initialMigration()`, `replaceLocalWithCloud()`, and
`mergeBoth()` have no mutual exclusion. They can run concurrently via:
- Debounce timer fires `push()` while periodic timer fires `pull()`
- User taps "Sync now" (`syncNow()` = `push()` + `pull()`) while a debounced
  push is in-flight
- `initialMigration()` runs while periodic pull starts

Concurrent sync can cause: duplicate Firestore documents (push race), sync
queue drained twice (data loss), and inconsistent `lastSyncAt` timestamps.

**Fix:** Add a simple lock:
```dart
bool _syncing = false;

Future<void> push() async {
  if (_syncing || !_canSync) return;
  _syncing = true;
  try {
    // ... existing logic
  } finally {
    _syncing = false;
  }
}
```

---

#### I-18. Missing `mounted` checks in Today's 5 undo SnackBar handlers
**File:** `lib/screens/todays_five_screen.dart:544-547, 567-569`

The SnackBar undo callbacks perform multiple async operations followed by
`_unmarkDone()` (which calls `setState()`) without any `mounted` check:

```dart
// Line 544-547
onPressed: () async {
  await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
  if (!wasStarted) await provider.unstartTask(task.id!);
  await _unmarkDone(task.id!, workedOn: true, autoStarted: !wasStarted);
  // ↑ calls setState() — crashes if widget disposed between awaits
},
```

Same pattern at line 567-569 for the "Done for good!" undo.

**Fix:** Add `if (!mounted) return;` after each `await`:
```dart
onPressed: () async {
  await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
  if (!mounted) return;
  if (!wasStarted) await provider.unstartTask(task.id!);
  if (!mounted) return;
  await _unmarkDone(task.id!, workedOn: true, autoStarted: !wasStarted);
},
```

---

#### I-19. Pin state not cleaned in `_swapTask` — stale pins and inflated pin count
**File:** `lib/screens/todays_five_screen.dart:862-873`

`_swapTask` replaces a task at an index with a random pick, but doesn't
remove the old task's pin status. Compare with `_pickSpecificTask` (line 817)
which correctly calls `_pinnedIds.remove(oldTask.id)`:

```dart
// _swapTask (line 862-863 — pin NOT removed):
final picked = provider.pickWeightedN(eligible, 1);
if (picked.isNotEmpty) {
  _todaysTasks[index] = picked.first;  // old task's pin orphaned in _pinnedIds
  // ...
}

// _pickSpecificTask (line 817 — pin correctly removed):
final wasPinned = _pinnedIds.remove(oldTask.id);
```

**Impact:** `_pinnedIds` retains the old task's ID (no longer in `_todaysTasks`).
`TodaysFivePinHelper` counts this as a valid pin, potentially blocking the user
from pinning another task ("Max 5 pinned tasks" error when only 4 are visible).

Same issue in `_replaceIfNoLongerLeaf` (line 605-611): replacement doesn't
clean the old task's pin.

**Fix:** Remove old pin before replacing in both methods:
```dart
// _swapTask:
_pinnedIds.remove(_todaysTasks[index].id);
_todaysTasks[index] = picked.first;

// _replaceIfNoLongerLeaf:
_pinnedIds.remove(_todaysTasks[idx].id);
if (replacements.isNotEmpty) {
  _todaysTasks[idx] = replacements.first;
} else {
  _todaysTasks.removeAt(idx);
}
```

---

#### I-20. Unsafe JSON cast in `pullTasksSince` — crashes on non-array response
**File:** `lib/services/firestore_service.dart:290`

The Firestore `:runQuery` response is cast to `List<dynamic>` without a
type check. If Firestore returns an error object or unexpected format, this
throws `TypeError` instead of a catchable `FirestoreException`:

```dart
final results = json.decode(response.body) as List<dynamic>;
```

**Scenario:** Firestore returns `{"error": {"code": 400, ...}}` (JSON object,
not array) → `as List<dynamic>` throws `_CastError`.

**Fix:** Add a type check:
```dart
final decoded = json.decode(response.body);
if (decoded is! List) {
  throw FirestoreException('Unexpected query response format');
}
final results = decoded;
```

---

#### I-21. Sync-queue DB operations not transactional — data can diverge from sync state
**File:** `lib/data/database_helper.dart:403-426, 721-745, 925-948, 950-974`

Four methods perform relationship/dependency mutations followed by sync queue
inserts as separate operations (not in a transaction):

```dart
// addRelationship (line 403-426):
await db.insert('task_relationships', {...});  // step 1: mutate
final rows = await db.rawQuery(...);           // step 2: fetch sync IDs
await db.insert('sync_queue', {...});          // step 3: queue sync
```

If the app crashes between step 1 and step 3, the local DB has the change
but the sync queue doesn't — the change never propagates to cloud.

Same pattern in `removeRelationship`, `addDependency`, `removeDependency`.

**Fix:** Wrap each method body in `db.transaction()`:
```dart
Future<void> addRelationship(int parentId, int childId) async {
  final db = await database;
  await db.transaction((txn) async {
    await txn.insert('task_relationships', {...});
    final rows = await txn.rawQuery(...);
    if (syncIds.containsKey(parentId) && syncIds.containsKey(childId)) {
      await txn.insert('sync_queue', {...});
    }
  });
}
```

---

#### I-22. Silent catch blocks in `AuthService` lose all error context
**File:** `lib/services/auth_service.dart:83-85, 236-238`

`silentSignIn()` and `_signInDesktop()` catch all exceptions with `catch (_)`
and discard the error. This makes debugging auth failures impossible — the
user just sees "sign in failed" with no indication of why:

```dart
// Line 83-85:
} catch (_) {
  // Token expired or revoked — user must sign in again
}
```

In reality, the exception could be: network timeout, malformed JSON response,
TLS error, SharedPreferences read failure, etc. All are indistinguishable.

**Fix:** Log the actual exception (at minimum use `debugPrint`):
```dart
} catch (e) {
  debugPrint('AuthService: silentSignIn failed: $e');
}
```

---

### Minor

#### M-14. Firestore `integerValue` uses `.toString()` — incorrect type for structured query
**File:** `lib/services/firestore_service.dart:281`

The `updated_at` filter value is converted to string:
```dart
'value': {'integerValue': lastSyncAt.toString()},
```

Firestore REST API documents `integerValue` as a string-encoded 64-bit
integer, so this technically works — but only because Firestore accepts the
string representation. For consistency with how Firestore encodes other integer
fields, this is correct as-is. However, `lastSyncAt` is `int?`, and calling
`.toString()` on `null` produces `"null"` (the string), which would cause a
silent query failure.

**Fix:** Guard against null (the `lastSyncAt` parameter is nullable):
```dart
if (lastSyncAt != null) {
  // add the 'where' clause to the query
}
```

---

#### M-15. Refresh token stored in plaintext `SharedPreferences`
**File:** `lib/services/auth_service.dart:280-282`

The Firebase refresh token is stored in `SharedPreferences`, which is plaintext
on both platforms (XML on Android, plist on Linux). On a rooted device or if
the filesystem is accessed, the token can be extracted and used to generate
new ID tokens.

**Fix (future):** Use `flutter_secure_storage` (Android Keystore / Linux
Secret Service) for the refresh token. Not critical for a personal app, but
worth noting for general security posture.

---

#### M-16. No error handling in `_loadTodaysTasks()` initial load
**File:** `lib/screens/todays_five_screen.dart:69-169`

The initial load performs many DB queries with no try-catch. If any query
fails (e.g., corrupted DB, migration issue), the exception propagates
unhandled and the screen stays in `_loading = true` state forever (spinner
shown indefinitely).

**Fix:** Wrap in try-catch and show an error message or fallback UI:
```dart
try {
  // ... existing load logic
} catch (e) {
  debugPrint('TodaysFive: load failed: $e');
  if (mounted) setState(() => _loading = false);
}
```

---

#### M-17. `navigateToLevel` missing bounds check
**File:** `lib/providers/task_provider.dart:67-73`

```dart
Future<void> navigateToLevel(int level) async {
  final target = breadcrumb[level];  // can throw RangeError
```

No validation that `level` is within bounds of the `breadcrumb` list.

**Fix:** Add a guard:
```dart
if (level < 0 || level >= breadcrumb.length) return;
```

---

## Round 5 — Suggested Implementation Order

1. **CR-5** — Fix sort tier priority order (2 min, `task_provider.dart` line 652 — swap two lines)
2. **CR-7** — Track token expiry in `AuthService` (20 min, `auth_service.dart` + `sync_service.dart`)
3. **CR-6** — Process sync queue entries individually instead of drain-then-process (15 min, `sync_service.dart` + `database_helper.dart`)
4. **I-16** — Add status code checks to `pushRelationships`/`pushDependencies` (2 min, `firestore_service.dart`)
5. **I-17** — Add sync lock to prevent concurrent operations (5 min, `sync_service.dart`)
6. **I-18** — Add mounted checks in Today's 5 undo handlers (5 min, `todays_five_screen.dart`)
7. **I-19** — Clean pin state in `_swapTask` and `_replaceIfNoLongerLeaf` (5 min, `todays_five_screen.dart`)
8. **I-20** — Add type check for Firestore query response (2 min, `firestore_service.dart`)
9. **I-21** — Wrap sync-queue DB operations in transactions (15 min, `database_helper.dart`)
10. **I-22** — Replace silent catches with `debugPrint` (5 min, `auth_service.dart`)
11. **Remaining open items** from previous rounds (I6, M3, M5, M6, M9, M-10, M-12, N1–N4) — as time permits
