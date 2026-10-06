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

---
---

## Round 6 (2026-02-25)

Full codebase review after "Also done today" UI rework, sync concurrency fix, and
version 1.0.11. Verified Round 5 items. Major focus: sync layer completeness gaps —
multiple core operations never trigger cloud sync.

---

### Previous Round Verification

- [x] CR-5: Sort tier bug — confirmed intentional (by-design, not a bug) per Round 5 status
- [x] CR-6: Sync queue data loss — verified fixed, `peekSyncQueue()` at `sync_service.dart:259` + `deleteSyncQueueEntry()` at line 293
- [x] CR-7: Token expiry — verified fixed, `isTokenExpired` getter at `auth_service.dart:57-59`, checked in `_getValidToken()` at `sync_service.dart:375`
- [x] I-16: Missing HTTP status checks — verified fixed, status checks at `firestore_service.dart:87-88` and `123-124`
- [x] I-17: Sync concurrency guard — verified fixed, `_syncing` flag with `_pushPending` at `sync_service.dart:236-304`
- [x] I-18: Missing `mounted` checks — verified fixed, extensive `mounted` checks throughout `todays_five_screen.dart`
- [x] I-19: Pin state cleanup — verified fixed, `_pinnedIds.remove()` in `_swapTask` (line 866) and `_replaceIfNoLongerLeaf` (line 607)
- [x] I-20: Unsafe JSON cast — verified fixed, `decoded is! List` check at `firestore_service.dart:297`
- [x] I-21: Transactional sync queue ops — verified fixed, `addRelationship` (line 405), `addDependency` (line 929), `removeRelationship` (line 724), `removeDependency` (line 955) all wrapped in `db.transaction()`
- [x] I-22: Silent catch blocks — **partially fixed**: `silentSignIn()` now logs with `debugPrint` at `auth_service.dart:87`, but `_signInDesktop()` at line 255 still has a bare `catch (e) { return null; }` with no logging
- [x] M-17: `navigateToLevel` bounds check — verified fixed at `task_provider.dart:68`

### Round 1/2/3/5 Items Still Open

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- M-10: `showEditUrlDialog` leaks TextEditingController — still open
- M-12: Repeating task code is dead code — still open
- M-14: Firestore `integerValue` null guard on `lastSyncAt` — still open
- M-15: Refresh token stored in plaintext SharedPreferences — still open (future)
- M-16: No error handling in `_loadTodaysTasks()` initial load — still open
- N1–N4: All still open

---

### Critical

#### CR-8. Sync gap: `completeTask`, `skipTask`, and `markWorkedOnAndNavigateBack` never trigger sync push
**Files:**
- `lib/providers/task_provider.dart:183-205, 514-518`
- `lib/providers/task_provider.dart:50-54, 633, 669`

The three most common user mutations — completing a task, skipping a task, and
marking "Done today" — all route through `navigateBack()` (line 50-54), which
calls `_refreshCurrentList(isMutation: false)`. Because `isMutation` is false,
`onMutation?.call()` at line 669 is **never invoked**, so `syncService.schedulePush()`
is never called.

```dart
// task_provider.dart
Future<Task> completeTask(int taskId) async {
  await _db.completeTask(taskId);    // marks sync_status='pending' in DB
  await navigateBack();              // isMutation: false → onMutation NOT called
  return task;
}

Future<void> navigateBack() async {
  _currentParent = _parentStack.removeLast();
  await _refreshCurrentList(isMutation: false);  // ← push never scheduled
}
```

The DB correctly marks the task as `sync_status: 'pending'`, but no push is
ever scheduled. The data stays pending until:
- Another mutation that **does** trigger `onMutation` (e.g., rename, add task)
- User manually taps "Sync now"

The periodic timer only calls `pull()`, not `push()`.

**Impact:** The core workflow of completing/skipping tasks silently fails to
sync to cloud. The user can complete 100 tasks, close the app, and none of
them are pushed to Firestore.

**Fix:** Either:
(a) Change `navigateBack()` to accept an `isMutation` parameter:
```dart
Future<bool> navigateBack({bool isMutation = false}) async {
  if (_parentStack.isEmpty) return false;
  _currentParent = _parentStack.removeLast();
  await _refreshCurrentList(isMutation: isMutation);
  return true;
}
```
Then pass `isMutation: true` from `completeTask`, `skipTask`, and `markWorkedOnAndNavigateBack`.

(b) Or call `onMutation?.call()` directly in those methods before `navigateBack()`.

---

#### CR-9. Sync gap: `deleteTaskSubtree` doesn't enqueue any sync events
**File:** `lib/data/database_helper.dart:1162-1216`

`deleteTaskSubtree` deletes multiple tasks, all their relationships, and all
their dependencies inside a transaction — but inserts **zero** entries into
`sync_queue`. Compare with `deleteTaskWithRelationships` (line 836-844)
which correctly enqueues a task deletion.

```dart
// deleteTaskSubtree (line 1201-1209):
await txn.rawDelete('DELETE FROM task_relationships WHERE ...');
await txn.rawDelete('DELETE FROM task_dependencies WHERE ...');
await txn.rawDelete('DELETE FROM tasks WHERE ...');
// ← no sync_queue inserts anywhere
```

**Impact:** Deleting a task subtree locally leaves all those tasks, relationships,
and dependencies intact in Firestore. On next pull, the deleted data comes back.

**Fix:** Inside the transaction, after collecting subtree data but before deleting,
enqueue sync events for each task with a `sync_id`:
```dart
for (final task in deletedTasks) {
  if (task.syncId != null) {
    await txn.insert('sync_queue', {
      'entity_type': 'task', 'action': 'remove',
      'key1': task.syncId!, 'key2': '',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
// Also enqueue relationship and dependency removals
```

---

#### CR-10. Sync gap: `deleteTaskAndReparentChildren` doesn't enqueue sync events
**File:** `lib/data/database_helper.dart:1099-1154`

Same issue as CR-9. This method deletes a task, its relationships, and its
dependencies, then reparents children — all without any `sync_queue` entries.
The deleted task stays in Firestore, and the new reparent relationships are
never pushed.

**Fix:** Enqueue task deletion and new reparent relationship additions inside
the transaction. The reparented links (`addedLinks`) need 'relationship/add'
entries, and the deleted task needs a 'task/remove' entry.

---

#### CR-11. Firestore delete methods silently ignore HTTP errors — failed deletes lost forever
**File:** `lib/services/firestore_service.dart:130-157`

All three delete methods (`deleteTask`, `deleteRelationship`, `deleteDependency`)
fire HTTP DELETE requests without checking the response status:

```dart
Future<void> deleteTask(String uid, String idToken, String syncId) async {
  final url = Uri.parse('${_tasksPath(uid)}/$syncId');
  await http.delete(url, headers: _headers(idToken));  // response IGNORED
}
```

In `sync_service.dart:push()`, each sync queue entry is deleted after the
Firestore operation (line 293: `await _db.deleteSyncQueueEntry(entryId)`).
If the HTTP DELETE returns 401/403/500, the error is silently swallowed, and
the sync queue entry is still deleted — the deletion is permanently lost.

Compare with `pushTasks`, `pushRelationships`, and `pushDependencies` which
all correctly throw `FirestoreException` on non-200 status.

**Fix:** Check response status in all three delete methods:
```dart
Future<void> deleteTask(String uid, String idToken, String syncId) async {
  final url = Uri.parse('${_tasksPath(uid)}/$syncId');
  final response = await http.delete(url, headers: _headers(idToken));
  if (response.statusCode != 200 && response.statusCode != 404) {
    throw FirestoreException('Delete task failed: ${response.statusCode}');
  }
}
```
(404 is acceptable — the document may already be deleted.)

---

### Important

#### I-23. Sync status stuck at "syncing" when token is null
**File:** `lib/services/sync_service.dart:92-96, 131-135, 242-246, 313-317`

Multiple methods set `_authProvider.setSyncStatus(SyncStatus.syncing)` and then
have an early return if `_getValidToken()` returns null:

```dart
_authProvider.setSyncStatus(SyncStatus.syncing);  // line 92/131/242/313
try {
  final idToken = await _getValidToken();
  if (idToken == null) return;  // ← exits without resetting status
```

When the token is null (e.g., refresh failed, user not signed in), the sync
status is permanently stuck at `SyncStatus.syncing`. The UI shows "Syncing..."
forever until the next successful sync operation.

For `push()` and `pull()`, the `finally` block clears `_syncing` but does not
reset the sync status. For `initialMigration()` and `replaceLocalWithCloud()`,
there is no `finally` block at all.

**Fix:** Reset status to `idle` (or `error`) on early return:
```dart
if (idToken == null) {
  _authProvider.setSyncStatus(SyncStatus.idle);
  return;
}
```

---

#### I-24. `removeAllDependencies` doesn't enqueue sync events
**File:** `lib/data/database_helper.dart:1065-1072`

`removeAllDependencies` deletes all dependencies for a task without inserting
any `sync_queue` entries:

```dart
Future<void> removeAllDependencies(int taskId) async {
  final db = await database;
  await db.delete('task_dependencies', where: 'task_id = ?', whereArgs: [taskId]);
}
```

Compare with `removeDependency` (line 953-974) which correctly enqueues
a 'dependency/remove' entry in `sync_queue`.

**Impact:** When a task's dependency is changed (old dependency removed via
`removeAllDependencies`, new one added via `addDependency`), only the new
dependency is synced. The old dependency remains in Firestore.

**Fix:** Query existing dependencies before deleting, then enqueue removal
entries for each:
```dart
Future<void> removeAllDependencies(int taskId) async {
  final db = await database;
  await db.transaction((txn) async {
    final deps = await txn.query('task_dependencies',
      where: 'task_id = ?', whereArgs: [taskId]);
    for (final dep in deps) {
      // Enqueue sync removal (look up sync_ids first)
      // ...
    }
    await txn.delete('task_dependencies', where: 'task_id = ?', whereArgs: [taskId]);
  });
}
```

---

#### I-25. `pull()` blocked by `_syncing` is permanently dropped — no retry mechanism
**File:** `lib/services/sync_service.dart:310`

```dart
Future<void> pull() async {
  if (!_canSync || _syncing) return;  // ← silently dropped
```

Unlike `push()` which sets `_pushPending = true` when blocked (line 237),
`pull()` has no equivalent "pull pending" flag. If a pull is blocked because
a push is in progress, the pull is silently discarded.

The periodic pull timer fires every N minutes, so the next periodic pull
will eventually succeed. But if a pull was triggered by the user tapping
"Sync now" (`syncNow()` calls `push()` then `pull()`), the push succeeds
and the pull is immediately blocked by the `_syncing` flag still being true
inside `push()`'s `finally` block.

Wait — actually, `push()` sets `_syncing = false` in its `finally` block
(line 300) before `syncNow()` calls `pull()`. So the sequential call is fine.
The real risk is when a periodic pull timer fires while a push is in progress.

**Fix (optional):** Add `_pullPending` flag mirroring `_pushPending`, or
document that this is an acceptable trade-off since periodic pulls will
catch up.

---

#### I-26. `_handleUncomplete` doesn't pass `restoreTo` when reverting "Done today"
**File:** `lib/screens/todays_five_screen.dart:629`

```dart
await provider.unmarkWorkedOn(task.id!);  // no restoreTo parameter
```

Unlike the SnackBar undo in `_workedOnTask` (line 545) which passes
`restoreTo: previousLastWorkedAt`, the check-icon uncomplete path calls
`unmarkWorkedOn` without `restoreTo`. This sets `lastWorkedAt` to `null`
in the DB, permanently erasing any previous `lastWorkedAt` value (e.g.,
"worked on yesterday").

This was flagged in CR-4 (Round 2) and partially fixed for the SnackBar
undo path, but the check-icon uncomplete path was never addressed.

**Fix:** Track the original `lastWorkedAt` in the `_workedOnTask` flow
and make it available to `_handleUncomplete`. One approach: add a
`Map<int, int?> _preWorkedOnLastWorkedAt` that stores the pre-mutation
value when "Done today" is tapped, and read from it in `_handleUncomplete`.

---

#### I-27. `AuthProvider.refreshToken()` signs out on transient network errors
**File:** `lib/providers/auth_provider.dart:42-50`

```dart
Future<bool> refreshToken() async {
  final success = await _authService.refreshToken();
  if (!success) {
    await _authService.signOut();  // ← destroys session on ANY failure
    notifyListeners();
  }
  return success;
}
```

If `_authService.refreshToken()` returns false due to a temporary network
error (not a permanent token revocation), the user is signed out and all
credentials are wiped from SharedPreferences. The user must sign in
interactively again.

Additionally, if `_authService.refreshToken()` **throws** (e.g.,
`SocketException` from `http.post`), the exception propagates uncaught —
`signOut()` is never called, but the token state is left inconsistent.

**Fix:** Distinguish permanent failures (HTTP 400 "invalid grant") from
transient ones (network error, timeout):
```dart
Future<bool> refreshToken() async {
  try {
    final success = await _authService.refreshToken();
    if (!success) {
      // Permanent failure (invalid/revoked token) — sign out
      await _authService.signOut();
      notifyListeners();
    }
    return success;
  } catch (e) {
    // Transient failure (network) — don't sign out, just report
    debugPrint('AuthProvider: token refresh failed: $e');
    return false;
  }
}
```

---

#### I-28. `PinButton` is tappable when visually disabled
**File:** `lib/utils/display_utils.dart:67`

```dart
final disabled = atMaxPins && !isPinned;
// ... visual dimming applied ...
onPressed: onToggle,  // ← always active, never null
```

When `disabled` is true (max pins reached, task not pinned), the button's icon
is dimmed and tooltip says "Max pins reached", but `onPressed` is never set to
null. The button remains tappable. Callers handle this gracefully (show a
snackbar), but the button should be actually disabled per Material guidelines.

**Fix:**
```dart
onPressed: disabled ? null : onToggle,
```

---

#### I-29. `_pickAndPinTask` doesn't update `_taskPaths` — new task shows without breadcrumb
**File:** `lib/screens/todays_five_screen.dart:836-839`

After picking and pinning a new task, `_pickAndPinTask` calls `setState` and
`_persist()` but does NOT update `_taskPaths` for the new task. Compare with
`_swapTask` (lines 868-873) which correctly loads the ancestor path.

The new task renders without its "Parent > Grandparent" breadcrumb subtitle
until the next `refreshSnapshots()` call.

**Fix:** Load the path after picking, same as `_swapTask`:
```dart
final ancestors = await DatabaseHelper().getAncestorPath(picked.id!);
if (ancestors.isNotEmpty) {
  _taskPaths[picked.id!] = ancestors.map((t) => t.name).join(' › ');
} else {
  _taskPaths.remove(picked.id!);
}
```

---

#### I-30. `_signInDesktop` still swallows exceptions with no logging
**File:** `lib/services/auth_service.dart:255-257`

I-22 was only partially fixed. `silentSignIn()` now has `debugPrint` (line 87),
but `_signInDesktop()` still has a bare catch that discards all error context:

```dart
} catch (e) {
  return null;  // network error? TLS error? JSON parse error? — unknown
}
```

**Fix:**
```dart
} catch (e) {
  debugPrint('AuthService: desktop sign-in failed: $e');
  return null;
}
```

---

### Minor

#### M-18. `_preWorkedOnTimestamps` map grows unboundedly
**File:** `lib/screens/task_list_screen.dart:41, 382`

Entries are added to `_preWorkedOnTimestamps` on every `_workedOn` call but
only removed in the `onUndoWorkedOn` callback (line 634). If the user marks
many tasks as "worked on" without pressing undo, the map grows for the
lifetime of the screen.

**Fix:** Clear entries for tasks that are no longer in `_tasks` during
`_refreshCurrentList`, or simply clear the map on navigation.

---

#### M-19. Double refresh on tab navigation
**File:** `lib/main.dart:137-146, 164-175`

Both the `onPageChanged` callback (PageView) and `onDestinationSelected`
callback (NavigationBar) trigger `refreshSnapshots()` / `loadTodaysFiveIds()`.
When the user taps a navigation bar item, `animateToPage` fires, which
triggers `onPageChanged` — both callbacks fire, causing double refreshes.

**Fix:** Only trigger refresh from one callback. Since `onDestinationSelected`
is the user action, move refresh logic there and remove it from `onPageChanged`.

---

#### M-20. Missing `WidgetsFlutterBinding.ensureInitialized()` in `main()`
**File:** `lib/main.dart:13-18`

```dart
void main() {
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
    sqfliteFfiInit();  // ← runs before binding initialized
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const TaskRouletteApp());
}
```

`sqfliteFfiInit()` runs before `runApp()` which is where
`WidgetsFlutterBinding.ensureInitialized()` is called. If `sqfliteFfiInit()`
uses any Flutter binding internals, this could fail on some platforms.

**Fix:** Add `WidgetsFlutterBinding.ensureInitialized()` as the first line
in `main()`.

---

#### M-21. `_initAuth` in `_HomeScreenState` has no error handling
**File:** `lib/main.dart:95-96`

```dart
void initState() {
  super.initState();
  _initAuth();  // fire-and-forget, no .catchError
}
```

If any awaited call inside `_initAuth` throws, the exception is unhandled.
Sync will never start, with no user feedback.

**Fix:** Wrap `_initAuth` body in try-catch:
```dart
Future<void> _initAuth() async {
  try {
    // ... existing logic ...
  } catch (e) {
    debugPrint('Failed to initialize auth/sync: $e');
  }
}
```

---

#### M-22. Theme data duplicated between light and dark themes
**File:** `lib/main.dart:41-68`

`cardTheme` and `snackBarTheme` are copy-pasted identically in both `theme:`
and `darkTheme:` blocks. If one is updated, the other must be updated manually.

**Fix:** Extract shared theme components:
```dart
const _cardTheme = CardThemeData(
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  clipBehavior: Clip.antiAlias,
);
const _snackBarTheme = SnackBarThemeData(behavior: SnackBarBehavior.floating);
```

---

#### M-23. `ThemeProvider` race between `_loadPreference()` and `toggle()`
**File:** `lib/providers/theme_provider.dart:12, 26-27`

The constructor fires `_loadPreference()` as fire-and-forget. If the user
toggles the theme before `_loadPreference()` completes, the async load
can overwrite the user's toggle with the old saved value.

**Fix:** Track whether a manual toggle occurred during load:
```dart
bool _manuallyToggled = false;

Future<void> _loadPreference() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_key);
  if (saved != null && !_manuallyToggled) {
    _themeMode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}

void toggle() {
  _manuallyToggled = true;
  // ... existing toggle logic
}
```

---

## Round 6 — Suggested Implementation Order

1. **CR-8** — Fix sync gap for completeTask/skipTask/markWorkedOnAndNavigateBack (10 min, `task_provider.dart`)
2. **CR-11** — Add HTTP status checks to Firestore delete methods (5 min, `firestore_service.dart`)
3. **CR-9** — Enqueue sync events in `deleteTaskSubtree` (20 min, `database_helper.dart`)
4. **CR-10** — Enqueue sync events in `deleteTaskAndReparentChildren` (20 min, `database_helper.dart`)
5. **I-23** — Reset sync status on null token early return (5 min, `sync_service.dart`)
6. **I-24** — Enqueue sync events in `removeAllDependencies` (10 min, `database_helper.dart`)
7. **I-27** — Don't sign out on transient network errors (10 min, `auth_provider.dart`)
8. **I-26** — Pass `restoreTo` in `_handleUncomplete` (10 min, `todays_five_screen.dart`)
9. **I-28** — Disable PinButton when at max pins (2 min, `display_utils.dart`)
10. **I-29** — Load `_taskPaths` in `_pickAndPinTask` (5 min, `todays_five_screen.dart`)
11. **I-30** — Add debugPrint to `_signInDesktop` catch (1 min, `auth_service.dart`)
12. **Remaining open items** from previous rounds — as time permits

---
---

## Round 7 (2026-02-25)

Full codebase review after Round 6 fixes (sync layer completeness, auth resilience).
Verified all Round 6 items — all fixed. Major focus: sync correctness on undo/restore
operations, pull-side relationship drift, and mounted-check gaps in async callbacks.

---

### Previous Round Verification

- [x] CR-8: Sync gap for completeTask/skipTask/markWorkedOnAndNavigateBack — verified fixed, `onMutation?.call()` at `task_provider.dart:191, 204, 519`
- [x] CR-9: `deleteTaskSubtree` sync events — verified fixed, enqueues task/relationship/dependency removal entries at `database_helper.dart:1271-1317`
- [x] CR-10: `deleteTaskAndReparentChildren` sync events — verified fixed, enqueues task deletion and reparent additions at `database_helper.dart:1167-1204`
- [x] CR-11: Firestore delete HTTP status checks — verified fixed, all three delete methods check status at `firestore_service.dart:130-167`
- [x] I-23: Sync status reset on null token — verified fixed, `SyncStatus.idle` set at `sync_service.dart:256, 330`
- [x] I-24: `removeAllDependencies` sync events — verified fixed, enqueues removal entries in transaction at `database_helper.dart:1066-1089`
- [x] I-25: `pull()` blocked by `_syncing` — verified present (acceptable trade-off, periodic pulls catch up)
- [x] I-26: `_handleUncomplete` passes `restoreTo` — verified fixed at `todays_five_screen.dart:634` (but see I-31 below for an edge case)
- [x] I-27: `AuthProvider.refreshToken()` — verified fixed, catches transient errors without sign-out at `auth_provider.dart:42-56`
- [x] I-28: PinButton disabled at max pins — verified fixed, `onPressed: disabled ? null : onToggle` at `display_utils.dart:67`
- [x] I-29: `_pickAndPinTask` loads `_taskPaths` — verified fixed at `todays_five_screen.dart:843-848`
- [x] I-30: `_signInDesktop` debugPrint — verified fixed at `auth_service.dart:256`
- [x] M-18 through M-23: Not explicitly fixed (still open from Round 6)

### Items Still Open From Previous Rounds

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- M-10: `showEditUrlDialog` leaks TextEditingController — still open
- M-12: Repeating task code is dead code — still open
- M-14: Firestore `integerValue` null guard on `lastSyncAt` — still open
- M-15: Refresh token stored in plaintext SharedPreferences — still open (future)
- M-16: No error handling in `_loadTodaysTasks()` initial load — still open
- M-18: `_preWorkedOnTimestamps` map grows unboundedly — still open
- M-19: Double refresh on tab navigation — still open
- M-20: Missing `WidgetsFlutterBinding.ensureInitialized()` in `main()` — still open
- M-21: `_initAuth` has no error handling — still open
- M-22: Theme data duplicated between light and dark — still open
- M-23: `ThemeProvider` race between `_loadPreference()` and `toggle()` — still open
- N1–N4: All still open

---

### Critical

#### CR-12. Undo-delete restores task locally but sync queue still has the deletion — cloud data permanently lost
**File:** `lib/data/database_helper.dart:859-901` (restoreTask), `lib/data/database_helper.dart:1338-1359` (restoreTaskSubtree)

When a task is deleted, sync queue entries are enqueued (`task/remove`, `relationship/remove`, etc.). When the user undoes the deletion via `restoreTask`, the task is re-inserted into the DB with its original `sync_status` (from `task.toMap()`), which is `'synced'`. However:

1. **The deletion entries remain in the sync queue.** On the next `push()`, the deletion is processed and the task is removed from Firestore — even though it was restored locally.
2. **The restored task is never re-pushed.** `push()` only pushes tasks with `sync_status: 'pending'`. The restored task has `sync_status: 'synced'`, so it's invisible to push.
3. **Restored relationships and dependencies are also not re-enqueued.** The sync queue only has removal entries from the original deletion.

**Reproduction:**
1. Delete a synced task (sync queue gets 'task/remove' entry)
2. Undo the deletion (task restored locally with `sync_status: 'synced'`)
3. Wait for next push → task deleted from Firestore, never re-added
4. On another device, the task is permanently gone

**Impact:** On multi-device setups, undoing a delete appears to work locally but the task is permanently lost in the cloud and on other devices. Same issue affects `restoreTaskSubtree`.

**Fix:** In `restoreTask` and `restoreTaskSubtree`:
1. Cancel pending sync queue entries for the restored task's `sync_id`:
```dart
// Inside the transaction, before re-inserting the task:
if (task.syncId != null) {
  await txn.delete('sync_queue',
    where: "entity_type = 'task' AND action = 'remove' AND key1 = ?",
    whereArgs: [task.syncId]);
}
```
2. Mark the restored task as `sync_status: 'pending'` so it gets re-pushed:
```dart
final map = task.toMap();
map['sync_status'] = 'pending';
await txn.insert('tasks', map);
```
3. Also cancel relationship/dependency removal entries and re-enqueue additions for restored links.

---

#### CR-13. Sync pull never removes stale relationships/dependencies — permanent drift between devices
**File:** `lib/services/sync_service.dart:349-360`

The `pull()` method pulls all remote relationships and dependencies, then upserts each one locally. But it **never removes** local relationships that don't exist in the remote set. Similarly for dependencies.

```dart
// pull() — lines 352-360:
final remoteRels = await _firestore.pullAllRelationships(uid, idToken);
for (final rel in remoteRels) {
  await _db.upsertRelationshipFromRemote(rel.parentSyncId, rel.childSyncId);
  // ← only adds, never removes
}
```

**Scenario:**
1. Device A: User removes a parent link from task X
2. Device A pushes: `sync_queue` has `relationship/remove`, Firestore deletes it
3. Device B pulls: gets all remote relationships, upserts them. But the removed relationship still exists locally from before — `upsertRelationshipFromRemote` is INSERT OR IGNORE, so it persists
4. Device B still shows the old parent link

Note: `removeRelationshipFromRemote` and `removeDependencyFromRemote` methods exist in `database_helper.dart:1510-1541` but are **never called** anywhere in the codebase.

**Impact:** Relationship and dependency deletions propagated via push are silently lost on the pulling device. Over time, devices diverge — one device has relationships the other doesn't.

**Fix:** After pulling all remote relationships, compute the diff with local synced relationships and remove any that exist locally but not remotely:
```dart
final remoteRels = await _firestore.pullAllRelationships(uid, idToken);
final remoteRelSet = remoteRels.map((r) => '${r.parentSyncId}:${r.childSyncId}').toSet();
final localRels = await _db.getAllSyncedRelationships(); // new method needed
for (final local in localRels) {
  final key = '${local.parentSyncId}:${local.childSyncId}';
  if (!remoteRelSet.contains(key)) {
    await _db.removeRelationshipFromRemote(local.parentSyncId, local.childSyncId);
  }
}
```
Same pattern for dependencies.

---

### Important

#### I-31. `_handleUncomplete` doesn't pass `restoreTo` in the `task.isCompleted` branch
**File:** `lib/screens/todays_five_screen.dart:637-641`

When a task was marked "Done today" (stored in `_workedOnIds`) and then externally completed (e.g., via "Go to task" → complete in All Tasks), `_handleUncomplete` enters the `task.isCompleted` branch. Line 640 calls `unmarkWorkedOn` without `restoreTo`:

```dart
} else if (task.isCompleted) {
  await provider.uncompleteTask(task.id!);
  if (wasWorkedOn) await provider.unmarkWorkedOn(task.id!);  // ← no restoreTo
}
```

The original `lastWorkedAt` value IS in `_preWorkedOnLastWorkedAt[task.id]` but is never read in this branch. This wipes `lastWorkedAt` to `null`, permanently erasing any prior "last worked" timestamp.

**Fix:**
```dart
if (wasWorkedOn) {
  final restoreTo = _preWorkedOnLastWorkedAt.remove(task.id);
  await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
}
```

---

#### I-32. `_swapTask` mutates state before `mounted` check — inconsistent state if widget disposed
**File:** `lib/screens/todays_five_screen.dart:878-887`

After awaiting `getAncestorPath` (line 881), the method mutates `_pinnedIds` (line 879), `_todaysTasks` (line 880), and `_taskPaths` (lines 883-885) before checking `mounted` on line 887. If the widget is disposed during the `await`, the state is mutated but `setState` never fires, causing inconsistency between in-memory state and persisted state (since `_persist()` on line 889 is never reached).

```dart
_pinnedIds.remove(_todaysTasks[index].id);     // line 879 — mutates
_todaysTasks[index] = picked.first;             // line 880 — mutates
final ancestors = await DatabaseHelper()...;    // line 881 — await
// lines 882-885: more mutations
if (!mounted) return;                           // line 887 — too late
```

**Fix:** Move the `mounted` check before the state mutations, or restructure so async work completes before any state is changed:
```dart
final picked = provider.pickWeightedN(eligible, 1);
if (picked.isEmpty) return;
final ancestors = await DatabaseHelper().getAncestorPath(picked.first.id!);
if (!mounted) return;
// Now safe to mutate state
_pinnedIds.remove(_todaysTasks[index].id);
_todaysTasks[index] = picked.first;
if (ancestors.isNotEmpty) {
  _taskPaths[picked.first.id!] = ancestors.map((t) => t.name).join(' › ');
} else {
  _taskPaths.remove(picked.first.id!);
}
setState(() {});
await _persist();
```

---

#### I-33. `onNavigateToTask` callback doesn't check `mounted` after `await`
**File:** `lib/main.dart:150-157`

The `onNavigateToTask` callback awaits `navigateToTask` and then calls `_pageController.animateToPage` without checking `mounted`:

```dart
onNavigateToTask: (task) async {
  await context.read<TaskProvider>().navigateToTask(task);
  _pageController.animateToPage(0, ...);  // ← _pageController may be disposed
},
```

If the `_AppShellState` is disposed during `navigateToTask` (e.g., app backgrounded), `_pageController` could be disposed, causing an exception.

**Fix:**
```dart
onNavigateToTask: (task) async {
  await context.read<TaskProvider>().navigateToTask(task);
  if (!mounted) return;
  _pageController.animateToPage(0, ...);
},
```

---

#### I-34. `getDeletedTasks()` queries for `sync_status = 'deleted'` which is never set — dead code
**File:** `lib/data/database_helper.dart:1382-1387`

```dart
Future<List<Task>> getDeletedTasks() async {
  final db = await database;
  final maps = await db.query('tasks', where: "sync_status = 'deleted'");
  return _tasksFromMaps(maps);
}
```

No code anywhere in the codebase sets `sync_status` to `'deleted'`. Task deletions use `DELETE FROM tasks` (actual row removal), not a soft-delete flag. This method always returns an empty list.

**Fix:** Remove `getDeletedTasks()` as dead code.

---

#### I-35. `removeRelationshipFromRemote` and `removeDependencyFromRemote` are never called
**File:** `lib/data/database_helper.dart:1510-1541`

These methods exist to remove relationships/dependencies by sync_id (for processing remote deletions during pull), but they are never called anywhere. The `pull()` method only upserts, never removes (see CR-13). These are unused but correctly implemented — they should be wired into the pull logic per CR-13.

**Fix:** Wire these into the `pull()` method as part of the CR-13 fix.

---

### Minor

#### M-24. `_autoStartedIds` never cleaned up on day rollover
**File:** `lib/screens/todays_five_screen.dart:31`

`_autoStartedIds` is an in-memory set tracking which tasks were auto-started by "Done today". It's never cleared when `_generateNewSet` runs (day rollover) or in `_loadTodaysTasks`. Stale IDs accumulate harmlessly but waste memory.

**Fix:** Clear `_autoStartedIds` (and `_workedOnIds`, `_preWorkedOnLastWorkedAt`) at the start of `_generateNewSet`.

---

#### M-25. `_chipsOverflow` creates `TextPainter` objects without disposing them
**File:** `lib/screens/todays_five_screen.dart:1290-1312`

`_chipsOverflow` creates `TextPainter(...)..layout()` to measure chip widths but never calls `textPainter.dispose()`. In modern Flutter, `TextPainter` allocates native resources that should be disposed. This is called on every build when the "Also done today" box is visible.

**Fix:** Call `tp.dispose()` after measuring each chip:
```dart
final tp = TextPainter(...)..layout();
final width = tp.width;
tp.dispose();
```

---

#### M-26. `BackupService.importDatabase` doesn't trigger Today's 5 refresh
**File:** `lib/services/backup_service.dart:90-110`

After importing a backup, `provider.loadRootTasks()` refreshes the All Tasks screen, but Today's 5 in-memory state (`_todaysTasks`, `_completedIds`, `_pinnedIds`) remains stale. The imported DB may have different `todays_five_state` data, but the Today's 5 screen won't refresh until the user manually switches tabs.

**Fix:** After import, also trigger `refreshSnapshots()` on the Today's 5 screen, or navigate to root and force-refresh both screens.

---

#### M-27. `_EdgePainter.shouldRepaint` uses identity comparison on lists
**File:** `lib/screens/dag_view_screen.dart:586`

`shouldRepaint` compares `edgePaths` with `!=` (identity comparison for List). Since `_edgePaths` is a new list on every `_computeLayout`, this always returns `true`. The painter repaints correctly but does unnecessary work.

**Fix:** Use `listEquals` from `foundation.dart`, or accept as negligible (DAG screen is rarely rebuilt).

---

## Round 7 — Suggested Implementation Order

1. **CR-12** — Fix undo-delete sync: cancel pending deletions + mark restored task as pending (20 min, `database_helper.dart`)
2. **CR-13** — Fix pull to remove stale local relationships/dependencies (30 min, `sync_service.dart` + `database_helper.dart`)
3. **I-31** — Pass `restoreTo` in `_handleUncomplete` completed branch (2 min, `todays_five_screen.dart`)
4. **I-32** — Fix `_swapTask` mounted check ordering (5 min, `todays_five_screen.dart`)
5. **I-33** — Add mounted check in `onNavigateToTask` (1 min, `main.dart`)
6. **I-34** — Remove dead `getDeletedTasks()` (1 min, `database_helper.dart`)
7. **I-35** — Wire `removeRelationshipFromRemote`/`removeDependencyFromRemote` into pull (part of CR-13)
8. **M-24 through M-27** — as time permits
9. **Remaining open items** from previous rounds — as time permits

---
---

## Round 8 (2026-03-07)

Full codebase review after Round 7 fixes, schedule feature addition, DAG view
performance overhaul, notification support, and version bump to 1.1.9. Verified
all Round 7 items. Major focus: silent partial-pull data loss in sync layer, and
missing sync metadata updates.

---

### Previous Round Verification

- [x] CR-12: Undo-delete sync: cancel pending deletions + mark restored task as pending — verified fixed, `restoreTask` at `database_helper.dart:970-979` cancels sync queue entries and sets `sync_status = 'pending'`; `restoreTaskSubtree` at lines 1564-1577 does the same
- [x] CR-13: Pull removes stale local relationships/dependencies — verified fixed, `sync_service.dart:440-454` computes diff and calls `removeRelationshipFromRemote`; lines 466-480 for dependencies
- [x] I-31: `_handleUncomplete` passes `restoreTo` in `task.isCompleted` branch — verified fixed at `todays_five_screen.dart:703-710`, both branches now pass `restoreTo`
- [x] I-32: `_swapTask` mounted check before state mutation — verified fixed at `todays_five_screen.dart:952`, `mounted` check before mutations
- [x] I-33: `onNavigateToTask` mounted check after await — verified fixed at `main.dart:171`
- [x] I-34: Dead `getDeletedTasks()` removed — verified, no such method exists in codebase
- [x] I-35: `removeRelationshipFromRemote`/`removeDependencyFromRemote` wired into pull — verified, called from `sync_service.dart:450` and `476`

### Items Still Open From Previous Rounds

- I6: Loading indicators for async UI transitions — still open
- M3: `_renameTask` dialog leaks TextEditingController — still open
- M5: `BackupService` hardcodes Android download path — still open
- M6: DAG view doesn't recompute layout on rotation — still open
- M9: N+1 queries in `_addParent` for grandparent siblings — still open
- M-10: `showEditUrlDialog` leaks TextEditingController — still open
- M-12: Repeating task code is dead code — still open
- M-14: Firestore `integerValue` null guard on `lastSyncAt` — still open
- M-15: Refresh token stored in plaintext SharedPreferences — still open (future)
- M-16: No error handling in `_loadTodaysTasks()` initial load — still open
- M-18: `_preWorkedOnTimestamps` map grows unboundedly — still open
- M-19: Double refresh on tab navigation — still open
- M-20: Missing `WidgetsFlutterBinding.ensureInitialized()` in `main()` — still open
- M-21: `_initAuth` has no error handling — still open
- M-22: Theme data duplicated between light and dark — still open
- M-23: `ThemeProvider` race between `_loadPreference()` and `toggle()` — still open
- M-24: `_autoStartedIds` never cleaned up on day rollover — still open
- M-25: `_chipsOverflow` creates TextPainter objects without disposing them — fixed (dispose() already present)
- M-26: `BackupService.importDatabase` doesn't trigger Today's 5 refresh — still open
- M-27: `_EdgePainter.shouldRepaint` uses identity comparison on lists — still open
- N1–N4: All still open

---

### Critical

#### CR-14. Silent partial pull deletes local data — relationships, dependencies, and schedules lost on transient HTTP errors [FIXED in Round 8 fix]
**Files:**
- `lib/services/firestore_service.dart:213, 241, 327`
- `lib/services/sync_service.dart:440-454, 466-480, 487-500`

The `pullAllRelationships`, `pullAllDependencies`, and `pullAllSchedules` methods
use paginated Firestore LIST requests. If any page request returns a non-200
status (e.g., 401 token expiry mid-pagination, 500 transient error, network
timeout), the method silently `break`s out of the pagination loop and returns
**partial results**:

```dart
// firestore_service.dart line 213:
if (response.statusCode != 200) break;  // silent — returns whatever was fetched so far
```

The caller in `sync_service.dart` then treats this partial result as the
**complete** remote state and deletes local items not in the set:

```dart
// sync_service.dart lines 440-454:
final remoteRelSet = remoteRels.map(...).toSet();  // INCOMPLETE set
for (final local in localRels) {
  if (!remoteRelSet.contains(key) && !pendingRelKeys.contains(key)) {
    await _db.removeRelationshipFromRemote(...);  // DELETES valid local data
  }
}
```

**Reproduction:**
1. User has 500 relationships (2 pages of 300)
2. Page 1 succeeds (300 relationships fetched)
3. Page 2 fails (token expired, 401)
4. `pullAllRelationships` returns 300 of 500 relationships
5. Pull logic deletes the 200 local relationships not in the partial set
6. 200 relationships permanently lost

**Impact:** Any transient HTTP error during a multi-page pull causes irreversible
deletion of local relationships, dependencies, and schedules. This is the most
dangerous data-loss vector in the sync layer.

**Fix:** Throw on non-200 status instead of silently breaking. Let the caller's
try-catch handle the error, preserving local data:
```dart
// In pullAllRelationships, pullAllDependencies, pullAllSchedules:
if (response.statusCode != 200) {
  throw FirestoreException(
    'Pull relationships failed on page: ${response.statusCode}');
}
```

The `pull()` method's existing catch block at `sync_service.dart:387-388`
will handle the exception and set `SyncStatus.error`, preventing the
destructive diff logic from running on incomplete data.

---

#### CR-15. `replaceSchedules` doesn't mark task as dirty when updating `is_schedule_override` [FIXED in Round 8 fix]
**File:** `lib/data/database_helper.dart:2287-2291`

When updating the `is_schedule_override` flag on a task, the update does not
include `_dirtyFields()` — meaning `updated_at` and `sync_status` are not
updated:

```dart
if (isOverride != null) {
  await txn.update('tasks',
    {'is_schedule_override': isOverride ? 1 : 0},  // missing _dirtyFields()
    where: 'id = ?', whereArgs: [taskId]);
}
```

Compare with every other task mutation method which includes `..._dirtyFields()`
to mark the task as `sync_status: 'pending'` and update `updated_at`.

**Impact:** When a user toggles schedule override on/off, the change is saved
locally but never synced to Firestore. On another device (or after
"Replace with cloud data"), the override flag reverts to its old value.

**Fix:**
```dart
if (isOverride != null) {
  await txn.update('tasks',
    {'is_schedule_override': isOverride ? 1 : 0, ..._dirtyFields()},
    where: 'id = ?', whereArgs: [taskId]);
}
```

---

### Important

#### I-36. `hasRemoteData` returns `false` on transient errors — wrong sync decision [FIXED in Round 8 fix]
**File:** `lib/services/firestore_service.dart:176-182`

```dart
Future<bool> hasRemoteData(String uid, String idToken) async {
  final url = Uri.parse('${_tasksPath(uid)}?pageSize=1');
  final response = await http.get(url, headers: _headers(idToken)).timeout(_httpTimeout);
  if (response.statusCode != 200) return false;  // ← treats 500/503/429 as "no data"
  ...
}
```

This method is called during first sign-in to decide whether to offer migration
options. If Firestore returns a transient error (500, 503, rate limit), the method
reports "no remote data", potentially leading the user to choose "push local"
when they actually have existing cloud data — overwriting it.

**Fix:** Only treat 200 with empty results as "no data". Throw on unexpected
status codes:
```dart
if (response.statusCode != 200) {
  throw FirestoreException('Check remote data failed: ${response.statusCode}');
}
```

---

#### I-37. `_showRandomResult` recursive calls lack mounted checks [FIXED in Round 8 fix]
**File:** `lib/screens/task_list_screen.dart:738-770`

The `_showRandomResult` method recursively calls itself (lines 743-747 and
764-769) after showing picker dialogs and awaiting `navigateInto`. No `mounted`
check before the recursive call:

```dart
// Line 743-747:
final result = await showDialog<Task?>(...);
if (result != null) {
  await provider.navigateInto(result);  // async
  _showRandomResult(result);            // no mounted check before this
}
```

If the widget is disposed while the picker dialog is open or during
`navigateInto`, the recursive call accesses a stale `context`.

**Fix:** Add `if (!mounted) return;` before each recursive call:
```dart
if (result != null) {
  await provider.navigateInto(result);
  if (!mounted) return;
  _showRandomResult(result);
}
```

---

### Minor

#### M-28. `NotificationService.init()` can register duplicate callbacks [FIXED in Round 8 fix]
**File:** `lib/services/notification_service.dart:45-82`

If `init()` is called multiple times (e.g., after hot restart during
development), `initialize()` registers a new `onDidReceiveNotificationResponse`
callback each time. The notification ID is fixed so scheduling is idempotent,
but the callback could fire multiple times.

**Fix:** Track initialization state:
```dart
bool _initialized = false;

Future<void> init() async {
  if (_initialized) return;
  _initialized = true;
  // ... existing logic ...
}
```

---

#### M-29. `_chipsOverflow` in Today's 5 leaks `TextPainter` objects (repeat of M-25, still unfixed) [ALREADY FIXED]
**File:** `lib/screens/todays_five_screen.dart:1290-1312`

`TextPainter` objects are created and laid out but never `dispose()`d. In
modern Flutter, `TextPainter` allocates native resources that require explicit
disposal. This runs on every build when the "Also done today" box is visible.

**Fix:** Call `tp.dispose()` after measuring:
```dart
final tp = TextPainter(...)..layout();
final width = tp.width;
tp.dispose();
```

---

## Round 8 — Suggested Implementation Order

1. **CR-14** — Throw on partial pull instead of silently breaking (5 min, `firestore_service.dart` — change `break` to `throw` in 3 methods)
2. **CR-15** — Add `_dirtyFields()` to `is_schedule_override` update (1 min, `database_helper.dart` line 2289)
3. **I-36** — Throw on non-200 in `hasRemoteData` (2 min, `firestore_service.dart`)
4. **I-37** — Add mounted checks in `_showRandomResult` recursive calls (2 min, `task_list_screen.dart`)
5. **Remaining open items** from previous rounds — as time permits

---

## Round 9 (2026-03-12)

Full codebase review after Round 8 fixes, security review Round 4 fixes,
and Today's 5 pin state / eager pin transfer feature (d184bdc).

---

### Previous Round Verification

- [x] CR-14: Throw on partial pull — verified fixed at `firestore_service.dart:216`, now throws `FirestoreException` instead of `break`
- [x] CR-15: `_dirtyFields()` on `is_schedule_override` update — verified fixed at `database_helper.dart:2289`
- [x] I-36: `hasRemoteData` throws on non-200 — verified fixed at `firestore_service.dart:180`
- [x] I-37: `_showRandomResult` mounted checks — partially fixed: `pickAnother` branch has mounted check at line 827, but `goDeeper` branch (line 806) still lacks one before the recursive call. In practice safe because the recursive method re-checks mounted at line 786, but inconsistent with `pickAnother`.
- [x] M-28: `NotificationService.init()` idempotent guard — verified fixed at `notification_service.dart:44-50`
- [x] M-29: `_chipsOverflow` TextPainter disposal — already fixed (confirmed in Round 8)

### Items Still Open From Previous Rounds

- I6: Loading indicators for async UI transitions — **FIXED (deferred fix round)** — loading spinner shown during `_fetchCandidateData`
- M3: `_renameTask` dialog leaks TextEditingController — **FIXED (deferred fix round)**
- M5: `BackupService` hardcodes Android download path — **ALREADY FIXED** — Android uses SAF save dialog; Linux `~/Downloads` is acceptable (dev-only)
- M6: DAG view doesn't recompute layout on rotation — **FIXED (deferred fix round)** — `didChangeDependencies` detects size changes
- M9: N+1 queries in `_addParent` for grandparent siblings — **FIXED (deferred fix round)** — batch `getChildIdsForParents` query
- M-10: `showEditUrlDialog` leaks TextEditingController — **FIXED (deferred fix round)**
- M-12: Repeating task code is dead code — **FIXED (deferred fix round)** — removed dead DB methods and model getters
- M-14: Firestore `integerValue` null guard on `lastSyncAt` — **ALREADY FIXED** — `lastSyncAt` is guarded at call site (non-null when passed)
- M-15: Refresh token stored in plaintext SharedPreferences — still open (needs `flutter_secure_storage` dep)
- M-16: No error handling in `_loadTodaysTasks()` initial load — **ALREADY FIXED** — try-catch wrapper added in earlier round
- M-18: `_preWorkedOnTimestamps` map grows unboundedly — **FIXED (deferred fix round)** — cleared on provider change
- M-19: Double refresh on tab navigation — **FIXED (deferred fix round)** — removed duplicate refresh from `onDestinationSelected`
- M-20: Missing `WidgetsFlutterBinding.ensureInitialized()` in `main()` — **ALREADY FIXED** — present on line 17
- M-21: `_initAuth` has no error handling — **FIXED (deferred fix round)** — wrapped in try-catch
- M-22: Theme data duplicated between light and dark — **FIXED (deferred fix round)** — extracted `_buildTheme(Brightness)`
- M-23: `ThemeProvider` race between `_loadPreference()` and `toggle()` — **FIXED (deferred fix round)** — `_manuallyToggled` flag
- M-24: `_autoStartedIds` never cleaned up on day rollover — **ALREADY FIXED** — cleared in `_generateNewSet()`
- M-26: `BackupService.importDatabase` doesn't trigger Today's 5 refresh — **acceptable** — `refreshSnapshots()` runs on tab switch
- M-27: `_EdgePainter.shouldRepaint` uses identity comparison on lists — **ALREADY FIXED** — uses `listEquals`
- N1–N4: N2 **FIXED (deferred fix round)** — 200ms debounce on TaskPickerDialog filter, N3 **ALREADY FIXED** (no const warnings from analyzer), N4 **ALREADY FIXED** (v8 migration normalizes defaults)

---

### Important

#### I-38. `_transferPinToChild` bypasses TaskProvider for Today's 5 DB mutations
**File:** `lib/screens/task_list_screen.dart:175-210`

The new `_transferPinToChild` method directly accesses `DatabaseHelper()` to
load/save Today's 5 state instead of going through a provider method. This
creates the same class of issue documented in C2 (Round 1): the Today's 5
screen's in-memory state can diverge from the DB.

While the new `refreshSnapshots()` code at `todays_five_screen.dart:237-258`
detects this divergence and reloads from DB on tab switch, there's a window
where both screens hold independent state. If `_persist()` runs on the
Today's 5 screen before the user switches tabs (e.g., via a timer or
completion action), it could overwrite the pin transfer.

**Fix:** Add a `transferPin(oldTaskId, newTaskId)` method to a shared
provider or manager so both screens see the same state, or at minimum
have `_transferPinToChild` notify the Today's 5 screen to reload
immediately via a callback.

---

#### I-39. `launchUrl` not awaited and no error handling on task list screen [FIXED in Round 9 fix]
**File:** `lib/screens/task_list_screen.dart:1085`

The URL launch button fires `launchUrl()` without awaiting the result and
without error handling:

```dart
launchUrl(uri, mode: LaunchMode.externalApplication);
```

Compare with `leaf_task_detail.dart:65-70` which properly awaits and shows
a snackbar on failure:

```dart
final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
if (!launched && context.mounted) {
  ScaffoldMessenger.of(context).showSnackBar(...);
}
```

**Fix:** Match the `leaf_task_detail.dart` pattern — await the result and
show feedback if the URL fails to open. The `onPressed` callback needs to
be `async`.

---

#### I-40. `_showRandomResult` goDeeper branch missing mounted check (I-37 incomplete) [FIXED in Round 9 fix]
**File:** `lib/screens/task_list_screen.dart:801-811`

The `goDeeper` branch calls `_showRandomResult` recursively at line 806
without a `mounted` check, while the `pickAnother` branch (line 827)
includes one. Although the recursive method re-checks `mounted` at line
786, the inconsistency means `context.read<TaskProvider>()` at line 769
could access a disposed widget's context in an edge case where disposal
happens between the switch statement and the method's first line.

**Fix:** Add `if (!mounted) return;` before line 806:
```dart
if (picked.isNotEmpty) {
  if (!mounted) return;
  await _showRandomResult(
    picked.first,
    siblingPool: eligible,
    navigateTarget: task,
  );
}
```

---

#### I-41. Refresh token not URL-encoded in form body [FIXED in Round 9 fix]
**File:** `lib/services/auth_service.dart:327`

The refresh token is interpolated directly into a
`application/x-www-form-urlencoded` POST body without encoding:

```dart
body: 'grant_type=refresh_token&refresh_token=$refreshToken',
```

While Google refresh tokens typically contain only URL-safe characters,
the `x-www-form-urlencoded` spec requires values to be percent-encoded.
A token containing `+`, `&`, or `=` would break the request.

**Fix:** Use `Uri.encodeQueryComponent`:
```dart
body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(refreshToken)}',
```

---

### Minor

#### M-30. Today's date key logic duplicated in 3 places [FIXED in Round 9 fix]
**Files:**
- `lib/screens/todays_five_screen.dart:106-108` (`_todayKey()`)
- `lib/services/sync_service.dart:32-35` (`_todayDateKey()`)
- `lib/screens/task_list_screen.dart:183` (inline in `_transferPinToChild`)

All three produce the same `YYYY-MM-DD` string with identical logic. If the
format needs to change (e.g., for timezone handling), all three must be
updated in lockstep.

**Fix:** Extract to a shared utility, e.g., in `display_utils.dart`:
```dart
String todayDateKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}
```

---

#### M-31. `onMutation` calling pattern inconsistent across TaskProvider methods [FIXED in Round 9 fix]
**File:** `lib/providers/task_provider.dart`

Some mutation methods explicitly call `onMutation?.call()` before navigating
(e.g., `completeTask` line 203, `skipTask` line 216, `markWorkedOnAndNavigateBack`
line 563), while others rely on the implicit call inside
`_refreshCurrentList(isMutation: true)` (e.g., `startTask`, `unstartTask`,
`completeTaskOnly`, `unskipTask`, `uncompleteTask`).

Both paths work correctly since `_refreshCurrentList` defaults to
`isMutation: true` (line 716). However, the inconsistency means:
- The sync trigger timing differs (before vs after UI refresh)
- If someone adds `isMutation: false` to a call site, sync silently breaks

**Fix:** Choose one pattern and use it consistently. Recommend explicit
`onMutation?.call()` in each mutation method rather than relying on
`_refreshCurrentList`'s default.

**Actual fix:** Extracted `_refreshAfterMutation()` which calls `_refreshCurrentList()` then `onMutation?.call()`. Removed `isMutation` parameter from `_refreshCurrentList`. All mutation methods now use `_refreshAfterMutation()`, navigation methods use `_refreshCurrentList()`, and methods that navigate back after mutation keep their explicit `onMutation?.call()` before `navigateBack()`.

---

#### M-32. N+1 queries in `deleteTaskAndReparentChildren` nested loop
**File:** `lib/data/database_helper.dart:1344-1357`

The reparenting loop queries `task_relationships` individually for each
(parentId, childId) pair to check if the relationship already exists:

```dart
for (final parentId in parentIds) {
  for (final childId in childIds) {
    final existing = await txn.query('task_relationships',
        where: 'parent_id = ? AND child_id = ?',
        whereArgs: [parentId, childId]);
```

For a task with M parents and N children, this runs M×N queries. Could
batch-check all desired pairs in a single query using an `IN` clause or
`INSERT OR IGNORE` with a unique index.

In practice M and N are small (typically 1-2 parents), so this is low
priority.

---

#### M-33. `_brainDump` pin transfer picks random child from stale pool [FIXED in Round 9 fix]
**File:** `lib/screens/task_list_screen.dart:267-275`

After `addTasksBatch`, the code picks a child to inherit the pin via
`provider.pickWeightedN(children, 1)`. The `children` are read from
`provider.tasks`, which was refreshed by `addTasksBatch`. However,
the picked child might not be one of the newly added tasks — it could
be a pre-existing child of the parent. This means a brain dump on a
pinned parent with existing children might transfer the pin to an
unrelated existing child instead of one of the new tasks.

**Fix:** Filter `provider.tasks` to only include the newly added tasks
(e.g., by capturing task IDs from `addTasksBatch` return value), or
use `provider.tasks.where((t) => names.contains(t.name))`.

---

### Refactoring

#### R-9. `_transferPinToChild` should share infrastructure with Today's 5 screen
**File:** `lib/screens/task_list_screen.dart:175-210`

The method duplicates the load-modify-save pattern for Today's 5 state
that already exists in `todays_five_screen.dart`. Both screens now
independently manage pin state in the DB, with `refreshSnapshots()`
acting as a reconciliation layer. As pin logic grows (e.g., auto-pin
rules, pin limits), this split ownership will become harder to maintain.

**Suggested refactor:** Extract Today's 5 state management into a
dedicated provider or manager class that both screens share. This would
make pin transfers atomic and eliminate the need for the divergence
detection in `refreshSnapshots()`.

---

## Round 9 — Suggested Implementation Order

1. **I-40** — Add mounted check in goDeeper branch (1 min, `task_list_screen.dart` line 806)
2. **I-39** — Await launchUrl and add error handling (2 min, `task_list_screen.dart` line 1085)
3. **I-41** — URL-encode refresh token in form body (1 min, `auth_service.dart` line 327)
4. **M-30** — Extract shared `todayDateKey()` utility (5 min, 3 files)
5. **I-38** / **R-9** — Consolidate Today's 5 state management (larger refactor, future)
6. **M-31** — Standardize `onMutation` pattern (10 min, `task_provider.dart`)
7. **Remaining open items** from previous rounds — as time permits

---

## Deferred Fix Round (2026-03-13)

Batch fix of all remaining open items from rounds 1–9.

### Fixed in this round

| Item | Fix | File(s) |
|------|-----|---------|
| I6 | Loading spinner during `_fetchCandidateData` for picker dialogs | `task_list_screen.dart` |
| M3 | `controller.dispose()` after rename dialog | `task_list_screen.dart` |
| M6 | `didChangeDependencies` detects size changes, rebuilds graph | `dag_view_screen.dart` |
| M9 | Batch `getChildIdsForParents(List<int>)` replaces N+1 loop | `database_helper.dart`, `task_provider.dart`, `task_list_screen.dart` |
| M-10 | `.then((_) => controller.dispose())` on URL edit dialog | `leaf_task_detail.dart` |
| M-12 | Removed dead `updateRepeatInterval`, `completeRepeatingTask`, `isRepeating`, `isDue` | `database_helper.dart`, `task.dart`, tests |
| M-18 | `_preWorkedOnTimestamps` cleared on provider change | `task_list_screen.dart` |
| M-19 | Removed duplicate refresh from `onDestinationSelected` | `main.dart` |
| M-21 | `_initAuth` wrapped in try-catch | `main.dart` |
| M-22 | Extracted `_buildTheme(Brightness)` to deduplicate light/dark | `main.dart` |
| M-23 | `_manuallyToggled` flag prevents async load overwriting user toggle | `theme_provider.dart` |
| N2 | 200ms debounce on TaskPickerDialog filter | `task_picker_dialog.dart` |

### Already fixed (confirmed in this round)

| Item | Status |
|------|--------|
| M5 | Android uses SAF; Linux `~/Downloads` acceptable (dev-only) |
| M-14 | `lastSyncAt` guarded at call site (non-null when passed) |
| M-16 | try-catch wrapper already present |
| M-20 | `WidgetsFlutterBinding.ensureInitialized()` on line 17 |
| M-24 | Cleared in `_generateNewSet()` |
| M-27 | Uses `listEquals` |
| N3 | No const warnings from analyzer |
| N4 | v8 migration normalizes defaults |

### Remaining open

| Item | Reason |
|------|--------|
| M-15 | Needs `flutter_secure_storage` dependency — future |
| M-26 | Acceptable: `refreshSnapshots()` runs on tab switch |

---
---

## Round 10 (2026-03-31)

Full codebase review after 155 commits since last round — roulette terminology
rebrand, starred view enhancements (dependency chain ordering, colour-only
priority, expanded dialog improvements), pin-on-add bugfix, remove-dependency
text overflow fix, dependent-task-freed-on-done-today feature, and version
bumps to 1.2.15. Verified Deferred Fix Round items. Major focus: sync gaps
in single-task deletion, TextEditingController regressions, and async
lifecycle safety.

---

### Previous Round Verification

- [x] I-39: `launchUrl` awaited and error handled — verified, `launchSafeUrl` utility used at `leaf_task_detail.dart:55`
- [x] I-40: `_showRandomResult` goDeeper mounted check — verified, mounted check present
- [x] I-41: Refresh token URL-encoded — verified via `_refreshFirebaseToken` implementation
- [x] M-30: `todayDateKey()` shared utility — verified, `_todayKey()` and `_todayDateKey()` consistent
- [x] M-31: `onMutation` pattern standardized — verified, `_refreshAfterMutation()` extracted; mutation methods use it, navigation methods use `_refreshCurrentList()`
- [x] M-33: `_brainDump` pin transfer pool — verified present (acceptable, existing children are valid candidates)

### Deferred Fix Round Verification (spot-checks)

- [x] M3: `_renameTask` dialog TextEditingController disposal — verified fixed, `controller.dispose()` in finally block at `task_list_screen.dart:648`
- [x] M-10: `showEditUrlDialog` TextEditingController disposal — verified fixed, `.then((_) => controller.dispose())` at `leaf_task_detail.dart:122`
- [x] M6: DAG view recompute on rotation — verified fixed
- [x] M9: Batch `getChildIdsForParents` — verified fixed
- [x] M-12: Dead repeating task code removed — verified
- [x] M-22: `_buildTheme(Brightness)` extracted — verified
- [x] M-23: `_manuallyToggled` flag — verified

### Items Still Open From Previous Rounds

- I-38 / R-9: `_transferPinToChild` bypasses TaskProvider for Today's 5 mutations — still open (future refactor), direct `DatabaseHelper()` at `task_list_screen.dart:394`
- M-15: Refresh token in plaintext SharedPreferences — **FIXED**: `flutter_secure_storage` imported and used at `auth_service.dart:6,54,345-349` with migration from legacy plaintext
- M-26: `BackupService.importDatabase` doesn't trigger Today's 5 refresh — **FIXED**: `provider.loadRootTasks()` at `backup_service.dart:110` refreshes Today's 5 via provider chain
- M-32: N+1 queries in `deleteTaskAndReparentChildren` nested loop — still open (low impact), loop at `database_helper.dart:2019-2032`

---

### Critical

#### CR-16. ~~TextEditingController disposal regressions~~ — **FALSE POSITIVE (verified)**
**Status:** Invalid. Verification confirmed both disposals ARE present:
- `task_list_screen.dart:648` — `controller.dispose()` in `finally` block
- `leaf_task_detail.dart:122` — `.then((_) => controller.dispose())`
The original review used stale line numbers. No regression occurred.

---

#### CR-17. `deleteTaskWithRelationships` doesn't enqueue relationship/dependency removal sync events — **[FIXED in Round 10 fix]**
**Status:** Fixed. The original review was correct — sync queue entries for
relationships, dependencies, and schedules were missing. The fix commit
(`0515d53`) added them. The verify session incorrectly marked this as
FALSE POSITIVE because it checked the code after the fix was already applied.
The method now correctly enqueues all four sync types:
- Relationship removals (lines 1540-1559)
- Dependency removals (lines 1560-1579)
- Schedule removals (lines 1580-1591)
- Task deletion (lines 1601-1610)

---

### Important

#### I-42. `addRelationship()` in TaskProvider doesn't call `_refreshAfterMutation()` [FIXED in code-review-fix]
**File:** `lib/providers/task_provider.dart:305-308`

Now calls `await _refreshAfterMutation()` at line 307 with CR-fix comment.

---

#### I-43. `reorderStarredTasks()` calls `onMutation()` without `notifyListeners()` [FIXED in code-review-fix]
**File:** `lib/providers/task_provider.dart:663-666`

Now calls `await _refreshAfterMutation()` at line 665 instead of bare `onMutation?.call()`.

---

#### ~~I-43 original description for reference~~

This called `onMutation` (triggering sync push) but didn't call
`notifyListeners()` or `_refreshAfterMutation()`. The starred screen manages
its own list locally (line 150-155 in `starred_screen.dart`), so the missing
`notifyListeners` didn't cause a visual bug. However, the inconsistency
with the `_refreshAfterMutation()` pattern meant sync fired before the
provider state was refreshed.

**Original fix:** Use `_refreshAfterMutation()` for consistency:
```dart
Future<void> reorderStarredTasks(List<int> taskIds) async {
  await _db.reorderStarredTasks(taskIds);
  await _refreshAfterMutation();
}
```

---

#### I-44. `_persistAndTrim()` not awaited in `_togglePinFromSheet` [FIXED in code-review-fix]
**File:** `lib/screens/todays_five_screen.dart:777`

Now awaited: `await _persistAndTrim();` with CR-fix I-44 comment at line 749.

---

#### I-45. `completion_animation.dart` calls `widget.onDone()` without mounted check [FIXED in code-review-fix]
**File:** `lib/widgets/completion_animation.dart:92-96`

Now checks `mounted` before calling `widget.onDone()` with CR-fix I-45 comment.

---

#### I-46. `_reorderByDependencyChains` and `reorderByDependencyChains` have no cycle detection [FIXED in code-review-fix]
**Files:**
- `lib/providers/task_provider.dart:829-832`
- `lib/screens/starred_screen.dart:371-374`

Both implementations now have a `visited` set with `if (!visited.add(id)) return;`
cycle guard, with CR-fix I-46 comments.

---

#### I-47. Token refresh not deduplicated — concurrent callers can race [FIXED in code-review-fix]
**File:** `lib/services/auth_service.dart:194-202`

Now uses `_refreshFuture` cached Future with `??=` pattern to deduplicate concurrent
refresh calls. `whenComplete` resets the Future after completion. CR-fix I-47 comment present.

---

### Minor

#### M-34. Starred screen N+1 queries for tree preview data
**File:** `lib/screens/starred_screen.dart:66-91`

`_loadStarredTasks` loads children and grandchildren individually for each
starred task:

```dart
final treeEntries = await Future.wait(starred.map((task) async {
  final children = await provider.getChildren(task.id!);
  // ...
  final childEntries = await Future.wait(shownChildren.map((child) async {
    final grandchildren = await provider.getChildren(child.id!);
```

For N starred tasks with M children each, this runs N + N*min(M,3) DB
queries. With 10 starred tasks averaging 5 children, that's 40 queries.
All queries are parallelized via `Future.wait`, so latency is bounded,
but DB contention can still cause jank.

**Fix (future):** Add a batch query `getChildrenForMultipleParents(List<int>)`
to reduce to 2 queries total (one for children, one for grandchildren).

---

#### M-35. `_onReorder` in starred screen calls provider method without await
**File:** `lib/screens/starred_screen.dart:155`

```dart
context.read<TaskProvider>().reorderStarredTasks(taskIds);
```

The async `reorderStarredTasks` is called without `await`. If the DB write
fails, the error is silently swallowed. The local `setState` (line 150-153)
has already optimistically updated the UI, so a DB failure leaves the UI
and DB out of sync.

**Fix:**
```dart
void _onReorder(int oldIndex, int newIndex) async {
  if (oldIndex < newIndex) newIndex--;
  setState(() {
    final task = _starredTasks.removeAt(oldIndex);
    _starredTasks.insert(newIndex, task);
  });
  final taskIds = _starredTasks.map((t) => t.id!).toList();
  await context.read<TaskProvider>().reorderStarredTasks(taskIds);
}
```

---

#### M-36. `_chipsOverflow` TextPainter disposal inconsistent
**File:** `lib/screens/todays_five_screen.dart`

Round 8 noted M-29 (TextPainter disposal) as "ALREADY FIXED", but verify
that `TextPainter.dispose()` is consistently called in all code paths.
Any path that creates a TextPainter for measurement without disposing it
leaks native resources.

---

#### M-37. `showInfoSnackBar` used outside of `_togglePinFromSheet` before mounted check
**File:** `lib/screens/todays_five_screen.dart:755-756`

In the `else` branch of `_togglePinFromSheet`, `showInfoSnackBar` is called
after an async operation (`TodaysFivePinHelper.togglePinInPlace`) without a
`mounted` check. If the widget is disposed during the async operation,
accessing `context` via `showInfoSnackBar` could crash.

**Fix:** Add `if (!mounted) return;` before `ScaffoldMessenger` / snackbar
calls in the error path.

---

## Round 10 — Status

**CR-16 was a false positive** (disposals already present). **CR-17 was correctly
identified and fixed** — the verify session incorrectly marked it false positive
because it checked after the fix was applied.

**All Important items (I-42 through I-47) fixed** in the code-review-fix session.

Remaining minor items: M-34 through M-38.

---

## Round 10 Fix (2026-03-31)

### Fixed
| ID | Title | Fix |
|----|-------|-----|
| CR-16 | ~~TextEditingController disposal regressions~~ | **FALSE POSITIVE** — disposals already present (line 648 and line 122) |
| CR-17 | `deleteTaskWithRelationships` missing sync events | Added rel/dep/schedule removal sync queue entries before delete |
| I-42 | `addRelationship` missing `_refreshAfterMutation` | Added call |
| I-43 | `reorderStarredTasks` inconsistent pattern | Replaced `onMutation` with `_refreshAfterMutation` |
| I-44 | `_persistAndTrim` not awaited in `_togglePinFromSheet` | Added `await`, changed method to async |
| I-45 | Completion animation `onDone` without mounted check | Added `if (mounted)` guard |
| I-46 | `walkChain` no cycle detection | Added `visited` set in both `task_provider.dart` and `starred_screen.dart` |
| I-47 | Token refresh not deduplicated | Added `_refreshFuture` dedup in `AuthService.refreshToken()` |
| M-35 | `_onReorder` not awaiting async call | Added `await` |
| M-37 | `showInfoSnackBar` without mounted check in pin error path | Added `if (mounted)` guard |

### Already Fixed
| ID | Title | Notes |
|----|-------|-------|
| M-36 | TextPainter disposal | Both code paths already call `textPainter.dispose()` |

### Not Fixed (deferred)
| ID | Title | Reason |
|----|-------|--------|
| M-34 | Starred screen N+1 queries for tree preview | Low impact — queries parallelized via Future.wait |

### Items Still Open From All Rounds

| Item | Title | Round | Status |
|------|-------|-------|--------|
| I-38 / R-9 | `_transferPinToChild` bypasses TaskProvider | 9 | Open — future refactor |
| M-32 | N+1 queries in `deleteTaskAndReparentChildren` | 9 | Open — low impact |
| M-34 | Starred screen N+1 queries for tree preview | 10 | Deferred — low impact |
| ~~M-38~~ | ~~`deleteTaskSubtree` missing schedule sync entries~~ | 10 | **Fixed** — CR-fix M-38 at `database_helper.dart:2210-2221` |

**Resolved in Round 10 Verification (previously listed as open):**
- M-15: Refresh token now in `flutter_secure_storage` (auth_service.dart:6,54,345-349)
- M-26: `provider.loadRootTasks()` at backup_service.dart:110 refreshes Today's 5

---
---

## Round 11 (2026-07-06)

Full codebase review after **78 commits** since Round 10 (1.2.15 → 1.3.9). Major
new/changed surface: the delta-sync overhaul (cursor-skew lookback, throttled
full-pull-on-open, periodic full pull), Today's-5 pin **LWW** with central
timestamp + suppression tombstones, soft-delete tombstones for
relationships/dependencies/schedules, the manual Today's-5 model rewrite
(`todays_five_screen.dart` largely rewritten, random algo removed), the shared
`AddTaskFlow` extraction, and the **create-task-from-search** feature that
unified the two task pickers.

Reviewed via five parallel subagents (sync layer, Today's-5 screen, picker/add
flow, provider/database, starred/task-list screens); every Important finding
below was then re-verified by hand against the current code. `flutter analyze`
is clean (no issues).

---

### Previous Round Verification

- [x] **I-38 / R-9**: `_transferPinToChild` bypasses TaskProvider — **NOW OBSOLETE.** The method no longer exists anywhere in `lib/` (`grep` returns nothing). Pin auto-transfer was removed with the manual Today's-5 model; the parent simply drops out of Today's 5 when it gains a subtask. Item closed.
- [ ] **M-32**: N+1 in `deleteTaskAndReparentChildren` — still present (`database_helper.dart:2028`). Still open, low impact.
- [ ] **M-34**: Starred N+1 for tree preview — still present. Still deferred, low impact.
- [x] Round 10 fixes (I-42…I-47, M-35, M-37, CR-17) spot-checked — all still in place.

---

### Critical

None. No compile errors (`flutter analyze` clean), no single-device data-loss bugs found. The most severe items this round are cross-device sync-correctness bugs (below), which are Important rather than Critical because they require multi-device use and don't corrupt the local DB.

---

### Important

#### I-48. Today's-5 LWW pushes push-time `now()` instead of the persisted-at stamp — cross-device last-write-wins can invert
**Files:** `lib/services/sync_service.dart:216-217, 360-361, 465-466` (push side) vs `:711-712` + `lib/data/database_helper.dart:2893` (pull side)

`saveTodaysFiveState` stamps `prefsKeyTodaysFivePersistedAt = now()` on **every**
local save (edit time), and `pull()` reads that value as `localPersistedAt`,
gating the merge on `remoteUpdatedAt >= localPersistedAt`
(`upsertTodaysFiveFromRemote`, `remoteIsNewer` at `database_helper.dart:2893`).
But all three `pushTodaysFive` sites send
`DateTime.now().millisecondsSinceEpoch` — the **push** time, *after* the 5s
debounce — as the remote `updated_at`. The two sides therefore compare against
different clock references (edit-time locally, push-time remotely). The code
comment at `database_helper.dart:2684-2695` shows the persisted-at stamp was
deliberately centralised *for exactly this LWW comparison* — but push never uses it.

**Failure scenario:** Device A edits Today's 5 at T=0 but its push is delayed
(slow network) to T=10s → remote `updated_at=10000`. Device B edits (newer) at
T=2s (`persistedAt=2000`), pushes at T=7s. B later pulls A's doc:
`remoteUpdatedAt=10000 >= localPersistedAt=2000` → A's **older** edit wins and
B's newer curation is silently discarded (and B's deadline suppressions cleared
via `unsuppressDeadlineAutoPin`). Any time push order ≠ edit order (variable
latency, debounce coalescing), LWW inverts.

**Recommended fix:** In each push site read
`prefs.getInt(DatabaseHelper.prefsKeyTodaysFivePersistedAt)` and pass **that** as
the `updatedAt` argument to `pushTodaysFive`, so remote `updated_at` and local
`localPersistedAt` share the same clock basis.

---

#### I-49. Task hard-deletions never propagate to other devices — deleted tasks resurrect as orphans
**Files:** `lib/services/firestore_service.dart:166-173` (`deleteTask`), `lib/services/sync_service.dart:541-552` (pull tasks), `lib/data/database_helper.dart` (`upsertFromRemote`, insert/update only)

Relationships, dependencies and schedules all use soft-delete tombstones
(`deleted_at`) + full-pull reconciliation that removes local rows absent from
remote. **Tasks do not.** `deleteTask` issues a hard Firestore `DELETE`
(`firestore_service.dart:168`); there is no `deleted_at` on task docs;
`upsertFromRemote` only inserts/updates; and the task section of `pull()`
(`sync_service.dart:541-552`) — even on a full pull — never deletes local tasks
that are absent from remote.

**Failure scenario:** User deletes task X on the phone (hard-deleted in Firestore;
its relationships tombstoned). Laptop pulls: the relationship tombstones detach
X's edges, but the X **row** is never removed, so X survives forever as an
orphaned root task. If the user later edits X on the laptop it is re-pushed,
fully **resurrecting** the "deleted" task on every device. Deletion is not durable.

**Recommended fix:** Give tasks the same tombstone treatment as
relationships/deps (soft-delete `deleted_at`, delta picks it up, full-pull
reconciles), **or** add a full-pull step that deletes local tasks whose
`sync_id` is not in the remote set (guarding pending local adds, exactly as the
relationship/dependency branches already do at `sync_service.dart:560+`).

---

#### I-50. Bulk sync operations run outside the `_syncing` mutex — race with debounced push / periodic pull
**File:** `lib/services/sync_service.dart:167` (`initialMigration`), `:231` (`replaceLocalWithCloud`), `:298` (`replaceCloudWithLocal`), `:378` (`mergeBoth`)

Only `push()` (`:386-390`) and `pull()` (`:496-501`) check/set `_syncing`. The
four bulk operations never acquire it, and they don't pause the 5s debounce
timer or the 5-minute periodic-pull timer. So a `schedulePush()` or the periodic
`pull()` can run **concurrently** with them.

**Failure scenario:** User taps "Replace local with cloud".
`replaceLocalWithCloud` calls `deleteAllLocalData()` (`:245`) then re-inserts from
remote over several seconds. Mid-way the periodic-pull timer fires; `pull()` sees
`_syncing == false`, runs against the half-wiped DB, upserts a partial task set
and advances `_prefsKeyLastSyncAt`. Result: interleaved, inconsistent local
state plus a corrupted delta cursor. Same hazard for a debounced `push()`
draining the sync queue concurrently with `initialMigration`'s own drain
(`drainSyncQueue` + `markTasksSynced` running twice).

**Recommended fix:** Have all four methods participate in the same guard (set
`_syncing = true` for their duration, honour `_pushPending`/`_pullPending` in a
`finally`), or serialize every sync entry point through one mutex.

---

#### I-51. Uncompleting an *externally* "Done today" task doesn't revert the DB worked-on flag — task bounces back to "done"
**File:** `lib/screens/todays_five_screen.dart:667-685` (`_handleUncomplete`), detection at `:200-202` and `:306-309`

`_handleUncomplete` branches on `wasWorkedOn = _workedOnIds.contains(task.id)`
and `task.isCompleted`. But when a task is marked "Done today" **outside** the
Today's-5 screen (e.g. All Tasks leaf detail → `markWorkedOn`), the load/refresh
paths add it to `_completedIds` only (`:200-202`, `:306-309`), **never** to
`_workedOnIds`. So for such a task `wasWorkedOn == false` and `isCompleted ==
false` → **both revert branches are skipped**, yet `_unmarkDone` still strips it
from `_completedIds` locally.

**Failure scenario:**
1. Task X pinned in Today's 5. From All Tasks leaf detail, mark X "Done today"
   (`lastWorkedAt = today` in DB).
2. Switch to Today tab → `refreshSnapshots` sees `isWorkedOnToday`, adds X to
   `_completedIds` only. X renders done.
3. Tap X in Today's 5 to undo. Neither branch fires; X leaves the done section
   and `_explicitlyUncompletedIds` suppresses re-detection **for the session**.
4. **Wrong outcome:** DB still has `lastWorkedAt = today`. On app restart, a
   cross-device sync, or a real `_reloadFromDb`, X reappears as done. Snackbar
   said "restored," but UI and DB diverged. (Same *class* as the Round 4 I-14
   fix, but for the externally-worked-on case, which the session sets don't track.)

**Recommended fix:** Detect worked-on from the DB snapshot, not just the session
set — e.g. `final wasWorkedOn = _workedOnIds.contains(task.id) ||
task.isWorkedOnToday;` and run `unmarkWorkedOn` whenever `task.isWorkedOnToday &&
!task.isCompleted`, even when `_workedOnIds` didn't have it. When the pre-worked
timestamp is unknown (external mark), `restoreTo` may be null — acceptable, and
the task correctly leaves the done state permanently.

---

#### I-52. `getEffectiveDeadlines` fires one recursive-CTE query per task on the refresh hot path (N+1)
**File:** `lib/data/database_helper.dart:1188-1213`

`_loadAuxiliaryData()` (`task_provider.dart:868`) calls `getEffectiveDeadlines`
on **every** `_refreshCurrentList()` — i.e. after every mutation. Tasks lacking
their own deadline fall into a per-task loop (`:1191`), each iteration running a
full recursive ancestor CTE (`:1192-1205`).

**Failure scenario:** Open a root category with 50 children and no deadlines
anywhere. The initial batch query fills nothing, so `remaining` = all 50 IDs,
firing 50 separate recursive walks. Every star/rename/priority/worked-on toggle
triggers a refresh → ~50 recursive CTE walks per tap. On mobile SQLite this is
visibly janky and scales with tree size.

**Recommended fix:** Collapse the loop into one batched recursive CTE keyed by
target id — the same pattern the file already uses in `getRootAncestorsForLeaves`
(`:722`) and `getEffectiveScheduledTodayIds` (`:3258`): walk all remaining ids in
a single `WITH RECURSIVE target_ancestors(target_id, ancestor_id)` and pick the
nearest deadline per `target_id`.

---

#### I-53. Starred DRY-rule violation — grandchildren in the tree-preview card get none of the priority/blocked styling the expanded dialog applies
**File:** `lib/screens/starred_screen.dart:664-669` (grandchild render), `:130` / `:149` (blocked-info fetch scope)

The project's "Starred view DRY rule" (see CLAUDE.md) requires any visual
treatment to apply to **both** the tree-preview card and the expanded dialog via
a shared helper (`childTextStyle`). It holds for children (card `:644-650`,
dialog `:1302-1308`) but **not** grandchildren: the card renders grandchildren
with a hardcoded `TextStyle(fontSize: 13, color: grandchildColor)` (`:666`),
never calling `childTextStyle`, while the dialog's `_ExpandedTreeRow` applies
`childTextStyle` at every depth (`:1302`). Worse, `_loadStarredTasks` only adds
**direct** child IDs to `allChildIds` (`:130`), so the `_blockedInfo` map fed to
the card (`:149`) can't even cover grandchildren.

**Failure scenario:** A high-priority grandchild shows accent-tinted in the
expanded dialog but plain grey in the card; a blocked grandchild is dimmed in the
dialog but full-emphasis in the card — contradictory cues for the same task
depending on the surface.

**Recommended fix:** Route the grandchild `Text` at `:666` through
`childTextStyle(task: gc, baseColor: grandchildColor, accent: accent, fontSize:
13, isBlocked: …)`, and include grandchild IDs in the `allChildIds` /
`getBlockedTaskInfo` fetch (`:130`, `:149`) so `_blockedInfo` covers them.

---

### Minor

#### M-39. Empty Today's-5 state is never pushed (defensive gap only)
**File:** `lib/services/sync_service.dart:462` (also `:213`, `:357`), pull guard `:709-710`

Push writes the Today's-5 doc only `if (todaysFiveEntries.isNotEmpty ||
suppressedSyncIds.isNotEmpty)`, and pull ignores an empty remote doc. In
isolation this could strand a "cleared" state. **Largely mitigated:** every
removal path records a suppression tombstone (`todays_five_screen.dart:544`,
`task_list_screen.dart:207`), so a cleared state always carries non-empty
`suppressedSyncIds` and *is* pushed/pulled. Reaching empty-with-no-suppressions
requires never having removed anything (nothing to propagate). Worth a defensive
"always push the doc" for robustness, but not an active bug.

#### M-40. Pull cycle counter advances (and persists) before the pull succeeds
**File:** `lib/services/sync_service.dart:523-524`

`_prefsKeyPullCycleCount` is incremented and written *before* the pull work; a
throwing pull still advances it. Repeated failures can "use up" the every-10th
full-reconciliation backstop, delaying it. Increment/persist only on the success
path (near the `_prefsKeyLastSyncAt` write at `:726`).

#### M-41. `_skipNextPeriodicPull` can hide concurrent remote changes
**File:** `lib/services/sync_service.dart:470-472`, consumed at `:98-101`

After a push the next periodic pull is skipped ("remote matches local"), but
that's only true for what *this* device pushed — changes made on another device
between our last pull and this push aren't fetched until the following cycle (up
to ~10 min latency). Low impact given the 5-min interval; the comment overstates
the invariant.

#### M-42. `cleanupTombstones` batch deletes ignore HTTP status
**File:** `lib/services/firestore_service.dart:934-941`

The chunked delete `_post` results are never checked, so a failed tombstone
purge is invisible. It's explicitly best-effort (documented `:918`), so not a
data bug — but a `debugLog` on non-200 would aid diagnosis.

#### M-43. Today's-5 remove/uncomplete flows orphan session-state sets
**File:** `lib/screens/todays_five_screen.dart:544-552` (and `_handleUncomplete`)

`_confirmRemoveFromTodaysFive` updates `_todaysTasks`/`_completedIds`/
`_workedOnIds` but not the parallel `_autoStartedIds`, `_preWorkedOnLastWorkedAt`,
`_explicitlyUncompletedIds`. Self-heals on the next `_reloadFromDb` (which clears
them), so it's a slow leak / latent risk, not an active bug. Drop the removed
task's id from those sets in the same `setState`.

#### M-44. No reentrancy guard on `refreshSnapshots`; listeners fire it unawaited
**File:** `lib/screens/todays_five_screen.dart:88-102, 236-338`

`_onProviderChanged` / `_onSyncStatusChanged` invoke `refreshSnapshots()`
fire-and-forget, and multi-step flows like `_workedOnTask` issue several
un-deferred provider mutations (`:592-596`), each re-entering `refreshSnapshots`
mid-flow. Two overlapping runs can interleave reads/writes of `_todaysTasks` /
`_completedIds`. Benign today (the id set doesn't change), but fragile. Add a
`bool _refreshing` coalescing guard, and/or batch `_workedOnTask` with
`deferNotify` as `_handleCreateNewForToday` already does.

#### M-45. `addRelationship` lacks a conflict algorithm — latent UNIQUE-constraint throw
**File:** `lib/data/database_helper.dart:571-595`

`txn.insert('task_relationships', …)` uses the default `abort`, so re-inserting
an existing `(parent_id, child_id)` edge throws. The two provider callers
(`linkChildToCurrent`, `addParentToTask`) only run the `hasPath` cycle check
(false for an already-existing edge). **Not currently reachable:** both pickers
exclude existing edges at the UI layer (`task_list_screen.dart:465-471`,
`:503-511`). But the guard is missing inside the method (inconsistent with
`moveTask`/`fileTask`, which pre-check), a latent crash for any future caller.
Add `ConflictAlgorithm.ignore` (and skip the sync-queue enqueue when nothing was
inserted).

#### M-46. `completeTask`/`skipTask`/`markWorkedOnAndNavigateBack` skip refresh when the nav stack is empty
**File:** `lib/providers/task_provider.dart:306-308, 319-321, 797-798`

These deliberately do `onMutation?.call(); await navigateBack();` instead of
`_refreshAfterMutation()`, relying on `navigateBack()` to refresh. But
`navigateBack()` returns `false` **without refreshing** when `_parentStack`
is empty (`:78-83`). In that case the DB mutation + sync push already fired but
no `notifyListeners()` runs → stale UI. Latent (these are called from leaf detail
where the stack is non-empty), but the "every mutator must refresh" invariant is
violated on the empty-stack branch. Fall back to `_refreshAfterMutation()` when
`navigateBack()` returns `false`.

#### M-47. Triage search recomputes over all tasks in `build()` with no debounce
**File:** `lib/widgets/triage_dialog.dart:182-185` (`_filteredSearch` getter), used at `:331`; `onChanged` at `:226-229`

Unlike the sibling picker (which caches into `_searchResults` and debounces
200ms — `task_picker_dialog.dart:217, 467-481`), triage's `_filteredSearch` is a
getter that re-runs `filterTasksBySearch` over **all** tasks inside `build()` on
every keystroke *and* every unrelated rebuild. With a few thousand tasks this
causes visible input lag. Cache into a field and add the same debounce.

#### M-48. Flat-mode "Create" can create a stale name during the debounce window
**File:** `lib/widgets/task_picker_dialog.dart:402-408` (`query: _filter`), debounce `:467-481`

The debounce special-cases only the *emptied* field. On append, `_filter` lags
the visible text up to 200ms, and the Create empty-state uses `_filter` (`:406`).
Type "Buy milk", correct to "Buy milkshake", tap Create within 200ms → a task
named "Buy milk" is created. Source the created name from the live controller
text (or flush the debounce before invoking `onCreateTask`).

#### M-49. `brain_dump_dialog` adds a controller listener without a matching `removeListener`
**File:** `lib/widgets/brain_dump_dialog.dart:33` vs `dispose()` `:60-63`

Not a leak in practice (the controller is disposed, tearing down its listeners),
but the add-without-remove asymmetry is a foot-gun if the controller is ever
injected/externalised. Low priority.

#### M-50. Dead `highlight` field on `_TreeRow` — set for children, never read
**File:** `lib/screens/starred_screen.dart:720, 728, 641`

`_TreeRow.highlight` is declared and passed (`highlight: item.child.isHighPriority`
at `:641`) but `build()` (`:736-761`) never reads it — the real highlight lives in
`childTextStyle`'s colour. It's also not passed for grandchildren, reinforcing
I-53's asymmetry. Delete the field + the `:641` argument (or wire it).

#### M-51. Starred `onUnstar` + undo are fire-and-forget — DB errors silently swallowed
**File:** `lib/screens/starred_screen.dart:182, 185-186`

`provider.updateTaskStarred(task.id!, false)` (and the undo closure) are called
without `await` — same class as the already-fixed reorder (CR-fix M-35, now
awaited at `:202-210`). If the write throws, the exception escapes to
`FlutterError.onError` while the snackbar still claims "Unstarred". Low severity
(the list self-corrects on the next provider reload), but the message can lie.
Make them `async` and await / try-catch.

#### M-52. CLAUDE.md DB-version doc drift
**File:** `CLAUDE.md:34`

CLAUDE.md says "currently at v22" but `_dbVersion = 23`
(`database_helper.dart:381`). Doc-only drift (a `todays_five_deadline_suppressed`
table was correctly added in a new v23 migration). Bump the doc note. (UI docs —
`docs/UI_VIEWS.md` — were checked and are up to date: create-from-search,
"Pin for today", and the actions-bar toggle folding are all documented.)

---

### Refactoring

#### R-10. `addTask` task insert + relationship inserts are not atomic
**File:** `lib/providers/task_provider.dart:182-199`

`insertTask()` runs in its own txn, then each parent edge is added via a
**separate** `addRelationship()` txn. Relationship+sync_queue is atomic per edge,
but the task row and its edges are not one unit — a crash between them leaves an
orphan root or partially-parented task. `insertTasksBatch`
(`database_helper.dart:533`) already does task + edges + sync_queue in a single
transaction; route the multi-parent path through the same pattern.

#### R-11. Triplicated structured-query + full-pull reconciliation across sync entity types
**Files:** `lib/services/firestore_service.dart` — `_queryTasksUpdatedSince` (`:697`), `pullRelationshipsSince` (`:280`), `pullDependenciesSince` (`:359`), `pullSchedulesSince` (`:500`); `lib/services/sync_service.dart` reconcile blocks for relationships (`:555-607`), dependencies (`:609-656`), schedules (`:658-704`)

The three per-entity delta/full-pull-with-deletion-reconciliation blocks are
structurally identical (delta+tombstone vs full+set-diff, both guarded by
`getPendingSyncAddKeys`), as are the four `updated_at > lastSyncAt` runQuery
helpers. Extract a generic `queryUpdatedSince(collectionId, parser)` and a
generic reconcile helper parameterized by key/upsert/remove callbacks (~150 lines
removed, eliminates drift risk between the copies).

#### R-12. Browse-tree state machine fully duplicated between the two "unified" pickers
**Files:** `lib/widgets/task_picker_dialog.dart:91-95, 152-192, 268-335` and `lib/widgets/triage_dialog.dart:44-48, 112-160, 360-439`

The picker unification only extracted the *leaf* widgets into
`task_picker_parts.dart`. The entire browse-tree engine (`_browseStack`,
`_browseChildren`, `_loadBrowseChildren`, `_browseInto`/`_browseBack`, the
`clamp(0,6)` truncation, "Show all N items", `_buildBrowseTree`) is copy-pasted
(~140 near-identical lines) into both dialog states, and has already drifted
(M-47 vs the debounce/cache in the pin picker). Extract a shared
`PickerBrowseTree` widget parameterized by the per-picker tap behavior.

---

## Round 11 Fix (2026-07-07)

All 6 Important and all 14 Minor findings fixed. R-10 done; R-11 and R-12
deferred (see below). `flutter analyze` clean; full `flutter test` green.

### Fixed in This Round

| ID | Title | Notes |
|----|-------|-------|
| I-48 | Today's-5 LWW clock-basis mismatch | Extracted shared `_pushTodaysFiveState`; pushes `prefsKeyTodaysFivePersistedAt` (edit-time) as remote `updated_at`. |
| I-49 | Task hard-deletes don't propagate | **Deviation from framing:** implemented **Firestore-only tombstones** (mirroring relationships/deps/schedules) — `deleteTask` now `_softDelete`s; new `pullTaskDeltasSince` surfaces tombstones; delta + full-pull reconciliation in `pull()`; `_listAllTasks` skips tombstones; `tasks` added to `cleanupTombstones`. **No local `deleted_at` column / v24 migration was needed** — local deletes stay hard-deletes exactly like the other entity types, so a local column would be dead schema. Achieves the delta-immediate propagation the "tombstones" option was chosen for. 4 regression tests. |
| I-50 | Bulk sync ops outside `_syncing` | `initialMigration`/`replaceLocalWithCloud`/`replaceCloudWithLocal` now run under `_runExclusive` (acquires `_syncing`, drains pending push/pull in `finally`). `mergeBoth` composes two guarded ops. |
| I-51 | External "Done today" undo doesn't revert DB | `_handleUncomplete` now detects worked-on from `task.isWorkedOnToday`, not just the session set. Regression test added. |
| I-52 | `getEffectiveDeadlines` N+1 | Per-task ancestor CTE collapsed into one batched `WITH RECURSIVE target_ancestors` per 500-id chunk. Nearest-ancestor regression test added. |
| I-53 | Starred grandchild DRY-rule violation | Grandchild card text routed through `childTextStyle`; grandchild ids included in `_blockedInfo` fetch. Regression test added. |
| M-40 | Pull-cycle counter advances before success | Counter persisted only on the success path. |
| M-42 | `cleanupTombstones` ignores HTTP status | Non-200 batch deletes now `debugLog`ged. |
| M-43 | Remove flow orphans session sets | `_confirmRemoveFromTodaysFive` now also clears `_autoStartedIds`/`_preWorkedOnLastWorkedAt`/`_explicitlyUncompletedIds`. |
| M-44 | No reentrancy guard on `refreshSnapshots` | Added `_refreshing`/`_refreshPending` coalescing guard. **Partial:** the optional `deferNotify` batching of `_workedOnTask` was **not** done — `deferNotify` only exists on `addTask`; threading it through `markWorkedOn`/`startTask`/`updateTaskDeadline` is out of scope for a Minor. |
| M-45 | `addRelationship` UNIQUE-throw | `ConflictAlgorithm.ignore` + skip the sync enqueue when nothing inserted. |
| M-46 | Mutators skip refresh on empty nav stack | `completeTask`/`skipTask`/`markWorkedOnAndNavigateBack` fall back to `_refreshCurrentList()` when `navigateBack()` returns false. |
| M-47 | Triage search recomputes in `build()` | Cached into `_searchResults`, recomputed per keystroke. **Deviation:** no `Timer` debounce — the true sibling (pin picker browse-mode) also caches without one, and a FakeAsync debounce timer would break existing triage tests under `pumpAsync`. |
| M-48 | Flat-mode Create stale name | Create now reads the live controller text (added `_flatController`). Regression test added. |
| M-49 | `brain_dump_dialog` add-without-remove listener | Matching `removeListener` in `dispose()`. |
| M-50 | Dead `highlight` field on `_TreeRow` | Field + `:641` argument deleted. |
| M-51 | Starred `onUnstar`/undo fire-and-forget | Now `async` + awaited with try-catch; success snackbar suppressed on failure. |
| M-52 | CLAUDE.md DB-version drift | Doc note bumped v22 → v23. |
| R-10 | `addTask` insert not atomic | New `insertTaskWithParents` inserts task + all edges + sync-queue in one transaction; `addTask` routed through it. |

### Not a Code Change (analyzed)

| ID | Title | Decision |
|----|-------|----------|
| M-39 | Empty Today's-5 state never pushed | **No-op by design.** Pull ignores an empty remote doc (`sync_service.dart` pull guard), so "always push the doc" would be inert write-spam. The only stranded case (empty-with-no-suppressions) requires never having removed anything → nothing to propagate. Every real removal records a suppression tombstone and IS pushed/pulled. Left as-is. |
| M-41 | `_skipNextPeriodicPull` overstates invariant | Comment corrected (skip is valid only for what *this* device pushed; cross-device changes wait for the next cycle). |

### Deferred (recommend as focused follow-up PRs)

| ID | Title | Reason |
|----|-------|--------|
| R-11 | Dedup structured-query + full-pull reconciliation across entity types | Pure refactor of prod-critical sync code that just went through multiple prod-bug rounds. The query/reconcile methods are mocked in tests (not directly unit-tested), so a subtle regression wouldn't be caught by the suite. Per-entity divergence (composite vs single-key, cycle-check vs not, heterogeneous return types) makes a generic reconcile helper a thin scaffold with a large callback surface — high risk, zero functional benefit. Adding tasks (I-49) raised both the value and the surface; best done as its own PR with dedicated coverage. |
| R-12 | Browse-tree state machine duplicated between the two pickers | Only the nav state machine + clamp/"Show all" scaffold are identical; tap semantics, header, root prefix, sort, child filter, row icons, and empty text all diverge. A faithful `PickerBrowseTree` would need injected builders for nearly every part — thin scaffold, large config surface, high drift risk for little real dedup. |

### Previously Open (rechecked)

| ID | Title | Status |
|----|-------|--------|
| M-32 | N+1 in `deleteTaskAndReparentChildren` | Still open — low impact, not in this round's scope. |
| M-34 | Starred N+1 for tree preview | Still open — low impact. |

---

## Round 11 Fix Verification (2026-07-07)

Independent verify pass over the Round 11 fix commit (`d499ee5`). Each fix was
read against the current code and checked for **root-cause** correctness (not just
symptom), plus regression risk. `flutter analyze` **clean**; `flutter test`
**green (+1457 passing, 1 skipped, 0 failures)**.

### Important — all CONFIRMED

- **I-48** ✓ — `_pushTodaysFiveState` (`sync_service.dart:97-108`) reads `prefsKeyTodaysFivePersistedAt` (edit-time) and sends it as the remote `updated_at`, matching the pull-side comparison basis (`:792`). Extraction also DRYs the three former push sites. Root cause fixed.
- **I-49** ✓ — Firestore-only tombstone approach verified end-to-end and **sound**: `deleteTask` now `_softDelete`s (`firestore_service.dart:166-173`); `_listAllTasks` skips tombstones (`:688-697`); `pullTaskDeltasSince` reports `deleted:true` (`:749-750`); `pull()` applies delta tombstones **guarding pending local adds** via `getPendingTaskSyncIds` (`sync_service.dart:594-600`) and reconciles on full pull against the remote live set with the same guard (`:620-628`); `tasks` added to `cleanupTombstones` (`:776`). No local `deleted_at` column needed — local deletes stay hard like the other entity types. The I-50 mutex additionally removes the push/pull TOCTOU. New DB helpers (`deleteTaskBySyncId`, `getPendingTaskSyncIds`, `getAllTaskSyncIds`) present; 4 regression tests.
- **I-50** ✓ — `_runExclusive` (`sync_service.dart:119-140`) acquires `_syncing` and drains `_pushPending`/`_pullPending` in `finally`; `initialMigration`/`replaceLocalWithCloud`/`replaceCloudWithLocal` route through it (`:230,283,352`); `mergeBoth` composes two guarded ops. Concurrent push/pull now defer. Bounded 5s wait is a pragmatic anti-deadlock backstop (bulk ops rare/user-initiated) — acceptable.
- **I-51** ✓ — `_handleUncomplete` detects worked-on from `task.isWorkedOnToday` (DB snapshot) not just `_workedOnIds` (`todays_five_screen.dart:707-715`); external "Done today" now clears `lastWorkedAt`. `restoreTo` null-safe. Regression test added.
- **I-52** ✓ — per-task ancestor CTE collapsed into one batched `WITH RECURSIVE target_ancestors` per 500-id chunk, keyed per target, `ORDER BY target_id, depth ASC` + first-wins keeps the nearest deadline (`database_helper.dart:1260-1285`). Semantically equivalent to the old `LIMIT 1`; no target/deadline cross-contamination.
- **I-53** ✓ — both parts: grandchild card text routed through `childTextStyle` (`starred_screen.dart:685`) and grandchild ids included in the blocked-info fetch (`:141,154`).

### Minor — CONFIRMED (with two accepted deviations)

- **M-40** ✓ (counter persisted only on success, `:813`), **M-42** ✓ (`debugLog` on non-200 batch delete, `firestore_service.dart:1009`), **M-43** ✓ (session sets cleared on remove), **M-45** ✓ (`ConflictAlgorithm.ignore` + skip enqueue when 0 inserted), **M-46** ✓ (fallback `_refreshCurrentList()` when `navigateBack()` returns false), **M-47** ✓ (triage search cached into `_searchResults`, out of `build()`), **M-48** ✓ (Create reads live `_flatController` text), **M-49** ✓ (matching `removeListener`), **M-50** ✓ (dead `highlight` field removed), **M-51** ✓ (unstar/undo async+awaited, snackbar suppressed on failure), **M-52** ✓ (CLAUDE.md bumped to v23).
- **M-41** — comment-only correction (skip-invariant reworded). Accepted.
- **M-39** — **No-op by design**, verified sound: every real removal records a suppression tombstone (so the doc IS pushed/pulled); the only stranded case is empty-with-no-suppressions, which has nothing to propagate.
- **M-44** — guard CONFIRMED (`_refreshing`/`_refreshPending` coalesces to exactly one trailing re-run). The `deferNotify` batching of `_workedOnTask` was **not** done — accepted as out-of-scope for a Minor.

### Refactoring

- **R-10** ✓ — `insertTaskWithParents` (`database_helper.dart:579-621`) inserts task + all edges + sync-queue in one transaction; `addTask` routes through it (`task_provider.dart:193-204`), multi-parent edges included, duplicate parents de-duped. Cycle check correctly omitted for a brand-new task.
- **R-11 / R-12** — Deferred. Rationale reviewed and accepted (high-risk refactor of prod-critical sync code with mock-only coverage; picker browse-trees diverge in tap semantics/header/sort/filter — a shared widget would be thin scaffold + large config surface). Recommend as focused follow-up PRs, not merge blockers.

### Still open (acceptable / deferred)

- **M-32**, **M-34** — genuinely still open (rechecked); low impact, not silently fixed. I-53's grandchild-id addition to the blocked-info fetch does **not** touch M-34's separate children/grandchildren load path.
- **I-38 / R-9** — obsolete (method removed with the manual model).

**No regressions or new bugs introduced by the fixes.**

**Merge verdict: This branch is ready to merge into main.** All 6 Important, all
14 Minor, and R-10 are verified fixed at the root cause; the two deferred
refactors (R-11/R-12) and two low-impact open items (M-32/M-34) are acceptable to
carry forward. Analyze clean, full test suite green.

---

## Round 11 — Suggested Implementation Order

1. **I-49** — Task-delete tombstone/reconciliation (highest-impact: silent resurrection of deleted tasks).
2. **I-48** — Push the persisted-at stamp as Today's-5 `updated_at` (fixes LWW inversion; small, same file cluster as I-49).
3. **I-51** — Detect external worked-on in `_handleUncomplete` (fixes "bounces back to done").
4. **I-50** — Bring the four bulk sync ops under `_syncing` (concurrency).
5. **I-52** — Batch the `getEffectiveDeadlines` ancestor CTE (hot-path jank).
6. **I-53** — Route grandchild styling through `childTextStyle` + include grandchildren in blocked fetch (DRY rule).
7. **Minor items** M-40…M-52 as time permits; M-46 and M-45 are cheap invariant hardening.
8. **Refactors** R-10 (atomicity — do with a fix), R-11/R-12 (dedup) when touching those files.

---

## Round 12 (2026-10-04)

Full codebase review after **43 commits** since Round 11 (1.3.10 → 1.4.5).
New or changed areas:
- the opt-in weighted Suggested section and "Also done today" on Today's 5
- "Go to task" in the Today's 5 options sheet
- search on the Starred and Today's 5 tabs (`task_search.dart`, `tab_app_bar_title.dart`)
- the "Did you mean" duplicate-task suggestion in `add_task_dialog.dart`
- `InboxToggleChip`, and the Inbox toggle carried over into "Add multiple"
- adding subtasks at any level and marking them done from the Starred tree (`done_actions.dart`)
- length caps on strings read from Firestore

`lib/data/` has no changes since Round 11.

Four parallel subagents reviewed the code: the Today's 5 screen, the Starred screen, the add/task-list/provider changes, and the rest of `lib/` plus UI docs drift. Every Important finding below was then re-checked by hand against the code. `flutter analyze` is clean.

---

### Previous Round Verification

- [x] Round 11 fixes are still in place: `_pushTodaysFiveState` and `_runExclusive` (`sync_service.dart:97,119`), the I-51 `isWorkedOnToday` check (`todays_five_screen.dart:883`), the batched `target_ancestors` CTE (`database_helper.dart:1261`), `insertTaskWithParents` (`:579`), the `_refreshing` flag that coalesces overlapping refreshes (`todays_five_screen.dart:56`), and CLAUDE.md at v23 (`_dbVersion = 23`).
- [x] **M-32** [FIXED in Round 12 fix]: N+1 in `deleteTaskAndReparentChildren` is still present (`database_helper.dart:2125-2139`). It runs one `txn.query` and one `txn.insert` per parent × child pair. Simpler fix than before: `insert(..., conflictAlgorithm: ConflictAlgorithm.ignore)` and check the returned row id, as `addRelationship` (`:633`) already does.
- [x] **M-34** [FIXED in Round 12 fix, with M-62]: Starred N+1 is still present and now runs more often (see M-62).
- R-11 / R-12 are still deferred.

---

### Critical

None. `flutter analyze` is clean, and no finding loses data on a single device.

---

### Important

#### I-54. Every successful sync reloads Today's 5, and the reload schedules another push — a signed-in device pushes about every 5 s while the app is open [FIXED in Round 12 fix]
**Files:** `lib/screens/todays_five_screen.dart:127-132` (`_onSyncStatusChanged`), `:263` and `:415-427` (`_persist`); `lib/services/sync_service.dart:198-200, 516, 522`

The loop:
1. `push()` finishes and calls `setSyncStatus(SyncStatus.synced)` (`sync_service.dart:516`).
2. `_onSyncStatusChanged` sees `synced` and calls `_reloadFromDb()`.
3. Whenever at least one task is in Today's 5, `_loadTodaysTasksInner` ends with `await _persist()` (`:263`).
4. `_persist()` calls `onTodaysFivePersisted()`, which calls `schedulePush()` (5 s debounce).
5. That push sets `synced` again, and the cycle repeats.

Consequences:
- Today's 5 is written to Firestore about every 5 s.
- Each push sets `_skipNextPeriodicPull = true` (`:522`), so the 5-minute periodic pull is always skipped. The device stops picking up other devices' edits until the app restarts.
- `saveTodaysFiveState` stamps `prefsKeyTodaysFivePersistedAt = now` on every save, and since I-48 that stamp is sent as the remote `updated_at`. An idle device therefore always looks newest and wins last-write-wins. It overwrites Today's 5 edits made on another device, which is what PR #72 was meant to prevent.

The listener is older than this round (March), but the I-48 fix made the last-write-wins effect much worse. I confirmed this by reading the code, not by running it. To check at runtime, add a `debugLog` in `push()` and leave the Today tab open with one task pinned.

**Recommended fix:** In `_onSyncStatusChanged`, reload only when a pull actually changed local data, for example via a "pull changed data" flag set by `SyncService`, not on every `synced`. Separately, make `_persist()` skip both the save and the push when the ids, completed set and worked-on set are the same as the last save.

---

#### I-55. "Add here" on an Inbox task lists it under the parent but leaves it in the Inbox [FIXED in Round 12 fix]
**Files:** `lib/screens/task_list_screen.dart:442`, `lib/screens/starred_screen.dart:1179`; `lib/providers/task_provider.dart:667` (`addParentToTask`)

Both "Did you mean → Add here" handlers call `provider.addParentToTask`, which only inserts the relationship. Filing an Inbox task normally goes through `fileTask` (`task_provider.dart:~1056`), which also calls `clearInboxFlag`. `getInboxTasks`/`getInboxCount` (`database_helper.dart:960-980`) filter on `is_inbox = 1` alone, so a task with a parent still counts as Inbox.

**Failure scenario:**
1. Brain-dump "Buy milk" into the Inbox.
2. Drill into "Groceries", tap +, type "buy milk".
3. Tap the match. The snackbar says `Added "Buy milk" here`.
4. "Buy milk" is now under Groceries, yet it is also still in the root Inbox section, and the Inbox count does not drop.

The duplicate suggestion makes this common, because re-typing an Inbox item you haven't filed yet is exactly the duplicate case. The older "Also show under" path (`task_list_screen.dart:605`) has the same gap.

The `_loadInboxCount()` calls at `task_list_screen.dart:450, 456` never run. `parentId != null` here, so `provider.isRoot` is false and `showInbox` is false.

**Recommended fix:** When `existing.isInbox`, call `provider.fileTask(existing.id!, parentId)` and undo with `unfileTask`, which restores the flag. Otherwise keep `addParentToTask`/`removeParentFromTask`. Do this in one shared helper (R-14). Drop the `_loadInboxCount` calls that never run.

---

#### I-56. Flare at root sometimes does nothing when it picks an Inbox task [FIXED in Round 12 fix]
**Files:** `lib/providers/task_provider.dart:447-455` (`pickRandom`), `lib/screens/task_list_screen.dart:942-947` (`_showSpotlight`), `lib/data/database_helper.dart:657` (`getRootTasks`)

At root, `_tasks` comes from `getRootTasks`, which includes Inbox tasks, and `pickRandom` draws from `_tasks`. `_showSpotlight` then looks the pick up in `gridTasks`. When `_inboxCount > 0`, `gridTasks` excludes Inbox tasks, so the lookup returns `index == -1` and the method returns with no feedback.

**Failure scenario:** At root with three Inbox tasks and two filed tasks, tap Flare a few times. Some taps do nothing: no spotlight, no snackbar, no dialog.

`docs/UI_VIEWS.md:60` says a "Lucky Pick" dialog appears as a fallback. That dialog (`RandomResultDialog`) has had no caller in `lib/` since b18ceab (see R-16).

**Recommended fix:** In `pickRandom`, exclude `isInbox` tasks when `isRoot`. Then either delete the fallback line from `UI_VIEWS.md` or wire `RandomResultDialog` in for `index == -1`.

---

#### I-57. A "Done for good!" row in the Starred dialog can still be opened, which lets you add a subtask under an archived task [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:1463` and `:1705`

A leaf row's body tap is `onToggleExpand ?? onNavigate`. A leaf has no `onToggleExpand`, so the tap always navigates, whatever `doneChoice` is. `navigateToTask` (`task_provider.dart:877`) re-reads the task, completed or not.

**Failure scenario:**
1. In the Starred dialog, mark leaf L "Done for good!".
2. Tap L's struck-through name.
3. The dialog closes, and All Tasks opens L's leaf detail with its add button and an active "Done for good!" button.
4. Add a subtask there. It sits under an archived parent and appears nowhere in All Tasks. This is the Codex P1 case that removing the row's "+" (`:1781-1785`) was meant to close.
5. Closing the dialog also loses the row's in-session undo.

**Recommended fix:** When `doneChoice == DoneChoice.forGood`, make the row body do nothing, or make it undo, like the circle does.

---

#### I-58. Starred dialog: after a reload, a second "Done today" works from the task as it was after the first mark, so its undo leaves the task worked on today [FIXED in Round 12 fix]
**Files:** `lib/screens/starred_screen.dart:994-1029` (`_fetchChildren`), `lib/widgets/done_actions.dart:59-60` (`markTaskDoneToday`)

`markTaskDoneToday` records `previousLastWorkedAt` and `wasStarted` from the `Task` it is passed. A "Done today" task keeps `completed_at` NULL, so the reload that follows any add (`_reloadAfterAdd`) replaces the row's cached `Task` with the copy read after the mark: `lastWorkedAt` = today, `startedAt` set, deadline possibly cleared. Undoing the mark does not refresh that cache.

**Failure scenario:**
1. Mark leaf L "Done today".
2. Add a task anywhere in the tree with "+", which reloads every cached level.
3. Tap L's circle to undo. The database is restored correctly.
4. Mark L "Done today" again. It skips the auto-start because `wasStarted` is true, and skips the deadline prompt.
5. Undo. `last_worked_at` is set back to step 1's timestamp, so L stays "worked on today" although every action was undone.

**Recommended fix:** In `markTaskDoneToday` (and `completeTaskForGood`), re-read the task from the database before recording the values the undo restores. This needs a public `TaskProvider.getTaskById`. Alternatively, have `_onDoneChanged(false)` re-read the task into every `_childrenCache` entry.

---

#### I-59. Starred dialog: a parent whose only child was done for good turns into a leaf after a reload, and undoing the child then leaves it active under an archived parent [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:1018-1028` (child count), `:1040-1056` (re-inserting done rows)

A reload puts the done child back into its parent's list. However, the parent's `childCount` comes from `getChildren`, which excludes completed tasks, so the count drops to 0 and the parent is treated as a leaf.

**Failure scenario:**
1. Expand A, whose only child is leaf B.
2. Mark B "Done for good!".
3. Add a subtask under any other row, which reloads every cached level.
4. A now draws as a leaf: done circle, no chevron, no way to collapse, while B is still shown indented under it.
5. Mark A "Done for good!", then tap B's circle to undo.
6. `uncompleteTask(B)` makes B active under an archived A, so B appears nowhere in All Tasks (the same invisible-task case as I-57).

The Completed screen handles the archived-parent case with `getArchivedParents`/`removeArchivedParentLinks`; this undo path does not.

**Recommended fix:** In `_addVisibleNodes`, treat a node as a branch while its `_childrenCache` entry is non-empty, or count the re-inserted done rows in the parent's `childCount`. Also check for archived parents in the "Done for good" undo, as the Completed screen does.

---

#### I-60. Today's 5: `_reloadFromDb()` discards the undo state for "Done today", so restoring a task afterwards only half-reverts it [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:138-145` (`_reloadFromDb`), `:1126` (`_pinTaskInTodaysFive`), `:883-892` (`_handleUncomplete`)

`_reloadFromDb` clears `_autoStartedIds` and `_preWorkedOnLastWorkedAt`. Both live only in memory and are never saved. Only the reconcile branches use `_reloadPreservingUndoState`. These callers use the plain reload:
- `_pinTaskInTodaysFive`: accepting a suggestion, creating a task, picking an existing task
- `_onSyncStatusChanged`, which with I-54 fires every few seconds
- `_onProviderChanged` at midnight

**Failure scenario:**
1. Task X is not started, and was last worked on 3 days ago.
2. Mark X "Done today". This auto-starts it.
3. Tap "+" on a suggestion pill, or just wait for a sync.
4. Tap X's done card to restore it.
5. `wasAutoStarted` is false, so X stays "in progress". `restoreTo` is null, so `last_worked_at` becomes NULL rather than 3 days ago, which changes how it is weighted for suggestions.

**Recommended fix:** `_pinTaskInTodaysFive` and `_onSyncStatusChanged` should call `_reloadPreservingUndoState()`, and it should also keep `_explicitlyUncompletedIds`. Better: keep a `DoneOutcome` per task (R-13), which holds its own undo data.

---

#### I-61. Today's 5: restoring a "Done for good!" task by tapping its done card does not restore its dependency links [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:895` (older than this round)

`_handleUncomplete` calls `provider.uncompleteTask(task.id!)` without `restoredDeps`. Only the snackbar undo (`:837`) passes the `removedDeps` that `completeTaskOnly` returned.

**Failure scenario:**
1. A blocks B. Pin A.
2. Mark A "Done for good!" and confirm the unblock.
3. Let the snackbar expire, then tap A's done card to restore it.
4. A is active again, but B no longer depends on it.

**Recommended fix:** Use `DoneOutcome` from `done_actions.dart` (R-13). Its undo restores the removed dependencies, and its doc comment already lists the Today's 5 sheet as a caller.

---

### Minor

#### M-53. Undoing "Add here" under a pinned parent does not put the parent back in Today's 5 [FIXED in Round 12 fix]
**Files:** `task_list_screen.dart:446-451`, `starred_screen.dart:1183-1190`

Linking a child turns the parent into a non-leaf. `_refreshAfterMutation` notifies listeners, and Today's 5 drops the parent and saves that (`todays_five_screen.dart:366-375, 393`). `removeParentFromTask` restores only the relationship.

**Scenario:** Pin leaf "Groceries". Drill into it, tap +, type an existing name, choose "Add anyway" on the pinned-parent warning, then tap the match. Tap Undo. Groceries is a leaf again, but no longer in Today's 5. The user was warned, but the Undo looks like a full restore.

**Fix:** Re-pin the parent with `TodaysFivePinHelper` in the undo if it was pinned before. Or offer no Undo when the parent was pinned, and say the pin is gone.

#### M-54. Firestore sync ids that are too long are cut to 50 characters and used, not rejected [FIXED in Round 12 fix]
**File:** `lib/services/firestore_service.dart:887-893`, applied at `:274-275, 321-322, 352-353, 400-401, 494-495, 545-546, 670, 879`

A malformed document whose `child_sync_id` is 60 characters is stored or looked up under a 50-character id that matches no task. `schedule_type`/`deadline_type` are cut to 20 characters in the same way and stored, when they should fall back to `weekly`/`due_by`. Reachable only with a malformed or hostile document. **Fix:** return null for ids that are too long, so the existing `!= null` checks skip the row. Check type fields against their allowed values and use the default otherwise.

#### M-55. "Also done today" tasks load paths, deadlines and schedules they never show [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:437-451`

`_loadTaskPaths` runs one recursive `getAncestorPath` per `_otherDoneToday` task and passes those ids to `getEffectiveDeadlines`/`getEffectiveScheduledTodayIds`. `_buildOtherDoneChip` shows only the name. This runs on every provider notification, so 20 tasks done today means 20 recursive queries per notification. **Fix:** load paths for `_todaysTasks` only.

#### M-56. `_loadTaskPaths` is called "for the suggestion pills" but never loads anything for them, and "suggest another" does not suggest another [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:470-474, 568, 756-760` (calls); `:1553` (sheet subtitle)

`_toggleSuggestions`, `_dismissSuggestion` and `_confirmRemoveFromTodaysFive` call `_loadTaskPaths` for the new pills. `_loadTaskPaths` skips suggestions (its own doc says so, `:431`), so each call only repeats queries. The options-sheet subtitle "Hide this one and suggest another" promises a replacement, but `_refreshSuggestions` re-picks only when the list is empty (`:526`). **Fix:** drop those calls. Reword the subtitle, for example to "Hide this one", and fix the comments listed in M-67.

#### M-57. A suggestion pick that finishes after "Hide" puts old pills back [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:464-478, 544`

Tap "Show suggestions", then "Hide" while the pick is still running. "Hide" sets `_suggestions = []`, then the finished pick assigns its list. On the next expand, the list is non-empty, so the old picks are kept, while the comment at `:476` promises a fresh set. **Fix:** a request counter in `_refreshSuggestions`. Apply the result only if the counter is unchanged and `_suggestionsExpanded` is still true.

#### M-58. Two quick "+" taps on different suggestion pills can lose the first pin [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:556-559, 1095-1118`

`_pinTaskInTodaysFive` reads the saved state, adds one id and saves the whole set. Two overlapping calls both read the old set, so the second save drops the first task. The window is a few awaits, so it needs a fast double tap. **Fix:** ignore a second accept while one is in flight, or run the pins one after another.

#### M-59. Restoring a task that has gained subtasks removes it from the screen but not from the saved state [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:852-865, 906`

`_removeIfNoLongerLeaf` drops the task from `_todaysTasks` but never calls `_persist()`. The database and the next push still list it until a later `refreshSnapshots` reconciles. **Fix:** `await _persist()` after the removal.

#### M-60. Today tab bottom sections may overflow on a phone in landscape [DEFERRED — needs `/debug-build` in landscape first]
**File:** `lib/screens/todays_five_screen.dart:1254-1272`

The Suggested and "Also done today" boxes sit in a non-scrolling `Column` below an `Expanded`, and orientation is not locked (`AndroidManifest.xml:20`). Estimated from layout constants, not run:
- Suggested expanded ≈154dp, Also-done ≈94dp, padding 24dp: ≈270dp in total.
- Landscape body ≈236dp: 412 screen − 24 status bar − 72 app bar − 80 navigation bar.

That is a RenderFlex overflow of about 35dp. **Fix:** move the bottom block into the scroll area, or wrap it in `Flexible` plus a scroll view. Check with `/debug-build` in landscape.

#### M-61. Pressing Back while the search spinner is showing can pop the wrong route [FIXED in Round 12 fix]
**File:** `lib/widgets/task_search.dart:57-74`

`barrierDismissible: false` does not block the Android Back button. If Back closes the spinner while `getAllTasks`/`getParentNamesMap` are loading, the `finally` block's `navigator.pop()` pops the route underneath, which is the app's home route. A database error also escapes `showTaskSearch` uncaught. The window is short with small data. **Fix:** wrap the spinner in `PopScope(canPop: false)` and catch errors in `showTaskSearch`.

#### M-62. Starred: M-34's N+1 now runs after every add or done in the dialog, and the dialog's own reload runs its queries one after another [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:179-221` (`_loadStarredTasks`), `:1014-1030` (`_fetchChildren`), `:1240-1246` (`_reloadAfterAdd`)

- `_loadStarredTasks` issues about 5S+1 queries for S starred tasks and runs after every provider notification (100 ms debounce, `:163-169`).
- `_fetchChildren` awaits `getChildren` once per child, one after another.
- `_reloadAfterAdd` repeats that for every cached level, also one after another. With 10 cached levels of 10 children, one add costs about 130 queries in sequence.

**Fix:** a database query that returns the active child count for each id in a list (`GROUP BY` on `task_relationships` joined to `tasks`). Run the levels in `_reloadAfterAdd` with `Future.wait`. This also closes M-34.

#### M-63. Starred: undoing with the circle refreshes blocked ids twice, and the snackbar's Undo still works meanwhile [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:1269-1273` (`_onDoneTapped`)

`done.undo()` already calls `_onDoneChanged(false)`, which runs `_refreshBlockedIds`, and `:1271` runs it again. `clearSnackBars()` runs only after both awaits, so a quick tap on the snackbar's Undo reverses the action a second time. The database effect is harmless (dependencies are re-inserted with `ConflictAlgorithm.ignore`), but `onChanged` fires twice. **Fix:** clear the snackbars first, and drop the second `_refreshBlockedIds`.

#### M-64. Starred: `_fetchChildren` adds to `_blockedIds`, while `_refreshBlockedIds` replaces the whole set (latent) [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:1009` vs `:1321`

If an expand runs at the same time as a done action, the replacement set can be built before the new level is in the cache, so blocked rows in that level lose their dimming. Needs taps at nearly the same moment. **Fix:** return the blocked ids from `_fetchChildren` and merge them in `setState`, or always rebuild through `_refreshBlockedIds`.

#### M-65. Starred: `_onProviderChanged` drops notifications that arrive during a load [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart:163-169`

It returns early while `_loading` is true, so a change that lands mid-load is never shown. If a load throws, `_loading` stays true and every later change is ignored. The dialog now sends notifications in bursts: a "Done today" sends 2-3. **Fix:** set a "reload again" flag in place of returning, and reset `_loading` in a `try`/`finally`.

#### M-66. Starred dialog rows overflow at depth 13 or more (latent) [FIXED in Round 12 fix]
**File:** `lib/screens/starred_screen.dart` (`_ExpandedTreeRow`)

The indent width is 72 + 16×depth px, and the dialog content is about 280 px wide on a 360 dp phone. Rows overflow from depth 13. Adding subtasks at any depth makes deep trees easier to build. **Fix:** cap the indent, or shrink the step with depth.

#### M-67. `docs/UI_VIEWS.md` is out of date [FIXED in Round 12 fix]
- **Line 16, suggestion count:** says Suggested shows "the whole eligible set". The code caps it at `_suggestionCap = 40` (`todays_five_screen.dart:87`) and re-picks only when the list is empty. The docstring at `:1377` repeats "all eligible".
- **Line 16, empty state:** the "No suggestions right now." empty state (`:1458`) is not mentioned.
- **Line 16, weighting:** says suggestions use "the same weighted selection as the All Tasks roulette". They don't:
  - The roulette's first spin uses `pickRandom` → `_taskWeight`, with no schedule boost, deadline boost or normalization (`task_provider.dart:448-455`).
  - "Spin Again" calls `pickWeightedN(pool, 1)` with no boost arguments (`task_list_screen.dart:1079`).
  - Suggestions are the boosted, normalized pick.

  The same wrong claim is in `todays_five_screen.dart:71-72, 481-484`.
- **Line 33:** omits that long-pressing a branch row in the Starred tree opens it in All Tasks (`starred_screen.dart:1706`).
- **Line 40, reopened dialog:** says done rows clear on reopen "since the tree only loads active tasks". That is true only for "Done for good!". A "Done today" task is still active, so it comes back as an ordinary row with an empty circle.
- **Line 40, repeated sentence:** two sentences say the circle tells the two apart.
- **Line 40, conflicting code comment:** `starred_screen.dart:1709-1710` says the strike-through tells them apart, which contradicts `:1729` and the doc.
- **Lines 64 and 72:** call Inbox a "checkbox" and "Add multiple" a toggle. Inbox is the shared `InboxToggleChip`: a filled accent inbox icon when on, outlined and muted when off. "Add multiple" is a `TextButton` (`add_task_dialog.dart:350-367`). The chip is not documented. Line 72 also carries a "(Bug fix: …)" history note, which belongs in a commit message.
- **All Tasks app bar:** not documented. At root it has the "Task graph" button (`account_tree_outlined`, `task_list_screen.dart:1583-1596`), which opens `DagViewScreen`. When drilled in it has Star/Unstar and "Open link".
- **Line 83 (Archive):** omits the relative status labels ("Completed today / yesterday / N days ago / <date>", `completed_tasks_screen.dart:64-85`), the "Delete permanently?" confirm (`:281`), and the "Restore task" confirm shown when a parent is archived (`:136`).
- **Line 60:** describes the "Lucky Pick" fallback dialog, which has no caller (I-56).

#### M-68. CLAUDE.md is out of date [FIXED in Round 12 fix]
- The "Today's 5 weighted selection" rule tells you to use `_fetchSelectionContext()`, which does not exist in `lib/`. Today's 5 is now manual. The only `pickWeightedN` call in that screen is in `_refreshSuggestions` (`:544`), which passes the boost arguments inline. Reword the rule to name `_refreshSuggestions`.
- The tabs are listed as "(Today, Starred, All Tasks)". The order is Starred, Today, All Tasks, and Starred is the default (`main.dart:89-92`).
- `AddTaskFlow` is said to include "pin transfer". Pin transfer was removed (`add_task_flow.dart:21`).

#### M-69. Stale code comments [FIXED in Round 12 fix]
- `todays_five_screen.dart:557-558, 562` say dismissing "backfills a fresh pick". It doesn't (M-56).
- The `_toggleSuggestions` docstring (`:461-463`) says suggestions are computed only on first expand. They are recomputed on every expand.
- `todays_five_screen.dart:572-574`: a doc comment about `_shortenPath` sits on `_deadlineIconColor`.
- `task_list_screen.dart:1408-1409` says deadlines are "stored for display only" and don't auto-pin. A deadline of today does auto-pin, and deadlines boost suggestions.
- `auth_service.dart:28` has "TODO: Replace with your actual Firebase project values". The values come from `--dart-define`.

#### M-70. Starred: a "Done today" row looks untouched when the dialog is reopened (design question) [OPEN — awaiting a design decision]
**File:** `lib/screens/starred_screen.dart:952-958`

Session styling is gone on reopen, so the circle offers "Done today" again for a task already worked on today. The comment at `:952-958` says the dimming matches All Tasks, but All Tasks dims a card from `last_worked_at`, which survives a reopen. This is a design decision for the user, not a bug fix.

---

### Refactoring

#### R-13. Today's 5 repeats the shared done actions instead of using `DoneOutcome` [FIXED in Round 12 fix]
**File:** `lib/screens/todays_five_screen.dart:784-842` (`_workedOnTask`, `_completeNormalTask`)

These repeat `markTaskDoneToday`/`completeTaskForGood` from `done_actions.dart` almost line for line: the deadline prompt, the animation, the dependency confirm and the undo closure. Keep a `Map<int, DoneOutcome>` the way `starred_screen.dart` does, with `onChanged` calling `_markDone`/`_unmarkDone`, and have `_handleUncomplete` call `outcome.undo()`. This fixes I-61 and most of I-60.

#### R-14. The "Add here" link-with-undo handler is written twice [FIXED in Round 12 fix]
**Files:** `task_list_screen.dart:417-457`, `starred_screen.dart:1164-1197`

Both handlers do the same steps: self-check → `getChildIds` → "already listed here" → `addParentToTask` → undo with `removeParentFromTask` → loop message. I-55 and M-53 each need fixing in both copies. Extract one helper, for example `linkExistingHere(context, provider, existing, parentId, {onChanged})`.

#### R-15. The suggestion data is fetched with two sequential full-table queries on every "+" [FIXED in Round 12 fix]
**Files:** `task_list_screen.dart:402-403`, `starred_screen.dart:96-97, 1152-1153`, `task_search.dart:103-104`

Each site awaits `getAllTasks()` and then `getParentNamesMap()`. `task_search.dart:68` and `_fetchCandidateData` (`task_list_screen.dart:501`) already run the same pair together with `Future.wait`. Make that one shared function, and make `fetchSearchCandidates` (`task_search.dart:54`, used only in that file) private or the shared entry point.

#### R-16. Dead code [FIXED in Round 12 fix — `getTaskBySyncId` kept, see Round 12 Fix]
- `lib/widgets/random_result_dialog.dart` is imported only by tests. `spinIcon` (`display_utils.dart:23`) is used only by that dialog. Delete both, plus `test/widgets/random_result_dialog_test.dart`, unless I-56 wires the dialog in.
- Public members with no caller in `lib/`:
  - `TaskProvider.hasSchedule` (`task_provider.dart:1021`), which has no caller even in tests
  - `DatabaseHelper.getLeafDescendants` (`:2718`), `getTaskBySyncId` (`:2527`), `getTaskIdsWithStartedDescendants` (`:2744`), `getTodaysFiveTaskIds` (`:2853`) and `updateStarOrder` (`:1387`; `reorderStarredTasks` took its place)
  - `Task.priorityLabel` and `Task.isDeadlineOn` (`task.dart:58, 62`)
- Commented-out `transferPin`/`togglePinInPlace` in `todays_five_pin_helper.dart:108-150`. Git history keeps them.
- `AddTaskFlow.parentId` (`add_task_flow.dart:59-62`) is never read; its doc says it is "kept as context".

`dag_view_screen.dart`/`force_directed_layout.dart` are **not** dead. The root "Task graph" button reaches them (M-67).

#### R-17. Small cleanups [FIXED in Round 12 fix]
- The "Go to task" `ListTile` (`todays_five_screen.dart:680-689, 1540-1549`) and the bordered container decoration (`:1418-1425, 1935-1942`) are each written twice. Extract each one.
- `_refreshSnapshotsInner` (`:350-358`) calls `getTaskById` per leaf although `getAllLeafTasks()` already returned fresh rows. `_refreshSuggestions` then fetches `getAllLeafTasks()` again. Pass the list through.
- `_handleTaskDone` (`:846`) and `_fadeRightEdge` (`:1474`) each only call one other function. `_refreshTaskSnapshot`'s return value is unused.
- `_matches` in `add_task_dialog.dart:140` is a getter that scans the whole task list and is read twice per keystroke (`:312-313`). Compute it once in `build`.
- `starred_screen.dart` `_loadDirectChildren` (`:981-985`) calls `setState` and then `_rebuildFlatTree`, which calls `setState` again. Merge the two.

---

## Round 12 — Suggested Implementation Order

1. **I-54**: Stop the push loop from sync status changes. It affects every signed-in user and undoes the cross-device last-write-wins fix.
2. **I-55** together with **R-14**: one shared "Add here" helper that files Inbox tasks with `fileTask`. Fold in **M-53**.
3. **R-13** together with **I-61** and **I-60**: move Today's 5 onto `DoneOutcome`, and use `_reloadPreservingUndoState` in the pin and sync paths.
4. **I-57**, **I-59**, **I-58**: Starred dialog done-row fixes (block navigation on archived rows; branch status from the cache; re-read the task before recording undo values).
5. **I-56**: exclude Inbox tasks from the root Flare pool, and decide what happens to `RandomResultDialog`.
6. **M-67 / M-68 / M-69**: docs and comments. Cheap; do with the related code fixes.
7. The remaining Minor items as time permits. **M-60** needs a `/debug-build` in landscape first.
8. **R-15–R-17**, and **M-32/M-34/M-62** (batched child counts), when touching those files.

---

### Items Still Open From All Rounds

| Item | Title | Round | Status |
|------|-------|-------|--------|
| R-11 | Dedup sync query/reconcile | 11 | Deferred (high-risk refactor; do as its own PR) |
| R-12 | Dedup picker browse-tree | 11 | Deferred (pickers behave differently, low value) |
| M-60 | Today tab bottom sections may overflow in landscape | 12 | Deferred — check with `/debug-build` in landscape first |
| M-70 | Starred "Done today" row looks untouched on reopen | 12 | Open — design question for the user |

Everything else from Round 12, plus M-32 and M-34, was fixed in the Round 12 Fix below.

---

## Round 12 Fix (2026-10-05)

All 8 Important findings, 16 of the 18 Minor findings, R-13 to R-17, and the older M-32 and M-34 are fixed. Each bug fix has a regression test that was run and seen to fail before the fix. `flutter analyze` is clean, the full `flutter test` run passes (1595 tests), and `flutter build linux` succeeds.

### Fixed in This Round

| ID | Title | Notes |
|----|-------|-------|
| I-54 | Sync → reload → push loop | `SyncService.dataChangeGeneration` goes up only when a pull writes remote changes. The Today tab reloads only when it changes. `_persist()` also skips the save and the push when the database already holds the same state. |
| I-55 | "Add here" leaves an Inbox task in the Inbox | The shared `linkExistingHere` (R-14) calls `fileTask`, and Undo calls `unfileTask`. "Also show under" files an Inbox task too. The `_loadInboxCount` calls that never ran are gone. |
| I-56 | Flare at root does nothing on an Inbox pick | `pickRandom` skips Inbox tasks at root. **User's choice:** `RandomResultDialog`, `spinIcon` and their tests are deleted, and so is the "Lucky Pick" line in `UI_VIEWS.md`. |
| I-57 | Done-for-good Starred row still opens | **User's choice:** tapping the row body does nothing while the row is done for good. The circle still undoes it. |
| I-58 | Second "Done today" works from the cached task | `markTaskDoneToday` reads the task from the database before recording the undo values (new `TaskProvider.getTaskById`). |
| I-59 | Parent turns into a leaf; child left under an archived parent | `_addVisibleNodes` keeps a node a branch while its cache entry has rows. The "Done for good!" undo in `done_actions.dart` drops links to archived parents, as the Completed screen does, but without a confirm dialog, since an undo has no dialog step. |
| I-60 | `_reloadFromDb` discards undo state | Fixed through R-13. The pin and sync paths call `_reloadPreservingUndoState`, which now also keeps `_explicitlyUncompletedIds`. |
| I-61 | Card restore drops dependency links | Fixed through R-13: tapping a done card calls the task's `DoneOutcome.undo()`. |
| M-32 | N+1 in `deleteTaskAndReparentChildren` | One `INSERT … OR IGNORE` per pair; a return value of 0 means the link already existed. |
| M-34 / M-62 | Starred N+1s | New `getChildrenOfParents` and `getActiveChildCounts` queries. The card preview uses one query for children and one for grandchildren. The dialog uses one count query per level, and `_reloadAfterAdd` fetches its levels in parallel. |
| M-53 | Undo of "Add here" does not re-pin the parent | **User's choice:** Undo pins the parent again if it was pinned. It pins before removing the link, so the Today tab's reload keeps it. New shared `pinIntoTodaysFive`, which `AddTaskFlow` uses too. |
| M-54 | Over-long Firestore ids cut and used | `_stringField` returns null for an over-long value. The new `_enumField` makes `deadline_type` and `schedule_type` fall back to their defaults for oversized or unknown values. The 12 INFO-12 tests that asserted truncation now assert the new rule. |
| M-55 | "Also done today" loads unused paths | `_loadTaskPaths` covers `_todaysTasks` only. |
| M-56 | "suggest another" | **User's choice:** the subtitle now reads "Hide this one". The `_loadTaskPaths` calls that loaded nothing are gone. |
| M-57 | Stale suggestion pick after Hide | `_refreshSuggestions` keeps a request counter and applies a result only if it is the latest request and the section is still expanded. |
| M-58 | Double "+" loses the first pin | `_pinTaskInTodaysFive` makes a second call wait for the first. |
| M-59 | Restored task with subtasks stays in saved state | `_removeIfNoLongerLeaf` calls `_persist()`. |
| M-61 | Back during the search spinner | The spinner is wrapped in `PopScope(canPop: false)`, and `fetchSearchCandidates` catches database errors and shows a snackbar. The duplicate spinner helper `_fetchCandidateData` in All Tasks is replaced by `fetchSearchCandidates`. |
| M-63 | Circle undo double-refresh | The snackbars are cleared before the undo runs, and the second `_refreshBlockedIds` call is gone. |
| M-64 | `_refreshBlockedIds` replaces the whole set | It now replaces only the ids it checked. |
| M-65 | Starred drops changes during a load | A change during a load queues one more load, and `_loading` is reset in a `finally`. |
| M-66 | Deep rows overflow | **Changed after manual testing (user's choice):** the dialog is 420 px wide until the deepest expanded row needs more, then widens to fit, up to the screen width. Rows keep 160 px for the name and draw as many ancestor columns as fit, never fewer than 6 unless the name would get under 40 px. Widget tests cover 15 levels at 360 px, 12 levels at 1400 px, and 9 levels at 230 px. |
| M-67 | `UI_VIEWS.md` drift | All listed points fixed. The behaviour changes from this round are documented too. |
| M-68 | CLAUDE.md drift | Tab order, no pin transfer, and the weighted-selection rule now names `_refreshSuggestions`. |
| M-69 | Stale comments | All listed comments fixed. |
| R-13 | Today's 5 repeats the done actions | Keeps a `Map<int, DoneOutcome>` and calls `markTaskDoneToday`/`completeTaskForGood`. **User-visible:** the Today's 5 snackbars now use the shared wording ("— nice work!" / "done for good!"). |
| R-14 | "Add here" written twice | `lib/widgets/link_existing_here.dart`. |
| R-15 | Sequential task + parent-name fetch | `TaskProvider.getAllTasksWithParentNames()` runs both reads in parallel and is used at every call site. |
| R-16 | Dead code | Deleted `hasSchedule`, `getLeafDescendants`, `getTaskIdsWithStartedDescendants`, `getTodaysFiveTaskIds`, `updateStarOrder` (its test now uses `reorderStarredTasks`), `Task.priorityLabel`, `Task.priorityLabels`, `Task.isDeadlineOn`, the commented-out `transferPin`/`togglePinInPlace` and their commented-out tests, and `AddTaskFlow.parentId`. **Deviation:** `getTaskBySyncId` is kept, because the sync tests use it to check upserts. |
| R-17 | Small cleanups | `_goToTaskTile` and `_bottomBoxDecoration` extracted. `_refreshSnapshotsInner` uses the rows `getAllLeafTasks` already returned. `_handleTaskDone` and `_fadeRightEdge` inlined. `_refreshTaskSnapshot` returns `void`. `_matches` is read once per build. `_loadDirectChildren` sets state once. |

### Remaining Open

| ID | Title | Reason |
|----|-------|--------|
| M-60 | Landscape overflow of the Today tab's bottom sections | Estimated, not observed. Check with `/debug-build` in landscape before changing the layout. |
| M-70 | Starred "Done today" row looks untouched on reopen | Design question for the user. |
| R-11, R-12 | Deferred refactors from Round 11 | Unchanged; see Round 11 Fix. |

---

## Round 12 Fix Verification (2026-10-06)

Independent verify pass over `c912fe8` and `b715fe0`. Each fix was read against the current code and checked for root cause and regressions. `flutter analyze` reports no issues. `flutter test` passes: 1614 tests, 1 skipped.

### Verified

- **Important:** I-55 (the "Add here" and "Also show under" paths; see I-63 for the path left out), I-56, I-57, I-58, I-59, I-60, I-61. **I-54** fixes the loop itself, but introduced I-62.
- **Minor:** M-32, M-34/M-62, M-53, M-54, M-55, M-56, M-57, M-58, M-59, M-61, M-63, M-64, M-65, M-66, M-68, M-69.
- **Refactoring:** R-13, R-14, R-16. R-15 and R-17 are verified for what the Fix table claims; the leftovers are in M-73.
- **M-67** is partly done; the leftovers are in M-72.

Notes:
- **I-54:** `dataChangeGeneration` goes up only when a pull changed data (`sync_service.dart:859`) or after `replaceLocalWithCloud` (`:368`). The skip check in `_persist` compares the ordered ids, the completed set, the worked-on set and the pinned set.
- **I-59, design consequence:** the "Done for good!" undo drops links to archived parents without asking. Complete child B, then its parent A. Undo B first, and A→B is dropped. Undoing A afterwards does not bring B back under it. This matches the documented choice (an undo has no dialog step), but the user may not expect it.
- **M-53:** if Today's 5 filled up between the link and the Undo, the re-pin is skipped without a message. This is a small edge case.
- **M-62:** `getChildrenOfParents`/`getActiveChildCounts` are not split into chunks for SQLite's 999-parameter limit. The id lists are starred tasks or one parent's children, so this is not a realistic failure.

### New Findings

#### I-62. Pins made on the Today tab are no longer pushed to Firestore (regression from I-54)
**File:** `lib/screens/todays_five_screen.dart:1111-1145` (`_pinTaskInTodaysFiveInner`), `:444-467` (`_persist`)

`_pinTaskInTodaysFiveInner` saves through `db.saveTodaysFiveState` directly, then calls `_reloadPreservingUndoState()`. That reload ends in `_persist()`. Before I-54, `_persist()` always called `onTodaysFivePersisted()` → `schedulePush()`. Now the database already holds exactly the reloaded state, so `_persist` returns early and schedules no push. `onTodaysFivePersisted` has no other caller (`grep` over `lib/`).

These paths make no other change that would push: accepting a suggestion ("+" on a pill or "Add to Today's 5"), "Pick existing task", and "Pin instead" in the create dialog. Creating a new task still pushes, because `addTask` fires `onMutation`. `flushPush` on going to the background does nothing, since no debounce timer is running. The deadline suppression that `unsuppressDeadlineAutoPin` clears is not pushed either.

**Scenario:** signed in, open the Today tab and accept a suggestion. Nothing is pushed. Other devices do not see the pin until some unrelated change triggers a push.

**Fix:** call `context.read<SyncService>().onTodaysFivePersisted()` right after the save in `_pinTaskInTodaysFiveInner`. Add a test that a pin from the Today tab schedules a push; the I-54 test checks only that an unchanged sync does not save again.

#### I-63. "Link existing task" leaves an Inbox task in the Inbox (I-55 path left out)
**Files:** `lib/screens/task_list_screen.dart:465-507` (`_linkExistingTask`), `lib/providers/task_provider.dart:680-691` (`linkChildToCurrent`)

The "Link existing task" button shown when drilled into a task (`playlist_add`, `task_list_screen.dart:1452`) calls `linkChildToCurrent`, which only calls `addRelationship` and never clears `is_inbox`.

**Scenario:** brain-dump "Buy milk" into the Inbox, drill into Groceries, tap "Link existing task" and pick "Buy milk". It is listed under Groceries and is still in the root Inbox.

**Fix:** clear the flag when an Inbox task is linked under a parent. Doing it in the provider covers every linking path at once; the undo then needs to restore the flag, as `unfileTask` does.

#### M-71. Today's 5: a card tap and the done snackbar's Undo can both run the same undo
**File:** `lib/screens/todays_five_screen.dart:861-874` (`_handleUncomplete`)

`_handleUncomplete` awaits `outcome.undo()` and `_removeIfNoLongerLeaf` before `_showRestoredSnackBar` clears the snackbars. Within that window, the done snackbar's Undo still calls the same `outcome.undo`. The database result is the same, because every write repeats the same values or inserts with ignore-on-conflict. The cost is a second `_unmarkDone` and a second refresh. **Fix:** clear the snackbars before running the undo, as M-63 did in Starred.

#### M-72. M-67/R-16 docs and comment leftovers
- `docs/UI_VIEWS.md:76` still calls "Add multiple" a "toggle". It is a `TextButton`.
- `starred_screen.dart:1846-1847` still says the strikethrough tells "Done today" and "Done for good!" apart. `:1869-1870` and `UI_VIEWS.md` say the circle does.
- `docs/TEST_COVERAGE.md:16` lists `isDeadlineOn`, and `:22` lists `togglePinInPlace`. Both were deleted in R-16.

#### M-73. R-15/R-17 leftovers (performance only)
- `triage_dialog.dart:172-173` still awaits `getAllTasks()` and then `getParentNamesMap()` one after the other. Use `getAllTasksWithParentNames()`.
- `_refreshSuggestions` (`todays_five_screen.dart:551`) still fetches `getAllLeafTasks()` itself, where R-17 asked to pass the list in.

### Merge Verdict

**Do NOT merge — fix these first:**
1. **I-62**: a sync regression that the fix round introduced. Pins from the Today tab no longer reach other devices.
2. **I-63**: the same Inbox bug as I-55, on the "Link existing task" path. It is cheap to fix together with I-62.

M-71 to M-73 are minor and can be done in the same pass or carried forward. M-60, M-70, R-11 and R-12 stay open as before.

### Items Still Open From All Rounds

| Item | Title | Round | Status |
|------|-------|-------|--------|
| I-62 | Today tab pins not pushed to Firestore | 12 verify | Open — blocks merge |
| I-63 | "Link existing task" leaves an Inbox task in the Inbox | 12 verify | Open — blocks merge |
| M-71 | Today's 5 card tap and snackbar Undo can both run | 12 verify | Open |
| M-72 | Docs and comment leftovers from M-67/R-16 | 12 verify | Open |
| M-73 | R-15/R-17 performance leftovers | 12 verify | Open |
| M-60 | Today tab bottom sections may overflow in landscape | 12 | Deferred — check with `/debug-build` in landscape first |
| M-70 | Starred "Done today" row looks untouched on reopen | 12 | Open — design question for the user |
| R-11 | Dedup sync query/reconcile | 11 | Deferred (high-risk refactor; do as its own PR) |
| R-12 | Dedup picker browse-tree | 11 | Deferred (pickers behave differently, low value) |
