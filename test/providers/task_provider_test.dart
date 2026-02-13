import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/task_provider.dart';

void main() {
  late DatabaseHelper db;
  late TaskProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    db = DatabaseHelper();
    await db.reset();
    await db.database;
    provider = TaskProvider();
  });

  tearDown(() async {
    await db.reset();
  });

  group('completeTask', () {
    test('completes a leaf task viewed via navigateInto', () async {
      // Create parent → child (leaf)
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Leaf child'));
      await db.addRelationship(parentId, childId);

      // Navigate: root → parent → child (leaf, no children)
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      // Now at leaf: currentParent is the child, tasks list is empty
      expect(provider.currentParent!.id, childId);
      expect(provider.tasks, isEmpty);

      // Completing the leaf task (currentParent) should not throw
      final completed = await provider.completeTask(childId);
      expect(completed.id, childId);

      // Should have navigated back to parent level
      expect(provider.currentParent!.id, parentId);
    });

    test('completes a leaf task viewed via navigateToTask', () async {
      // Create a standalone leaf task
      final leafId = await db.insertTask(Task(name: 'Standalone leaf'));

      // Navigate directly to it (as DAG view does)
      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateToTask(leaf);

      expect(provider.currentParent!.id, leafId);
      expect(provider.tasks, isEmpty);

      // Should not throw
      final completed = await provider.completeTask(leafId);
      expect(completed.id, leafId);

      // Should have navigated back to root
      expect(provider.currentParent, isNull);
    });
  });

  group('startTask / unstartTask', () {
    test('startTask updates currentParent when on leaf', () async {
      final leafId = await db.insertTask(Task(name: 'Leaf'));

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      expect(provider.currentParent!.isStarted, isFalse);

      await provider.startTask(leafId);

      expect(provider.currentParent!.isStarted, isTrue);
      expect(provider.currentParent!.startedAt, isNotNull);
    });

    test('unstartTask updates currentParent when on leaf', () async {
      final leafId = await db.insertTask(Task(name: 'Leaf'));

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);
      await provider.startTask(leafId);

      expect(provider.currentParent!.isStarted, isTrue);

      await provider.unstartTask(leafId);

      expect(provider.currentParent!.isStarted, isFalse);
      expect(provider.currentParent!.startedAt, isNull);
    });

    test('startedDescendantIds contains parent when child is started', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);

      await provider.loadRootTasks();

      expect(provider.startedDescendantIds, contains(parentId));
    });

    test('startedDescendantIds clears when child is unstarted', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // Start the child via the provider (simulates leaf toggle)
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);
      await provider.startTask(childId);

      // Navigate back to parent level and check
      await provider.navigateBack();
      await provider.navigateBack();

      expect(provider.startedDescendantIds, contains(parentId));

      // Unstart
      await provider.navigateInto(parent);
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == childId));
      await provider.unstartTask(childId);
      await provider.navigateBack();
      await provider.navigateBack();

      expect(provider.startedDescendantIds, isNot(contains(parentId)));
    });

    test('completing a started task clears startedDescendantIds on parent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);

      await provider.loadRootTasks();
      expect(provider.startedDescendantIds, contains(parentId));

      // Complete the started child
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);
      await provider.completeTask(childId);

      // Should navigate back to parent level; go back to root
      await provider.navigateBack();

      expect(provider.startedDescendantIds, isNot(contains(parentId)));
    });
  });

  group('renameTask', () {
    test('updates currentParent name immediately on leaf view', () async {
      final leafId = await db.insertTask(Task(name: 'Old name'));

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      expect(provider.currentParent!.name, 'Old name');

      await provider.renameTask(leafId, 'New name');

      expect(provider.currentParent!.name, 'New name');
      expect(provider.currentParent!.id, leafId);
    });

    test('preserves other fields when renaming currentParent', () async {
      final leafId = await db.insertTask(Task(name: 'Task'));
      await db.startTask(leafId);

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      expect(provider.currentParent!.isStarted, isTrue);

      await provider.renameTask(leafId, 'Renamed');

      expect(provider.currentParent!.name, 'Renamed');
      expect(provider.currentParent!.isStarted, isTrue);
      expect(provider.currentParent!.startedAt, isNotNull);
    });

    test('does not affect currentParent when renaming a different task', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      expect(provider.currentParent!.name, 'Parent');

      await provider.renameTask(childId, 'Renamed child');

      // Parent name unchanged
      expect(provider.currentParent!.name, 'Parent');
      // Child renamed in tasks list
      expect(provider.tasks.firstWhere((t) => t.id == childId).name, 'Renamed child');
    });
  });
}
