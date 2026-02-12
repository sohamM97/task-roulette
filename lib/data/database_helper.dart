import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/task.dart';

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
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'task_roulette.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL
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
    );
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
      ORDER BY t.created_at ASC
    ''', [childId]);
    return maps.map((m) => Task.fromMap(m)).toList();
  }

  Future<void> deleteTask(int taskId) async {
    final db = await database;
    await db.delete('task_relationships',
        where: 'parent_id = ? OR child_id = ?',
        whereArgs: [taskId, taskId]);
    await db.delete('tasks', where: 'id = ?', whereArgs: [taskId]);
  }
}
