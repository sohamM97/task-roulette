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

    test('defaults difficulty to 1 (Medium)', () {
      final task = Task(name: 'Test');
      expect(task.difficulty, 1);
      expect(task.difficultyLabel, 'Medium');
    });

    test('creates with explicit priority and difficulty', () {
      final task = Task(id: 1, name: 'Hard task', createdAt: 1000, priority: 1, difficulty: 2);
      expect(task.priority, 1);
      expect(task.difficulty, 2);
      expect(task.priorityLabel, 'High');
      expect(task.difficultyLabel, 'Hard');
    });

    test('priorityLabel returns correct labels', () {
      expect(Task(name: 'T', priority: 0).priorityLabel, 'Normal');
      expect(Task(name: 'T', priority: 1).priorityLabel, 'High');
    });

    test('difficultyLabel returns correct labels', () {
      expect(Task(name: 'T', difficulty: 0).difficultyLabel, 'Easy');
      expect(Task(name: 'T', difficulty: 1).difficultyLabel, 'Medium');
      expect(Task(name: 'T', difficulty: 2).difficultyLabel, 'Hard');
    });

    test('toMap includes priority and difficulty', () {
      final task = Task(id: 1, name: 'T', createdAt: 100, priority: 1, difficulty: 0);
      final map = task.toMap();

      expect(map['priority'], 1);
      expect(map['difficulty'], 0);
    });

    test('toMap includes default priority and difficulty', () {
      final task = Task(id: 1, name: 'T', createdAt: 100);
      final map = task.toMap();

      expect(map['priority'], 0);
      expect(map['difficulty'], 1);
    });

    test('fromMap parses priority and difficulty', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Hard',
        'created_at': 1000,
        'completed_at': null,
        'started_at': null,
        'skipped_at': null,
        'priority': 1,
        'difficulty': 2,
      });

      expect(task.priority, 1);
      expect(task.difficulty, 2);
    });

    test('fromMap defaults priority and difficulty when missing', () {
      final task = Task.fromMap({
        'id': 5,
        'name': 'Old',
        'created_at': 1000,
        'completed_at': null,
      });

      expect(task.priority, 0);
      expect(task.difficulty, 1);
    });

    test('toMap/fromMap round-trip preserves priority and difficulty', () {
      final original = Task(id: 10, name: 'Round trip', createdAt: 999, priority: 0, difficulty: 2);
      final restored = Task.fromMap(original.toMap());

      expect(restored.priority, original.priority);
      expect(restored.difficulty, original.difficulty);
    });
  });
}
