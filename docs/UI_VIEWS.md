# UI Views Reference

Reference for manual test instructions. Use these names consistently.

## Navigation

- **Bottom nav bar** — 3 tabs: "Today", "Starred", "All Tasks". Swiping also switches tabs.

## Tabs

### Today tab (Today's 5)
- **Task card** — each task in the Today's 5 list. Shows task name, subtitle icons (priority, deadline, scheduled today, started, someday). Done tasks are faded with strikethrough. Trailing icons: pin button, spin button (double-dice `casino_outlined`), "Go to task" link (`open_in_new`).
- **Spin button** (double-dice icon) — on undone task cards. Opens the **swap bottom sheet**. Not shown on done tasks.
- **Swap bottom sheet** — appears when tapping the spin button. Options: "Roulette spin" (spin the wheel for a new task) and "Place your bet" (hand-pick a task for this slot).
- **Reroll pinned task dialog** — appears when tapping "Roulette spin" on a pinned task. Title: "Reroll pinned task?", body: "Reroll this slot?", buttons: "Cancel" / "Reroll".
- **Reroll all button** — double-dice icon (`casino_rounded`, two overlapping tilted dice) in the app bar. Only shown when there are undone unpinned tasks. Opens the **Reroll all dialog**.
- **Reroll all dialog** — title: "Reroll all?", body varies by state, button: "Reroll". When all tasks are done/pinned, shows "nothing to reroll" with no confirm button.
- **Bottom sheet** — appears when **tapping** an undone task card. Options: "Done today", "Done for good!", "In progress"/"Stop working". Note: Pin/Unpin is NOT in the bottom sheet — it's a separate pin icon button on the card itself.
- **Completion animation** — brief celebration overlay after marking done.
- **"Also done today" section** — expandable area below the main list showing tasks worked on today outside the Today's 5 set.
- **Progress bar** — segmented progress bar at top showing done/total.

### Starred tab
- **Starred task card** — card with accent bar (left edge, color derived from task ID), star icon, task name, subtitle (sub-task count, "In progress"), and tree preview. **Tap** opens the expanded dialog (if task has children) or navigates to the task (if leaf). **Long-press** opens unstar option with undo. **Drag handle** on right for reordering.
- **Tree preview** — inside the card, shows up to 3 children and 2 grandchildren per child with connector lines. High-priority children are shown with accent-tinted bold text. Blocked children are dimmed.
- **Expanded dialog** — full-screen dialog opened by tapping a starred card with children. Shows task tree with lazy-expanding nodes. Chevron (`>` / `v`) on non-leaf nodes to expand/collapse. Leaf nodes show `open_in_new` icon. Same priority highlighting and blocked dimming as tree preview via shared `childTextStyle()` helper.

### All Tasks tab
- **Task card** — grid card for each task. Shows task name, top-left indicator icons (Today's 5, worked-on, started, priority, someday, deadline, scheduled today, starred). **Tap** navigates into the task. **Long-press** opens a context menu (delete, rename, move, schedule, etc.).
- **Task list** — hierarchical list. Shows children of the current parent. Root level shows top-level tasks + Inbox.
- **Inbox section** — collapsible section at top showing unorganized tasks.
- **Leaf detail view** — appears when navigating into a leaf task (a task with no children). Shows task name, "Done today" button, "Done for good!" button, "Start"/"Started" toggle, priority selector, schedule/deadline info, dependencies, parent breadcrumbs. This is NOT the same as the Today's 5 bottom sheet.
  - **"Do after..." icon (add_task)** — shown when the task has **no** dependency. **Tap** opens the "Do X after..." picker dialog to add a dependency.
  - **Dependency icon (hourglass)** — replaces the "Do after..." icon when the task has a dependency. **Tap** navigates to the blocker task. **Long-press** opens the "Do X after..." picker dialog to change or remove the dependency. Color behavior: **primary color** when actively blocked, **greyed out** when the blocker is no longer blocking (e.g. marked "Done today"). When the blocker is completed ("Done for good") or skipped, the dependency row is deleted from the DB, so the hourglass **disappears entirely**.
- **"Done today" button** — filled purple button on the leaf detail view. Marks the task as worked on.
- **"Worked on today" button** — outlined button that replaces "Done today" after marking. Acts as undo for the worked-on status.
- **Flare FAB** (`Icons.flare`) — bottom-right FAB on non-leaf views. Triggers the **spotlight** random pick animation.
- **Spotlight overlay** — dims all task cards and spotlights (glow + scale-up) a randomly picked task. Tapping the spotlighted card navigates into it. The FAB column changes during spotlight: "Spin Again" (flare, rerolls), "Open" (`open_in_new`, navigates into task), "Spin Deeper" (`keyboard_double_arrow_down`, shown if task has children — navigates in and auto-spotlights a child). Tapping the dim backdrop dismisses. Back button dismisses.
- **Lucky Pick dialog** — fallback dialog shown if spotlight can't render (e.g. task not in grid). Title: "Lucky Pick". Actions: "Spin Again", "Go Deeper", "Go to Task".

## Dialogs

- **Add Task dialog** — opened via the + FAB. Text field for name, "Add multiple" toggle, "Inbox" checkbox (root level only, default ON), pin toggle (only when Today's 5 exists and pin slots available). Pin label: "Pin" at root level, "Pin for today" inside a task. Only leaf tasks can appear in Today's 5 — non-leaf tasks are never pinned.
- **"This task is pinned" warning dialog** — appears when tapping the + FAB on a task that is pinned in Today's 5. Title: "This task is pinned", body: explains adding a subtask will replace the pinned task with the new subtask. Buttons: "Cancel" / "Add anyway". Shown before the Add Task dialog opens.
- **Schedule dialog** — opened via the calendar icon on a task card or leaf detail. Has deadline picker (date + "Due by"/"On" toggle), recurrence settings.
- **Remove deadline dialog** — appears when tapping "Done today" on a task with a deadline. Title: "Remove deadline?", body shows deadline type and date, buttons: "Keep" / "Remove". Dismissing (tap outside) cancels the action entirely.

## Common Patterns

- **Snackbar** — appears at bottom after actions. May include "Undo" button (5s timeout) and close icon.
- **Archive screen** — accessed via the archive icon in the app bar. Shows completed and skipped tasks.
- **Search** — magnifying glass icon in All Tasks app bar. Opens a task picker dialog.
