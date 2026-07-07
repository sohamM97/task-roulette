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

### Items Still Open From All Rounds

| Item | Title | Round | Status |
|------|-------|-------|--------|
| ~~I-38 / R-9~~ | ~~`_transferPinToChild` bypasses TaskProvider~~ | 9 | **Obsolete** — method removed with manual Today's-5 model |
| M-32 | N+1 in `deleteTaskAndReparentChildren` | 9 | Open — low impact |
| M-34 | Starred N+1 for tree preview | 10 | Open — low impact |
| ~~I-48~~ | ~~Today's-5 LWW clock-basis mismatch~~ | 11 | **[FIXED in Round 11 fix]** |
| ~~I-49~~ | ~~Task hard-deletes don't propagate~~ | 11 | **[FIXED in Round 11 fix]** (Firestore-only tombstones) |
| ~~I-50~~ | ~~Bulk sync ops outside `_syncing` mutex~~ | 11 | **[FIXED in Round 11 fix]** |
| ~~I-51~~ | ~~External "Done today" undo doesn't revert DB~~ | 11 | **[FIXED in Round 11 fix]** |
| ~~I-52~~ | ~~`getEffectiveDeadlines` N+1 on hot path~~ | 11 | **[FIXED in Round 11 fix]** |
| ~~I-53~~ | ~~Starred grandchild DRY-rule violation~~ | 11 | **[FIXED in Round 11 fix]** |
| ~~M-39…M-52~~ | (see Round 11 Fix section) | 11 | **All fixed** (M-39 no-op by design; M-44 partial — see notes) |
| ~~R-10~~ | ~~`addTask` insert not atomic~~ | 11 | **[FIXED in Round 11 fix]** |
| R-11 | Dedup sync query/reconcile | 11 | **Deferred** — high-risk refactor, recommend focused PR |
| R-12 | Dedup picker browse-tree | 11 | **Deferred** — divergent per-picker behavior, low value |
