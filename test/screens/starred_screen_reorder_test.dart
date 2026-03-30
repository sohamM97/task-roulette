import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/screens/starred_screen.dart';

void main() {
  group('reorderByDependencyChains', () {
    Task makeTask(int id, String name) =>
        Task(name: name, priority: 0).copyWith(id: id);

    // --- Mechanism tests: verify the reordering logic works correctly ---

    test('returns tasks unchanged when siblingDeps is empty', () {
      // Mechanism: no deps means no reordering
      final tasks = [makeTask(1, 'A'), makeTask(2, 'B'), makeTask(3, 'C')];
      final result = reorderByDependencyChains(tasks, {});
      expect(result.map((t) => t.id), [1, 2, 3]);
    });

    test('places blocked task immediately after its blocker', () {
      // Mechanism: single blocker→dependent pair reorders correctly
      // Task 2 is blocked by Task 1 (dep 2 → blocker 1)
      final tasks = [makeTask(1, 'Blocker'), makeTask(2, 'Blocked')];
      final result = reorderByDependencyChains(tasks, {2: 1});
      expect(result.map((t) => t.id), [1, 2]);
    });

    test('moves blocked task after blocker when originally before it', () {
      // Regression: if blocked task appears first in original order,
      // it should still end up after the blocker
      final tasks = [
        makeTask(3, 'Blocked'),
        makeTask(1, 'Unrelated'),
        makeTask(2, 'Blocker'),
      ];
      // Task 3 is blocked by Task 2
      final result = reorderByDependencyChains(tasks, {3: 2});
      final ids = result.map((t) => t.id).toList();
      // Blocker (2) must come before blocked (3)
      expect(ids.indexOf(2), lessThan(ids.indexOf(3)));
    });

    test('handles chain of dependencies (A blocks B blocks C)', () {
      // Mechanism: transitive chain ordering via walkChain
      final tasks = [makeTask(1, 'A'), makeTask(2, 'B'), makeTask(3, 'C')];
      // B blocked by A, C blocked by B
      final result = reorderByDependencyChains(tasks, {2: 1, 3: 2});
      expect(result.map((t) => t.id), [1, 2, 3]);
    });

    test('handles chain in reverse original order', () {
      // Regression: chain tasks in reverse order should still produce
      // blocker-first ordering
      final tasks = [makeTask(3, 'C'), makeTask(2, 'B'), makeTask(1, 'A')];
      // B blocked by A, C blocked by B
      final result = reorderByDependencyChains(tasks, {2: 1, 3: 2});
      expect(result.map((t) => t.id), [1, 2, 3]);
    });

    test('preserves unrelated tasks in original order', () {
      // Baseline: tasks not in any dependency should keep their relative order
      final tasks = [
        makeTask(5, 'X'),
        makeTask(1, 'Blocker'),
        makeTask(3, 'Y'),
        makeTask(2, 'Blocked'),
      ];
      // Only 2 is blocked by 1
      final result = reorderByDependencyChains(tasks, {2: 1});
      final ids = result.map((t) => t.id).toList();
      // X and Y should appear, and blocker before blocked
      expect(ids.indexOf(1), lessThan(ids.indexOf(2)));
      // All tasks present
      expect(ids.length, 4);
      expect(ids.toSet(), {5, 1, 3, 2});
    });

    test('handles blocker with multiple dependents', () {
      // Mechanism: one blocker with two dependents — both follow it
      final tasks = [
        makeTask(1, 'Blocker'),
        makeTask(2, 'Dep A'),
        makeTask(3, 'Dep B'),
      ];
      // Both 2 and 3 blocked by 1
      final result = reorderByDependencyChains(tasks, {2: 1, 3: 1});
      final ids = result.map((t) => t.id).toList();
      expect(ids.first, 1);
      // Both deps come after blocker
      expect(ids.indexOf(2), greaterThan(ids.indexOf(1)));
      expect(ids.indexOf(3), greaterThan(ids.indexOf(1)));
      expect(ids.length, 3);
    });

    // --- Edge case tests ---

    test('empty task list returns empty', () {
      // Edge case: no tasks at all
      final result = reorderByDependencyChains([], {2: 1});
      expect(result, isEmpty);
    });

    test('single task with no deps returns same list', () {
      // Edge case: single element
      final tasks = [makeTask(1, 'Solo')];
      final result = reorderByDependencyChains(tasks, {});
      expect(result.map((t) => t.id), [1]);
    });

    test('deps referencing tasks not in list are ignored gracefully', () {
      // Edge case: siblingDeps mentions IDs not present in tasks list
      final tasks = [makeTask(1, 'A'), makeTask(2, 'B')];
      // Task 99 (not in list) blocked by Task 1
      final result = reorderByDependencyChains(tasks, {99: 1});
      // Task 2 is a dependent (in dep map), but 99 is not in task list
      // The function should not crash and return available tasks
      expect(result.map((t) => t.id).toSet(), {1, 2});
    });

    test('multiple independent chains preserve relative chain order', () {
      // Mechanism: two separate chains in the same list
      final tasks = [
        makeTask(10, 'Chain1-Head'),
        makeTask(20, 'Chain2-Head'),
        makeTask(11, 'Chain1-Tail'),
        makeTask(21, 'Chain2-Tail'),
      ];
      // Chain 1: 11 blocked by 10; Chain 2: 21 blocked by 20
      final result =
          reorderByDependencyChains(tasks, {11: 10, 21: 20});
      final ids = result.map((t) => t.id).toList();
      // Each blocker before its dependent
      expect(ids.indexOf(10), lessThan(ids.indexOf(11)));
      expect(ids.indexOf(20), lessThan(ids.indexOf(21)));
      // Chain 1 head appeared before chain 2 head in original,
      // so chain 1 should come first
      expect(ids.indexOf(10), lessThan(ids.indexOf(20)));
    });

    test('deep chain of 4 tasks reorders correctly', () {
      // Edge case: deeper chain — A→B→C→D
      final tasks = [
        makeTask(4, 'D'),
        makeTask(2, 'B'),
        makeTask(1, 'A'),
        makeTask(3, 'C'),
      ];
      final result =
          reorderByDependencyChains(tasks, {2: 1, 3: 2, 4: 3});
      expect(result.map((t) => t.id), [1, 2, 3, 4]);
    });
  });
}
