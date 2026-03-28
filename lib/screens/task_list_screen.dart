import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../models/task_schedule.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/brain_dump_dialog.dart';
import '../widgets/completion_animation.dart';
import '../widgets/empty_state.dart';
import '../widgets/leaf_task_detail.dart';
import '../widgets/random_result_dialog.dart';
import '../widgets/task_card.dart';
import '../utils/display_utils.dart';
import '../widgets/delete_task_dialog.dart';
import '../widgets/schedule_dialog.dart';
import '../widgets/task_picker_dialog.dart';
import '../widgets/triage_dialog.dart';
import '../services/backup_service.dart';
import '../widgets/profile_icon.dart';
import 'completed_tasks_screen.dart';
import 'dag_view_screen.dart';

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => TaskListScreenState();
}

class TaskListScreenState extends State<TaskListScreen>
    with AutomaticKeepAliveClientMixin {
  // Cached deps Future for the leaf detail view — avoids recreating on every
  // Consumer rebuild. Invalidated when dependency mutations occur.
  int? _leafDepsTaskId;
  Future<List<Task>>? _leafDepsFuture;

  // Pre-mutation lastWorkedAt values, keyed by task ID.
  // Used by the leaf detail's "Worked on today" undo button.
  final Map<int, int?> _preWorkedOnTimestamps = {};

  /// IDs of tasks currently in Today's 5 (for card indicators, pin gating, sort).
  Set<int> _todaysFiveIds = {};

  // Cached Today's 5 pinned IDs — loaded lazily for the leaf detail pin icon.
  Set<int>? _todays5PinnedIds;

  // Inbox state
  int _inboxCount = 0;
  List<Task>? _inboxTasks;
  bool _inboxExpanded = true;

  @override
  bool get wantKeepAlive => true;

  TaskProvider? _providerRef;

  @override
  void initState() {
    super.initState();
    // Don't call loadRootTasks() here — it's called from AppShell.initState.
    // Calling it here would overwrite navigateToTask() state when PageView
    // lazily builds this screen for the first time.
    loadTodaysFiveIds();
    _loadInboxCount();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<TaskProvider>();
    if (_providerRef != provider) {
      _providerRef?.removeListener(_onProviderChanged);
      _providerRef = provider;
      provider.addListener(_onProviderChanged);
    }
  }

  @override
  void dispose() {
    _providerRef?.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    // Clear stale undo data — snackbars are dismissed on navigation anyway.
    _preWorkedOnTimestamps.clear();

    // Refresh inbox when returning to root after mutations (e.g. complete/delete
    // an inbox task from its leaf view). Without this, the cached _inboxTasks
    // list shows stale entries.
    final provider = _providerRef;
    if (provider != null && provider.isRoot) {
      _loadInboxTasks();
    }
  }

  Future<void> loadTodaysFiveIds() async {
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final result = await DatabaseHelper().getTodaysFiveTaskAndPinIds(today);
    if (!mounted) return;
    setState(() {
      _todaysFiveIds = result.taskIds;
      _todays5PinnedIds = result.pinnedIds;
    });
  }

  Future<void> _togglePinInTodays5(int taskId) async {
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final db = DatabaseHelper();
    final saved = await db.loadTodaysFiveState(today);
    if (saved == null) return;

    final result = TodaysFivePinHelper.togglePin(saved, taskId);
    if (result == null) {
      // Blocked — max pins reached
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Max 5 pinned tasks — unpin one first');
      }
      return;
    }

    await db.saveTodaysFiveState(
      date: today,
      taskIds: result.taskIds,
      completedIds: saved.completedIds,
      workedOnIds: saved.workedOnIds,
      pinnedIds: result.pinnedIds,
    );
    if (mounted) {
      setState(() {
        _todaysFiveIds = result.taskIds.toSet();
        _todays5PinnedIds = result.pinnedIds;
      });
    }
  }

  Future<void> _loadInboxCount() async {
    final provider = context.read<TaskProvider>();
    final count = await provider.getInboxCount();
    if (!mounted) return;
    if (count > 0) {
      // Eagerly load tasks so the section renders immediately
      final tasks = await provider.getInboxTasks();
      if (!mounted) return;
      setState(() {
        _inboxCount = tasks.length;
        _inboxTasks = tasks;
      });
    } else {
      setState(() {
        _inboxCount = 0;
        _inboxTasks = null;
      });
    }
  }

  Future<void> _loadInboxTasks() async {
    final provider = context.read<TaskProvider>();
    final tasks = await provider.getInboxTasks();
    if (!mounted) return;
    setState(() {
      _inboxTasks = tasks;
      _inboxCount = tasks.length;
    });
  }

  Future<void> _fileTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final result = await showDialog<TriageResult>(
      context: context,
      builder: (_) => TriageDialog(
        task: task,
        provider: provider,
      ),
    );
    if (result == null || !mounted) return;

    if (result.keepAtTopLevel) {
      await _dismissFromInbox(task);
      return;
    }

    if (result.parent != null) {
      final parentId = result.parent!.id!;
      final success = await provider.fileTask(task.id!, parentId);
      if (!mounted) return;
      if (success) {
        await _loadInboxTasks();
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Filed "${task.name}" under "${result.parent!.name}"', onUndo: () async {
          await provider.unfileTask(task.id!, parentId);
          if (mounted) await _loadInboxTasks();
        });
      } else {
        showInfoSnackBar(context, 'Cannot file: would create a cycle');
      }
    }
  }

  Future<void> _dismissFromInbox(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.dismissFromInbox(task.id!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, 'Kept "${task.name}" at top level', onUndo: () async {
      await provider.undoDismissFromInbox(task.id!);
      if (mounted) await _loadInboxTasks();
    });
    await _loadInboxTasks();
  }

  Future<void> _fileAll() async {
    if (_inboxTasks == null || _inboxTasks!.isEmpty) return;
    final provider = context.read<TaskProvider>();
    // Iterative loop instead of recursion to avoid deep call stacks
    while (_inboxTasks != null && _inboxTasks!.isNotEmpty && mounted) {
      final task = _inboxTasks!.first;
      final remaining = _inboxTasks!.length - 1;
      if (!mounted) break;
      final result = await showDialog<TriageResult>(
        context: context,
        builder: (_) => TriageDialog(
          task: task,
          provider: provider,
          remainingCount: remaining,
        ),
      );
      if (result == null || !mounted) break; // user cancelled — stop batch

      if (result.keepAtTopLevel) {
        await provider.dismissFromInbox(task.id!);
      } else if (result.parent != null) {
        final success = await provider.fileTask(task.id!, result.parent!.id!);
        if (!mounted) break;
        if (!success) {
          showInfoSnackBar(context, 'Cannot file: would create a cycle');
          continue; // retry same task
        }
      }
      if (!mounted) break;
      await _loadInboxTasks();
    }
    // Show summary snackbar after batch completes
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      final remaining = _inboxTasks?.length ?? 0;
      if (remaining == 0) {
        showInfoSnackBar(context, 'Inbox cleared!');
      }
    }
  }

  /// Returns true if the user confirmed (or task isn't pinned), false to abort.
  Future<bool> _warnIfPinned({bool isBrainDump = false}) async {
    final provider = context.read<TaskProvider>();
    final currentParent = provider.currentParent;
    if (currentParent == null) return true;

    final pinnedIds = _todays5PinnedIds;
    if (pinnedIds == null || !pinnedIds.contains(currentParent.id)) return true;

    if (!mounted) return false;
    final message = isBrainDump
        ? '"${currentParent.name}" is in your Today\'s 5 and pinned. '
          'Adding subtasks will replace it with one of the new subtasks.'
        : '"${currentParent.name}" is in your Today\'s 5 and pinned. '
          'Adding a subtask will replace it with the new subtask.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This task is pinned'),
        content: Text(message),
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
    return confirmed == true;
  }

  Future<void> _addTask() async {
    if (!await _warnIfPinned()) return;
    if (!mounted) return;
    final provider = context.read<TaskProvider>();
    final parentId = provider.currentParent?.id;
    final parentIsPinned = parentId != null &&
        (_todays5PinnedIds?.contains(parentId) ?? false);
    // Hide "Pin for today" when parent is pinned — the pin will auto-transfer
    // to the new subtask, so the option is misleading.
    final showPin = !parentIsPinned && _todaysFiveIds.isNotEmpty &&
        (_todays5PinnedIds?.length ?? 0) < maxPins;
    final result = await showDialog<AddTaskResult>(
      context: context,
      builder: (_) => AddTaskDialog(showPinOption: showPin, showInboxOption: provider.isRoot),
    );
    if (!mounted || result == null) return;
    if (result is SingleTask) {
      final taskId = await provider.addTask(result.name, url: result.url, isInbox: result.addToInbox);
      if (result.pinInTodays5 && mounted) {
        await _pinNewTaskInTodays5(taskId);
      } else if (parentIsPinned && mounted) {
        // Parent was pinned in Today's 5 and just became non-leaf —
        // eagerly transfer the pin to the new subtask so the pin icon
        // appears immediately without waiting for a tab switch.
        await _transferPinToChild(parentId, taskId);
      }
      if (provider.isRoot && mounted) await _loadInboxCount();
    } else if (result is SwitchToBrainDump) {
      await _brainDump(initialText: result.initialText);
    }
  }

  /// Transfers a pin from a parent that just became non-leaf to its new child
  /// in Today's 5 state. Called eagerly after adding a subtask to a pinned
  /// parent so the pin icon appears immediately on the child's card.
  Future<void> _transferPinToChild(int parentId, int childId) async {
    final today = todayDateKey();
    final db = DatabaseHelper();
    final saved = await db.loadTodaysFiveState(today);
    if (saved == null) return;

    final taskIds = List<int>.from(saved.taskIds);
    final pinnedIds = Set<int>.from(saved.pinnedIds);

    final parentIdx = taskIds.indexOf(parentId);
    if (parentIdx < 0) return;

    // Replace parent with child in the list, transfer pin
    taskIds[parentIdx] = childId;
    if (pinnedIds.remove(parentId)) {
      pinnedIds.add(childId);
    }

    await db.saveTodaysFiveState(
      date: today,
      taskIds: taskIds,
      completedIds: saved.completedIds,
      workedOnIds: saved.workedOnIds,
      pinnedIds: pinnedIds,
    );
    if (mounted) {
      setState(() {
        _todaysFiveIds = taskIds.toSet();
        _todays5PinnedIds = pinnedIds;
      });
    }
  }

  /// Adds a newly created task to Today's 5 (replacing an unpinned undone slot)
  /// and pins it.
  Future<void> _pinNewTaskInTodays5(int taskId) async {
    final today = todayDateKey();
    final db = DatabaseHelper();
    final saved = await db.loadTodaysFiveState(today);
    if (saved == null) return;

    final result = TodaysFivePinHelper.pinNewTask(saved, taskId);
    if (result == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Couldn\'t pin — all Today\'s 5 slots are full');
      }
      return;
    }

    await db.saveTodaysFiveState(
      date: today,
      taskIds: result.taskIds,
      completedIds: saved.completedIds,
      workedOnIds: saved.workedOnIds,
      pinnedIds: result.pinnedIds,
    );
    if (mounted) {
      setState(() {
        _todaysFiveIds = result.taskIds.toSet();
        _todays5PinnedIds = result.pinnedIds;
      });
    }
  }

  Future<void> _brainDump({String initialText = ''}) async {
    if (!await _warnIfPinned(isBrainDump: true)) return;
    if (!mounted) return;
    final provider = context.read<TaskProvider>();
    final parentId = provider.currentParent?.id;
    final parentIsPinned = parentId != null &&
        (_todays5PinnedIds?.contains(parentId) ?? false);
    final result = await showDialog<BrainDumpResult>(
      context: context,
      builder: (_) => BrainDumpDialog(initialText: initialText, showInboxOption: provider.isRoot),
    );
    if (result != null && result.names.isNotEmpty && mounted) {
      final names = result.names;
      final beforeIds = provider.tasks.map((t) => t.id!).toSet();
      await provider.addTasksBatch(names, isInbox: result.addToInbox);
      if (parentIsPinned && mounted) {
        // Pick one of the NEW subtasks to inherit the pin (not pre-existing children)
        final newChildren = provider.tasks.where((t) => !beforeIds.contains(t.id)).toList();
        if (newChildren.isNotEmpty) {
          final picked = provider.pickWeightedN(newChildren, 1);
          if (picked.isNotEmpty) {
            await _transferPinToChild(parentId, picked.first.id!);
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Added ${names.length} tasks');
      }
      if (provider.isRoot && mounted) await _loadInboxCount();
    }
  }

  /// Fetches allTasks and parentNamesMap concurrently.
  Future<(List<Task>, Map<int, List<String>>)> _fetchCandidateData() async {
    // Show a brief loading indicator while fetching task data for picker dialogs.
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final provider = context.read<TaskProvider>();
      late List<Task> allTasks;
      late Map<int, List<String>> parentNamesMap;
      await Future.wait([
        provider.getAllTasks().then((v) => allTasks = v),
        provider.getParentNamesMap().then((v) => parentNamesMap = v),
      ]);
      return (allTasks, parentNamesMap);
    } finally {
      if (mounted) navigator.pop();
    }
  }

  Future<void> _linkExistingTask() async {
    if (!await _warnIfPinned()) return;
    if (!mounted) return;
    final provider = context.read<TaskProvider>();
    final currentParent = provider.currentParent;
    if (currentParent == null) return;

    final (allTasks, parentNamesMap) = await _fetchCandidateData();
    final existingChildIds = await provider.getChildIds(currentParent.id!);
    final existingChildIdSet = existingChildIds.toSet();

    // Filter out: the current task itself, its existing children
    final candidates = allTasks.where((t) {
      if (t.id == currentParent.id) return false;
      if (existingChildIdSet.contains(t.id)) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Add task under "${currentParent.name}"',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.linkChildToCurrent(selected.id!);
    if (!success && mounted) {
      showInfoSnackBar(context, 'Cannot link: would create a cycle');
    }
  }

  Future<void> _addParentToTask(Task task) async {
    final provider = context.read<TaskProvider>();

    final (allTasks, parentNamesMap) = await _fetchCandidateData();
    final existingParentIds = await provider.getParentIds(task.id!);
    final existingParentIdSet = existingParentIds.toSet();

    // Filter out: the task itself, its existing parents
    final candidates = allTasks.where((t) {
      if (t.id == task.id) return false;
      if (existingParentIdSet.contains(t.id)) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .where((id) => id != task.id)
        .toSet();

    // Parent's siblings: grandparent's children minus the current parent
    var parentSiblingIds = <int>{};
    final currentParent = provider.currentParent;
    if (currentParent != null) {
      final grandparentIds = await provider.getParentIds(currentParent.id!);
      parentSiblingIds = await provider.getChildIdsForParents(grandparentIds);
      // If parent is a root task, other root tasks are its siblings
      if (grandparentIds.isEmpty) {
        final rootTasks = await provider.getRootTaskIds();
        parentSiblingIds.addAll(rootTasks);
      }
      parentSiblingIds.remove(currentParent.id);
      // Don't include tasks already in siblings or the task itself
      parentSiblingIds.removeAll(siblingIds);
      parentSiblingIds.remove(task.id);
    }

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Also show "${task.name}" under...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
        secondaryPriorityIds: parentSiblingIds,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.addParentToTask(task.id!, selected.id!);
    if (!success && mounted) {
      showInfoSnackBar(context, 'Cannot link: would create a cycle');
    }
  }

  Future<void> _renameTask(Task task) async {
    final controller = TextEditingController(text: task.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 500,
          decoration: const InputDecoration(
            hintText: 'Task name',
            counterText: '',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != task.name && mounted) {
      await context.read<TaskProvider>().renameTask(task.id!, newName);
    }
  }

  Future<void> _updateUrl(Task task, String? url) async {
    await context.read<TaskProvider>().updateTaskUrl(task.id!, url);
  }

  Future<void> _updatePriority(Task task, int priority) async {
    await context.read<TaskProvider>().updateTaskPriority(task.id!, priority);
  }

  Future<void> _updateSomeday(Task task, bool isSomeday) async {
    await context.read<TaskProvider>().updateTaskSomeday(task.id!, isSomeday);
  }

  Future<void> _updateStarred(Task task, bool isStarred) async {
    await context.read<TaskProvider>().updateTaskStarred(task.id!, isStarred);
  }

  Future<void> _workedOn(Task task) async {
    final provider = context.read<TaskProvider>();
    final previousLastWorkedAt = task.lastWorkedAt;
    final wasStarted = task.isStarted;
    _preWorkedOnTimestamps[task.id!] = previousLastWorkedAt;
    // If the task has its own deadline, ask whether to remove it.
    // null = cancelled (dismiss/back) → abort the whole "Done today" action.
    final hadDeadline = task.hasDeadline;
    bool removeDeadline = false;
    if (hadDeadline) {
      final result = await askRemoveDeadlineOnDone(context, task.deadline!, task.deadlineType);
      if (!mounted) return;
      if (result == null) return; // user cancelled — abort
      removeDeadline = result;
    }
    await showCompletionAnimation(context);
    if (!mounted) return;
    await provider.markWorkedOnAndNavigateBack(
      task.id!,
      alsoStart: !task.isStarted,
    );
    if (removeDeadline) {
      await provider.updateTaskDeadline(task.id!, null);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — nice work!', onUndo: () async {
      await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
      if (!wasStarted) await provider.unstartTask(task.id!);
      if (removeDeadline) {
        await provider.updateTaskDeadline(task.id!, task.deadline!, deadlineType: task.deadlineType);
      }
    });
  }

  Future<void> _moveTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final currentParent = provider.currentParent;
    if (currentParent == null) return;

    final (allTasks, parentNamesMap) = await _fetchCandidateData();
    final existingParentIds = (await provider.getParentIds(task.id!)).toSet();

    // Filter out: the task itself, all existing parents (including current)
    final candidates = allTasks.where((t) {
      if (t.id == task.id) return false;
      if (existingParentIds.contains(t.id)) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .where((id) => id != task.id && id != currentParent.id)
        .toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Move "${task.name}" to...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.moveTask(task.id!, selected.id!);
    if (!success && mounted) {
      showInfoSnackBar(context, 'Cannot move: would create a cycle');
    }
  }

  Future<void> _unlinkTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final parentIds = await provider.getParentIds(task.id!);

    if (parentIds.length <= 1) {
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Move to top level?'),
          content: Text(
            '"${task.name}" is only listed here. '
            'Removing it will move it to the top level.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Move to top level'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    await provider.unlinkFromCurrentParent(task.id!);
  }

  void _showDeleteUndoSnackbar(String description, VoidCallback onUndo) {
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, description, onUndo: onUndo);
  }

  Future<void> _deleteTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();
    final isDeletingCurrentParent = task.id == provider.currentParent?.id;
    final hasKids = await provider.hasChildren(task.id!);

    if (!hasKids) {
      // Leaf task — delete directly, no dialog
      final deleted = await provider.deleteTask(task.id!);
      if (isDeletingCurrentParent) await provider.navigateBack();
      if (!mounted) return;
      _showDeleteUndoSnackbar('Deleted "${task.name}"', () {
        provider.restoreTask(
          deleted.task, deleted.parentIds, deleted.childIds,
          dependsOnIds: deleted.dependsOnIds,
          dependedByIds: deleted.dependedByIds,
          schedules: deleted.schedules,
        );
      });
      return;
    }

    // Has children — show choice dialog
    if (!mounted) return;
    final choice = await showDialog<DeleteChoice>(
      context: context,
      builder: (_) => DeleteTaskDialog(taskName: task.name),
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case DeleteChoice.reparent:
        final result = await provider.deleteTaskAndReparent(task.id!);
        if (isDeletingCurrentParent) await provider.navigateBack();
        if (!mounted) return;
        _showDeleteUndoSnackbar('Deleted "${task.name}"', () {
          provider.restoreTask(
            result.task, result.parentIds, result.childIds,
            dependsOnIds: result.dependsOnIds,
            dependedByIds: result.dependedByIds,
            removeReparentLinks: result.addedReparentLinks,
            schedules: result.schedules,
          );
        });
      case DeleteChoice.deleteAll:
        final result = await provider.deleteTaskSubtree(task.id!);
        if (isDeletingCurrentParent) await provider.navigateBack();
        if (!mounted) return;
        final count = result.deletedTasks.length - 1;
        final desc = count > 0
            ? 'Deleted "${task.name}" and $count sub-task${count == 1 ? '' : 's'}'
            : 'Deleted "${task.name}"';
        _showDeleteUndoSnackbar(desc, () {
          provider.restoreTaskSubtree(
            tasks: result.deletedTasks,
            relationships: result.deletedRelationships,
            dependencies: result.deletedDependencies,
            schedules: result.deletedSchedules,
          );
        });
    }
  }

  Future<void> _toggleStarted(Task task) async {
    final provider = context.read<TaskProvider>();
    if (task.isStarted) {
      await provider.unstartTask(task.id!);
    } else {
      await provider.startTask(task.id!);
    }
  }

  Future<void> _skipTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();

    // Check if skipping this task will free any dependents — confirm first.
    final dependentNames = await provider.getDependentTaskNames(task.id!);
    if (!mounted) return;
    if (!await confirmDependentUnblock(context, task.name, dependentNames)) return;
    if (!mounted) return;

    final result = await provider.skipTask(task.id!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, 'Skipped "${task.name}"',
        onUndo: () => provider.unskipTask(task.id!, restoredDeps: result.removedDeps));
  }

  Future<void> _completeTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();

    // Check if completing this task will free any dependents — confirm first.
    final dependentNames = await provider.getDependentTaskNames(task.id!);
    if (!mounted) return;
    if (!await confirmDependentUnblock(context, task.name, dependentNames)) return;
    if (!mounted) return;

    // Show celebratory animation before completing
    await showCompletionAnimation(context);

    if (!mounted) return;

    final result = await provider.completeTask(task.id!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" done for good!',
        onUndo: () => provider.uncompleteTask(task.id!, restoredDeps: result.removedDeps));
  }

  Widget _buildLeafTaskDetail(TaskProvider provider) {
    final task = provider.currentParent!;
    // Reuse cached Future unless the task changed or deps were invalidated.
    if (_leafDepsTaskId != task.id) {
      _leafDepsTaskId = task.id;
      _leafDepsFuture = provider.getDependencies(task.id!);
    }
    final parentNames = provider.parentNamesMap[task.id] ?? [];
    return FutureBuilder<List<Task>>(
      future: _leafDepsFuture,
      builder: (context, snapshot) {
        final deps = snapshot.data ?? [];
        return LeafTaskDetail(
          task: task,
          onDone: () => _completeTaskWithUndo(task),
          onSkip: () => _skipTaskWithUndo(task),
          onToggleStarted: () => _toggleStarted(task),
          onRename: () => _renameTask(task),
          onUpdateUrl: (url) => _updateUrl(task, url),
          onUpdatePriority: (p) => _updatePriority(task, p),
          onUpdateSomeday: (s) => _updateSomeday(task, s),
          onWorkedOn: () => _workedOn(task),
          onUndoWorkedOn: () async {
            final provider = context.read<TaskProvider>();
            final restoreTo = _preWorkedOnTimestamps.remove(task.id!);
            await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
          },
          dependencies: deps,
          onAddDependency: () async {
            await _addDependencyToTask(task);
            _leafDepsTaskId = null; // invalidate — may have added a dep
          },
          onNavigateToDependency: (dep) async {
            await provider.navigateToTask(dep);
          },
          parentNames: parentNames,
          isPinnedInTodays5: _todays5PinnedIds?.contains(task.id) ?? false,
          atMaxPins: (_todays5PinnedIds?.length ?? 0) >= maxPins,
          onTogglePin: _todaysFiveIds.isNotEmpty
              ? () => _togglePinInTodays5(task.id!)
              : null,
          isBlocked: provider.blockedTaskIds.contains(task.id),
        );
      },
    );
  }

  Future<void> _searchTask() async {
    final provider = context.read<TaskProvider>();
    final (allTasks, parentNamesMap) = await _fetchCandidateData();

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: allTasks,
        title: 'Search tasks',
        parentNamesMap: parentNamesMap,
      ),
    );

    if (selected == null || !mounted) return;
    await provider.navigateToTask(selected);
  }

  Future<void> _pickRandom() async {
    final provider = context.read<TaskProvider>();
    final picked = provider.pickRandom();
    if (picked == null) {
      if (mounted) {
        showInfoSnackBar(context, 'No tasks to pick from');
      }
      return;
    }
    await _showRandomResult(picked);
  }

  Future<void> _showRandomResult(
    Task task, {
    Set<int>? excluded,
    /// The pool of siblings for Pick Another. When null, uses provider.tasks.
    /// Set by Go Deeper so Pick Another picks from the parent's children.
    List<Task>? siblingPool,
    /// The task to navigate into for Go to Task. When null, navigates into
    /// [task] itself. Set by Go Deeper so Go to Task enters the parent.
    Task? navigateTarget,
  }) async {
    final provider = context.read<TaskProvider>();
    final children = await provider.getChildren(task.id!);
    final childIds = children.map((c) => c.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(childIds);
    final eligible = children.where((c) => !blockedIds.contains(c.id)).toList();

    // Use explicit sibling pool (from Go Deeper) or current view's tasks
    final siblings = siblingPool ?? provider.tasks;
    final siblingIds = siblings.map((s) => s.id!).toList();
    final blockedSiblingIds = await provider.getBlockedChildIds(siblingIds);
    final allEligibleSiblings = siblings.where(
      (s) => s.id != task.id && !blockedSiblingIds.contains(s.id),
    ).toList();
    final eligibleSiblings = allEligibleSiblings.where(
      (s) => !(excluded?.contains(s.id) ?? false),
    ).toList();

    if (!mounted) return;

    final action = await showDialog<RandomResultAction>(
      context: context,
      builder: (_) => RandomResultDialog(
        task: task,
        hasChildren: eligible.isNotEmpty,
        // Show button if there are other siblings at all (pool replenishes)
        canPickAnother: allEligibleSiblings.isNotEmpty,
      ),
    );

    if (!mounted) return;

    switch (action) {
      case RandomResultAction.goDeeper:
        // Pick random from this task's children, pass children as sibling pool
        if (eligible.isNotEmpty) {
          final picked = provider.pickWeightedN(eligible, 1);
          if (picked.isNotEmpty) {
            if (!mounted) return;
            await _showRandomResult(
              picked.first,
              siblingPool: eligible,
              navigateTarget: task,
            );
          }
        }
      case RandomResultAction.goToTask:
        await provider.navigateInto(navigateTarget ?? task);
      case RandomResultAction.pickAnother:
        var newExcluded = {...?excluded, task.id!};
        var pool = eligibleSiblings;
        if (pool.isEmpty) {
          newExcluded = {task.id!};
          pool = siblings.where(
            (s) => s.id != task.id && !blockedSiblingIds.contains(s.id),
          ).toList();
        }
        if (pool.isNotEmpty) {
          final picked = provider.pickWeightedN(pool, 1);
          if (picked.isNotEmpty) {
            if (!mounted) return;
            await _showRandomResult(
              picked.first,
              excluded: newExcluded,
              siblingPool: siblingPool,
              navigateTarget: navigateTarget,
            );
          }
        }
      case null:
        break;
    }
  }

  Widget _buildInboxSection(TaskProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: () => setState(() => _inboxExpanded = !_inboxExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.inbox, size: 20, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Inbox ($_inboxCount)',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  if (_inboxExpanded && _inboxCount > 1)
                    GestureDetector(
                      onTap: _fileAll,
                      child: Text(
                        'File all',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  if (_inboxExpanded && _inboxCount > 1)
                    const SizedBox(width: 8),
                  Icon(
                    _inboxExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_inboxExpanded) ...[
            if (_inboxTasks == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ...(_inboxTasks!.map((task) {
                final cardColor = AppColors.cardColor(context, task.id ?? 0);
                final age = DateTime.now().difference(
                    DateTime.fromMillisecondsSinceEpoch(task.createdAt));
                final ageText = age.inDays > 0
                    ? '${age.inDays}d ago'
                    : age.inHours > 0
                        ? '${age.inHours}h ago'
                        : 'just now';
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  child: Material(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _fileTask(task),
                      onLongPress: () => provider.navigateInto(task),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    task.name,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    ageText,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 11,
                                      color: age.inDays >= 3
                                          ? colorScheme.error.withAlpha(180)
                                          : colorScheme.onSurfaceVariant.withAlpha(120),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: colorScheme.onSurfaceVariant.withAlpha(120),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              })),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildBreadcrumb(TaskProvider provider) {
    final crumbs = provider.breadcrumb;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(128),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < crumbs.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (i < crumbs.length - 1)
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => provider.navigateToLevel(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      crumbs[i] == null ? 'Task Roulette' : crumbs[i]!.name,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    crumbs[i]!.name,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addDependencyToTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final (allTasks, parentNamesMap) = await _fetchCandidateData();

    // Filter out: the task itself
    final candidates = allTasks.where((t) => t.id != task.id).toList();

    // Prioritize siblings (other tasks under the same parent).
    // On leaf view, provider.tasks is empty — look up siblings from the parent.
    Set<int> siblingIds;
    if (provider.tasks.isNotEmpty) {
      siblingIds = provider.tasks
          .map((t) => t.id!)
          .where((id) => id != task.id)
          .toSet();
    } else {
      // Leaf view: get siblings from the parent above
      final parentIds = await provider.getParentIds(task.id!);
      if (parentIds.isNotEmpty) {
        final siblings = await provider.getChildren(parentIds.first);
        siblingIds = siblings
            .map((t) => t.id!)
            .where((id) => id != task.id)
            .toSet();
      } else {
        siblingIds = {};
      }
    }

    // Check if task already has a dependency — show remove option if so
    final existingDeps = await provider.getDependencies(task.id!);

    if (!mounted) return;

    final colorScheme = Theme.of(context).colorScheme;
    // Use Object? so we can return either a Task or 'remove' sentinel
    final result = await showDialog<Object>(
      context: context,
      builder: (ctx) => TaskPickerDialog(
        candidates: candidates,
        title: 'Do "${task.name}" after...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
        headerAction: existingDeps.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => Navigator.pop(ctx, 'remove'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.link_off, size: 18,
                            color: colorScheme.error),
                        const SizedBox(width: 8),
                        // Bug fix: Text overflowed when blocker name was long.
                        // Expanded constrains the Text to remaining Row width
                        // so TextOverflow.ellipsis can truncate properly.
                        Expanded(
                          child: Text(
                            'Remove dependency on "${existingDeps.first.name}"',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.error),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : null,
      ),
    );

    if (result == null || !mounted) return;

    if (result == 'remove') {
      _leafDepsTaskId = null;
      await provider.removeDependency(task.id!, existingDeps.first.id!);
      return;
    }

    final selected = result as Task;
    final success = await provider.addDependency(task.id!, selected.id!);
    if (!success && mounted) {
      showInfoSnackBar(context, 'Cannot add: would create a cycle');
    }
  }

  Future<void> _editSchedule(Task task) async {
    final provider = context.read<TaskProvider>();
    final results = await Future.wait([
      provider.getSchedules(task.id!),
      provider.isScheduleOverride(task.id!),
      provider.getScheduleSources(task.id!),
      if (!task.hasDeadline) provider.getInheritedDeadline(task.id!),
    ]);
    if (!mounted) return;

    final current = results[0] as List<TaskSchedule>;
    final isOverrideFlag = results[1] as bool;
    final sources = results[2] as List<({int id, String name, Set<int> days})>;
    final inheritedDeadline = !task.hasDeadline && results.length > 3
        ? results[3] as ({String deadline, String deadlineType, String sourceName})?
        : null;
    final isOverride = current.isNotEmpty || isOverrideFlag;
    final inheritedDays = sources.fold<Set<int>>(
        {}, (acc, s) => acc..addAll(s.days));

    final result = await ScheduleDialog.show(
      context,
      taskId: task.id!,
      currentSchedules: current,
      inheritedDays: inheritedDays,
      isCurrentlyOverriding: isOverride,
      sources: sources,
      currentDeadline: task.deadline,
      currentDeadlineType: task.deadlineType,
      inheritedDeadline: inheritedDeadline,
    );
    if (result == null || !mounted) return;

    await provider.updateSchedules(task.id!, result.schedules,
        isOverride: result.isOverride);
    // Update deadline if changed (null = no change, empty string would clear)
    final deadlineType = result.deadlineType ?? task.deadlineType;
    if (result.deadline != null || result.deadlineType != null) {
      final newDeadline = result.deadline != null
          ? (result.deadline!.isEmpty ? null : result.deadline)
          : task.deadline;
      // Pin into Today's 5 BEFORE updating the deadline on the provider,
      // because updateTaskDeadline triggers notifyListeners → Today's 5
      // refreshSnapshots → _persist, which would overwrite our DB changes.
      String? deadlineSnackMessage;
      if (newDeadline != null) {
        final parsed = DateTime.tryParse(newDeadline);
        if (parsed != null) {
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final deadlineDay = DateTime(parsed.year, parsed.month, parsed.day);
          if (!deadlineDay.isAfter(today)) {
            final db = DatabaseHelper();
            final dateKey = todayDateKey();
            final saved = await db.loadTodaysFiveState(dateKey);
            final children = await db.getChildren(task.id!);
            final isLeaf = children.isEmpty;
            deadlineSnackMessage = 'Due today';
            if (isLeaf && saved == null) {
              await db.saveTodaysFiveState(
                date: dateKey,
                taskIds: [task.id!],
                completedIds: {},
                workedOnIds: {},
                pinnedIds: {task.id!},
              );
              await db.unsuppressDeadlineAutoPin(dateKey, task.id!);
              deadlineSnackMessage = 'Due today — pinned to Today\'s 5!';
            } else if (isLeaf && saved != null && !saved.taskIds.contains(task.id!)) {
              final pinResult = TodaysFivePinHelper.pinNewTask(saved, task.id!);
              if (pinResult != null) {
                await db.saveTodaysFiveState(
                  date: dateKey,
                  taskIds: pinResult.taskIds,
                  completedIds: saved.completedIds,
                  workedOnIds: saved.workedOnIds,
                  pinnedIds: pinResult.pinnedIds,
                );
                await db.unsuppressDeadlineAutoPin(dateKey, task.id!);
                deadlineSnackMessage = 'Due today — pinned to Today\'s 5!';
              } else {
                await db.suppressDeadlineAutoPin(dateKey, task.id!);
                deadlineSnackMessage = 'Due today — couldn\'t pin, all 5 pin slots are taken';
              }
            } else if (isLeaf && saved != null && saved.taskIds.contains(task.id!)) {
              // Bug fix: Previously just showed "already in Today's 5" without
              // pinning. Now pins the task so it's protected from rerolls.
              if (!saved.pinnedIds.contains(task.id!)) {
                final newPins = TodaysFivePinHelper.togglePinInPlace(saved.pinnedIds, task.id!);
                if (newPins != null) {
                  await db.saveTodaysFiveState(
                    date: dateKey,
                    taskIds: saved.taskIds.toList(),
                    completedIds: saved.completedIds,
                    workedOnIds: saved.workedOnIds,
                    pinnedIds: newPins,
                  );
                  deadlineSnackMessage = 'Due today — pinned in Today\'s 5!';
                } else {
                  deadlineSnackMessage = 'Due today — already in Today\'s 5 (max pins reached)';
                }
              } else {
                deadlineSnackMessage = 'Due today — already pinned in Today\'s 5';
              }
            }
          }
        }
      }
      // Now update the deadline — this triggers notifyListeners → refreshSnapshots,
      // which will detect the DB mismatch and reload (picking up our pin).
      await provider.updateTaskDeadline(task.id!, newDeadline, deadlineType: deadlineType);
      if (mounted && deadlineSnackMessage != null) {
        showInfoSnackBar(context, deadlineSnackMessage);
      }
    }
    // Refresh Today's 5 indicators (deadline may have triggered auto-pin)
    await loadTodaysFiveIds();
    // Invalidate cached schedule state so leaf detail refreshes
    if (mounted) setState(() {});
  }

  int _crossAxisCount(double width) {
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  double _childAspectRatio(int columns) {
    if (columns == 1) return 3.0;
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final provider = context.read<TaskProvider>();
        final navigated = await provider.navigateBack();
        if (!navigated && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Consumer<TaskProvider>(
        builder: (context, provider, _) {
          return Scaffold(
            appBar: AppBar(
              titleSpacing: provider.isRoot ? 16 : 0,
              title: provider.isRoot
                  ? Text(
                      'Task Roulette',
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.3,
                      ),
                    )
                  : Text(
                      provider.currentParent!.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18),
                    ),
              leading: provider.isRoot
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => provider.navigateBack(),
                    ),
              actions: [
                const ProfileIcon(),
                IconButton(
                  icon: const Icon(Icons.search, size: 22),
                  onPressed: _searchTask,
                  tooltip: 'Search',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(archiveIcon, size: 22),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CompletedTasksScreen(),
                      ),
                    );
                  },
                  tooltip: 'Archive',
                  visualDensity: VisualDensity.compact,
                ),
                if (provider.isRoot)
                  IconButton(
                    icon: const Icon(Icons.account_tree_outlined, size: 22),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DagViewScreen(),
                        ),
                      );
                    },
                    tooltip: 'Task graph',
                    visualDensity: VisualDensity.compact,
                  ),
                if (!provider.isRoot && provider.currentParent != null)
                  IconButton(
                    icon: Icon(
                      provider.currentParent!.isStarred ? Icons.star : Icons.star_outline,
                      size: 22,
                      color: provider.currentParent!.isStarred ? AppColors.starGold : null,
                    ),
                    onPressed: () => _updateStarred(
                      provider.currentParent!,
                      !provider.currentParent!.isStarred,
                    ),
                    tooltip: provider.currentParent!.isStarred ? 'Unstar' : 'Star',
                    visualDensity: VisualDensity.compact,
                  ),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, _) {
                    return IconButton(
                      icon: Icon(themeProvider.icon, size: 22),
                      onPressed: themeProvider.toggle,
                      tooltip: 'Toggle theme',
                      visualDensity: VisualDensity.compact,
                    );
                  },
                ),
                if (!provider.isRoot && provider.currentParent?.hasUrl == true && provider.tasks.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.link, size: 22),
                    onPressed: () => launchSafeUrl(context, provider.currentParent!.url!),
                    tooltip: 'Open link',
                    visualDensity: VisualDensity.compact,
                  ),
                if (!(kIsWeb && provider.isRoot))
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  position: PopupMenuPosition.under,
                  onSelected: (value) {
                    final task = provider.currentParent;
                    switch (value) {
                      case 'rename':
                        if (task != null) _renameTask(task);
                      case 'add_parent':
                        if (task != null) _addParentToTask(task);
                      case 'edit_link':
                        if (task != null) {
                          LeafTaskDetail.showEditUrlDialog(
                            context,
                            task.url,
                            (url) => _updateUrl(task, url),
                          );
                        }
                      case 'do_after':
                        if (task != null) _addDependencyToTask(task);
                      case 'schedule':
                        if (task != null) _editSchedule(task);
                      case 'delete':
                        if (task != null) _deleteTaskWithUndo(task);
                      case 'export':
                        BackupService.exportDatabase(context);
                      case 'import':
                        BackupService.importDatabase(
                          context,
                          context.read<TaskProvider>(),
                        );
                    }
                  },
                  itemBuilder: (_) => [
                    if (!provider.isRoot && provider.tasks.isEmpty) ...[
                      const PopupMenuItem(
                        value: 'add_parent',
                        child: Text('Also show under...'),
                      ),
                    ],
                    if (!provider.isRoot && provider.tasks.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: 'edit_link',
                        child: Text(
                          provider.currentParent?.hasUrl == true
                              ? 'Edit link'
                              : 'Add link',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'do_after',
                        child: Text('Do after...'),
                      ),
                    ],
                    if (!provider.isRoot) ...[
                      const PopupMenuItem(
                        value: 'schedule',
                        child: Text('Schedule'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                    if (!kIsWeb) ...[
                      if (!provider.isRoot) const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('Export backup'),
                      ),
                      const PopupMenuItem(
                        value: 'import',
                        child: Text('Import backup'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                if (!provider.isRoot)
                  _buildBreadcrumb(provider),
                Expanded(
                  child: provider.tasks.isEmpty && _inboxCount == 0
                    ? (provider.isRoot
                        ? const EmptyState(isRoot: true)
                        : _buildLeafTaskDetail(provider))
                    : provider.tasks.isEmpty && !provider.isRoot
                    ? _buildLeafTaskDetail(provider)
                    : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = _crossAxisCount(constraints.maxWidth);
                      // At root, filter inbox tasks out of the grid — they show
                      // in the inbox section above.
                      final gridTasks = provider.isRoot && _inboxCount > 0
                          ? provider.tasks.where((t) => !t.isInbox).toList()
                          : provider.tasks;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (provider.isRoot && _inboxCount > 0)
                              _buildInboxSection(provider),
                            GridView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              childAspectRatio: _childAspectRatio(columns),
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: gridTasks.length,
                            itemBuilder: (context, index) {
                              final task = gridTasks[index];
                              return TaskCard(
                                task: task,
                                onTap: () => provider.navigateInto(task),
                                onDelete: () => _deleteTaskWithUndo(task),
                                onAddParent: () => _addParentToTask(task),
                                onUnlink: provider.isRoot
                                    ? null
                                    : () => _unlinkTask(task),
                                onMove: provider.isRoot
                                    ? null
                                    : () => _moveTask(task),
                                onRename: () => _renameTask(task),
                                onAddDependency: () => _addDependencyToTask(task),
                                onSchedule: () => _editSchedule(task),
                                onFile: task.isInbox ? () => _fileTask(task) : null,
                                onStopWorking: task.isStarted
                                    ? () => _toggleStarted(task)
                                    : null,
                                isBlocked: provider.blockedTaskIds.contains(task.id),
                                blockedByName: provider.blockedByNames[task.id],
                                isInTodaysFive: _todaysFiveIds.contains(task.id),
                                isPinnedInTodaysFive: _todays5PinnedIds?.contains(task.id) ?? false,
                                parentNames: (provider.parentNamesMap[task.id] ?? [])
                                    .where((name) => name != provider.currentParent?.name)
                                    .toList(),
                                effectiveDeadline: provider.effectiveDeadlines[task.id],
                                isScheduledToday: provider.scheduledTodayIds.contains(task.id),
                                isStarred: task.isStarred,
                                onToggleStar: () => _updateStarred(task, !task.isStarred),
                              );
                            },
                          ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            floatingActionButton: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (provider.tasks.isNotEmpty)
                  FloatingActionButton(
                    heroTag: 'pickRandom',
                    onPressed: _pickRandom,
                    child: const Icon(Icons.shuffle),
                  ),
                if (provider.tasks.isNotEmpty)
                  const SizedBox(height: 12),
                if (!provider.isRoot)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton(
                        heroTag: 'linkTask',
                        onPressed: _linkExistingTask,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                        child: const Icon(Icons.playlist_add),
                      ),
                      const SizedBox(width: 12),
                      FloatingActionButton(
                        heroTag: 'addTask',
                        onPressed: _addTask,
                        child: const Icon(Icons.add),
                      ),
                    ],
                  )
                else
                  FloatingActionButton(
                    heroTag: 'addTask',
                    onPressed: _addTask,
                    child: const Icon(Icons.add),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
