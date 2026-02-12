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
  });
}
