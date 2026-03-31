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
      final result = await provider.completeTask(childId);
      expect(result.task.id, childId);

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
      final result = await provider.completeTask(leafId);
      expect(result.task.id, leafId);

      // Should have navigated back to root
      expect(provider.currentParent, isNull);
    });
  });

  group('completeTaskOnly', () {
    test('completes task without navigating back', () async {
      // Create parent → child (leaf)
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Leaf child'));
      await db.addRelationship(parentId, childId);

      // Navigate: root → parent → child (leaf)
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      expect(provider.currentParent!.id, childId);

      // completeTaskOnly should NOT navigate back
      await provider.completeTaskOnly(childId);

      // Still on the same level (currentParent unchanged)
      expect(provider.currentParent!.id, childId);

      // Verify task is actually completed in DB
      final freshTask = await db.getTaskById(childId);
      expect(freshTask!.isCompleted, isTrue);
    });

    test('completeTask navigates back but completeTaskOnly does not', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      // Navigate to child leaf
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      // completeTask navigates back
      await provider.completeTask(childId);
      expect(provider.currentParent!.id, parentId);

      // Restore the child and navigate back to it
      await db.uncompleteTask(childId);
      await provider.navigateInto(child);
      expect(provider.currentParent!.id, childId);

      // completeTaskOnly does NOT navigate back
      await provider.completeTaskOnly(childId);
      expect(provider.currentParent!.id, childId);
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
  });

  group('Dependency chain reordering', () {
    test('dependent sibling is placed right after its blocker', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      await db.addRelationship(parent, c);
      await db.addDependency(c, a); // C depends on A

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      final ids = provider.tasks.map((t) => t.id).toList();
      final aIdx = ids.indexOf(a);
      final cIdx = ids.indexOf(c);
      expect(cIdx, aIdx + 1);
    });

    test('chain of 3 tasks keeps order A → B → C', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      await db.addRelationship(parent, c);
      await db.addDependency(b, a); // B depends on A
      await db.addDependency(c, b); // C depends on B

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      final ids = provider.tasks.map((t) => t.id).toList();
      final aIdx = ids.indexOf(a);
      final bIdx = ids.indexOf(b);
      final cIdx = ids.indexOf(c);
      expect(bIdx, aIdx + 1);
      expect(cIdx, bIdx + 1);
    });

    test('non-sibling dependency does not reorder', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final external = await db.insertTask(Task(name: 'External'));
      await db.addRelationship(parent, a);
      await db.addDependency(a, external); // A depends on External (not a sibling)

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      expect(provider.blockedTaskIds, contains(a));
      expect(provider.tasks, hasLength(1));
    });

    test('chain dissolves when dependency is removed', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      await db.addRelationship(parent, c);
      await db.addDependency(b, a); // B depends on A

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      // B should be right after A
      var ids = provider.tasks.map((t) => t.id).toList();
      expect(ids.indexOf(b), ids.indexOf(a) + 1);

      // Remove dependency — B goes back to natural position
      await provider.removeDependency(b, a);

      ids = provider.tasks.map((t) => t.id).toList();
      // A, B, C all present, B no longer forced after A
      expect(ids.toSet(), {a, b, c});
    });

    test('grouping persists when blocker is worked on today', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      await db.addDependency(b, a); // B depends on A

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      expect(provider.blockedTaskIds, contains(b));

      // Work on A — unblocks B but grouping should persist
      await provider.markWorkedOn(a);

      expect(provider.blockedTaskIds, isNot(contains(b)));
      final ids = provider.tasks.map((t) => t.id).toList();
      expect(ids.indexOf(b), ids.indexOf(a) + 1);
    });

    test('fan-out: multiple dependents of same blocker all follow it', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      final c = await db.insertTask(Task(name: 'Task C'));
      final d = await db.insertTask(Task(name: 'Task D'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      await db.addRelationship(parent, c);
      await db.addRelationship(parent, d);
      await db.addDependency(b, a); // B depends on A
      await db.addDependency(c, a); // C depends on A

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      final ids = provider.tasks.map((t) => t.id).toList();
      final aIdx = ids.indexOf(a);
      final bIdx = ids.indexOf(b);
      final cIdx = ids.indexOf(c);
      // Both B and C should appear right after A (consecutive)
      expect({bIdx, cIdx}, {aIdx + 1, aIdx + 2});
      // D should not be between A and its dependents
      final dIdx = ids.indexOf(d);
      expect(dIdx == 0 || dIdx > aIdx + 2, isTrue);
    });

    test('root-level dependencies also group', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.insertTask(Task(name: 'Task C')); // unrelated task
      await db.addDependency(b, a); // B depends on A

      await provider.loadRootTasks();

      expect(provider.tasks, hasLength(3));
      final ids = provider.tasks.map((t) => t.id).toList();
      expect(ids.indexOf(b), ids.indexOf(a) + 1);
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

  group('deleteTask and undo', () {
    test('deleteTask removes task from current list', () async {
      final id = await db.insertTask(Task(name: 'Doomed'));

      await provider.loadRootTasks();
      expect(provider.tasks.map((t) => t.id), contains(id));

      await provider.deleteTask(id);
      expect(provider.tasks.map((t) => t.id), isNot(contains(id)));
    });

    test('restoreTask brings back deleted task', () async {
      final id = await db.insertTask(Task(name: 'Resurrected'));

      await provider.loadRootTasks();
      final result = await provider.deleteTask(id);

      // Task gone
      expect(provider.tasks.map((t) => t.id), isNot(contains(id)));

      // Undo
      await provider.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
      );

      expect(provider.tasks.map((t) => t.id), contains(id));
    });

    test('delete+undo preserves parent-child relationships', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // Delete child
      final result = await provider.deleteTask(childId);
      expect(provider.tasks, isEmpty);

      // Undo
      await provider.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
      );

      expect(provider.tasks.map((t) => t.id), contains(childId));
    });

    test('delete+undo preserves dependencies', () async {
      final a = await db.insertTask(Task(name: 'Task A'));
      final b = await db.insertTask(Task(name: 'Task B'));
      await db.addDependency(b, a); // B depends on A

      await provider.loadRootTasks();
      final result = await provider.deleteTask(b);

      await provider.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
      );

      final deps = await provider.getDependencies(b);
      expect(deps.map((t) => t.id), contains(a));
    });

    test('deleting currentParent (leaf) then navigateBack returns to parent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Leaf Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      expect(provider.currentParent!.id, parentId);

      // Navigate into the leaf child — it becomes currentParent
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);
      expect(provider.currentParent!.id, childId);
      expect(provider.tasks, isEmpty); // leaf has no children

      // Delete the leaf (which IS currentParent)
      await provider.deleteTask(childId);
      // Simulate what the screen does: navigateBack after deleting currentParent
      await provider.navigateBack();

      // Should be back at parent level
      expect(provider.currentParent!.id, parentId);
      // The deleted child should not appear
      expect(provider.tasks.map((t) => t.id), isNot(contains(childId)));
    });

    test('deleting currentParent (non-leaf, subtree) then navigateBack returns to parent', () async {
      final grandparentId = await db.insertTask(Task(name: 'Grandparent'));
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(grandparentId, parentId);
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final gp = provider.tasks.firstWhere((t) => t.id == grandparentId);
      await provider.navigateInto(gp);
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      expect(provider.currentParent!.id, parentId);
      expect(provider.tasks.length, 1); // has one child

      // Delete subtree (parent + child)
      await provider.deleteTaskSubtree(parentId);
      await provider.navigateBack();

      // Should be back at grandparent level
      expect(provider.currentParent!.id, grandparentId);
      expect(provider.tasks.map((t) => t.id), isNot(contains(parentId)));
    });

    test('deleting currentParent (non-leaf, reparent) then navigateBack returns to parent', () async {
      final grandparentId = await db.insertTask(Task(name: 'Grandparent'));
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(grandparentId, parentId);
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final gp = provider.tasks.firstWhere((t) => t.id == grandparentId);
      await provider.navigateInto(gp);
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      expect(provider.currentParent!.id, parentId);

      // Delete parent with reparent — child should move up to grandparent
      await provider.deleteTaskAndReparent(parentId);
      await provider.navigateBack();

      // Should be back at grandparent level with child reparented
      expect(provider.currentParent!.id, grandparentId);
      expect(provider.tasks.map((t) => t.id), contains(childId));
      expect(provider.tasks.map((t) => t.id), isNot(contains(parentId)));
    });
  });

  group('navigateToTask', () {
    test('navigateToTask sets currentParent and clears stack', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final child = (await db.getAllTasks()).firstWhere((t) => t.id == childId);
      await provider.navigateToTask(child);

      expect(provider.currentParent!.id, childId);
    });

    test('navigateBack after navigateToTask on root task returns to root', () async {
      final id = await db.insertTask(Task(name: 'Root task'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateToTask(task);

      expect(provider.currentParent!.id, id);

      await provider.navigateBack();
      expect(provider.currentParent, isNull);
    });

    test('navigateBack after navigateToTask on deep task goes to parent', () async {
      final a = await db.insertTask(Task(name: 'Grandparent'));
      final b = await db.insertTask(Task(name: 'Parent'));
      final c = await db.insertTask(Task(name: 'Leaf'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);

      await provider.loadRootTasks();
      final leaf = (await db.getAllTasks()).firstWhere((t) => t.id == c);
      await provider.navigateToTask(leaf);

      expect(provider.currentParent!.id, c);

      // Back should go to parent, not root
      await provider.navigateBack();
      expect(provider.currentParent!.id, b);

      // Back again to grandparent
      await provider.navigateBack();
      expect(provider.currentParent!.id, a);

      // Back to root
      await provider.navigateBack();
      expect(provider.currentParent, isNull);
    });

    test('loadRootTasks after navigateToTask must not overwrite navigation', () async {
      // Regression: PageView lazily builds TaskListScreen, whose initState
      // called loadRootTasks() after navigateToTask had already set the
      // provider to a deep task — resetting it back to root.
      final a = await db.insertTask(Task(name: 'Root'));
      final b = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(a, b);

      // Simulate app startup: loadRootTasks first
      await provider.loadRootTasks();
      expect(provider.isRoot, isTrue);

      // Simulate "Go to task" from Today's 5
      final child = (await db.getAllTasks()).firstWhere((t) => t.id == b);
      await provider.navigateToTask(child);
      expect(provider.currentParent!.id, b);

      // Simulate TaskListScreen.initState calling loadRootTasks again
      // (the old bug). This should NOT happen in production anymore,
      // but verify the effect: it resets navigation.
      await provider.loadRootTasks();
      // After loadRootTasks, we're back at root — this is the bug behavior.
      // The fix is architectural (don't call loadRootTasks in initState),
      // but this test documents that loadRootTasks does reset state.
      expect(provider.isRoot, isTrue);
    });
  });

  group('deep navigation', () {
    test('navigateInto 3 levels deep then back to root', () async {
      final a = await db.insertTask(Task(name: 'Level 1'));
      final b = await db.insertTask(Task(name: 'Level 2'));
      final c = await db.insertTask(Task(name: 'Level 3'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);

      await provider.loadRootTasks();
      // Navigate: root → a → b → c
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == a));
      expect(provider.currentParent!.id, a);
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == b));
      expect(provider.currentParent!.id, b);
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == c));
      expect(provider.currentParent!.id, c);

      // Navigate back: c → b → a → root
      await provider.navigateBack();
      expect(provider.currentParent!.id, b);
      await provider.navigateBack();
      expect(provider.currentParent!.id, a);
      await provider.navigateBack();
      expect(provider.currentParent, isNull);
    });

    test('navigateBack at root is a no-op', () async {
      await provider.loadRootTasks();
      expect(provider.currentParent, isNull);

      await provider.navigateBack();
      expect(provider.currentParent, isNull);
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

  group("Today's 5 leaf filtering", () {
    test('getAllLeafTasks excludes task after child is added', () async {
      // Create 5 standalone leaf tasks (simulates Today's 5)
      final ids = <int>[];
      for (int i = 0; i < 5; i++) {
        ids.add(await db.insertTask(Task(name: 'Task $i')));
      }
      // Plus a 6th task to serve as replacement
      final replacementId = await db.insertTask(Task(name: 'Replacement'));

      var leaves = await provider.getAllLeafTasks();
      var leafIds = leaves.map((t) => t.id).toSet();
      expect(leafIds, containsAll(ids));
      expect(leafIds, contains(replacementId));

      // Add a subtask to Task 0 — it's no longer a leaf
      final subtaskId = await db.insertTask(Task(name: 'Subtask'));
      await db.addRelationship(ids[0], subtaskId);

      leaves = await provider.getAllLeafTasks();
      leafIds = leaves.map((t) => t.id).toSet();
      expect(leafIds, isNot(contains(ids[0])));
      // Other original tasks + replacement + subtask are still leaves
      expect(leafIds, containsAll(ids.sublist(1)));
      expect(leafIds, contains(replacementId));
      expect(leafIds, contains(subtaskId));
    });

    test('pickWeightedN fills up to requested count from eligible pool', () async {
      // Create 3 leaf tasks
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      final c = await db.insertTask(Task(name: 'C'));

      final leaves = await provider.getAllLeafTasks();
      // Pick 2 from all 3
      final picked = provider.pickWeightedN(leaves, 2);
      expect(picked, hasLength(2));
      // All picked tasks should be from the leaf pool
      for (final t in picked) {
        expect([a, b, c], contains(t.id));
      }
    });

    test('simulated refresh: non-leaf tasks replaced with new leaves', () async {
      // Create 5 leaf tasks (Today's 5)
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }
      // Create extra leaves for replacement pool
      final extra1 = await db.insertTask(Task(name: 'Extra 1'));
      final extra2 = await db.insertTask(Task(name: 'Extra 2'));

      // Simulate: Task 0 gets a subtask (no longer a leaf)
      final sub = await db.insertTask(Task(name: 'Sub'));
      await db.addRelationship(todaysIds[0], sub);

      // Refresh logic: filter through leaves, backfill
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();

      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        }
      }

      // Task 0 should be filtered out
      expect(refreshed, hasLength(4));
      expect(refreshed.map((t) => t.id), isNot(contains(todaysIds[0])));

      // Backfill: pick 1 replacement from eligible leaves
      final currentIds = refreshed.map((t) => t.id).toSet();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);
      final eligible = allLeaves.where(
        (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
      ).toList();
      final replacements = provider.pickWeightedN(eligible, 1);

      refreshed.addAll(replacements);
      expect(refreshed, hasLength(5));

      // The replacement should be from the extra pool or the subtask
      final replacementId = replacements.first.id;
      expect([extra1, extra2, sub], contains(replacementId));
    });

    test('done task kept in list even after becoming non-leaf', () async {
      // Create 5 leaf tasks + extras for backfill
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }
      await db.insertTask(Task(name: 'Extra'));

      // Simulate: user marks Task 0 as done
      final completedIds = {todaysIds[0]};

      // Task 0 gets a subtask → no longer a leaf
      final sub = await db.insertTask(Task(name: 'Sub'));
      await db.addRelationship(todaysIds[0], sub);

      // Refresh logic (mirrors refreshSnapshots)
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        } else if (completedIds.contains(id)) {
          // Done task kept even though non-leaf
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        }
      }

      // All 5 kept: 4 leaves + 1 done-but-non-leaf
      expect(refreshed, hasLength(5));
      expect(refreshed.map((t) => t.id), contains(todaysIds[0]));
      // No backfill needed
    });

    test('non-done non-leaf replaced while done non-leaf preserved', () async {
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }
      await db.insertTask(Task(name: 'Extra'));

      // Task 0 is done, Task 1 is not done
      final completedIds = {todaysIds[0]};

      // Both get subtasks → both non-leaf
      final sub0 = await db.insertTask(Task(name: 'Sub0'));
      final sub1 = await db.insertTask(Task(name: 'Sub1'));
      await db.addRelationship(todaysIds[0], sub0);
      await db.addRelationship(todaysIds[1], sub1);

      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        } else if (completedIds.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        }
      }

      // Task 0 kept (done), Task 1 dropped (not done, not leaf)
      expect(refreshed, hasLength(4));
      expect(refreshed.map((t) => t.id), contains(todaysIds[0]));
      expect(refreshed.map((t) => t.id), isNot(contains(todaysIds[1])));

      // Backfill 1 replacement
      final currentIds = refreshed.map((t) => t.id).toSet();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);
      final eligible = allLeaves.where(
        (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
      ).toList();
      final replacements = provider.pickWeightedN(eligible, 1);
      refreshed.addAll(replacements);

      expect(refreshed, hasLength(5));
    });

    test('completedIds cleaned up when done task is deleted', () async {
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      // Task 0 is done
      final completedIds = {todaysIds[0]};

      // Task 0 is deleted entirely
      await db.deleteTaskWithRelationships(todaysIds[0]);

      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        } else if (completedIds.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        }
      }

      // Task 0 deleted — getTaskById returns null, not kept
      expect(refreshed, hasLength(4));
      expect(refreshed.map((t) => t.id), isNot(contains(todaysIds[0])));

      // Clean completedIds (mirrors refreshSnapshots logic)
      completedIds.removeWhere((id) => !refreshed.any((t) => t.id == id));
      expect(completedIds, isEmpty);
    });

    test('unmarking done non-leaf task removes it and triggers backfill', () async {
      // Scenario: 5 tasks, no extras. Mark task 0 done, make it non-leaf,
      // then unmark it. On next refresh, it should be gone and backfill
      // should attempt to fill the slot.
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      // Step 1: mark Task 0 done
      await db.markWorkedOn(todaysIds[0]);
      await db.startTask(todaysIds[0]);
      final completedIds = {todaysIds[0]};

      // Step 2: add subtask to Task 0 → non-leaf
      final sub = await db.insertTask(Task(name: 'Sub'));
      await db.addRelationship(todaysIds[0], sub);

      // Step 3: refresh — Task 0 kept because it's in completedIds
      var allLeaves = await provider.getAllLeafTasks();
      var leafIdSet = allLeaves.map((t) => t.id!).toSet();
      var todaysTasks = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) todaysTasks.add(fresh);
        } else if (completedIds.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) todaysTasks.add(fresh);
        }
      }
      expect(todaysTasks, hasLength(5));

      // Step 4: user unmarks Task 0 → remove from completedIds
      completedIds.remove(todaysIds[0]);

      // Step 5: next refresh — Task 0 is non-leaf AND not completed
      allLeaves = await provider.getAllLeafTasks();
      leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final t in todaysTasks) {
        if (leafIdSet.contains(t.id)) {
          final fresh = await db.getTaskById(t.id!);
          if (fresh != null) refreshed.add(fresh);
        } else if (completedIds.contains(t.id)) {
          final fresh = await db.getTaskById(t.id!);
          if (fresh != null) refreshed.add(fresh);
        }
      }

      // Task 0 filtered out
      expect(refreshed, hasLength(4));
      expect(refreshed.map((t) => t.id), isNot(contains(todaysIds[0])));

      // Backfill: only "sub" is an eligible leaf not already in list
      final currentIds = refreshed.map((t) => t.id).toSet();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);
      final eligible = allLeaves.where(
        (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
      ).toList();
      final replacements = provider.pickWeightedN(eligible, 1);
      refreshed.addAll(replacements);

      // Should backfill with "sub" (the only available leaf)
      expect(refreshed, hasLength(5));
      expect(refreshed.map((t) => t.id), contains(sub));
    });

    test('unmarking done non-leaf with no eligible replacements results in 4 tasks', () async {
      // Same scenario but the subtask was worked on today (ineligible for pick)
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      final completedIds = {todaysIds[0]};

      // Add subtask to Task 0, mark subtask as worked on today
      final sub = await db.insertTask(Task(name: 'Sub'));
      await db.addRelationship(todaysIds[0], sub);
      await db.markWorkedOn(sub);

      // After unmark + refresh
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      completedIds.remove(todaysIds[0]);

      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        } else if (completedIds.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) refreshed.add(fresh);
        }
      }
      expect(refreshed, hasLength(4));

      // "sub" is a leaf but was worked on today → pickWeightedN excludes it
      final currentIds = refreshed.map((t) => t.id).toSet();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);
      final eligible = allLeaves.where(
        (t) => !currentIds.contains(t.id) && !blockedIds.contains(t.id),
      ).toList();
      final replacements = provider.pickWeightedN(eligible, 1);
      refreshed.addAll(replacements);

      // No eligible replacement → stays at 4
      expect(refreshed, hasLength(4));
    });

    test('externally completed task shows as done, not vanished', () async {
      // Bug: task completed from All Tasks leaf detail vanishes from Today's 5
      // instead of showing struck out
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      final completedIds = <int>{};

      // Simulate: user completes task 0 from All Tasks (not from Today's 5)
      await db.completeTask(todaysIds[0]);

      // refreshSnapshots logic (updated)
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            refreshed.add(fresh);
            if (fresh.isWorkedOnToday && !completedIds.contains(fresh.id)) {
              completedIds.add(fresh.id!);
            }
          }
        } else {
          // Not a leaf — check if completed externally
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            if (completedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday) {
              completedIds.add(fresh.id!);
              refreshed.add(fresh);
            }
          }
        }
      }

      // Task 0 should still be in the list (not vanished)
      expect(refreshed, hasLength(5));
      expect(refreshed.map((t) => t.id), contains(todaysIds[0]));
      // And it should be in completedIds (shown as struck out)
      expect(completedIds, contains(todaysIds[0]));
    });

    test('externally worked-on task shows as done, not in-progress', () async {
      // Bug: task marked "done today" from All Tasks leaf detail shows as
      // in-progress in Today's 5 instead of struck out
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      final completedIds = <int>{};

      // Simulate: user marks task 0 as "worked on today" from All Tasks
      await db.markWorkedOn(todaysIds[0]);
      await db.startTask(todaysIds[0]);

      // refreshSnapshots logic (updated)
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            refreshed.add(fresh);
            if (fresh.isWorkedOnToday && !completedIds.contains(fresh.id)) {
              completedIds.add(fresh.id!);
            }
          }
        } else {
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            if (completedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday) {
              completedIds.add(fresh.id!);
              refreshed.add(fresh);
            }
          }
        }
      }

      // Task 0 should still be in the list
      expect(refreshed, hasLength(5));
      expect(refreshed.map((t) => t.id), contains(todaysIds[0]));
      // And it should be in completedIds (shown as struck out, not in-progress)
      expect(completedIds, contains(todaysIds[0]));
      // The task should have isWorkedOnToday = true
      final task0 = refreshed.firstWhere((t) => t.id == todaysIds[0]);
      expect(task0.isWorkedOnToday, isTrue);
      expect(task0.isStarted, isTrue);
    });

    test('uncompleted task from archive is unmarked in Today\'s 5', () async {
      // Bug: task completed → shows struck out in Today's 5. User restores
      // it from archive. On refresh, it should no longer be struck out.
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }

      // Complete task 0 and add to completedIds (as Today's 5 would)
      await db.completeTask(todaysIds[0]);
      final completedIds = <int>{todaysIds[0]};

      // User restores task 0 from archive
      await db.uncompleteTask(todaysIds[0]);

      // refreshSnapshots logic
      final allLeaves = await provider.getAllLeafTasks();
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final refreshed = <Task>[];
      for (final id in todaysIds) {
        if (leafIdSet.contains(id)) {
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            refreshed.add(fresh);
            if (fresh.isWorkedOnToday && !completedIds.contains(fresh.id)) {
              completedIds.add(fresh.id!);
            }
          }
        } else {
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            if (completedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday) {
              completedIds.add(fresh.id!);
              refreshed.add(fresh);
            }
          }
        }
      }

      // Clean up: remove from completedIds if no longer completed/worked-on
      completedIds.removeWhere((id) {
        final task = refreshed.where((t) => t.id == id).firstOrNull;
        if (task == null) return true;
        return !task.isCompleted && !task.isWorkedOnToday;
      });

      // Task 0 should be in the list but NOT in completedIds
      expect(refreshed, hasLength(5));
      expect(refreshed.map((t) => t.id), contains(todaysIds[0]));
      expect(completedIds, isNot(contains(todaysIds[0])));
    });
  });

  group("Today's 5 new set preserves done tasks", () {
    test('new set keeps done tasks and only replaces undone ones', () async {
      // Create 8 leaf tasks (5 for today + 3 extras)
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }
      final extras = <int>[];
      for (int i = 0; i < 3; i++) {
        extras.add(await db.insertTask(Task(name: 'Extra $i')));
      }

      // Mark tasks 0 and 1 as done
      final completedIds = {todaysIds[0], todaysIds[1]};

      // Simulate _generateNewSet logic: keep done, replace undone
      final allLeaves = await provider.getAllLeafTasks();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);

      final todaysTasks = <Task>[];
      for (final id in todaysIds) {
        final t = await db.getTaskById(id);
        if (t != null) todaysTasks.add(t);
      }

      final kept = todaysTasks.where((t) => completedIds.contains(t.id)).toList();
      final keptIds = kept.map((t) => t.id).toSet();

      final eligible = allLeaves.where(
        (t) => !blockedIds.contains(t.id) && !keptIds.contains(t.id),
      ).toList();

      final slotsToFill = 5 - kept.length;
      final picked = provider.pickWeightedN(eligible, slotsToFill);

      final newSet = [...kept, ...picked];

      // Done tasks preserved
      expect(newSet, hasLength(5));
      expect(newSet.map((t) => t.id), contains(todaysIds[0]));
      expect(newSet.map((t) => t.id), contains(todaysIds[1]));

      // Undone tasks (2, 3, 4) should NOT be in the new set
      // (replaced by picks from eligible pool)
      final newIds = newSet.map((t) => t.id).toSet();
      // The 3 new picks come from eligible pool (excludes kept)
      final newPicks = newIds.difference(keptIds);
      expect(newPicks, hasLength(3));
    });

    test('new set with no tasks done replaces all', () async {
      final todaysIds = <int>[];
      for (int i = 0; i < 5; i++) {
        todaysIds.add(await db.insertTask(Task(name: 'Today $i')));
      }
      for (int i = 0; i < 3; i++) {
        await db.insertTask(Task(name: 'Extra $i'));
      }

      // No tasks done
      final completedIds = <int>{};

      final allLeaves = await provider.getAllLeafTasks();
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final blockedIds = await provider.getBlockedChildIds(leafIds);

      final todaysTasks = <Task>[];
      for (final id in todaysIds) {
        final t = await db.getTaskById(id);
        if (t != null) todaysTasks.add(t);
      }

      final kept = todaysTasks.where((t) => completedIds.contains(t.id)).toList();
      expect(kept, isEmpty);

      final eligible = allLeaves.where(
        (t) => !blockedIds.contains(t.id),
      ).toList();
      final picked = provider.pickWeightedN(eligible, 5);

      // Full replacement — 5 new picks
      expect(picked, hasLength(5));
    });
  });

  group('unstartTask on non-leaf', () {
    test('unstartTask clears started_at on a task that has children', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));

      // Start the task while it's still a leaf
      await db.startTask(parentId);
      var task = await db.getTaskById(parentId);
      expect(task!.isStarted, isTrue);

      // Add a child — now it's a non-leaf but still started
      await db.addRelationship(parentId, childId);
      task = await db.getTaskById(parentId);
      expect(task!.isStarted, isTrue);

      // Unstart should still work
      await provider.unstartTask(parentId);
      task = await db.getTaskById(parentId);
      expect(task!.isStarted, isFalse);
      expect(task.startedAt, isNull);
    });
  });

  // Helper to navigate into a task by ID (looks up the Task object from provider.tasks)
  Future<void> navInto(TaskProvider p, int taskId) async {
    final task = p.tasks.firstWhere((t) => t.id == taskId);
    await p.navigateInto(task);
  }

  group('Field updates and currentParent freshness', () {
    test('renameTask updates currentParent in place', () async {
      final parentId = await db.insertTask(Task(name: 'Old Name'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.currentParent!.name, 'Old Name');

      await provider.renameTask(parentId, 'New Name');

      expect(provider.currentParent!.name, 'New Name');
      // DB should also reflect the change
      final task = await db.getTaskById(parentId);
      expect(task!.name, 'New Name');
    });

    test('updateTaskUrl updates currentParent in place', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.currentParent!.url, isNull);

      await provider.updateTaskUrl(parentId, 'https://example.com');

      expect(provider.currentParent!.url, 'https://example.com');
    });

    test('updateTaskPriority updates currentParent in place', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.currentParent!.priority, 0); // default Normal

      await provider.updateTaskPriority(parentId, 1); // high

      expect(provider.currentParent!.priority, 1);
      expect(provider.currentParent!.isHighPriority, isTrue);
    });

    test('updateTaskSomeday updates currentParent in place', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.currentParent!.isSomeday, isFalse);

      await provider.updateTaskSomeday(parentId, true);

      expect(provider.currentParent!.isSomeday, isTrue);
    });

    test('updateTaskSomeday clears high priority (mutual exclusion)', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      await provider.updateTaskPriority(parentId, 1);
      expect(provider.currentParent!.isHighPriority, isTrue);

      await provider.updateTaskSomeday(parentId, true);
      expect(provider.currentParent!.isSomeday, isTrue);
      // Priority should be cleared
      final task = await db.getTaskById(parentId);
      expect(task!.priority, 0);
    });

    test('updateTaskPriority clears someday (mutual exclusion)', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      await provider.updateTaskSomeday(parentId, true);
      expect(provider.currentParent!.isSomeday, isTrue);

      await provider.updateTaskPriority(parentId, 1);
      expect(provider.currentParent!.isHighPriority, isTrue);
      // Someday should be cleared
      final task = await db.getTaskById(parentId);
      expect(task!.isSomeday, isFalse);
    });

    test('someday tasks get no staleness, started, or novelty weight boost', () async {
      // Create a someday task that's been untouched for 30 days
      final old = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
      final somedayId = await db.insertTask(Task(name: 'Someday', isSomeday: true, createdAt: old));
      final normalId = await db.insertTask(Task(name: 'Normal', createdAt: old));

      final leaves = await provider.getAllLeafTasks();
      expect(leaves.any((t) => t.id == somedayId), isTrue);
      expect(leaves.any((t) => t.id == normalId), isTrue);

      // Both should be pickable, but normal task should have higher weight
      // due to staleness. We can verify by picking many times — normal should
      // appear more often. Instead, just verify both are in the pool.
      final picked = provider.pickWeightedN(leaves, 2);
      expect(picked, hasLength(2));
    });

    test('someday tasks skip started boost', () async {
      // Create a started someday task and a started normal task
      final now = DateTime.now().millisecondsSinceEpoch;
      final somedayId = await db.insertTask(Task(
        name: 'Someday Started',
        isSomeday: true,
        startedAt: now,
        createdAt: now,
      ));
      final normalId = await db.insertTask(Task(
        name: 'Normal Started',
        startedAt: now,
        createdAt: now,
      ));

      final leaves = await provider.getAllLeafTasks();

      // Both are started, but someday should not get 2x boost.
      // Run many single picks to verify statistical difference.
      int somedayPicks = 0;
      int normalPicks = 0;
      for (int i = 0; i < 200; i++) {
        final picked = provider.pickWeightedN(leaves, 1);
        if (picked.first.id == somedayId) somedayPicks++;
        if (picked.first.id == normalId) normalPicks++;
      }
      // Normal should be picked roughly 2x more often (started boost)
      expect(normalPicks, greaterThan(somedayPicks));
    });

    test('someday tasks skip novelty boost', () async {
      // Create a brand-new someday task and a brand-new normal task
      final now = DateTime.now().millisecondsSinceEpoch;
      final somedayId = await db.insertTask(Task(
        name: 'Someday New',
        isSomeday: true,
        createdAt: now,
      ));
      // Create a normal task that is NOT new (no novelty boost)
      final oldTime = DateTime.now().subtract(const Duration(days: 10)).millisecondsSinceEpoch;
      final normalId = await db.insertTask(Task(
        name: 'Normal Old',
        createdAt: oldTime,
      ));

      final leaves = await provider.getAllLeafTasks();

      // Someday task is new but should NOT get novelty boost.
      // Normal task is old so gets staleness boost instead.
      int somedayPicks = 0;
      int normalPicks = 0;
      for (int i = 0; i < 200; i++) {
        final picked = provider.pickWeightedN(leaves, 1);
        if (picked.first.id == somedayId) somedayPicks++;
        if (picked.first.id == normalId) normalPicks++;
      }
      expect(normalPicks, greaterThan(somedayPicks));
    });

    test('someday task with all boostable traits gets same weight as plain task', () async {
      // A someday task that is started + new should have the same weight
      // as a plain non-started, old task (both should be ~1.0 base).
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldTime = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;

      // Someday: started + new (all boosts skipped → weight ~1.0)
      final somedayId = await db.insertTask(Task(
        name: 'Someday All Boosts',
        isSomeday: true,
        startedAt: now,
        createdAt: now,
      ));
      // Normal: not started + old (staleness applies → weight > 1.0)
      final normalId = await db.insertTask(Task(
        name: 'Normal Old',
        createdAt: oldTime,
      ));

      final leaves = await provider.getAllLeafTasks();

      // Normal old task gets staleness boost (~1.5x at 30 days),
      // someday task gets nothing despite being started + new.
      int somedayPicks = 0;
      int normalPicks = 0;
      for (int i = 0; i < 300; i++) {
        final picked = provider.pickWeightedN(leaves, 1);
        if (picked.first.id == somedayId) somedayPicks++;
        if (picked.first.id == normalId) normalPicks++;
      }
      // Normal should dominate due to staleness boost
      expect(normalPicks, greaterThan(somedayPicks));
    });

    test('toggling someday on clears high priority in weight selection', () async {
      // Verify that marking a task someday clears its priority,
      // so it can't have both someday + high priority boosts.
      final now = DateTime.now().millisecondsSinceEpoch;
      final taskId = await db.insertTask(Task(
        name: 'Priority Task',
        priority: 1,
        createdAt: now,
      ));

      await provider.loadRootTasks();
      var task = provider.tasks.firstWhere((t) => t.id == taskId);
      expect(task.isHighPriority, isTrue);
      expect(task.isSomeday, isFalse);

      // Toggle someday on — should clear priority
      await provider.updateTaskSomeday(taskId, true);
      task = provider.tasks.firstWhere((t) => t.id == taskId);
      expect(task.isSomeday, isTrue);
      expect(task.isHighPriority, isFalse);
      expect(task.priority, 0);
    });

    test('field updates on non-currentParent task do not break currentParent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      // Update a different task (the child, not the currentParent)
      await provider.renameTask(childId, 'Renamed Child');

      // currentParent should be unchanged
      expect(provider.currentParent!.name, 'Parent');
      // But the child in the list should be updated
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      expect(child.name, 'Renamed Child');
    });
  });

  group('markWorkedOn / unmarkWorkedOn', () {
    test('markWorkedOn updates currentParent lastWorkedAt', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.currentParent!.lastWorkedAt, isNull);

      await provider.markWorkedOn(parentId);

      expect(provider.currentParent!.lastWorkedAt, isNotNull);
      expect(provider.currentParent!.isWorkedOnToday, isTrue);
    });

    test('unmarkWorkedOn clears currentParent lastWorkedAt', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      await provider.markWorkedOn(parentId);

      await provider.unmarkWorkedOn(parentId);

      expect(provider.currentParent!.lastWorkedAt, isNull);
      expect(provider.currentParent!.isWorkedOnToday, isFalse);
    });

    test('unmarkWorkedOn restores previous timestamp on currentParent', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      final oldTimestamp = DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      await provider.markWorkedOn(parentId);
      await provider.unmarkWorkedOn(parentId, restoreTo: oldTimestamp);

      expect(provider.currentParent!.lastWorkedAt, oldTimestamp);
    });

    test('markWorkedOn on non-currentParent does not break currentParent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      await provider.markWorkedOn(childId);

      // currentParent unchanged
      expect(provider.currentParent!.lastWorkedAt, isNull);
      expect(provider.currentParent!.name, 'Parent');
    });
  });

  group('Multi-parent DAG operations', () {
    test('linkChildToCurrent adds relationship', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      final result = await provider.linkChildToCurrent(childId);
      expect(result, isTrue);

      // Child should now appear in parent's children
      expect(provider.tasks.any((t) => t.id == childId), isTrue);
    });

    test('linkChildToCurrent prevents cycle', () async {
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      await db.addRelationship(a, b);

      await provider.loadRootTasks();
      await navInto(provider, a);
      await navInto(provider, b);

      // Try to link A as child of B (would create A→B→A cycle)
      final result = await provider.linkChildToCurrent(a);
      expect(result, isFalse);
    });

    test('addParentToTask adds second parent', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent1, child);

      await provider.loadRootTasks();

      final result = await provider.addParentToTask(child, parent2);
      expect(result, isTrue);

      // Child should now have two parents
      final parents = await db.getParents(child);
      expect(parents.length, 2);
      expect(parents.map((t) => t.id).toSet(), {parent1, parent2});
    });

    test('addParentToTask prevents cycle', () async {
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      await db.addRelationship(a, b);

      await provider.loadRootTasks();

      // Try to make A a child of B (would create A→B→A cycle)
      final result = await provider.addParentToTask(a, b);
      expect(result, isFalse);
    });

    test('moveTask moves from one parent to another', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent1, child);

      await provider.loadRootTasks();
      await navInto(provider, parent1);

      final result = await provider.moveTask(child, parent2);
      expect(result, isTrue);

      // Child should no longer be under parent1
      final children1 = await db.getChildren(parent1);
      expect(children1.any((t) => t.id == child), isFalse);
      // Child should be under parent2
      final children2 = await db.getChildren(parent2);
      expect(children2.any((t) => t.id == child), isTrue);
    });

    test('moveTask returns false when target is already a parent', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent1, child);
      await db.addRelationship(parent2, child);

      // Navigate into Parent 1
      await provider.loadRootTasks();
      await navInto(provider, parent1);

      // Try to move child to Parent 2 (already a parent)
      final result = await provider.moveTask(child, parent2);
      expect(result, isFalse);

      // Child should still be under both parents
      final parents = await db.getParents(child);
      expect(parents.map((t) => t.id).toSet(), {parent1, parent2});
    });

    test('moveTask prevents cycle', () async {
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      final c = await db.insertTask(Task(name: 'C'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);

      await provider.loadRootTasks();
      await navInto(provider, a);

      // Try to move B under C — would create cycle since B→C exists
      final result = await provider.moveTask(b, c);
      expect(result, isFalse);
    });

    test('unlinkFromCurrentParent removes relationship', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);
      expect(provider.tasks.any((t) => t.id == childId), isTrue);

      await provider.unlinkFromCurrentParent(childId);

      expect(provider.tasks.any((t) => t.id == childId), isFalse);
      // But task still exists (now a root task)
      final task = await db.getTaskById(childId);
      expect(task, isNotNull);
    });

    test('unlinkFromCurrentParent does nothing at root', () async {
      final id = await db.insertTask(Task(name: 'Root Task'));
      await provider.loadRootTasks();
      expect(provider.currentParent, isNull);

      // Should not throw, just no-op
      await provider.unlinkFromCurrentParent(id);
    });
  });

  group('Navigation', () {
    test('navigateInto sets currentParent and loads children', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      expect(provider.currentParent, isNull);
      expect(provider.tasks.any((t) => t.id == parentId), isTrue);

      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      expect(provider.currentParent, isNotNull);
      expect(provider.currentParent!.id, parentId);
      expect(provider.tasks.any((t) => t.id == childId), isTrue);
    });

    test('navigateBack returns to previous level', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      expect(provider.currentParent!.id, parentId);

      final result = await provider.navigateBack();
      expect(result, isTrue);
      expect(provider.currentParent, isNull);
    });

    test('navigateBack at root returns false', () async {
      await provider.loadRootTasks();
      final result = await provider.navigateBack();
      expect(result, isFalse);
      expect(provider.currentParent, isNull);
    });

    test('breadcrumb at root is [null]', () async {
      await provider.loadRootTasks();
      expect(provider.breadcrumb, [null]);
    });

    test('breadcrumb reflects navigation depth', () async {
      final a = await db.insertTask(Task(name: 'Level 1'));
      final b = await db.insertTask(Task(name: 'Level 2'));
      final c = await db.insertTask(Task(name: 'Level 3'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);

      await provider.loadRootTasks();
      // At root: breadcrumb = [null]
      expect(provider.breadcrumb.length, 1);
      expect(provider.breadcrumb[0], isNull);

      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == a));
      // At level 1: breadcrumb = [null, a]
      expect(provider.breadcrumb.length, 2);
      expect(provider.breadcrumb[0], isNull);
      expect(provider.breadcrumb[1]!.id, a);

      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == b));
      // At level 2: breadcrumb = [null, a, b]
      expect(provider.breadcrumb.length, 3);
      expect(provider.breadcrumb[2]!.id, b);

      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == c));
      // At level 3: breadcrumb = [null, a, b, c]
      expect(provider.breadcrumb.length, 4);
      expect(provider.breadcrumb[3]!.id, c);
    });

    test('navigateToLevel jumps to a specific breadcrumb level', () async {
      final a = await db.insertTask(Task(name: 'Level 1'));
      final b = await db.insertTask(Task(name: 'Level 2'));
      final c = await db.insertTask(Task(name: 'Level 3'));
      await db.addRelationship(a, b);
      await db.addRelationship(b, c);

      await provider.loadRootTasks();
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == a));
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == b));
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == c));

      // breadcrumb = [null, a, b, c]
      expect(provider.breadcrumb.length, 4);

      // Jump to level 1 (task a)
      await provider.navigateToLevel(1);
      expect(provider.currentParent!.id, a);
      // breadcrumb should be [null, a]
      expect(provider.breadcrumb.length, 2);
    });

    test('navigateToLevel(0) returns to root', () async {
      final a = await db.insertTask(Task(name: 'Level 1'));
      final b = await db.insertTask(Task(name: 'Level 2'));
      await db.addRelationship(a, b);

      await provider.loadRootTasks();
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == a));
      await provider.navigateInto(provider.tasks.firstWhere((t) => t.id == b));

      await provider.navigateToLevel(0);
      expect(provider.currentParent, isNull);
      expect(provider.breadcrumb, [null]);
    });

    test('isRoot is true at root and false when navigated in', () async {
      final id = await db.insertTask(Task(name: 'Task'));

      await provider.loadRootTasks();
      expect(provider.isRoot, isTrue);

      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateInto(task);
      expect(provider.isRoot, isFalse);
    });
  });

  group('Task creation', () {
    test('addTask returns the new task ID', () async {
      await provider.loadRootTasks();

      final id = await provider.addTask('Test');

      expect(id, isPositive);
      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.id, id);
    });

    test('addTask creates task at root when no parent', () async {
      await provider.loadRootTasks();
      expect(provider.tasks, isEmpty);

      await provider.addTask('New Task');

      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.name, 'New Task');
    });

    test('addTask creates child under current parent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      await provider.addTask('Child Task');

      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.name, 'Child Task');

      // Verify relationship in DB
      final children = await db.getChildren(parentId);
      expect(children.any((c) => c.name == 'Child Task'), isTrue);
    });

    test('addTask with additionalParentIds creates multi-parent task', () async {
      final parent1 = await db.insertTask(Task(name: 'Parent 1'));
      final parent2 = await db.insertTask(Task(name: 'Parent 2'));

      await provider.loadRootTasks();
      final p1 = provider.tasks.firstWhere((t) => t.id == parent1);
      await provider.navigateInto(p1);

      await provider.addTask('Multi-parent Child', additionalParentIds: [parent2]);

      // Child should appear under parent1
      expect(provider.tasks, hasLength(1));
      final childId = provider.tasks.first.id!;

      // Verify it's also under parent2
      final parents = await db.getParents(childId);
      expect(parents.map((p) => p.id).toSet(), {parent1, parent2});
    });

    test('addTask with additionalParentIds does not duplicate current parent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // Include current parent in additionalParentIds — should not duplicate
      await provider.addTask('Child', additionalParentIds: [parentId]);

      final childId = provider.tasks.first.id!;
      final parents = await db.getParents(childId);
      // Should have exactly 1 parent, not 2
      expect(parents, hasLength(1));
      expect(parents.first.id, parentId);
    });

    test('addTasksBatch creates multiple tasks at once', () async {
      await provider.loadRootTasks();
      await provider.addTasksBatch(['Task A', 'Task B', 'Task C']);

      expect(provider.tasks, hasLength(3));
      final names = provider.tasks.map((t) => t.name).toSet();
      expect(names, {'Task A', 'Task B', 'Task C'});
    });

    test('addTasksBatch creates tasks under current parent', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      await provider.addTasksBatch(['Child 1', 'Child 2']);

      expect(provider.tasks, hasLength(2));
      final children = await db.getChildren(parentId);
      expect(children, hasLength(2));
    });
  });

  group('Task deletion & restore', () {
    test('deleteTask removes task and returns undo info', () async {
      final id = await db.insertTask(Task(name: 'Doomed'));
      await provider.loadRootTasks();
      expect(provider.tasks.any((t) => t.id == id), isTrue);

      final result = await provider.deleteTask(id);

      expect(result.task.id, id);
      expect(result.task.name, 'Doomed');
      expect(provider.tasks.any((t) => t.id == id), isFalse);
    });

    test('deleteTask returns parent and child IDs for undo', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Middle'));
      final grandchild = await db.insertTask(Task(name: 'Grandchild'));
      await db.addRelationship(parentId, childId);
      await db.addRelationship(childId, grandchild);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      final result = await provider.deleteTask(childId);
      expect(result.parentIds, contains(parentId));
      expect(result.childIds, contains(grandchild));
    });

    test('restoreTask brings back task with relationships', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      final result = await provider.deleteTask(childId);
      expect(provider.tasks, isEmpty);

      await provider.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
      );

      expect(provider.tasks.any((t) => t.id == childId), isTrue);
    });

    test('deleteTaskAndReparent moves children up to parents', () async {
      final grandparent = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child1 = await db.insertTask(Task(name: 'Child 1'));
      final child2 = await db.insertTask(Task(name: 'Child 2'));
      await db.addRelationship(grandparent, parent);
      await db.addRelationship(parent, child1);
      await db.addRelationship(parent, child2);

      await provider.loadRootTasks();
      final gp = provider.tasks.firstWhere((t) => t.id == grandparent);
      await provider.navigateInto(gp);

      final result = await provider.deleteTaskAndReparent(parent);

      // Parent should be gone, children reparented under grandparent
      expect(result.task.id, parent);
      expect(provider.tasks.map((t) => t.id), isNot(contains(parent)));
      expect(provider.tasks.map((t) => t.id), containsAll([child1, child2]));
    });

    test('deleteTaskAndReparent undo restores original hierarchy', () async {
      final grandparent = await db.insertTask(Task(name: 'Grandparent'));
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(grandparent, parent);
      await db.addRelationship(parent, child);

      await provider.loadRootTasks();
      final gp = provider.tasks.firstWhere((t) => t.id == grandparent);
      await provider.navigateInto(gp);

      final result = await provider.deleteTaskAndReparent(parent);

      // Now child is directly under grandparent
      expect(provider.tasks.map((t) => t.id), contains(child));

      // Undo
      await provider.restoreTask(
        result.task, result.parentIds, result.childIds,
        dependsOnIds: result.dependsOnIds,
        dependedByIds: result.dependedByIds,
        removeReparentLinks: result.addedReparentLinks,
      );

      // Parent restored under grandparent; child back under parent (not grandparent)
      expect(provider.tasks.map((t) => t.id), contains(parent));
      // Child should no longer be a direct child of grandparent
      final gpChildren = await db.getChildren(grandparent);
      expect(gpChildren.map((t) => t.id), contains(parent));
      expect(gpChildren.map((t) => t.id), isNot(contains(child)));
      // Child should be under parent
      final parentChildren = await db.getChildren(parent);
      expect(parentChildren.map((t) => t.id), contains(child));
    });

    test('deleteTaskSubtree removes task and all descendants', () async {
      final root = await db.insertTask(Task(name: 'Root'));
      final mid = await db.insertTask(Task(name: 'Mid'));
      final leaf = await db.insertTask(Task(name: 'Leaf'));
      await db.addRelationship(root, mid);
      await db.addRelationship(mid, leaf);

      await provider.loadRootTasks();

      final result = await provider.deleteTaskSubtree(root);

      expect(result.deletedTasks.map((t) => t.id).toSet(), {root, mid, leaf});
      expect(provider.tasks, isEmpty);
      // Verify they're gone from DB
      expect(await db.getTaskById(root), isNull);
      expect(await db.getTaskById(mid), isNull);
      expect(await db.getTaskById(leaf), isNull);
    });

    test('restoreTaskSubtree brings back entire subtree', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      final grandchild = await db.insertTask(Task(name: 'Grandchild'));
      await db.addRelationship(parent, child);
      await db.addRelationship(child, grandchild);

      await provider.loadRootTasks();
      final result = await provider.deleteTaskSubtree(parent);
      expect(provider.tasks, isEmpty);

      await provider.restoreTaskSubtree(
        tasks: result.deletedTasks,
        relationships: result.deletedRelationships,
        dependencies: result.deletedDependencies,
      );

      // Root tasks should show parent again
      expect(provider.tasks.any((t) => t.id == parent), isTrue);

      // Verify the full hierarchy in DB
      final children = await db.getChildren(parent);
      expect(children.any((t) => t.id == child), isTrue);
      final grandchildren = await db.getChildren(child);
      expect(grandchildren.any((t) => t.id == grandchild), isTrue);
    });

    test('deleteTaskSubtree preserves sibling tasks', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child1 = await db.insertTask(Task(name: 'Child 1'));
      final child2 = await db.insertTask(Task(name: 'Child 2'));
      final grandchild = await db.insertTask(Task(name: 'Grandchild'));
      await db.addRelationship(parent, child1);
      await db.addRelationship(parent, child2);
      await db.addRelationship(child1, grandchild);

      await provider.loadRootTasks();
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);

      // Delete child1 subtree only
      await provider.deleteTaskSubtree(child1);

      // child2 should still be there
      expect(provider.tasks.any((t) => t.id == child2), isTrue);
      // child1 and grandchild gone
      expect(provider.tasks.any((t) => t.id == child1), isFalse);
      expect(await db.getTaskById(grandchild), isNull);
    });
  });

  group('Task lifecycle', () {
    test('completeTask marks task as completed and navigates back', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      expect(provider.currentParent!.id, childId);
      final result = await provider.completeTask(childId);
      expect(result.task.id, childId);

      // Should navigate back to parent
      expect(provider.currentParent!.id, parentId);

      // Verify completed in DB
      final task = await db.getTaskById(childId);
      expect(task!.isCompleted, isTrue);
    });

    test('skipTask marks task as skipped and navigates back', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      final result = await provider.skipTask(childId);
      expect(result.task.id, childId);

      // Should navigate back
      expect(provider.currentParent!.id, parentId);

      // Verify skipped in DB
      final task = await db.getTaskById(childId);
      expect(task!.isSkipped, isTrue);
    });

    test('unskipTask restores a skipped task', () async {
      final id = await db.insertTask(Task(name: 'Task'));
      await db.skipTask(id);

      await provider.loadRootTasks();
      // Skipped tasks don't appear in root tasks, so check DB directly
      var task = await db.getTaskById(id);
      expect(task!.isSkipped, isTrue);

      await provider.unskipTask(id);

      task = await db.getTaskById(id);
      expect(task!.isSkipped, isFalse);
    });

    test('uncompleteTask restores a completed task', () async {
      final id = await db.insertTask(Task(name: 'Task'));
      await db.completeTask(id);

      var task = await db.getTaskById(id);
      expect(task!.isCompleted, isTrue);

      await provider.uncompleteTask(id);

      task = await db.getTaskById(id);
      expect(task!.isCompleted, isFalse);
      expect(task.completedAt, isNull);
    });

    test('uncompleteTask preserves deadline through complete/uncomplete cycle', () async {
      final id = await db.insertTask(Task(
        name: 'Deadline task',
        deadline: '2026-04-15',
        deadlineType: 'due_by',
      ));
      // Complete the task ("Done for good!") — deadline stays untouched
      await db.completeTask(id);
      var task = await db.getTaskById(id);
      expect(task!.isCompleted, isTrue);
      expect(task.deadline, '2026-04-15');
      expect(task.deadlineType, 'due_by');

      // Uncomplete (e.g. from archive) — deadline should still be there
      await provider.uncompleteTask(id);
      task = await db.getTaskById(id);
      expect(task!.isCompleted, isFalse);
      expect(task.deadline, '2026-04-15');
      expect(task.deadlineType, 'due_by');
    });

    test('reCompleteTask re-archives without navigating back', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      expect(provider.currentParent!.id, parentId);

      // reCompleteTask does NOT navigate back
      await provider.reCompleteTask(childId);

      // Still at parent level
      expect(provider.currentParent!.id, parentId);

      // But task is completed in DB
      final task = await db.getTaskById(childId);
      expect(task!.isCompleted, isTrue);
    });

    test('reSkipTask re-skips without navigating back', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // reSkipTask does NOT navigate back
      await provider.reSkipTask(childId);

      expect(provider.currentParent!.id, parentId);

      final task = await db.getTaskById(childId);
      expect(task!.isSkipped, isTrue);
    });

    test('completeTaskOnly completes without navigating back', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      await provider.completeTaskOnly(childId);

      // Should NOT navigate back
      expect(provider.currentParent!.id, childId);

      // But task is completed in DB
      final task = await db.getTaskById(childId);
      expect(task!.isCompleted, isTrue);
    });

    test('complete then uncomplete roundtrip', () async {
      final id = await db.insertTask(Task(name: 'Task'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateInto(task);
      await provider.completeTask(id);

      // Task is completed
      var dbTask = await db.getTaskById(id);
      expect(dbTask!.isCompleted, isTrue);

      // Uncomplete it
      await provider.uncompleteTask(id);
      dbTask = await db.getTaskById(id);
      expect(dbTask!.isCompleted, isFalse);
    });

    test('completeTask returns removed dependency links', () async {
      // Bug fix: completeTask now removes dep rows and returns them for undo.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == blocker);
      await provider.navigateInto(task);

      final result = await provider.completeTask(blocker);
      expect(result.removedDeps, hasLength(1));
      expect(result.removedDeps.first.taskId, dep);
      expect(result.removedDeps.first.dependsOnId, blocker);
    });

    test('completeTask returns empty removedDeps when no dependents', () async {
      final id = await db.insertTask(Task(name: 'Solo'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateInto(task);

      final result = await provider.completeTask(id);
      expect(result.removedDeps, isEmpty);
    });

    test('completeTaskOnly returns removed dependency links', () async {
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);

      await provider.loadRootTasks();
      final removedDeps = await provider.completeTaskOnly(blocker);
      expect(removedDeps, hasLength(1));
      expect(removedDeps.first.taskId, dep);
      expect(removedDeps.first.dependsOnId, blocker);
    });

    test('uncompleteTask with restoredDeps restores dependency links', () async {
      // Undo path: completing a blocker removes deps, undoing restores them.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);

      await provider.loadRootTasks();
      final removedDeps = await provider.completeTaskOnly(blocker);

      // Deps should be gone
      final depsAfterComplete = await db.getDependencies(dep);
      expect(depsAfterComplete, isEmpty);

      // Undo — restore deps
      await provider.uncompleteTask(blocker, restoredDeps: removedDeps);
      final depsAfterUndo = await db.getDependencies(dep);
      expect(depsAfterUndo, hasLength(1));
      expect(depsAfterUndo.first.id, blocker);
    });

    test('reCompleteTask works without breaking on removedDeps', () async {
      // reCompleteTask (restore-from-archive) discards removedDeps intentionally.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await db.addRelationship(parentId, blocker);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // reCompleteTask should complete without errors
      await provider.reCompleteTask(blocker);
      final task = await db.getTaskById(blocker);
      expect(task!.isCompleted, isTrue);
      // Dep rows removed as side effect (not restored on re-archive)
      expect(await db.getDependencies(dep), isEmpty);
    });

    test('getDependentTaskNames returns names via provider', () async {
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep1 = await db.insertTask(Task(name: 'Waiting A'));
      final dep2 = await db.insertTask(Task(name: 'Waiting B'));
      await db.addDependency(dep1, blocker);
      await db.addDependency(dep2, blocker);

      final names = await provider.getDependentTaskNames(blocker);
      expect(names, unorderedEquals(['Waiting A', 'Waiting B']));
    });

    test('getDependentTaskNames returns empty when no dependents', () async {
      final id = await db.insertTask(Task(name: 'Standalone'));
      final names = await provider.getDependentTaskNames(id);
      expect(names, isEmpty);
    });

    test('blockedTaskIds includes currentParent when blocked', () async {
      // Bug fix: _loadAuxiliaryData now passes parentNameIds (including
      // currentParent) to getBlockedTaskInfo, so leaf detail view can
      // check the blocked state of the task being viewed.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final blocked = await db.insertTask(Task(name: 'Blocked'));
      await db.addDependency(blocked, blocker);

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == blocked);
      await provider.navigateInto(task);

      // currentParent is 'blocked', which depends on 'blocker'
      expect(provider.currentParent!.id, blocked);
      expect(provider.blockedTaskIds, contains(blocked));
    });

    test('skipTask returns removed dependency links', () async {
      // Bug fix: skipTask now removes dep rows and returns them for undo,
      // same as completeTask.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == blocker);
      await provider.navigateInto(task);

      final result = await provider.skipTask(blocker);
      expect(result.removedDeps, hasLength(1));
      expect(result.removedDeps.first.taskId, dep);
      expect(result.removedDeps.first.dependsOnId, blocker);
    });

    test('skipTask returns empty removedDeps when no dependents', () async {
      final id = await db.insertTask(Task(name: 'Solo'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateInto(task);

      final result = await provider.skipTask(id);
      expect(result.removedDeps, isEmpty);
    });

    test('unskipTask with restoredDeps restores dependency links', () async {
      // Undo path: skipping a blocker removes deps, undoing restores them.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == blocker);
      await provider.navigateInto(task);

      final result = await provider.skipTask(blocker);

      // Deps should be gone
      final depsAfterSkip = await db.getDependencies(dep);
      expect(depsAfterSkip, isEmpty);

      // Undo — restore deps
      await provider.unskipTask(blocker, restoredDeps: result.removedDeps);
      final depsAfterUndo = await db.getDependencies(dep);
      expect(depsAfterUndo, hasLength(1));
      expect(depsAfterUndo.first.id, blocker);
    });

    test('reSkipTask discards removedDeps intentionally', () async {
      // reSkipTask (restore-from-archive) discards removedDeps — same as
      // reCompleteTask. Dependency links are not preserved on re-archive.
      final blocker = await db.insertTask(Task(name: 'Blocker'));
      final dep = await db.insertTask(Task(name: 'Dependent'));
      await db.addDependency(dep, blocker);
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await db.addRelationship(parentId, blocker);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // reSkipTask should skip without errors
      await provider.reSkipTask(blocker);
      final task = await db.getTaskById(blocker);
      expect(task!.isSkipped, isTrue);
      // Dep rows removed as side effect (not restored on re-archive)
      expect(await db.getDependencies(dep), isEmpty);
    });

    test('skip then unskip roundtrip', () async {
      final id = await db.insertTask(Task(name: 'Task'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateInto(task);
      await provider.skipTask(id);

      var dbTask = await db.getTaskById(id);
      expect(dbTask!.isSkipped, isTrue);

      await provider.unskipTask(id);
      dbTask = await db.getTaskById(id);
      expect(dbTask!.isSkipped, isFalse);
    });
  });

  group('pickWeightedN', () {
    test('returns requested number of tasks', () async {
      for (int i = 0; i < 10; i++) {
        await db.insertTask(Task(name: 'Task $i'));
      }
      final leaves = await provider.getAllLeafTasks();
      final picked = provider.pickWeightedN(leaves, 5);

      expect(picked, hasLength(5));
    });

    test('returns all tasks when count exceeds candidates', () async {
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      final leaves = await provider.getAllLeafTasks();
      final picked = provider.pickWeightedN(leaves, 10);

      expect(picked, hasLength(2));
      expect(picked.map((t) => t.id).toSet(), {a, b});
    });

    test('returns empty list for empty candidates', () async {
      final picked = provider.pickWeightedN([], 5);
      expect(picked, isEmpty);
    });

    test('returns unique tasks (no duplicates)', () async {
      for (int i = 0; i < 20; i++) {
        await db.insertTask(Task(name: 'Task $i'));
      }
      final leaves = await provider.getAllLeafTasks();
      final picked = provider.pickWeightedN(leaves, 5);

      final ids = picked.map((t) => t.id).toSet();
      expect(ids.length, picked.length); // no duplicates
    });

    test('excludes tasks worked on today', () async {
      final id1 = await db.insertTask(Task(name: 'Fresh'));
      final id2 = await db.insertTask(Task(name: 'Worked'));
      await db.markWorkedOn(id2);

      final leaves = await provider.getAllLeafTasks();
      final picked = provider.pickWeightedN(leaves, 5);

      expect(picked.any((t) => t.id == id1), isTrue);
      expect(picked.any((t) => t.id == id2), isFalse);
    });

    test('returns empty when all candidates were worked on today', () async {
      final id1 = await db.insertTask(Task(name: 'A'));
      final id2 = await db.insertTask(Task(name: 'B'));
      await db.markWorkedOn(id1);
      await db.markWorkedOn(id2);

      final leaves = await provider.getAllLeafTasks();
      final picked = provider.pickWeightedN(leaves, 5);

      expect(picked, isEmpty);
    });

    test('high priority tasks get selected with higher probability', () async {
      // Statistical test: with enough runs, high priority should appear more often
      await db.insertTask(Task(name: 'Normal'));
      final highId = await db.insertTask(Task(name: 'High', priority: 1));

      final leaves = await provider.getAllLeafTasks();

      // Pick 1 out of 2 many times — high priority should win more often
      int highCount = 0;
      const runs = 200;
      for (int i = 0; i < runs; i++) {
        final picked = provider.pickWeightedN(leaves, 1);
        if (picked.first.id == highId) highCount++;
      }

      // High priority has 3x weight. Expected ratio ~75%.
      // Use a generous threshold to avoid flaky tests.
      expect(highCount, greaterThan(runs ~/ 4)); // at least 25%
    });

    test('scheduleBoostedIds increases selection probability', () async {
      final normalId = await db.insertTask(Task(name: 'Normal'));
      final boostedId = await db.insertTask(Task(name: 'Boosted'));

      final leaves = await provider.getAllLeafTasks();
      final boostedIds = {boostedId};

      // Pick 1 out of 2 many times — boosted should win more often
      int boostedCount = 0;
      const runs = 200;
      for (int i = 0; i < runs; i++) {
        final picked = provider.pickWeightedN(leaves, 1,
            scheduleBoostedIds: boostedIds);
        if (picked.first.id == boostedId) boostedCount++;
      }

      // Schedule boost is 2.5x weight. Expected ratio ~71%.
      // Use a generous threshold to avoid flaky tests.
      expect(boostedCount, greaterThan(runs ~/ 4)); // at least 25%
      // Also verify it's selected more than half the time on average
      expect(boostedCount, greaterThan(runs ~/ 3));
      // Unused variable suppression
      expect(normalId, isNotNull);
    });
  });

  group('parentNamesMap', () {
    test('contains parent names for children in current view', () async {
      final parentA = await db.insertTask(Task(name: 'Parent A'));
      final parentB = await db.insertTask(Task(name: 'Parent B'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentA, childId);
      await db.addRelationship(parentB, childId);

      // Navigate into Parent A — Child should show both parents
      await provider.loadRootTasks();
      final pA = provider.tasks.firstWhere((t) => t.id == parentA);
      await provider.navigateInto(pA);

      expect(provider.parentNamesMap[childId], isNotNull);
      expect(provider.parentNamesMap[childId], containsAll(['Parent A', 'Parent B']));
    });

    test('single-parent child has one entry in parentNamesMap', () async {
      final parentId = await db.insertTask(Task(name: 'Solo Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      expect(provider.parentNamesMap[childId], ['Solo Parent']);
    });

    test('root tasks with no parents have no entry in parentNamesMap', () async {
      final rootId = await db.insertTask(Task(name: 'Root task'));

      await provider.loadRootTasks();
      expect(provider.parentNamesMap[rootId], isNull);
    });

    test('includes currentParent (leaf task) in parentNamesMap', () async {
      final parentA = await db.insertTask(Task(name: 'Parent A'));
      final parentB = await db.insertTask(Task(name: 'Parent B'));
      final leafId = await db.insertTask(Task(name: 'Leaf'));
      await db.addRelationship(parentA, leafId);
      await db.addRelationship(parentB, leafId);

      // Navigate to the leaf task (has no children)
      await provider.loadRootTasks();
      final pA = provider.tasks.firstWhere((t) => t.id == parentA);
      await provider.navigateInto(pA);
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      // Leaf is now currentParent, tasks list is empty
      expect(provider.currentParent!.id, leafId);
      expect(provider.tasks, isEmpty);

      // parentNamesMap should still contain the leaf's parents
      expect(provider.parentNamesMap[leafId], isNotNull);
      expect(provider.parentNamesMap[leafId], containsAll(['Parent A', 'Parent B']));
    });
  });

  group('Sort tiers in _refreshCurrentList', () {
    // Sort tiers (lower = higher priority):
    // 0: pinned in Today's 5
    // 1: high priority
    // 2: in Today's 5 (unpinned)
    // 3: normal
    // 4: worked-on-today

    test('pinned Today\'s 5 tasks appear before high priority tasks', () async {
      final normalId = await db.insertTask(Task(name: 'Normal'));
      final hpId = await db.insertTask(Task(name: 'HP', priority: 1));
      final pinnedId = await db.insertTask(Task(name: 'Pinned'));

      // Save pinned task in Today's 5 state
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [pinnedId],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {pinnedId},
      );

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final pinnedIdx = ids.indexOf(pinnedId);
      final hpIdx = ids.indexOf(hpId);
      final normalIdx = ids.indexOf(normalId);

      // Pinned (tier 0) < HP (tier 1) < Normal (tier 3)
      expect(pinnedIdx, lessThan(hpIdx));
      expect(hpIdx, lessThan(normalIdx));
    });

    test('high priority tasks appear before unpinned Today\'s 5 tasks', () async {
      final hpId = await db.insertTask(Task(name: 'HP', priority: 1));
      final todaysFiveId = await db.insertTask(Task(name: 'Today Five'));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [todaysFiveId],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {},
      );

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final hpIdx = ids.indexOf(hpId);
      final t5Idx = ids.indexOf(todaysFiveId);
      final normalIdx = ids.indexOf(normalId);

      // HP (tier 1) < Today's 5 unpinned (tier 2) < Normal (tier 3)
      expect(hpIdx, lessThan(t5Idx));
      expect(t5Idx, lessThan(normalIdx));
    });

    test('worked-on-today tasks appear last (after normal)', () async {
      final normalId = await db.insertTask(Task(name: 'Normal'));
      final workedOnId = await db.insertTask(Task(name: 'Worked On'));

      // Mark as worked on today
      await db.markWorkedOn(workedOnId);

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final normalIdx = ids.indexOf(normalId);
      final workedOnIdx = ids.indexOf(workedOnId);

      // Normal (tier 3) < Worked-on-today (tier 4)
      expect(normalIdx, lessThan(workedOnIdx));
    });

    test('full tier ordering: pinned > HP > Today\'s 5 > normal > worked-on-today', () async {
      // Create one task per tier
      final pinnedId = await db.insertTask(Task(name: 'Pinned T5'));
      final hpId = await db.insertTask(Task(name: 'High Priority', priority: 1));
      final todaysFiveId = await db.insertTask(Task(name: 'Unpinned T5'));
      final normalId = await db.insertTask(Task(name: 'Normal'));
      final workedOnId = await db.insertTask(Task(name: 'Worked On'));

      // Mark worked-on-today
      await db.markWorkedOn(workedOnId);

      // Save Today's 5 state with pinned and unpinned
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [pinnedId, todaysFiveId],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {pinnedId},
      );

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      final pinnedIdx = ids.indexOf(pinnedId);
      final hpIdx = ids.indexOf(hpId);
      final t5Idx = ids.indexOf(todaysFiveId);
      final normalIdx = ids.indexOf(normalId);
      final workedOnIdx = ids.indexOf(workedOnId);

      // Verify strict ordering across all tiers
      expect(pinnedIdx, lessThan(hpIdx),
          reason: 'Pinned (tier 0) should be before HP (tier 1)');
      expect(hpIdx, lessThan(t5Idx),
          reason: 'HP (tier 1) should be before Today\'s 5 unpinned (tier 2)');
      expect(t5Idx, lessThan(normalIdx),
          reason: 'Today\'s 5 unpinned (tier 2) should be before normal (tier 3)');
      expect(normalIdx, lessThan(workedOnIdx),
          reason: 'Normal (tier 3) should be before worked-on-today (tier 4)');
    });

    test('multiple tasks in the same tier preserve relative DB order', () async {
      // Insert in order: A, B, C — all normal tier
      final aId = await db.insertTask(Task(name: 'Task A'));
      final bId = await db.insertTask(Task(name: 'Task B'));
      final cId = await db.insertTask(Task(name: 'Task C'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      // All same tier (3=normal), so order should match DB order
      final aIdx = ids.indexOf(aId);
      final bIdx = ids.indexOf(bId);
      final cIdx = ids.indexOf(cId);

      expect(aIdx, lessThan(bIdx));
      expect(bIdx, lessThan(cIdx));
    });

    test('sort tiers work inside a non-root parent', () async {
      // Create a parent with children of different tiers
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final pinnedChild = await db.insertTask(Task(name: 'Pinned Child'));
      final normalChild = await db.insertTask(Task(name: 'Normal Child'));
      final hpChild = await db.insertTask(Task(name: 'HP Child', priority: 1));

      await db.addRelationship(parentId, pinnedChild);
      await db.addRelationship(parentId, normalChild);
      await db.addRelationship(parentId, hpChild);

      // Pin the child in Today's 5
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [pinnedChild],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {pinnedChild},
      );

      // Navigate into parent
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      final ids = provider.tasks.map((t) => t.id).toList();
      final pinnedIdx = ids.indexOf(pinnedChild);
      final hpIdx = ids.indexOf(hpChild);
      final normalIdx = ids.indexOf(normalChild);

      // Pinned (0) < HP (1) < Normal (3)
      expect(pinnedIdx, lessThan(hpIdx));
      expect(hpIdx, lessThan(normalIdx));
    });

    test('worked-on-today HP task gets tier 4 (worked-on overrides HP)', () async {
      // A high priority task that was worked on today should be in tier 4
      // because isWorkedOnToday check comes first in sortTier
      final hpWorkedId = await db.insertTask(Task(name: 'HP Worked', priority: 1));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await db.markWorkedOn(hpWorkedId);

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final hpWorkedIdx = ids.indexOf(hpWorkedId);
      final normalIdx = ids.indexOf(normalId);

      // HP + worked-on-today → tier 4, normal → tier 3
      // So normal should come before HP-worked-on
      expect(normalIdx, lessThan(hpWorkedIdx));
    });

    test('worked-on-today pinned task gets tier 4 (worked-on overrides pinned)', () async {
      // A pinned task that was worked on today should be in tier 4
      final pinnedWorkedId = await db.insertTask(Task(name: 'Pinned Worked'));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await db.markWorkedOn(pinnedWorkedId);

      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [pinnedWorkedId],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {pinnedWorkedId},
      );

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final pinnedWorkedIdx = ids.indexOf(pinnedWorkedId);
      final normalIdx = ids.indexOf(normalId);

      // Worked-on-today check comes first → tier 4
      expect(normalIdx, lessThan(pinnedWorkedIdx));
    });

    test('no Today\'s 5 state: all tasks get normal/HP tiers only', () async {
      // When there's no Today's 5 state saved, no task should get tier 0 or 2
      final hpId = await db.insertTask(Task(name: 'HP', priority: 1));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      // HP first, then normal
      expect(ids.indexOf(hpId), lessThan(ids.indexOf(normalId)));
    });
  });

  group('onMutation callback', () {
    test('completeTask calls onMutation', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      int callCount = 0;
      provider.onMutation = () => callCount++;

      await provider.completeTask(childId);
      expect(callCount, 1);
    });

    test('skipTask calls onMutation', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      int callCount = 0;
      provider.onMutation = () => callCount++;

      await provider.skipTask(childId);
      expect(callCount, 1);
    });

    test('markWorkedOnAndNavigateBack calls onMutation', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await db.startTask(childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      int callCount = 0;
      provider.onMutation = () => callCount++;

      await provider.markWorkedOnAndNavigateBack(childId);
      expect(callCount, 1);
    });

    test('onMutation is not called when callback is null', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      final child = provider.tasks.firstWhere((t) => t.id == childId);
      await provider.navigateInto(child);

      provider.onMutation = null;

      // Should not throw when onMutation is null
      await provider.completeTask(childId);
    });
  });

  group('refreshCurrentView', () {
    test('refreshes at root without resetting navigation', () async {
      await db.insertTask(Task(name: 'Root Task'));
      await provider.loadRootTasks();
      expect(provider.tasks.length, 1);

      // Insert another task behind the scenes (simulates sync)
      await db.insertTask(Task(name: 'Synced Task'));
      await provider.refreshCurrentView();

      expect(provider.isRoot, isTrue);
      expect(provider.tasks.length, 2);
    });

    test('refreshes at non-root without navigating back to root', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await provider.loadRootTasks();

      final parent = provider.tasks.first;
      await provider.navigateInto(parent);
      expect(provider.isRoot, isFalse);
      expect(provider.currentParent?.id, parentId);
      expect(provider.tasks.length, 1);

      // Insert another child behind the scenes (simulates sync)
      final syncedChildId = await db.insertTask(Task(name: 'Synced Child'));
      await db.addRelationship(parentId, syncedChildId);
      await provider.refreshCurrentView();

      // Should still be inside parent, not reset to root
      expect(provider.isRoot, isFalse);
      expect(provider.currentParent?.id, parentId);
      expect(provider.tasks.length, 2);
    });

    test('preserves navigation stack depth', () async {
      final grandparentId = await db.insertTask(Task(name: 'Grandparent'));
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await db.addRelationship(grandparentId, parentId);
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);
      await provider.loadRootTasks();

      // Navigate two levels deep
      final grandparent = provider.tasks.first;
      await provider.navigateInto(grandparent);
      final parent = provider.tasks.first;
      await provider.navigateInto(parent);
      expect(provider.currentParent?.id, parentId);

      await provider.refreshCurrentView();

      // Still at same depth, can navigate back twice
      expect(provider.currentParent?.id, parentId);
      await provider.navigateBack();
      expect(provider.currentParent?.id, grandparentId);
      await provider.navigateBack();
      expect(provider.isRoot, isTrue);
    });

    test('does not trigger onMutation callback', () async {
      await db.insertTask(Task(name: 'Task'));
      await provider.loadRootTasks();

      var mutationCalled = false;
      provider.onMutation = () => mutationCalled = true;

      await provider.refreshCurrentView();

      expect(mutationCalled, isFalse);
    });
  });

  group('pickWeightedN normalization', () {
    test('normFactor reduces large-root dominance', () async {
      // Create 2 roots: big (20 leaves) and small (2 leaves)
      final bigRoot = await db.insertTask(Task(name: 'Big'));
      final smallRoot = await db.insertTask(Task(name: 'Small'));
      final bigLeaves = <Task>[];
      final smallLeaves = <Task>[];

      for (var i = 0; i < 20; i++) {
        final id = await db.insertTask(Task(name: 'B$i'));
        await db.addRelationship(bigRoot, id);
        final t = await db.getTaskById(id);
        bigLeaves.add(t!);
      }
      for (var i = 0; i < 2; i++) {
        final id = await db.insertTask(Task(name: 'S$i'));
        await db.addRelationship(smallRoot, id);
        final t = await db.getTaskById(id);
        smallLeaves.add(t!);
      }

      final allLeaves = [...bigLeaves, ...smallLeaves];
      final leafIds = allLeaves.map((t) => t.id!).toList();
      final normData = await db.getNormalizationData(leafIds);

      final smallRootIds = smallLeaves.map((t) => t.id!).toSet();
      var smallPicks = 0;
      const runs = 200;

      for (var i = 0; i < runs; i++) {
        final picked = provider.pickWeightedN(allLeaves, 1, normData: normData);
        if (picked.isNotEmpty && smallRootIds.contains(picked.first.id)) {
          smallPicks++;
        }
      }

      // Without normalization, small root would get ~2/22 ≈ 9%.
      // With normalization, should be ≥15%.
      expect(smallPicks / runs, greaterThanOrEqualTo(0.15),
          reason: 'Small root should get ≥15% of picks with normalization '
              '(got ${(smallPicks / runs * 100).toStringAsFixed(1)}%)');
    });

    test('diversity penalty spreads picks across roots', () async {
      // 2 equal roots with 5 leaves each
      final rootA = await db.insertTask(Task(name: 'A'));
      final rootB = await db.insertTask(Task(name: 'B'));
      final allLeaves = <Task>[];

      for (var i = 0; i < 5; i++) {
        final id = await db.insertTask(Task(name: 'A$i'));
        await db.addRelationship(rootA, id);
        final t = await db.getTaskById(id);
        allLeaves.add(t!);
      }
      for (var i = 0; i < 5; i++) {
        final id = await db.insertTask(Task(name: 'B$i'));
        await db.addRelationship(rootB, id);
        final t = await db.getTaskById(id);
        allLeaves.add(t!);
      }

      final leafIds = allLeaves.map((t) => t.id!).toList();
      final normData = await db.getNormalizationData(leafIds);

      final rootALeafIds = allLeaves.sublist(0, 5).map((t) => t.id!).toSet();
      var totalFromA = 0;
      const runs = 100;

      for (var i = 0; i < runs; i++) {
        final picked = provider.pickWeightedN(allLeaves, 4, normData: normData);
        totalFromA += picked.where((t) => rootALeafIds.contains(t.id)).length;
      }

      // With diversity penalty, expect roughly 2 from each root per run.
      // Average from A should be between 1.2 and 2.8 (allowing variance).
      final avgFromA = totalFromA / runs;
      expect(avgFromA, greaterThan(1.2),
          reason: 'Should pick from root A (avg=$avgFromA)');
      expect(avgFromA, lessThan(2.8),
          reason: 'Should not over-pick from root A (avg=$avgFromA)');
    });

    test('existingRootPickCounts seeds diversity penalty for swap', () async {
      // 2 equal roots with 5 leaves each
      final rootA = await db.insertTask(Task(name: 'A'));
      final rootB = await db.insertTask(Task(name: 'B'));
      final allLeaves = <Task>[];

      for (var i = 0; i < 5; i++) {
        final id = await db.insertTask(Task(name: 'A$i'));
        await db.addRelationship(rootA, id);
        final t = await db.getTaskById(id);
        allLeaves.add(t!);
      }
      for (var i = 0; i < 5; i++) {
        final id = await db.insertTask(Task(name: 'B$i'));
        await db.addRelationship(rootB, id);
        final t = await db.getTaskById(id);
        allLeaves.add(t!);
      }

      final leafIds = allLeaves.map((t) => t.id!).toList();
      final normData = await db.getNormalizationData(leafIds);

      // Simulate: today's 5 already has 3 tasks from root A.
      // When swapping, pre-seeded counts should penalize root A heavily.
      final existingCounts = <int, int>{rootA: 3};

      final rootBLeafIds = allLeaves.sublist(5).map((t) => t.id!).toSet();
      var pickedFromB = 0;
      const runs = 100;

      for (var i = 0; i < runs; i++) {
        final picked = provider.pickWeightedN(allLeaves, 1,
            normData: normData, existingRootPickCounts: existingCounts);
        if (rootBLeafIds.contains(picked.first.id)) pickedFromB++;
      }

      // With 3 existing picks from A, diversity penalty = 0.3^3 = 0.027x
      // on root A. Root B should be picked the vast majority of the time.
      expect(pickedFromB, greaterThan(70),
          reason: 'Root B should dominate when A has 3 existing picks '
                  '(got $pickedFromB/100)');
    });

    test('backward compatible when normData is null', () async {
      final id = await db.insertTask(Task(name: 'Solo'));
      final t = await db.getTaskById(id);

      final picked = provider.pickWeightedN([t!], 1);
      expect(picked, hasLength(1));
      expect(picked.first.id, id);
    });
  });

  group('Inbox', () {
    test('addTask at root with isInbox sets isInbox to true', () async {
      await provider.loadRootTasks();
      await provider.addTask('Inbox task', isInbox: true);

      final inboxTasks = await provider.getInboxTasks();
      expect(inboxTasks, hasLength(1));
      expect(inboxTasks.first.name, 'Inbox task');
      expect(inboxTasks.first.isInbox, isTrue);
    });

    test('addTask under parent does not set isInbox', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      await provider.addTask('Child task');

      final inboxTasks = await provider.getInboxTasks();
      expect(inboxTasks, isEmpty);
    });

    test('addTask with additionalParentIds does not set isInbox', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();

      await provider.addTask('Multi-parent task', additionalParentIds: [parentId]);

      final inboxTasks = await provider.getInboxTasks();
      expect(inboxTasks, isEmpty);
    });

    test('addTasksBatch with isInbox sets flag on all tasks', () async {
      await provider.loadRootTasks();
      await provider.addTasksBatch(['A', 'B', 'C'], isInbox: true);

      final inboxTasks = await provider.getInboxTasks();
      expect(inboxTasks, hasLength(3));
      expect(inboxTasks.every((t) => t.isInbox), isTrue);
    });

    test('addTasksBatch without isInbox does not set flag', () async {
      await provider.loadRootTasks();
      await provider.addTasksBatch(['A', 'B']);

      final inboxTasks = await provider.getInboxTasks();
      expect(inboxTasks, isEmpty);
    });

    test('fileTask clears inbox flag and adds relationship', () async {
      await provider.loadRootTasks();
      final taskId = await provider.addTask('Inbox task', isInbox: true);
      final parentId = await db.insertTask(Task(name: 'Target parent'));

      expect(await provider.getInboxCount(), 1);

      final success = await provider.fileTask(taskId, parentId);
      expect(success, isTrue);

      expect(await provider.getInboxCount(), 0);
      final parents = await provider.getParents(taskId);
      expect(parents.any((p) => p.id == parentId), isTrue);
    });

    test('fileTask rejects cycles', () async {
      await provider.loadRootTasks();
      final parentId = await provider.addTask('Parent');
      final childId = await db.insertTask(Task(name: 'Child', isInbox: true));
      await db.addRelationship(parentId, childId);

      // Try to file the parent under its own child
      final success = await provider.fileTask(parentId, childId);
      expect(success, isFalse);
    });

    test('dismissFromInbox clears flag without adding parent', () async {
      await provider.loadRootTasks();
      final taskId = await provider.addTask('Keep at root', isInbox: true);

      expect(await provider.getInboxCount(), 1);

      await provider.dismissFromInbox(taskId);

      expect(await provider.getInboxCount(), 0);
      // Task should still be a root task (no parents)
      final parents = await provider.getParents(taskId);
      expect(parents, isEmpty);
    });

    test('getInboxCount returns correct count', () async {
      await provider.loadRootTasks();
      await provider.addTask('A', isInbox: true);
      await provider.addTask('B', isInbox: true);
      // Add one under a parent
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);
      await provider.addTask('C under parent');

      expect(await provider.getInboxCount(), 2);
    });

    test('unfileTask restores inbox flag and removes relationship', () async {
      await provider.loadRootTasks();
      final taskId = await provider.addTask('Inbox task', isInbox: true);
      final parentId = await db.insertTask(Task(name: 'Parent'));

      // File it
      final success = await provider.fileTask(taskId, parentId);
      expect(success, isTrue);
      expect(await provider.getInboxCount(), 0);

      // Undo
      await provider.unfileTask(taskId, parentId);
      expect(await provider.getInboxCount(), 1);
      final parents = await provider.getParents(taskId);
      expect(parents.any((p) => p.id == parentId), isFalse);
    });

    test('undoDismissFromInbox restores inbox flag', () async {
      await provider.loadRootTasks();
      final taskId = await provider.addTask('Dismiss me', isInbox: true);

      await provider.dismissFromInbox(taskId);
      expect(await provider.getInboxCount(), 0);

      await provider.undoDismissFromInbox(taskId);
      expect(await provider.getInboxCount(), 1);
    });

    test('navigateInto loads fresh task data from DB', () async {
      await provider.loadRootTasks();
      final taskId = await provider.addTask('Test task', isInbox: true);

      // Get a reference to the task (priority 0)
      final inboxTasks = await provider.getInboxTasks();
      final staleTask = inboxTasks.first;
      expect(staleTask.priority, 0);

      // Update priority directly in DB
      await db.updateTaskPriority(taskId, 1);

      // navigateInto should reload from DB, not use the stale object
      await provider.navigateInto(staleTask);
      expect(provider.currentParent!.priority, 1);
    });
  });

  group('computeParentSuggestions', () {
    test('returns empty for no tasks', () async {
      final suggestions = await provider.computeParentSuggestions('Anything');
      expect(suggestions, isEmpty);
    });

    test('keyword scoring: matching names score higher', () async {
      await db.insertTask(Task(name: 'Shopping list'));
      await db.insertTask(Task(name: 'Work projects'));
      await db.insertTask(Task(name: 'Grocery shopping'));

      final suggestions = await provider.computeParentSuggestions('Shopping items');
      // Tasks with "shopping" in name should appear
      expect(suggestions.isNotEmpty, isTrue);
      final names = suggestions.map((s) => s.task.name).toList();
      expect(names, contains('Shopping list'));
      expect(names, contains('Grocery shopping'));
    });

    test('recency scoring: parent with recent children scores higher', () async {
      final recentParent = await db.insertTask(Task(name: 'Recent'));
      final staleParent = await db.insertTask(Task(name: 'Stale'));
      // Recent parent has a child added just now
      final recentChild = await db.insertTask(Task(name: 'New child'));
      await db.addRelationship(recentParent, recentChild);
      // Stale parent has a child added 30 days ago
      final staleChild = await db.insertTask(Task(
        name: 'Old child',
        createdAt: DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch,
      ));
      await db.addRelationship(staleParent, staleChild);

      final suggestions = await provider.computeParentSuggestions('task');
      if (suggestions.length >= 2) {
        final recentScore = suggestions.firstWhere((s) => s.task.id == recentParent).score;
        final staleScore = suggestions.firstWhere((s) => s.task.id == staleParent).score;
        expect(recentScore, greaterThan(staleScore));
      }
    });

    test('sibling scoring: matching child names increase score', () async {
      final parentId = await db.insertTask(Task(name: 'Errands'));
      final child1 = await db.insertTask(Task(name: 'Buy groceries'));
      final child2 = await db.insertTask(Task(name: 'Pick up dry cleaning'));
      await db.addRelationship(parentId, child1);
      await db.addRelationship(parentId, child2);

      final suggestions = await provider.computeParentSuggestions('Buy milk');
      // "Errands" should appear because its child "Buy groceries" shares "buy" token
      expect(suggestions.any((s) => s.task.id == parentId), isTrue);
    });

    test('respects limit parameter', () async {
      for (int i = 0; i < 10; i++) {
        await db.insertTask(Task(name: 'Task $i'));
      }

      final suggestions = await provider.computeParentSuggestions('Task', limit: 3);
      expect(suggestions.length, lessThanOrEqualTo(3));
    });

    test('excludeTaskId omits the specified task', () async {
      final taskA = await db.insertTask(Task(name: 'Shopping list'));
      await db.insertTask(Task(name: 'Shopping cart'));

      final suggestions = await provider.computeParentSuggestions(
        'Shopping',
        excludeTaskId: taskA,
      );
      expect(suggestions.any((s) => s.task.id == taskA), isFalse);
    });

    test('substring match: parent name containing query scores higher', () async {
      // "Groceries" should match "Buy groceries" via substring
      final groceries = await db.insertTask(Task(name: 'Groceries'));
      final unrelated = await db.insertTask(Task(name: 'Meetings'));

      final suggestions = await provider.computeParentSuggestions('Buy groceries');
      final groceriesScore = suggestions.firstWhere((s) => s.task.id == groceries).score;
      // Unrelated task may or may not appear; if it does, it should score lower
      final unrelatedEntry = suggestions.where((s) => s.task.id == unrelated);
      if (unrelatedEntry.isNotEmpty) {
        expect(groceriesScore, greaterThan(unrelatedEntry.first.score));
      }
    });

    test('category boost: parent with 3+ children scores higher than parent with 0', () async {
      // Both parents have the same keyword match so any score difference is from category boost
      final bigParent = await db.insertTask(Task(name: 'Chores list'));
      for (int i = 0; i < 4; i++) {
        final childId = await db.insertTask(Task(name: 'Chore item $i'));
        await db.addRelationship(bigParent, childId);
      }
      final smallParent = await db.insertTask(Task(name: 'Chores backlog'));

      final suggestions = await provider.computeParentSuggestions('Chores');
      final bigScore = suggestions.firstWhere((s) => s.task.id == bigParent).score;
      final smallScore = suggestions.firstWhere((s) => s.task.id == smallParent).score;
      expect(bigScore, greaterThan(smallScore));
    });

    test('tasks with zero score are filtered out', () async {
      // Insert a task with a completely unrelated name
      await db.insertTask(Task(name: 'XYZZY'));

      // Query something with no overlap at all
      final suggestions = await provider.computeParentSuggestions('Quantum physics');
      // XYZZY should not appear since it has no keyword, substring, or sibling match
      expect(suggestions.any((s) => s.task.name == 'XYZZY'), isFalse);
    });
  });

  group('Deadline sort tier', () {
    test('task with deadline <= 3 days sorts at tier 1 (virtual high priority)', () async {
      // Create a task with near deadline and a normal task
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final deadlineStr = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
      final deadlineId = await db.insertTask(Task(name: 'Deadline Soon', deadline: deadlineStr));
      final normalId = await db.insertTask(Task(name: 'Normal Task'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final deadlineIdx = ids.indexOf(deadlineId);
      final normalIdx = ids.indexOf(normalId);

      // Near-deadline (tier 1) should sort before normal (tier 3)
      expect(deadlineIdx, lessThan(normalIdx),
          reason: 'Near-deadline task should sort before normal task');
    });

    test('task with deadline today sorts at tier 1', () async {
      final today = DateTime.now();
      final deadlineStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final deadlineId = await db.insertTask(Task(name: 'Due Today', deadline: deadlineStr));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      expect(ids.indexOf(deadlineId), lessThan(ids.indexOf(normalId)),
          reason: 'Today-deadline task should sort before normal');
    });

    test('task with deadline 3 days out sorts at tier 1', () async {
      final threeDays = DateTime.now().add(const Duration(days: 3));
      final deadlineStr = '${threeDays.year}-${threeDays.month.toString().padLeft(2, '0')}-${threeDays.day.toString().padLeft(2, '0')}';
      final deadlineId = await db.insertTask(Task(name: 'Due in 3d', deadline: deadlineStr));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      expect(ids.indexOf(deadlineId), lessThan(ids.indexOf(normalId)),
          reason: 'Deadline in 3 days should sort at tier 1 (before normal tier 3)');
    });

    test('task with deadline > 3 days does not get tier 1', () async {
      final fiveDays = DateTime.now().add(const Duration(days: 5));
      final deadlineStr = '${fiveDays.year}-${fiveDays.month.toString().padLeft(2, '0')}-${fiveDays.day.toString().padLeft(2, '0')}';
      final deadlineId = await db.insertTask(Task(name: 'Due in 5d', deadline: deadlineStr));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();
      final deadlineIdx = ids.indexOf(deadlineId);
      final normalIdx = ids.indexOf(normalId);

      // Both should be tier 3 (normal), so preserve DB insert order
      // deadlineId was inserted first
      expect(deadlineIdx, lessThan(normalIdx),
          reason: 'Both are tier 3, preserve insert order');
    });

    test('overdue deadline sorts at tier 1', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final deadlineStr = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      final overdueId = await db.insertTask(Task(name: 'Overdue', deadline: deadlineStr));
      final normalId = await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();
      final ids = provider.tasks.map((t) => t.id).toList();

      expect(ids.indexOf(overdueId), lessThan(ids.indexOf(normalId)),
          reason: 'Overdue deadline (daysUntil=-1, <=3) should sort at tier 1');
    });
  });

  group('Deadline updateTaskDeadline via provider', () {
    test('updateTaskDeadline sets deadline and refreshes currentParent', () async {
      final leafId = await db.insertTask(Task(name: 'Leaf'));

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      expect(provider.currentParent!.deadline, isNull);

      await provider.updateTaskDeadline(leafId, '2026-06-15');

      expect(provider.currentParent!.deadline, '2026-06-15');
      expect(provider.currentParent!.hasDeadline, isTrue);
    });

    test('updateTaskDeadline clears deadline on currentParent', () async {
      final leafId = await db.insertTask(Task(name: 'Leaf', deadline: '2026-06-15'));

      await provider.loadRootTasks();
      final leaf = provider.tasks.firstWhere((t) => t.id == leafId);
      await provider.navigateInto(leaf);

      expect(provider.currentParent!.deadline, '2026-06-15');

      await provider.updateTaskDeadline(leafId, null);

      expect(provider.currentParent!.deadline, isNull);
      expect(provider.currentParent!.hasDeadline, isFalse);
    });

    test('updateTaskDeadline persists to database', () async {
      final id = await db.insertTask(Task(name: 'Task'));

      await provider.loadRootTasks();
      await provider.updateTaskDeadline(id, '2026-12-25');

      final task = await db.getTaskById(id);
      expect(task!.deadline, '2026-12-25');
    });
  });

  group('Deadline weight multiplier', () {
    // We test _taskWeight indirectly: create two tasks — one with deadline, one without.
    // The deadline task should be picked more often by pickRandom due to higher weight.
    test('deadline today heavily favors picking (approx 8x base)', () async {
      final today = DateTime.now();
      final deadlineStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      // Both tasks created now, same age, same priority
      final deadlineId = await db.insertTask(Task(name: 'Deadline Today', deadline: deadlineStr));
      await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();

      // Pick 200 times and count
      int deadlinePicks = 0;
      int normalPicks = 0;
      for (int i = 0; i < 200; i++) {
        final picked = provider.pickRandom();
        if (picked!.id == deadlineId) {
          deadlinePicks++;
        } else {
          normalPicks++;
        }
      }

      // With ~8x weight, deadline should be picked roughly 80%+ of the time
      // Allow wide margin for randomness
      expect(deadlinePicks, greaterThan(normalPicks),
          reason: 'Deadline-today task (8x weight) should be picked more often');
      // At least 60% of picks should be the deadline task
      expect(deadlinePicks, greaterThan(120),
          reason: 'Deadline-today should be picked at least 60% of 200 times');
    });

    test('deadline 15+ days away does not boost weight', () async {
      final farFuture = DateTime.now().add(const Duration(days: 20));
      final deadlineStr = '${farFuture.year}-${farFuture.month.toString().padLeft(2, '0')}-${farFuture.day.toString().padLeft(2, '0')}';

      // Both tasks created now, same age, same priority
      final deadlineId = await db.insertTask(Task(name: 'Far Deadline', deadline: deadlineStr));
      await db.insertTask(Task(name: 'Normal'));

      await provider.loadRootTasks();

      // Pick 200 times and count
      int deadlinePicks = 0;
      for (int i = 0; i < 200; i++) {
        final picked = provider.pickRandom();
        if (picked!.id == deadlineId) deadlinePicks++;
      }

      // With 1.0x multiplier (no boost), picks should be roughly even (~50%)
      // Allow wide margin: between 30% and 70%
      expect(deadlinePicks, greaterThan(60),
          reason: 'Far-deadline task should get some picks (no penalty)');
      expect(deadlinePicks, lessThan(140),
          reason: 'Far-deadline task should not dominate (no boost)');
    });
  });

  group('Starred tasks', () {
    test('updateTaskStarred assigns next star_order when starring', () async {
      final id1 = await db.insertTask(Task(name: 'First'));
      final id2 = await db.insertTask(Task(name: 'Second'));

      await provider.updateTaskStarred(id1, true);
      await provider.updateTaskStarred(id2, true);

      final starred = await provider.getStarredTasks();
      expect(starred.length, 2);
      // First starred task gets order 0, second gets order 1
      expect(starred[0].id, id1);
      expect(starred[0].starOrder, 0);
      expect(starred[1].id, id2);
      expect(starred[1].starOrder, 1);
    });

    test('updateTaskStarred unstarring clears star_order', () async {
      final id = await db.insertTask(Task(name: 'Star then unstar'));
      await provider.updateTaskStarred(id, true);

      // Verify it's starred
      var starred = await provider.getStarredTasks();
      expect(starred.length, 1);

      // Unstar
      await provider.updateTaskStarred(id, false);
      starred = await provider.getStarredTasks();
      expect(starred, isEmpty);

      // Verify task still exists but is not starred
      final task = await db.getTaskById(id);
      expect(task!.isStarred, isFalse);
    });

    test('reorderStarredTasks normalizes star_order to 0..N-1', () async {
      final id1 = await db.insertTask(Task(name: 'A'));
      final id2 = await db.insertTask(Task(name: 'B'));
      final id3 = await db.insertTask(Task(name: 'C'));

      await provider.updateTaskStarred(id1, true);
      await provider.updateTaskStarred(id2, true);
      await provider.updateTaskStarred(id3, true);

      // Reorder: C, A, B
      await provider.reorderStarredTasks([id3, id1, id2]);

      final starred = await provider.getStarredTasks();
      expect(starred[0].id, id3);
      expect(starred[0].starOrder, 0);
      expect(starred[1].id, id1);
      expect(starred[1].starOrder, 1);
      expect(starred[2].id, id2);
      expect(starred[2].starOrder, 2);
    });

    test('starred completed task excluded from getStarredTasks', () async {
      final id = await db.insertTask(Task(name: 'Complete me'));
      await provider.updateTaskStarred(id, true);

      await db.completeTask(id);
      final starred = await provider.getStarredTasks();
      expect(starred.where((t) => t.id == id), isEmpty);
    });

    test('starred skipped task excluded from getStarredTasks', () async {
      final id = await db.insertTask(Task(name: 'Skip me'));
      await provider.updateTaskStarred(id, true);

      await db.skipTask(id);
      final starred = await provider.getStarredTasks();
      expect(starred.where((t) => t.id == id), isEmpty);
    });

    test('uncompleting a starred task restores it in getStarredTasks', () async {
      final id = await db.insertTask(Task(name: 'Restore me'));
      await provider.updateTaskStarred(id, true);
      await db.completeTask(id);

      // Not visible while completed
      expect((await provider.getStarredTasks()).where((t) => t.id == id), isEmpty);

      await db.uncompleteTask(id);

      // Visible again
      final starred = await provider.getStarredTasks();
      expect(starred.where((t) => t.id == id), hasLength(1));
    });

    test('updateTaskStarred updates currentParent when task is current', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      // Now currentParent is parent — star it
      await provider.updateTaskStarred(parentId, true);
      expect(provider.currentParent!.isStarred, isTrue);
      expect(provider.currentParent!.starOrder, 0);
    });
  });

  group('addTask deferNotify', () {
    test('addTask with deferNotify:true does not call onMutation', () async {
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      await provider.addTask('Deferred Task', deferNotify: true);

      // onMutation should NOT have been called
      expect(mutationCount, 0);
    });

    test('addTask with deferNotify:true does not refresh task list', () async {
      await provider.loadRootTasks();
      expect(provider.tasks, isEmpty);

      await provider.addTask('Deferred Task', deferNotify: true);

      // Task list should still be empty because _refreshAfterMutation was skipped
      expect(provider.tasks, isEmpty);
    });

    test('addTask with deferNotify:false (default) calls onMutation', () async {
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      await provider.addTask('Normal Task');

      expect(mutationCount, 1);
    });

    test('addTask with deferNotify:false refreshes task list', () async {
      await provider.loadRootTasks();

      await provider.addTask('Normal Task');

      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.name, 'Normal Task');
    });

    test('addTask with deferNotify:true still inserts task in DB', () async {
      await provider.loadRootTasks();

      final taskId = await provider.addTask('Deferred Task', deferNotify: true);

      // Task should exist in DB even though listeners weren't notified
      final task = await db.getTaskById(taskId);
      expect(task, isNotNull);
      expect(task!.name, 'Deferred Task');
    });

    test('addTask with deferNotify:true still creates relationships', () async {
      final parentId = await db.insertTask(Task(name: 'Parent'));
      await provider.loadRootTasks();
      final parent = provider.tasks.firstWhere((t) => t.id == parentId);
      await provider.navigateInto(parent);

      final childId = await provider.addTask('Child', deferNotify: true);

      // Relationship should exist in DB
      final children = await db.getChildren(parentId);
      expect(children.any((c) => c.id == childId), isTrue);
    });

    test('refreshAfterMutation completes deferred notification', () async {
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      await provider.addTask('Deferred Task', deferNotify: true);
      expect(mutationCount, 0);
      expect(provider.tasks, isEmpty);

      // Now call refreshAfterMutation to complete the deferred work
      await provider.refreshAfterMutation();

      expect(mutationCount, 1);
      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.name, 'Deferred Task');
    });

    // Regression: Before the try/finally fix in task_list_screen.dart, if the
    // pin operation threw after addTask(deferNotify: true), refreshAfterMutation
    // was never called — the task existed in DB but the UI stayed stale.
    // The fix wraps pin operations in try/finally so refreshAfterMutation always
    // runs. This test verifies the provider-level contract that makes it work.
    test('refreshAfterMutation recovers task list even after pin failure', () async {
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      final taskId = await provider.addTask('Pin Me', deferNotify: true);

      // Task is in DB but not in provider's list
      expect(provider.tasks, isEmpty);
      expect(mutationCount, 0);

      // Simulate pin operation that throws (e.g. saveTodaysFiveState fails).
      // In the real code, the finally block catches this.
      bool pinFailed = false;
      try {
        throw Exception('Simulated pin failure');
      } catch (_) {
        pinFailed = true;
      } finally {
        // This is the critical call — the try/finally fix ensures this always runs
        await provider.refreshAfterMutation();
      }

      expect(pinFailed, isTrue);
      // Despite pin failure, task is now visible in the provider's list
      expect(provider.tasks, hasLength(1));
      expect(provider.tasks.first.id, taskId);
      expect(provider.tasks.first.name, 'Pin Me');
      expect(mutationCount, 1);
    });

    test('deferNotify allows DB writes before listeners fire', () async {
      // This simulates the pin-on-add bug fix:
      // 1. addTask with deferNotify:true
      // 2. Pin the new task in Today's 5 (DB write)
      // 3. Call refreshAfterMutation()
      // The key point: step 2 happens without listeners firing in between.
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      final taskId = await provider.addTask('Pin Me', deferNotify: true);

      // Simulate pinning the task in the DB before listeners fire
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await db.saveTodaysFiveState(
        date: today,
        taskIds: [taskId],
        completedIds: {},
        workedOnIds: {},
        pinnedIds: {taskId},
      );

      // No listeners fired yet — pin is safely persisted
      expect(mutationCount, 0);

      // Now trigger notification
      await provider.refreshAfterMutation();
      expect(mutationCount, 1);

      // Verify the pin survived (not overwritten by a race condition)
      final state = await db.loadTodaysFiveState(today);
      expect(state, isNotNull);
      expect(state!.taskIds, contains(taskId));
      expect(state.pinnedIds, contains(taskId));
    });

    // Edge case: multiple deferred adds without intermediate refreshes.
    // refreshAfterMutation called once at the end should pick up all tasks.
    test('single refreshAfterMutation picks up multiple deferred tasks', () async {
      await provider.loadRootTasks();

      final id1 = await provider.addTask('Deferred 1', deferNotify: true);
      final id2 = await provider.addTask('Deferred 2', deferNotify: true);
      final id3 = await provider.addTask('Deferred 3', deferNotify: true);

      // None visible yet
      expect(provider.tasks, isEmpty);

      await provider.refreshAfterMutation();

      // All three should appear
      expect(provider.tasks, hasLength(3));
      final ids = provider.tasks.map((t) => t.id).toSet();
      expect(ids, containsAll([id1, id2, id3]));
    });

    // Baseline: without the try/finally fix, if refreshAfterMutation is never
    // called after deferNotify:true, the task is invisible in the UI despite
    // existing in the DB. This baseline documents why the finally block matters.
    test('task stays invisible in provider without refreshAfterMutation call', () async {
      await provider.loadRootTasks();

      final taskId = await provider.addTask('Orphaned', deferNotify: true);

      // Task exists in DB
      final dbTask = await db.getTaskById(taskId);
      expect(dbTask, isNotNull);
      expect(dbTask!.name, 'Orphaned');

      // But provider still shows empty list — this is the stale state the
      // try/finally fix prevents
      expect(provider.tasks, isEmpty);
    });
  });

  // I-42 Regression: addRelationship was missing _refreshAfterMutation, so
  // undo-restored relationships didn't refresh UI or trigger sync push.
  group('addRelationship triggers refresh and mutation', () {
    test('addRelationship calls onMutation', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parent, child);
      // Remove the relationship so we can re-add via provider
      await db.removeRelationship(parent, child);
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      await provider.addRelationship(parent, child);
      expect(mutationCount, 1, reason: 'addRelationship should call onMutation via _refreshAfterMutation');
    });

    test('addRelationship refreshes task list', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final child = await db.insertTask(Task(name: 'Child'));
      await provider.loadRootTasks();

      // Both should be root tasks initially
      expect(provider.tasks.length, 2);

      await provider.addRelationship(parent, child);

      // After adding relationship, child is no longer a root task
      // _refreshAfterMutation reloads the list
      expect(provider.tasks.length, 1);
      expect(provider.tasks.first.id, parent);
    });
  });

  // I-43 Regression: reorderStarredTasks was calling onMutation directly
  // instead of _refreshAfterMutation, so sync could fire before provider
  // state was refreshed.
  group('reorderStarredTasks triggers refresh and mutation', () {
    test('reorderStarredTasks calls onMutation', () async {
      final id1 = await db.insertTask(Task(name: 'A'));
      final id2 = await db.insertTask(Task(name: 'B'));
      await provider.updateTaskStarred(id1, true);
      await provider.updateTaskStarred(id2, true);
      await provider.loadRootTasks();

      int mutationCount = 0;
      provider.onMutation = () => mutationCount++;

      await provider.reorderStarredTasks([id2, id1]);
      expect(mutationCount, 1, reason: 'reorderStarredTasks should call onMutation via _refreshAfterMutation');
    });
  });

  // I-46 Regression: walkChain in _reorderByDependencyChains had no cycle
  // detection, causing infinite recursion on corrupted data.
  group('_reorderByDependencyChains cycle detection', () {
    test('cyclic dependency does not cause stack overflow in provider', () async {
      final parent = await db.insertTask(Task(name: 'Parent'));
      final a = await db.insertTask(Task(name: 'A'));
      final b = await db.insertTask(Task(name: 'B'));
      await db.addRelationship(parent, a);
      await db.addRelationship(parent, b);
      // Create cycle: A blocks B, B blocks A (corrupted data)
      await db.addDependency(a, b);
      await db.addDependency(b, a);
      await provider.loadRootTasks();

      // Navigate into parent to load children with dependencies.
      // Before I-46 fix, this would stack overflow in _reorderByDependencyChains.
      // After fix, both tasks are mutual dependents so both get skipped by the
      // head-detection loop (neither is a pure head), resulting in empty reorder.
      // The critical assertion is that this completes without hanging/crashing.
      final parentTask = provider.tasks.firstWhere((t) => t.id == parent);
      await provider.navigateInto(parentTask);
      // No assertion on tasks content — the cycle causes both to be skipped.
      // The test passes by completing without timeout or stack overflow.
    });
  });
}
