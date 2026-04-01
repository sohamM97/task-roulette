import 'dart:math';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import '../data/xp_config.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';
import '../models/task_schedule.dart';
import '../utils/display_utils.dart';
import '../utils/inbox_scoring.dart';

class TaskProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper();
  final Random _random = Random();

  /// Exponential base for diversity penalty in pickWeightedN.
  /// After n picks from the same root, remaining same-root tasks get
  /// weight × (this ^ n). Lower = stronger penalty.
  static const _diversityPenaltyBase = 0.3;

  /// Callback invoked after every local mutation, used by SyncService
  /// to schedule a debounced push.
  void Function()? onMutation;

  /// Callback invoked when XP should be awarded/revoked.
  /// Parameters: (eventType, xpAmount, taskId, isHighPriority).
  /// Wired to ProgressionProvider in main.dart.
  void Function(String eventType, int xpAmount, int? taskId, {bool isHighPriority})? onXpEarned;

  List<Task> _tasks = [];
  List<Task> get tasks => _tasks;

  /// Blocked task ID → name of the task it depends on.
  Map<int, String> _blockedByNames = {};
  Set<int> get blockedTaskIds => _blockedByNames.keys.toSet();
  Map<int, String> get blockedByNames => _blockedByNames;

  /// Dependent task ID → blocker task ID (only for blockers present as siblings).
  /// Used by [_reorderByDependencyChains] to group dependents after their blocker.
  Map<int, int> _blockedByTaskId = {};

  /// Task ID → list of parent names for each task in the current view.
  Map<int, List<String>> _parentNamesMap = {};
  Map<int, List<String>> get parentNamesMap => _parentNamesMap;

  /// Task ID → effective deadline info (own or inherited) for each task in current view.
  Map<int, ({String deadline, String type})> _effectiveDeadlines = {};
  Map<int, ({String deadline, String type})> get effectiveDeadlines => _effectiveDeadlines;

  /// Leaf task IDs scheduled for today (own or inherited from ancestor).
  Set<int> _scheduledTodayIds = {};
  Set<int> get scheduledTodayIds => _scheduledTodayIds;

  /// null means we're at the root level
  Task? _currentParent;
  Task? get currentParent => _currentParent;

  /// Navigation stack for back navigation
  final List<Task?> _parentStack = [];

  Future<void> loadRootTasks() async {
    _currentParent = null;
    _parentStack.clear();
    await _refreshCurrentList();
  }

  /// Reload the current view (root or children) without resetting navigation.
  Future<void> refreshCurrentView() async {
    await _refreshCurrentList();
  }

  Future<void> navigateInto(Task task) async {
    _parentStack.add(_currentParent);
    // Reload from DB to avoid stale data (e.g. inbox tasks cached in local state).
    _currentParent = await _db.getTaskById(task.id!) ?? task;
    await _refreshCurrentList();
  }

  Future<bool> navigateBack() async {
    if (_parentStack.isEmpty) return false;
    _currentParent = _parentStack.removeLast();
    await _refreshCurrentList();
    return true;
  }

  bool get isRoot => _currentParent == null;

  /// Full breadcrumb path: [root(null), grandparent, parent, current].
  /// Includes the current task. Root is represented as null.
  List<Task?> get breadcrumb {
    return [..._parentStack, _currentParent];
  }

  /// Navigate to a specific level in the breadcrumb.
  /// Level 0 = root, 1 = first task, etc.
  Future<void> navigateToLevel(int level) async {
    if (level < 0 || level >= breadcrumb.length) return;
    final target = breadcrumb[level];
    // Trim the stack to just the entries before the target level
    _parentStack.removeRange(level, _parentStack.length);
    _currentParent = target;
    await _refreshCurrentList();
  }

  /// Inserts multiple tasks in a single transaction, refreshes once at the end.
  Future<void> addTasksBatch(List<String> names, {bool isInbox = false}) async {
    final tasks = names.map((name) => Task(name: name, isInbox: isInbox)).toList();
    await _db.insertTasksBatch(tasks, _currentParent?.id);
    await _refreshAfterMutation();
  }

  /// Adds a task and returns its ID.
  ///
  /// When [deferNotify] is true, skips [_refreshAfterMutation] so the caller
  /// can perform follow-up DB writes (e.g. pinning in Today's 5) before
  /// listeners fire. The caller MUST call [refreshAfterMutation] afterwards.
  Future<int> addTask(String name, {String? url, List<int>? additionalParentIds, bool isInbox = false, bool deferNotify = false}) async {
    final task = Task(name: name, url: url, isInbox: isInbox);
    final taskId = await _db.insertTask(task);

    if (_currentParent != null) {
      await _db.addRelationship(_currentParent!.id!, taskId);
    }

    if (additionalParentIds != null) {
      for (final parentId in additionalParentIds) {
        if (parentId != _currentParent?.id) {
          await _db.addRelationship(parentId, taskId);
        }
      }
    }

    // Bug fix: without deferNotify, _refreshAfterMutation() fired immediately
    // after task insert, triggering notifyListeners -> refreshSnapshots() ->
    // _persist(), which overwrote the pin before _pinNewTaskInTodays5 could
    // save it. deferNotify: true skips this call so the caller can persist
    // the pin first, then call refreshAfterMutation() explicitly.
    if (!deferNotify) await _refreshAfterMutation();
    return taskId;
  }

  /// Deletes a task and returns info needed for undo.
  Future<({Task task, List<int> parentIds, List<int> childIds, List<int> dependsOnIds, List<int> dependedByIds, List<TaskSchedule> schedules})> deleteTask(int taskId) async {
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    final rels = await _db.deleteTaskWithRelationships(taskId);
    await _refreshAfterMutation();
    return (
      task: task,
      parentIds: rels.parentIds,
      childIds: rels.childIds,
      dependsOnIds: rels.dependsOnIds,
      dependedByIds: rels.dependedByIds,
      schedules: rels.schedules,
    );
  }

  Future<void> restoreTask(
    Task task,
    List<int> parentIds,
    List<int> childIds, {
    List<int> dependsOnIds = const [],
    List<int> dependedByIds = const [],
    List<({int parentId, int childId})> removeReparentLinks = const [],
    List<TaskSchedule> schedules = const [],
  }) async {
    await _db.restoreTask(task, parentIds, childIds,
        dependsOnIds: dependsOnIds,
        dependedByIds: dependedByIds,
        removeReparentLinks: removeReparentLinks,
        schedules: schedules);
    await _refreshAfterMutation();
  }

  /// Returns true if a task has at least one child.
  Future<bool> hasChildren(int taskId) async {
    return _db.hasChildren(taskId);
  }

  /// Deletes a task and reparents its children to its parents.
  /// Returns info needed for undo.
  Future<({
    Task task,
    List<int> parentIds,
    List<int> childIds,
    List<int> dependsOnIds,
    List<int> dependedByIds,
    List<({int parentId, int childId})> addedReparentLinks,
    List<TaskSchedule> schedules,
  })> deleteTaskAndReparent(int taskId) async {
    final result = await _db.deleteTaskAndReparentChildren(taskId);
    await _refreshAfterMutation();
    return result;
  }

  /// Deletes a task and its entire subtree. Returns info needed for undo.
  Future<({
    List<Task> deletedTasks,
    List<({int parentId, int childId})> deletedRelationships,
    List<({int taskId, int dependsOnId})> deletedDependencies,
    List<TaskSchedule> deletedSchedules,
  })> deleteTaskSubtree(int taskId) async {
    final result = await _db.deleteTaskSubtree(taskId);
    await _refreshAfterMutation();
    return result;
  }

  /// Restores a previously deleted subtree.
  Future<void> restoreTaskSubtree({
    required List<Task> tasks,
    required List<({int parentId, int childId})> relationships,
    required List<({int taskId, int dependsOnId})> dependencies,
    List<TaskSchedule> schedules = const [],
  }) async {
    await _db.restoreTaskSubtree(
      tasks: tasks,
      relationships: relationships,
      dependencies: dependencies,
      schedules: schedules,
    );
    await _refreshAfterMutation();
  }

  /// Marks a task as completed (archived) and navigates back.
  /// Returns the task and removed dependency links for undo support.
  /// Completing a task also removes dependency links where this task was
  /// a blocker — dependents are freed since the blocker no longer exists.
  Future<({Task task, List<({int taskId, int dependsOnId})> removedDeps})> completeTask(int taskId) async {
    // The task being completed may be _currentParent (leaf detail view's
    // Done button) rather than a member of _tasks.
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    final removedDeps = await _db.completeTask(taskId);
    // Award XP for completing from All Tasks (non-Today's-5 context)
    onXpEarned?.call(
      XpEventType.taskComplete, XpAmounts.taskComplete, taskId,
      isHighPriority: task.priority == 1,
    );
    onMutation?.call();
    await navigateBack();
    return (task: task, removedDeps: removedDeps);
  }

  /// Marks a task as skipped and navigates back.
  /// Returns the task for undo support.
  Future<({Task task, List<({int taskId, int dependsOnId})> removedDeps})> skipTask(int taskId) async {
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    final removedDeps = await _db.skipTask(taskId);
    onMutation?.call();
    await navigateBack();
    return (task: task, removedDeps: removedDeps);
  }

  /// Un-skips a task and refreshes the list.
  /// Optionally restores dependency links that were removed on skip.
  Future<void> unskipTask(int taskId, {
    List<({int taskId, int dependsOnId})> restoredDeps = const [],
  }) async {
    await _db.unskipTask(taskId, restoredDeps: restoredDeps);
    await _refreshAfterMutation();
  }

  /// Re-skips a task (for undo-restore). Unlike skipTask(), this does
  /// not call navigateBack() since it's invoked from the archive screen.
  /// Discards removedDeps intentionally (restore-from-archive path).
  Future<void> reSkipTask(int taskId) async {
    await _db.skipTask(taskId);
    await _refreshAfterMutation();
  }

  /// Completes a task without navigating back. Used by Today's 5 screen
  /// which manages its own UI state separately.
  /// Returns removed dependency links for undo support.
  Future<List<({int taskId, int dependsOnId})>> completeTaskOnly(int taskId) async {
    final removedDeps = await _db.completeTask(taskId);
    await _refreshAfterMutation();
    return removedDeps;
  }

  /// Un-completes a task and refreshes the list.
  /// Optionally restores dependency links that were removed on completion.
  Future<void> uncompleteTask(int taskId, {
    List<({int taskId, int dependsOnId})> restoredDeps = const [],
  }) async {
    await _db.uncompleteTask(taskId, restoredDeps: restoredDeps);
    await _refreshAfterMutation();
  }

  Future<List<Task>> getParents(int childId) async {
    return _db.getParents(childId);
  }

  /// Returns archived parents of [childId].
  Future<List<Task>> getArchivedParents(int childId) async {
    return _db.getArchivedParents(childId);
  }

  /// Removes relationships to archived parents for [childId].
  Future<void> removeArchivedParentLinks(int childId, List<Task> archivedParents) async {
    for (final parent in archivedParents) {
      await _db.removeRelationship(parent.id!, childId);
    }
    await _refreshAfterMutation();
  }

  /// Re-adds a previously existing parent-child relationship (for undo).
  /// Skips cycle check since the relationship is known to be safe.
  // CR-fix I-42: was missing _refreshAfterMutation — undo-restored
  // relationships didn't refresh UI or trigger sync push.
  Future<void> addRelationship(int parentId, int childId) async {
    await _db.addRelationship(parentId, childId);
    await _refreshAfterMutation();
  }

  double _taskWeight(Task t, {Set<int>? scheduleBoostedIds, Map<int, int>? deadlineDaysMap, double normFactor = 1.0}) {
    double w = 1.0;

    // Priority: high = 3x
    if (t.isHighPriority) w *= 3.0;

    // Started: committed tasks = 2x. Someday tasks skip this.
    if (t.isStarted && !t.isSomeday) w *= 2.0;

    // Staleness: logarithmic curve, cap 2x. Someday tasks skip staleness.
    if (!t.isSomeday) {
      final lastTouched = t.lastWorkedAt ?? t.startedAt ?? t.createdAt;
      final daysSince = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(lastTouched))
          .inDays;
      final staleness = 1.0 + 0.25 * log(daysSince + 1);
      w *= staleness.clamp(1.0, 2.0);
    }

    // Novelty: added in last 3 days = 1.3x. Someday tasks skip this.
    if (!t.isSomeday) {
      final daysOld = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(t.createdAt))
          .inDays;
      if (daysOld <= 3) w *= 1.3;
    }

    // Deadline proximity: hyperbolic boost within 14-day window.
    // Uses inherited deadline from deadlineDaysMap if available (for leaves
    // under a parent with a deadline), falls back to task's own deadline.
    final daysUntil = (deadlineDaysMap != null && t.id != null && deadlineDaysMap.containsKey(t.id))
        ? deadlineDaysMap[t.id]
        : t.daysUntilDeadline;
    if (daysUntil != null) {
      final absD = daysUntil.abs();
      if (absD <= 14) {
        w *= 1.0 + 7.0 / (absD + 1);
      }
    }

    // Scheduled for today: 2.5x boost
    if (scheduleBoostedIds != null && t.id != null &&
        scheduleBoostedIds.contains(t.id)) {
      w *= 2.5;
    }

    // Root-size normalization: dampens volume advantage of large root categories
    w *= normFactor;

    return w;
  }

  Task? pickRandom() {
    final eligible = _tasks.where((t) =>
      !_blockedByNames.containsKey(t.id) &&
      !t.isWorkedOnToday
    ).toList();
    if (eligible.isEmpty) return null;

    final weights = eligible.map(_taskWeight).toList();
    final total = weights.fold(0.0, (a, b) => a + b);
    var roll = _random.nextDouble() * total;
    for (int i = 0; i < eligible.length; i++) {
      roll -= weights[i];
      if (roll <= 0) return eligible[i];
    }
    return eligible.last;
  }

  Future<List<Task>> getChildren(int taskId) async {
    return _db.getChildren(taskId);
  }

  /// Returns all leaf tasks (tasks with no children) for Today's 5 selection.
  Future<List<Task>> getAllLeafTasks() async {
    return _db.getAllLeafTasks();
  }

  /// Picks n tasks via weighted random without replacement.
  /// Tries to include at least 1 quick task if available.
  /// When [scheduleBoostedIds] is provided, tasks in that set get a 2.5x
  /// weight multiplier (scheduled for today).
  /// When [normData] is provided, applies root-size normalization and
  /// diversity penalty to spread picks across root categories.
  List<Task> pickWeightedN(List<Task> candidates, int n,
      {Set<int>? scheduleBoostedIds, Map<int, int>? deadlineDaysMap,
       NormalizationData? normData, Map<int, int>? existingRootPickCounts}) {
    if (candidates.isEmpty) return [];
    final eligible = candidates.where((t) =>
      !t.isWorkedOnToday
    ).toList();
    if (eligible.isEmpty) return [];

    final picked = <Task>[];
    final remaining = List<Task>.from(eligible);
    // Track how many picks came from each root (for diversity penalty).
    // Seed with existing picks (e.g. current Today's 5 tasks) so swap
    // accounts for what's already showing.
    final rootPickCounts = <int, int>{...?existingRootPickCounts};

    // Fill slots via weighted random
    while (picked.length < n && remaining.isNotEmpty) {
      final weights = <double>[];
      for (final t in remaining) {
        final nf = normData?.normFactors[t.id] ?? 1.0;
        var w = _taskWeight(t, scheduleBoostedIds: scheduleBoostedIds,
            deadlineDaysMap: deadlineDaysMap, normFactor: nf);

        // Diversity penalty: penalize tasks sharing roots with already-picked
        if (normData != null && rootPickCounts.isNotEmpty) {
          final roots = normData.leafToRoots[t.id] ?? <int>{};
          var maxPicks = 0;
          for (final r in roots) {
            final c = rootPickCounts[r] ?? 0;
            if (c > maxPicks) maxPicks = c;
          }
          if (maxPicks > 0) {
            w *= pow(_diversityPenaltyBase, maxPicks).toDouble();
          }
        }

        weights.add(w);
      }

      final total = weights.fold(0.0, (a, b) => a + b);
      var roll = _random.nextDouble() * total;
      Task? pick;
      for (int i = 0; i < remaining.length; i++) {
        roll -= weights[i];
        if (roll <= 0) { pick = remaining[i]; break; }
      }
      pick ??= remaining.last;
      picked.add(pick);
      remaining.remove(pick);

      // Update root pick counts
      if (normData != null) {
        final roots = normData.leafToRoots[pick.id] ?? <int>{};
        for (final r in roots) {
          rootPickCounts[r] = (rootPickCounts[r] ?? 0) + 1;
        }
      }
    }

    return picked;
  }

  /// Computes normalization data for fair Today's 5 selection.
  Future<NormalizationData> getNormalizationData(List<int> leafIds) =>
      _db.getNormalizationData(leafIds);

  Future<List<Task>> getRootTasks() async {
    return _db.getRootTasks();
  }

  Future<List<Task>> getAllTasks() async {
    return _db.getAllTasks();
  }

  Future<List<Task>> getArchivedTasks() async {
    return _db.getArchivedTasks();
  }

  Future<Map<int, List<String>>> getParentNamesForTaskIds(
    List<int> taskIds, {
    bool includeArchived = false,
  }) async {
    return _db.getParentNamesForTaskIds(taskIds, includeArchived: includeArchived);
  }

  /// Re-completes a task (for undo-restore). Unlike completeTask(), this does
  /// not call navigateBack() since it's invoked from the archive screen.
  /// Discards removed deps — restore-from-archive doesn't preserve dep links.
  Future<void> reCompleteTask(int taskId) async {
    await _db.completeTask(taskId); // removedDeps discarded intentionally
    await _refreshAfterMutation();
  }

  /// Permanently deletes a completed task. Returns info needed for undo.
  Future<({Task task, List<int> parentIds, List<int> childIds, List<int> dependsOnIds, List<int> dependedByIds, List<TaskSchedule> schedules})> permanentlyDeleteTask(int taskId, Task task) async {
    final rels = await _db.deleteTaskWithRelationships(taskId);
    await _refreshAfterMutation();
    return (
      task: task,
      parentIds: rels.parentIds,
      childIds: rels.childIds,
      dependsOnIds: rels.dependsOnIds,
      dependedByIds: rels.dependedByIds,
      schedules: rels.schedules,
    );
  }

  /// Marks a task as started (in progress).
  /// [awardXp] controls whether XP is awarded. Set to false when auto-starting
  /// from Today's 5 "Done today" (the screen handles XP itself).
  Future<void> startTask(int taskId, {bool awardXp = true}) async {
    await _db.startTask(taskId);
    // Update _currentParent in place so the leaf detail view reflects the change
    // immediately without needing to navigate away and back.
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        startedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (awardXp) {
      final task = await _db.getTaskById(taskId);
      onXpEarned?.call(
        XpEventType.taskStarted, XpAmounts.taskStarted, taskId,
        isHighPriority: task?.priority == 1,
      );
    }
    await _refreshAfterMutation();
  }

  /// Un-starts a task (removes in-progress state).
  Future<void> unstartTask(int taskId) async {
    await _db.unstartTask(taskId);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(startedAt: () => null);
    }
    await _refreshAfterMutation();
  }

  // --- Task dependency methods ---

  /// Adds a dependency: taskId depends on dependsOnId.
  /// Replaces any existing dependency (single dependency per task).
  /// Returns false if a cycle would be created.
  Future<bool> addDependency(int taskId, int dependsOnId) async {
    // Check: would this create a cycle in the dependency graph?
    if (taskId == dependsOnId) return false;
    final wouldCycle = await _db.hasDependencyPath(dependsOnId, taskId);
    if (wouldCycle) return false;
    // Single dependency: remove any existing before adding new
    await _db.removeAllDependencies(taskId);
    await _db.addDependency(taskId, dependsOnId);
    await _refreshAfterMutation();
    return true;
  }

  Future<void> removeDependency(int taskId, int dependsOnId) async {
    await _db.removeDependency(taskId, dependsOnId);
    await _refreshAfterMutation();
  }

  Future<List<Task>> getDependencies(int taskId) async {
    return _db.getDependencies(taskId);
  }

  /// Returns names of tasks that depend on [taskId] and will be freed
  /// when it is completed (excludes already-completed/skipped dependents).
  Future<List<String>> getDependentTaskNames(int taskId) async {
    return _db.getDependentTaskNames(taskId);
  }

  Future<Set<int>> getBlockedChildIds(List<int> childIds) async {
    return _db.getBlockedTaskIds(childIds);
  }

  Future<Map<int, List<String>>> getParentNamesMap() async {
    return _db.getParentNamesMap();
  }

  /// Links an existing task as a child of the current parent.
  /// Returns false if a cycle would be created.
  Future<bool> linkChildToCurrent(int childId) async {
    if (_currentParent == null) return false;
    final parentId = _currentParent!.id!;

    // Check: is parentId reachable from childId? (i.e., child is an ancestor of parent)
    final wouldCycle = await _db.hasPath(childId, parentId);
    if (wouldCycle) return false;

    await _db.addRelationship(parentId, childId);
    await _refreshAfterMutation();
    return true;
  }

  /// Adds another parent to a task.
  /// Returns false if a cycle would be created.
  Future<bool> addParentToTask(int taskId, int parentId) async {
    // Check: is parentId reachable from taskId? (i.e., the new parent is a descendant of the task)
    final wouldCycle = await _db.hasPath(taskId, parentId);
    if (wouldCycle) return false;

    await _db.addRelationship(parentId, taskId);
    await _refreshAfterMutation();
    return true;
  }

  /// Moves a task from the current parent to a new parent.
  /// Returns false if a cycle would be created or the task is already
  /// under the target parent.
  Future<bool> moveTask(int taskId, int newParentId) async {
    if (_currentParent == null) return false;
    final wouldCycle = await _db.hasPath(taskId, newParentId);
    if (wouldCycle) return false;
    final existingParents = await _db.getParentIds(taskId);
    if (existingParents.contains(newParentId)) return false;

    await _db.addRelationship(newParentId, taskId);
    await _db.removeRelationship(_currentParent!.id!, taskId);
    await _refreshAfterMutation();
    return true;
  }

  Future<void> renameTask(int taskId, String name) async {
    await _db.updateTaskName(taskId, name);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(name: name);
    }
    await _refreshAfterMutation();
  }

  Future<void> updateTaskUrl(int taskId, String? url) async {
    await _db.updateTaskUrl(taskId, url);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(url: () => url);
    }
    await _refreshAfterMutation();
  }

  Future<void> updateTaskPriority(int taskId, int priority) async {
    if (priority >= 1) {
      // Clear someday when marking as high priority
      await _db.updateTaskSomeday(taskId, false);
    }
    await _db.updateTaskPriority(taskId, priority);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        priority: priority,
        isSomeday: priority >= 1 ? false : null,
      );
    }
    await _refreshAfterMutation();
  }

  /// Toggles starred flag. Assigns next star_order when starring.
  /// Pass [starOrder] to restore a specific position (e.g. undo).
  Future<void> updateTaskStarred(int taskId, bool isStarred,
      {int? starOrder}) async {
    if (isStarred && starOrder == null) {
      final maxOrder = await _db.getMaxStarOrder();
      starOrder = maxOrder + 1;
    }
    await _db.updateTaskStarred(taskId, isStarred, starOrder: starOrder);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        isStarred: isStarred,
        starOrder: () => starOrder,
      );
    }
    await _refreshAfterMutation();
  }

  Future<List<Task>> getStarredTasks() async {
    return _db.getStarredTasks();
  }

  /// Reassigns sequential star_order 0..N-1 for the given task IDs.
  // CR-fix I-43: was calling onMutation directly — inconsistent with pattern,
  // sync could fire before provider state refreshed.
  Future<void> reorderStarredTasks(List<int> taskIds) async {
    await _db.reorderStarredTasks(taskIds);
    await _refreshAfterMutation();
  }

  /// Toggles someday flag. Mutually exclusive with high priority.
  Future<void> updateTaskSomeday(int taskId, bool isSomeday) async {
    if (isSomeday) {
      // Clear priority when marking as someday
      await _db.updateTaskPriority(taskId, 0);
    }
    await _db.updateTaskSomeday(taskId, isSomeday);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        isSomeday: isSomeday,
        priority: isSomeday ? 0 : null,
      );
    }
    await _refreshAfterMutation();
  }

  Future<void> updateTaskDeadline(int taskId, String? deadline, {String deadlineType = 'due_by'}) async {
    await _db.updateTaskDeadline(taskId, deadline, deadlineType: deadlineType);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        deadline: () => deadline,
        deadlineType: deadlineType,
      );
    }
    await _refreshAfterMutation();
  }

  Future<Set<int>> getDeadlinePinLeafIds() async {
    return _db.getDeadlinePinLeafIds();
  }

  Future<Map<int, int>> getDeadlineBoostedLeafData() async {
    return _db.getDeadlineBoostedLeafData();
  }

  Future<({String deadline, String deadlineType, String sourceName})?> getInheritedDeadline(int taskId) async {
    return _db.getInheritedDeadline(taskId);
  }

  Future<void> markWorkedOn(int taskId) async {
    await _db.markWorkedOn(taskId);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        lastWorkedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _refreshAfterMutation();
  }

  /// Marks a task as worked on, optionally starts it, and navigates back.
  /// Single DB refresh instead of 2-3 separate ones.
  Future<void> markWorkedOnAndNavigateBack(int taskId, {bool alsoStart = false}) async {
    await _db.markWorkedOn(taskId);
    if (alsoStart) await _db.startTask(taskId);
    onMutation?.call();
    await navigateBack(); // single _refreshCurrentList()
  }

  Future<void> unmarkWorkedOn(int taskId, {int? restoreTo}) async {
    await _db.unmarkWorkedOn(taskId, restoreTo: restoreTo);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(lastWorkedAt: () => restoreTo);
    }
    await _refreshAfterMutation();
  }

  /// Removes a task from the current parent only (does not delete the task).
  /// If it was the last parent, the task becomes a root task.
  Future<void> unlinkFromCurrentParent(int childId) async {
    if (_currentParent == null) return;
    await _db.removeRelationship(_currentParent!.id!, childId);
    await _refreshAfterMutation();
  }

  Future<List<int>> getParentIds(int childId) async {
    return _db.getParentIds(childId);
  }

  Future<List<int>> getChildIds(int parentId) async {
    return _db.getChildIds(parentId);
  }

  Future<Set<int>> getChildIdsForParents(List<int> parentIds) async {
    return _db.getChildIdsForParents(parentIds);
  }

  Future<List<int>> getRootTaskIds() async {
    return _db.getRootTaskIds();
  }

  Future<List<TaskRelationship>> getAllRelationships() async {
    return _db.getAllRelationships();
  }

  /// Navigate directly to a task, clearing the stack.
  /// Sets stack to [null] so back returns to root.
  Future<void> navigateToTask(Task task) async {
    final ancestors = await _db.getAncestorPath(task.id!);
    _parentStack.clear();
    _parentStack.add(null); // root
    for (final ancestor in ancestors) {
      _parentStack.add(ancestor);
    }
    _currentParent = task;
    await _refreshCurrentList();
  }

  /// Loads blocked-task info, dependency pairs, and parent names for the
  /// current _tasks. The queries are independent, so they run concurrently.
  Future<void> _loadAuxiliaryData() async {
    final taskIds = _tasks.map((t) => t.id!).toList();
    // Include currentParent so leaf detail can also look up its parents.
    final parentNameIds = _currentParent?.id != null
        ? [...taskIds, _currentParent!.id!]
        : taskIds;
    late Map<int, ({int blockerId, String blockerName})> blockedInfo;
    late Map<int, int> siblingDeps;
    late Map<int, List<String>> parentNames;
    late Map<int, ({String deadline, String type})> effectiveDeadlines;
    late Set<int> scheduledTodayIds;
    await Future.wait([
      // Include currentParent so leaf detail view can check its blocked state.
      _db.getBlockedTaskInfo(parentNameIds).then((v) => blockedInfo = v),
      _db.getSiblingDependencyPairs(taskIds).then((v) => siblingDeps = v),
      _db.getParentNamesForTaskIds(parentNameIds).then((v) => parentNames = v),
      _db.getEffectiveDeadlines(taskIds).then((v) => effectiveDeadlines = v),
      _db.getEffectiveScheduledTodayIds(taskIds).then((v) => scheduledTodayIds = v),
    ]);
    // Derive the simple name map for UI display
    _blockedByNames = {
      for (final e in blockedInfo.entries) e.key: e.value.blockerName,
    };
    // Use ALL sibling dependency pairs for positional ordering (not just active ones)
    _blockedByTaskId = siblingDeps;
    _parentNamesMap = parentNames;
    _effectiveDeadlines = effectiveDeadlines;
    _scheduledTodayIds = scheduledTodayIds;
  }

  /// Reorders _tasks so that dependent tasks appear immediately after their
  /// blocker, forming visual chains. Only affects tasks whose blocker is a
  /// sibling in the current view.
  void _reorderByDependencyChains() {
    if (_blockedByTaskId.isEmpty) return;

    // Build blocker → [dependents] map
    final dependents = <int, List<int>>{};
    for (final e in _blockedByTaskId.entries) {
      dependents.putIfAbsent(e.value, () => []).add(e.key);
    }

    // Set of task IDs that are dependents (will be placed after their blocker)
    final dependentIds = _blockedByTaskId.keys.toSet();

    // Index tasks by ID for fast lookup
    final taskById = <int, Task>{};
    for (final t in _tasks) {
      taskById[t.id!] = t;
    }

    // Walk chain from a head, depth-first.
    // CR-fix I-46: visited set prevents infinite recursion if data is corrupted.
    final visited = <int>{};
    void walkChain(int id, List<Task> out) {
      if (!visited.add(id)) return; // cycle — break
      final task = taskById[id];
      if (task == null) return;
      out.add(task);
      final deps = dependents[id];
      if (deps != null) {
        for (final depId in deps) {
          walkChain(depId, out);
        }
      }
    }

    final reordered = <Task>[];
    for (final task in _tasks) {
      // Skip dependents — they'll be emitted as part of their chain
      if (dependentIds.contains(task.id)) continue;
      walkChain(task.id!, reordered);
    }
    _tasks = reordered;
  }

  /// Refreshes the current list and notifies sync that a mutation occurred.
  /// Use this for all DB-mutating methods instead of bare [_refreshCurrentList].
  /// Public entry point for deferred-notify callers (see [addTask] deferNotify).
  Future<void> refreshAfterMutation() async => _refreshAfterMutation();

  Future<void> _refreshAfterMutation() async {
    await _refreshCurrentList();
    onMutation?.call();
  }

  Future<void> _refreshCurrentList() async {
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    // Load today's 5 IDs and pinned IDs for sort priority
    final today = todayDateKey();
    final todaysData = await _db.getTodaysFiveTaskAndPinIds(today);
    final pinnedIds = todaysData.pinnedIds;
    final todaysFiveIds = todaysData.taskIds;

    // Sort tiers (lower = higher priority):
    // 0: pinned in Today's 5
    // 1: high priority (from DB order — already sorted by priority DESC)
    // 2: in Today's 5 (unpinned)
    // 3: normal
    // 4: worked-on-today (push to end)
    int sortTier(Task t) {
      if (t.isWorkedOnToday) return 4;
      if (pinnedIds.contains(t.id)) return 0;
      if (t.isHighPriority) return 1;
      // Near-deadline tasks (≤3 days) sort at virtual high priority (due_by only)
      final daysUntil = t.daysUntilDeadline;
      if (daysUntil != null && daysUntil <= 3 && t.isDeadlineDueBy) return 1;
      if (todaysFiveIds.contains(t.id)) return 2;
      return 3;
    }

    _tasks.sort((a, b) {
      final tierA = sortTier(a);
      final tierB = sortTier(b);
      if (tierA != tierB) return tierA.compareTo(tierB);
      return 0; // preserve DB order within same tier
    });
    await _loadAuxiliaryData();
    _reorderByDependencyChains();
    notifyListeners();
    // onMutation is now called explicitly by _refreshAfterMutation()
  }

  // --- Schedule methods ---

  Future<List<TaskSchedule>> getSchedules(int taskId) async {
    return _db.getSchedulesForTask(taskId);
  }

  Future<void> updateSchedules(int taskId, List<TaskSchedule> schedules, {bool? isOverride}) async {
    await _db.replaceSchedules(taskId, schedules, isOverride: isOverride);
    await _refreshAfterMutation();
  }

  Future<bool> hasSchedule(int taskId) async {
    return _db.hasSchedules(taskId);
  }

  Future<Set<int>> getEffectiveScheduleDays(int taskId) async {
    return _db.getEffectiveScheduleDays(taskId);
  }

  Future<Set<int>> getInheritedScheduleDays(int taskId) async {
    return _db.getInheritedScheduleDays(taskId);
  }

  Future<List<({int id, String name, Set<int> days})>> getScheduleSources(int taskId) async {
    return _db.getScheduleSources(taskId);
  }

  Future<bool> isScheduleOverride(int taskId) async {
    return _db.isScheduleOverride(taskId);
  }

  Future<Set<int>> getScheduleBoostedLeafIds() async {
    return _db.getScheduleBoostedLeafIds();
  }

  Future<Map<int, List<int>>> getScheduledSourceToLeafMap() async {
    return _db.getScheduledSourceToLeafMap();
  }

  // --- Inbox methods ---

  Future<int> getInboxCount() => _db.getInboxCount();

  Future<List<Task>> getInboxTasks() => _db.getInboxTasks();

  /// Files an inbox task under a parent: adds the relationship and clears
  /// the inbox flag. Returns false if it would create a cycle.
  Future<bool> fileTask(int taskId, int parentId) async {
    final wouldCycle = await _db.hasPath(taskId, parentId);
    if (wouldCycle) return false;
    await _db.addRelationship(parentId, taskId);
    await _db.clearInboxFlag(taskId);
    await _refreshAfterMutation();
    return true;
  }

  /// Undoes a fileTask: removes the relationship and restores the inbox flag.
  Future<void> unfileTask(int taskId, int parentId) async {
    await _db.removeRelationship(parentId, taskId);
    await _db.setInboxFlag(taskId);
    await _refreshAfterMutation();
  }

  /// Undoes a dismissFromInbox: restores the inbox flag.
  Future<void> undoDismissFromInbox(int taskId) async {
    await _db.setInboxFlag(taskId);
    await _refreshAfterMutation();
  }

  /// Dismisses a task from inbox without assigning a parent (keeps it at root).
  Future<void> dismissFromInbox(int taskId) async {
    await _db.clearInboxFlag(taskId);
    await _refreshAfterMutation();
  }

  /// Computes parent suggestions for an inbox task, scoring by keyword match,
  /// recency of children, and sibling name similarity.
  Future<List<({Task task, double score})>> computeParentSuggestions(
    String taskName, {
    int limit = 5,
    int? excludeTaskId,
  }) async {
    final rawTasks = await _db.getAllTasks();
    final allTasks = excludeTaskId != null
        ? rawTasks.where((t) => t.id != excludeTaskId).toList()
        : rawTasks;
    if (allTasks.isEmpty) return [];

    final candidateIds = allTasks.map((t) => t.id!).toList();

    // Sequential to avoid sqflite deadlock (single-threaded DB queue)
    final recencyMap = await _db.getMostRecentChildCreatedAt(candidateIds);
    final childNamesMap = await _db.getChildNamesForParents(candidateIds);

    final taskTokens = tokenize(taskName);
    final now = DateTime.now().millisecondsSinceEpoch;

    final scored = <({Task task, double score})>[];
    for (final candidate in allTasks) {
      final candidateTokens = tokenize(candidate.name);
      final keywordScore = jaccardSimilarity(taskTokens, candidateTokens);

      // Substring boost: "Buy groceries" matches parent "Groceries"
      final substringScore = substringMatch(taskName, candidate.name);

      double recencyScore = 0.0;
      final lastChildCreated = recencyMap[candidate.id!];
      if (lastChildCreated != null) {
        final daysSince = (now - lastChildCreated) / (1000 * 60 * 60 * 24);
        recencyScore = exp(-daysSince / 7);
      }

      double siblingScore = 0.0;
      final childNames = childNamesMap[candidate.id!];
      if (childNames != null && childNames.isNotEmpty) {
        final allChildTokens = <String>{};
        for (final name in childNames) {
          allChildTokens.addAll(tokenize(name));
        }
        siblingScore = jaccardSimilarity(taskTokens, allChildTokens);
      }

      // Category boost: parents with more children are likely categories
      final childCount = childNames?.length ?? 0;
      final categoryBoost = childCount >= 3 ? 0.15 : childCount >= 1 ? 0.05 : 0.0;

      final score = 0.35 * keywordScore
          + 0.20 * substringScore
          + 0.15 * recencyScore
          + 0.15 * siblingScore
          + categoryBoost;
      if (score > 0.01) {
        scored.add((task: candidate, score: score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList();
  }
}
