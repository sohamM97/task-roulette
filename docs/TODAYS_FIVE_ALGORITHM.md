# Today's 5 Selection — Manual Model (with deadline-today auto-pin)

How the app populates the daily focus view.

## Overview

Today's 5 is **manual-first** with **one automatic exception**: leaf tasks
whose deadline is **exactly today** are auto-pinned on every load (see
"Deadline-today auto-pin" below). Apart from that, each day starts empty and
tasks appear only when the user explicitly pins them. Pin entry points:

- **Today tab + FAB** → bottom sheet with "Create new task" (auto-pinned at
  root) or "Pick existing task" (triage-style dialog with always-visible
  search bar + browse tree; only leaves can be pinned, tasks already in
  Today's 5 are hidden).
- **All Tasks tab** pin button on any task card.
- Per-task **bottom sheet** on the Today tab (Pin/Unpin tile).

Up to 5 tasks can be pinned at once.

There is no random pick, no weighted roulette, no normalization, no
diversity penalty, no schedule reservation, no reroll, no per-card swap. The
**only** automatic population is the deadline-today auto-pin described below
(overdue/future deadlines are never auto-pinned).

## Deadline-today auto-pin

The reconcile runs on **every load** (`_loadTodaysTasksInner()` — app start,
sync, midnight rollover) **and on every in-place refresh** (`refreshSnapshots()`
— provider notifications / tab focus). The refresh path does a cheap check:
if a non-suppressed deadline-today leaf isn't already in the list it falls back
to a full reload, so a deadline set to **today while the app is open** auto-pins
immediately without an app restart. The reconcile compares the saved set with
today's deadlines:

1. `getDeadlinePinLeafIds()` returns leaf tasks that are due today — either the
   leaf's **own** `deadline = today`, **or** it's a leaf descendant of an
   ancestor whose `deadline = today` (deadline inheritance: the SQL walks
   descendants of every `deadline = today` task and returns the leaves). So a
   leaf with a NULL/other deadline can still auto-pin if a parent is due today.
   Overdue (yesterday or earlier) and future deadlines are excluded — overdue
   tasks rely on weight boost in the All Tasks roulette instead.
2. Tasks the user has removed today are subtracted: `getDeadlineSuppressedIds()`
   reads the `todays_five_deadline_suppressed` table (keyed by date).
3. The remaining IDs are merged into the saved task list and persisted as
   normal pinned members.

**Removals are respected per task.** When the user removes *any* Today's 5 task
— pinned or deadline-forced — via the X button / "Remove" tile / All Tasks
unpin, `suppressDeadlineAutoPin(today, id)` records a per-task suppression
tombstone. This does two jobs: (a) the next reconcile won't re-auto-pin a
*deadline* task the user removed (a *different* task that becomes due today
still auto-pins); and (b) the tombstone is **synced** (`deadline_suppressed_
sync_ids`) so a removal propagates across devices instead of bouncing back —
the merge drops any suppressed task even if a device still has it locally
pinned. (Codex P2 fix: this used to be recorded only for deadline-today tasks,
so removing a plain pinned task left no tombstone and it was resurrected on the
next pull.) Manually pinning a task back clears its suppression
(`unsuppressDeadlineAutoPin`), as does giving the task a **today deadline**
(`updateTaskDeadline` — "due today" deliberately overrides an earlier same-day
unpin). On merge, a task the remote lists as a member clears the local
suppression **only when the remote doc is genuinely newer** (`remoteIsNewer`) —
a real cross-device re-pin. It must NOT clear when the remote is merely *stale*
(still listing a task we just unpinned but haven't pushed yet), or a pull racing
ahead of our debounced push would erase the fresh tombstone and resurrect the
removal. Suppression rows are date-keyed and old ones are purged on load
(`purgeOldDeadlineSuppressed`).

The deadline-today indicator on the card is the existing proximity-coloured
clock icon (deepOrange for ≤2 days) — there is no separate "Today"-specific
badge.

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
| Pin entry points | `lib/screens/task_list_screen.dart`, `lib/widgets/add_task_flow.dart` | `_togglePinInTodays5` (All Tasks leaf detail); `_pinNewTask` (pin-on-add via shared `AddTaskFlow`). Manual model: no pin auto-transfer to a child when a pinned task becomes non-leaf — it just drops. |
| State persistence | `lib/data/database_helper.dart` | `saveTodaysFiveState`, `loadTodaysFiveState` |

## What Was Removed (and Why)

This view used to use a weighted-random algorithm with deadline auto-pin and
scheduled-source reserved slots. It was removed because the auto-selection
felt too prescriptive — the user wanted full control over what appears in
the focus view.

The deadline-today auto-pin was **later restored** in a narrowed form
(deadline *exactly* today only — see "Deadline-today auto-pin" above), which
brought `getDeadlinePinLeafIds()`, the suppression methods, and the
`todays_five_deadline_suppressed` table back into production use.

The following are **still present but unused in production**, kept for the
future suggestion mechanism (see "Future" below):

- `TaskProvider.pickWeightedN()`, `getScheduleBoostedLeafIds()`,
  `getDeadlineBoostedLeafData()`, `getNormalizationData()`,
  `getScheduledSourceToLeafMap()`

Now back **in** production use (no longer dead code):

- `DatabaseHelper.getDeadlinePinLeafIds()`, `suppressDeadlineAutoPin()`,
  `unsuppressDeadlineAutoPin()`, `getDeadlineSuppressedIds()`,
  `purgeOldDeadlineSuppressed()`, and the `todays_five_deadline_suppressed`
  table.

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
