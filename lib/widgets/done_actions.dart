import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';
import 'completion_animation.dart';

/// The two ways a task can be ticked off, offered by every surface that can
/// complete a task (the All Tasks leaf detail, the Today's 5 sheet, and the
/// Starred expanded tree).
enum DoneChoice {
  /// Partial progress: stamps `last_worked_at` so the task resurfaces later.
  today,

  /// Permanent completion: stamps `completed_at` and archives the task.
  forGood,
}

/// A completed "done" action, and the means to reverse it.
///
/// The undo snackbar uses [undo] itself, but a caller that keeps ticked-off
/// rows on screen after the snackbar has gone needs to reverse the action later
/// — and doing that by hand is easy to get wrong. Reversing a "Done for good!"
/// means restoring the dependency links that completing the task removed;
/// reversing a "Done today" means restoring the previous `last_worked_at` and
/// unstarting the task if the mark auto-started it. [undo] closes over all of
/// that, so callers never reconstruct it.
class DoneOutcome {
  const DoneOutcome({required this.choice, required this.undo});

  final DoneChoice choice;

  /// Reverses the action. Safe to call once; calling it again is a no-op at the
  /// database level but will re-fire the caller's `onChanged`.
  final Future<void> Function() undo;
}

/// Marks [cachedTask] as worked on today, with the deadline prompt, the
/// celebratory animation and an undo snackbar. Only its id is relied on: the
/// task is read from the database first.
///
/// Returns the [DoneOutcome] when the task was marked, or null when the user
/// cancelled at the deadline prompt or the widget went away mid-flow.
///
/// [navigateBack] pops the All Tasks navigation stack after marking — correct
/// when the caller is showing the task's own detail page, wrong when the caller
/// is a list or a dialog that stays open, so it defaults to false.
///
/// [onChanged] is awaited after the mark lands and again after an undo, so a
/// caller
/// holding its own session state (which rows to strike through, for instance)
/// can re-render. It is passed true when the task is marked, false on undo.
Future<DoneOutcome?> markTaskDoneToday(
  BuildContext context,
  Task cachedTask, {
  bool navigateBack = false,
  Future<void> Function(bool isDone)? onChanged,
}) async {
  final provider = context.read<TaskProvider>();
  // CR-fix I-58: the values the undo restores were read from the caller's Task.
  // The Starred dialog keeps that Task across reloads, so after a "Done today"
  // and its undo it still held the marked copy: started, with today's
  // last_worked_at. A second mark then skipped the auto-start, and its undo
  // restored today's timestamp, leaving the task worked on today. Reading the
  // task from the database here makes every mark start from its real state.
  final task = await provider.getTaskById(cachedTask.id!) ?? cachedTask;
  if (!context.mounted) return null;
  final previousLastWorkedAt = task.lastWorkedAt;
  final wasStarted = task.isStarted;

  // If the task has its own deadline, ask whether to remove it.
  // null = cancelled (dismiss/back) → abort the whole "Done today" action.
  bool removeDeadline = false;
  if (task.hasDeadline) {
    final result = await askRemoveDeadlineOnDone(
      context,
      task.deadline!,
      task.deadlineType,
    );
    if (!context.mounted) return null;
    if (result == null) return null; // user cancelled — abort
    removeDeadline = result;
  }

  await showCompletionAnimation(context);
  if (!context.mounted) return null;

  if (navigateBack) {
    await provider.markWorkedOnAndNavigateBack(task.id!, alsoStart: !wasStarted);
  } else {
    await provider.markWorkedOn(task.id!);
    if (!wasStarted) await provider.startTask(task.id!);
  }
  if (removeDeadline) {
    await provider.updateTaskDeadline(task.id!, null);
  }
  await onChanged?.call(true);

  final outcome = DoneOutcome(
    choice: DoneChoice.today,
    undo: () async {
      await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
      if (!wasStarted) await provider.unstartTask(task.id!);
      if (removeDeadline) {
        await provider.updateTaskDeadline(
          task.id!,
          task.deadline!,
          deadlineType: task.deadlineType,
        );
      }
      await onChanged?.call(false);
    },
  );

  if (!context.mounted) return outcome;
  ScaffoldMessenger.of(context).clearSnackBars();
  showInfoSnackBar(context, '"${task.name}" — nice work!', onUndo: outcome.undo);
  return outcome;
}

/// Completes [task] for good, after confirming with the user when doing so
/// would unblock dependents. Shows the celebratory animation and an undo
/// snackbar.
///
/// Returns the [DoneOutcome] when the task was completed, or null when the user
/// declined the unblock confirmation or the widget went away mid-flow.
///
/// [navigateBack] uses `TaskProvider.completeTask`, which pops the All Tasks
/// navigation stack — correct only when the caller is showing the task's own
/// detail page. Callers that stay put (a list, a dialog) leave it false and get
/// `completeTaskOnly`, which mutates without touching navigation.
///
/// [onChanged] fires after completion and again after an undo, passed true when
/// the task is completed and false on undo.
Future<DoneOutcome?> completeTaskForGood(
  BuildContext context,
  Task task, {
  bool navigateBack = false,
  Future<void> Function(bool isDone)? onChanged,
}) async {
  final provider = context.read<TaskProvider>();

  // Completing a task drops the dependency links it was blocking, so anything
  // waiting on it becomes actionable — confirm before that happens.
  final dependentNames = await provider.getDependentTaskNames(task.id!);
  if (!context.mounted) return null;
  if (!await confirmDependentUnblock(context, task.name, dependentNames)) {
    return null;
  }
  if (!context.mounted) return null;

  await showCompletionAnimation(context);
  if (!context.mounted) return null;

  final removedDeps = navigateBack
      ? (await provider.completeTask(task.id!)).removedDeps
      : await provider.completeTaskOnly(task.id!);
  await onChanged?.call(true);

  final outcome = DoneOutcome(
    choice: DoneChoice.forGood,
    undo: () async {
      await provider.uncompleteTask(task.id!, restoredDeps: removedDeps);
      // CR-fix I-59: a parent completed while this task was done stays
      // archived, and the restored task stayed listed under it, where no
      // screen shows it. Drop those links, as restoring from the Completed
      // screen does; with no active parent left, the task returns to the top
      // level.
      final archivedParents = await provider.getArchivedParents(task.id!);
      if (archivedParents.isNotEmpty) {
        await provider.removeArchivedParentLinks(task.id!, archivedParents);
      }
      await onChanged?.call(false);
    },
  );

  if (!context.mounted) return outcome;
  ScaffoldMessenger.of(context).clearSnackBars();
  showInfoSnackBar(
    context,
    '"${task.name}" done for good!',
    onUndo: outcome.undo,
  );
  return outcome;
}
