import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task_schedule.dart';

void main() {
  group('TaskSchedule model', () {
    test('isWeekly and isOneOff', () {
      final weekly = TaskSchedule(
        taskId: 1, scheduleType: 'weekly', dayOfWeek: 1);
      expect(weekly.isWeekly, isTrue);
      expect(weekly.isOneOff, isFalse);

      final oneoff = TaskSchedule(
        taskId: 1, scheduleType: 'oneoff', specificDate: '2026-03-10');
      expect(oneoff.isWeekly, isFalse);
      expect(oneoff.isOneOff, isTrue);
    });

    test('isActiveOn for weekly schedule', () {
      // Monday = weekday 1
      final monday = TaskSchedule(
        taskId: 1, scheduleType: 'weekly', dayOfWeek: 1);

      // 2026-03-02 is a Monday
      expect(monday.isActiveOn(DateTime(2026, 3, 2)), isTrue);
      // 2026-03-03 is a Tuesday
      expect(monday.isActiveOn(DateTime(2026, 3, 3)), isFalse);
      // 2026-03-09 is a Monday
      expect(monday.isActiveOn(DateTime(2026, 3, 9)), isTrue);
    });

    test('isActiveOn for one-off schedule', () {
      final oneoff = TaskSchedule(
        taskId: 1, scheduleType: 'oneoff', specificDate: '2026-03-10');

      expect(oneoff.isActiveOn(DateTime(2026, 3, 10)), isTrue);
      expect(oneoff.isActiveOn(DateTime(2026, 3, 11)), isFalse);
      expect(oneoff.isActiveOn(DateTime(2026, 3, 9)), isFalse);
    });

    test('isExpired for one-off in the past', () {
      final past = TaskSchedule(
        taskId: 1, scheduleType: 'oneoff', specificDate: '2020-01-01');
      expect(past.isExpired, isTrue);
    });

    test('isExpired is false for future one-off', () {
      final future = TaskSchedule(
        taskId: 1, scheduleType: 'oneoff', specificDate: '2099-12-31');
      expect(future.isExpired, isFalse);
    });

    test('isExpired is false for weekly schedules', () {
      final weekly = TaskSchedule(
        taskId: 1, scheduleType: 'weekly', dayOfWeek: 1);
      expect(weekly.isExpired, isFalse);
    });

    test('toMap and fromMap round-trip', () {
      final original = TaskSchedule(
        id: 5,
        taskId: 10,
        scheduleType: 'weekly',
        dayOfWeek: 3,
        syncId: 'abc-123',
        updatedAt: 1000,
      );
      final map = original.toMap();
      final restored = TaskSchedule.fromMap(map);

      expect(restored.id, 5);
      expect(restored.taskId, 10);
      expect(restored.scheduleType, 'weekly');
      expect(restored.dayOfWeek, 3);
      expect(restored.specificDate, isNull);
      expect(restored.syncId, 'abc-123');
      expect(restored.updatedAt, 1000);
    });

    test('toMap and fromMap round-trip for one-off', () {
      final original = TaskSchedule(
        taskId: 7,
        scheduleType: 'oneoff',
        specificDate: '2026-06-15',
      );
      final map = original.toMap();
      final restored = TaskSchedule.fromMap(map);

      expect(restored.taskId, 7);
      expect(restored.scheduleType, 'oneoff');
      expect(restored.dayOfWeek, isNull);
      expect(restored.specificDate, '2026-06-15');
    });

    test('copyWith preserves and overrides fields', () {
      final original = TaskSchedule(
        id: 1,
        taskId: 2,
        scheduleType: 'weekly',
        dayOfWeek: 5,
        syncId: 'old',
      );
      final copy = original.copyWith(syncId: 'new', updatedAt: 999);

      expect(copy.id, 1);
      expect(copy.taskId, 2);
      expect(copy.scheduleType, 'weekly');
      expect(copy.dayOfWeek, 5);
      expect(copy.syncId, 'new');
      expect(copy.updatedAt, 999);
    });
  });
}
