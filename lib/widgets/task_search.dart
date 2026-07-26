import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';
import 'add_task_flow.dart';
import 'task_picker_dialog.dart';

/// Global task search, shared by all three tabs (Starred, Today's 5, All Tasks)
/// so the affordance behaves identically wherever it is tapped:
///
/// * searches every task (flat-mode [TaskPickerDialog], matching name + parent
///   names),
/// * selecting a result hands the task to [onSelected] — every caller opens it
///   in the All Tasks tab,
/// * an empty result offers "Create ..." named after the query, which runs the
///   shared root add flow ([showRootAddFromSearch]).
///
/// Search is a GLOBAL action, so creation always files at root (Inbox toggle
/// default on) regardless of which tab it was launched from or where the All
/// Tasks tab happens to be drilled into.
Future<void> showTaskSearch(
  BuildContext context, {
  required Future<void> Function(Task selected) onSelected,
  required void Function(String query) onCreateTask,
}) async {
  final data = await fetchSearchCandidates(context);
  if (data == null || !context.mounted) return;
  final (allTasks, parentNamesMap) = data;

  final selected = await showDialog<Task>(
    context: context,
    builder: (dialogCtx) => TaskPickerDialog(
      candidates: allTasks,
      title: 'Search tasks',
      parentNamesMap: parentNamesMap,
      // Empty results → offer to create a task named after the search term.
      onCreateTask: (name) {
        Navigator.of(dialogCtx).pop();
        onCreateTask(name);
      },
    ),
  );

  if (selected == null || !context.mounted) return;
  await onSelected(selected);
}

/// Fetches the search pool (all tasks + parent names) behind a modal spinner.
/// Returns null if the widget went away mid-fetch.
Future<(List<Task>, Map<int, List<String>>)?> fetchSearchCandidates(
  BuildContext context,
) async {
  final navigator = Navigator.of(context);
  final provider = context.read<TaskProvider>();
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    late List<Task> allTasks;
    late Map<int, List<String>> parentNamesMap;
    await Future.wait([
      provider.getAllTasks().then((v) => allTasks = v),
      provider.getParentNamesMap().then((v) => parentNamesMap = v),
    ]);
    return (allTasks, parentNamesMap);
  } finally {
    if (navigator.mounted) navigator.pop();
  }
}

/// Creates a task from an empty search result, named after the search term.
///
/// Always files at root (`atRoot: true`) with the Inbox toggle shown and
/// default-on — search is global, so the currently open task in All Tasks (a
/// provider-level, cross-tab value) must not capture the new task. The term
/// pre-fills the Add dialog so the user can tweak the name / options first.
///
/// Used by the Starred and Today's 5 tabs. (All Tasks routes its own
/// create-from-search through `_runAddFlow(atRoot: true)`, which additionally
/// handles the drilled-in parent case and the Inbox badge refresh.)
Future<void> showRootAddFromSearch(
  BuildContext context, {
  required String initialName,
  required void Function(Task existing) onOpenExisting,
  Future<void> Function()? onCompleted,
}) async {
  final provider = context.read<TaskProvider>();
  // Offer "Pin for today" only while a pin slot is free — the add lands at
  // root, so there is no pinned-parent case to suppress it for.
  final todaysFive =
      await DatabaseHelper().getTodaysFiveTaskAndPinIds(todayDateKey());
  if (!context.mounted) return;
  final showPin = todaysFive.pinnedIds.length < maxPins;
  try {
    // For the "already exists" suggestion: creation is at root, so there is no
    // parent to file a match under — tapping a match just opens it.
    final allTasks = await provider.getAllTasks();
    final parentNames = await provider.getParentNamesMap();
    if (!context.mounted) return;
    await AddTaskFlow(
      initialName: initialName,
      showInboxOption: true,
      showPinOption: showPin,
      existingTasks: allTasks,
      existingActionIcon: Icons.open_in_new,
      existingActionLabel: 'Open',
      existingParentNames: parentNames,
      onUseExisting: (existing) async => onOpenExisting(existing),
      addSingle:
          ({required name, url, required isInbox, required deferNotify}) =>
              provider.addTask(
                name,
                url: url,
                isInbox: isInbox,
                deferNotify: deferNotify,
                atRoot: true,
              ),
      addBatch: (names, {required isInbox}) =>
          provider.addTasksBatch(names, isInbox: isInbox, atRoot: true),
      onProviderRefresh: provider.refreshAfterMutation,
      onCompleted: (_) async => onCompleted?.call(),
    ).run(context);
  } catch (e) {
    // Fired un-awaited from the picker's "Create" callback, so a DB/sync throw
    // would otherwise escape to FlutterError.onError with the user just seeing
    // the dialog vanish.
    if (context.mounted) {
      showInfoSnackBar(context, "Couldn't add task — please retry");
    }
  }
}
