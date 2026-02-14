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

  /// Override in tests to use inMemoryDatabasePath instead of the real DB.
  @visibleForTesting
  static String? testDatabasePath;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final String path;
    if (testDatabasePath != null) {
      path = testDatabasePath!;
    } else {
      final appDir = await getApplicationSupportDirectory();
      path = join(appDir.path, 'task_roulette.db');

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
    }

    return openDatabase(
      path,
      version: 6,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            completed_at INTEGER,
            started_at INTEGER,
            url TEXT,
            skipped_at INTEGER,
            priority INTEGER NOT NULL DEFAULT 1,
            difficulty INTEGER NOT NULL DEFAULT 1
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
        // PERFORMANCE: indices speed up JOIN/WHERE on task_relationships
        await db.execute('CREATE INDEX idx_task_relationships_parent_id ON task_relationships(parent_id)');
        await db.execute('CREATE INDEX idx_task_relationships_child_id ON task_relationships(child_id)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE tasks ADD COLUMN completed_at INTEGER');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE tasks ADD COLUMN started_at INTEGER');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE tasks ADD COLUMN url TEXT');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE tasks ADD COLUMN skipped_at INTEGER');
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 1');
          await db.execute('ALTER TABLE tasks ADD COLUMN difficulty INTEGER NOT NULL DEFAULT 1');
          // PERFORMANCE: indices speed up JOIN/WHERE on task_relationships
          await db.execute('CREATE INDEX IF NOT EXISTS idx_task_relationships_parent_id ON task_relationships(parent_id)');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_task_relationships_child_id ON task_relationships(child_id)');
        }
      },
    );
  }

  /// Returns the path to the current database file.
  Future<String> getDatabasePath() async {
    if (testDatabasePath != null) return testDatabasePath!;
    final appDir = await getApplicationSupportDirectory();
    return join(appDir.path, 'task_roulette.db');
  }

  /// Validates that [sourcePath] is a SQLite database with a `tasks` table.
  /// Throws [FormatException] if it isn't.
  Future<void> _validateBackup(String sourcePath) async {
    Database? testDb;
    try {
      testDb = await openDatabase(sourcePath, readOnly: true);
      final tables = await testDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='tasks'",
      );
      if (tables.isEmpty) {
        throw const FormatException('Not a valid TaskRoulette backup');
      }
    } on DatabaseException {
      throw const FormatException('Not a valid database file');
    } finally {
      await testDb?.close();
    }
  }

  /// Validates [sourcePath], then closes the current DB, copies source over
  /// it, and clears the cached instance so the next access reopens fresh.
  /// Throws [FormatException] if the file is not a valid backup.
  Future<void> importDatabase(String sourcePath) async {
    await _validateBackup(sourcePath);
    final dbPath = await getDatabasePath();
    await _database?.close();
    _database = null;
    await File(sourcePath).copy(dbPath);
  }

  @visibleForTesting
  Future<void> reset() async {
    await _database?.close();
    _database = null;
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
      AND t.skipped_at IS NULL
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
      AND t.skipped_at IS NULL
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
      AND t.skipped_at IS NULL
      ORDER BY t.created_at ASC
    ''', [childId]);
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  Future<List<Task>> getAllTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NULL
      AND skipped_at IS NULL
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
      AND p.skipped_at IS NULL
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

  /// Returns all archived tasks (completed or skipped), most recent first.
  Future<List<Task>> getArchivedTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NOT NULL OR skipped_at IS NOT NULL
      ORDER BY COALESCE(completed_at, skipped_at) DESC
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
      AND p.skipped_at IS NULL AND c.skipped_at IS NULL
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

  Future<void> updateTaskUrl(int taskId, String? url) async {
    final db = await database;
    await db.update('tasks', {'url': url}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> updateTaskPriority(int taskId, int priority) async {
    final db = await database;
    await db.update('tasks', {'priority': priority}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> updateTaskDifficulty(int taskId, int difficulty) async {
    final db = await database;
    await db.update('tasks', {'difficulty': difficulty}, where: 'id = ?', whereArgs: [taskId]);
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

  /// Marks a task as skipped by setting skipped_at to now.
  Future<void> skipTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'skipped_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-skips a task by clearing skipped_at.
  Future<void> unskipTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'skipped_at': null},
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
  // PERFORMANCE: transaction batches reads + deletes into a single DB round-trip
  Future<Map<String, List<int>>> deleteTaskWithRelationships(int taskId) async {
    final db = await database;
    return db.transaction((txn) async {
      final parentMaps = await txn.query(
        'task_relationships',
        columns: ['parent_id'],
        where: 'child_id = ?',
        whereArgs: [taskId],
      );
      final childMaps = await txn.query(
        'task_relationships',
        columns: ['child_id'],
        where: 'parent_id = ?',
        whereArgs: [taskId],
      );
      await txn.delete('task_relationships',
          where: 'parent_id = ? OR child_id = ?',
          whereArgs: [taskId, taskId]);
      await txn.delete('tasks', where: 'id = ?', whereArgs: [taskId]);
      return {
        'parentIds': parentMaps.map((m) => m['parent_id'] as int).toList(),
        'childIds': childMaps.map((m) => m['child_id'] as int).toList(),
      };
    });
  }

  /// Restores a previously deleted task with its original ID and relationships.
  // PERFORMANCE: transaction batches task insert + N relationship inserts
  Future<void> restoreTask(Task task, List<int> parentIds, List<int> childIds) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('tasks', task.toMap());
      for (final parentId in parentIds) {
        await txn.insert('task_relationships', {
          'parent_id': parentId,
          'child_id': task.id!,
        });
      }
      for (final childId in childIds) {
        await txn.insert('task_relationships', {
          'parent_id': task.id!,
          'child_id': childId,
        });
      }
    });
  }

  /// Marks a task as started by setting started_at to now.
  Future<void> startTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'started_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-starts a task by clearing started_at.
  Future<void> unstartTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'started_at': null},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Returns the set of task IDs (from the given list) that have at least one
  /// descendant which is in progress (started_at IS NOT NULL AND completed_at IS NULL).
  /// Uses a single query with a recursive CTE from all started tasks upward
  /// to find which ancestors have started descendants.
  Future<Set<int>> getTaskIdsWithStartedDescendants(List<int> taskIds) async {
    if (taskIds.isEmpty) return {};
    final db = await database;
    // Walk upward from all started tasks to find their ancestors,
    // then intersect with the requested taskIds.
    final placeholders = taskIds.map((_) => '?').join(',');
    final rows = await db.rawQuery('''
      WITH RECURSIVE ancestors(id) AS (
        -- Start from parents of all in-progress tasks
        SELECT tr.parent_id FROM task_relationships tr
        INNER JOIN tasks t ON tr.child_id = t.id
        WHERE t.started_at IS NOT NULL AND t.completed_at IS NULL AND t.skipped_at IS NULL
        UNION
        -- Walk upward through parent relationships
        SELECT tr.parent_id
        FROM task_relationships tr
        INNER JOIN ancestors a ON tr.child_id = a.id
      )
      SELECT DISTINCT id FROM ancestors
      WHERE id IN ($placeholders)
    ''', taskIds);
    return rows.map((r) => r['id'] as int).toSet();
  }
}
