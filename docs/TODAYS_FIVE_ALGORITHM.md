# Today's 5 Selection — Manual Model

How the app populates the daily focus view.

## Overview

Today's 5 has **no automatic selection**. Each day starts empty, and tasks
appear only when the user explicitly pins them. Pin entry points:

- **Today tab + FAB** → bottom sheet with "Create new task" (auto-pinned at
  root) or "Pick existing task" (triage-style dialog with always-visible
  search bar + browse tree; only leaves can be pinned, tasks already in
  Today's 5 are hidden).
- **All Tasks tab** pin button on any task card.
- Per-task **bottom sheet** on the Today tab (Pin/Unpin tile).

Up to 5 tasks can be pinned at once.

There is no random pick, no weighted roulette, no normalization, no
diversity penalty, no schedule reservation, no deadline auto-pin, no reroll,
no per-card swap.

## Lifecycle

1. **Empty by default.** When `_loadTodaysTasksInner()` finds no saved
   `todays_five_state` row for today, the screen renders the empty state.
2. **First pin bootstraps state.** `_togglePinInTodays5` /
   `_pinNewTaskInTodays5` in `task_list_screen.dart`, and
   `_pinTaskInTodaysFive` in `todays_five_screen.dart`, all create a fresh
   empty `TodaysFiveData` if none exists, then add the task.
3. **Refresh keeps existing tasks fresh.** `refreshSnapshots()` re-fetches
   the current task list from the DB — it does **not** add new tasks.
4. **Tasks dropped automatically only when invalid.** A task is removed from
   Today's 5 if it becomes non-leaf (subtasks added) and isn't already done,
   or if it's deleted entirely. No replacement is picked.
5. **Pin = membership.** Every task in Today's 5 is implicitly pinned —
   there is no separate pin/unpin toggle within the screen. The only way
   to take a task off the list is the **Remove (X) button** on the card or
   the "Remove from Today's 5" tile in the bottom sheet, both of which go
   through an "are you sure?" confirmation dialog. The DB column
   `pinnedIds` is still persisted (set equal to `taskIds` on every save) for
   sync round-trip compatibility, but the UI no longer reads it for any
   distinction.
6. **Midnight rollover.** When the date key changes, the screen reloads from
   DB. Yesterday's saved state isn't carried forward — today starts empty
   unless the user already pinned something for today on another device.

## Constants

| Constant | Value | Where |
|----------|------:|-------|
| Max pinned | 5 | `TodaysFivePinHelper.maxPins` |
| Max total slots | 10 | `TodaysFivePinHelper.maxSlots` |

`maxSlots` allowed legacy auto-picked tasks plus pins to coexist. With the
manual model every task is pinned, so the effective ceiling is `maxPins`.

## Key Files

| Component | File | Notes |
|-----------|------|-------|
| Screen | `lib/screens/todays_five_screen.dart` | Load / refresh / unpin removal / FAB add flow (`_pinTaskInTodaysFive`) |
| Pin helper | `lib/data/todays_five_pin_helper.dart` | `togglePin` / `togglePinInPlace` / `pinNewTask` |
| Pin entry points | `lib/screens/task_list_screen.dart` | `_togglePinInTodays5`, `_pinNewTaskInTodays5`, `_transferPinToChild` |
| State persistence | `lib/data/database_helper.dart` | `saveTodaysFiveState`, `loadTodaysFiveState` |

## What Was Removed (and Why)

This view used to use a weighted-random algorithm with deadline auto-pin and
scheduled-source reserved slots. It was removed because the auto-selection
felt too prescriptive — the user wanted full control over what appears in
the focus view.

The following methods, fields, DB tables, and `TaskProvider` APIs are
**still present in the code but unused in production**, kept around in case
they're needed for the future suggestion mechanism (see "Future" below):

- `TaskProvider.pickWeightedN()`, `getDeadlinePinLeafIds()`,
  `getScheduleBoostedLeafIds()`, `getDeadlineBoostedLeafData()`,
  `getNormalizationData()`, `getScheduledSourceToLeafMap()`
- `DatabaseHelper.suppressDeadlineAutoPin()`,
  `unsuppressDeadlineAutoPin()`, `getDeadlineSuppressedIds()`,
  `purgeOldDeadlineSuppressed()`
- The `todays_five_deadline_suppressed` DB table (still created by
  migrations; no longer written or read by the UI)

If those stay unused indefinitely, a future cleanup pass can remove them
together with the migration to drop the table.

## Future

The user has expressed interest in a **suggestion mechanism** for surfacing
deadline-due and scheduled tasks without forcing them into Today's 5.
Possible directions:

- A "Suggested" affordance (banner / chip / bottom sheet) on the Today tab
  that says "You have X due today" or "Y is scheduled for today" with a
  one-tap pin action.
- A separate "Suggestions" tab or section in All Tasks that highlights
  tasks the system thinks are worth attention (using the old weighted
  factors — priority, deadline, schedule, staleness — but as a *display*
  ranking rather than a forced pin).

Whatever shape it takes, the dormant code listed above (especially
`pickWeightedN` and the boost queries) is a viable starting point.
