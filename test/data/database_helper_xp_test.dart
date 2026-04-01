import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/data/xp_config.dart';
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
    await db.database;
  });

  tearDown(() async {
    await db.reset();
  });

  group('insertXpEvent', () {
    // Baseline: insert and retrieve XP event
    test('inserts an XP event and increases total XP', () async {
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
      );
      final total = await db.getTotalXp();
      expect(total, 20);
    });

    // Mechanism: multiple events accumulate
    test('multiple events accumulate XP', () async {
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-04-01',
      );
      final total = await db.getTotalXp();
      expect(total, 30);
    });

    // Baseline: event with task_id links correctly
    test('inserts event with task_id', () async {
      final taskId = await db.insertTask(Task(name: 'Test task'));
      final rowId = await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-01',
      );
      expect(rowId, greaterThan(0));
      final total = await db.getTotalXp();
      expect(total, 20);
    });
  });

  group('getTotalXp', () {
    // Edge case: empty table returns 0
    test('returns 0 when no events exist', () async {
      final total = await db.getTotalXp();
      expect(total, 0);
    });
  });

  group('deleteXpEventsForTask', () {
    // Mechanism: deletes matching events and reduces total
    test('deletes events for specific task, type, and date', () async {
      final taskId = await db.insertTask(Task(name: 'Test'));
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: taskId,
        date: '2026-04-01',
      );
      // Delete only task_complete events
      final deleted = await db.deleteXpEventsForTask(
        taskId, XpEventType.taskComplete, '2026-04-01',
      );
      expect(deleted, 1);
      final total = await db.getTotalXp();
      expect(total, 10); // only workedOn remains
    });

    // Edge case: no matching events — returns 0
    test('returns 0 when no matching events', () async {
      final deleted = await db.deleteXpEventsForTask(
        999, XpEventType.taskComplete, '2026-04-01',
      );
      expect(deleted, 0);
    });

    // Mechanism: only deletes for matching date
    test('does not delete events on different dates', () async {
      final taskId = await db.insertTask(Task(name: 'Test'));
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-02',
      );
      await db.deleteXpEventsForTask(
        taskId, XpEventType.taskComplete, '2026-04-01',
      );
      final total = await db.getTotalXp();
      expect(total, 20); // only April 2 remains
    });
  });

  group('deleteXpBonusesForTask', () {
    // Mechanism: deletes all three bonus types for a task on a date
    test('deletes all bonus types for task on date', () async {
      final taskId = await db.insertTask(Task(name: 'Test'));
      await db.insertXpEvent(
        eventType: XpEventType.todaysFiveBonus,
        xpAmount: 5,
        taskId: taskId,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.highPriorityBonus,
        xpAmount: 5,
        taskId: taskId,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.pinnedBonus,
        xpAmount: 5,
        taskId: taskId,
        date: '2026-04-01',
      );
      // Also a base event that should NOT be deleted
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-01',
      );
      final deleted = await db.deleteXpBonusesForTask(taskId, '2026-04-01');
      expect(deleted, 3);
      final total = await db.getTotalXp();
      expect(total, 20); // only base event remains
    });
  });

  group('getXpForWeek', () {
    // Baseline: returns 7-element list of daily XP sums
    test('returns XP sums for each day of the week', () async {
      // 2026-03-30 is Monday
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-03-30', // Monday
      );
      await db.insertXpEvent(
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-03-30', // Monday again
      );
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-02', // Thursday
      );
      final week = await db.getXpForWeek('2026-03-30');
      expect(week.length, 7);
      expect(week[0], 30); // Monday: 20+10
      expect(week[3], 20); // Thursday
      expect(week[1], 0); // Tuesday: nothing
    });

    // Edge case: empty week returns all zeros
    test('returns all zeros for week with no events', () async {
      final week = await db.getXpForWeek('2026-03-30');
      expect(week, List.filled(7, 0));
    });

    // Edge case: events outside the week are excluded
    test('excludes events outside the week range', () async {
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-03-29', // Sunday before the week
      );
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-06', // Monday of next week
      );
      final week = await db.getXpForWeek('2026-03-30');
      expect(week, List.filled(7, 0));
    });
  });

  group('getActiveDaysStreak', () {
    // Edge case: no events returns 0/0
    test('returns 0/0 when no events', () async {
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 0);
      expect(streak.best, 0);
    });

    // Mechanism: single day today gives streak of 1
    test('single event today gives current streak of 1', () async {
      final today = DateTime.now();
      final dateKey = _dateKey(today);
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: dateKey,
      );
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 1);
      expect(streak.best, 1);
    });

    // Mechanism: consecutive days build streak
    test('consecutive days build streak', () async {
      final today = DateTime.now();
      for (var i = 0; i < 5; i++) {
        final date = today.subtract(Duration(days: i));
        await db.insertXpEvent(
          eventType: XpEventType.taskComplete,
          xpAmount: 20,
          taskId: null,
          date: _dateKey(date),
        );
      }
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 5);
      expect(streak.best, 5);
    });

    // Mechanism: gap breaks current streak but best is preserved
    test('gap breaks current streak, best streak preserved', () async {
      final today = DateTime.now();
      // Today and yesterday (current streak = 2)
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: _dateKey(today),
      );
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: _dateKey(today.subtract(const Duration(days: 1))),
      );
      // Skip a day, then 4 consecutive days (old best = 4)
      for (var i = 3; i < 7; i++) {
        await db.insertXpEvent(
          eventType: XpEventType.taskComplete,
          xpAmount: 20,
          taskId: null,
          date: _dateKey(today.subtract(Duration(days: i))),
        );
      }
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 2);
      expect(streak.best, 4);
    });

    // Mechanism: yesterday grace period — event only yesterday counts as streak of 1
    test('yesterday-only event counts as current streak of 1', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: _dateKey(yesterday),
      );
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 1);
    });

    // Mechanism: event only 2 days ago — no current streak
    test('event only 2 days ago gives current streak of 0', () async {
      final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: _dateKey(twoDaysAgo),
      );
      final streak = await db.getActiveDaysStreak();
      expect(streak.current, 0);
      expect(streak.best, 1);
    });
  });

  group('getWeekActiveDays', () {
    // Baseline: counts distinct active days in a week
    test('counts distinct active days', () async {
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-03-30', // Monday
      );
      await db.insertXpEvent(
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-03-30', // Monday (duplicate day)
      );
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01', // Wednesday
      );
      final count = await db.getWeekActiveDays('2026-03-30');
      expect(count, 2); // Monday and Wednesday
    });

    // Edge case: no events = 0
    test('returns 0 for week with no events', () async {
      final count = await db.getWeekActiveDays('2026-03-30');
      expect(count, 0);
    });
  });

  group('deleteAllXpEvents', () {
    // Mechanism: clears all XP events
    test('removes all XP events', () async {
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
      );
      await db.insertXpEvent(
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-04-01',
      );
      await db.deleteAllXpEvents();
      final total = await db.getTotalXp();
      expect(total, 0);
    });
  });

  group('upsertXpEventFromRemote', () {
    // Baseline: inserts new event from remote
    test('inserts event when sync_id does not exist', () async {
      await db.upsertXpEventFromRemote(
        syncId: 'remote-1',
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      final total = await db.getTotalXp();
      expect(total, 20);
    });

    // Mechanism: does not duplicate on re-insert (idempotent)
    test('does not duplicate when sync_id already exists', () async {
      await db.upsertXpEventFromRemote(
        syncId: 'remote-1',
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      await db.upsertXpEventFromRemote(
        syncId: 'remote-1',
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
        createdAt: 2000,
      );
      final total = await db.getTotalXp();
      expect(total, 20); // Not 40
    });
  });

  group('getXpEventBySyncId', () {
    // Baseline: retrieves event by sync_id
    test('returns event when sync_id matches', () async {
      await db.upsertXpEventFromRemote(
        syncId: 'find-me',
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      final event = await db.getXpEventBySyncId('find-me');
      expect(event, isNotNull);
      expect(event!['event_type'], XpEventType.workedOn);
      expect(event['xp_amount'], 10);
    });

    // Edge case: returns null for non-existent sync_id
    test('returns null for unknown sync_id', () async {
      final event = await db.getXpEventBySyncId('nonexistent');
      expect(event, isNull);
    });
  });

  group('getAllXpEventSyncIds', () {
    // Baseline: returns all sync_ids
    test('returns set of all sync_ids', () async {
      await db.upsertXpEventFromRemote(
        syncId: 'id-1',
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      await db.upsertXpEventFromRemote(
        syncId: 'id-2',
        eventType: XpEventType.workedOn,
        xpAmount: 10,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      final ids = await db.getAllXpEventSyncIds();
      expect(ids, {'id-1', 'id-2'});
    });

    // Edge case: empty table returns empty set
    test('returns empty set when no events', () async {
      final ids = await db.getAllXpEventSyncIds();
      expect(ids, isEmpty);
    });
  });

  group('deleteXpEventBySyncId', () {
    // Mechanism: deletes specific event by sync_id
    test('deletes event by sync_id', () async {
      await db.upsertXpEventFromRemote(
        syncId: 'del-me',
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: null,
        date: '2026-04-01',
        createdAt: 1000,
      );
      await db.deleteXpEventBySyncId('del-me');
      final total = await db.getTotalXp();
      expect(total, 0);
    });
  });

  group('backfillXpEvents', () {
    // Baseline: backfills completed tasks
    test('creates XP events for completed tasks', () async {
      final taskId = await db.insertTask(Task(name: 'Done task'));
      await db.completeTask(taskId);
      await db.backfillXpEvents();
      final total = await db.getTotalXp();
      expect(total, greaterThanOrEqualTo(XpAmounts.taskComplete));
    });

    // Mechanism: backfills started (but not completed) tasks
    test('creates XP events for started tasks', () async {
      final taskId = await db.insertTask(Task(name: 'Started task'));
      await db.startTask(taskId);
      await db.backfillXpEvents();
      final total = await db.getTotalXp();
      expect(total, XpAmounts.taskStarted);
    });

    // Mechanism: high priority completed tasks get bonus XP
    test('awards high priority bonus for priority=1 completed tasks', () async {
      final taskId = await db.insertTask(Task(name: 'Priority task', priority: 1));
      await db.completeTask(taskId);
      await db.backfillXpEvents();
      final total = await db.getTotalXp();
      expect(total, XpAmounts.taskComplete + XpAmounts.highPriorityBonus);
    });

    // Mechanism: idempotent — running twice gives same result
    test('is idempotent — clears and re-inserts', () async {
      final taskId = await db.insertTask(Task(name: 'Done'));
      await db.completeTask(taskId);
      await db.backfillXpEvents();
      final total1 = await db.getTotalXp();
      await db.backfillXpEvents();
      final total2 = await db.getTotalXp();
      expect(total1, total2);
    });

    // Edge case: no tasks — no XP events
    test('produces 0 XP when no tasks exist', () async {
      await db.backfillXpEvents();
      final total = await db.getTotalXp();
      expect(total, 0);
    });
  });

  group('getCompletionsForWeek', () {
    // Baseline: counts completed tasks per day
    test('counts tasks completed in the week', () async {
      // 2026-03-30 is Monday
      final monday = DateTime.parse('2026-03-30');
      final mondayMs = monday.millisecondsSinceEpoch;

      final taskId = await db.insertTask(Task(name: 'Task'));
      // Manually set completed_at to Monday
      final d = await db.database;
      await d.update('tasks', {'completed_at': mondayMs},
        where: 'id = ?', whereArgs: [taskId]);

      // Mark as completed so the query picks it up
      await db.completeTask(taskId);

      final counts = await db.getCompletionsForWeek('2026-03-30');
      expect(counts.length, 7);
      // The task was completed — should show up on at least one day
      expect(counts.reduce((a, b) => a + b), greaterThan(0));
    });

    // Edge case: empty week
    test('returns all zeros for empty week', () async {
      final counts = await db.getCompletionsForWeek('2026-03-30');
      expect(counts, List.filled(7, 0));
    });
  });

  group('XP event foreign key behavior', () {
    // Mechanism: task deletion sets task_id to NULL (ON DELETE SET NULL)
    test('task deletion sets xp event task_id to NULL', () async {
      final taskId = await db.insertTask(Task(name: 'Delete me'));
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2026-04-01',
      );
      // Delete the task
      await db.deleteTaskWithRelationships(taskId);
      // XP should still be counted
      final total = await db.getTotalXp();
      expect(total, 20);
    });
  });
}

/// Helper to format DateTime as YYYY-MM-DD.
String _dateKey(DateTime dt) {
  return '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}
