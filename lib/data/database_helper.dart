import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final appDir = await getApplicationSupportDirectory();
    final path = join(appDir.path, 'task_roulette.db');

    // Migrate from old location (.dart_tool/sqflite_common_ffi/databases/)
    // which gets wiped by flutter clean.
    if (!File(path).existsSync()) {
      final oldPath = join(
        await getDatabasesPath(),
        'task_roulette.db',
      );
      if (File(oldPath).existsSync()) {
        await File(oldPath).copy(path);
      }
    }

    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            completed_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE task_relationships (
            parent_id INTEGER NOT NULL,
            child_id INTEGER NOT NULL,
            PRIMARY KEY (parent_id, child_id),
            FOREIGN KEY (parent_id) REFERENCES tasks(id) ON DELETE CASCADE,
            FOREIGN KEY (child_id) REFERENCES tasks(id) ON DELETE CASCADE
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE tasks ADD COLUMN completed_at INTEGER');
        }
      },
    );
  }

  @visibleForTesting
  Future<void> reset() async {
    await _database?.close();
    _database = null;
    final appDir = await getApplicationSupportDirectory();
    final path = join(appDir.path, 'task_roulette.db');
    await deleteDatabase(path);
  }

  Future<int> insertTask(Task task) async {
    final db = await database;
    return db.insert('tasks', task.toMap());
  }

  Future<void> addRelationship(int parentId, int childId) async {
    final db = await database;
    await db.insert('task_relationships', {
      'parent_id': parentId,
      'child_id': childId,
    });
  }

  Future<List<Task>> getRootTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      WHERE t.id NOT IN (
        SELECT child_id FROM task_relationships
      )
      AND t.completed_at IS NULL
      ORDER BY t.created_at ASC
    ''');
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  Future<List<Task>> getChildren(int parentId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      INNER JOIN task_relationships tr ON t.id = tr.child_id
      WHERE tr.parent_id = ?
      AND t.completed_at IS NULL
      ORDER BY t.created_at ASC
    ''', [parentId]);
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  Future<List<Task>> getParents(int childId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      INNER JOIN task_relationships tr ON t.id = tr.parent_id
      WHERE tr.child_id = ?
      AND t.completed_at IS NULL
      ORDER BY t.created_at ASC
    ''', [childId]);
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  Future<List<Task>> getAllTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NULL
      ORDER BY created_at ASC
    ''');
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  /// Returns a map of task ID → list of parent names (for disambiguation).
  Future<Map<int, List<String>>> getParentNamesMap() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT tr.child_id, p.name AS parent_name
      FROM task_relationships tr
      INNER JOIN tasks p ON tr.parent_id = p.id
      WHERE p.completed_at IS NULL
      ORDER BY p.name ASC
    ''');
    final result = <int, List<String>>{};
    for (final row in maps) {
      final childId = row['child_id'] as int;
      final parentName = row['parent_name'] as String;
      result.putIfAbsent(childId, () => []).add(parentName);
    }
    return result;
  }

  /// Returns all completed tasks, most recent first.
  Future<List<Task>> getCompletedTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NOT NULL
      ORDER BY completed_at DESC
    ''');
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  /// Returns a map of task ID → list of parent names for the given task IDs.
  /// Unlike getParentNamesMap(), this includes completed parents too.
  Future<Map<int, List<String>>> getParentNamesForTaskIds(List<int> taskIds) async {
    if (taskIds.isEmpty) return {};
    final db = await database;
    final placeholders = taskIds.map((_) => '?').join(',');
    final maps = await db.rawQuery('''
      SELECT tr.child_id, p.name AS parent_name
      FROM task_relationships tr
      INNER JOIN tasks p ON tr.parent_id = p.id
      WHERE tr.child_id IN ($placeholders)
      ORDER BY p.name ASC
    ''', taskIds);
    final result = <int, List<String>>{};
    for (final row in maps) {
      final childId = row['child_id'] as int;
      final parentName = row['parent_name'] as String;
      result.putIfAbsent(childId, () => []).add(parentName);
    }
    return result;
  }

  /// Returns all relationships where both parent and child are non-completed.
  Future<List<TaskRelationship>> getAllRelationships() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT tr.parent_id, tr.child_id
      FROM task_relationships tr
      INNER JOIN tasks p ON tr.parent_id = p.id
      INNER JOIN tasks c ON tr.child_id = c.id
      WHERE p.completed_at IS NULL AND c.completed_at IS NULL
    ''');
    return maps.map((m) => TaskRelationship.fromMap(m)).toList();
  }

  /// Returns true if [toId] is reachable from [fromId] via parent→child edges.
  Future<bool> hasPath(int fromId, int toId) async {
    final db = await database;
    final result = await db.rawQuery('''
      WITH RECURSIVE descendants(id) AS (
        SELECT child_id FROM task_relationships WHERE parent_id = ?
        UNION
        SELECT tr.child_id FROM task_relationships tr
        INNER JOIN descendants d ON tr.parent_id = d.id
      )
      SELECT 1 FROM descendants WHERE id = ? LIMIT 1
    ''', [fromId, toId]);
    return result.isNotEmpty;
  }

  Future<List<int>> getParentIds(int childId) async {
    final db = await database;
    final maps = await db.query(
      'task_relationships',
      columns: ['parent_id'],
      where: 'child_id = ?',
      whereArgs: [childId],
    );
    return maps.map((m) => m['parent_id'] as int).toList();
  }

  Future<List<int>> getChildIds(int parentId) async {
    final db = await database;
    final maps = await db.query(
      'task_relationships',
      columns: ['child_id'],
      where: 'parent_id = ?',
      whereArgs: [parentId],
    );
    return maps.map((m) => m['child_id'] as int).toList();
  }

  Future<void> updateTaskName(int taskId, String name) async {
    final db = await database;
    await db.update('tasks', {'name': name}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> removeRelationship(int parentId, int childId) async {
    final db = await database;
    await db.delete(
      'task_relationships',
      where: 'parent_id = ? AND child_id = ?',
      whereArgs: [parentId, childId],
    );
  }

  /// Marks a task as completed by setting completed_at to now.
  Future<void> completeTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'completed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-completes a task by clearing completed_at.
  Future<void> uncompleteTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'completed_at': null},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Deletes a task and returns its relationships for undo support.
  /// Returns a map with 'parentIds' and 'childIds'.
  Future<Map<String, List<int>>> deleteTaskWithRelationships(int taskId) async {
    final db = await database;
    final parentIds = await getParentIds(taskId);
    final childIds = await getChildIds(taskId);
    await db.delete('task_relationships',
        where: 'parent_id = ? OR child_id = ?',
        whereArgs: [taskId, taskId]);
    await db.delete('tasks', where: 'id = ?', whereArgs: [taskId]);
    return {'parentIds': parentIds, 'childIds': childIds};
  }

  /// Restores a previously deleted task with its original ID and relationships.
  Future<void> restoreTask(Task task, List<int> parentIds, List<int> childIds) async {
    final db = await database;
    await db.insert('tasks', task.toMap());
    for (final parentId in parentIds) {
      await addRelationship(parentId, task.id!);
    }
    for (final childId in childIds) {
      await addRelationship(task.id!, childId);
    }
  }
}
