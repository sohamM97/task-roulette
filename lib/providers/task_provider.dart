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

  /// null means we're at the root level
  Task? _currentParent;
  Task? get currentParent => _currentParent;

  /// Navigation stack for back navigation
  final List<Task?> _parentStack = [];

  Future<void> loadRootTasks() async {
    _currentParent = null;
    _parentStack.clear();
    _tasks = await _db.getRootTasks();
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
  }

  Future<void> navigateInto(Task task) async {
    _parentStack.add(_currentParent);
    _currentParent = task;
    _tasks = await _db.getChildren(task.id!);
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
  }

  Future<bool> navigateBack() async {
    if (_parentStack.isEmpty) return false;
    _currentParent = _parentStack.removeLast();
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
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
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
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
  /// Returns a record of (task, parentIds, childIds).
  Future<({Task task, List<int> parentIds, List<int> childIds})> deleteTask(int taskId) async {
    final task = _tasks.firstWhere((t) => t.id == taskId);
    final rels = await _db.deleteTaskWithRelationships(taskId);
    await _refreshCurrentList();
    return (task: task, parentIds: rels['parentIds']!, childIds: rels['childIds']!);
  }

  Future<void> restoreTask(Task task, List<int> parentIds, List<int> childIds) async {
    await _db.restoreTask(task, parentIds, childIds);
    await _refreshCurrentList();
  }

  /// Marks a task as completed (archived) and navigates back.
  /// Returns the task for undo support.
  Future<Task> completeTask(int taskId) async {
    // The task being completed may be _currentParent (leaf detail view's
    // Done button) rather than a member of _tasks.
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId);
    await _db.completeTask(taskId);
    await navigateBack();
    return task;
  }

  /// Marks a task as skipped and navigates back.
  /// Returns the task for undo support.
  Future<Task> skipTask(int taskId) async {
    final task = _currentParent?.id == taskId
        ? _currentParent!
        : _tasks.firstWhere((t) => t.id == taskId);
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

  /// Un-completes a task and refreshes the list.
  Future<void> uncompleteTask(int taskId) async {
    await _db.uncompleteTask(taskId);
    await _refreshCurrentList();
  }

  Future<List<Task>> getParents(int childId) async {
    return _db.getParents(childId);
  }

  Task? pickRandom() {
    if (_tasks.isEmpty) return null;
    return _tasks[_random.nextInt(_tasks.length)];
  }

  Future<List<Task>> getChildren(int taskId) async {
    return _db.getChildren(taskId);
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
  Future<({Task task, List<int> parentIds, List<int> childIds})> permanentlyDeleteTask(int taskId, Task task) async {
    final rels = await _db.deleteTaskWithRelationships(taskId);
    return (task: task, parentIds: rels['parentIds']!, childIds: rels['childIds']!);
  }

  /// Marks a task as started (in progress).
  Future<void> startTask(int taskId) async {
    await _db.startTask(taskId);
    // Update _currentParent in place so the leaf detail view reflects the change
    // immediately without needing to navigate away and back.
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: _currentParent!.name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        url: _currentParent!.url,
        priority: _currentParent!.priority,
        difficulty: _currentParent!.difficulty,
      );
    }
    await _refreshCurrentList();
  }

  /// Un-starts a task (removes in-progress state).
  Future<void> unstartTask(int taskId) async {
    await _db.unstartTask(taskId);
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: _currentParent!.name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: null,
        url: _currentParent!.url,
        priority: _currentParent!.priority,
        difficulty: _currentParent!.difficulty,
      );
    }
    await _refreshCurrentList();
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
  /// Returns false if a cycle would be created.
  Future<bool> moveTask(int taskId, int newParentId) async {
    if (_currentParent == null) return false;
    final wouldCycle = await _db.hasPath(taskId, newParentId);
    if (wouldCycle) return false;

    await _db.addRelationship(newParentId, taskId);
    await _db.removeRelationship(_currentParent!.id!, taskId);
    await _refreshCurrentList();
    return true;
  }

  Future<void> renameTask(int taskId, String name) async {
    await _db.updateTaskName(taskId, name);
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: _currentParent!.startedAt,
        url: _currentParent!.url,
        priority: _currentParent!.priority,
        difficulty: _currentParent!.difficulty,
      );
    }
    await _refreshCurrentList();
  }

  Future<void> updateTaskUrl(int taskId, String? url) async {
    await _db.updateTaskUrl(taskId, url);
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: _currentParent!.name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: _currentParent!.startedAt,
        url: url,
        priority: _currentParent!.priority,
        difficulty: _currentParent!.difficulty,
      );
    }
    await _refreshCurrentList();
  }

  Future<void> updateTaskPriority(int taskId, int priority) async {
    await _db.updateTaskPriority(taskId, priority);
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: _currentParent!.name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: _currentParent!.startedAt,
        url: _currentParent!.url,
        priority: priority,
        difficulty: _currentParent!.difficulty,
      );
    }
    await _refreshCurrentList();
  }

  Future<void> updateTaskDifficulty(int taskId, int difficulty) async {
    await _db.updateTaskDifficulty(taskId, difficulty);
    if (_currentParent?.id == taskId) {
      _currentParent = Task(
        id: _currentParent!.id,
        name: _currentParent!.name,
        createdAt: _currentParent!.createdAt,
        completedAt: _currentParent!.completedAt,
        startedAt: _currentParent!.startedAt,
        url: _currentParent!.url,
        priority: _currentParent!.priority,
        difficulty: difficulty,
      );
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

  Future<List<TaskRelationship>> getAllRelationships() async {
    return _db.getAllRelationships();
  }

  /// Navigate directly to a task, clearing the stack.
  /// Sets stack to [null] so back returns to root.
  Future<void> navigateToTask(Task task) async {
    _parentStack.clear();
    _parentStack.add(null);
    _currentParent = task;
    _tasks = await _db.getChildren(task.id!);
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
  }

  Future<void> _refreshCurrentList() async {
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    final taskIds = _tasks.map((t) => t.id!).toList();
    _startedDescendantIds = await _db.getTaskIdsWithStartedDescendants(taskIds);
    notifyListeners();
  }
}
