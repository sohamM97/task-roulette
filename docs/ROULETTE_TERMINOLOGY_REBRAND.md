# Roulette Terminology Rebrand Reference

This document records the old → new terminology changes for the roulette theming rebrand.
Use this as a revert reference if needed.

## String Changes

| File | Old Text | New Text |
|------|----------|----------|
| `random_result_dialog.dart` | `'Random Pick'` | `'Lucky Pick'` |
| `random_result_dialog.dart` | `'Pick Another'` (tooltip) | `'Spin Again'` |
| `todays_five_screen.dart` | `'All tasks are done or pinned — nothing to replace.'` | `'...nothing to reroll.'` |
| `todays_five_screen.dart` | `'Replace N undone tasks with new picks? Done and pinned tasks will stay.'` | `'Reroll N undone tasks? Done and pinned tasks will stay.'` |
| `todays_five_screen.dart` | `'Replace all tasks with a fresh set of 5?'` | `'Reroll all tasks with a fresh set of 5?'` |
| `todays_five_screen.dart` | `'Replace N undone tasks with new picks? Done tasks will stay.'` | `'Reroll N undone tasks? Done tasks will stay.'` |
| `todays_five_screen.dart` | `'New set?'` (dialog title) | `'Reroll all?'` |
| `todays_five_screen.dart` | `'Replace'` (dialog button) | `'Reroll'` (both new-set and pinned-task dialogs) |
| `todays_five_screen.dart` | `'Random replacement'` | `'Roulette spin'` |
| `todays_five_screen.dart` | `'Replace with a randomly picked task'` | `'Spin the wheel for a new task'` |
| `todays_five_screen.dart` | `'Choose a task'` | `'Place your bet'` |
| `todays_five_screen.dart` | `'Pick a specific task for this slot'` | `'Hand-pick a task for this slot'` |
| `todays_five_screen.dart` | `'Replace pinned task?'` | `'Reroll pinned task?'` |
| `todays_five_screen.dart` | `'"X" was manually pinned. Replace it with a random task?'` | `'"X" was manually pinned. Reroll this slot?'` |
| `todays_five_screen.dart` | `'No other tasks available to pick'` | `'No tasks left to spin'` |
| `todays_five_screen.dart` | `'Pick a task'` (TaskPickerDialog title) | `'Place your bet'` |
| `todays_five_screen.dart` | `'No other tasks to swap in'` | `'No tasks left to spin'` |
| `todays_five_screen.dart` | `'New set'` (tooltip) | `'Reroll all'` |
| `todays_five_screen.dart` | `'Swap task'` (tooltip) | `'Spin'` |
| `task_list_screen.dart` | `'No tasks to pick from'` | `'No tasks to spin'` |

## Icon Changes

| File | Old Icon | New Icon |
|------|----------|----------|
| Per-task spin (3 locations via `spinIcon`) | `Icons.shuffle` | `Icons.loop` (DRY: `spinIcon` in `display_utils.dart`) |
| "Reroll all" button (app bar) | `Icons.refresh` | `Icons.casino_outlined` |
| All Tasks FAB (random pick) | `Icons.shuffle` | `Icons.flare` |

## Unchanged (Intentionally Kept)

| Item | Reason |
|------|--------|
| `'Go Deeper'` tooltip | Navigation action, not random-selection |
| `'Go to Task'` button | Navigation action |
| `TaskPickerDialog` default title `'Select a task'` | Generic widget used in non-roulette contexts (dependencies, move, link) |
| Internal variable/method names (`pickRandom`, `_swapTask`, etc.) | Not user-visible |
| `RandomResultAction` enum values | Internal API |
