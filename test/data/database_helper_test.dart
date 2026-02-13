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

      final completed = await db.getCompletedTasks();
      final task = completed.firstWhere((t) => t.id == id);
      expect(task.startedAt, isNotNull);
      expect(task.isCompleted, isTrue);
      expect(task.isStarted, isFalse);
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
  });
}
