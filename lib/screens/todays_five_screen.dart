import 'package:flutter/foundation.dart' show kDebugMode, setEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/auth_provider.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../services/sync_service.dart';
import '../utils/display_utils.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/completion_animation.dart';
import '../widgets/task_picker_dialog.dart';
import '../widgets/profile_icon.dart';
import 'completed_tasks_screen.dart';

class TodaysFiveScreen extends StatefulWidget {
  final void Function(Task task)? onNavigateToTask;

  const TodaysFiveScreen({super.key, this.onNavigateToTask});

  @override
  State<TodaysFiveScreen> createState() => TodaysFiveScreenState();
}

class TodaysFiveScreenState extends State<TodaysFiveScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

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
  /// Task IDs explicitly uncompleted this session — prevents refreshSnapshots
  /// from re-adding them to _completedIds via isWorkedOnToday auto-detection.
  /// Bug fix: provider.unmarkWorkedOn triggers an unawaited refreshSnapshots()
  /// that races with _unmarkDone, re-reading isWorkedOnToday before DB settles.
  final Set<int> _explicitlyUncompletedIds = {};
  /// Cached ancestor-path strings keyed by task ID (e.g. "Work > Project X").
  Map<int, String> _taskPaths = {};
  /// Task ID → effective deadline info for icon display.
  Map<int, ({String deadline, String type})> _effectiveDeadlines = {};
  /// Leaf task IDs scheduled for today (for icon display).
  Set<int> _scheduledTodayIds = {};
  /// Leaf task IDs whose deadline is exactly today. These are force-pinned into
  /// Today's 5 on every load (manual-model exception), unless the user has
  /// removed (suppressed) them today. Cached so the remove flow knows whether a
  /// removal needs to be recorded as a deadline suppression.
  Set<int> _deadlineTodayIds = {};
  /// Other tasks completed/worked-on today, outside the Today's 5 set.
  List<Task> _otherDoneToday = [];
  bool _otherDoneExpanded = false;
  bool _loading = true;
  /// The date key that was last loaded, used to detect midnight rollover.
  String _loadedDateKey = '';
  TaskProvider? _provider;
  AuthProvider? _authProvider;

  @override
  void initState() {
    super.initState();
    _loadTodaysTasks();
    // Listen for external changes (e.g. undo "Done for good" from All Tasks)
    // so _otherDoneToday stays in sync without requiring a tab switch.
    _provider = context.read<TaskProvider>();
    _provider!.addListener(_onProviderChanged);
    // Listen for sync completion to reload Today's 5 from DB after pull.
    _authProvider = context.read<AuthProvider>();
    _authProvider!.addListener(_onSyncStatusChanged);
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    _authProvider?.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted || _loading) return;
    if (_todayKey() != _loadedDateKey) {
      _reloadFromDb();
      return;
    }
    refreshSnapshots();
  }

  void _onSyncStatusChanged() {
    if (!mounted || _loading) return;
    if (_authProvider?.syncStatus == SyncStatus.synced) {
      _reloadFromDb();
    }
  }

  /// Fully reloads Today's 5 from DB after a sync pull.
  /// Unlike refreshSnapshots() which keeps the same task IDs,
  /// this picks up any changes to the task list itself (e.g.
  /// different selections synced from another device).
  Future<void> _reloadFromDb() async {
    _completedIds.clear();
    _workedOnIds.clear();
    _autoStartedIds.clear();
    _preWorkedOnLastWorkedAt.clear();
    _explicitlyUncompletedIds.clear();
    await _loadTodaysTasks();
  }

  /// Reloads from DB but preserves the session-only undo state that
  /// `_reloadFromDb()` would otherwise clear (auto-started flags and
  /// pre-worked-on timestamps are not persisted, so they must survive a
  /// refresh-triggered reload). Used by both reconcile branches in
  /// refreshSnapshots() so the snapshot→reload→restore dance lives in one place.
  Future<void> _reloadPreservingUndoState() async {
    final prevAutoStarted = Set<int>.from(_autoStartedIds);
    final prevPreWorkedOn = Map<int, int?>.from(_preWorkedOnLastWorkedAt);
    await _reloadFromDb();
    _autoStartedIds.addAll(prevAutoStarted);
    _preWorkedOnLastWorkedAt.addAll(prevPreWorkedOn);
  }

  String _todayKey() => todayDateKey();

  Future<void> _loadTodaysTasks() async {
    try {
      await _loadTodaysTasksInner();
    } catch (e) {
      debugLog('TodaysFiveScreen: _loadTodaysTasks failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTodaysTasksInner() async {
    final provider = context.read<TaskProvider>();
    final db = DatabaseHelper();
    final today = _todayKey();
    _loadedDateKey = today;

    // Migrate SharedPreferences → DB (idempotent, safe to call every time)
    await db.migrateTodaysFiveFromPrefs();

    // Manual model, with ONE exception: leaf tasks whose deadline is exactly
    // today are auto-pinned into Today's 5 on every load. Overdue deadlines are
    // NOT auto-pinned — getDeadlinePinLeafIds() filters to `deadline = today`,
    // so yesterday's/earlier misses rely on weight boost in All Tasks instead.
    // A task the user explicitly removes today is recorded as "suppressed" so it
    // stays off the list for the rest of the day and is not re-pinned on the next
    // reconcile — while a *different* task that becomes due today still gets
    // pinned (suppression is per task-id, so removals are respected individually).
    await db.purgeOldDeadlineSuppressed(today);
    _deadlineTodayIds = await db.getDeadlinePinLeafIds();
    final suppressedIds = await db.getDeadlineSuppressedIds(today);
    final autoPinIds = _deadlineTodayIds.difference(suppressedIds);

    final saved = await db.loadTodaysFiveState(today);
    // Merge saved manual pins with today's (non-suppressed) deadline auto-pins.
    final effectiveTaskIds = List<int>.from(saved?.taskIds ?? const <int>[]);
    for (final id in autoPinIds) {
      if (!effectiveTaskIds.contains(id)) effectiveTaskIds.add(id);
    }

    if (effectiveTaskIds.isEmpty) {
      if (!mounted) return;
      // Bug fix (manual-model empty-at-start): when there is no saved state for
      // today AND no deadline-today task to auto-pin — real midnight rollover
      // with the app left open, a sync pull that empties the set, or the debug
      // rollover button — this branch must reset the in-memory list. Before: it
      // returned WITHOUT clearing _todaysTasks, so yesterday's tasks lingered on
      // the new day (shown undone after _reloadFromDb cleared _completedIds, then
      // re-marked done on the next refreshSnapshots via isWorkedOnToday). After:
      // the list is truly empty and the "Nothing pinned yet" state shows.
      _todaysTasks = [];
      _completedIds.clear();
      _workedOnIds.clear();
      await _loadOtherDoneToday();
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }

    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    final savedCompletedIds = Set<int>.from(saved?.completedIds ?? const <int>{});
    final savedWorkedOnIds = Set<int>.from(saved?.workedOnIds ?? const <int>{});
    final tasks = <Task>[];
    for (final id in effectiveTaskIds) {
      if (leafIdSet.contains(id)) {
        // Still a leaf — restore from fresh data
        final match = allLeaves.where((t) => t.id == id).firstOrNull;
        if (match != null) {
          tasks.add(match);
          if (match.isWorkedOnToday && !savedCompletedIds.contains(id)) {
            savedCompletedIds.add(id);
          }
        }
      } else {
        // No longer a leaf — keep only if completed/done. Otherwise drop it
        // (manual model: no auto-replacement with a descendant).
        final fresh = await db.getTaskById(id);
        if (fresh != null &&
            (savedCompletedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday)) {
          savedCompletedIds.add(id);
          tasks.add(fresh);
        }
      }
    }
    // Only keep state for tasks still in the list
    final taskIdSet = tasks.map((t) => t.id).toSet();
    final validCompletedIds = savedCompletedIds.where(taskIdSet.contains).toSet();
    final validWorkedOnIds = savedWorkedOnIds.where(taskIdSet.contains).toSet();
    if (!mounted) return;
    _todaysTasks = tasks;
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {
      _completedIds.addAll(validCompletedIds);
      _workedOnIds.addAll(validWorkedOnIds);
      _loading = false;
    });
    await _persist();
  }

  /// Re-fetches task snapshots from DB without regenerating the set.
  /// Called when switching back to the Today tab to pick up changes made
  /// in All Tasks (e.g. unstarting a task, toggling pins). Manual-only model:
  /// tasks that become non-leaf or deleted are dropped — no auto-replacement.
  Future<void> refreshSnapshots() async {
    // Midnight rollover: date changed since last load → reload from DB
    if (_todayKey() != _loadedDateKey) {
      await _reloadFromDb();
      return;
    }

    final db = DatabaseHelper();
    final today = _todayKey();

    // Detect external modifications FIRST (cheap, indexed lookup): the task
    // list screen can toggle pins or add pinned tasks directly to the DB. If
    // the DB state differs from our in-memory state, do a full reload (which
    // also runs the deadline reconcile) so we don't overwrite DB changes when
    // _persist() runs at the end. Doing this before the deadline reconcile
    // avoids paying the deadline query twice when a reload happens anyway.
    final saved = await db.loadTodaysFiveState(today);
    if (saved != null &&
        !setEquals(saved.taskIds.toSet(),
            _todaysTasks.map((t) => t.id!).toSet())) {
      await _reloadPreservingUndoState();
      return;
    }

    // Deadline-today reconcile without a restart. Bug fix: the deadline
    // auto-pin used to run only on a full load (app start / sync / midnight),
    // so setting a deadline to today (or a task otherwise becoming due today)
    // while the app was open did NOT auto-pin until the app was restarted.
    // After: if a non-suppressed deadline-today leaf isn't already in the list,
    // do a full reload so _loadTodaysTasksInner merges and persists it. The
    // `every` short-circuits to a no-op once everything due today is present,
    // so there's no reload loop. This runs on every provider notification, so
    // the cheap hasDeadlineDueToday() guard skips the recursive descendant
    // walk + suppression lookup entirely on days with nothing due today.
    if (await db.hasDeadlineDueToday()) {
      _deadlineTodayIds = await db.getDeadlinePinLeafIds();
      final suppressedForReconcile = await db.getDeadlineSuppressedIds(today);
      final autoPinIds = _deadlineTodayIds.difference(suppressedForReconcile);
      final currentIds = _todaysTasks.map((t) => t.id!).toSet();
      if (!autoPinIds.every(currentIds.contains)) {
        await _reloadPreservingUndoState();
        return;
      }
    } else {
      _deadlineTodayIds = {};
    }

    if (_todaysTasks.isEmpty) {
      // Nothing to refresh — but still update the "+N others done today" badge.
      if (!mounted) return;
      await _loadOtherDoneToday();
      if (!mounted) return;
      setState(() {});
      return;
    }

    if (!mounted) return;
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    final refreshed = <Task>[];
    for (final t in _todaysTasks) {
      if (leafIdSet.contains(t.id)) {
        // Still a leaf — re-fetch fresh data
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null) {
          refreshed.add(fresh);
          // Detect "worked on today" done externally (e.g. from All Tasks leaf detail).
          // Skip tasks explicitly uncompleted this session to prevent race
          // condition: unawaited refreshSnapshots re-adding tasks mid-uncomplete.
          if (fresh.isWorkedOnToday && !_completedIds.contains(fresh.id) &&
              !_explicitlyUncompletedIds.contains(fresh.id)) {
            _completedIds.add(fresh.id!);
          }
        }
      } else {
        // No longer a leaf — keep only if completed/done. Otherwise drop it
        // (manual model: no auto-replacement with a descendant).
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null &&
            (_completedIds.contains(t.id) || fresh.isCompleted || fresh.isWorkedOnToday)) {
          _completedIds.add(fresh.id!);
          refreshed.add(fresh);
        }
      }
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
    _todaysTasks = refreshed;
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {});
    await _persistAndTrim();
  }

  /// Trims excess undone tasks past the cap and persists. Calls setState if
  /// the list actually shrank so the UI updates immediately. With the
  /// implicit-pin model every member is pinned, so this is effectively
  /// only a safety net for legacy state carrying unpinned slots.
  Future<void> _persistAndTrim() async {
    final currentIds = _todaysTasks.map((t) => t.id!).toList();
    final pinnedIds = currentIds.toSet();
    final trimmedIds = TodaysFivePinHelper.trimExcess(
      currentIds, _completedIds, pinnedIds,
    );
    if (trimmedIds.length < currentIds.length) {
      final trimmedSet = trimmedIds.toSet();
      _todaysTasks.removeWhere((t) => !trimmedSet.contains(t.id));
      if (mounted) setState(() {});
    }
    await _persist();
  }

  Future<void> _persist() async {
    final currentIds = _todaysTasks.map((t) => t.id!).toList();
    await DatabaseHelper().saveTodaysFiveState(
      date: _todayKey(),
      taskIds: currentIds,
      completedIds: _completedIds,
      workedOnIds: _workedOnIds,
      // Implicit-pin model: every member of taskIds is pinned by definition.
      pinnedIds: currentIds.toSet(),
    );
    if (mounted) {
      context.read<SyncService>().onTodaysFivePersisted();
    }
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
    final taskIds = allTasks.map((t) => t.id!).toList();
    _effectiveDeadlines = await db.getEffectiveDeadlines(taskIds);
    _scheduledTodayIds = await db.getEffectiveScheduledTodayIds(taskIds);
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
  Color _deadlineIconColor(({String deadline, String type}) info, ColorScheme colorScheme) {
    return deadlineDisplayColor(info.deadline, info.type, colorScheme);
  }

  String _shortenPath(String path) => shortenAncestorPath(path);

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
    _explicitlyUncompletedIds.remove(taskId);
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

  /// Shows a bottom sheet: "In progress" / "Done today" / "Done for good!" /
  /// "Remove from Today's 5".
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
              ListTile(
                leading: Icon(Icons.close, color: colorScheme.onSurfaceVariant),
                title: const Text("Remove from Today’s 5"),
                subtitle: const Text("Take this off today’s list"),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmRemoveFromTodaysFive(task);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows an "are you sure?" confirmation, then removes [task] from
  /// Today's 5. Implicit-pin model: every task in Today's 5 is pinned,
  /// so removal is the only "unpin" action.
  Future<void> _confirmRemoveFromTodaysFive(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Remove from Today’s 5?"),
        content: Text('"${task.name}" will be taken off today’s list. You can add it back any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Record the removal as a suppression tombstone. Bug fix (Codex P2): this
    // used to fire only for deadline-today tasks, so removing a *non-deadline*
    // pinned task left no tombstone — another device (or a pull before our
    // push) re-added it via the local-only-pinned append and the removal
    // bounced back. The tombstone is synced (getDeadlineSuppressedSyncIds) and
    // drops the task from the merge on every device. Suppression is per task-id,
    // so removing this one never affects another task; a later re-pin clears it.
    await DatabaseHelper().suppressDeadlineAutoPin(_todayKey(), task.id!);
    _deadlineTodayIds.remove(task.id);
    if (!mounted) return;
    setState(() {
      _todaysTasks.removeWhere((t) => t.id == task.id);
      _completedIds.remove(task.id);
      _workedOnIds.remove(task.id);
    });
    await _persist();
  }

  Future<void> _stopWorking(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.unstartTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — stopped.');
  }

  Future<void> _markInProgress(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.startTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — on it!');
  }

  Future<void> _workedOnTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final wasStarted = task.isStarted;
    final previousLastWorkedAt = task.lastWorkedAt;
    _preWorkedOnLastWorkedAt[task.id!] = previousLastWorkedAt;
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
    await provider.markWorkedOn(task.id!);
    if (!wasStarted) await provider.startTask(task.id!);
    if (removeDeadline) {
      await provider.updateTaskDeadline(task.id!, null);
    }
    await _markDone(task.id!, workedOn: true, autoStarted: !wasStarted);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — nice work! We\'ll remind you again soon.', onUndo: () async {
      _preWorkedOnLastWorkedAt.remove(task.id);
      await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
      if (!wasStarted) await provider.unstartTask(task.id!);
      if (removeDeadline) {
        await provider.updateTaskDeadline(task.id!, task.deadline!, deadlineType: task.deadlineType);
      }
      if (!mounted) return;
      _explicitlyUncompletedIds.add(task.id!);
      await _unmarkDone(task.id!, workedOn: true, autoStarted: !wasStarted);
    });
  }

  Future<void> _completeNormalTask(Task task) async {
    final provider = context.read<TaskProvider>();

    // Check if completing this task will free any dependents — confirm first.
    final dependentNames = await provider.getDependentTaskNames(task.id!);
    if (!mounted) return;
    if (!await confirmDependentUnblock(context, task.name, dependentNames)) return;
    if (!mounted) return;

    await showCompletionAnimation(context);
    if (!mounted) return;
    final removedDeps = await provider.completeTaskOnly(task.id!);
    await _markDone(task.id!, workedOn: false, autoStarted: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" done!', onUndo: () async {
      await provider.uncompleteTask(task.id!, restoredDeps: removedDeps);
      if (!mounted) return;
      await _unmarkDone(task.id!, workedOn: false, autoStarted: false);
    });
  }

  /// Handles the check action on a Today's 5 task.
  /// Always shows bottom sheet: "Done today" vs "Done for good!"
  Future<void> _handleTaskDone(Task task) async {
    _showTaskOptions(task);
  }

  /// If [task] is no longer a leaf (e.g. user added subtasks), removes it
  /// from [_todaysTasks] and unpins it. Manual model: no auto-replacement.
  Future<void> _removeIfNoLongerLeaf(Task task) async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    if (leafIdSet.contains(task.id)) return;

    final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
    if (idx < 0) return;

    if (!mounted) return;
    setState(() {
      _todaysTasks.removeAt(idx);
    });
  }

  /// Uncompletes a task that was marked done in Today's 5.
  /// Correctly reverts "Done today" (unmark worked-on + unstart) vs
  /// "Done for good!" (uncomplete). If the task is no longer a leaf,
  /// removes it from Today's 5 (no auto-replacement in manual mode).
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
    _explicitlyUncompletedIds.add(task.id!);
    await _unmarkDone(task.id!, workedOn: wasWorkedOn, autoStarted: wasAutoStarted);
    if (!mounted) return;
    await _removeIfNoLongerLeaf(task);

    if (!mounted) return;
    final wasRemoved = !_todaysTasks.any((t) => t.id == task.id);
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, wasRemoved
        ? '"${task.name}" restored and removed from Today\'s 5 (it has subtasks now).'
        : '"${task.name}" restored.');
  }

  /// Bottom sheet for the FAB: "Create new task" / "Pick existing task".
  void _showAddToTodaysSheet() {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Add to Today’s 5",
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.add_circle_outline, color: colorScheme.primary),
                title: const Text('Create new task'),
                subtitle: const Text('Make a fresh task and pin it'),
                onTap: () {
                  Navigator.pop(ctx);
                  _handleCreateNewForToday();
                },
              ),
              ListTile(
                leading: Icon(Icons.search, color: colorScheme.tertiary),
                title: const Text('Pick existing task'),
                subtitle: const Text('Search or browse your tasks'),
                onTap: () {
                  Navigator.pop(ctx);
                  _handlePickExistingForToday();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Create-new flow: opens AddTaskDialog (no pin toggle — pin is implicit),
  /// inserts the task at root, then pins it. [initialName] pre-fills the name
  /// field — used by the pick-existing dialog's "Create ..." affordance so
  /// an empty search can spin up (and pin) a brand-new task named after the
  /// search term.
  Future<void> _handleCreateNewForToday({String? initialName}) async {
    if (_todaysTasks.length >= maxPins) {
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, "Today’s 5 is full — remove one first");
      return;
    }
    final result = await showDialog<AddTaskResult>(
      context: context,
      builder: (_) => AddTaskDialog(
        showPinOption: false,
        showInboxOption: true,
        initialName: initialName,
      ),
    );
    if (!mounted || result == null) return;
    if (result is! SingleTask) return; // brain dump not offered for this flow

    final provider = context.read<TaskProvider>();
    // deferNotify so we can pin before refreshSnapshots fires and overwrites
    // (same race fixed in task_list_screen for the All Tasks tab pin flow).
    final taskId = await provider.addTask(
      result.name,
      url: result.url,
      isInbox: result.addToInbox,
      atRoot: true,
      deferNotify: true,
    );
    try {
      if (mounted) await _pinTaskInTodaysFive(taskId);
    } finally {
      await provider.refreshAfterMutation();
    }
  }

  /// Pick-existing flow: opens TaskPickerDialog filtered to leaf tasks not
  /// already in Today's 5, then pins the selection.
  Future<void> _handlePickExistingForToday() async {
    if (_todaysTasks.length >= maxPins) {
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, "Today’s 5 is full — remove one first");
      return;
    }
    final provider = context.read<TaskProvider>();
    final alreadyIn = _todaysTasks.map((t) => t.id!).toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (dialogCtx) => TaskPickerDialog(
        title: "Pin a task to Today’s 5",
        browse: TaskBrowseConfig(provider: provider, excludeIds: alreadyIn),
        // Empty search → create a brand-new task named after the query and pin
        // it, reusing the create-new flow (pin implicit) with the name filled.
        onCreateTask: (name) {
          Navigator.of(dialogCtx).pop();
          _handleCreateNewForToday(initialName: name);
        },
      ),
    );
    if (selected == null || !mounted) return;
    await _pinTaskInTodaysFive(selected.id!);
  }

  /// Persists a pin into Today's 5 and updates local widget state. Both entry
  /// points (create-new and pick-existing) are ALWAYS-ADD, never a toggle.
  ///
  /// Bug fix: pick-existing's exclude-list is snapshotted when the picker opens,
  /// so a task can slip into Today's 5 in the interim (pinned from All Tasks, or
  /// pulled via sync) before the user selects it. The old code called
  /// [TodaysFivePinHelper.togglePin] here, which would then REMOVE the
  /// just-selected task — the opposite of intent. Guarding on already-present +
  /// [pinNewTask] makes this a true idempotent add. (A freshly created task is
  /// never already present, so create-new takes the same path safely.)
  Future<void> _pinTaskInTodaysFive(int taskId) async {
    final db = DatabaseHelper();
    final today = _todayKey();
    final saved = await db.loadTodaysFiveState(today) ?? TodaysFiveData(
      date: today, taskIds: const [], completedIds: const {},
      workedOnIds: const {}, pinnedIds: const {},
    );
    // Already in Today's 5 → nothing to do (never toggle it back off).
    if (saved.taskIds.contains(taskId)) return;
    final result = TodaysFivePinHelper.pinNewTask(saved, taskId);
    if (result == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Couldn\'t pin — Today\'s 5 is full');
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
    // Manually pinning a task back clears any prior deadline-suppression, so a
    // removed-then-re-added deadline-today task is treated as an intentional
    // member again (and a later removal can re-suppress it).
    await db.unsuppressDeadlineAutoPin(today, taskId);
    // Reload from DB so the new task's snapshot, paths, and deadline/schedule
    // metadata are populated for the card. _reloadFromDb clears local state
    // and re-runs the full _loadTodaysTasksInner pipeline.
    if (mounted) await _reloadFromDb();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final completedCount = _completedIds.length;
    final totalCount = _todaysTasks.length;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      // Hide the + FAB once Today's 5 is full (maxPins tasks). It reappears
      // when the user removes one, so there's never an add button that can
      // only fail with a "full" message.
      floatingActionButton: _todaysTasks.length >= maxPins
          ? null
          : FloatingActionButton(
              onPressed: _showAddToTodaysSheet,
              tooltip: 'Add to Today’s 5',
              child: const Icon(Icons.add),
            ),
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
            const SizedBox(height: 2),
            Text(
              "Today\u2019s 5",
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 16,
                fontWeight: FontWeight.w300,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        toolbarHeight: 72,
        actions: [
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.nightlight_round, size: 20),
              onPressed: () async {
                // Simulate midnight rollover: set _loadedDateKey to yesterday
                // so refreshSnapshots detects a date mismatch and triggers
                // _reloadFromDb → _loadTodaysTasksInner (same as real midnight).
                final messenger = ScaffoldMessenger.of(context);
                final yesterday = DateTime.now().subtract(const Duration(days: 1));
                _loadedDateKey = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
                // Delete today's saved state so the reload lands in the
                // manual-model empty state ("Nothing pinned yet") — there is no
                // auto-pick to re-populate it.
                await DatabaseHelper().deleteTodaysFiveState(_todayKey());
                await refreshSnapshots();
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Simulated midnight rollover')),
                  );
                }
              },
              tooltip: 'Simulate midnight rollover',
            ),
          const ProfileIcon(),
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return IconButton(
                icon: Icon(themeProvider.icon, size: 22),
                onPressed: themeProvider.toggle,
                tooltip: 'Toggle theme',
              );
            },
          ),
          IconButton(
            icon: const Icon(archiveIcon, size: 22),
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
        ],
      ),
      // Empty state: a clean centered hero. "Also done today" is intentionally
      // NOT shown here — it only appears once Today's 5 has at least one entry
      // (the populated branch below).
      body: _todaysTasks.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.push_pin_outlined, size: 64, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Nothing pinned yet',
                    style: textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the + button to pick a task to focus on today.',
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
            // Segmented progress bar
            _buildSegmentedProgress(colorScheme, totalCount, completedCount),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: completedCount == 0
                        ? _motivationalText()
                        : completedCount == totalCount
                            ? 'All $totalCount done!'
                            : '$completedCount of $totalCount done',
                    style: completedCount == totalCount && totalCount > 0
                        ? const TextStyle(color: Color(0xFF66BB6A), fontWeight: FontWeight.w500)
                        : null,
                  ),
                  if (_otherDoneToday.isNotEmpty)
                    TextSpan(
                      text: '  +${_otherDoneToday.length} ${_otherDoneToday.length == 1 ? 'other' : 'others'}',
                      style: TextStyle(
                        color: completedCount == totalCount && totalCount > 0
                            ? const Color(0xFF66BB6A).withAlpha(140)
                            : colorScheme.primary.withAlpha(180),
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
    // Implicit-pin model: every task is "pinned" by membership, so the
    // only distinction left is undone vs done.
    final undone = <int>[];
    final done = <int>[];
    for (int i = 0; i < _todaysTasks.length; i++) {
      if (_completedIds.contains(_todaysTasks[i].id)) {
        done.add(i);
      } else {
        undone.add(i);
      }
    }

    return ListView(
      children: [
        for (final i in undone)
          _buildTaskCard(context, _todaysTasks[i], false),
        if (done.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            icon: Icons.check_circle_outline,
            label: 'Done',
            color: colorScheme.primary,
            topPadding: undone.isEmpty ? 0 : 12,
          ),
          for (final i in done)
            _buildTaskCard(context, _todaysTasks[i], true),
        ],
        if (_otherDoneToday.isNotEmpty)
          _buildOtherDoneBox(context, textTheme, colorScheme),
      ],
    );
  }


  Widget _buildSegmentedProgress(ColorScheme colorScheme, int total, int completed) {
    if (total == 0) return const SizedBox.shrink();
    return Row(
      children: List.generate(total, (i) {
        final isDone = i < completed;
        final isFirst = i == 0;
        final isLast = i == total - 1;
        return Expanded(
          child: Container(
            height: 8,
            margin: EdgeInsets.only(
              left: isFirst ? 0 : 1.5,
              right: isLast ? 0 : 1.5,
            ),
            decoration: BoxDecoration(
              color: isDone
                  ? const Color(0xFF66BB6A)
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.horizontal(
                left: isFirst ? const Radius.circular(4) : Radius.zero,
                right: isLast ? const Radius.circular(4) : Radius.zero,
              ),
            ),
          ),
        );
      }),
    );
  }

  String _motivationalText() {
    const texts = [
      'Completing even 1 is a win!',
      'Pick one and start small.',
      'One step at a time.',
      'Just begin \u2014 momentum follows.',
      'You\u2019ve got this.',
    ];
    // Use today's date as seed for daily rotation
    final now = DateTime.now();
    final dayIndex = (now.year * 366 + now.month * 31 + now.day) % texts.length;
    return texts[dayIndex];
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    double topPadding = 0,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: color.withAlpha(80),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildCardSubtitle(Task task, bool isDone, ColorScheme colorScheme, TextTheme textTheme) {
    final hasPath = _taskPaths.containsKey(task.id);
    final hasDeadline = _effectiveDeadlines.containsKey(task.id);
    final isScheduled = _scheduledTodayIds.contains(task.id);
    final hasIcons = task.isHighPriority || task.isSomeday || hasDeadline || isScheduled || (task.isStarted && !isDone);
    if (!hasPath && !hasIcons) return const SizedBox.shrink();

    final children = <Widget>[];
    if (hasPath) {
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withAlpha(20),
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
      );
    }
    if (hasIcons) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (task.isHighPriority)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.flag, size: 14, color: colorScheme.error),
              ),
            if (task.isSomeday)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.bedtime, size: 14, color: Color(0xFF7EB8D8)),
              ),
            if (hasDeadline)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(deadlineIcon, size: 14,
                    color: _deadlineIconColor(
                      _effectiveDeadlines[task.id]!, colorScheme),
                ),
              ),
            if (isScheduled)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(scheduledTodayIcon, size: 14,
                    color: colorScheme.tertiary),
              ),
            if (task.isStarted && !isDone)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.play_circle_filled, size: 14,
                    color: colorScheme.tertiary),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildTaskCard(
    BuildContext context,
    Task task,
    bool isDone,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('task_${task.id}_$isDone'),
      color: colorScheme.surfaceContainerHigh,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.onSurface.withAlpha(20),
        ),
      ),
      child: Opacity(
        opacity: isDone ? 0.38 : 1.0,
        child: ListTile(
          leading: isDone
              ? Icon(Icons.check_circle, color: const Color(0xFF66BB6A))
              : Icon(Icons.radio_button_unchecked,
                  color: colorScheme.onSurfaceVariant),
          title: Text(
            task.name,
            style: textTheme.bodyLarge?.copyWith(
              decoration: isDone ? TextDecoration.lineThrough : null,
              decorationColor: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          subtitle: _buildCardSubtitle(task, isDone, colorScheme, textTheme),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDone)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _confirmRemoveFromTodaysFive(task),
                  tooltip: "Remove from Today’s 5",
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
            return GestureDetector(
              onTap: hasOverflow ? () => setState(() => _otherDoneExpanded = !_otherDoneExpanded) : null,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                  const SizedBox(height: 8),
                  _buildOtherDoneChips(context),
                ],
              ),
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
