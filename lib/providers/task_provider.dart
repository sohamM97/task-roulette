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

  Future<void> _refreshCurrentList() async {
    if (_currentParent == null) {
      _tasks = await _db.getRootTasks();
    } else {
      _tasks = await _db.getChildren(_currentParent!.id!);
    }
    notifyListeners();
  }
}
