import 'dart:math';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import '../models/task.dart';

class TaskProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper();
  final Random _random = Random();

  List<Task> _tasks = [];
  List<Task> get tasks => _tasks;

  /// null means we're at the root level
  Task? _currentParent;
  Task? get currentParent => _currentParent;

  /// Navigation stack for back navigation
  final List<Task?> _parentStack = [];

  Future<void> loadRootTasks() async {
    _currentParent = null;
    _parentStack.clear();
    _tasks = await _db.getRootTasks();
    notifyListeners();
  }

  Future<void> navigateInto(Task task) async {
    _parentStack.add(_currentParent);
    _currentParent = task;
    _tasks = await _db.getChildren(task.id!);
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

  Future<void> deleteTask(int taskId) async {
    await _db.deleteTask(taskId);
    await _refreshCurrentList();
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

  Future<void> _refreshCurrentList() async {
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    notifyListeners();
  }
}
