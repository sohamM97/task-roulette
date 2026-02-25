import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/services/firestore_service.dart';

void main() {
  late FirestoreService service;

  setUp(() {
    service = FirestoreService();
  });

  group('taskToFirestoreFields', () {
    test('includes required fields', () {
      final task = Task(
        name: 'Test task',
        createdAt: 1000000,
        priority: 1,
        difficulty: 2,
      );
      final fields = service.taskToFirestoreFields(task);

      expect(fields['name'], {'stringValue': 'Test task'});
      expect(fields['created_at'], {'integerValue': '1000000'});
      expect(fields['priority'], {'integerValue': '1'});
      expect(fields['difficulty'], {'integerValue': '2'});
      expect(fields.containsKey('updated_at'), isTrue);
    });

    test('includes optional fields when set', () {
      final task = Task(
        name: 'Full task',
        createdAt: 1000000,
        completedAt: 2000000,
        startedAt: 1500000,
        url: 'https://example.com',
        skippedAt: 1800000,
        priority: 2,
        difficulty: 1,
        lastWorkedAt: 1900000,
        repeatInterval: 'daily',
        nextDueAt: 3000000,
        updatedAt: 2500000,
      );
      final fields = service.taskToFirestoreFields(task);

      expect(fields['completed_at'], {'integerValue': '2000000'});
      expect(fields['started_at'], {'integerValue': '1500000'});
      expect(fields['url'], {'stringValue': 'https://example.com'});
      expect(fields['skipped_at'], {'integerValue': '1800000'});
      expect(fields['last_worked_at'], {'integerValue': '1900000'});
      expect(fields['repeat_interval'], {'stringValue': 'daily'});
      expect(fields['next_due_at'], {'integerValue': '3000000'});
      expect(fields['updated_at'], {'integerValue': '2500000'});
    });

    test('omits optional fields when null', () {
      final task = Task(name: 'Minimal');
      final fields = service.taskToFirestoreFields(task);

      expect(fields.containsKey('completed_at'), isFalse);
      expect(fields.containsKey('started_at'), isFalse);
      expect(fields.containsKey('url'), isFalse);
      expect(fields.containsKey('skipped_at'), isFalse);
      expect(fields.containsKey('last_worked_at'), isFalse);
      expect(fields.containsKey('repeat_interval'), isFalse);
      expect(fields.containsKey('next_due_at'), isFalse);
    });
  });

  group('taskFromFirestoreDoc', () {
    test('parses a complete document', () {
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/sync-123',
        'fields': {
          'name': {'stringValue': 'Test task'},
          'created_at': {'integerValue': '1000000'},
          'completed_at': {'integerValue': '2000000'},
          'started_at': {'integerValue': '1500000'},
          'url': {'stringValue': 'https://example.com'},
          'skipped_at': {'integerValue': '1800000'},
          'priority': {'integerValue': '1'},
          'difficulty': {'integerValue': '2'},
          'last_worked_at': {'integerValue': '1900000'},
          'repeat_interval': {'stringValue': 'daily'},
          'next_due_at': {'integerValue': '3000000'},
          'updated_at': {'integerValue': '2500000'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);

      expect(task, isNotNull);
      expect(task!.name, 'Test task');
      expect(task.syncId, 'sync-123');
      expect(task.createdAt, 1000000);
      expect(task.completedAt, 2000000);
      expect(task.startedAt, 1500000);
      expect(task.url, 'https://example.com');
      expect(task.skippedAt, 1800000);
      expect(task.priority, 1);
      expect(task.difficulty, 2);
      expect(task.lastWorkedAt, 1900000);
      expect(task.repeatInterval, 'daily');
      expect(task.nextDueAt, 3000000);
      expect(task.updatedAt, 2500000);
      expect(task.syncStatus, 'synced');
    });

    test('parses minimal document with missing optional fields', () {
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/abc',
        'fields': {
          'name': {'stringValue': 'Simple'},
          'created_at': {'integerValue': '500'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);

      expect(task, isNotNull);
      expect(task!.name, 'Simple');
      expect(task.syncId, 'abc');
      expect(task.createdAt, 500);
      expect(task.completedAt, isNull);
      expect(task.startedAt, isNull);
      expect(task.url, isNull);
      expect(task.skippedAt, isNull);
      expect(task.lastWorkedAt, isNull);
      expect(task.repeatInterval, isNull);
      expect(task.nextDueAt, isNull);
      expect(task.updatedAt, isNull);
    });

    test('returns null when fields is missing', () {
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/xyz',
      };

      expect(service.taskFromFirestoreDoc(doc), isNull);
    });

    test('extracts sync_id from document name (last path segment)', () {
      final doc = {
        'name': 'projects/my-proj/databases/(default)/documents/users/uid123/tasks/my-sync-id-456',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.syncId, 'my-sync-id-456');
    });

    test('handles integer values as both int and String', () {
      // Firestore REST API returns integers as strings
      final doc = {
        'name': 'a/b/c/d/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '12345'},
          'priority': {'integerValue': '2'},
          'difficulty': {'integerValue': '1'},
          'updated_at': {'integerValue': '99999'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 12345);
      expect(task.priority, 2);
      expect(task.difficulty, 1);
      expect(task.updatedAt, 99999);
    });

    test('defaults name to empty string when missing', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.name, '');
    });

    test('defaults numeric fields to 0 when missing', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 0);
      expect(task.priority, 0);
      expect(task.difficulty, 0);
    });
  });

  group('round-trip: Task → Firestore fields → Task', () {
    test('preserves all fields through serialization round-trip', () {
      final original = Task(
        name: 'Round trip task',
        createdAt: 1000000,
        completedAt: 2000000,
        startedAt: 1500000,
        url: 'https://example.com/path',
        skippedAt: 1800000,
        priority: 2,
        difficulty: 1,
        lastWorkedAt: 1900000,
        repeatInterval: 'weekly',
        nextDueAt: 3000000,
        updatedAt: 2500000,
        syncId: 'round-trip-id',
      );

      final fields = service.taskToFirestoreFields(original);

      // Simulate what Firestore returns: wrap in a document structure
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/${original.syncId}',
        'fields': fields,
      };

      final restored = service.taskFromFirestoreDoc(doc);

      expect(restored, isNotNull);
      expect(restored!.name, original.name);
      expect(restored.createdAt, original.createdAt);
      expect(restored.completedAt, original.completedAt);
      expect(restored.startedAt, original.startedAt);
      expect(restored.url, original.url);
      expect(restored.skippedAt, original.skippedAt);
      expect(restored.priority, original.priority);
      expect(restored.difficulty, original.difficulty);
      expect(restored.lastWorkedAt, original.lastWorkedAt);
      expect(restored.repeatInterval, original.repeatInterval);
      expect(restored.nextDueAt, original.nextDueAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.syncId, original.syncId);
    });

    test('round-trip with minimal task (only required fields)', () {
      final original = Task(
        name: 'Minimal',
        createdAt: 42,
        updatedAt: 100,
      );

      final fields = service.taskToFirestoreFields(original);
      final doc = {
        'name': 'a/b/tasks/some-id',
        'fields': fields,
      };

      final restored = service.taskFromFirestoreDoc(doc);

      expect(restored!.name, 'Minimal');
      expect(restored.createdAt, 42);
      expect(restored.updatedAt, 100);
      expect(restored.completedAt, isNull);
      expect(restored.startedAt, isNull);
      expect(restored.url, isNull);
    });
  });

  group('FirestoreException', () {
    test('toString includes message', () {
      final ex = FirestoreException('something broke');
      expect(ex.toString(), 'FirestoreException: something broke');
    });

    test('message field is accessible', () {
      final ex = FirestoreException('test error');
      expect(ex.message, 'test error');
    });
  });

  group('isConfigured', () {
    test('returns false when project ID is empty (default)', () {
      // Without --dart-define, _projectId defaults to ''
      expect(service.isConfigured, isFalse);
    });
  });

  group('taskFromFirestoreDoc field size validation (MED-9)', () {
    test('truncates oversized name to 500 characters', () {
      final longName = 'A' * 1000;
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': longName},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.name.length, 500);
    });

    test('drops URL longer than 2048 characters', () {
      final longUrl = 'https://example.com/${'x' * 2100}';
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
          'url': {'stringValue': longUrl},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.url, isNull);
    });

    test('accepts URL within 2048 characters', () {
      final normalUrl = 'https://example.com/path';
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
          'url': {'stringValue': normalUrl},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.url, normalUrl);
    });

    test('drops repeat_interval longer than 50 characters', () {
      final longInterval = 'x' * 60;
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'difficulty': {'integerValue': '0'},
          'repeat_interval': {'stringValue': longInterval},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.repeatInterval, isNull);
    });

    test('preserves normal-length name and fields', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Normal task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '1'},
          'difficulty': {'integerValue': '2'},
          'url': {'stringValue': 'https://example.com'},
          'repeat_interval': {'stringValue': 'daily'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.name, 'Normal task');
      expect(task.url, 'https://example.com');
      expect(task.repeatInterval, 'daily');
    });
  });
}
