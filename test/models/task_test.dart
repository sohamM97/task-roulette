import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';

void main() {
  group('Task model', () {
    test('creates with default createdAt', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final task = Task(name: 'Test');
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(task.name, 'Test');
      expect(task.id, isNull);
      expect(task.completedAt, isNull);
      expect(task.createdAt, greaterThanOrEqualTo(before));
      expect(task.createdAt, lessThanOrEqualTo(after));
    });

    test('creates with explicit createdAt and completedAt', () {
      final task = Task(
        id: 1,
        name: 'Done task',
        createdAt: 1000,
        completedAt: 2000,
      );

      expect(task.id, 1);
      expect(task.createdAt, 1000);
      expect(task.completedAt, 2000);
    });

    test('isCompleted returns true when completedAt is set', () {
      final task = Task(name: 'Done', completedAt: 12345);
      expect(task.isCompleted, isTrue);
    });

    test('isCompleted returns false when completedAt is null', () {
      final task = Task(name: 'Pending');
      expect(task.isCompleted, isFalse);
    });

    test('toMap includes completedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, completedAt: 200);
      final map = task.toMap();

      expect(map['id'], 1);
      expect(map['name'], 'T');
      expect(map['created_at'], 100);
      expect(map['completed_at'], 200);
    });

    test('toMap includes null completedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();

      expect(map.containsKey('completed_at'), isTrue);
      expect(map['completed_at'], isNull);
    });

    test('fromMap parses completedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Archived',
        'created_at': 1000,
        'completed_at': 2000,
      });

      expect(task.id, 5);
      expect(task.name, 'Archived');
      expect(task.completedAt, 2000);
      expect(task.isCompleted, isTrue);
    });

    test('fromMap handles null completedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Open',
        'created_at': 1000,
        'completed_at': null,
      });

      expect(task.completedAt, isNull);
      expect(task.isCompleted, isFalse);
    });

    test('toMap/fromMap round-trip preserves all fields', () {
      final original = Task(id: 7, name: 'Round trip', createdAt: 999, completedAt: 1500);
      final restored = Task.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.createdAt, original.createdAt);
      expect(restored.completedAt, original.completedAt);
    });

    test('isStarted returns true when startedAt is set and not completed', () {
      final task = Task(name: 'In progress', startedAt: 12345);
      expect(task.isStarted, isTrue);
    });

    test('isStarted returns false when startedAt is null', () {
      final task = Task(name: 'Not started');
      expect(task.isStarted, isFalse);
    });

    test('isStarted returns false when both startedAt and completedAt are set', () {
      final task = Task(name: 'Done', startedAt: 1000, completedAt: 2000);
      expect(task.isStarted, isFalse);
      expect(task.isCompleted, isTrue);
    });

    test('toMap includes startedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, startedAt: 300);
      final map = task.toMap();

      expect(map['started_at'], 300);
    });

    test('toMap includes null startedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();

      expect(map.containsKey('started_at'), isTrue);
      expect(map['started_at'], isNull);
    });

    test('fromMap parses startedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'WIP',
        'created_at': 1000,
        'completed_at': null,
        'started_at': 1500,
      });

      expect(task.startedAt, 1500);
      expect(task.isStarted, isTrue);
    });

    test('fromMap handles null startedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Open',
        'created_at': 1000,
        'completed_at': null,
        'started_at': null,
      });

      expect(task.startedAt, isNull);
      expect(task.isStarted, isFalse);
    });

    test('toMap/fromMap round-trip preserves startedAt', () {
      final original = Task(id: 8, name: 'Round trip', createdAt: 999, startedAt: 1200);
      final restored = Task.fromMap(original.toMap());

      expect(restored.startedAt, original.startedAt);
      expect(restored.isStarted, isTrue);
    });

    test('isSkipped returns true when skippedAt is set', () {
      final task = Task(name: 'Nah', skippedAt: 12345);
      expect(task.isSkipped, isTrue);
    });

    test('isSkipped returns false when skippedAt is null', () {
      final task = Task(name: 'Active');
      expect(task.isSkipped, isFalse);
    });

    test('toMap includes skippedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, skippedAt: 400);
      final map = task.toMap();

      expect(map['skipped_at'], 400);
    });

    test('toMap includes null skippedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();

      expect(map.containsKey('skipped_at'), isTrue);
      expect(map['skipped_at'], isNull);
    });

    test('fromMap parses skippedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Skipped',
        'created_at': 1000,
        'completed_at': null,
        'started_at': null,
        'skipped_at': 2000,
      });

      expect(task.skippedAt, 2000);
      expect(task.isSkipped, isTrue);
    });

    test('fromMap handles null skippedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Open',
        'created_at': 1000,
        'completed_at': null,
        'started_at': null,
        'skipped_at': null,
      });

      expect(task.skippedAt, isNull);
      expect(task.isSkipped, isFalse);
    });

    test('toMap/fromMap round-trip preserves skippedAt', () {
      final original = Task(id: 9, name: 'Round trip', createdAt: 999, skippedAt: 1800);
      final restored = Task.fromMap(original.toMap());

      expect(restored.skippedAt, original.skippedAt);
      expect(restored.isSkipped, isTrue);
    });

    test('defaults priority to 0 (Normal)', () {
      final task = Task(name: 'Test');
      expect(task.priority, 0);
      expect(task.priorityLabel, 'Normal');
    });

    test('priorityLabel returns correct labels', () {
      expect(Task(name: 'T', priority: 0).priorityLabel, 'Normal');
      expect(Task(name: 'T', priority: 1).priorityLabel, 'High');
    });

    test('toMap includes priority', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, priority: 1);
      final map = task.toMap();

      expect(map['priority'], 1);
    });

    test('toMap includes default priority', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();

      expect(map['priority'], 0);
    });

    test('fromMap parses priority', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'High',
        'created_at': 1000,
        'completed_at': null,
        'started_at': null,
        'skipped_at': null,
        'priority': 1,
      });

      expect(task.priority, 1);
    });

    test('fromMap defaults priority when missing', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Old',
        'created_at': 1000,
        'completed_at': null,
      });

      expect(task.priority, 0);
    });

    test('toMap/fromMap round-trip preserves priority', () {
      final original = Task(id: 10, name: 'Round trip', createdAt: 999, priority: 1);
      final restored = Task.fromMap(original.toMap());

      expect(restored.priority, original.priority);
    });

    // --- lastWorkedAt tests ---

    test('isWorkedOnToday returns false when lastWorkedAt is null', () {
      final task = Task(name: 'Test');
      expect(task.isWorkedOnToday, isFalse);
    });

    test('isWorkedOnToday returns true when lastWorkedAt is today', () {
      final task = Task(
        name: 'Test',
        lastWorkedAt: DateTime.now().millisecondsSinceEpoch,
      );
      expect(task.isWorkedOnToday, isTrue);
    });

    test('isWorkedOnToday returns false when lastWorkedAt is yesterday', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final task = Task(name: 'Test', lastWorkedAt: yesterday.millisecondsSinceEpoch);
      expect(task.isWorkedOnToday, isFalse);
    });

    test('toMap includes lastWorkedAt', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, lastWorkedAt: 500);
      final map = task.toMap();
      expect(map['last_worked_at'], 500);
    });

    test('fromMap parses lastWorkedAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'WIP',
        'created_at': 1000,
        'last_worked_at': 2000,
      });
      expect(task.lastWorkedAt, 2000);
    });

    // --- Repeating task fields (DB columns exist but no UI/provider code uses them) ---

    test('toMap includes repeatInterval and nextDueAt', () {
      final task = Task(
        id: 1,
        name: 'T',
        createdAt: 100,
        repeatInterval: 'weekly',
        nextDueAt: 999,
      );
      final map = task.toMap();
      expect(map['repeat_interval'], 'weekly');
      expect(map['next_due_at'], 999);
    });

    test('fromMap parses repeatInterval and nextDueAt', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Repeat',
        'created_at': 1000,
        'repeat_interval': 'monthly',
        'next_due_at': 5000,
      });
      expect(task.repeatInterval, 'monthly');
      expect(task.nextDueAt, 5000);
      expect(task.repeatInterval, 'monthly');
    });

    test('toMap/fromMap round-trip preserves all new fields', () {
      final original = Task(
        id: 11,
        name: 'Full round trip',
        createdAt: 999,
        lastWorkedAt: 1500,
        repeatInterval: 'biweekly',
        nextDueAt: 2000,
      );
      final restored = Task.fromMap(original.toMap());

      expect(restored.lastWorkedAt, original.lastWorkedAt);
      expect(restored.repeatInterval, original.repeatInterval);
      expect(restored.nextDueAt, original.nextDueAt);
    });

    // --- Sync fields ---

    test('creates with default sync fields', () {
      final task = Task(name: 'Sync test');
      expect(task.syncId, isNull);
      expect(task.updatedAt, isNull);
      expect(task.syncStatus, 'synced');
    });

    test('creates with explicit sync fields', () {
      final task = Task(
        name: 'Sync test',
        syncId: 'abc-123',
        updatedAt: 5000,
        syncStatus: 'pending',
      );
      expect(task.syncId, 'abc-123');
      expect(task.updatedAt, 5000);
      expect(task.syncStatus, 'pending');
    });

    test('toMap includes sync fields', () {
      final task = Task(
        id: 1,
        name: 'T',
        createdAt: 100,
        syncId: 'uuid-here',
        updatedAt: 200,
        syncStatus: 'pending',
      );
      final map = task.toMap();
      expect(map['sync_id'], 'uuid-here');
      expect(map['updated_at'], 200);
      expect(map['sync_status'], 'pending');
    });

    test('toMap includes null sync_id and updated_at', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();
      expect(map['sync_id'], isNull);
      expect(map['updated_at'], isNull);
      expect(map['sync_status'], 'synced');
    });

    test('fromMap parses sync fields', () {
      final task = Task.fromMap({
        'id': 1,
        'name': 'T',
        'created_at': 100,
        'sync_id': 'my-uuid',
        'updated_at': 300,
        'sync_status': 'pending',
      });
      expect(task.syncId, 'my-uuid');
      expect(task.updatedAt, 300);
      expect(task.syncStatus, 'pending');
    });

    test('fromMap defaults sync_status to synced when missing', () {
      final task = Task.fromMap({
        'id': 1,
        'name': 'T',
        'created_at': 100,
      });
      expect(task.syncStatus, 'synced');
    });

    test('copyWith updates sync fields', () {
      final task = Task(
        name: 'T',
        syncId: 'old-id',
        updatedAt: 100,
        syncStatus: 'synced',
      );
      final updated = task.copyWith(
        syncId: 'new-id',
        updatedAt: 200,
        syncStatus: 'pending',
      );
      expect(updated.syncId, 'new-id');
      expect(updated.updatedAt, 200);
      expect(updated.syncStatus, 'pending');
    });

    test('copyWith preserves sync fields when not specified', () {
      final task = Task(
        name: 'T',
        syncId: 'keep-me',
        updatedAt: 100,
        syncStatus: 'pending',
      );
      final updated = task.copyWith(name: 'New name');
      expect(updated.syncId, 'keep-me');
      expect(updated.updatedAt, 100);
      expect(updated.syncStatus, 'pending');
      expect(updated.name, 'New name');
    });

    test('toMap/fromMap round-trip preserves sync fields', () {
      final original = Task(
        id: 20,
        name: 'Sync round trip',
        createdAt: 999,
        syncId: 'round-trip-uuid',
        updatedAt: 1234,
        syncStatus: 'deleted',
      );
      final restored = Task.fromMap(original.toMap());

      expect(restored.syncId, original.syncId);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.syncStatus, original.syncStatus);
    });
  });

  group('Someday field', () {
    test('defaults to false', () {
      final task = Task(name: 'T');
      expect(task.isSomeday, isFalse);
    });

    test('creates with isSomeday true', () {
      final task = Task(name: 'T', isSomeday: true);
      expect(task.isSomeday, isTrue);
    });

    test('toMap stores isSomeday as integer', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, isSomeday: true);
      expect(task.toMap()['is_someday'], 1);

      final task2 = Task(id: 2, name: 'T2', createdAt: 100, isSomeday: false);
      expect(task2.toMap()['is_someday'], 0);
    });

    test('fromMap parses is_someday', () {
      final task = Task.fromMap({
        'id': 1, 'name': 'T', 'created_at': 100, 'is_someday': 1,
      });
      expect(task.isSomeday, isTrue);

      final task2 = Task.fromMap({
        'id': 2, 'name': 'T2', 'created_at': 100, 'is_someday': 0,
      });
      expect(task2.isSomeday, isFalse);
    });

    test('fromMap defaults is_someday to false when missing', () {
      final task = Task.fromMap({'id': 1, 'name': 'T', 'created_at': 100});
      expect(task.isSomeday, isFalse);
    });

    test('copyWith updates isSomeday', () {
      final task = Task(name: 'T', isSomeday: false);
      final updated = task.copyWith(isSomeday: true);
      expect(updated.isSomeday, isTrue);
    });

    test('copyWith preserves isSomeday when not specified', () {
      final task = Task(name: 'T', isSomeday: true);
      final updated = task.copyWith(name: 'New');
      expect(updated.isSomeday, isTrue);
    });

    test('toMap/fromMap round-trip preserves isSomeday', () {
      final original = Task(id: 1, name: 'T', createdAt: 100, isSomeday: true);
      final restored = Task.fromMap(original.toMap());
      expect(restored.isSomeday, original.isSomeday);
    });
  });

  group('isInbox', () {
    test('defaults to false', () {
      final task = Task(name: 'T');
      expect(task.isInbox, isFalse);
    });

    test('toMap/fromMap round-trip preserves isInbox', () {
      final original = Task(id: 1, name: 'T', createdAt: 100, isInbox: true);
      final map = original.toMap();
      expect(map['is_inbox'], 1);
      final restored = Task.fromMap(map);
      expect(restored.isInbox, isTrue);
    });

    test('fromMap defaults to false when is_inbox is missing', () {
      final task = Task.fromMap({
        'id': 1,
        'name': 'T',
        'created_at': 100,
      });
      expect(task.isInbox, isFalse);
    });

    test('copyWith can set isInbox', () {
      final task = Task(name: 'T');
      final updated = task.copyWith(isInbox: true);
      expect(updated.isInbox, isTrue);
    });

    test('copyWith preserves isInbox when not specified', () {
      final task = Task(name: 'T', isInbox: true);
      final updated = task.copyWith(name: 'New');
      expect(updated.isInbox, isTrue);
    });
  });

  group('Deadline field', () {
    test('defaults to null', () {
      final task = Task(name: 'T');
      expect(task.deadline, isNull);
    });

    test('creates with deadline set', () {
      final task = Task(name: 'T', deadline: '2026-03-20');
      expect(task.deadline, '2026-03-20');
    });

    test('toMap includes deadline when set', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, deadline: '2026-03-20');
      final map = task.toMap();
      expect(map['deadline'], '2026-03-20');
    });

    test('toMap includes null deadline', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();
      expect(map.containsKey('deadline'), isTrue);
      expect(map['deadline'], isNull);
    });

    test('fromMap parses deadline', () {
      final task = Task.fromMap({
        'id': 1, 'name': 'T', 'created_at': 100, 'deadline': '2026-03-20',
      });
      expect(task.deadline, '2026-03-20');
    });

    test('fromMap handles null deadline', () {
      final task = Task.fromMap({
        'id': 1, 'name': 'T', 'created_at': 100, 'deadline': null,
      });
      expect(task.deadline, isNull);
    });

    test('fromMap handles missing deadline key', () {
      final task = Task.fromMap({
        'id': 1, 'name': 'T', 'created_at': 100,
      });
      expect(task.deadline, isNull);
    });

    test('toMap/fromMap round-trip with deadline set', () {
      final original = Task(id: 1, name: 'T', createdAt: 100, deadline: '2026-12-31');
      final restored = Task.fromMap(original.toMap());
      expect(restored.deadline, '2026-12-31');
    });

    test('toMap/fromMap round-trip with deadline null', () {
      final original = Task(id: 1, name: 'T', createdAt: 100);
      final restored = Task.fromMap(original.toMap());
      expect(restored.deadline, isNull);
    });

    test('copyWith sets deadline', () {
      final task = Task(name: 'T');
      final updated = task.copyWith(deadline: () => '2026-06-15');
      expect(updated.deadline, '2026-06-15');
    });

    test('copyWith clears deadline via () => null', () {
      final task = Task(name: 'T', deadline: '2026-06-15');
      final updated = task.copyWith(deadline: () => null);
      expect(updated.deadline, isNull);
    });

    test('copyWith preserves deadline when not specified', () {
      final task = Task(name: 'T', deadline: '2026-06-15');
      final updated = task.copyWith(name: 'New');
      expect(updated.deadline, '2026-06-15');
    });

    test('hasDeadline returns true when deadline is set', () {
      final task = Task(name: 'T', deadline: '2026-03-20');
      expect(task.hasDeadline, isTrue);
    });

    test('hasDeadline returns false when deadline is null', () {
      final task = Task(name: 'T');
      expect(task.hasDeadline, isFalse);
    });

    test('hasDeadline returns false when deadline is empty string', () {
      final task = Task(name: 'T', deadline: '');
      expect(task.hasDeadline, isFalse);
    });

    test('deadlineDate parses valid YYYY-MM-DD', () {
      final task = Task(name: 'T', deadline: '2026-03-20');
      final date = task.deadlineDate;
      expect(date, isNotNull);
      expect(date!.year, 2026);
      expect(date.month, 3);
      expect(date.day, 20);
    });

    test('deadlineDate returns null when deadline is null', () {
      final task = Task(name: 'T');
      expect(task.deadlineDate, isNull);
    });

    test('deadlineDate returns null for invalid date string', () {
      final task = Task(name: 'T', deadline: 'not-a-date');
      expect(task.deadlineDate, isNull);
    });

    test('daysUntilDeadline returns positive for future deadline', () {
      final futureDate = DateTime.now().add(const Duration(days: 5));
      final dateStr = '${futureDate.year}-${futureDate.month.toString().padLeft(2, '0')}-${futureDate.day.toString().padLeft(2, '0')}';
      final task = Task(name: 'T', deadline: dateStr);
      expect(task.daysUntilDeadline, 5);
    });

    test('daysUntilDeadline returns 0 for today', () {
      final today = DateTime.now();
      final dateStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final task = Task(name: 'T', deadline: dateStr);
      expect(task.daysUntilDeadline, 0);
    });

    test('daysUntilDeadline returns negative for overdue', () {
      final pastDate = DateTime.now().subtract(const Duration(days: 3));
      final dateStr = '${pastDate.year}-${pastDate.month.toString().padLeft(2, '0')}-${pastDate.day.toString().padLeft(2, '0')}';
      final task = Task(name: 'T', deadline: dateStr);
      expect(task.daysUntilDeadline, -3);
    });

    test('daysUntilDeadline returns null when no deadline', () {
      final task = Task(name: 'T');
      expect(task.daysUntilDeadline, isNull);
    });
  });

  group('Starred fields', () {
    test('defaults isStarred to false and starOrder to null', () {
      final task = Task(name: 'T');
      expect(task.isStarred, isFalse);
      expect(task.starOrder, isNull);
    });

    test('creates with isStarred true and starOrder', () {
      final task = Task(name: 'T', isStarred: true, starOrder: 3);
      expect(task.isStarred, isTrue);
      expect(task.starOrder, 3);
    });

    test('toMap stores isStarred as integer', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, isStarred: true, starOrder: 5);
      expect(task.toMap()['is_starred'], 1);
      expect(task.toMap()['star_order'], 5);

      final task2 = Task(id: 2, name: 'T2', createdAt: 100);
      expect(task2.toMap()['is_starred'], 0);
      expect(task2.toMap()['star_order'], isNull);
    });

    test('fromMap parses is_starred and star_order', () {
      final task = Task.fromMap({
        'id': 1, 'name': 'T', 'created_at': 100,
        'is_starred': 1, 'star_order': 7,
      });
      expect(task.isStarred, isTrue);
      expect(task.starOrder, 7);

      final task2 = Task.fromMap({
        'id': 2, 'name': 'T2', 'created_at': 100,
        'is_starred': 0, 'star_order': null,
      });
      expect(task2.isStarred, isFalse);
      expect(task2.starOrder, isNull);
    });

    test('fromMap defaults is_starred to false when missing', () {
      final task = Task.fromMap({'id': 1, 'name': 'T', 'created_at': 100});
      expect(task.isStarred, isFalse);
      expect(task.starOrder, isNull);
    });

    test('copyWith updates isStarred and starOrder', () {
      final task = Task(name: 'T');
      final updated = task.copyWith(isStarred: true, starOrder: () => 2);
      expect(updated.isStarred, isTrue);
      expect(updated.starOrder, 2);
    });

    test('copyWith can clear starOrder to null', () {
      final task = Task(name: 'T', isStarred: true, starOrder: 5);
      final updated = task.copyWith(isStarred: false, starOrder: () => null);
      expect(updated.isStarred, isFalse);
      expect(updated.starOrder, isNull);
    });

    test('copyWith preserves starred fields when not specified', () {
      final task = Task(name: 'T', isStarred: true, starOrder: 3);
      final updated = task.copyWith(name: 'New');
      expect(updated.isStarred, isTrue);
      expect(updated.starOrder, 3);
    });

    test('toMap/fromMap round-trip preserves starred fields', () {
      final original = Task(id: 1, name: 'T', createdAt: 100, isStarred: true, starOrder: 4);
      final restored = Task.fromMap(original.toMap());
      expect(restored.isStarred, original.isStarred);
      expect(restored.starOrder, original.starOrder);
    });
  });
}
