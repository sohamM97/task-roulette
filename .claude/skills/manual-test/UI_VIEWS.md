# UI Views Reference

Reference for manual test instructions. Use these names consistently.

## Navigation

- **Bottom nav bar** — 3 tabs: "Today", "Starred", "All Tasks". Swiping also switches tabs.

## Tabs

### Today tab (Today's 5)
- **Task card** — each task in the Today's 5 list. Shows task name, subtitle icons (priority, deadline, scheduled today, started, someday). Done tasks are faded with strikethrough. Trailing icons: pin button, swap button, "Go to task" link.
- **Bottom sheet** — appears when **tapping** an undone task card. Options: "Done today", "Done for good!", "In progress"/"Stop working". Note: Pin/Unpin is NOT in the bottom sheet — it's a separate pin icon button on the card itself.
- **Completion animation** — brief celebration overlay after marking done.
- **"Also done today" section** — expandable area below the main list showing tasks worked on today outside the Today's 5 set.
- **Progress ring** — circular progress indicator at top showing done/total.

### Starred tab
- **Starred task list** — flat list of starred tasks.

### All Tasks tab
- **Task card** — grid card for each task. Shows task name, top-left indicator icons (Today's 5, worked-on, started, priority, someday, deadline, scheduled today, starred). **Tap** navigates into the task. **Long-press** opens a context menu (delete, rename, move, schedule, etc.).
- **Task list** — hierarchical list. Shows children of the current parent. Root level shows top-level tasks + Inbox.
- **Inbox section** — collapsible section at top showing unorganized tasks.
- **Leaf detail view** — appears when navigating into a leaf task (a task with no children). Shows task name, "Done today" button, "Done for good!" button, "Start"/"Started" toggle, priority selector, schedule/deadline info, dependencies, parent breadcrumbs. This is NOT the same as the Today's 5 bottom sheet.
  - **"Do after..." icon (add_task)** — shown when the task has **no** dependency. **Tap** opens the "Do X after..." picker dialog to add a dependency.
  - **Dependency icon (hourglass)** — replaces the "Do after..." icon when the task has a dependency. **Tap** navigates to the blocker task. **Long-press** opens the "Do X after..." picker dialog to change or remove the dependency. Color behavior: **primary color** when actively blocked, **greyed out** when the blocker is no longer blocking (e.g. marked "Done today"). When the blocker is completed ("Done for good") or skipped, the dependency row is deleted from the DB, so the hourglass **disappears entirely**.
- **"Done today" button** — filled purple button on the leaf detail view. Marks the task as worked on.
- **"Worked on today" button** — outlined button that replaces "Done today" after marking. Acts as undo for the worked-on status.

## Dialogs

- **Add Task dialog** — opened via the + FAB. Text field for name, "Add multiple" toggle, "Inbox" checkbox.
- **Schedule dialog** — opened via the calendar icon on a task card or leaf detail. Has deadline picker (date + "Due by"/"On" toggle), recurrence settings.
- **Remove deadline dialog** — appears when tapping "Done today" on a task with a deadline. Title: "Remove deadline?", body shows deadline type and date, buttons: "Keep" / "Remove". Dismissing (tap outside) cancels the action entirely.

## Common Patterns

- **Snackbar** — appears at bottom after actions. May include "Undo" button (5s timeout) and close icon.
- **Archive screen** — accessed via the archive icon in the app bar. Shows completed and skipped tasks.
- **Search** — magnifying glass icon in All Tasks app bar. Opens a task picker dialog.
