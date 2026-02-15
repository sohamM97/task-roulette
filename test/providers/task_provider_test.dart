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

    test('navigateBack after navigateToTask returns to root', () async {
      final id = await db.insertTask(Task(name: 'Deep task'));

      await provider.loadRootTasks();
      final task = provider.tasks.firstWhere((t) => t.id == id);
      await provider.navigateToTask(task);

      expect(provider.currentParent!.id, id);

      await provider.navigateBack();
      expect(provider.currentParent, isNull);
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
}
