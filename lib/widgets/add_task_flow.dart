import 'package:flutter/material.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../utils/display_utils.dart';
import 'add_task_dialog.dart';
import 'brain_dump_dialog.dart';

/// Shared, reusable "add task(s)" flow used by any screen that lets the user
/// create children of some parent (the All Tasks list, the Starred expanded
/// dialog, and any future caller).
///
/// It encapsulates everything that used to be copy-pasted per screen:
///   * the optional "this parent is pinned in Today's 5" warning,
///   * the [AddTaskDialog] → [SingleTask] / [SwitchToBrainDump] branch,
///   * [BrainDumpDialog] for bulk add,
///   * Today's 5 pin-on-add handling.
///
/// Manual Today's 5 model: adding a subtask to a task that is pinned in
/// Today's 5 makes it a non-leaf parent, so it simply drops out of Today's 5
/// on the next refresh. The pin is NOT auto-transferred to a child — the user
/// curates Today's 5 explicitly. [parentIsPinned] only drives the heads-up
/// warning, not any pin mutation.
///
/// Task *creation* is delegated back to the caller via [addSingle] / [addBatch]
/// so each screen keeps control of parenting (current-navigation parent vs an
/// explicit parent with `atRoot`). To add this flow to a new screen, construct
/// an [AddTaskFlow] with that screen's config and call [run].
class AddTaskFlow {
  const AddTaskFlow({
    required this.addSingle,
    required this.addBatch,
    this.parentId,
    this.parentName,
    this.parentIsPinned = false,
    this.showPinOption = false,
    this.showInboxOption = false,
    this.onTodaysFiveChanged,
    this.onProviderRefresh,
    this.onCompleted,
    this.announceBatchAdd = true,
  });

  /// Creates one task and returns its id. [deferNotify] mirrors
  /// `TaskProvider.addTask` — when true the provider skips its own refresh so
  /// the pin can be persisted first (then [onProviderRefresh] fires).
  final Future<int> Function({
    required String name,
    String? url,
    required bool isInbox,
    required bool deferNotify,
  }) addSingle;

  /// Creates many tasks at once and returns their ids in input order.
  final Future<List<int>> Function(List<String> names, {required bool isInbox})
      addBatch;

  /// Parent task id this flow adds under, when known. Parenting itself is
  /// handled by the caller's [addSingle]/[addBatch] closures; this is kept as
  /// context for callers and potential future use.
  final int? parentId;

  /// Parent task name, used only in the pinned-warning text.
  final String? parentName;

  /// Whether the parent is currently pinned in Today's 5. Drives the heads-up
  /// warning that adding a subtask will drop the parent out of Today's 5.
  final bool parentIsPinned;

  /// Whether to show the "Pin in Today's 5" toggle in [AddTaskDialog].
  final bool showPinOption;

  /// Whether to show the "Add to Inbox" toggle (root level only).
  final bool showInboxOption;

  /// Called after any Today's 5 mutation with the new state, so the screen can
  /// refresh its local mirrors (e.g. `_todaysFiveIds`) / pin indicators.
  final void Function(PinResult result)? onTodaysFiveChanged;

  /// Called (in a `finally`) after pin work on a single add that used
  /// `deferNotify`, so the provider always refreshes even if pinning throws.
  final Future<void> Function()? onProviderRefresh;

  /// Called once after tasks are created (and any pin work is done) so the
  /// screen can reload its list. Receives the number of tasks added.
  final Future<void> Function(int addedCount)? onCompleted;

  /// Whether to show the "Added N tasks" snackbar after a bulk add. Disable on
  /// screens where the add happens inside a dialog that covers the snackbar
  /// (e.g. the Starred expanded dialog) — there the in-place list refresh is
  /// the confirmation.
  final bool announceBatchAdd;

  /// Runs the full flow. Safe to abandon at any dialog (returns early).
  Future<void> run(BuildContext context) async {
    // Warn once, up front, if adding will displace a pinned parent. (Both
    // legacy call sites warned up front; this also collapses All Tasks'
    // previous double-warn on the brain-dump path into a single prompt.)
    if (parentIsPinned) {
      final proceed = await _confirmPinnedParent(context);
      if (proceed != true || !context.mounted) return;
    }

    final result = await showDialog<AddTaskResult>(
      context: context,
      builder: (_) => AddTaskDialog(
        showPinOption: showPinOption,
        showInboxOption: showInboxOption,
      ),
    );
    if (!context.mounted || result == null) return;

    if (result is SingleTask) {
      await _addOne(context, result);
    } else if (result is SwitchToBrainDump) {
      await _addMany(context, result.initialText);
    }
  }

  Future<bool?> _confirmPinnedParent(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This task is pinned'),
        content: Text(
          '"${parentName ?? 'This task'}" is pinned in your Today\'s 5. '
          'Adding a subtask makes it a parent, so it will drop out of '
          'Today\'s 5.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add anyway'),
          ),
        ],
      ),
    );
  }

  Future<void> _addOne(BuildContext context, SingleTask result) async {
    // Defer the provider notify when we pin the new task, so refreshSnapshots()
    // doesn't overwrite the pin before it's persisted. A pinned parent going
    // non-leaf needs no pin write here — it drops out of Today's 5 on refresh.
    final needsPin = result.pinInTodays5;
    final id = await addSingle(
      name: result.name,
      url: result.url,
      isInbox: result.addToInbox,
      deferNotify: needsPin,
    );
    if (needsPin) {
      try {
        final pinned = await _pinNewTask(id);
        if (!pinned && context.mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          showInfoSnackBar(
              context, "Couldn't pin — all Today's 5 slots are full");
        }
      } finally {
        await onProviderRefresh?.call();
      }
    }
    await onCompleted?.call(1);
  }

  Future<void> _addMany(BuildContext context, String initialText) async {
    final result = await showDialog<BrainDumpResult>(
      context: context,
      builder: (_) => BrainDumpDialog(
        initialText: initialText,
        showInboxOption: showInboxOption,
      ),
    );
    if (!context.mounted || result == null || result.names.isEmpty) return;

    await addBatch(result.names, isInbox: result.addToInbox);
    // Manual Today's 5 model: adding subtasks makes a pinned parent non-leaf,
    // so it drops out of Today's 5 on the next refresh. The pin is not
    // auto-transferred onto a child — the user curates Today's 5 explicitly.
    if (announceBatchAdd && context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, 'Added ${result.names.length} tasks');
    }
    await onCompleted?.call(result.names.length);
  }

  /// Pins a freshly created task into Today's 5 (load → compute → save).
  /// Returns false if it couldn't be pinned (all slots full) so the caller can
  /// surface the message without holding a [BuildContext] across the await.
  Future<bool> _pinNewTask(int taskId) async {
    final db = DatabaseHelper();
    final today = todayDateKey();
    final saved = await db.loadTodaysFiveState(today);
    if (saved == null) return true;

    final result = TodaysFivePinHelper.pinNewTask(saved, taskId);
    if (result == null) return false;

    await db.saveTodaysFiveState(
      date: today,
      taskIds: result.taskIds,
      completedIds: saved.completedIds,
      workedOnIds: saved.workedOnIds,
      pinnedIds: result.pinnedIds,
    );
    onTodaysFiveChanged?.call(result);
    return true;
  }
}
