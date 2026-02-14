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

  group('pickRandom with dependencies', () {
    test('pickRandom skips blocked tasks', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a); // B depends on A (A not completed)

      await provider.loadRootTasks();
      expect(provider.tasks, hasLength(2));
      expect(provider.blockedTaskIds, contains(b));

      // pickRandom should only ever return A
      for (int i = 0; i < 20; i++) {
        final picked = provider.pickRandom();
        expect(picked, isNotNull);
        expect(picked!.id, a);
      }
    });

    test('pickRandom includes task after dependency resolved', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);

      await provider.loadRootTasks();
      expect(provider.blockedTaskIds, contains(b));

      // Complete A
      final taskA = provider.tasks.firstWhere((t) => t.id == a);
      await provider.navigateInto(taskA);
      await provider.completeTask(a);
      // Back at root now

      expect(provider.blockedTaskIds, isNot(contains(b)));
    });

    test('pickRandom returns null when all tasks are blocked', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(a, b);
      await db.addDependency(b, a); // circular, but both blocked

      // Manually add both — they're mutually dependent
      // Actually this won't be blocked unless deps are unresolved.
      // Let's create a simpler scenario: a 3rd task that both depend on
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.removeDependency(a, b);
      await db.removeDependency(b, a);
      await db.addDependency(a, c);
      await db.addDependency(b, c);

      // Remove C from root (it's still active, so A and B are blocked)
      // Actually C is also at root. Let's just test: if only blocked tasks remain
      // Create parent to contain A and B, with C elsewhere
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await db.addRelationship(parentId, a);
      await db.addRelationship(parentId, b);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // A and B are children of parent, both depend on C
      expect(provider.blockedTaskIds, containsAll([a, b]));
      expect(provider.pickRandom(), isNull);
    });
  });

  group('addDependency / removeDependency', () {
    test('addDependency succeeds for non-cyclic dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));

      await provider.loadRootTasks();
      final result = await provider.addDependency(b, a);
      expect(result, isTrue);
    });

    test('addDependency prevents self-dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));

      await provider.loadRootTasks();
      final result = await provider.addDependency(a, a);
      expect(result, isFalse);
    });

    test('addDependency prevents cyclic dependency', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a); // B depends on A

      await provider.loadRootTasks();
      // Try to make A depend on B (would create cycle)
      final result = await provider.addDependency(a, b);
      expect(result, isFalse);
    });

    test('removeDependency unblocks the task', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);

      await provider.loadRootTasks();
      expect(provider.blockedTaskIds, contains(b));

      await provider.removeDependency(b, a);
      expect(provider.blockedTaskIds, isNot(contains(b)));
    });

    test('getDependencies returns dependency list', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a);

      final deps = await provider.getDependencies(b);
      expect(deps, hasLength(1));
      expect(deps.first.id, a);
    });

    test('addDependency replaces existing dependency (single dep)', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));

      await provider.loadRootTasks();
      await provider.addDependency(c, a); // C depends on A
      var deps = await provider.getDependencies(c);
      expect(deps, hasLength(1));
      expect(deps.first.id, a);

      await provider.addDependency(c, b); // C now depends on B (replaces A)
      deps = await provider.getDependencies(c);
      expect(deps, hasLength(1));
      expect(deps.first.id, b);
    });

    test('blockedByNames contains dependency name', () async {
      final a = await db.insertTask(Task(name: 'First Task'));
      final b = await db.insertTask(Task(name: 'Second Task'));
      await db.addDependency(b, a);

      await provider.loadRootTasks();
      expect(provider.blockedByNames[b], 'First Task');
      expect(provider.blockedByNames.containsKey(a), isFalse);
    });

    test('siblings available for leaf task via getParentIds + getChildren', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childA = await db.insertTask(Task(name: 'Child A'));
      final childB = await db.insertTask(Task(name: 'Child B'));
      await db.addRelationship(parentId, childA);
      await db.addRelationship(parentId, childB);

      // Navigate to leaf (childA)
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childA);
      await provider.navigateInto(child);

      // On leaf view, provider.tasks is empty
      expect(provider.tasks, isEmpty);

      // But we can get siblings via parentIds + getChildren
      final parentIds = await provider.getParentIds(childA);
      expect(parentIds, contains(parentId));
      final siblings = await provider.getChildren(parentIds.first);
      final siblingIds = siblings.map((t) => t.id!).where((id) => id != childA).toSet();
      expect(siblingIds, contains(childB));
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
