import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';
import '../widgets/completion_animation.dart';
import '../widgets/profile_icon.dart';
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTodaysTasks();
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadTodaysTasks() async {
    final provider = context.read<TaskProvider>();
    final prefs = await SharedPreferences.getInstance();
    final savedDate = prefs.getString('todays5_date');
    final today = _todayKey();

    if (savedDate == today) {
      // Restore saved IDs
      final savedIds = prefs.getStringList('todays5_ids') ?? [];
      final completedIds = prefs.getStringList('todays5_completed') ?? [];
      final workedOnIds = prefs.getStringList('todays5_worked_on') ?? [];
      if (savedIds.isNotEmpty) {
        final allLeaves = await provider.getAllLeafTasks();
        final leafIdSet = allLeaves.map((t) => t.id!).toSet();
        final savedCompletedIds = completedIds.map(int.tryParse).whereType<int>().toSet();
        final savedWorkedOnIds = workedOnIds.map(int.tryParse).whereType<int>().toSet();
        final db = DatabaseHelper();
        final idSet = savedIds.map(int.tryParse).whereType<int>().toSet();
        final tasks = <Task>[];
        for (final id in idSet) {
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
        if (!mounted) return;
        setState(() {
          _todaysTasks = tasks;
          _completedIds.addAll(validCompletedIds);
          _workedOnIds.addAll(validWorkedOnIds);
          _loading = false;
        });
        await _persist();
        return;
      }
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
    if (!mounted) return;
    setState(() {
      _todaysTasks = refreshed;
    });
    await _persist();
  }

  Future<void> _generateNewSet() async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();

    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);

    // Keep done tasks, only replace undone ones
    final kept = _todaysTasks.where((t) => _completedIds.contains(t.id)).toList();
    final keptIds = kept.map((t) => t.id).toSet();

    final eligible = allLeaves.where(
      (t) => !blockedIds.contains(t.id) && !keptIds.contains(t.id),
    ).toList();

    final slotsToFill = 5 - kept.length;
    final picked = provider.pickWeightedN(eligible, slotsToFill);
    if (!mounted) return;
    setState(() {
      _todaysTasks = [...kept, ...picked];
      _loading = false;
    });
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('todays5_date', _todayKey());
    await prefs.setStringList(
      'todays5_ids',
      _todaysTasks.map((t) => t.id!.toString()).toList(),
    );
    await prefs.setStringList(
      'todays5_completed',
      _completedIds.map((id) => id.toString()).toList(),
    );
    await prefs.setStringList(
      'todays5_worked_on',
      _workedOnIds.map((id) => id.toString()).toList(),
    );
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
    if (!mounted) return;
    setState(() {});
    await _persist();
  }

  /// Unmarks a task as done: updates sets, refreshes snapshot, setState, persist.
  Future<void> _unmarkDone(int taskId, {required bool workedOn, required bool autoStarted}) async {
    _completedIds.remove(taskId);
    if (workedOn) _workedOnIds.remove(taskId);
    if (autoStarted) _autoStartedIds.remove(taskId);
    await _refreshTaskSnapshot(taskId);
    if (!mounted) return;
    setState(() {});
    await _persist();
  }

  /// Shows a bottom sheet: "In progress" / "Done today" / "Done for good!"
  void _showTaskOptions(Task task) {
    final colorScheme = Theme.of(context).colorScheme;
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
            ],
          ),
        ),
      ),
    );
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
            await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
            if (!wasStarted) await provider.unstartTask(task.id!);
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
      // "Done today" only — revert worked-on state
      await provider.unmarkWorkedOn(task.id!);
      if (wasAutoStarted) await provider.unstartTask(task.id!);
    } else if (task.isCompleted) {
      // "Done for good!" (or externally completed) — revert completion
      await provider.uncompleteTask(task.id!);
      if (wasWorkedOn) await provider.unmarkWorkedOn(task.id!);
    }
    if (!mounted) return;

    await _unmarkDone(task.id!, workedOn: wasWorkedOn, autoStarted: wasAutoStarted);
    if (!mounted) return;
    await _replaceIfNoLongerLeaf(task);
    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" restored.'),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmNewSet() async {
    final undoneCount = _todaysTasks.where(
      (t) => !_completedIds.contains(t.id),
    ).length;
    final message = undoneCount == _todaysTasks.length
        ? 'Replace all tasks with a fresh set of 5?'
        : 'Replace $undoneCount undone ${undoneCount == 1 ? 'task' : 'tasks'} with new picks? Done tasks will stay.';
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Swap task?'),
        content: Text('Replace "${task.name}" with another task?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Swap'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _swapTask(index);
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
      setState(() {
        _todaysTasks[index] = picked.first;
      });
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

    if (_todaysTasks.isEmpty) {
      return Center(
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
      );
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
          if (completedCount < totalCount)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _confirmNewSet,
              tooltip: 'New set',
            ),
        ],
      ),
      body: Padding(
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
            Text(
              completedCount == 0
                  ? 'Completing even 1 is a win!'
                  : '$completedCount of $totalCount done',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Task list
            Expanded(
              child: ListView.builder(
                itemCount: _todaysTasks.length,
                itemBuilder: (context, index) {
                  final task = _todaysTasks[index];
                  final isDone = _completedIds.contains(task.id);
                  return _buildTaskCard(context, task, index, isDone);
                },
              ),
            ),
          ],
        ),
      ),
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
          subtitle: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDone)
                IconButton(
                  icon: const Icon(Icons.shuffle, size: 20),
                  onPressed: () => _confirmSwapTask(index),
                  tooltip: 'Swap task',
                ),
              if (widget.onNavigateToTask != null && !task.isCompleted)
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  onPressed: () => widget.onNavigateToTask!(task),
                  tooltip: 'Go to task',
                ),
              if (task.isCompleted)
                IconButton(
                  icon: const Icon(archiveIcon, size: 20),
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
}
