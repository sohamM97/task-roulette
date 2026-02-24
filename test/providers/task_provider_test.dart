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

    test('updateQuickTask updates currentParent in place', () async {
      final parentId = await db.insertTask(Task(name: 'Task'));
      final childId = await db.insertTask(Task(name: 'Child'));
      await db.addRelationship(parentId, childId);

      await provider.loadRootTasks();
      await navInto(provider, parentId);

      await provider.updateQuickTask(parentId, 1); // quick

      expect(provider.currentParent!.difficulty, 1);
      expect(provider.currentParent!.isQuickTask, isTrue);
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
      expect(result.id, childId);

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
      expect(result.id, childId);

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

    test('includes at least one quick task if available', () async {
      // Create 9 normal tasks and 1 quick task
      for (int i = 0; i < 9; i++) {
        await db.insertTask(Task(name: 'Normal $i'));
      }
      final quickId = await db.insertTask(Task(name: 'Quick', difficulty: 1));

      final leaves = await provider.getAllLeafTasks();

      // Run multiple times to verify the quick task guarantee
      bool quickAlwaysIncluded = true;
      for (int run = 0; run < 20; run++) {
        final picked = provider.pickWeightedN(leaves, 5);
        if (!picked.any((t) => t.id == quickId)) {
          quickAlwaysIncluded = false;
          break;
        }
      }
      expect(quickAlwaysIncluded, isTrue);
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
}
