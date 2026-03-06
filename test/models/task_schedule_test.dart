import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task_schedule.dart';

void main() {
  group('TaskSchedule model', () {
    test('isActiveOn for weekly schedule', () {
      // Monday = weekday 1
      final monday = TaskSchedule(taskId: 1, dayOfWeek: 1);

      // 2026-03-02 is a Monday
      expect(monday.isActiveOn(DateTime(2026, 3, 2)), isTrue);
      // 2026-03-03 is a Tuesday
      expect(monday.isActiveOn(DateTime(2026, 3, 3)), isFalse);
      // 2026-03-09 is a Monday
      expect(monday.isActiveOn(DateTime(2026, 3, 9)), isTrue);
    });

    test('toMap and fromMap round-trip', () {
      final original = TaskSchedule(
        id: 5,
        taskId: 10,
        dayOfWeek: 3,
        syncId: 'abc-123',
        updatedAt: 1000,
      );
      final map = original.toMap();
      final restored = TaskSchedule.fromMap(map);

      expect(restored.id, 5);
      expect(restored.taskId, 10);
      expect(restored.dayOfWeek, 3);
      expect(restored.syncId, 'abc-123');
      expect(restored.updatedAt, 1000);
      expect(map['schedule_type'], 'weekly');
    });

    test('copyWith preserves and overrides fields', () {
      final original = TaskSchedule(
        id: 1,
        taskId: 2,
        dayOfWeek: 5,
        syncId: 'old',
      );
      final copy = original.copyWith(syncId: 'new', updatedAt: 999);

      expect(copy.id, 1);
      expect(copy.taskId, 2);
      expect(copy.dayOfWeek, 5);
      expect(copy.syncId, 'new');
      expect(copy.updatedAt, 999);
    });
  });
}
