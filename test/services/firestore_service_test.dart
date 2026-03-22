import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      );
      final fields = service.taskToFirestoreFields(task);

      expect(fields['name'], {'stringValue': 'Test task'});
      expect(fields['created_at'], {'integerValue': '1000000'});
      expect(fields['priority'], {'integerValue': '1'});
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
          'updated_at': {'integerValue': '99999'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 12345);
      expect(task.priority, 2);
      expect(task.updatedAt, 99999);
    });

    test('defaults name to empty string when missing', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
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
          'url': {'stringValue': 'https://example.com'},
          'repeat_interval': {'stringValue': 'daily'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.name, 'Normal task');
      expect(task.url, 'https://example.com');
      expect(task.repeatInterval, 'daily');
    });

    test('URL at exactly 2048 characters is accepted', () {
      final exactUrl = 'https://example.com/${'x' * 2028}';
      expect(exactUrl.length, 2048);
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'url': {'stringValue': exactUrl},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.url, exactUrl);
    });

    test('repeat_interval at exactly 50 characters is accepted', () {
      final exactInterval = 'x' * 50;
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          'repeat_interval': {'stringValue': exactInterval},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.repeatInterval, exactInterval);
    });

    test('name at exactly 500 characters is not truncated', () {
      final exactName = 'A' * 500;
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': exactName},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.name.length, 500);
      expect(task.name, exactName);
    });
  });

  group('taskFromFirestoreDoc integer edge cases', () {
    test('handles integerValue as actual int (not string)', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': 42},
          'priority': {'integerValue': 1},
          'updated_at': {'integerValue': 9999},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 42);
      expect(task.priority, 1);
      expect(task.updatedAt, 9999);
    });

    test('handles unparseable integer string gracefully', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': 'not-a-number'},
          'priority': {'integerValue': ''},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 0);
      expect(task.priority, 0);
    });

    test('returns null for nullable int fields with non-parseable values', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '0'},
          'completed_at': {'integerValue': 'invalid'},
          'started_at': {'integerValue': 'xyz'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.completedAt, isNull);
      expect(task.startedAt, isNull);
    });

    test('handles missing integerValue key in field map', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'wrongKey': '100'},
          'priority': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.createdAt, 0); // defaults to 0
    });

    test('nullable int field returns null when field key is absent', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '0'},
          'priority': {'integerValue': '0'},
          // skipped_at, last_worked_at etc. are completely absent
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.skippedAt, isNull);
      expect(task.lastWorkedAt, isNull);
      expect(task.nextDueAt, isNull);
    });
  });

  group('taskToFirestoreFields edge cases', () {
    test('updated_at uses current timestamp when null on task', () {
      final task = Task(name: 'No updated_at', createdAt: 100);
      final fields = service.taskToFirestoreFields(task);

      // updated_at should be present with a recent timestamp
      expect(fields.containsKey('updated_at'), isTrue);
      final updatedAt = int.parse(
          (fields['updated_at'] as Map)['integerValue'] as String);
      // Should be recent (within last 10 seconds)
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(updatedAt, greaterThan(now - 10000));
      expect(updatedAt, lessThanOrEqualTo(now));
    });

    test('serializes all optional fields when present', () {
      final task = Task(
        name: 'Full',
        createdAt: 1,
        completedAt: 2,
        startedAt: 3,
        url: 'https://x.com',
        skippedAt: 4,
        priority: 5,
        lastWorkedAt: 7,
        repeatInterval: 'weekly',
        nextDueAt: 8,
        updatedAt: 9,
      );
      final fields = service.taskToFirestoreFields(task);

      expect(fields.length, 11); // all 11 fields
      expect(fields['name'], {'stringValue': 'Full'});
      expect(fields['completed_at'], {'integerValue': '2'});
      expect(fields['started_at'], {'integerValue': '3'});
      expect(fields['url'], {'stringValue': 'https://x.com'});
      expect(fields['skipped_at'], {'integerValue': '4'});
      expect(fields['last_worked_at'], {'integerValue': '7'});
      expect(fields['repeat_interval'], {'stringValue': 'weekly'});
      expect(fields['next_due_at'], {'integerValue': '8'});
    });

    test('omits all optional fields when null', () {
      final task = Task(name: 'Minimal', createdAt: 0, updatedAt: 100);
      final fields = service.taskToFirestoreFields(task);

      // Required: name, created_at, priority, updated_at = 4
      expect(fields.length, 4);
      expect(fields.containsKey('completed_at'), isFalse);
      expect(fields.containsKey('started_at'), isFalse);
      expect(fields.containsKey('url'), isFalse);
      expect(fields.containsKey('skipped_at'), isFalse);
      expect(fields.containsKey('last_worked_at'), isFalse);
      expect(fields.containsKey('repeat_interval'), isFalse);
      expect(fields.containsKey('next_due_at'), isFalse);
      expect(fields.containsKey('deadline'), isFalse);
    });
  });

  group('Deadline in Firestore serialization', () {
    test('taskToFirestoreFields includes deadline when set', () {
      final task = Task(name: 'T', createdAt: 100, deadline: '2026-03-20');
      final fields = service.taskToFirestoreFields(task);

      expect(fields.containsKey('deadline'), isTrue);
      expect(fields['deadline'], {'stringValue': '2026-03-20'});
    });

    test('taskToFirestoreFields omits deadline when null', () {
      final task = Task(name: 'T', createdAt: 100);
      final fields = service.taskToFirestoreFields(task);

      expect(fields.containsKey('deadline'), isFalse);
    });

    test('taskFromFirestoreDoc parses deadline', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '0'},
          'deadline': {'stringValue': '2026-03-20'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadline, '2026-03-20');
    });

    test('taskFromFirestoreDoc returns null deadline when absent', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '0'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadline, isNull);
    });

    test('taskFromFirestoreDoc rejects deadline string > 10 chars', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '0'},
          'deadline': {'stringValue': '2026-03-20T00:00:00'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadline, isNull);
    });

    test('taskFromFirestoreDoc accepts deadline at exactly 10 chars', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'Task'},
          'created_at': {'integerValue': '100'},
          'priority': {'integerValue': '0'},
          'deadline': {'stringValue': '2026-03-20'},
        },
      };

      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadline, '2026-03-20');
      expect(task.deadline!.length, 10);
    });

    test('round-trip preserves deadline through Firestore serialization', () {
      final original = Task(
        name: 'Deadline task',
        createdAt: 1000,
        updatedAt: 2000,
        syncId: 'deadline-rt',
        deadline: '2026-12-31',
      );

      final fields = service.taskToFirestoreFields(original);
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/${original.syncId}',
        'fields': fields,
      };

      final restored = service.taskFromFirestoreDoc(doc);
      expect(restored!.deadline, '2026-12-31');
    });

    test('round-trip with null deadline', () {
      final original = Task(
        name: 'No deadline',
        createdAt: 1000,
        updatedAt: 2000,
        syncId: 'no-dl',
      );

      final fields = service.taskToFirestoreFields(original);
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/${original.syncId}',
        'fields': fields,
      };

      final restored = service.taskFromFirestoreDoc(doc);
      expect(restored!.deadline, isNull);
    });

    test('taskToFirestoreFields includes deadline_type when not due_by', () {
      final task = Task(name: 'T', createdAt: 100, deadline: '2026-03-20', deadlineType: 'on');
      final fields = service.taskToFirestoreFields(task);
      expect(fields['deadline_type'], {'stringValue': 'on'});
    });

    test('taskToFirestoreFields omits deadline_type when due_by (default)', () {
      final task = Task(name: 'T', createdAt: 100, deadline: '2026-03-20');
      final fields = service.taskToFirestoreFields(task);
      expect(fields.containsKey('deadline_type'), isFalse);
    });

    test('taskFromFirestoreDoc parses deadline_type', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'T'},
          'created_at': {'integerValue': '100'},
          'deadline': {'stringValue': '2026-03-20'},
          'deadline_type': {'stringValue': 'on'},
        },
      };
      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadlineType, 'on');
    });

    test('taskFromFirestoreDoc defaults deadline_type to due_by when absent', () {
      final doc = {
        'name': 'a/b/tasks/id1',
        'fields': {
          'name': {'stringValue': 'T'},
          'created_at': {'integerValue': '100'},
          'deadline': {'stringValue': '2026-03-20'},
        },
      };
      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.deadlineType, 'due_by');
    });

    test('round-trip preserves deadline_type through Firestore serialization', () {
      final original = Task(
        name: 'On deadline',
        createdAt: 1000,
        updatedAt: 2000,
        syncId: 'on-dl-rt',
        deadline: '2026-03-20',
        deadlineType: 'on',
      );

      final fields = service.taskToFirestoreFields(original);
      final doc = {
        'name': 'projects/p/databases/(default)/documents/users/u/tasks/${original.syncId}',
        'fields': fields,
      };

      final restored = service.taskFromFirestoreDoc(doc);
      expect(restored!.deadlineType, 'on');
    });
  });

  group('Starred fields serialization', () {
    test('taskToFirestoreFields includes is_starred when true', () {
      final task = Task(name: 'Starred', isStarred: true, starOrder: 3);
      final fields = service.taskToFirestoreFields(task);
      expect(fields['is_starred'], {'booleanValue': true});
      expect(fields['star_order'], {'integerValue': '3'});
    });

    test('taskToFirestoreFields omits is_starred when false', () {
      final task = Task(name: 'Not starred');
      final fields = service.taskToFirestoreFields(task);
      expect(fields.containsKey('is_starred'), isFalse);
      expect(fields.containsKey('star_order'), isFalse);
    });

    test('taskToFirestoreFields omits star_order when null', () {
      final task = Task(name: 'Starred no order', isStarred: true);
      final fields = service.taskToFirestoreFields(task);
      expect(fields['is_starred'], {'booleanValue': true});
      expect(fields.containsKey('star_order'), isFalse);
    });

    test('taskFromFirestoreDoc parses is_starred and star_order', () {
      final doc = {
        'name': 'documents/tasks/abc123',
        'fields': {
          'name': {'stringValue': 'Test'},
          'created_at': {'integerValue': '1000'},
          'is_starred': {'booleanValue': true},
          'star_order': {'integerValue': '5'},
        },
      };
      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.isStarred, isTrue);
      expect(task.starOrder, 5);
    });

    test('taskFromFirestoreDoc defaults is_starred to false when missing', () {
      final doc = {
        'name': 'documents/tasks/abc123',
        'fields': {
          'name': {'stringValue': 'Test'},
          'created_at': {'integerValue': '1000'},
        },
      };
      final task = service.taskFromFirestoreDoc(doc);
      expect(task!.isStarred, isFalse);
      expect(task.starOrder, isNull);
    });
  });

  // --- HTTP-mocked tests for tombstone/delta pull logic ---

  /// Helper to build a mock Firestore document JSON for relationships.
  Map<String, dynamic> relDoc(String parent, String child, {int? deletedAt, int? updatedAt}) {
    final fields = <String, dynamic>{
      'parent_sync_id': {'stringValue': parent},
      'child_sync_id': {'stringValue': child},
    };
    if (updatedAt != null) {
      fields['updated_at'] = {'integerValue': updatedAt.toString()};
    }
    if (deletedAt != null) {
      fields['deleted_at'] = {'integerValue': deletedAt.toString()};
    }
    return {
      'name': 'projects/test/databases/(default)/documents/users/u/relationships/${parent}_$child',
      'fields': fields,
    };
  }

  /// Helper to build a mock Firestore document JSON for dependencies.
  Map<String, dynamic> depDoc(String task, String dependsOn, {int? deletedAt, int? updatedAt}) {
    final fields = <String, dynamic>{
      'task_sync_id': {'stringValue': task},
      'depends_on_sync_id': {'stringValue': dependsOn},
    };
    if (updatedAt != null) {
      fields['updated_at'] = {'integerValue': updatedAt.toString()};
    }
    if (deletedAt != null) {
      fields['deleted_at'] = {'integerValue': deletedAt.toString()};
    }
    return {
      'name': 'projects/test/databases/(default)/documents/users/u/dependencies/${task}_$dependsOn',
      'fields': fields,
    };
  }

  /// Helper to build a mock Firestore schedule document.
  Map<String, dynamic> schedDoc(String syncId, String taskSyncId,
      {int? dayOfWeek, int? deletedAt, int? updatedAt}) {
    final fields = <String, dynamic>{
      'task_sync_id': {'stringValue': taskSyncId},
      'schedule_type': {'stringValue': 'weekly'},
    };
    if (dayOfWeek != null) {
      fields['day_of_week'] = {'integerValue': dayOfWeek.toString()};
    }
    if (updatedAt != null) {
      fields['updated_at'] = {'integerValue': updatedAt.toString()};
    }
    if (deletedAt != null) {
      fields['deleted_at'] = {'integerValue': deletedAt.toString()};
    }
    return {
      'name': 'projects/test/databases/(default)/documents/users/u/schedules/$syncId',
      'fields': fields,
    };
  }

  group('pullAllRelationships — tombstone filtering', () {
    test('skips documents with deleted_at set', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            relDoc('p1', 'c1'),
            relDoc('p2', 'c2', deletedAt: 1000),
            relDoc('p3', 'c3'),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllRelationships('u', 'token');

      expect(results.length, 2);
      expect(results[0].parentSyncId, 'p1');
      expect(results[0].childSyncId, 'c1');
      expect(results[1].parentSyncId, 'p3');
      expect(results[1].childSyncId, 'c3');
    });

    test('returns empty when all docs are tombstoned', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            relDoc('p1', 'c1', deletedAt: 100),
            relDoc('p2', 'c2', deletedAt: 200),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllRelationships('u', 'token');

      expect(results, isEmpty);
    });

    test('returns all when no docs are tombstoned', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            relDoc('p1', 'c1'),
            relDoc('p2', 'c2'),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllRelationships('u', 'token');

      expect(results.length, 2);
    });
  });

  group('pullAllDependencies — tombstone filtering', () {
    test('skips documents with deleted_at set', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            depDoc('t1', 'd1'),
            depDoc('t2', 'd2', deletedAt: 500),
            depDoc('t3', 'd3'),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllDependencies('u', 'token');

      expect(results.length, 2);
      expect(results[0].taskSyncId, 't1');
      expect(results[1].taskSyncId, 't3');
    });

    test('returns empty when all docs are tombstoned', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            depDoc('t1', 'd1', deletedAt: 100),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllDependencies('u', 'token');

      expect(results, isEmpty);
    });
  });

  group('pullAllSchedules — tombstone filtering', () {
    test('skips documents with deleted_at set', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            schedDoc('s1', 'ts1', dayOfWeek: 1),
            schedDoc('s2', 'ts2', dayOfWeek: 3, deletedAt: 999),
            schedDoc('s3', 'ts3', dayOfWeek: 5),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllSchedules('u', 'token');

      expect(results.length, 2);
      expect(results[0]['sync_id'], 's1');
      expect(results[0]['day_of_week'], 1);
      expect(results[1]['sync_id'], 's3');
      expect(results[1]['day_of_week'], 5);
    });

    test('returns empty when all schedules are tombstoned', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode({
          'documents': [
            schedDoc('s1', 'ts1', deletedAt: 100),
          ],
        });
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullAllSchedules('u', 'token');

      expect(results, isEmpty);
    });
  });

  group('pullRelationshipsSince — delta pull with deleted flag', () {
    test('returns live and deleted relationships with correct deleted flag', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/test/rel/p1_c1',
              'fields': {
                'parent_sync_id': {'stringValue': 'p1'},
                'child_sync_id': {'stringValue': 'c1'},
                'updated_at': {'integerValue': '2000'},
              },
            },
          },
          {
            'document': {
              'name': 'projects/test/rel/p2_c2',
              'fields': {
                'parent_sync_id': {'stringValue': 'p2'},
                'child_sync_id': {'stringValue': 'c2'},
                'updated_at': {'integerValue': '2000'},
                'deleted_at': {'integerValue': '1500'},
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullRelationshipsSince('u', 'token', 1000);

      expect(results.length, 2);
      expect(results[0].parentSyncId, 'p1');
      expect(results[0].childSyncId, 'c1');
      expect(results[0].deleted, isFalse);
      expect(results[1].parentSyncId, 'p2');
      expect(results[1].childSyncId, 'c2');
      expect(results[1].deleted, isTrue);
    });

    test('returns empty list when response has no documents', () async {
      final mockClient = MockClient((request) async {
        // Firestore returns [{"readTime": "..."}] when no results match
        final body = json.encode([
          {'readTime': '2026-03-22T00:00:00Z'},
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullRelationshipsSince('u', 'token', 1000);

      expect(results, isEmpty);
    });

    test('sends structured query with updated_at filter', () async {
      Uri? capturedUri;
      String? capturedBody;
      final mockClient = MockClient((request) async {
        capturedUri = request.url;
        capturedBody = request.body;
        return http.Response(json.encode([]), 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.pullRelationshipsSince('u', 'token', 5000);

      expect(capturedUri.toString(), contains(':runQuery'));
      final decoded = json.decode(capturedBody!) as Map<String, dynamic>;
      final query = decoded['structuredQuery'] as Map<String, dynamic>;
      final from = (query['from'] as List).first as Map<String, dynamic>;
      expect(from['collectionId'], 'relationships');
      final filter = query['where']['fieldFilter'] as Map<String, dynamic>;
      expect(filter['field']['fieldPath'], 'updated_at');
      expect(filter['op'], 'GREATER_THAN');
      expect(filter['value']['integerValue'], '5000');
    });
  });

  group('pullDependenciesSince — delta pull with deleted flag', () {
    test('returns live and deleted dependencies with correct deleted flag', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/test/dep/t1_d1',
              'fields': {
                'task_sync_id': {'stringValue': 't1'},
                'depends_on_sync_id': {'stringValue': 'd1'},
                'updated_at': {'integerValue': '3000'},
              },
            },
          },
          {
            'document': {
              'name': 'projects/test/dep/t2_d2',
              'fields': {
                'task_sync_id': {'stringValue': 't2'},
                'depends_on_sync_id': {'stringValue': 'd2'},
                'updated_at': {'integerValue': '3000'},
                'deleted_at': {'integerValue': '2500'},
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullDependenciesSince('u', 'token', 2000);

      expect(results.length, 2);
      expect(results[0].taskSyncId, 't1');
      expect(results[0].dependsOnSyncId, 'd1');
      expect(results[0].deleted, isFalse);
      expect(results[1].taskSyncId, 't2');
      expect(results[1].dependsOnSyncId, 'd2');
      expect(results[1].deleted, isTrue);
    });

    test('skips entries with missing sync IDs', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/test/dep/t1_d1',
              'fields': {
                'task_sync_id': {'stringValue': 't1'},
                // depends_on_sync_id is missing
              },
            },
          },
          {
            'document': {
              'name': 'projects/test/dep/t2_d2',
              'fields': {
                'task_sync_id': {'stringValue': 't2'},
                'depends_on_sync_id': {'stringValue': 'd2'},
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullDependenciesSince('u', 'token', 1000);

      expect(results.length, 1);
      expect(results[0].taskSyncId, 't2');
    });

    test('returns empty list for non-list response', () async {
      final mockClient = MockClient((request) async {
        return http.Response(json.encode({'not': 'a list'}), 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullDependenciesSince('u', 'token', 1000);

      expect(results, isEmpty);
    });
  });

  group('pullSchedulesSince — delta pull with deleted flag', () {
    test('returns schedules with deleted flag from deleted_at', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/test/databases/(default)/documents/users/u/schedules/sched1',
              'fields': {
                'task_sync_id': {'stringValue': 'ts1'},
                'schedule_type': {'stringValue': 'weekly'},
                'day_of_week': {'integerValue': '3'},
                'updated_at': {'integerValue': '4000'},
              },
            },
          },
          {
            'document': {
              'name': 'projects/test/databases/(default)/documents/users/u/schedules/sched2',
              'fields': {
                'task_sync_id': {'stringValue': 'ts2'},
                'schedule_type': {'stringValue': 'weekly'},
                'day_of_week': {'integerValue': '5'},
                'updated_at': {'integerValue': '4000'},
                'deleted_at': {'integerValue': '3500'},
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullSchedulesSince('u', 'token', 3000);

      expect(results.length, 2);
      // Live schedule
      expect(results[0]['sync_id'], 'sched1');
      expect(results[0]['task_sync_id'], 'ts1');
      expect(results[0]['schedule_type'], 'weekly');
      expect(results[0]['day_of_week'], 3);
      expect(results[0]['deleted'], isFalse);
      // Tombstoned schedule
      expect(results[1]['sync_id'], 'sched2');
      expect(results[1]['task_sync_id'], 'ts2');
      expect(results[1]['deleted'], isTrue);
    });

    test('extracts sync_id from document name', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/p/databases/(default)/documents/users/u/schedules/my-sync-id-123',
              'fields': {
                'task_sync_id': {'stringValue': 'ts1'},
                'schedule_type': {'stringValue': 'weekly'},
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullSchedulesSince('u', 'token', 0);

      expect(results[0]['sync_id'], 'my-sync-id-123');
    });

    test('defaults schedule_type to weekly when missing', () async {
      final mockClient = MockClient((request) async {
        final body = json.encode([
          {
            'document': {
              'name': 'projects/p/databases/(default)/documents/users/u/schedules/s1',
              'fields': {
                'task_sync_id': {'stringValue': 'ts1'},
                // schedule_type missing
              },
            },
          },
        ]);
        return http.Response(body, 200);
      });

      final svc = FirestoreService(client: mockClient);
      final results = await svc.pullSchedulesSince('u', 'token', 0);

      expect(results[0]['schedule_type'], 'weekly');
    });
  });

  group('deleteRelationship — soft-delete via commit API', () {
    test('sends commit with deleted_at and updated_at fields', () async {
      Map<String, dynamic>? capturedWrite;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains(':commit')) {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final writes = body['writes'] as List;
          capturedWrite = writes[0] as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.deleteRelationship('u', 'token', 'parent1', 'child1');

      expect(capturedWrite, isNotNull);
      final update = capturedWrite!['update'] as Map<String, dynamic>;
      expect(update['name'], contains('parent1_child1'));
      final fields = update['fields'] as Map<String, dynamic>;
      expect(fields['parent_sync_id'], {'stringValue': 'parent1'});
      expect(fields['child_sync_id'], {'stringValue': 'child1'});
      expect(fields.containsKey('deleted_at'), isTrue);
      expect(fields.containsKey('updated_at'), isTrue);
      // Both timestamps should be the same
      expect(fields['deleted_at']['integerValue'], fields['updated_at']['integerValue']);
    });

    test('does not use HTTP DELETE method', () async {
      String? capturedMethod;
      final mockClient = MockClient((request) async {
        capturedMethod = request.method;
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.deleteRelationship('u', 'token', 'p', 'c');

      expect(capturedMethod, 'POST'); // commit API uses POST, not DELETE
    });
  });

  group('deleteDependency — soft-delete via commit API', () {
    test('sends commit with deleted_at and updated_at fields', () async {
      Map<String, dynamic>? capturedWrite;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains(':commit')) {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final writes = body['writes'] as List;
          capturedWrite = writes[0] as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.deleteDependency('u', 'token', 'task1', 'dep1');

      expect(capturedWrite, isNotNull);
      final update = capturedWrite!['update'] as Map<String, dynamic>;
      expect(update['name'], contains('task1_dep1'));
      final fields = update['fields'] as Map<String, dynamic>;
      expect(fields['task_sync_id'], {'stringValue': 'task1'});
      expect(fields['depends_on_sync_id'], {'stringValue': 'dep1'});
      expect(fields.containsKey('deleted_at'), isTrue);
      expect(fields.containsKey('updated_at'), isTrue);
    });
  });

  group('deleteSchedule — soft-delete via commit API', () {
    test('sends commit with deleted_at and updated_at fields', () async {
      Map<String, dynamic>? capturedWrite;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains(':commit')) {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final writes = body['writes'] as List;
          capturedWrite = writes[0] as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.deleteSchedule('u', 'token', 'sched-abc');

      expect(capturedWrite, isNotNull);
      final update = capturedWrite!['update'] as Map<String, dynamic>;
      expect(update['name'], contains('sched-abc'));
      final fields = update['fields'] as Map<String, dynamic>;
      expect(fields.containsKey('deleted_at'), isTrue);
      expect(fields.containsKey('updated_at'), isTrue);
    });
  });

  group('cleanupTombstones', () {
    test('queries tombstones with composite filter and deletes them', () async {
      final requests = <http.Request>[];
      final mockClient = MockClient((request) async {
        requests.add(request);
        if (request.url.toString().contains(':runQuery')) {
          final body = json.encode([
            {
              'document': {
                'name': 'projects/test/databases/(default)/documents/users/u/relationships/old1',
                'fields': {},
              },
            },
            {
              'document': {
                'name': 'projects/test/databases/(default)/documents/users/u/relationships/old2',
                'fields': {},
              },
            },
          ]);
          return http.Response(body, 200);
        }
        // commit for batch delete
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.cleanupTombstones('u', 'token', 'relationships', const Duration(days: 7));

      // Should have 2 requests: query + commit
      expect(requests.length, 2);

      // Verify the query uses compositeFilter with deleted_at
      final queryBody = json.decode(requests[0].body) as Map<String, dynamic>;
      final query = queryBody['structuredQuery'] as Map<String, dynamic>;
      final composite = query['where']['compositeFilter'] as Map<String, dynamic>;
      expect(composite['op'], 'AND');
      final filters = composite['filters'] as List;
      expect(filters.length, 2);
      // First filter: deleted_at > 0
      final f1 = (filters[0] as Map<String, dynamic>)['fieldFilter'] as Map<String, dynamic>;
      expect(f1['field']['fieldPath'], 'deleted_at');
      expect(f1['op'], 'GREATER_THAN');
      expect(f1['value']['integerValue'], '0');
      // Second filter: deleted_at < cutoff
      final f2 = (filters[1] as Map<String, dynamic>)['fieldFilter'] as Map<String, dynamic>;
      expect(f2['field']['fieldPath'], 'deleted_at');
      expect(f2['op'], 'LESS_THAN');

      // Verify the commit sends delete writes
      final commitBody = json.decode(requests[1].body) as Map<String, dynamic>;
      final writes = commitBody['writes'] as List;
      expect(writes.length, 2);
      expect(writes[0]['delete'], contains('old1'));
      expect(writes[1]['delete'], contains('old2'));
    });

    test('does nothing when no tombstones found', () async {
      final requests = <http.Request>[];
      final mockClient = MockClient((request) async {
        requests.add(request);
        if (request.url.toString().contains(':runQuery')) {
          // Empty result — no tombstones
          return http.Response(json.encode([
            {'readTime': '2026-03-22T00:00:00Z'},
          ]), 200);
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.cleanupTombstones('u', 'token', 'dependencies', const Duration(days: 7));

      // Only the query request, no commit
      expect(requests.length, 1);
    });

    test('gracefully handles query failure', () async {
      final mockClient = MockClient((request) async {
        return http.Response('error', 500);
      });

      // Should not throw — best-effort cleanup
      final svc = FirestoreService(client: mockClient);
      await svc.cleanupTombstones('u', 'token', 'schedules', const Duration(days: 7));
    });
  });

  group('pushRelationships — includes updated_at', () {
    test('sends updated_at field in relationship documents', () async {
      Map<String, dynamic>? capturedWrite;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains(':commit')) {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final writes = body['writes'] as List;
          capturedWrite = writes[0] as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.pushRelationships('u', 'token', [
        (parentSyncId: 'p1', childSyncId: 'c1'),
      ]);

      expect(capturedWrite, isNotNull);
      final fields = (capturedWrite!['update'] as Map<String, dynamic>)['fields'] as Map<String, dynamic>;
      expect(fields.containsKey('updated_at'), isTrue);
      expect(fields['parent_sync_id'], {'stringValue': 'p1'});
      expect(fields['child_sync_id'], {'stringValue': 'c1'});
    });
  });

  group('pushDependencies — includes updated_at', () {
    test('sends updated_at field in dependency documents', () async {
      Map<String, dynamic>? capturedWrite;
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains(':commit')) {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final writes = body['writes'] as List;
          capturedWrite = writes[0] as Map<String, dynamic>;
        }
        return http.Response('{}', 200);
      });

      final svc = FirestoreService(client: mockClient);
      await svc.pushDependencies('u', 'token', [
        (taskSyncId: 't1', dependsOnSyncId: 'd1'),
      ]);

      expect(capturedWrite, isNotNull);
      final fields = (capturedWrite!['update'] as Map<String, dynamic>)['fields'] as Map<String, dynamic>;
      expect(fields.containsKey('updated_at'), isTrue);
      expect(fields['task_sync_id'], {'stringValue': 't1'});
      expect(fields['depends_on_sync_id'], {'stringValue': 'd1'});
    });
  });
}
