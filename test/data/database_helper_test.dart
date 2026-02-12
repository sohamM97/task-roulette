import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';

void main() {
  late DatabaseHelper db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
}
