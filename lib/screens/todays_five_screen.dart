import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/display_utils.dart';
import '../widgets/completion_animation.dart';
import '../widgets/profile_icon.dart';
import '../widgets/task_picker_dialog.dart';
import 'completed_tasks_screen.dart';

class TodaysFiveScreen extends StatefulWidget {
  final void Function(Task task)? onNavigateToTask;

  const TodaysFiveScreen({super.key, this.onNavigateToTask});

  @override
  State<TodaysFiveScreen> createState() => TodaysFiveScreenState();
}

class TodaysFiveScreenState extends State<TodaysFiveScreen> {
  List<Task> _todaysTasks = [];
  final Set<int> _completedIds = {};
  /// Tracks tasks marked "Done today" (vs "Done for good!") so
  /// _handleUncomplete can revert the correct state.
  final Set<int> _workedOnIds = {};
  /// Tracks tasks that were auto-started by "Done today" (weren't started
  /// before). _handleUncomplete uses this to also call unstartTask.
  final Set<int> _autoStartedIds = {};
  /// Tracks pre-mutation lastWorkedAt values for "Done today" tasks,
  /// so _handleUncomplete can restore the original value.
  final Map<int, int?> _preWorkedOnLastWorkedAt = {};
  /// Cached ancestor-path strings keyed by task ID (e.g. "Work > Project X").
  Map<int, String> _taskPaths = {};
  /// Other tasks completed/worked-on today, outside the Today's 5 set.
  List<Task> _otherDoneToday = [];
  bool _otherDoneExpanded = false;
  /// Tracks manually pinned tasks — protected from refresh until explicitly swapped.
  final Set<int> _pinnedIds = {};
  bool _loading = true;
  TaskProvider? _provider;

  @override
  void initState() {
    super.initState();
    _loadTodaysTasks();
    // Listen for external changes (e.g. undo "Done for good" from All Tasks)
    // so _otherDoneToday stays in sync without requiring a tab switch.
    _provider = context.read<TaskProvider>();
    _provider!.addListener(_onProviderChanged);
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted || _loading) return;
    _loadOtherDoneToday().then((_) {
      if (mounted) setState(() {});
    });
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadTodaysTasks() async {
    try {
      await _loadTodaysTasksInner();
    } catch (e) {
      debugPrint('TodaysFiveScreen: _loadTodaysTasks failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTodaysTasksInner() async {
    final provider = context.read<TaskProvider>();
    final db = DatabaseHelper();
    final today = _todayKey();

    // Migrate SharedPreferences → DB (idempotent, safe to call every time)
    await db.migrateTodaysFiveFromPrefs();

    // Try to restore from DB
    final saved = await db.loadTodaysFiveState(today);
    if (saved != null && saved.taskIds.isNotEmpty) {
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final savedCompletedIds = Set<int>.from(saved.completedIds);
      final savedWorkedOnIds = Set<int>.from(saved.workedOnIds);
      final savedPinnedIds = Set<int>.from(saved.pinnedIds);
      final tasks = <Task>[];
      for (final id in saved.taskIds) {
        if (leafIdSet.contains(id)) {
          // Still a leaf — restore from fresh data
          final match = allLeaves.where((t) => t.id == id);
          if (match.isNotEmpty) {
            tasks.add(match.first);
            // Detect external completion (e.g. worked-on from All Tasks)
            if (match.first.isWorkedOnToday && !savedCompletedIds.contains(id)) {
              savedCompletedIds.add(id);
            }
          }
        } else {
          // No longer a leaf — check if completed/done externally
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            if (savedCompletedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday) {
              savedCompletedIds.add(id);
              tasks.add(fresh);
            } else if (savedPinnedIds.contains(id)) {
              // Pinned task became non-leaf — try to slot in a leaf descendant
              final descendants = await db.getLeafDescendants(id);
              final currentIds = tasks.map((t) => t.id).toSet();
              final descLeafIds = descendants.map((d) => d.id!).toList();
              final descBlockedIds = await provider.getBlockedChildIds(descLeafIds);
              final eligibleDesc = descendants.where(
                (d) => !currentIds.contains(d.id) && !descBlockedIds.contains(d.id),
              ).toList();
              if (eligibleDesc.isNotEmpty) {
                final picked = provider.pickWeightedN(eligibleDesc, 1);
                if (picked.isNotEmpty) {
                  tasks.add(picked.first);
                  savedPinnedIds.remove(id);
                  savedPinnedIds.add(picked.first.id!);
                }
              } else {
                savedPinnedIds.remove(id);
                // Will be backfilled randomly below
              }
            }
          }
        }
      }
      // Backfill if some non-done tasks are no longer leaves
      if (tasks.length < 5) {
        final currentIds = tasks.map((t) => t.id).toSet();
        final leafIds = allLeaves.map((t) => t.id!).toList();
        final blockedIds = await provider.getBlockedChildIds(leafIds);
        final eligible = allLeaves.where(
          (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
        ).toList();
        final replacements = provider.pickWeightedN(
          eligible, 5 - tasks.length,
        );
        tasks.addAll(replacements);
      }
      // Only keep completed/worked-on IDs for tasks still in the list
      final taskIdSet = tasks.map((t) => t.id).toSet();
      final validCompletedIds = savedCompletedIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      final validWorkedOnIds = savedWorkedOnIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      // Keep pinned IDs for tasks still in the list (including transferred pins)
      final validPinnedIds = savedPinnedIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      if (!mounted) return;
      _todaysTasks = tasks;
      await _loadOtherDoneToday();
      await _loadTaskPaths();
      if (!mounted) return;
      setState(() {
        _completedIds.addAll(validCompletedIds);
        _workedOnIds.addAll(validWorkedOnIds);
        _pinnedIds.addAll(validPinnedIds);
        _loading = false;
      });
      await _persist();
      return;
    }

    await _generateNewSet();
  }

  /// Re-fetches task snapshots from DB without regenerating the set.
  /// Called when switching back to the Today tab to pick up changes
  /// made in All Tasks (e.g. unstarting a task).
  /// If the current set is empty, generates a new set instead (handles
  /// the case where the app started with no tasks and user added some).
  Future<void> refreshSnapshots() async {
    if (_todaysTasks.isEmpty) {
      await _generateNewSet();
      return;
    }
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    final db = DatabaseHelper();
    final refreshed = <Task>[];
    for (final t in _todaysTasks) {
      if (leafIdSet.contains(t.id)) {
        // Still a leaf — re-fetch fresh data
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null) {
          refreshed.add(fresh);
          // Detect "worked on today" done externally (e.g. from All Tasks leaf detail)
          if (fresh.isWorkedOnToday && !_completedIds.contains(fresh.id)) {
            _completedIds.add(fresh.id!);
          }
        }
      } else {
        // No longer a leaf — check if completed/done externally
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null) {
          if (_completedIds.contains(t.id) || fresh.isCompleted || fresh.isWorkedOnToday) {
            // Keep for progress tracking
            _completedIds.add(fresh.id!);
            refreshed.add(fresh);
          } else if (_pinnedIds.contains(t.id)) {
            // Pinned task became non-leaf — try to slot in a leaf descendant
            final descendants = await db.getLeafDescendants(t.id!);
            final currentIds = refreshed.map((r) => r.id).toSet();
            final descLeafIds = descendants.map((d) => d.id!).toList();
            final descBlockedIds = await provider.getBlockedChildIds(descLeafIds);
            final eligibleDesc = descendants.where(
              (d) => !currentIds.contains(d.id) && !descBlockedIds.contains(d.id),
            ).toList();
            if (eligibleDesc.isNotEmpty) {
              final picked = provider.pickWeightedN(eligibleDesc, 1);
              if (picked.isNotEmpty) {
                refreshed.add(picked.first);
                _pinnedIds.remove(t.id);
                _pinnedIds.add(picked.first.id!);
              }
            } else {
              _pinnedIds.remove(t.id);
              // Will be backfilled randomly below
            }
          }
          // Otherwise: became non-leaf without being done — will be backfilled
        }
      }
    }
    // Backfill replacements for non-done tasks that became non-leaf/deleted
    if (refreshed.length < _todaysTasks.length) {
      final currentIds = refreshed.map((t) => t.id).toSet();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);
      final eligible = allLeaves.where(
        (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
      ).toList();
      final replacements = provider.pickWeightedN(
        eligible, _todaysTasks.length - refreshed.length,
      );
      refreshed.addAll(replacements);
    }
    // Clean up completed IDs: remove if task left the list, or was
    // uncompleted externally (e.g. restored from archive)
    _completedIds.removeWhere((id) {
      final task = refreshed.where((t) => t.id == id).firstOrNull;
      if (task == null) return true; // no longer in list
      return !task.isCompleted && !task.isWorkedOnToday; // restored
    });
    // Keep workedOnIds in sync — remove if no longer in completed set
    _workedOnIds.removeWhere((id) => !_completedIds.contains(id));
    // Clean pinned IDs: remove if task left the list or is no longer a leaf
    _pinnedIds.removeWhere((id) {
      if (!refreshed.any((t) => t.id == id)) return true; // not in list
      return !leafIdSet.contains(id); // no longer a leaf
    });
    if (!mounted) return;
    _todaysTasks = refreshed;
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {});
    await _persist();
  }

  Future<void> _generateNewSet() async {
    // Clear stale per-session tracking sets from previous day
    _workedOnIds.clear();
    _autoStartedIds.clear();
    _preWorkedOnLastWorkedAt.clear();

    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();

    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);

    // Keep done + pinned tasks, only replace the rest
    final kept = _todaysTasks.where(
      (t) => _completedIds.contains(t.id) || _pinnedIds.contains(t.id),
    ).toList();
    // Clean pinned IDs for tasks no longer in the kept set
    _pinnedIds.removeWhere((id) => !kept.any((t) => t.id == id));
    final keptIds = kept.map((t) => t.id).toSet();

    final eligible = allLeaves.where(
      (t) => !blockedIds.contains(t.id) && !keptIds.contains(t.id),
    ).toList();

    final slotsToFill = 5 - kept.length;
    final picked = provider.pickWeightedN(eligible, slotsToFill);
    if (!mounted) return;
    _todaysTasks = [...kept, ...picked];
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    await _persist();
  }

  /// Trims excess unpinned undone tasks and persists. Calls setState if
  /// the list actually shrank so the UI updates immediately.
  Future<void> _persistAndTrim() async {
    final currentIds = _todaysTasks.map((t) => t.id!).toList();
    final trimmedIds = TodaysFivePinHelper.trimExcess(
      currentIds, _completedIds, _pinnedIds,
    );
    if (trimmedIds.length < currentIds.length) {
      final trimmedSet = trimmedIds.toSet();
      _todaysTasks.removeWhere((t) => !trimmedSet.contains(t.id));
      if (mounted) setState(() {});
    }
    await _persist();
  }

  Future<void> _persist() async {
    await DatabaseHelper().saveTodaysFiveState(
      date: _todayKey(),
      taskIds: _todaysTasks.map((t) => t.id!).toList(),
      completedIds: _completedIds,
      workedOnIds: _workedOnIds,
      pinnedIds: _pinnedIds,
    );
  }

  /// Fetches ancestor paths for all tasks in [_todaysTasks] + [_otherDoneToday]
  /// and caches them.
  Future<void> _loadTaskPaths() async {
    final db = DatabaseHelper();
    final paths = <int, String>{};
    final allTasks = [..._todaysTasks, ..._otherDoneToday];
    for (final task in allTasks) {
      final ancestors = await db.getAncestorPath(task.id!);
      if (ancestors.isNotEmpty) {
        paths[task.id!] = ancestors.map((t) => t.name).join(' › ');
      }
    }
    _taskPaths = paths;
  }

  /// Loads tasks completed/worked-on today that aren't in Today's 5.
  Future<void> _loadOtherDoneToday() async {
    final todaysFiveIds = _todaysTasks.map((t) => t.id!).toSet();
    _otherDoneToday = await DatabaseHelper().getTasksDoneToday(
      excludeIds: todaysFiveIds,
    );
  }

  /// Truncates a hierarchy path to keep the last 2 segments when there
  /// are more than 3, so the immediate parent is always visible.
  /// e.g. "Coding › App › Enhancements › Random" → "… › Enhancements › Random"
  String _shortenPath(String path) {
    final segments = path.split(' › ');
    if (segments.length <= 3) return path;
    return '… › ${segments.sublist(segments.length - 2).join(' › ')}';
  }

  /// Re-fetches a single task from DB and updates it in [_todaysTasks].
  /// Does NOT call setState — callers handle that.
  /// Returns the fresh task, or null if not found.
  Future<Task?> _refreshTaskSnapshot(int taskId) async {
    final fresh = await DatabaseHelper().getTaskById(taskId);
    if (fresh != null) {
      final idx = _todaysTasks.indexWhere((t) => t.id == taskId);
      if (idx >= 0) _todaysTasks[idx] = fresh;
    }
    return fresh;
  }

  /// Marks a task as done: updates sets, refreshes snapshot, setState, persist.
  /// [workedOn] — true for "Done today", false for "Done for good!"
  /// [autoStarted] — true if the task was auto-started by "Done today"
  Future<void> _markDone(int taskId, {required bool workedOn, required bool autoStarted}) async {
    _completedIds.add(taskId);
    if (workedOn) _workedOnIds.add(taskId);
    if (autoStarted) _autoStartedIds.add(taskId);
    await _refreshTaskSnapshot(taskId);
    await _loadOtherDoneToday();
    if (!mounted) return;
    setState(() {});
    await _persist();
  }

  /// Unmarks a task as done: updates sets, refreshes snapshot, setState, persist.
  /// Also trims excess tasks — uncompleting may leave unpinned undone tasks
  /// beyond slot 5 that should be removed.
  Future<void> _unmarkDone(int taskId, {required bool workedOn, required bool autoStarted}) async {
    _completedIds.remove(taskId);
    if (workedOn) _workedOnIds.remove(taskId);
    if (autoStarted) _autoStartedIds.remove(taskId);
    await _refreshTaskSnapshot(taskId);
    await _loadOtherDoneToday();
    if (!mounted) return;
    setState(() {});
    await _persistAndTrim();
  }

  /// Shows a bottom sheet: "In progress" / "Done today" / "Done for good!" / Pin/Unpin
  void _showTaskOptions(Task task) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPinned = _pinnedIds.contains(task.id);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.today, color: Colors.orange),
                title: const Text('Done today'),
                subtitle: const Text('Partial work counts — we\'ll remind you again soon.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _workedOnTask(task);
                },
              ),
              ListTile(
                leading: Icon(Icons.check_circle, color: colorScheme.primary),
                title: const Text('Done for good!'),
                subtitle: const Text('Permanently complete this task'),
                onTap: () {
                  Navigator.pop(ctx);
                  _completeNormalTask(task);
                },
              ),
              if (!task.isStarted)
                ListTile(
                  leading: Icon(Icons.play_circle_outline, color: colorScheme.tertiary),
                  title: const Text('In progress'),
                  subtitle: const Text("I'm working on this"),
                  onTap: () {
                    Navigator.pop(ctx);
                    _markInProgress(task);
                  },
                )
              else
                ListTile(
                  leading: Icon(Icons.stop_circle_outlined, color: colorScheme.onSurfaceVariant),
                  title: const Text('Stop working'),
                  subtitle: const Text('Remove in-progress marker'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _stopWorking(task);
                  },
                ),
              if (isPinned)
                ListTile(
                  leading: Icon(Icons.push_pin_outlined, color: colorScheme.onSurfaceVariant),
                  title: const Text('Unpin'),
                  subtitle: const Text('Remove from must do'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePinFromSheet(task);
                  },
                )
              else if (_pinnedIds.length < maxPins)
                ListTile(
                  leading: Icon(Icons.push_pin, color: colorScheme.tertiary),
                  title: const Text('Pin'),
                  subtitle: const Text('Mark as must do'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePinFromSheet(task);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _togglePinFromSheet(Task task) {
    final result = TodaysFivePinHelper.togglePinInPlace(
      _pinnedIds, task.id!,
    );
    if (result == null) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Max 5 pinned tasks — unpin one first'), showCloseIcon: true, persist: false),
      );
    } else {
      setState(() {
        _pinnedIds.clear();
        _pinnedIds.addAll(result);
      });
      _persistAndTrim();
    }
  }

  Future<void> _stopWorking(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.unstartTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" — stopped.'),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _markInProgress(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.startTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" — on it!'),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _workedOnTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final wasStarted = task.isStarted;
    final previousLastWorkedAt = task.lastWorkedAt;
    _preWorkedOnLastWorkedAt[task.id!] = previousLastWorkedAt;
    await showCompletionAnimation(context);
    if (!mounted) return;
    await provider.markWorkedOn(task.id!);
    if (!wasStarted) await provider.startTask(task.id!);
    await _markDone(task.id!, workedOn: true, autoStarted: !wasStarted);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" — nice work! We\'ll remind you again soon.'),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            _preWorkedOnLastWorkedAt.remove(task.id);
            await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
            if (!wasStarted) await provider.unstartTask(task.id!);
            if (!mounted) return;
            await _unmarkDone(task.id!, workedOn: true, autoStarted: !wasStarted);
          },
        ),
      ),
    );
  }

  Future<void> _completeNormalTask(Task task) async {
    final provider = context.read<TaskProvider>();
    await showCompletionAnimation(context);
    if (!mounted) return;
    await provider.completeTaskOnly(task.id!);
    await _markDone(task.id!, workedOn: false, autoStarted: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" done!'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await provider.uncompleteTask(task.id!);
            if (!mounted) return;
            await _unmarkDone(task.id!, workedOn: false, autoStarted: false);
          },
        ),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Handles the check action on a Today's 5 task.
  /// Always shows bottom sheet: "Done today" vs "Done for good!"
  Future<void> _handleTaskDone(Task task) async {
    _showTaskOptions(task);
  }

  /// If [task] is no longer a leaf, replaces it in [_todaysTasks] with
  /// a randomly picked eligible leaf (or removes it if none available).
  /// Calls setState if a replacement happens.
  Future<void> _replaceIfNoLongerLeaf(Task task) async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    if (leafIdSet.contains(task.id)) return;

    final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
    if (idx < 0) return;

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);
    final eligible = allLeaves.where(
      (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
    ).toList();
    final replacements = provider.pickWeightedN(eligible, 1);
    if (!mounted) return;
    _pinnedIds.remove(task.id);
    setState(() {
      if (replacements.isNotEmpty) {
        _todaysTasks[idx] = replacements.first;
      } else {
        _todaysTasks.removeAt(idx);
      }
    });
  }

  /// Uncompletes a task that was marked done in Today's 5.
  /// Correctly reverts "Done today" (unmark worked-on + unstart) vs
  /// "Done for good!" (uncomplete). If the task is no longer a leaf,
  /// swaps it out immediately.
  Future<void> _handleUncomplete(Task task) async {
    final provider = context.read<TaskProvider>();
    // Check actual DB state — task may have been completed externally
    // (e.g. via "Go to task" → All Tasks) even if _workedOnIds has it.
    final wasWorkedOn = _workedOnIds.contains(task.id);
    final wasAutoStarted = _autoStartedIds.contains(task.id);
    if (wasWorkedOn && !task.isCompleted) {
      // "Done today" only — revert worked-on state, restore original lastWorkedAt
      final restoreTo = _preWorkedOnLastWorkedAt.remove(task.id);
      await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
      if (wasAutoStarted) await provider.unstartTask(task.id!);
    } else if (task.isCompleted) {
      // "Done for good!" (or externally completed) — revert completion
      await provider.uncompleteTask(task.id!);
      if (wasWorkedOn) {
        final restoreTo = _preWorkedOnLastWorkedAt.remove(task.id);
        await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
      }
    }
    if (!mounted) return;

    await _unmarkDone(task.id!, workedOn: wasWorkedOn, autoStarted: wasAutoStarted);
    if (!mounted) return;
    await _replaceIfNoLongerLeaf(task);
    if (!mounted) return;

    final wasRemoved = !_todaysTasks.any((t) => t.id == task.id);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(wasRemoved
            ? '"${task.name}" restored and removed from Today\'s 5 (all slots are pinned).'
            : '"${task.name}" restored.'),
        showCloseIcon: true,
        persist: false,
        duration: Duration(seconds: wasRemoved ? 5 : 3),
      ),
    );
  }

  Future<void> _confirmNewSet() async {
    final replaceableCount = _todaysTasks.where(
      (t) => !_completedIds.contains(t.id) && !_pinnedIds.contains(t.id),
    ).length;
    final pinnedCount = _todaysTasks.where(
      (t) => _pinnedIds.contains(t.id) && !_completedIds.contains(t.id),
    ).length;
    final String message;
    if (replaceableCount == 0) {
      message = 'All tasks are done or pinned — nothing to replace.';
    } else if (pinnedCount > 0) {
      message = 'Replace $replaceableCount undone ${replaceableCount == 1 ? 'task' : 'tasks'} '
          'with new picks? Done and pinned tasks will stay.';
    } else if (replaceableCount == _todaysTasks.length) {
      message = 'Replace all tasks with a fresh set of 5?';
    } else {
      message = 'Replace $replaceableCount undone ${replaceableCount == 1 ? 'task' : 'tasks'} '
          'with new picks? Done tasks will stay.';
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New set?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          if (replaceableCount > 0)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
        ],
      ),
    );
    if (confirmed == true) await _generateNewSet();
  }

  Future<void> _confirmSwapTask(int index) async {
    final task = _todaysTasks[index];
    final isPinned = _pinnedIds.contains(task.id);
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPinned)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.push_pin, size: 16, color: colorScheme.tertiary),
                      const SizedBox(width: 6),
                      Text(
                        'This task was manually pinned.',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: Icon(Icons.shuffle, color: colorScheme.onSurfaceVariant),
                title: const Text('Random replacement'),
                subtitle: const Text('Replace with a randomly picked task'),
                onTap: () {
                  Navigator.pop(ctx);
                  if (isPinned) {
                    _confirmUnpinAndSwap(index);
                  } else {
                    _swapTask(index);
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.checklist, color: colorScheme.primary),
                title: const Text('Choose a task'),
                subtitle: const Text('Pick a specific task for this slot'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndPinTask(index);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows extra confirmation when randomly replacing a pinned task.
  Future<void> _confirmUnpinAndSwap(int index) async {
    final task = _todaysTasks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace pinned task?'),
        content: Text('"${task.name}" was manually pinned. Replace it with a random task?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _pinnedIds.remove(task.id);
      await _swapTask(index);
    }
  }

  /// Opens TaskPickerDialog to let the user choose a task for a slot, then pins it.
  Future<void> _pickAndPinTask(int index) async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final eligible = allLeaves.where(
      (t) => !currentIds.contains(t.id) &&
             !blockedIds.contains(t.id) &&
             !t.isWorkedOnToday,
    ).toList();

    if (eligible.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No other tasks available to pick'), showCloseIcon: true, persist: false),
        );
      }
      return;
    }

    final parentNamesMap = await provider.getParentNamesForTaskIds(
      eligible.map((t) => t.id!).toList(),
    );

    if (!mounted) return;
    final picked = await showDialog<Task>(
      context: context,
      builder: (ctx) => TaskPickerDialog(
        candidates: eligible,
        title: 'Pick a task',
        parentNamesMap: parentNamesMap,
      ),
    );
    if (picked == null || !mounted) return;

    final oldTask = _todaysTasks[index];
    final wasPinned = _pinnedIds.remove(oldTask.id);
    // Always pin the picked task (we just freed a slot if old was pinned)
    final newPins = TodaysFivePinHelper.togglePinInPlace(_pinnedIds, picked.id!);
    if (newPins == null) {
      // Restore old pin if we can't fit the new one
      if (wasPinned) _pinnedIds.add(oldTask.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Max 5 pinned tasks — unpin one first'), showCloseIcon: true, persist: false),
        );
      }
      return;
    }
    _pinnedIds.clear();
    _pinnedIds.addAll(newPins);
    // Load ancestor path for the new task's breadcrumb subtitle
    final ancestors = await DatabaseHelper().getAncestorPath(picked.id!);
    if (ancestors.isNotEmpty) {
      _taskPaths[picked.id!] = ancestors.map((t) => t.name).join(' › ');
    } else {
      _taskPaths.remove(picked.id!);
    }
    setState(() {
      _todaysTasks[index] = picked;
    });
    await _persist();
  }

  Future<void> _swapTask(int index) async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final eligible = allLeaves.where(
      (t) => !currentIds.contains(t.id) &&
             !blockedIds.contains(t.id) &&
             !t.isWorkedOnToday,
    ).toList();

    if (eligible.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No other tasks to swap in'), showCloseIcon: true, persist: false),
        );
      }
      return;
    }

    final picked = provider.pickWeightedN(eligible, 1);
    if (picked.isNotEmpty) {
      // Complete async work before mutating state
      final ancestors = await DatabaseHelper().getAncestorPath(picked.first.id!);
      if (!mounted) return;
      _pinnedIds.remove(_todaysTasks[index].id);
      _todaysTasks[index] = picked.first;
      if (ancestors.isNotEmpty) {
        _taskPaths[picked.first.id!] = ancestors.map((t) => t.name).join(' › ');
      } else {
        _taskPaths.remove(picked.first.id!);
      }
      setState(() {});
      await _persist();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final completedCount = _completedIds.length;
    final totalCount = _todaysTasks.length;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Task Roulette',
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 30,
                fontWeight: FontWeight.w400,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              "Today's 5",
              style: textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        toolbarHeight: 72,
        actions: [
          const ProfileIcon(),
          IconButton(
            icon: const Icon(archiveIcon),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const CompletedTasksScreen(),
                ),
              );
              if (mounted) await refreshSnapshots();
            },
            tooltip: 'Archive',
          ),
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return IconButton(
                icon: Icon(themeProvider.icon, size: 28),
                onPressed: themeProvider.toggle,
                tooltip: 'Toggle theme',
              );
            },
          ),
          if (_todaysTasks.any((t) =>
              !_completedIds.contains(t.id) && !_pinnedIds.contains(t.id)))
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _confirmNewSet,
              tooltip: 'New set',
            ),
        ],
      ),
      body: _todaysTasks.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 64, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'No tasks for today!',
                    style: textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add some tasks in the All Tasks tab.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        : Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: totalCount > 0 ? completedCount / totalCount : 0,
                minHeight: 8,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: completedCount == 0
                        ? 'Completing even 1 is a win!'
                        : '$completedCount of $totalCount done',
                  ),
                  if (_otherDoneToday.isNotEmpty)
                    TextSpan(
                      text: '  +${_otherDoneToday.length} ${_otherDoneToday.length == 1 ? 'other' : 'others'}',
                      style: TextStyle(
                        color: colorScheme.primary.withAlpha(180),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Task list — pinned undone tasks on top as "Must do"
            Expanded(
              child: _buildTaskList(context, colorScheme, textTheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList(BuildContext context, ColorScheme colorScheme, TextTheme textTheme) {
    // Split into pinned-undone ("Must do") and the rest
    final mustDo = <int>[]; // indices into _todaysTasks
    final rest = <int>[];
    for (int i = 0; i < _todaysTasks.length; i++) {
      final task = _todaysTasks[i];
      final isDone = _completedIds.contains(task.id);
      if (_pinnedIds.contains(task.id) && !isDone) {
        mustDo.add(i);
      } else {
        rest.add(i);
      }
    }

    if (mustDo.isEmpty) {
      // No pinned tasks — flat list, no headers
      return ListView(
        children: [
          ..._todaysTasks.asMap().entries.map((entry) {
            final index = entry.key;
            final task = entry.value;
            final isDone = _completedIds.contains(task.id);
            return _buildTaskCard(context, task, index, isDone);
          }),
          if (_otherDoneToday.isNotEmpty)
            _buildOtherDoneBox(context, textTheme, colorScheme),
        ],
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'Must do',
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.tertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final i in mustDo)
          _buildTaskCard(context, _todaysTasks[i], i, false),
        if (rest.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              'Also on the table',
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final i in rest)
          _buildTaskCard(context, _todaysTasks[i], i, _completedIds.contains(_todaysTasks[i].id)),
        if (_otherDoneToday.isNotEmpty)
          _buildOtherDoneBox(context, textTheme, colorScheme),
      ],
    );
  }

  Widget _buildTaskCard(
    BuildContext context,
    Task task,
    int index,
    bool isDone,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: isDone ? 0.5 : 1.0,
        child: ListTile(
          leading: isDone
              ? Icon(Icons.check_circle, color: colorScheme.primary)
              : Icon(Icons.radio_button_unchecked,
                  color: colorScheme.onSurfaceVariant),
          title: Text(
            task.name,
            style: textTheme.bodyLarge?.copyWith(
              decoration: isDone ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_taskPaths.containsKey(task.id))
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _shortenPath(_taskPaths[task.id]!),
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pinnedIds.contains(task.id) && !isDone)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.push_pin, size: 14,
                          color: colorScheme.tertiary),
                    ),
                  if (task.isHighPriority)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.flag, size: 14, color: colorScheme.error),
                    ),
                  if (task.isQuickTask)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.bolt, size: 14, color: Colors.amber),
                    ),
                  if (task.isStarted && !isDone)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.play_circle_filled, size: 14,
                          color: colorScheme.tertiary),
                    ),
                ],
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDone)
                PinButton(
                  isPinned: _pinnedIds.contains(task.id),
                  onToggle: () {
                    final result = TodaysFivePinHelper.togglePinInPlace(
                      _pinnedIds, task.id!,
                    );
                    if (result == null) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Max 5 pinned tasks — unpin one first'), showCloseIcon: true, persist: false),
                      );
                    } else {
                      setState(() {
                        _pinnedIds.clear();
                        _pinnedIds.addAll(result);
                      });
                      _persistAndTrim();
                    }
                  },
                ),
              if (!isDone)
                IconButton(
                  icon: const Icon(Icons.shuffle, size: 18),
                  onPressed: () => _confirmSwapTask(index),
                  tooltip: 'Swap task',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              if (widget.onNavigateToTask != null && !task.isCompleted)
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => widget.onNavigateToTask!(task),
                  tooltip: 'Go to task',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              if (task.isCompleted)
                IconButton(
                  icon: const Icon(archiveIcon, size: 18),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CompletedTasksScreen(),
                      ),
                    );
                    if (mounted) await refreshSnapshots();
                  },
                  tooltip: 'View in archive',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
            ],
          ),
          onTap: isDone
              ? () => _handleUncomplete(task)
              : () => _handleTaskDone(task),
        ),
      ),
    );
  }

  Widget _buildOtherDoneBox(BuildContext context, TextTheme textTheme, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withAlpha(40),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final hasOverflow = _otherDoneExpanded || _chipsOverflow(context, constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: hasOverflow ? () => setState(() => _otherDoneExpanded = !_otherDoneExpanded) : null,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Text(
                        'Also done today',
                        style: textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (hasOverflow) ...[
                        const SizedBox(width: 4),
                        Icon(
                          _otherDoneExpanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _buildOtherDoneChips(context),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Returns true if the chips won't all fit in a single row.
  bool _chipsOverflow(BuildContext context, double maxWidth) {
    const spacing = 6.0;
    const maxChipWidth = 160.0;
    var usedWidth = 0.0;

    for (final task in _otherDoneToday) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: task.name,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final rawChipWidth = 14 + 4 + textPainter.width + 20 + 2;
      textPainter.dispose();
      final chipWidth = rawChipWidth.clamp(0.0, maxChipWidth);
      final neededWidth = usedWidth > 0 ? chipWidth + spacing : chipWidth;

      if (usedWidth + neededWidth > maxWidth) return true;
      usedWidth += neededWidth;
    }
    return false;
  }

  Widget _buildOtherDoneChips(BuildContext context) {
    if (_otherDoneExpanded) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: _otherDoneToday.map((task) =>
          _buildOtherDoneChip(context, task),
        ).toList(),
      );
    }

    // Collapsed: show chips that fit in one row
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        const spacing = 6.0;
        const maxChipWidth = 160.0;
        var usedWidth = 0.0;
        var visibleCount = 0;

        for (final task in _otherDoneToday) {
          final textPainter = TextPainter(
            text: TextSpan(
              text: task.name,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          final rawChipWidth = 14 + 4 + textPainter.width + 20 + 2;
          textPainter.dispose();
          final chipWidth = rawChipWidth.clamp(0.0, maxChipWidth);
          final neededWidth = usedWidth > 0 ? chipWidth + spacing : chipWidth;

          if (usedWidth + neededWidth <= maxWidth) {
            usedWidth += neededWidth;
            visibleCount++;
          } else {
            break;
          }
        }

        if (visibleCount == 0) visibleCount = 1;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: _otherDoneToday.take(visibleCount).map((task) =>
            _buildOtherDoneChip(context, task),
          ).toList(),
        );
      },
    );
  }

  Widget _buildOtherDoneChip(BuildContext context, Task task) {
    final doneForGood = task.isCompleted;
    final chipColor = doneForGood ? Colors.green : Colors.lightGreen;
    final icon = doneForGood ? Icons.done_all : Icons.check;

    return Tooltip(
      message: task.name,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: chipColor.withAlpha(40),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: chipColor.withAlpha(80)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: chipColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  task.name,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: chipColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
