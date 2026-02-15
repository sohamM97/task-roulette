import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';

void main() {
  late DatabaseHelper db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    db = DatabaseHelper();
    await db.reset();
    // Force initialization
    await db.database;
  });

  tearDown(() async {
    await db.reset();
  });

  group('Task completion', () {
    test('completeTask sets completed_at', () async {
      final id = await db.insertTask(Task(name: 'Buy milk'));
      await db.completeTask(id);

      // Completed task should be excluded from getAllTasks
      final tasks = await db.getAllTasks();
      expect(tasks.where((t) => t.id == id), isEmpty);
    });

    test('uncompleteTask clears completed_at', () async {
      final id = await db.insertTask(Task(name: 'Buy milk'));
      await db.completeTask(id);
      await db.uncompleteTask(id);

      final tasks = await db.getAllTasks();
      expect(tasks.where((t) => t.id == id), hasLength(1));
      expect(tasks.first.isCompleted, isFalse);
    });

    test('completed tasks excluded from getRootTasks', () async {
      final id1 = await db.insertTask(Task(name: 'Task A'));
      final id2 = await db.insertTask(Task(name: 'Task B'));
      await db.completeTask(id1);

      final roots = await db.getRootTasks();
      final rootIds = roots.map((t) => t.id).toList();
      expect(rootIds, contains(id2));
      expect(rootIds, isNot(contains(id1)));
    });

    test('completed tasks excluded from getChildren', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final child1 = await db.insertTask(Task(name: 'Child 1'));
      final child2 = await db.insertTask(Task(name: 'Child 2'));
      await db.addRelationship(parentId, child1);
      await db.addRelationship(parentId, child2);
      await db.completeTask(child1);

      final children = await db.getChildren(parentId);
      final childIds = children.map((t) => t.id).toList();
      expect(childIds, contains(child2));
      expect(childIds, isNot(contains(child1)));
    });

    test('completed tasks excluded from getParents', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent1, child);
      await db.addRelationship(parent2, child);
      await db.completeTask(parent1);

      final parents = await db.getParents(child);
      final parentIds = parents.map((t) => t.id).toList();
      expect(parentIds, contains(parent2));
      expect(parentIds, isNot(contains(parent1)));
    });

    test('completed tasks excluded from getParentNamesMap', () async {
      final parent = await db.insertTask(Task(name: 'Visible Parent'));
      final hiddenParent = await db.insertTask(Task(name: 'Hidden Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent, child);
      await db.addRelationship(hiddenParent, child);
      await db.completeTask(hiddenParent);

      final map = await db.getParentNamesMap();
      expect(map[child], ['Visible Parent']);
    });

    test('complete and uncomplete round-trip', () async {
      final id = await db.insertTask(Task(name: 'Flip flop'));

      // Initially visible
      expect((await db.getAllTasks()).map((t) => t.id), contains(id));

      // Complete — hidden
      await db.completeTask(id);
      expect((await db.getAllTasks()).map((t) => t.id), isNot(contains(id)));

      // Uncomplete — visible again
      await db.uncompleteTask(id);
      final tasks = await db.getAllTasks();
      final restored = tasks.firstWhere((t) => t.id == id);
      expect(restored.isCompleted, isFalse);
    });
  });

  group('Task started state', () {
    test('startTask sets started_at', () async {
      final id = await db.insertTask(Task(name: 'WIP'));
      await db.startTask(id);

      final tasks = await db.getAllTasks();
      final task = tasks.firstWhere((t) => t.id == id);
      expect(task.startedAt, isNotNull);
      expect(task.isStarted, isTrue);
    });

    test('unstartTask clears started_at', () async {
      final id = await db.insertTask(Task(name: 'WIP'));
      await db.startTask(id);
      await db.unstartTask(id);

      final tasks = await db.getAllTasks();
      final task = tasks.firstWhere((t) => t.id == id);
      expect(task.startedAt, isNull);
      expect(task.isStarted, isFalse);
    });

    test('start and unstart round-trip', () async {
      final id = await db.insertTask(Task(name: 'Toggle'));

      // Initially not started
      var tasks = await db.getAllTasks();
      expect(tasks.firstWhere((t) => t.id == id).isStarted, isFalse);

      // Start
      await db.startTask(id);
      tasks = await db.getAllTasks();
      expect(tasks.firstWhere((t) => t.id == id).isStarted, isTrue);

      // Unstart
      await db.unstartTask(id);
      tasks = await db.getAllTasks();
      expect(tasks.firstWhere((t) => t.id == id).isStarted, isFalse);
    });

    test('completing a started task makes isStarted false', () async {
      final id = await db.insertTask(Task(name: 'Started then done'));
      await db.startTask(id);
      await db.completeTask(id);

      final completed = await db.getArchivedTasks();
      final task = completed.firstWhere((t) => t.id == id);
      expect(task.startedAt, isNotNull);
      expect(task.isCompleted, isTrue);
      expect(task.isStarted, isFalse);
    });
  });

  group('Task skip', () {
    test('skipTask sets skipped_at', () async {
      final id = await db.insertTask(Task(name: 'Boring task'));
      await db.skipTask(id);

      // Skipped task should be excluded from getAllTasks
      final tasks = await db.getAllTasks();
      expect(tasks.where((t) => t.id == id), isEmpty);
    });

    test('unskipTask clears skipped_at', () async {
      final id = await db.insertTask(Task(name: 'Boring task'));
      await db.skipTask(id);
      await db.unskipTask(id);

      final tasks = await db.getAllTasks();
      expect(tasks.where((t) => t.id == id), hasLength(1));
      expect(tasks.first.isSkipped, isFalse);
    });

    test('skipped tasks excluded from getRootTasks', () async {
      final id1 = await db.insertTask(Task(name: 'Task A'));
      final id2 = await db.insertTask(Task(name: 'Task B'));
      await db.skipTask(id1);

      final roots = await db.getRootTasks();
      final rootIds = roots.map((t) => t.id).toList();
      expect(rootIds, contains(id2));
      expect(rootIds, isNot(contains(id1)));
    });

    test('skipped tasks excluded from getChildren', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final child1 = await db.insertTask(Task(name: 'Child 1'));
      final child2 = await db.insertTask(Task(name: 'Child 2'));
      await db.addRelationship(parentId, child1);
      await db.addRelationship(parentId, child2);
      await db.skipTask(child1);

      final children = await db.getChildren(parentId);
      final childIds = children.map((t) => t.id).toList();
      expect(childIds, contains(child2));
      expect(childIds, isNot(contains(child1)));
    });

    test('skipped tasks excluded from getParents', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent1, child);
      await db.addRelationship(parent2, child);
      await db.skipTask(parent1);

      final parents = await db.getParents(child);
      final parentIds = parents.map((t) => t.id).toList();
      expect(parentIds, contains(parent2));
      expect(parentIds, isNot(contains(parent1)));
    });

    test('skipped tasks excluded from getParentNamesMap', () async {
      final parent = await db.insertTask(Task(name: 'Visible Parent'));
      final hiddenParent = await db.insertTask(Task(name: 'Hidden Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent, child);
      await db.addRelationship(hiddenParent, child);
      await db.skipTask(hiddenParent);

      final map = await db.getParentNamesMap();
      expect(map[child], ['Visible Parent']);
    });

    test('skip and unskip round-trip', () async {
      final id = await db.insertTask(Task(name: 'Flip flop'));

      // Initially visible
      expect((await db.getAllTasks()).map((t) => t.id), contains(id));

      // Skip — hidden
      await db.skipTask(id);
      expect((await db.getAllTasks()).map((t) => t.id), isNot(contains(id)));

      // Unskip — visible again
      await db.unskipTask(id);
      final tasks = await db.getAllTasks();
      final restored = tasks.firstWhere((t) => t.id == id);
      expect(restored.isSkipped, isFalse);
    });

    test('getArchivedTasks includes both completed and skipped tasks', () async {
      final id1 = await db.insertTask(Task(name: 'Completed'));
      final id2 = await db.insertTask(Task(name: 'Skipped'));
      final id3 = await db.insertTask(Task(name: 'Active'));
      await db.completeTask(id1);
      await db.skipTask(id2);

      final archived = await db.getArchivedTasks();
      final archivedIds = archived.map((t) => t.id).toList();
      expect(archivedIds, contains(id1));
      expect(archivedIds, contains(id2));
      expect(archivedIds, isNot(contains(id3)));
    });

    test('skipped started descendant not flagged in getTaskIdsWithStartedDescendants', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);
      await db.skipTask(childId);

      final result = await db.getTaskIdsWithStartedDescendants([parentId]);
      expect(result, isEmpty);
    });
  });

  group('getTaskIdsWithStartedDescendants', () {
    test('returns empty set for tasks with no started descendants', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      final result = await db.getTaskIdsWithStartedDescendants([parentId]);
      expect(result, isEmpty);
    });

    test('returns parent ID when direct child is started', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);

      final result = await db.getTaskIdsWithStartedDescendants([parentId]);
      expect(result, contains(parentId));
    });

    test('returns parent ID when deep descendant is started', () async {
      final grandparent = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(grandparent, parent);
      await db.addRelationship(parent, child);
      await db.startTask(child);

      final result = await db.getTaskIdsWithStartedDescendants([grandparent]);
      expect(result, contains(grandparent));
    });

    test('does not include parent when started descendant is completed', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);
      await db.completeTask(childId);

      final result = await db.getTaskIdsWithStartedDescendants([parentId]);
      expect(result, isEmpty);
    });

    test('returns empty set for empty input', () async {
      final result = await db.getTaskIdsWithStartedDescendants([]);
      expect(result, isEmpty);
    });

    test('handles multiple parents with mixed started descendants', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child1 = await db.insertTask(Task(name: 'Child 1'));
      final child2 = await db.insertTask(Task(name: 'Child 2'));
      await db.addRelationship(parent1, child1);
      await db.addRelationship(parent2, child2);
      await db.startTask(child1);

      final result = await db.getTaskIdsWithStartedDescendants([parent1, parent2]);
      expect(result, contains(parent1));
      expect(result, isNot(contains(parent2)));
    });

    test('grandparent and parent both flagged when grandchild is started', () async {
      final gp = await db.insertTask(Task(name: 'Grandparent'));
      final p = await db.insertTask(Task(name: 'Parent'));
      final c = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(gp, p);
      await db.addRelationship(p, c);
      await db.startTask(c);

      final result = await db.getTaskIdsWithStartedDescendants([gp, p]);
      expect(result, contains(gp));
      expect(result, contains(p));
    });

    test('does not flag task as its own started descendant', () async {
      final taskId = await db.insertTask(Task(name: 'Self'));
      await db.startTask(taskId);

      // A started task should not appear as having started *descendants*
      // (it IS started, but it has no descendants that are started)
      final result = await db.getTaskIdsWithStartedDescendants([taskId]);
      expect(result, isEmpty);
    });

    test('multi-parent DAG: shared child started flags both parents', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent A'));
      final parent2 = await db.insertTask(Task(name: 'Parent B'));
      final child = await db.insertTask(Task(name: 'Shared Child'));
      await db.addRelationship(parent1, child);
      await db.addRelationship(parent2, child);
      await db.startTask(child);

      final result = await db.getTaskIdsWithStartedDescendants([parent1, parent2]);
      expect(result, contains(parent1));
      expect(result, contains(parent2));
    });
  });

  group('Task dependencies', () {
    test('addDependency and getDependencies round-trip', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a); // B depends on A

      final deps = await db.getDependencies(b);
      expect(deps, hasLength(1));
      expect(deps.first.id, a);
    });

    test('removeDependency removes the dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);
      await db.removeDependency(b, a);

      final deps = await db.getDependencies(b);
      expect(deps, isEmpty);
    });

    test('getBlockedTaskIds returns tasks with unresolved dependencies', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addDependency(b, a); // B depends on A (A not completed)

      final blocked = await db.getBlockedTaskIds([a, b, c]);
      expect(blocked, contains(b));
      expect(blocked, isNot(contains(a)));
      expect(blocked, isNot(contains(c)));
    });

    test('getBlockedTaskIds excludes tasks whose deps are completed', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);
      await db.completeTask(a);

      final blocked = await db.getBlockedTaskIds([b]);
      expect(blocked, isEmpty);
    });

    test('getBlockedTaskIds excludes tasks whose deps are skipped', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);
      await db.skipTask(a);

      final blocked = await db.getBlockedTaskIds([b]);
      expect(blocked, isEmpty);
    });

    test('getBlockedTaskIds returns empty for empty input', () async {
      final blocked = await db.getBlockedTaskIds([]);
      expect(blocked, isEmpty);
    });

    test('hasDependencyPath detects direct dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a); // B depends on A

      // Path from B → A exists
      expect(await db.hasDependencyPath(b, a), isTrue);
      // No path from A → B
      expect(await db.hasDependencyPath(a, b), isFalse);
    });

    test('hasDependencyPath detects transitive dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addDependency(b, a); // B depends on A
      await db.addDependency(c, b); // C depends on B

      // C → A exists via B
      expect(await db.hasDependencyPath(c, a), isTrue);
      // A → C does not exist
      expect(await db.hasDependencyPath(a, c), isFalse);
    });

    test('deleteTaskWithRelationships returns dependency IDs', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addDependency(b, a); // B depends on A
      await db.addDependency(c, b); // C depends on B

      final rels = await db.deleteTaskWithRelationships(b);
      expect(rels['dependsOnIds'], contains(a));
      expect(rels['dependedByIds'], contains(c));
    });

    test('restoreTask restores dependencies', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addDependency(b, a);
      await db.addDependency(c, b);

      // Delete B
      final rels = await db.deleteTaskWithRelationships(b);
      final taskB = Task(id: b, name: 'Task B');

      // Restore B with dependencies
      await db.restoreTask(
        taskB, [], [],
        dependsOnIds: rels['dependsOnIds']!,
        dependedByIds: rels['dependedByIds']!,
      );

      // B should still depend on A
      final bDeps = await db.getDependencies(b);
      expect(bDeps.map((t) => t.id), contains(a));

      // C should still depend on B
      final cDeps = await db.getDependencies(c);
      expect(cDeps.map((t) => t.id), contains(b));
    });

    test('getDependencies returns completed deps for UI display', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);
      await db.completeTask(a);

      // getDependencies should still return A (for chip display)
      final deps = await db.getDependencies(b);
      expect(deps, hasLength(1));
      expect(deps.first.id, a);
      expect(deps.first.isCompleted, isTrue);
    });
  });

  group('getDatabasePath', () {
    test('returns testDatabasePath when set', () async {
      expect(DatabaseHelper.testDatabasePath, isNotNull);
      final path = await db.getDatabasePath();
      expect(path, equals(DatabaseHelper.testDatabasePath));
    });
  });

  group('importDatabase', () {
    // These tests use real temp files instead of in-memory databases.
    late Directory tempDir;
    late String mainDbPath;
    late String backupDbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('task_roulette_test_');
      mainDbPath = '${tempDir.path}/main.db';
      backupDbPath = '${tempDir.path}/backup.db';
    });

    tearDown(() async {
      // Restore in-memory path for other test groups
      DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
      await db.reset();
      await tempDir.delete(recursive: true);
    });

    test('replaces current database with imported file', () async {
      // Set up a real file-backed DB with one task
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database; // init
      await db.insertTask(Task(name: 'Original task'));
      var tasks = await db.getAllTasks();
      expect(tasks, hasLength(1));
      expect(tasks.first.name, 'Original task');

      // Create a separate backup DB with different data
      DatabaseHelper.testDatabasePath = backupDbPath;
      await db.reset();
      await db.database; // init
      await db.insertTask(Task(name: 'Backup task A'));
      await db.insertTask(Task(name: 'Backup task B'));
      tasks = await db.getAllTasks();
      expect(tasks, hasLength(2));

      // Import backup over the main DB
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.importDatabase(backupDbPath);

      // Verify main DB now has the backup data
      tasks = await db.getAllTasks();
      expect(tasks, hasLength(2));
      final names = tasks.map((t) => t.name).toSet();
      expect(names, containsAll(['Backup task A', 'Backup task B']));
      expect(names, isNot(contains('Original task')));
    });

    test('clears cached instance so next access reopens fresh', () async {
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database; // init
      await db.insertTask(Task(name: 'Before import'));

      // Create backup
      DatabaseHelper.testDatabasePath = backupDbPath;
      await db.reset();
      await db.database;
      await db.insertTask(Task(name: 'After import'));

      // Import and verify we can immediately query the new data
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database; // open main
      await db.importDatabase(backupDbPath);

      // This should work without needing a manual reset — importDatabase
      // clears the cache internally
      final tasks = await db.getAllTasks();
      expect(tasks, hasLength(1));
      expect(tasks.first.name, 'After import');
    });

    test('preserves relationships in imported database', () async {
      // Create backup DB with parent-child relationship
      DatabaseHelper.testDatabasePath = backupDbPath;
      await db.reset();
      await db.database;
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      // Set up main DB (empty)
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;

      // Import
      await db.importDatabase(backupDbPath);

      // Verify relationships survived
      final children = await db.getChildren(parentId);
      expect(children, hasLength(1));
      expect(children.first.name, 'Child');

      final roots = await db.getRootTasks();
      expect(roots, hasLength(1));
      expect(roots.first.name, 'Parent');
    });

    test('rejects a non-database file', () async {
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;

      // Write a plain text file
      final badFile = File('${tempDir.path}/not_a_db.txt');
      await badFile.writeAsString('this is not a database');

      expect(
        () => db.importDatabase(badFile.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a SQLite database without tasks table', () async {
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;

      // Create a valid SQLite DB that has no tasks table
      final wrongDbPath = '${tempDir.path}/wrong_schema.db';
      final wrongDb = await openDatabase(wrongDbPath, version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, text TEXT)');
        },
      );
      await wrongDb.close();

      expect(
        () => db.importDatabase(wrongDbPath),
        throwsA(isA<FormatException>()),
      );
    });

    test('does not overwrite current DB when validation fails', () async {
      // Set up main DB with data
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;
      await db.insertTask(Task(name: 'Precious task'));

      // Try importing a bad file
      final badFile = File('${tempDir.path}/garbage.bin');
      await badFile.writeAsBytes([0, 1, 2, 3, 4, 5]);

      try {
        await db.importDatabase(badFile.path);
      } on FormatException {
        // expected
      }

      // Original data should still be intact
      // Need to reset since _database was not cleared on failure...
      // Actually, importDatabase only clears after validation passes.
      final tasks = await db.getAllTasks();
      expect(tasks, hasLength(1));
      expect(tasks.first.name, 'Precious task');
    });
  });

  group('exportDatabase (file copy)', () {
    late Directory tempDir;
    late String mainDbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('task_roulette_export_test_');
      mainDbPath = '${tempDir.path}/main.db';
    });

    tearDown(() async {
      DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
      await db.reset();
      await tempDir.delete(recursive: true);
    });

    test('copied DB file contains the same tasks', () async {
      // Create a DB with some tasks
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;
      await db.insertTask(Task(name: 'Task One'));
      await db.insertTask(Task(name: 'Task Two'));

      // Copy the DB file (simulates what BackupService.exportDatabase does)
      final destPath = '${tempDir.path}/export_copy.db';
      await File(mainDbPath).copy(destPath);

      // Open the copy and verify contents
      DatabaseHelper.testDatabasePath = destPath;
      await db.reset();
      final tasks = await db.getAllTasks();
      expect(tasks, hasLength(2));
      final names = tasks.map((t) => t.name).toSet();
      expect(names, containsAll(['Task One', 'Task Two']));
    });

    test('copied DB file preserves relationships', () async {
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      // Copy
      final destPath = '${tempDir.path}/export_copy.db';
      await File(mainDbPath).copy(destPath);

      // Verify the copy
      DatabaseHelper.testDatabasePath = destPath;
      await db.reset();
      final roots = await db.getRootTasks();
      expect(roots, hasLength(1));
      expect(roots.first.name, 'Parent');
      final children = await db.getChildren(parentId);
      expect(children, hasLength(1));
      expect(children.first.name, 'Child');
    });

    test('copied DB file preserves started and completed state', () async {
      DatabaseHelper.testDatabasePath = mainDbPath;
      await db.reset();
      await db.database;
      final id1 = await db.insertTask(Task(name: 'Started'));
      final id2 = await db.insertTask(Task(name: 'Completed'));
      await db.insertTask(Task(name: 'Active'));
      await db.startTask(id1);
      await db.completeTask(id2);

      // Copy
      final destPath = '${tempDir.path}/export_copy.db';
      await File(mainDbPath).copy(destPath);

      // Verify
      DatabaseHelper.testDatabasePath = destPath;
      await db.reset();
      final active = await db.getAllTasks();
      expect(active, hasLength(2)); // Started + Active (Completed excluded)
      final started = active.firstWhere((t) => t.id == id1);
      expect(started.isStarted, isTrue);

      final archived = await db.getArchivedTasks();
      expect(archived, hasLength(1));
      expect(archived.first.name, 'Completed');
    });
  });

  group('hasChildren', () {
    test('returns false for task with no children', () async {
      final id = await db.insertTask(Task(name: 'Leaf'));
      expect(await db.hasChildren(id), isFalse);
    });

    test('returns true for task with children', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      expect(await db.hasChildren(parentId), isTrue);
    });
  });

  group('deleteTaskAndReparentChildren', () {
    test('reparents children to grandparent', () async {
      // Grandparent → Parent → Child
      final gp = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(gp, parent);
      await db.addRelationship(parent, child);

      final result = await db.deleteTaskAndReparentChildren(parent);

      // Parent should be gone
      expect(await db.getTaskById(parent), isNull);
      // Child should now be under Grandparent
      final gpChildren = await db.getChildren(gp);
      expect(gpChildren.map((t) => t.id), contains(child));
      // One reparent link was added
      expect(result.addedReparentLinks, hasLength(1));
      expect(result.addedReparentLinks.first.parentId, gp);
      expect(result.addedReparentLinks.first.childId, child);
    });

    test('does not duplicate pre-existing grandparent link', () async {
      // GP → Parent → Child, and GP → Child already exists
      final gp = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(gp, parent);
      await db.addRelationship(parent, child);
      await db.addRelationship(gp, child); // pre-existing

      final result = await db.deleteTaskAndReparentChildren(parent);

      // No new reparent links were needed
      expect(result.addedReparentLinks, isEmpty);
      // Child is still under GP (just one relationship)
      final gpChildren = await db.getChildren(gp);
      expect(gpChildren.map((t) => t.id), contains(child));
    });

    test('root task reparent: children become root', () async {
      // Root Parent → Child A, Child B (no grandparent)
      final parent = await db.insertTask(Task(name: 'Root Parent'));
      final childA = await db.insertTask(Task(name: 'Child A'));
      final childB = await db.insertTask(Task(name: 'Child B'));
      await db.addRelationship(parent, childA);
      await db.addRelationship(parent, childB);

      final result = await db.deleteTaskAndReparentChildren(parent);

      // No parents → no reparent links
      expect(result.addedReparentLinks, isEmpty);
      // Children should now be root tasks
      final roots = await db.getRootTasks();
      final rootIds = roots.map((t) => t.id).toSet();
      expect(rootIds, contains(childA));
      expect(rootIds, contains(childB));
    });

    test('undo restores original structure', () async {
      final gp = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(gp, parent);
      await db.addRelationship(parent, child);

      final result = await db.deleteTaskAndReparentChildren(parent);

      // Undo: restore with removeReparentLinks
      await db.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
        removeReparentLinks: result.addedReparentLinks,
      );

      // Parent should be back
      expect(await db.getTaskById(parent), isNotNull);
      // Grandparent's children should be just Parent (not Child directly)
      final gpChildren = await db.getChildren(gp);
      expect(gpChildren.map((t) => t.id), contains(parent));
      expect(gpChildren.map((t) => t.id), isNot(contains(child)));
      // Parent's children should be just Child
      final parentChildren = await db.getChildren(parent);
      expect(parentChildren.map((t) => t.id), contains(child));
    });

    test('preserves dependencies during reparent', () async {
      final gp = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      final other = await db.insertTask(Task(name: 'Other'));
      await db.addRelationship(gp, parent);
      await db.addRelationship(parent, child);
      await db.addDependency(parent, other); // parent depends on other

      final result = await db.deleteTaskAndReparentChildren(parent);
      expect(result.dependsOnIds, contains(other));

      // Undo
      await db.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
        removeReparentLinks: result.addedReparentLinks,
      );
      final deps = await db.getDependencies(parent);
      expect(deps.map((t) => t.id), contains(other));
    });
  });

  group('deleteTaskSubtree', () {
    test('deletes entire subtree', () async {
      // Root → Parent → Child
      final root = await db.insertTask(Task(name: 'Root'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(root, parent);
      await db.addRelationship(parent, child);

      final result = await db.deleteTaskSubtree(parent);

      // Both parent and child should be deleted
      expect(result.deletedTasks.map((t) => t.id).toSet(), {parent, child});
      expect(await db.getTaskById(parent), isNull);
      expect(await db.getTaskById(child), isNull);
      // Root should still exist
      expect(await db.getTaskById(root), isNotNull);
    });

    test('subtree undo restores all tasks and relationships', () async {
      final root = await db.insertTask(Task(name: 'Root'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(root, parent);
      await db.addRelationship(parent, child);

      final result = await db.deleteTaskSubtree(parent);

      // Restore
      await db.restoreTaskSubtree(
        tasks: result.deletedTasks,
        relationships: result.deletedRelationships,
        dependencies: result.deletedDependencies,
      );

      // Everything should be back
      expect(await db.getTaskById(parent), isNotNull);
      expect(await db.getTaskById(child), isNotNull);
      final rootChildren = await db.getChildren(root);
      expect(rootChildren.map((t) => t.id), contains(parent));
      final parentChildren = await db.getChildren(parent);
      expect(parentChildren.map((t) => t.id), contains(child));
    });

    test('subtree delete with external dependencies captures them', () async {
      final root = await db.insertTask(Task(name: 'Root'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      final external = await db.insertTask(Task(name: 'External'));
      await db.addRelationship(root, parent);
      await db.addRelationship(parent, child);
      await db.addDependency(child, external); // child depends on external

      final result = await db.deleteTaskSubtree(parent);

      expect(result.deletedDependencies, isNotEmpty);
      // External should not be deleted
      expect(await db.getTaskById(external), isNotNull);

      // Undo should restore the dependency
      await db.restoreTaskSubtree(
        tasks: result.deletedTasks,
        relationships: result.deletedRelationships,
        dependencies: result.deletedDependencies,
      );
      final deps = await db.getDependencies(child);
      expect(deps.map((t) => t.id), contains(external));
    });

    test('deep subtree with multiple levels', () async {
      // A → B → C → D
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      final c = await db.insertTask(Task(name: 'C'));
      final d = await db.insertTask(Task(name: 'D'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);
      await db.addRelationship(c, d);

      final result = await db.deleteTaskSubtree(b);

      expect(result.deletedTasks.map((t) => t.id).toSet(), {b, c, d});
      expect(await db.getTaskById(a), isNotNull);
      expect(await db.getTaskById(b), isNull);
      expect(await db.getTaskById(c), isNull);
      expect(await db.getTaskById(d), isNull);
    });
  });
}
