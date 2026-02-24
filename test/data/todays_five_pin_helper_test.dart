import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/data/todays_five_pin_helper.dart';

/// Helper to build a TodaysFiveData with sensible defaults.
TodaysFiveData _state({
  List<int> taskIds = const [],
  Set<int> completedIds = const {},
  Set<int> workedOnIds = const {},
  Set<int> pinnedIds = const {},
}) {
  return TodaysFiveData(
    date: '2026-02-24',
    taskIds: taskIds,
    completedIds: completedIds,
    workedOnIds: workedOnIds,
    pinnedIds: pinnedIds,
  );
}

void main() {
  group('togglePin', () {
    test('pin a task already in the list', () {
      final state = _state(taskIds: [1, 2, 3, 4, 5]);
      final result = TodaysFivePinHelper.togglePin(state, 3);
      expect(result, isNotNull);
      expect(result!.pinnedIds, {3});
      expect(result.taskIds, [1, 2, 3, 4, 5]); // unchanged
    });

    test('unpin a pinned task', () {
      final state = _state(
        taskIds: [1, 2, 3],
        pinnedIds: {1, 3},
      );
      final result = TodaysFivePinHelper.togglePin(state, 1);
      expect(result, isNotNull);
      expect(result!.pinnedIds, {3});
      expect(result.taskIds, [1, 2, 3]);
    });

    test('pin external task replaces last unpinned undone slot', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1},
      );
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNotNull);
      // Replaces slot 4 (index 4, last unpinned undone)
      expect(result!.taskIds, [1, 2, 3, 4, 99]);
      expect(result.taskIds, isNot(contains(5)));
      expect(result.pinnedIds, {1, 99});
    });

    test('pin external task skips completed and pinned when finding slot', () {
      // [1=pinned, 2=done, 3=unpinned, 4=unpinned, 5=done]
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        completedIds: {2, 5},
        pinnedIds: {1},
      );
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNotNull);
      // Should replace 4 (last unpinned undone, searching from end)
      expect(result!.taskIds[3], 99);
      expect(result.taskIds, contains(3)); // 3 kept
    });

    test('pin external task appends when all slots done or pinned', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        completedIds: {3, 4, 5},
        pinnedIds: {1, 2},
      );
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNotNull);
      expect(result!.taskIds.length, 6);
      expect(result.taskIds.last, 99);
    });

    test('append respects maxSlots (10)', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        completedIds: {1, 2, 3, 4, 5, 6, 7, 8, 9},
      );
      // 9 slots, all completed — append to 10 should work
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNotNull);
      expect(result!.taskIds.length, 10);
    });

    test('blocks when 10 slots full and no replaceable slot', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        completedIds: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
      );
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNull);
    });

    test('blocks when already at max 5 pins', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1, 2, 3, 4, 5},
      );
      final result = TodaysFivePinHelper.togglePin(state, 99);
      expect(result, isNull);
    });

    test('unpin still works even when at max pins', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1, 2, 3, 4, 5},
      );
      // Unpinning should always work
      final result = TodaysFivePinHelper.togglePin(state, 3);
      expect(result, isNotNull);
      expect(result!.pinnedIds, {1, 2, 4, 5});
    });

    test('pin then unpin is a round-trip', () {
      final state = _state(taskIds: [1, 2, 3]);
      final pinned = TodaysFivePinHelper.togglePin(state, 2)!;
      expect(pinned.pinnedIds, {2});

      // Build new state from result
      final state2 = _state(
        taskIds: pinned.taskIds,
        pinnedIds: pinned.pinnedIds,
      );
      final unpinned = TodaysFivePinHelper.togglePin(state2, 2)!;
      expect(unpinned.pinnedIds, isEmpty);
    });

    test('does not modify original state', () {
      final original = _state(taskIds: [1, 2, 3]);
      TodaysFivePinHelper.togglePin(original, 2);
      expect(original.pinnedIds, isEmpty); // original unchanged
    });

    test('unpin shrinks list back when over 5 tasks', () {
      // 7 tasks: 5 original + 2 appended via pin
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6, 7],
        pinnedIds: {6, 7},
        completedIds: {1, 2, 3, 4, 5},
      );
      final result = TodaysFivePinHelper.togglePin(state, 6);
      expect(result, isNotNull);
      expect(result!.pinnedIds, {7});
      // 6 was unpinned and undone → removed from list
      expect(result.taskIds, isNot(contains(6)));
      expect(result.taskIds.length, 6);
    });

    test('unpin does not shrink list at exactly 5 tasks', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {3},
      );
      final result = TodaysFivePinHelper.togglePin(state, 3);
      expect(result, isNotNull);
      // Still 5 — no shrink
      expect(result!.taskIds.length, 5);
      expect(result.taskIds, contains(3));
    });

    test('unpin does not remove completed task even when over 5', () {
      // 6 tasks: 5 pinned, task 6 is both pinned and completed
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6],
        pinnedIds: {1, 2, 3, 4, 6},
        completedIds: {6},
      );
      final result = TodaysFivePinHelper.togglePin(state, 6);
      expect(result, isNotNull);
      // 6 is completed → kept despite unpin; 5 is unpinned undone → trimmed
      expect(result!.taskIds, contains(6));
      expect(result.taskIds.length, 5);
    });

    test('unpinning all shrinks list back to 5', () {
      // Started with 5, appended 3 pinned tasks → 8 total
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6, 7, 8],
        completedIds: {1, 2, 3, 4, 5},
        pinnedIds: {6, 7, 8},
      );
      // Unpin 8 → list shrinks to 7
      var result = TodaysFivePinHelper.togglePin(state, 8)!;
      expect(result.taskIds.length, 7);

      // Unpin 7 → list shrinks to 6
      var next = _state(
        taskIds: result.taskIds,
        completedIds: {1, 2, 3, 4, 5},
        pinnedIds: result.pinnedIds,
      );
      result = TodaysFivePinHelper.togglePin(next, 7)!;
      expect(result.taskIds.length, 6);

      // Unpin 6 → list shrinks to 5
      next = _state(
        taskIds: result.taskIds,
        completedIds: {1, 2, 3, 4, 5},
        pinnedIds: result.pinnedIds,
      );
      result = TodaysFivePinHelper.togglePin(next, 6)!;
      expect(result.taskIds.length, 5);
      expect(result.pinnedIds, isEmpty);
    });
  });

  group('trimExcess', () {
    test('no-op when list has 5 or fewer items', () {
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5], {}, {},
      );
      expect(result, [1, 2, 3, 4, 5]);
    });

    test('removes unpinned undone tasks from end when over 5', () {
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7], {}, {1, 2, 3, 4, 5},
      );
      // 6 and 7 are unpinned and undone → removed
      expect(result, [1, 2, 3, 4, 5]);
    });

    test('keeps completed tasks even when over 5', () {
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7], {6, 7}, {1, 2, 3, 4, 5},
      );
      // 6 and 7 are completed → kept
      expect(result.length, 7);
    });

    test('keeps pinned tasks even when over 5', () {
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7], {}, {1, 2, 3, 4, 5, 6, 7},
      );
      expect(result.length, 7);
    });

    test('trims only enough to reach 5', () {
      // 8 tasks, 5 pinned, 3 unpinned undone → trim 3
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7, 8], {}, {1, 2, 3, 4, 5},
      );
      expect(result, [1, 2, 3, 4, 5]);
    });

    test('mixed: keeps pinned+completed, trims unpinned undone', () {
      // 7 tasks: 3 pinned, 1 completed, 3 unpinned undone
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7], {4}, {1, 2, 3},
      );
      // Should keep 1,2,3 (pinned) + 4 (completed) = 4 protected
      // Trim 5,6,7 from end → but only until length is 5
      // So remove 7, then 6 → length 5
      expect(result.length, 5);
      expect(result, contains(1));
      expect(result, contains(2));
      expect(result, contains(3));
      expect(result, contains(4));
    });

    test('after uncompleting pinned tasks, excess unpinned are trimmed', () {
      // Simulates the user's bug: 5 pinned, 2 done, list has 7
      // After uncompleting 2, those 2 unpinned non-done extras should go
      // The 5 pinned remain, the 2 extras (unpinned, now undone) get trimmed
      final result = TodaysFivePinHelper.trimExcess(
        [1, 2, 3, 4, 5, 6, 7], {}, {1, 2, 3, 4, 5},
      );
      expect(result, [1, 2, 3, 4, 5]);
    });
  });

  group('pinNewTask', () {
    test('replaces last unpinned undone slot', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1},
      );
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNotNull);
      expect(result!.taskIds, contains(99));
      expect(result.taskIds, isNot(contains(5))); // replaced
      expect(result.pinnedIds, {1, 99});
    });

    test('result taskIds can be used to update all caches consistently', () {
      // Verifies that the result contains everything needed to update
      // both _todays5TaskIds and _todaysFiveIds (Codex bug: missing cache update)
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1},
      );
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNotNull);
      final resultTaskIdSet = result!.taskIds.toSet();
      // The new task must be in the set
      expect(resultTaskIdSet, contains(99));
      // The replaced task must NOT be in the set
      expect(resultTaskIdSet, isNot(contains(5)));
      // pinnedIds is a subset of taskIds
      expect(resultTaskIdSet.containsAll(result.pinnedIds), isTrue);
    });

    test('appends when no replaceable slot', () {
      final state = _state(
        taskIds: [1, 2, 3],
        completedIds: {2, 3},
        pinnedIds: {1},
      );
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNotNull);
      expect(result!.taskIds.length, 4);
      expect(result.taskIds.last, 99);
    });

    test('blocked when already 5 pins', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1, 2, 3, 4, 5},
      );
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNull);
    });

    test('blocked when 10 slots full and no replaceable', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        completedIds: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
        pinnedIds: {1, 2},
      );
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNull);
    });

    test('works with empty initial list', () {
      final state = _state(taskIds: []);
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNotNull);
      expect(result!.taskIds, [99]);
      expect(result.pinnedIds, {99});
    });

    test('can pin up to 5 new tasks sequentially', () {
      var state = _state(taskIds: [1, 2, 3, 4, 5]);
      final newIds = [10, 20, 30, 40, 50];
      for (final id in newIds) {
        final result = TodaysFivePinHelper.pinNewTask(state, id);
        expect(result, isNotNull, reason: 'Should be able to pin task $id');
        state = _state(
          taskIds: result!.taskIds,
          pinnedIds: result.pinnedIds,
        );
      }
      // All 5 original replaced, 5 new pinned
      expect(state.pinnedIds.length, 5);
      expect(state.taskIds.toSet(), newIds.toSet());

      // 6th should fail
      final result = TodaysFivePinHelper.pinNewTask(state, 60);
      expect(result, isNull);
    });
  });

  group('togglePinInPlace', () {
    test('pin a task', () {
      final result = TodaysFivePinHelper.togglePinInPlace({1, 2}, 3);
      expect(result, {1, 2, 3});
    });

    test('unpin a task', () {
      final result = TodaysFivePinHelper.togglePinInPlace({1, 2, 3}, 2);
      expect(result, {1, 3});
    });

    test('blocked at max 5 pins', () {
      final result = TodaysFivePinHelper.togglePinInPlace(
        {1, 2, 3, 4, 5}, 6,
      );
      expect(result, isNull);
    });

    test('unpin works even at max', () {
      final result = TodaysFivePinHelper.togglePinInPlace(
        {1, 2, 3, 4, 5}, 3,
      );
      expect(result, {1, 2, 4, 5});
    });

    test('does not modify original set', () {
      final original = {1, 2};
      TodaysFivePinHelper.togglePinInPlace(original, 3);
      expect(original, {1, 2}); // unchanged
    });

    test('pin from empty set', () {
      final result = TodaysFivePinHelper.togglePinInPlace(<int>{}, 1);
      expect(result, {1});
    });
  });

  group('pinNewTask — add task dialog gate', () {
    // The add task dialog's pin option is hidden when pinnedIds.length >= maxPins.
    // This group tests that pinNewTask correctly blocks at the limit,
    // which is the same condition used to gate the UI option.

    test('pinNewTask blocked at exactly maxPins pins', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1, 2, 3, 4, 5},
      );
      expect(state.pinnedIds.length >= maxPins, isTrue);
      expect(TodaysFivePinHelper.pinNewTask(state, 99), isNull);
    });

    test('pinNewTask allowed at maxPins - 1 pins', () {
      final state = _state(
        taskIds: [1, 2, 3, 4, 5],
        pinnedIds: {1, 2, 3, 4},
      );
      expect(state.pinnedIds.length < maxPins, isTrue);
      final result = TodaysFivePinHelper.pinNewTask(state, 99);
      expect(result, isNotNull);
      expect(result!.pinnedIds, {1, 2, 3, 4, 99});
    });
  });

  group('bottom sheet pin/unpin gate', () {
    // The Today's 5 bottom sheet shows "Pin" when pinnedIds.length < maxPins
    // and "Unpin" when the task is already pinned (regardless of count).
    // These tests validate the gate logic.

    test('pin option available when under maxPins', () {
      final pinnedIds = {1, 2};
      final taskId = 3;
      // Gate: !pinnedIds.contains(taskId) && pinnedIds.length < maxPins
      expect(pinnedIds.contains(taskId), isFalse);
      expect(pinnedIds.length < maxPins, isTrue);
      // togglePinInPlace should succeed
      final result = TodaysFivePinHelper.togglePinInPlace(pinnedIds, taskId);
      expect(result, isNotNull);
      expect(result, contains(taskId));
    });

    test('pin option hidden when at maxPins', () {
      final pinnedIds = {1, 2, 3, 4, 5};
      final taskId = 6;
      // Gate: pinnedIds.length < maxPins → false, so "Pin" is not shown
      expect(pinnedIds.length < maxPins, isFalse);
      // togglePinInPlace would also block
      expect(TodaysFivePinHelper.togglePinInPlace(pinnedIds, taskId), isNull);
    });

    test('unpin option always shown for pinned task even at maxPins', () {
      final pinnedIds = {1, 2, 3, 4, 5};
      final taskId = 3;
      // Gate: pinnedIds.contains(taskId) → true, so "Unpin" is shown
      expect(pinnedIds.contains(taskId), isTrue);
      // togglePinInPlace should succeed (unpin)
      final result = TodaysFivePinHelper.togglePinInPlace(pinnedIds, taskId);
      expect(result, isNotNull);
      expect(result, isNot(contains(taskId)));
    });
  });

  group('constants', () {
    test('maxPins is 5', () {
      expect(maxPins, 5);
    });

    test('maxSlots is 10', () {
      expect(maxSlots, 10);
    });
  });
}
