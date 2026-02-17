import 'dart:math';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';

class TaskProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper();
  final Random _random = Random();

  List<Task> _tasks = [];
  List<Task> get tasks => _tasks;

  /// Task IDs that have at least one in-progress descendant.
  Set<int> _startedDescendantIds = {};
  Set<int> get startedDescendantIds => _startedDescendantIds;

  /// Blocked task ID → name of the task it depends on.
  Map<int, String> _blockedByNames = {};
  Set<int> get blockedTaskIds => _blockedByNames.keys.toSet();
  Map<int, String> get blockedByNames => _blockedByNames;

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

  Future<void> navigateInto(Task task) async {
    _parentStack.add(_currentParent);
    _currentParent = task;
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
    final target = breadcrumb[level];
    // Trim the stack to just the entries before the target level
    _parentStack.removeRange(level, _parentStack.length);
    _currentParent = target;
    await _refreshCurrentList();
  }

  /// Inserts multiple tasks in a single transaction, refreshes once at the end.
  Future<void> addTasksBatch(List<String> names) async {
    final tasks = names.map((name) => Task(name: name)).toList();
    await _db.insertTasksBatch(tasks, _currentParent?.id);
    await _refreshCurrentList();
  }

  Future<void> addTask(String name, {List<int>? additionalParentIds}) async {
    final task = Task(name: name);
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

    await _refreshCurrentList();
  }

  /// Deletes a task and returns info needed for undo.
  /// Returns a record of (task, parentIds, childIds, dependsOnIds, dependedByIds).
  Future<({Task task, List<int> parentIds, List<int> childIds, List<int> dependsOnIds, List<int> dependedByIds})> deleteTask(int taskId) async {
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    final rels = await _db.deleteTaskWithRelationships(taskId);
    await _refreshCurrentList();
    return (
      task: task,
      parentIds: rels['parentIds']!,
      childIds: rels['childIds']!,
      dependsOnIds: rels['dependsOnIds']!,
      dependedByIds: rels['dependedByIds']!,
    );
  }

  Future<void> restoreTask(
    Task task,
    List<int> parentIds,
    List<int> childIds, {
    List<int> dependsOnIds = const [],
    List<int> dependedByIds = const [],
    List<({int parentId, int childId})> removeReparentLinks = const [],
  }) async {
    await _db.restoreTask(task, parentIds, childIds,
        dependsOnIds: dependsOnIds,
        dependedByIds: dependedByIds,
        removeReparentLinks: removeReparentLinks);
    await _refreshCurrentList();
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
  })> deleteTaskAndReparent(int taskId) async {
    final result = await _db.deleteTaskAndReparentChildren(taskId);
    await _refreshCurrentList();
    return result;
  }

  /// Deletes a task and its entire subtree. Returns info needed for undo.
  Future<({
    List<Task> deletedTasks,
    List<({int parentId, int childId})> deletedRelationships,
    List<({int taskId, int dependsOnId})> deletedDependencies,
  })> deleteTaskSubtree(int taskId) async {
    final result = await _db.deleteTaskSubtree(taskId);
    await _refreshCurrentList();
    return result;
  }

  /// Restores a previously deleted subtree.
  Future<void> restoreTaskSubtree({
    required List<Task> tasks,
    required List<({int parentId, int childId})> relationships,
    required List<({int taskId, int dependsOnId})> dependencies,
  }) async {
    await _db.restoreTaskSubtree(
      tasks: tasks,
      relationships: relationships,
      dependencies: dependencies,
    );
    await _refreshCurrentList();
  }

  /// Marks a task as completed (archived) and navigates back.
  /// Returns the task for undo support.
  Future<Task> completeTask(int taskId) async {
    // The task being completed may be _currentParent (leaf detail view's
    // Done button) rather than a member of _tasks.
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    await _db.completeTask(taskId);
    await navigateBack();
    return task;
  }

  /// Marks a task as skipped and navigates back.
  /// Returns the task for undo support.
  Future<Task> skipTask(int taskId) async {
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId,
            orElse: () => throw StateError('Task $taskId not found in current list'));
    await _db.skipTask(taskId);
    await navigateBack();
    return task;
  }

  /// Un-skips a task and refreshes the list.
  Future<void> unskipTask(int taskId) async {
    await _db.unskipTask(taskId);
    await _refreshCurrentList();
  }

  /// Re-skips a task (for undo-restore). Unlike skipTask(), this does
  /// not call navigateBack() since it's invoked from the archive screen.
  Future<void> reSkipTask(int taskId) async {
    await _db.skipTask(taskId);
  }

  /// Completes a task without navigating back. Used by Today's 5 screen
  /// which manages its own UI state separately.
  Future<void> completeTaskOnly(int taskId) async {
    await _db.completeTask(taskId);
    await _refreshCurrentList();
  }

  /// Un-completes a task and refreshes the list.
  Future<void> uncompleteTask(int taskId) async {
    await _db.uncompleteTask(taskId);
    await _refreshCurrentList();
  }

  Future<List<Task>> getParents(int childId) async {
    return _db.getParents(childId);
  }

  double _taskWeight(Task t) {
    double w = 1.0;

    // Priority: high = 3x
    if (t.isHighPriority) w *= 3.0;

    // Quick task: momentum starter = 1.5x
    if (t.isQuickTask) w *= 1.5;

    // Started: committed tasks = 2x
    if (t.isStarted) w *= 2.0;

    // Staleness: +10% per day untouched, max 4x at 30 days
    final lastTouched = t.lastWorkedAt ?? t.startedAt ?? t.createdAt;
    final daysSince = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(lastTouched))
        .inDays;
    w *= 1.0 + (daysSince.clamp(0, 30) * 0.1);

    // Novelty: added in last 3 days = 1.3x
    final daysOld = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(t.createdAt))
        .inDays;
    if (daysOld <= 3) w *= 1.3;

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
  List<Task> pickWeightedN(List<Task> candidates, int n) {
    if (candidates.isEmpty) return [];
    final eligible = candidates.where((t) =>
      !t.isWorkedOnToday
    ).toList();
    if (eligible.isEmpty) return [];

    final picked = <Task>[];
    final remaining = List<Task>.from(eligible);

    // Ensure at least 1 quick task if available and not yet picked
    if (picked.length < n && !picked.any((t) => t.isQuickTask)) {
      final quickTasks = remaining.where((t) => t.isQuickTask).toList();
      if (quickTasks.isNotEmpty) {
        final weights = quickTasks.map(_taskWeight).toList();
        final total = weights.fold(0.0, (a, b) => a + b);
        var roll = _random.nextDouble() * total;
        Task? quickPick;
        for (int i = 0; i < quickTasks.length; i++) {
          roll -= weights[i];
          if (roll <= 0) { quickPick = quickTasks[i]; break; }
        }
        quickPick ??= quickTasks.last;
        picked.add(quickPick);
        remaining.remove(quickPick);
      }
    }

    // Fill remaining slots via weighted random
    while (picked.length < n && remaining.isNotEmpty) {
      final weights = remaining.map(_taskWeight).toList();
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
    }

    return picked;
  }

  Future<List<Task>> getAllTasks() async {
    return _db.getAllTasks();
  }

  Future<List<Task>> getArchivedTasks() async {
    return _db.getArchivedTasks();
  }

  Future<Map<int, List<String>>> getParentNamesForTaskIds(List<int> taskIds) async {
    return _db.getParentNamesForTaskIds(taskIds);
  }

  /// Re-completes a task (for undo-restore). Unlike completeTask(), this does
  /// not call navigateBack() since it's invoked from the archive screen.
  Future<void> reCompleteTask(int taskId) async {
    await _db.completeTask(taskId);
  }

  /// Permanently deletes a completed task. Returns info needed for undo.
  Future<({Task task, List<int> parentIds, List<int> childIds, List<int> dependsOnIds, List<int> dependedByIds})> permanentlyDeleteTask(int taskId, Task task) async {
    final rels = await _db.deleteTaskWithRelationships(taskId);
    return (
      task: task,
      parentIds: rels['parentIds']!,
      childIds: rels['childIds']!,
      dependsOnIds: rels['dependsOnIds']!,
      dependedByIds: rels['dependedByIds']!,
    );
  }

  /// Marks a task as started (in progress).
  Future<void> startTask(int taskId) async {
    await _db.startTask(taskId);
    // Update _currentParent in place so the leaf detail view reflects the change
    // immediately without needing to navigate away and back.
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        startedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _refreshCurrentList();
  }

  /// Un-starts a task (removes in-progress state).
  Future<void> unstartTask(int taskId) async {
    await _db.unstartTask(taskId);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(startedAt: () => null);
    }
    await _refreshCurrentList();
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
    await _refreshCurrentList();
    return true;
  }

  Future<void> removeDependency(int taskId, int dependsOnId) async {
    await _db.removeDependency(taskId, dependsOnId);
    await _refreshCurrentList();
  }

  Future<List<Task>> getDependencies(int taskId) async {
    return _db.getDependencies(taskId);
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
    await _refreshCurrentList();
    return true;
  }

  /// Adds another parent to a task.
  /// Returns false if a cycle would be created.
  Future<bool> addParentToTask(int taskId, int parentId) async {
    // Check: is parentId reachable from taskId? (i.e., the new parent is a descendant of the task)
    final wouldCycle = await _db.hasPath(taskId, parentId);
    if (wouldCycle) return false;

    await _db.addRelationship(parentId, taskId);
    await _refreshCurrentList();
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
    await _refreshCurrentList();
    return true;
  }

  Future<void> renameTask(int taskId, String name) async {
    await _db.updateTaskName(taskId, name);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(name: name);
    }
    await _refreshCurrentList();
  }

  Future<void> updateTaskUrl(int taskId, String? url) async {
    await _db.updateTaskUrl(taskId, url);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(url: () => url);
    }
    await _refreshCurrentList();
  }

  Future<void> updateTaskPriority(int taskId, int priority) async {
    await _db.updateTaskPriority(taskId, priority);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(priority: priority);
    }
    await _refreshCurrentList();
  }

  Future<void> updateQuickTask(int taskId, int quickTask) async {
    await _db.updateTaskQuickTask(taskId, quickTask);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(difficulty: quickTask);
    }
    await _refreshCurrentList();
  }

  Future<void> markWorkedOn(int taskId) async {
    await _db.markWorkedOn(taskId);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(
        lastWorkedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _refreshCurrentList();
  }

  /// Marks a task as worked on, optionally starts it, and navigates back.
  /// Single DB refresh instead of 2-3 separate ones.
  Future<void> markWorkedOnAndNavigateBack(int taskId, {bool alsoStart = false}) async {
    await _db.markWorkedOn(taskId);
    if (alsoStart) await _db.startTask(taskId);
    await navigateBack(); // single _refreshCurrentList()
  }

  Future<void> unmarkWorkedOn(int taskId, {int? restoreTo}) async {
    await _db.unmarkWorkedOn(taskId, restoreTo: restoreTo);
    if (_currentParent?.id == taskId) {
      _currentParent = _currentParent!.copyWith(lastWorkedAt: () => restoreTo);
    }
    await _refreshCurrentList();
  }

  /// Removes a task from the current parent only (does not delete the task).
  /// If it was the last parent, the task becomes a root task.
  Future<void> unlinkFromCurrentParent(int childId) async {
    if (_currentParent == null) return;
    await _db.removeRelationship(_currentParent!.id!, childId);
    await _refreshCurrentList();
  }

  Future<List<int>> getParentIds(int childId) async {
    return _db.getParentIds(childId);
  }

  Future<List<int>> getChildIds(int parentId) async {
    return _db.getChildIds(parentId);
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

  /// Loads started-descendant and blocked-task info for the current _tasks.
  /// The two queries are independent, so they run concurrently.
  Future<void> _loadAuxiliaryData() async {
    final taskIds = _tasks.map((t) => t.id!).toList();
    late Set<int> startedIds;
    late Map<int, String> blockedNames;
    await Future.wait([
      _db.getTaskIdsWithStartedDescendants(taskIds).then((v) => startedIds = v),
      _db.getBlockedTaskInfo(taskIds).then((v) => blockedNames = v),
    ]);
    _startedDescendantIds = startedIds;
    _blockedByNames = blockedNames;
  }

  Future<void> _refreshCurrentList() async {
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    // Sort worked-on-today tasks to the end, preserving DB order otherwise
    _tasks.sort((a, b) {
      final aWorked = a.isWorkedOnToday ? 1 : 0;
      final bWorked = b.isWorkedOnToday ? 1 : 0;
      return aWorked.compareTo(bWorked);
    });
    await _loadAuxiliaryData();
    notifyListeners();
  }
}
