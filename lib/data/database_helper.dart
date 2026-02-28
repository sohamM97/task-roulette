import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';
import '../platform/platform_utils.dart'
    if (dart.library.io) '../platform/platform_utils_native.dart' as platform;

/// Data holder for Today's 5 state loaded from / saved to the DB.
class TodaysFiveData {
  final String date;
  final List<int> taskIds;
  final Set<int> completedIds;
  final Set<int> workedOnIds;
  final Set<int> pinnedIds;

  const TodaysFiveData({
    required this.date,
    required this.taskIds,
    required this.completedIds,
    required this.workedOnIds,
    this.pinnedIds = const {},
  });
}

const _uuid = Uuid();

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database>? _dbFuture;

  /// Override in tests to use inMemoryDatabasePath instead of the real DB.
  @visibleForTesting
  static String? testDatabasePath;

  Future<Database> get database {
    _dbFuture ??= _initDatabase();
    return _dbFuture!;
  }

  Future<Database> _initDatabase() async {
    final String path;
    if (testDatabasePath != null) {
      path = testDatabasePath!;
    } else if (kIsWeb) {
      // On web, sqflite_ffi_web uses IndexedDB — just use a simple name.
      path = 'task_roulette.db';
    } else {
      path = await platform.resolveDatabasePath();

      // Migrate from old location (.dart_tool/sqflite_common_ffi/databases/)
      // which gets wiped by flutter clean.
      if (!platform.fileExistsSync(path)) {
        final oldPath = join(
          await getDatabasesPath(),
          'task_roulette.db',
        );
        if (platform.fileExistsSync(oldPath)) {
          await platform.copyFile(oldPath, path);
        }
      }
    }

    return openDatabase(
      path,
      version: 14,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
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
            priority INTEGER NOT NULL DEFAULT 0,
            difficulty INTEGER NOT NULL DEFAULT 0,
            last_worked_at INTEGER,
            repeat_interval TEXT,
            next_due_at INTEGER,
            sync_id TEXT,
            updated_at INTEGER,
            sync_status TEXT NOT NULL DEFAULT 'synced'
          )
        ''');
        await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_sync_id ON tasks(sync_id)');
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
        await db.execute('''
          CREATE TABLE task_dependencies (
            task_id INTEGER NOT NULL,
            depends_on_id INTEGER NOT NULL,
            PRIMARY KEY (task_id, depends_on_id),
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
            FOREIGN KEY (depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX idx_task_dependencies_task_id ON task_dependencies(task_id)');
        await db.execute('CREATE INDEX idx_task_dependencies_depends_on_id ON task_dependencies(depends_on_id)');
        await db.execute('''
          CREATE TABLE sync_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL,
            action TEXT NOT NULL,
            key1 TEXT NOT NULL,
            key2 TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE todays_five_state (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            task_id INTEGER NOT NULL,
            is_completed INTEGER NOT NULL DEFAULT 0,
            is_worked_on INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_todays_five_state_date ON todays_five_state(date)');
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
        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE task_dependencies (
              task_id INTEGER NOT NULL,
              depends_on_id INTEGER NOT NULL,
              PRIMARY KEY (task_id, depends_on_id),
              FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
              FOREIGN KEY (depends_on_id) REFERENCES tasks(id) ON DELETE CASCADE
            )
          ''');
          await db.execute('CREATE INDEX idx_task_dependencies_task_id ON task_dependencies(task_id)');
          await db.execute('CREATE INDEX idx_task_dependencies_depends_on_id ON task_dependencies(depends_on_id)');
        }
        // Track whether priority/difficulty columns were freshly added (no old
        // data to remap) vs already present (need value migration).
        var columnsJustAdded = false;
        if (oldVersion < 8) {
          // Columns were added to the v6 onCreate retroactively, so DBs at v6/v7
          // won't have them. Add if missing before the UPDATE.
          final cols = await db.rawQuery('PRAGMA table_info(tasks)');
          final colNames = cols.map((c) => c['name'] as String).toSet();
          columnsJustAdded = !colNames.contains('priority');
          if (columnsJustAdded) {
            await db.execute('ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0');
            await db.execute('ALTER TABLE tasks ADD COLUMN difficulty INTEGER NOT NULL DEFAULT 0');
          } else {
            // Remap 3-level priority (0=Low,1=Medium,2=High) to 2-level (0=Normal,1=High)
            await db.execute('UPDATE tasks SET priority = CASE WHEN priority >= 2 THEN 1 ELSE 0 END');
          }
        }
        if (oldVersion < 9 && !columnsJustAdded) {
          // Reinterpret difficulty: old Easy(0)→quick(1), old Medium(1)/Hard(2)→normal(0)
          // Skip if columns were just added — defaults are already correct (0 = Normal).
          await db.execute('UPDATE tasks SET difficulty = CASE WHEN difficulty = 0 THEN 1 ELSE 0 END');
        }
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE tasks ADD COLUMN last_worked_at INTEGER');
        }
        if (oldVersion < 11) {
          await db.execute('ALTER TABLE tasks ADD COLUMN repeat_interval TEXT');
          await db.execute('ALTER TABLE tasks ADD COLUMN next_due_at INTEGER');
        }
        if (oldVersion < 12) {
          await db.execute('ALTER TABLE tasks ADD COLUMN sync_id TEXT');
          await db.execute('ALTER TABLE tasks ADD COLUMN updated_at INTEGER');
          await db.execute("ALTER TABLE tasks ADD COLUMN sync_status TEXT NOT NULL DEFAULT 'synced'");
          await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_sync_id ON tasks(sync_id)');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_queue (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              entity_type TEXT NOT NULL,
              action TEXT NOT NULL,
              key1 TEXT NOT NULL,
              key2 TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          // Generate UUIDs for all existing tasks
          final existing = await db.rawQuery('SELECT id FROM tasks');
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final row in existing) {
            await db.update(
              'tasks',
              {'sync_id': _uuid.v4(), 'updated_at': now},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
        if (oldVersion < 13) {
          await db.execute('''
            CREATE TABLE todays_five_state (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date TEXT NOT NULL,
              task_id INTEGER NOT NULL,
              is_completed INTEGER NOT NULL DEFAULT 0,
              is_worked_on INTEGER NOT NULL DEFAULT 0,
              sort_order INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('CREATE INDEX idx_todays_five_state_date ON todays_five_state(date)');
        }
        if (oldVersion < 14) {
          await db.execute('ALTER TABLE todays_five_state ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
  }

  /// Returns the path to the current database file.
  Future<String> getDatabasePath() async {
    if (testDatabasePath != null) return testDatabasePath!;
    if (kIsWeb) return 'task_roulette.db';
    return platform.resolveDatabasePath();
  }

  static const _maxBackupSizeBytes = 100 * 1024 * 1024; // 100 MB
  static const _expectedTables = ['tasks', 'task_relationships', 'task_dependencies'];

  /// Validates that [sourcePath] is a valid TaskRoulette backup.
  /// Checks: file size, required tables, no triggers/views, schema version.
  /// Throws [FormatException] if validation fails.
  Future<void> _validateBackup(String sourcePath) async {
    // Check file size
    final fileSize = await platform.fileSize(sourcePath);
    if (fileSize > _maxBackupSizeBytes) {
      throw const FormatException('Backup file is too large (max 100 MB)');
    }

    Database? testDb;
    try {
      testDb = await openDatabase(sourcePath, readOnly: true);

      // Check all expected tables exist
      for (final table in _expectedTables) {
        final result = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table],
        );
        if (result.isEmpty) {
          throw FormatException('Not a valid TaskRoulette backup (missing $table)');
        }
      }

      // Check schema version is compatible
      final versionResult = await testDb.rawQuery('PRAGMA user_version');
      final version = versionResult.first.values.first as int;
      if (version < 1 || version > 14) {
        throw FormatException(
          'Incompatible backup version ($version). This app supports versions 1-14.',
        );
      }

      // Reject databases with triggers or views (potential tampering)
      final dangerous = await testDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')",
      );
      if (dangerous.isNotEmpty) {
        throw const FormatException('Backup contains unexpected database objects');
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
    // Create safety backup before overwriting
    if (await platform.fileExists(dbPath)) {
      await platform.copyFile(dbPath, '$dbPath.bak');
    }
    if (_dbFuture != null) {
      final db = await _dbFuture!;
      await db.close();
    }
    _dbFuture = null;
    await platform.copyFile(sourcePath, dbPath);
  }

  @visibleForTesting
  Future<void> reset() async {
    if (_dbFuture != null) {
      final db = await _dbFuture!;
      await db.close();
    }
    _dbFuture = null;
  }

  /// Returns a map with `updated_at` and `sync_status` set for dirty tracking.
  static Map<String, dynamic> _dirtyFields() => {
    'updated_at': DateTime.now().millisecondsSinceEpoch,
    'sync_status': 'pending',
  };

  /// Shared conversion: maps DB rows to Task objects.
  static List<Task> _tasksFromMaps(List<Map<String, Object?>> maps) {
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  /// Shared conversion: groups parent-name rows into a map of childId → names.
  static Map<int, List<String>> _parentNamesFromRows(
      List<Map<String, Object?>> rows) {
    final result = <int, List<String>>{};
    for (final row in rows) {
      final childId = row['child_id'] as int;
      final parentName = row['parent_name'] as String;
      result.putIfAbsent(childId, () => []).add(parentName);
    }
    return result;
  }

  Future<int> insertTask(Task task) async {
    final db = await database;
    final map = task.toMap();
    map['sync_id'] ??= _uuid.v4();
    map.addAll(_dirtyFields());
    return db.insert('tasks', map);
  }

  /// Inserts multiple tasks in a single transaction.
  /// If [parentId] is non-null, each task is added as a child of that parent.
  Future<void> insertTasksBatch(List<Task> tasks, int? parentId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      String? parentSyncId;
      if (parentId != null) {
        final parentRow = await txn.query('tasks', columns: ['sync_id'], where: 'id = ?', whereArgs: [parentId]);
        parentSyncId = parentRow.firstOrNull?['sync_id'] as String?;
      }
      for (final task in tasks) {
        final map = task.toMap();
        final childSyncId = _uuid.v4();
        map['sync_id'] ??= childSyncId;
        map['updated_at'] = now;
        map['sync_status'] = 'pending';
        final id = await txn.insert('tasks', map);
        if (parentId != null) {
          await txn.insert('task_relationships', {
            'parent_id': parentId,
            'child_id': id,
          });
          if (parentSyncId != null) {
            await txn.insert('sync_queue', {
              'entity_type': 'relationship',
              'action': 'add',
              'key1': parentSyncId,
              'key2': map['sync_id'],
              'created_at': now,
            });
          }
        }
      }
    });
  }

  Future<void> addRelationship(int parentId, int childId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('task_relationships', {
        'parent_id': parentId,
        'child_id': childId,
      });
      final rows = await txn.rawQuery(
        'SELECT id, sync_id FROM tasks WHERE id IN (?, ?)', [parentId, childId]);
      final syncIds = <int, String>{};
      for (final r in rows) {
        final sid = r['sync_id'] as String?;
        if (sid != null) syncIds[r['id'] as int] = sid;
      }
      if (syncIds.containsKey(parentId) && syncIds.containsKey(childId)) {
        await txn.insert('sync_queue', {
          'entity_type': 'relationship',
          'action': 'add',
          'key1': syncIds[parentId],
          'key2': syncIds[childId],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
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
      ORDER BY t.priority DESC, t.created_at ASC
    ''');
    return _tasksFromMaps(maps);
  }

  Future<List<int>> getRootTaskIds() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT id FROM tasks
      WHERE id NOT IN (
        SELECT child_id FROM task_relationships
      )
      AND completed_at IS NULL
      AND skipped_at IS NULL
    ''');
    return maps.map((m) => m['id'] as int).toList();
  }

  Future<List<Task>> getChildren(int parentId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      INNER JOIN task_relationships tr ON t.id = tr.child_id
      WHERE tr.parent_id = ?
      AND t.completed_at IS NULL
      AND t.skipped_at IS NULL
      ORDER BY t.priority DESC, t.created_at ASC
    ''', [parentId]);
    return _tasksFromMaps(maps);
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
    return _tasksFromMaps(maps);
  }

  /// Returns a path from root to the task's immediate parent using a single
  /// recursive CTE. Picks the first (min id) parent at each level for DAGs.
  /// Result is ordered root-first: [grandparent, parent].
  Future<List<Task>> getAncestorPath(int taskId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      WITH RECURSIVE ancestors(id, depth) AS (
        SELECT MIN(parent_id), 1 FROM task_relationships WHERE child_id = ?
        UNION ALL
        SELECT (SELECT MIN(tr.parent_id) FROM task_relationships tr WHERE tr.child_id = a.id),
               a.depth + 1
        FROM ancestors a
        WHERE a.id IS NOT NULL
      )
      SELECT t.* FROM tasks t
      INNER JOIN ancestors a ON t.id = a.id
      ORDER BY a.depth DESC
    ''', [taskId]);
    return _tasksFromMaps(maps);
  }

  Future<Task?> getTaskById(int id) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Task.fromMap(maps.first);
  }

  Future<List<Task>> getAllTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NULL
      AND skipped_at IS NULL
      ORDER BY created_at ASC
    ''');
    return _tasksFromMaps(maps);
  }

  /// Returns all leaf tasks (tasks with no children that are active).
  Future<List<Task>> getAllLeafTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      WHERE t.completed_at IS NULL
      AND t.skipped_at IS NULL
      AND t.id NOT IN (
        SELECT DISTINCT tr.parent_id FROM task_relationships tr
        INNER JOIN tasks c ON tr.child_id = c.id
        WHERE c.completed_at IS NULL AND c.skipped_at IS NULL
      )
      ORDER BY t.created_at ASC
    ''');
    return _tasksFromMaps(maps);
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
    return _parentNamesFromRows(maps);
  }

  /// Returns all archived tasks (completed or skipped), most recent first.
  Future<List<Task>> getArchivedTasks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE completed_at IS NOT NULL OR skipped_at IS NOT NULL
      ORDER BY COALESCE(completed_at, skipped_at) DESC
    ''');
    return _tasksFromMaps(maps);
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
    return _parentNamesFromRows(maps);
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

  /// Returns true if a task has at least one child in task_relationships.
  Future<bool> hasChildren(int taskId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT 1 FROM task_relationships WHERE parent_id = ? LIMIT 1',
      [taskId],
    );
    return result.isNotEmpty;
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
    await db.update('tasks', {'name': name, ..._dirtyFields()}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> updateTaskUrl(int taskId, String? url) async {
    final db = await database;
    await db.update('tasks', {'url': url, ..._dirtyFields()}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> updateTaskPriority(int taskId, int priority) async {
    final db = await database;
    await db.update('tasks', {'priority': priority, ..._dirtyFields()}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> updateTaskQuickTask(int taskId, int quickTask) async {
    final db = await database;
    await db.update('tasks', {'difficulty': quickTask, ..._dirtyFields()}, where: 'id = ?', whereArgs: [taskId]);
  }

  Future<void> markWorkedOn(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'last_worked_at': DateTime.now().millisecondsSinceEpoch, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  Future<void> unmarkWorkedOn(int taskId, {int? restoreTo}) async {
    final db = await database;
    await db.update(
      'tasks',
      {'last_worked_at': restoreTo, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  Future<void> updateRepeatInterval(int taskId, String? interval) async {
    final db = await database;
    await db.update(
      'tasks',
      {'repeat_interval': interval, 'next_due_at': null, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Completes a repeating task: computes next_due_at, clears started_at/last_worked_at.
  Future<void> completeRepeatingTask(int taskId, String repeatInterval) async {
    final db = await database;
    final now = DateTime.now();
    final Duration offset;
    switch (repeatInterval) {
      case 'daily':
        offset = const Duration(days: 1);
      case 'weekly':
        offset = const Duration(days: 7);
      case 'biweekly':
        offset = const Duration(days: 14);
      case 'monthly':
        offset = const Duration(days: 30);
      default:
        assert(false, 'Unknown repeat interval: $repeatInterval');
        offset = const Duration(days: 1);
    }
    final nextDue = now.add(offset).millisecondsSinceEpoch;
    await db.update(
      'tasks',
      {
        'started_at': null,
        'last_worked_at': null,
        'next_due_at': nextDue,
        ..._dirtyFields(),
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  Future<void> removeRelationship(int parentId, int childId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT id, sync_id FROM tasks WHERE id IN (?, ?)', [parentId, childId]);
      final syncIds = <int, String>{};
      for (final r in rows) {
        final sid = r['sync_id'] as String?;
        if (sid != null) syncIds[r['id'] as int] = sid;
      }
      await txn.delete(
        'task_relationships',
        where: 'parent_id = ? AND child_id = ?',
        whereArgs: [parentId, childId],
      );
      if (syncIds.containsKey(parentId) && syncIds.containsKey(childId)) {
        await txn.insert('sync_queue', {
          'entity_type': 'relationship',
          'action': 'remove',
          'key1': syncIds[parentId],
          'key2': syncIds[childId],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  /// Marks a task as completed by setting completed_at to now.
  Future<void> completeTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'completed_at': DateTime.now().millisecondsSinceEpoch, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Marks a task as skipped by setting skipped_at to now.
  Future<void> skipTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'skipped_at': DateTime.now().millisecondsSinceEpoch, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-skips a task by clearing skipped_at.
  Future<void> unskipTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'skipped_at': null, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-completes a task by clearing completed_at.
  Future<void> uncompleteTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'completed_at': null, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Deletes a task and returns its relationships for undo support.
  /// Returns a map with 'parentIds', 'childIds', 'dependsOnIds', 'dependedByIds'.
  // PERFORMANCE: transaction batches reads + deletes into a single DB round-trip
  Future<Map<String, List<int>>> deleteTaskWithRelationships(int taskId) async {
    final db = await database;
    return db.transaction((txn) async {
      // Capture sync_id before deletion for sync queue
      final taskRow = await txn.query('tasks', columns: ['sync_id'], where: 'id = ?', whereArgs: [taskId]);
      final syncId = taskRow.firstOrNull?['sync_id'] as String?;

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
      final dependsOnMaps = await txn.query(
        'task_dependencies',
        columns: ['depends_on_id'],
        where: 'task_id = ?',
        whereArgs: [taskId],
      );
      final dependedByMaps = await txn.query(
        'task_dependencies',
        columns: ['task_id'],
        where: 'depends_on_id = ?',
        whereArgs: [taskId],
      );
      await txn.delete('task_relationships',
          where: 'parent_id = ? OR child_id = ?',
          whereArgs: [taskId, taskId]);
      await txn.delete('task_dependencies',
          where: 'task_id = ? OR depends_on_id = ?',
          whereArgs: [taskId, taskId]);
      await txn.delete('tasks', where: 'id = ?', whereArgs: [taskId]);

      // Enqueue task deletion for sync
      if (syncId != null) {
        await txn.insert('sync_queue', {
          'entity_type': 'task',
          'action': 'remove',
          'key1': syncId,
          'key2': '',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      return {
        'parentIds': parentMaps.map((m) => m['parent_id'] as int).toList(),
        'childIds': childMaps.map((m) => m['child_id'] as int).toList(),
        'dependsOnIds': dependsOnMaps.map((m) => m['depends_on_id'] as int).toList(),
        'dependedByIds': dependedByMaps.map((m) => m['task_id'] as int).toList(),
      };
    });
  }

  /// Restores a previously deleted task with its original ID and relationships.
  /// If [removeReparentLinks] is provided, those reparent links are removed
  /// (used to undo the reparenting that happened during delete-and-reparent).
  // PERFORMANCE: transaction batches task insert + N relationship inserts
  Future<void> restoreTask(
    Task task,
    List<int> parentIds,
    List<int> childIds, {
    List<int> dependsOnIds = const [],
    List<int> dependedByIds = const [],
    List<({int parentId, int childId})> removeReparentLinks = const [],
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // Remove reparent links that were added during deletion
      for (final link in removeReparentLinks) {
        await txn.delete('task_relationships',
            where: 'parent_id = ? AND child_id = ?',
            whereArgs: [link.parentId, link.childId]);
      }

      // Cancel pending sync deletion entries for this task
      if (task.syncId != null) {
        await txn.delete('sync_queue',
          where: "entity_type = 'task' AND action = 'remove' AND key1 = ?",
          whereArgs: [task.syncId]);
      }

      // Re-insert task as 'pending' so it gets re-pushed to cloud
      final map = task.toMap();
      map['sync_status'] = 'pending';
      await txn.insert('tasks', map);

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
      for (final depId in dependsOnIds) {
        await txn.insert('task_dependencies', {
          'task_id': task.id!,
          'depends_on_id': depId,
        });
      }
      for (final depById in dependedByIds) {
        await txn.insert('task_dependencies', {
          'task_id': depById,
          'depends_on_id': task.id!,
        });
      }

      // Cancel pending sync removal entries for restored relationships
      if (task.syncId != null) {
        // Look up sync_ids for related tasks
        final allRelatedIds = <int>{...parentIds, ...childIds, ...dependsOnIds, ...dependedByIds};
        if (allRelatedIds.isNotEmpty) {
          final placeholders = allRelatedIds.map((_) => '?').join(',');
          final syncRows = await txn.rawQuery(
            'SELECT id, sync_id FROM tasks WHERE id IN ($placeholders) AND sync_id IS NOT NULL',
            allRelatedIds.toList());
          final syncMap = <int, String>{};
          for (final r in syncRows) {
            syncMap[r['id'] as int] = r['sync_id'] as String;
          }

          // Cancel relationship removal entries and enqueue additions
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final pid in parentIds) {
            final pSyncId = syncMap[pid];
            if (pSyncId != null) {
              await txn.delete('sync_queue',
                where: "entity_type = 'relationship' AND action = 'remove' AND key1 = ? AND key2 = ?",
                whereArgs: [pSyncId, task.syncId]);
              await txn.insert('sync_queue', {
                'entity_type': 'relationship', 'action': 'add',
                'key1': pSyncId, 'key2': task.syncId!, 'created_at': now,
              });
            }
          }
          for (final cid in childIds) {
            final cSyncId = syncMap[cid];
            if (cSyncId != null) {
              await txn.delete('sync_queue',
                where: "entity_type = 'relationship' AND action = 'remove' AND key1 = ? AND key2 = ?",
                whereArgs: [task.syncId, cSyncId]);
              await txn.insert('sync_queue', {
                'entity_type': 'relationship', 'action': 'add',
                'key1': task.syncId!, 'key2': cSyncId, 'created_at': now,
              });
            }
          }
          for (final depId in dependsOnIds) {
            final dSyncId = syncMap[depId];
            if (dSyncId != null) {
              await txn.delete('sync_queue',
                where: "entity_type = 'dependency' AND action = 'remove' AND key1 = ? AND key2 = ?",
                whereArgs: [task.syncId, dSyncId]);
              await txn.insert('sync_queue', {
                'entity_type': 'dependency', 'action': 'add',
                'key1': task.syncId!, 'key2': dSyncId, 'created_at': now,
              });
            }
          }
          for (final depById in dependedByIds) {
            final dbSyncId = syncMap[depById];
            if (dbSyncId != null) {
              await txn.delete('sync_queue',
                where: "entity_type = 'dependency' AND action = 'remove' AND key1 = ? AND key2 = ?",
                whereArgs: [dbSyncId, task.syncId]);
              await txn.insert('sync_queue', {
                'entity_type': 'dependency', 'action': 'add',
                'key1': dbSyncId, 'key2': task.syncId!, 'created_at': now,
              });
            }
          }
        }
      }
    });
  }

  /// Marks a task as started by setting started_at to now.
  Future<void> startTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'started_at': DateTime.now().millisecondsSinceEpoch, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Un-starts a task by clearing started_at.
  Future<void> unstartTask(int taskId) async {
    final db = await database;
    await db.update(
      'tasks',
      {'started_at': null, ..._dirtyFields()},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  // --- Task dependency methods ---

  Future<void> addDependency(int taskId, int dependsOnId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('task_dependencies', {
        'task_id': taskId,
        'depends_on_id': dependsOnId,
      });
      final rows = await txn.rawQuery(
        'SELECT id, sync_id FROM tasks WHERE id IN (?, ?)', [taskId, dependsOnId]);
      final syncIds = <int, String>{};
      for (final r in rows) {
        final sid = r['sync_id'] as String?;
        if (sid != null) syncIds[r['id'] as int] = sid;
      }
      if (syncIds.containsKey(taskId) && syncIds.containsKey(dependsOnId)) {
        await txn.insert('sync_queue', {
          'entity_type': 'dependency',
          'action': 'add',
          'key1': syncIds[taskId],
          'key2': syncIds[dependsOnId],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  Future<void> removeDependency(int taskId, int dependsOnId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT id, sync_id FROM tasks WHERE id IN (?, ?)', [taskId, dependsOnId]);
      final syncIds = <int, String>{};
      for (final r in rows) {
        final sid = r['sync_id'] as String?;
        if (sid != null) syncIds[r['id'] as int] = sid;
      }
      await txn.delete(
        'task_dependencies',
        where: 'task_id = ? AND depends_on_id = ?',
        whereArgs: [taskId, dependsOnId],
      );
      if (syncIds.containsKey(taskId) && syncIds.containsKey(dependsOnId)) {
        await txn.insert('sync_queue', {
          'entity_type': 'dependency',
          'action': 'remove',
          'key1': syncIds[taskId],
          'key2': syncIds[dependsOnId],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  /// Returns all tasks that [taskId] depends on (completed or not, for UI).
  Future<List<Task>> getDependencies(int taskId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT t.* FROM tasks t
      INNER JOIN task_dependencies td ON t.id = td.depends_on_id
      WHERE td.task_id = ?
      ORDER BY t.name ASC
    ''', [taskId]);
    return _tasksFromMaps(maps);
  }

  /// Returns the subset of [taskIds] that have at least one unresolved
  /// (non-completed, non-skipped, not worked-on-today) dependency.
  Future<Set<int>> getBlockedTaskIds(List<int> taskIds) async {
    if (taskIds.isEmpty) return {};
    final db = await database;
    final now = DateTime.now();
    final startOfTodayMs =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final placeholders = taskIds.map((_) => '?').join(',');
    final rows = await db.rawQuery('''
      SELECT DISTINCT td.task_id
      FROM task_dependencies td
      INNER JOIN tasks t ON td.depends_on_id = t.id
      WHERE td.task_id IN ($placeholders)
        AND t.completed_at IS NULL
        AND t.skipped_at IS NULL
        AND NOT (t.last_worked_at IS NOT NULL
                 AND t.last_worked_at >= ?)
    ''', [...taskIds, startOfTodayMs]);
    return rows.map((r) => r['task_id'] as int).toSet();
  }

  /// Returns a map of blocked task ID → dependency task name for display.
  /// Only includes tasks with unresolved (non-completed, non-skipped,
  /// not worked-on-today) dependencies.
  Future<Map<int, ({int blockerId, String blockerName})>> getBlockedTaskInfo(List<int> taskIds) async {
    if (taskIds.isEmpty) return {};
    final db = await database;
    final now = DateTime.now();
    final startOfTodayMs =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final placeholders = taskIds.map((_) => '?').join(',');
    final rows = await db.rawQuery('''
      SELECT td.task_id, td.depends_on_id, t.name
      FROM task_dependencies td
      INNER JOIN tasks t ON td.depends_on_id = t.id
      WHERE td.task_id IN ($placeholders)
        AND t.completed_at IS NULL
        AND t.skipped_at IS NULL
        AND NOT (t.last_worked_at IS NOT NULL
                 AND t.last_worked_at >= ?)
    ''', [...taskIds, startOfTodayMs]);
    final result = <int, ({int blockerId, String blockerName})>{};
    for (final row in rows) {
      result[row['task_id'] as int] = (
        blockerId: row['depends_on_id'] as int,
        blockerName: row['name'] as String,
      );
    }
    return result;
  }

  /// Returns all dependency pairs where both task_id and depends_on_id are in
  /// [taskIds]. Unlike [getBlockedTaskInfo], this ignores blocker status
  /// (completed, skipped, worked-on-today) so it can be used for stable
  /// positional ordering.
  Future<Map<int, int>> getSiblingDependencyPairs(List<int> taskIds) async {
    if (taskIds.isEmpty) return {};
    final db = await database;
    final placeholders = taskIds.map((_) => '?').join(',');
    final rows = await db.rawQuery('''
      SELECT task_id, depends_on_id
      FROM task_dependencies
      WHERE task_id IN ($placeholders)
        AND depends_on_id IN ($placeholders)
    ''', [...taskIds, ...taskIds]);
    return {
      for (final row in rows)
        row['task_id'] as int: row['depends_on_id'] as int,
    };
  }

  /// Removes all dependencies for a task (used before setting a new single dependency).
  /// Enqueues sync removal events for each deleted dependency.
  Future<void> removeAllDependencies(int taskId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Look up existing dependencies and their sync_ids before deleting
      final rows = await txn.rawQuery('''
        SELECT t1.sync_id AS task_sync_id, t2.sync_id AS depends_on_sync_id
        FROM task_dependencies td
        JOIN tasks t1 ON td.task_id = t1.id
        JOIN tasks t2 ON td.depends_on_id = t2.id
        WHERE td.task_id = ? AND t1.sync_id IS NOT NULL AND t2.sync_id IS NOT NULL
      ''', [taskId]);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        await txn.insert('sync_queue', {
          'entity_type': 'dependency',
          'action': 'remove',
          'key1': row['task_sync_id'] as String,
          'key2': row['depends_on_sync_id'] as String,
          'created_at': now,
        });
      }
      await txn.delete('task_dependencies', where: 'task_id = ?', whereArgs: [taskId]);
    });
  }

  /// Returns true if there is a dependency path from [fromId] to [toId].
  /// Used for cycle detection on the dependency graph.
  Future<bool> hasDependencyPath(int fromId, int toId) async {
    final db = await database;
    final result = await db.rawQuery('''
      WITH RECURSIVE dep_chain(id) AS (
        SELECT depends_on_id FROM task_dependencies WHERE task_id = ?
        UNION
        SELECT td.depends_on_id FROM task_dependencies td
        INNER JOIN dep_chain dc ON td.task_id = dc.id
      )
      SELECT 1 FROM dep_chain WHERE id = ? LIMIT 1
    ''', [fromId, toId]);
    return result.isNotEmpty;
  }

  /// Deletes a task and reparents its children to its parents.
  /// Returns info needed for undo, including which reparent links were added.
  Future<({
    Task task,
    List<int> parentIds,
    List<int> childIds,
    List<int> dependsOnIds,
    List<int> dependedByIds,
    List<({int parentId, int childId})> addedReparentLinks,
  })> deleteTaskAndReparentChildren(int taskId) async {
    final db = await database;
    // Load task data before deleting
    final taskMaps = await db.query('tasks', where: 'id = ?', whereArgs: [taskId]);
    if (taskMaps.isEmpty) throw StateError('Task $taskId not found');
    final task = Task.fromMap(taskMaps.first);

    return db.transaction((txn) async {
      final parentMaps = await txn.query('task_relationships',
          columns: ['parent_id'], where: 'child_id = ?', whereArgs: [taskId]);
      final childMaps = await txn.query('task_relationships',
          columns: ['child_id'], where: 'parent_id = ?', whereArgs: [taskId]);
      final dependsOnMaps = await txn.query('task_dependencies',
          columns: ['depends_on_id'], where: 'task_id = ?', whereArgs: [taskId]);
      final dependedByMaps = await txn.query('task_dependencies',
          columns: ['task_id'], where: 'depends_on_id = ?', whereArgs: [taskId]);

      final parentIds = parentMaps.map((m) => m['parent_id'] as int).toList();
      final childIds = childMaps.map((m) => m['child_id'] as int).toList();
      final dependsOnIds = dependsOnMaps.map((m) => m['depends_on_id'] as int).toList();
      final dependedByIds = dependedByMaps.map((m) => m['task_id'] as int).toList();

      // Reparent: connect each child to each parent. Track which links are new.
      final addedLinks = <({int parentId, int childId})>[];
      for (final parentId in parentIds) {
        for (final childId in childIds) {
          final existing = await txn.query('task_relationships',
              where: 'parent_id = ? AND child_id = ?',
              whereArgs: [parentId, childId]);
          if (existing.isEmpty) {
            await txn.insert('task_relationships', {
              'parent_id': parentId,
              'child_id': childId,
            });
            addedLinks.add((parentId: parentId, childId: childId));
          }
        }
      }

      // Enqueue sync events
      final now = DateTime.now().millisecondsSinceEpoch;
      // Look up sync_ids for all involved tasks
      final allIds = <int>{taskId, ...parentIds, ...childIds, ...dependsOnIds, ...dependedByIds};
      final idPlaceholders = allIds.map((_) => '?').join(',');
      final syncRows = await txn.rawQuery(
        'SELECT id, sync_id FROM tasks WHERE id IN ($idPlaceholders) AND sync_id IS NOT NULL',
        allIds.toList());
      final syncMap = <int, String>{};
      for (final r in syncRows) {
        syncMap[r['id'] as int] = r['sync_id'] as String;
      }
      // Enqueue task deletion
      final taskSyncId = syncMap[taskId];
      if (taskSyncId != null) {
        await txn.insert('sync_queue', {
          'entity_type': 'task', 'action': 'remove',
          'key1': taskSyncId, 'key2': '', 'created_at': now,
        });
      }
      // Enqueue new reparent relationship additions
      for (final link in addedLinks) {
        final pSyncId = syncMap[link.parentId];
        final cSyncId = syncMap[link.childId];
        if (pSyncId != null && cSyncId != null) {
          await txn.insert('sync_queue', {
            'entity_type': 'relationship', 'action': 'add',
            'key1': pSyncId, 'key2': cSyncId, 'created_at': now,
          });
        }
      }
      // Enqueue removed relationships (task's own parent/child links)
      for (final pid in parentIds) {
        final pSyncId = syncMap[pid];
        if (pSyncId != null && taskSyncId != null) {
          await txn.insert('sync_queue', {
            'entity_type': 'relationship', 'action': 'remove',
            'key1': pSyncId, 'key2': taskSyncId, 'created_at': now,
          });
        }
      }
      for (final cid in childIds) {
        final cSyncId = syncMap[cid];
        if (taskSyncId != null && cSyncId != null) {
          await txn.insert('sync_queue', {
            'entity_type': 'relationship', 'action': 'remove',
            'key1': taskSyncId, 'key2': cSyncId, 'created_at': now,
          });
        }
      }

      // Delete the task and its relationships/dependencies
      await txn.delete('task_relationships',
          where: 'parent_id = ? OR child_id = ?', whereArgs: [taskId, taskId]);
      await txn.delete('task_dependencies',
          where: 'task_id = ? OR depends_on_id = ?', whereArgs: [taskId, taskId]);
      await txn.delete('tasks', where: 'id = ?', whereArgs: [taskId]);

      return (
        task: task,
        parentIds: parentIds,
        childIds: childIds,
        dependsOnIds: dependsOnIds,
        dependedByIds: dependedByIds,
        addedReparentLinks: addedLinks,
      );
    });
  }

  /// Deletes a task and all its descendants (the entire subtree).
  /// Returns all deleted data for undo support.
  Future<({
    List<Task> deletedTasks,
    List<({int parentId, int childId})> deletedRelationships,
    List<({int taskId, int dependsOnId})> deletedDependencies,
  })> deleteTaskSubtree(int taskId) async {
    final db = await database;
    return db.transaction((txn) async {
      // Find all descendant IDs via recursive CTE
      final descendantRows = await txn.rawQuery('''
        WITH RECURSIVE subtree(id) AS (
          VALUES(?)
          UNION
          SELECT tr.child_id FROM task_relationships tr
          INNER JOIN subtree s ON tr.parent_id = s.id
        )
        SELECT id FROM subtree
      ''', [taskId]);
      final subtreeIds = descendantRows.map((r) => r['id'] as int).toSet();

      // Load all Task objects in the subtree
      final placeholders = subtreeIds.map((_) => '?').join(',');
      final taskMaps = await txn.rawQuery(
        'SELECT * FROM tasks WHERE id IN ($placeholders)', subtreeIds.toList());
      final deletedTasks = _tasksFromMaps(taskMaps);

      // Capture all relationships touching the subtree
      final relRows = await txn.rawQuery('''
        SELECT parent_id, child_id FROM task_relationships
        WHERE parent_id IN ($placeholders) OR child_id IN ($placeholders)
      ''', [...subtreeIds, ...subtreeIds]);
      final deletedRelationships = relRows
          .map((r) => (parentId: r['parent_id'] as int, childId: r['child_id'] as int))
          .toList();

      // Capture all dependencies touching the subtree
      final depRows = await txn.rawQuery('''
        SELECT task_id, depends_on_id FROM task_dependencies
        WHERE task_id IN ($placeholders) OR depends_on_id IN ($placeholders)
      ''', [...subtreeIds, ...subtreeIds]);
      final deletedDependencies = depRows
          .map((r) => (taskId: r['task_id'] as int, dependsOnId: r['depends_on_id'] as int))
          .toList();

      // Enqueue sync events for each deleted task that has a sync_id
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final task in deletedTasks) {
        if (task.syncId != null) {
          await txn.insert('sync_queue', {
            'entity_type': 'task',
            'action': 'remove',
            'key1': task.syncId!,
            'key2': '',
            'created_at': now,
          });
        }
      }
      // Enqueue sync events for deleted relationships
      final relSyncRows = await txn.rawQuery('''
        SELECT t1.sync_id AS parent_sync_id, t2.sync_id AS child_sync_id
        FROM task_relationships tr
        JOIN tasks t1 ON tr.parent_id = t1.id
        JOIN tasks t2 ON tr.child_id = t2.id
        WHERE (tr.parent_id IN ($placeholders) OR tr.child_id IN ($placeholders))
          AND t1.sync_id IS NOT NULL AND t2.sync_id IS NOT NULL
      ''', [...subtreeIds, ...subtreeIds]);
      for (final row in relSyncRows) {
        await txn.insert('sync_queue', {
          'entity_type': 'relationship',
          'action': 'remove',
          'key1': row['parent_sync_id'] as String,
          'key2': row['child_sync_id'] as String,
          'created_at': now,
        });
      }
      // Enqueue sync events for deleted dependencies
      final depSyncRows = await txn.rawQuery('''
        SELECT t1.sync_id AS task_sync_id, t2.sync_id AS depends_on_sync_id
        FROM task_dependencies td
        JOIN tasks t1 ON td.task_id = t1.id
        JOIN tasks t2 ON td.depends_on_id = t2.id
        WHERE (td.task_id IN ($placeholders) OR td.depends_on_id IN ($placeholders))
          AND t1.sync_id IS NOT NULL AND t2.sync_id IS NOT NULL
      ''', [...subtreeIds, ...subtreeIds]);
      for (final row in depSyncRows) {
        await txn.insert('sync_queue', {
          'entity_type': 'dependency',
          'action': 'remove',
          'key1': row['task_sync_id'] as String,
          'key2': row['depends_on_sync_id'] as String,
          'created_at': now,
        });
      }

      // Delete everything
      await txn.rawDelete(
        'DELETE FROM task_relationships WHERE parent_id IN ($placeholders) OR child_id IN ($placeholders)',
        [...subtreeIds, ...subtreeIds]);
      await txn.rawDelete(
        'DELETE FROM task_dependencies WHERE task_id IN ($placeholders) OR depends_on_id IN ($placeholders)',
        [...subtreeIds, ...subtreeIds]);
      await txn.rawDelete(
        'DELETE FROM tasks WHERE id IN ($placeholders)', subtreeIds.toList());

      return (
        deletedTasks: deletedTasks,
        deletedRelationships: deletedRelationships,
        deletedDependencies: deletedDependencies,
      );
    });
  }

  /// Restores a previously deleted subtree (inverse of deleteTaskSubtree).
  Future<void> restoreTaskSubtree({
    required List<Task> tasks,
    required List<({int parentId, int childId})> relationships,
    required List<({int taskId, int dependsOnId})> dependencies,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // Cancel pending sync deletion entries for all restored tasks
      for (final task in tasks) {
        if (task.syncId != null) {
          await txn.delete('sync_queue',
            where: "entity_type = 'task' AND action = 'remove' AND key1 = ?",
            whereArgs: [task.syncId]);
        }
      }

      // Re-insert tasks as 'pending' so they get re-pushed
      for (final task in tasks) {
        final map = task.toMap();
        map['sync_status'] = 'pending';
        await txn.insert('tasks', map);
      }

      // Build sync_id lookup for relationship/dependency sync queue cleanup
      final syncMap = <int, String>{};
      for (final task in tasks) {
        if (task.id != null && task.syncId != null) {
          syncMap[task.id!] = task.syncId!;
        }
      }
      // Also look up sync_ids for tasks outside the subtree that may have relationships
      final externalIds = <int>{};
      for (final rel in relationships) {
        if (!syncMap.containsKey(rel.parentId)) externalIds.add(rel.parentId);
        if (!syncMap.containsKey(rel.childId)) externalIds.add(rel.childId);
      }
      for (final dep in dependencies) {
        if (!syncMap.containsKey(dep.taskId)) externalIds.add(dep.taskId);
        if (!syncMap.containsKey(dep.dependsOnId)) externalIds.add(dep.dependsOnId);
      }
      if (externalIds.isNotEmpty) {
        final placeholders = externalIds.map((_) => '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT id, sync_id FROM tasks WHERE id IN ($placeholders) AND sync_id IS NOT NULL',
          externalIds.toList());
        for (final r in rows) {
          syncMap[r['id'] as int] = r['sync_id'] as String;
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;

      for (final rel in relationships) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO task_relationships (parent_id, child_id) VALUES (?, ?)',
          [rel.parentId, rel.childId]);
        // Cancel removal and enqueue addition for synced pairs
        final pSyncId = syncMap[rel.parentId];
        final cSyncId = syncMap[rel.childId];
        if (pSyncId != null && cSyncId != null) {
          await txn.delete('sync_queue',
            where: "entity_type = 'relationship' AND action = 'remove' AND key1 = ? AND key2 = ?",
            whereArgs: [pSyncId, cSyncId]);
          await txn.insert('sync_queue', {
            'entity_type': 'relationship', 'action': 'add',
            'key1': pSyncId, 'key2': cSyncId, 'created_at': now,
          });
        }
      }
      for (final dep in dependencies) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO task_dependencies (task_id, depends_on_id) VALUES (?, ?)',
          [dep.taskId, dep.dependsOnId]);
        final tSyncId = syncMap[dep.taskId];
        final dSyncId = syncMap[dep.dependsOnId];
        if (tSyncId != null && dSyncId != null) {
          await txn.delete('sync_queue',
            where: "entity_type = 'dependency' AND action = 'remove' AND key1 = ? AND key2 = ?",
            whereArgs: [tSyncId, dSyncId]);
          await txn.insert('sync_queue', {
            'entity_type': 'dependency', 'action': 'add',
            'key1': tSyncId, 'key2': dSyncId, 'created_at': now,
          });
        }
      }
    });
  }

  /// Deletes all local tasks, relationships, dependencies, and sync queue.
  /// Used when the user chooses "Replace with cloud data" on first sign-in.
  Future<void> deleteAllLocalData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('sync_queue');
      await txn.delete('task_dependencies');
      await txn.delete('task_relationships');
      await txn.delete('tasks');
    });
  }

  // --- Sync-related methods ---

  /// Returns all tasks with sync_status = 'pending'.
  Future<List<Task>> getPendingTasks() async {
    final db = await database;
    final maps = await db.query('tasks', where: "sync_status = 'pending'");
    return _tasksFromMaps(maps);
  }

  /// Marks tasks as synced by their IDs.
  Future<void> markTasksSynced(List<int> taskIds) async {
    if (taskIds.isEmpty) return;
    final db = await database;
    final placeholders = taskIds.map((_) => '?').join(',');
    await db.rawUpdate(
      "UPDATE tasks SET sync_status = 'synced' WHERE id IN ($placeholders)",
      taskIds,
    );
  }

  /// Drains and returns all entries from the sync_queue, deleting them.
  /// Returns all pending sync queue entries without deleting them.
  Future<List<Map<String, dynamic>>> peekSyncQueue() async {
    final db = await database;
    return db.query('sync_queue', orderBy: 'id ASC');
  }

  /// Deletes a single sync queue entry by its row ID.
  Future<void> deleteSyncQueueEntry(int id) async {
    final db = await database;
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  /// Reads and deletes all sync queue entries atomically.
  /// @deprecated Use peekSyncQueue + deleteSyncQueueEntry for safe processing.
  Future<List<Map<String, dynamic>>> drainSyncQueue() async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query('sync_queue', orderBy: 'id ASC');
      if (rows.isNotEmpty) {
        await txn.delete('sync_queue');
      }
      return rows;
    });
  }

  /// Finds a task by its sync_id. Returns null if not found.
  Future<Task?> getTaskBySyncId(String syncId) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'sync_id = ?', whereArgs: [syncId]);
    if (maps.isEmpty) return null;
    return Task.fromMap(maps.first);
  }

  /// Upserts a task from a remote source (sync pull).
  /// If a task with the same sync_id exists and remote is newer, updates it.
  /// If no task with that sync_id exists, inserts it.
  /// Returns true if a change was made.
  Future<bool> upsertFromRemote(Task remoteTask) async {
    final db = await database;
    final existing = await db.query('tasks', where: 'sync_id = ?', whereArgs: [remoteTask.syncId]);
    if (existing.isEmpty) {
      // Insert new task from remote
      final map = remoteTask.toMap();
      map.remove('id'); // let local DB assign ID
      map['sync_status'] = 'synced';
      await db.insert('tasks', map);
      return true;
    } else {
      final local = Task.fromMap(existing.first);
      if (remoteTask.updatedAt != null &&
          (local.updatedAt == null || remoteTask.updatedAt! > local.updatedAt!)) {
        // Remote is newer — update local
        final map = remoteTask.toMap();
        map.remove('id'); // keep local ID
        map['sync_status'] = 'synced';
        await db.update('tasks', map, where: 'id = ?', whereArgs: [local.id]);
        return true;
      }
      return false; // local is newer or same
    }
  }

  /// Returns all relationships as (parentSyncId, childSyncId) pairs.
  Future<List<({String parentSyncId, String childSyncId})>> getAllRelationshipsWithSyncIds() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT p.sync_id AS parent_sync_id, c.sync_id AS child_sync_id
      FROM task_relationships tr
      INNER JOIN tasks p ON tr.parent_id = p.id
      INNER JOIN tasks c ON tr.child_id = c.id
      WHERE p.sync_id IS NOT NULL AND c.sync_id IS NOT NULL
    ''');
    return rows.map((r) => (
      parentSyncId: r['parent_sync_id'] as String,
      childSyncId: r['child_sync_id'] as String,
    )).toList();
  }

  /// Returns all dependencies as (taskSyncId, dependsOnSyncId) pairs.
  Future<List<({String taskSyncId, String dependsOnSyncId})>> getAllDependenciesWithSyncIds() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.sync_id AS task_sync_id, d.sync_id AS depends_on_sync_id
      FROM task_dependencies td
      INNER JOIN tasks t ON td.task_id = t.id
      INNER JOIN tasks d ON td.depends_on_id = d.id
      WHERE t.sync_id IS NOT NULL AND d.sync_id IS NOT NULL
    ''');
    return rows.map((r) => (
      taskSyncId: r['task_sync_id'] as String,
      dependsOnSyncId: r['depends_on_sync_id'] as String,
    )).toList();
  }

  /// Returns true if adding a relationship (by sync_ids) would create a cycle.
  Future<bool> wouldRelationshipCreateCycle(String parentSyncId, String childSyncId) async {
    final db = await database;
    final parentRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [parentSyncId]);
    final childRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [childSyncId]);
    if (parentRows.isEmpty || childRows.isEmpty) return false;
    final parentId = parentRows.first['id'] as int;
    final childId = childRows.first['id'] as int;
    // Would adding child→parent path create a cycle? Check if parent is already reachable from child.
    return hasPath(childId, parentId);
  }

  /// Returns true if adding a dependency (by sync_ids) would create a cycle.
  Future<bool> wouldDependencyCreateCycle(String taskSyncId, String dependsOnSyncId) async {
    final db = await database;
    final taskRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [taskSyncId]);
    final depRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [dependsOnSyncId]);
    if (taskRows.isEmpty || depRows.isEmpty) return false;
    final taskId = taskRows.first['id'] as int;
    final depId = depRows.first['id'] as int;
    return hasDependencyPath(depId, taskId);
  }

  /// Upserts a relationship from remote using sync_ids.
  Future<void> upsertRelationshipFromRemote(String parentSyncId, String childSyncId) async {
    final db = await database;
    final parentRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [parentSyncId]);
    final childRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [childSyncId]);
    if (parentRows.isEmpty || childRows.isEmpty) return;
    final parentId = parentRows.first['id'] as int;
    final childId = childRows.first['id'] as int;
    await db.rawInsert(
      'INSERT OR IGNORE INTO task_relationships (parent_id, child_id) VALUES (?, ?)',
      [parentId, childId],
    );
  }

  /// Removes a relationship from remote using sync_ids.
  Future<void> removeRelationshipFromRemote(String parentSyncId, String childSyncId) async {
    final db = await database;
    final parentRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [parentSyncId]);
    final childRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [childSyncId]);
    if (parentRows.isEmpty || childRows.isEmpty) return;
    await db.delete('task_relationships',
      where: 'parent_id = ? AND child_id = ?',
      whereArgs: [parentRows.first['id'], childRows.first['id']]);
  }

  /// Upserts a dependency from remote using sync_ids.
  Future<void> upsertDependencyFromRemote(String taskSyncId, String dependsOnSyncId) async {
    final db = await database;
    final taskRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [taskSyncId]);
    final depRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [dependsOnSyncId]);
    if (taskRows.isEmpty || depRows.isEmpty) return;
    await db.rawInsert(
      'INSERT OR IGNORE INTO task_dependencies (task_id, depends_on_id) VALUES (?, ?)',
      [taskRows.first['id'], depRows.first['id']],
    );
  }

  /// Removes a dependency from remote using sync_ids.
  Future<void> removeDependencyFromRemote(String taskSyncId, String dependsOnSyncId) async {
    final db = await database;
    final taskRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [taskSyncId]);
    final depRows = await db.query('tasks', columns: ['id'], where: 'sync_id = ?', whereArgs: [dependsOnSyncId]);
    if (taskRows.isEmpty || depRows.isEmpty) return;
    await db.delete('task_dependencies',
      where: 'task_id = ? AND depends_on_id = ?',
      whereArgs: [taskRows.first['id'], depRows.first['id']]);
  }

  /// Returns all tasks (including completed/skipped) that have a sync_id.
  Future<List<Task>> getAllTasksWithSyncId() async {
    final db = await database;
    final maps = await db.query('tasks', where: 'sync_id IS NOT NULL');
    return _tasksFromMaps(maps);
  }

  /// Returns all active leaf descendants of [taskId].
  /// A leaf descendant is one with no active (non-completed, non-skipped) children.
  Future<List<Task>> getLeafDescendants(int taskId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      WITH RECURSIVE descendants(id) AS (
        SELECT child_id FROM task_relationships WHERE parent_id = ?
        UNION
        SELECT tr.child_id FROM task_relationships tr
        INNER JOIN descendants d ON tr.parent_id = d.id
      )
      SELECT t.* FROM tasks t
      INNER JOIN descendants d ON t.id = d.id
      WHERE t.completed_at IS NULL
      AND t.skipped_at IS NULL
      AND t.id NOT IN (
        SELECT DISTINCT tr2.parent_id FROM task_relationships tr2
        INNER JOIN tasks c ON tr2.child_id = c.id
        WHERE c.completed_at IS NULL AND c.skipped_at IS NULL
      )
    ''', [taskId]);
    return _tasksFromMaps(maps);
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

  // --- Today's 5 state methods ---

  /// Saves Today's 5 state to the DB, replacing any existing data for [date].
  Future<void> saveTodaysFiveState({
    required String date,
    required List<int> taskIds,
    required Set<int> completedIds,
    required Set<int> workedOnIds,
    Set<int> pinnedIds = const {},
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('todays_five_state', where: 'date = ?', whereArgs: [date]);
      for (var i = 0; i < taskIds.length; i++) {
        final id = taskIds[i];
        await txn.insert('todays_five_state', {
          'date': date,
          'task_id': id,
          'is_completed': completedIds.contains(id) ? 1 : 0,
          'is_worked_on': workedOnIds.contains(id) ? 1 : 0,
          'sort_order': i,
          'is_pinned': pinnedIds.contains(id) ? 1 : 0,
        });
      }
    });
  }

  /// Loads Today's 5 state from the DB for [date]. Returns null if no data.
  Future<TodaysFiveData?> loadTodaysFiveState(String date) async {
    final db = await database;
    final rows = await db.query(
      'todays_five_state',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'sort_order ASC',
    );
    if (rows.isEmpty) return null;
    final taskIds = <int>[];
    final completedIds = <int>{};
    final workedOnIds = <int>{};
    final pinnedIds = <int>{};
    for (final row in rows) {
      final taskId = row['task_id'] as int;
      taskIds.add(taskId);
      if (row['is_completed'] == 1) completedIds.add(taskId);
      if (row['is_worked_on'] == 1) workedOnIds.add(taskId);
      if (row['is_pinned'] == 1) pinnedIds.add(taskId);
    }
    return TodaysFiveData(
      date: date,
      taskIds: taskIds,
      completedIds: completedIds,
      workedOnIds: workedOnIds,
      pinnedIds: pinnedIds,
    );
  }

  /// Returns just the task IDs for today's five (for indicator on task cards).
  Future<Set<int>> getTodaysFiveTaskIds(String date) async {
    final db = await database;
    final rows = await db.query(
      'todays_five_state',
      columns: ['task_id'],
      where: 'date = ?',
      whereArgs: [date],
    );
    return rows.map((r) => r['task_id'] as int).toSet();
  }

  /// Returns task IDs and pinned IDs for today's five.
  Future<({Set<int> taskIds, Set<int> pinnedIds})> getTodaysFiveTaskAndPinIds(String date) async {
    final db = await database;
    final rows = await db.query(
      'todays_five_state',
      columns: ['task_id', 'is_pinned'],
      where: 'date = ?',
      whereArgs: [date],
    );
    final taskIds = <int>{};
    final pinnedIds = <int>{};
    for (final row in rows) {
      final id = row['task_id'] as int;
      taskIds.add(id);
      if (row['is_pinned'] == 1) pinnedIds.add(id);
    }
    return (taskIds: taskIds, pinnedIds: pinnedIds);
  }

  /// Migrates Today's 5 state from SharedPreferences to the DB (idempotent).
  /// Only migrates if SharedPreferences has data AND the DB doesn't for that date.
  /// Clears SharedPreferences keys after a verified DB write.
  Future<void> migrateTodaysFiveFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDate = prefs.getString('todays5_date');
    if (savedDate == null) return; // nothing to migrate

    // Check if DB already has data for this date (idempotent)
    final existing = await loadTodaysFiveState(savedDate);
    if (existing != null) {
      // Already migrated — just clean up prefs
      await prefs.remove('todays5_date');
      await prefs.remove('todays5_ids');
      await prefs.remove('todays5_completed');
      await prefs.remove('todays5_worked_on');
      return;
    }

    final savedIds = prefs.getStringList('todays5_ids') ?? [];
    if (savedIds.isEmpty) {
      // No task IDs to migrate — clean up
      await prefs.remove('todays5_date');
      await prefs.remove('todays5_ids');
      await prefs.remove('todays5_completed');
      await prefs.remove('todays5_worked_on');
      return;
    }

    final completedIds = (prefs.getStringList('todays5_completed') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final workedOnIds = (prefs.getStringList('todays5_worked_on') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final taskIds = savedIds.map(int.tryParse).whereType<int>().toList();

    // Write to DB
    await saveTodaysFiveState(
      date: savedDate,
      taskIds: taskIds,
      completedIds: completedIds,
      workedOnIds: workedOnIds,
    );

    // Verify DB write succeeded before clearing prefs
    final verify = await loadTodaysFiveState(savedDate);
    if (verify != null && verify.taskIds.isNotEmpty) {
      await prefs.remove('todays5_date');
      await prefs.remove('todays5_ids');
      await prefs.remove('todays5_completed');
      await prefs.remove('todays5_worked_on');
    }
  }

  /// Returns tasks completed or worked-on today, excluding the given IDs.
  Future<List<Task>> getTasksDoneToday({Set<int> excludeIds = const {}}) async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final endOfDay = startOfDay + 86400000; // +24h in ms

    // Tasks where completed_at OR last_worked_at falls within today
    final maps = await db.rawQuery('''
      SELECT * FROM tasks
      WHERE (
        (completed_at >= ? AND completed_at < ?)
        OR (last_worked_at >= ? AND last_worked_at < ?)
      )
      ORDER BY COALESCE(completed_at, last_worked_at) DESC
    ''', [startOfDay, endOfDay, startOfDay, endOfDay]);

    final tasks = _tasksFromMaps(maps);
    if (excludeIds.isEmpty) return tasks;
    return tasks.where((t) => !excludeIds.contains(t.id)).toList();
  }

}
