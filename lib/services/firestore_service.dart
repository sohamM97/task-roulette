import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../models/task.dart';

/// Firestore REST API service for cloud sync.
/// All operations use the Firestore v1 REST API with Firebase ID token auth.
class FirestoreService {
  static const _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: '',
  );

  static const _baseUrl =
      'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents';

  bool get isConfigured => _projectId.isNotEmpty;

  Map<String, String> _headers(String idToken) => {
        'Authorization': 'Bearer $idToken',
        'Content-Type': 'application/json',
      };

  String _tasksPath(String uid) => '$_baseUrl/users/$uid/tasks';
  String _relationshipsPath(String uid) => '$_baseUrl/users/$uid/relationships';
  String _dependenciesPath(String uid) => '$_baseUrl/users/$uid/dependencies';

  // --- Push ---

  /// Pushes tasks to Firestore using batch commit (up to 500 per batch).
  Future<void> pushTasks(String uid, String idToken, List<Task> tasks) async {
    if (tasks.isEmpty) return;
    // Process in batches of 500 (Firestore limit)
    for (var i = 0; i < tasks.length; i += 500) {
      final batch = tasks.skip(i).take(500).toList();
      final writes = batch.map((task) => {
            'update': {
              'name': 'projects/$_projectId/databases/(default)/documents/users/$uid/tasks/${task.syncId}',
              'fields': taskToFirestoreFields(task),
            },
          }).toList();

      final commitUrl = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents:commit',
      );
      final response = await http.post(
        commitUrl,
        headers: _headers(idToken),
        body: json.encode({'writes': writes}),
      );
      if (response.statusCode != 200) {
        throw FirestoreException('Push tasks failed: ${response.statusCode} ${response.body}');
      }
    }
  }

  /// Pushes relationships to Firestore.
  Future<void> pushRelationships(
    String uid,
    String idToken,
    List<({String parentSyncId, String childSyncId})> relationships,
  ) async {
    if (relationships.isEmpty) return;
    for (var i = 0; i < relationships.length; i += 500) {
      final batch = relationships.skip(i).take(500).toList();
      final writes = batch.map((rel) {
        final docId = '${rel.parentSyncId}_${rel.childSyncId}';
        return {
          'update': {
            'name': 'projects/$_projectId/databases/(default)/documents/users/$uid/relationships/$docId',
            'fields': {
              'parent_sync_id': {'stringValue': rel.parentSyncId},
              'child_sync_id': {'stringValue': rel.childSyncId},
            },
          },
        };
      }).toList();

      final commitUrl = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents:commit',
      );
      await http.post(
        commitUrl,
        headers: _headers(idToken),
        body: json.encode({'writes': writes}),
      );
    }
  }

  /// Pushes dependencies to Firestore.
  Future<void> pushDependencies(
    String uid,
    String idToken,
    List<({String taskSyncId, String dependsOnSyncId})> dependencies,
  ) async {
    if (dependencies.isEmpty) return;
    for (var i = 0; i < dependencies.length; i += 500) {
      final batch = dependencies.skip(i).take(500).toList();
      final writes = batch.map((dep) {
        final docId = '${dep.taskSyncId}_${dep.dependsOnSyncId}';
        return {
          'update': {
            'name': 'projects/$_projectId/databases/(default)/documents/users/$uid/dependencies/$docId',
            'fields': {
              'task_sync_id': {'stringValue': dep.taskSyncId},
              'depends_on_sync_id': {'stringValue': dep.dependsOnSyncId},
            },
          },
        };
      }).toList();

      final commitUrl = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents:commit',
      );
      await http.post(
        commitUrl,
        headers: _headers(idToken),
        body: json.encode({'writes': writes}),
      );
    }
  }

  /// Deletes a task document from Firestore.
  Future<void> deleteTask(String uid, String idToken, String syncId) async {
    final url = Uri.parse('${_tasksPath(uid)}/$syncId');
    await http.delete(url, headers: _headers(idToken));
  }

  /// Deletes a relationship document from Firestore.
  Future<void> deleteRelationship(
    String uid,
    String idToken,
    String parentSyncId,
    String childSyncId,
  ) async {
    final docId = '${parentSyncId}_$childSyncId';
    final url = Uri.parse('${_relationshipsPath(uid)}/$docId');
    await http.delete(url, headers: _headers(idToken));
  }

  /// Deletes a dependency document from Firestore.
  Future<void> deleteDependency(
    String uid,
    String idToken,
    String taskSyncId,
    String dependsOnSyncId,
  ) async {
    final docId = '${taskSyncId}_$dependsOnSyncId';
    final url = Uri.parse('${_dependenciesPath(uid)}/$docId');
    await http.delete(url, headers: _headers(idToken));
  }

  // --- Check ---

  /// Returns true if the user has any task documents in Firestore.
  Future<bool> hasRemoteData(String uid, String idToken) async {
    final url = Uri.parse('${_tasksPath(uid)}?pageSize=1');
    final response = await http.get(url, headers: _headers(idToken));
    if (response.statusCode != 200) return false;
    final body = json.decode(response.body) as Map<String, dynamic>;
    final docs = body['documents'] as List<dynamic>? ?? [];
    return docs.isNotEmpty;
  }

  // --- Pull ---

  /// Pulls tasks updated since [lastSyncAt] (epoch millis).
  /// If null, pulls all tasks.
  Future<List<Task>> pullTasksSince(
    String uid,
    String idToken, {
    int? lastSyncAt,
  }) async {
    if (lastSyncAt != null) {
      // Use structured query to filter by updated_at
      return _queryTasksUpdatedSince(uid, idToken, lastSyncAt);
    }
    // Pull all
    return _listAllTasks(uid, idToken);
  }

  /// Pulls all relationships.
  Future<List<({String parentSyncId, String childSyncId})>> pullAllRelationships(
    String uid,
    String idToken,
  ) async {
    final results = <({String parentSyncId, String childSyncId})>[];
    String? pageToken;
    do {
      var url = '${_relationshipsPath(uid)}?pageSize=300';
      if (pageToken != null) url += '&pageToken=$pageToken';
      final response = await http.get(Uri.parse(url), headers: _headers(idToken));
      if (response.statusCode != 200) break;
      final body = json.decode(response.body) as Map<String, dynamic>;
      final docs = body['documents'] as List<dynamic>? ?? [];
      for (final doc in docs) {
        final fields = (doc as Map<String, dynamic>)['fields'] as Map<String, dynamic>?;
        if (fields == null) continue;
        final parentSyncId = _stringField(fields, 'parent_sync_id');
        final childSyncId = _stringField(fields, 'child_sync_id');
        if (parentSyncId != null && childSyncId != null) {
          results.add((parentSyncId: parentSyncId, childSyncId: childSyncId));
        }
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null);
    return results;
  }

  /// Pulls all dependencies.
  Future<List<({String taskSyncId, String dependsOnSyncId})>> pullAllDependencies(
    String uid,
    String idToken,
  ) async {
    final results = <({String taskSyncId, String dependsOnSyncId})>[];
    String? pageToken;
    do {
      var url = '${_dependenciesPath(uid)}?pageSize=300';
      if (pageToken != null) url += '&pageToken=$pageToken';
      final response = await http.get(Uri.parse(url), headers: _headers(idToken));
      if (response.statusCode != 200) break;
      final body = json.decode(response.body) as Map<String, dynamic>;
      final docs = body['documents'] as List<dynamic>? ?? [];
      for (final doc in docs) {
        final fields = (doc as Map<String, dynamic>)['fields'] as Map<String, dynamic>?;
        if (fields == null) continue;
        final taskSyncId = _stringField(fields, 'task_sync_id');
        final dependsOnSyncId = _stringField(fields, 'depends_on_sync_id');
        if (taskSyncId != null && dependsOnSyncId != null) {
          results.add((taskSyncId: taskSyncId, dependsOnSyncId: dependsOnSyncId));
        }
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null);
    return results;
  }

  // --- Private helpers ---

  Future<List<Task>> _listAllTasks(String uid, String idToken) async {
    final tasks = <Task>[];
    String? pageToken;
    do {
      var url = '${_tasksPath(uid)}?pageSize=300';
      if (pageToken != null) url += '&pageToken=$pageToken';
      final response = await http.get(Uri.parse(url), headers: _headers(idToken));
      if (response.statusCode != 200) {
        throw FirestoreException('List tasks failed: ${response.statusCode}');
      }
      final body = json.decode(response.body) as Map<String, dynamic>;
      final docs = body['documents'] as List<dynamic>? ?? [];
      for (final doc in docs) {
        final task = taskFromFirestoreDoc(doc as Map<String, dynamic>);
        if (task != null) tasks.add(task);
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null);
    return tasks;
  }

  Future<List<Task>> _queryTasksUpdatedSince(
    String uid,
    String idToken,
    int lastSyncAt,
  ) async {
    final queryUrl = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents/users/$uid:runQuery',
    );
    final response = await http.post(
      queryUrl,
      headers: _headers(idToken),
      body: json.encode({
        'structuredQuery': {
          'from': [
            {'collectionId': 'tasks'},
          ],
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': 'updated_at'},
              'op': 'GREATER_THAN',
              'value': {'integerValue': lastSyncAt.toString()},
            },
          },
        },
      }),
    );
    if (response.statusCode != 200) {
      throw FirestoreException('Query tasks failed: ${response.statusCode}');
    }
    final results = json.decode(response.body) as List<dynamic>;
    final tasks = <Task>[];
    for (final result in results) {
      final doc = (result as Map<String, dynamic>)['document'] as Map<String, dynamic>?;
      if (doc == null) continue;
      final task = taskFromFirestoreDoc(doc);
      if (task != null) tasks.add(task);
    }
    return tasks;
  }

  @visibleForTesting
  Map<String, dynamic> taskToFirestoreFields(Task task) {
    return {
      'name': {'stringValue': task.name},
      'created_at': {'integerValue': task.createdAt.toString()},
      if (task.completedAt != null)
        'completed_at': {'integerValue': task.completedAt.toString()},
      if (task.startedAt != null)
        'started_at': {'integerValue': task.startedAt.toString()},
      if (task.url != null) 'url': {'stringValue': task.url},
      if (task.skippedAt != null)
        'skipped_at': {'integerValue': task.skippedAt.toString()},
      'priority': {'integerValue': task.priority.toString()},
      'difficulty': {'integerValue': task.difficulty.toString()},
      if (task.lastWorkedAt != null)
        'last_worked_at': {'integerValue': task.lastWorkedAt.toString()},
      if (task.repeatInterval != null)
        'repeat_interval': {'stringValue': task.repeatInterval},
      if (task.nextDueAt != null)
        'next_due_at': {'integerValue': task.nextDueAt.toString()},
      'updated_at': {'integerValue': (task.updatedAt ?? DateTime.now().millisecondsSinceEpoch).toString()},
    };
  }

  @visibleForTesting
  Task? taskFromFirestoreDoc(Map<String, dynamic> doc) {
    final fields = doc['fields'] as Map<String, dynamic>?;
    if (fields == null) return null;

    // Extract sync_id from document name (last path segment)
    final name = doc['name'] as String? ?? '';
    final syncId = name.split('/').last;

    return Task(
      name: _stringField(fields, 'name') ?? '',
      createdAt: _intField(fields, 'created_at'),
      completedAt: _intFieldNullable(fields, 'completed_at'),
      startedAt: _intFieldNullable(fields, 'started_at'),
      url: _stringField(fields, 'url'),
      skippedAt: _intFieldNullable(fields, 'skipped_at'),
      priority: _intField(fields, 'priority'),
      difficulty: _intField(fields, 'difficulty'),
      lastWorkedAt: _intFieldNullable(fields, 'last_worked_at'),
      repeatInterval: _stringField(fields, 'repeat_interval'),
      nextDueAt: _intFieldNullable(fields, 'next_due_at'),
      syncId: syncId,
      updatedAt: _intFieldNullable(fields, 'updated_at'),
      syncStatus: 'synced',
    );
  }

  String? _stringField(Map<String, dynamic> fields, String key) {
    final field = fields[key] as Map<String, dynamic>?;
    return field?['stringValue'] as String?;
  }

  int _intField(Map<String, dynamic> fields, String key) {
    final field = fields[key] as Map<String, dynamic>?;
    final val = field?['integerValue'];
    if (val is int) return val;
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }

  int? _intFieldNullable(Map<String, dynamic> fields, String key) {
    final field = fields[key] as Map<String, dynamic>?;
    if (field == null) return null;
    final val = field['integerValue'];
    if (val is int) return val;
    if (val is String) return int.tryParse(val);
    return null;
  }
}

class FirestoreException implements Exception {
  final String message;
  FirestoreException(this.message);
  @override
  String toString() => 'FirestoreException: $message';
}
