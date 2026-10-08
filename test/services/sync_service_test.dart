import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/models/task_schedule.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/services/firestore_service.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/utils/display_utils.dart' show todayDateKey;

/// Signed-in auth by default, so [SyncService] proceeds past its `_canSync`
/// gate. Tests flip [signedIn] to sign out, or set [tokenExpired] together with
/// [refreshSucceeds] = false to make `_getValidToken` return null.
class _FakeAuthProvider extends AuthProvider {
  bool signedIn = true;
  bool tokenExpired = false;
  bool refreshSucceeds = true;
  int signOutCalls = 0;

  /// If set, the FIRST `refreshToken()` call awaits this before returning
  /// [refreshSucceeds]. A push/pull/bulk op parked there holds `_syncing`
  /// without touching the database, which suits fake-time tests.
  Completer<void>? gateFirstRefresh;
  bool _firstRefreshGated = false;

  /// Every status passed to [setSyncStatus], in order.
  final List<SyncStatus> statuses = [];

  @override
  bool get isSignedIn => signedIn;
  @override
  String? get uid => 'test-uid';
  @override
  String? get firebaseIdToken => 'test-token';
  @override
  bool get isTokenExpired => tokenExpired;
  @override
  Future<bool> refreshToken() async {
    if (gateFirstRefresh != null && !_firstRefreshGated) {
      _firstRefreshGated = true;
      await gateFirstRefresh!.future;
    }
    return refreshSucceeds;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    signedIn = false;
  }

  @override
  void setSyncStatus(SyncStatus status, {String? error}) {
    statuses.add(status);
    super.setSyncStatus(status, error: error);
  }
}

/// Fake Firestore that records the `lastSyncAt` cursor each task pull is called
/// with and returns empty data for everything else, so a `pull()` runs the full
/// delta path against controllable inputs without any network/env config.
class _FakeFirestoreService extends FirestoreService {
  final List<int?> capturedTaskCursors = [];

  /// Relationships the delta pull should return (defaults to none).
  List<({String parentSyncId, String childSyncId, bool deleted})> relsSince =
      const [];

  /// Dependencies the delta pull should return (defaults to none).
  List<({String taskSyncId, String dependsOnSyncId, bool deleted})> depsSince =
      const [];

  /// Schedules the delta pull should return (defaults to none).
  List<Map<String, dynamic>> schedulesSince = const [];

  /// Task deltas the delta pull should return (defaults to none).
  List<({Task? task, String syncId, bool deleted})> tasksDeltaSince = const [];

  /// If set, the FIRST task pull awaits this before returning — lets a test
  /// hold `_syncing` true and issue a second pull that gets queued.
  Completer<void>? gateFirstTaskPull;
  bool _firstTaskPullGated = false;

  /// If set, `pullTasksSince` (the full-pull path) throws this — simulates
  /// `_listAllTasks` aborting on a non-200 page so a full pull never yields a
  /// partial remote set. Pins the I-49 "partial/failed fetch deletes nothing"
  /// invariant.
  Object? throwOnFullTaskPull;

  /// Records the `updatedAt` the last Today's-5 push was called with (I-48).
  int? capturedTodaysFiveUpdatedAt;

  /// Every write/delete call, as `method:arg1:arg2`, in call order. Pull calls
  /// are not recorded here (see [capturedTaskCursors]).
  final List<String> calls = [];

  /// Sync ids of every task passed to [pushTasks].
  final List<String?> pushedTaskSyncIds = [];

  /// Schedules passed to [pushSchedules].
  final List<Map<String, dynamic>> pushedSchedules = [];

  /// Entries and suppressions passed to the last [pushTodaysFive].
  List<Map<String, dynamic>>? pushedTodaysFiveEntries;
  List<String>? pushedSuppressedSyncIds;

  /// Method name → error that method throws. Keys are the [calls] method
  /// names plus `pullTodaysFive`.
  final Map<String, Object> failOn = {};

  /// If set, the first [pushTasks] call awaits this before returning.
  Completer<void>? gateFirstPushTasks;
  bool _firstPushTasksGated = false;

  /// What the full pull and the bulk ops read from "the cloud".
  List<Task> remoteTasks = const [];
  List<({String parentSyncId, String childSyncId})> allRels = const [];
  List<({String taskSyncId, String dependsOnSyncId})> allDeps = const [];
  List<Map<String, dynamic>> allSchedules = const [];
  ({
    List<Map<String, dynamic>> entries,
    List<String> suppressedSyncIds,
    int updatedAt
  })? todaysFive;

  /// Value [hasRemoteData] returns.
  bool remoteHasData = false;

  /// Collections passed to [cleanupTombstones].
  final List<String> cleanedCollections = [];

  /// If set, [cleanupTombstones] fails with this error.
  Object? cleanupError;

  void _record(String method, [List<String> args = const []]) {
    calls.add([method, ...args].join(':'));
    final error = failOn[method];
    if (error != null) throw error;
  }

  @override
  Future<void> pushTodaysFive(
    String uid,
    String idToken,
    String date,
    List<Map<String, dynamic>> entries,
    List<String> suppressedSyncIds,
    int updatedAt,
  ) async {
    _record('pushTodaysFive');
    capturedTodaysFiveUpdatedAt = updatedAt;
    pushedTodaysFiveEntries = entries;
    pushedSuppressedSyncIds = suppressedSyncIds;
  }

  @override
  Future<void> pushTasks(String uid, String idToken, List<Task> tasks) async {
    if (gateFirstPushTasks != null && !_firstPushTasksGated) {
      _firstPushTasksGated = true;
      await gateFirstPushTasks!.future;
    }
    _record('pushTasks', [tasks.length.toString()]);
    pushedTaskSyncIds.addAll(tasks.map((t) => t.syncId));
  }

  @override
  Future<void> pushRelationships(String uid, String idToken,
      List<({String parentSyncId, String childSyncId})> relationships) async {
    _record('pushRelationships',
        relationships.map((r) => '${r.parentSyncId}>${r.childSyncId}').toList());
  }

  @override
  Future<void> pushDependencies(String uid, String idToken,
      List<({String taskSyncId, String dependsOnSyncId})> dependencies) async {
    _record('pushDependencies',
        dependencies.map((d) => '${d.taskSyncId}>${d.dependsOnSyncId}').toList());
  }

  @override
  Future<void> pushSchedules(
      String uid, String idToken, List<Map<String, dynamic>> schedules) async {
    _record('pushSchedules', [schedules.length.toString()]);
    pushedSchedules.addAll(schedules);
  }

  @override
  Future<void> deleteTask(String uid, String idToken, String syncId) async {
    _record('deleteTask', [syncId]);
  }

  @override
  Future<void> deleteRelationship(String uid, String idToken,
      String parentSyncId, String childSyncId) async {
    _record('deleteRelationship', [parentSyncId, childSyncId]);
  }

  @override
  Future<void> deleteDependency(String uid, String idToken, String taskSyncId,
      String dependsOnSyncId) async {
    _record('deleteDependency', [taskSyncId, dependsOnSyncId]);
  }

  @override
  Future<void> deleteSchedule(
      String uid, String idToken, String scheduleSyncId) async {
    _record('deleteSchedule', [scheduleSyncId]);
  }

  @override
  Future<bool> hasRemoteData(String uid, String idToken) async {
    _record('hasRemoteData');
    return remoteHasData;
  }

  @override
  bool get isConfigured => true;

  Future<void> _maybeGate() async {
    if (gateFirstTaskPull != null && !_firstTaskPullGated) {
      _firstTaskPullGated = true;
      await gateFirstTaskPull!.future;
    }
  }

  @override
  Future<List<Task>> pullTasksSince(String uid, String idToken,
      {int? lastSyncAt}) async {
    // Full pulls call this with a null cursor (CR-fix I-49 split the delta path
    // out to pullTaskDeltasSince).
    capturedTaskCursors.add(lastSyncAt);
    await _maybeGate();
    if (throwOnFullTaskPull != null) throw throwOnFullTaskPull!;
    return remoteTasks;
  }

  @override
  Future<List<({Task? task, String syncId, bool deleted})>> pullTaskDeltasSince(
      String uid, String idToken, int lastSyncAt) async {
    capturedTaskCursors.add(lastSyncAt);
    await _maybeGate();
    return tasksDeltaSince;
  }

  @override
  Future<List<({String parentSyncId, String childSyncId})>>
      pullAllRelationships(String uid, String idToken) async => allRels;

  @override
  Future<List<({String parentSyncId, String childSyncId, bool deleted})>>
      pullRelationshipsSince(String uid, String idToken, int lastSyncAt) async =>
          relsSince;

  @override
  Future<List<({String taskSyncId, String dependsOnSyncId})>>
      pullAllDependencies(String uid, String idToken) async => allDeps;

  @override
  Future<List<({String taskSyncId, String dependsOnSyncId, bool deleted})>>
      pullDependenciesSince(String uid, String idToken, int lastSyncAt) async =>
          depsSince;

  @override
  Future<List<Map<String, dynamic>>> pullAllSchedules(
      String uid, String idToken) async => allSchedules;

  @override
  Future<List<Map<String, dynamic>>> pullSchedulesSince(
      String uid, String idToken, int lastSyncAt) async => schedulesSince;

  /// What [pullAllXpEvents] reads from "the cloud".
  List<Map<String, dynamic>> allXpEvents = const [];

  /// Number of times [pullAllXpEvents] was called.
  int xpFullPulls = 0;

  /// XP events the delta pull should return (defaults to none).
  List<Map<String, dynamic>> xpSince = const [];

  @override
  Future<List<Map<String, dynamic>>> pullXpEventsSince(
      String uid, String idToken, int lastSyncAt) async => xpSince;

  /// Sync ids of every XP event passed to [pushXpEvents].
  final List<String> pushedXpSyncIds = [];

  @override
  Future<List<Map<String, dynamic>>> pullAllXpEvents(
      String uid, String idToken) async {
    xpFullPulls++;
    return allXpEvents;
  }

  @override
  Future<void> pushXpEvents(String uid, String idToken,
      List<Map<String, dynamic>> xpEvents) async {
    _record('pushXpEvents', [xpEvents.length.toString()]);
    pushedXpSyncIds.addAll(xpEvents.map((e) => e['sync_id'] as String));
  }

  @override
  Future<void> deleteXpEvent(
      String uid, String idToken, String xpEventSyncId) async {
    _record('deleteXpEvent', [xpEventSyncId]);
  }

  @override
  Future<({List<Map<String, dynamic>> entries, List<String> suppressedSyncIds, int updatedAt})?>
      pullTodaysFive(String uid, String idToken, String date) async {
    final error = failOn['pullTodaysFive'];
    if (error != null) throw error;
    return todaysFive;
  }

  @override
  Future<void> cleanupTombstones(
      String uid, String idToken, String collectionId, Duration maxAge) {
    cleanedCollections.add(collectionId);
    if (cleanupError != null) return Future.error(cleanupError!);
    return Future.value();
  }
}

/// Adds a raw row to `sync_queue`, the way the DB helper's mutations do.
Future<void> _enqueue(DatabaseHelper db, String entityType, String action,
    String key1, [String key2 = '']) async {
  await (await db.database).insert('sync_queue', {
    'entity_type': entityType,
    'action': action,
    'key1': key1,
    'key2': key2,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
}

/// Inserts a task and marks it synced, so push() does not resend it and full
/// pulls may treat its absence from the cloud as a remote deletion.
Future<int> _syncedTask(DatabaseHelper db, String syncId) async {
  final id = await db.insertTask(Task(name: 'T-$syncId', syncId: syncId));
  await db.markTasksSynced([id]);
  return id;
}

void main() {
  // SharedPreferences mock needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const lookbackMs = 10 * 60 * 1000; // must match SyncService._deltaCursorLookback
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

  group('delta cursor skew lookback (bug: edits stranded below the cursor)', () {
    test('pull rewinds the persisted cursor by the lookback, not the raw wall clock',
        () async {
      // Prior sync exists → this is a delta pull.
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final sync = SyncService(_FakeAuthProvider(),
          firestore: _FakeFirestoreService());

      final before = DateTime.now().millisecondsSinceEpoch;
      await sync.pull();
      final after = DateTime.now().millisecondsSinceEpoch;

      final prefs = await SharedPreferences.getInstance();
      final cursor = prefs.getInt('sync_last_sync_at')!;

      // The new cursor is stamped at now-minus-lookback...
      expect(cursor, greaterThanOrEqualTo(before - lookbackMs));
      expect(cursor, lessThanOrEqualTo(after - lookbackMs));
      // ...i.e. it is rewound into the past, NOT the raw now() (the old bug,
      // where cursor >= before would strand a lagging writer's edits).
      expect(cursor, lessThan(before));
    });

    test('the following delta pull queries with the rewound cursor', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull(); // persists cursor = firstNow - lookback
      final persistedCursor =
          (await SharedPreferences.getInstance()).getInt('sync_last_sync_at')!;

      final secondPullNow = DateTime.now().millisecondsSinceEpoch;
      await sync.pull(); // should query tasks with the rewound cursor

      // First pull used the stored delta cursor; second used the rewound one.
      expect(fakeFs.capturedTaskCursors.first, 1000);
      expect(fakeFs.capturedTaskCursors.last, persistedCursor);
      // The cursor the second pull queries with sits at least the lookback
      // behind wall-now, so an edit stamped up to `lookback` in the past (a
      // device whose clock lags this one) is still inside the query window.
      expect(fakeFs.capturedTaskCursors.last, lessThanOrEqualTo(secondPullNow - lookbackMs));
    });
  });

  group('throttled full pull on open (bug: short web sessions never full-pull)', () {
    test('forces a full pull on open when the throttle window has elapsed', () async {
      // Prior delta cursor exists, but the last full pull was long ago (0).
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_last_full_pull_at': 0,
      });
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull(fullPullOnOpen: true);

      // A full pull clears the cursor → tasks are pulled with null (pull all).
      expect(fakeFs.capturedTaskCursors.single, isNull);
      // And the full-pull timestamp is recorded so the next open is throttled.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('sync_last_full_pull_at'), isNotNull);
      expect(prefs.getInt('sync_last_full_pull_at'), greaterThan(0));
    });

    test('stays a delta pull on open when within the throttle window', () async {
      final recent = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_last_full_pull_at': recent, // full pull just happened
      });
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull(fullPullOnOpen: true);

      // Within the window → no full pull; the delta cursor is used as-is.
      expect(fakeFs.capturedTaskCursors.single, 1000);
    });

    test('a normal periodic pull (not on open) never forces the open full pull',
        () async {
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_last_full_pull_at': 0, // long ago, but this isn't an open
      });
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull(); // fullPullOnOpen defaults to false

      expect(fakeFs.capturedTaskCursors.single, 1000); // delta, not full
    });
  });

  group('fullPullOnOpen carried through a deferred pull (bug: on-open full pull '
      'downgraded to delta when it lands during an in-flight sync)', () {
    test('a fullPullOnOpen queued while syncing is re-dispatched as a full pull',
        () async {
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_last_full_pull_at': 0, // full-pull throttle is elapsed
      });
      final fakeFs = _FakeFirestoreService()..gateFirstTaskPull = Completer<void>();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      // First pull (delta) parks inside pullTasksSince holding _syncing = true.
      final first = sync.pull();
      // Give it a moment to reach the gate.
      await Future.delayed(const Duration(milliseconds: 20));
      // This lands while syncing → gets queued as a pending pull.
      final second = sync.pull(fullPullOnOpen: true);
      // Release the first pull; its finally re-dispatches the queued pull.
      fakeFs.gateFirstTaskPull!.complete();
      await Future.wait([first, second]);
      // Wait for the re-dispatched pull to run.
      for (var i = 0; i < 100 && fakeFs.capturedTaskCursors.length < 2; i++) {
        await Future.delayed(const Duration(milliseconds: 5));
      }

      expect(fakeFs.capturedTaskCursors.first, 1000); // first pull: delta
      // The re-dispatched pull must honour fullPullOnOpen → full pull (null
      // cursor), not silently downgrade to a delta pull.
      expect(fakeFs.capturedTaskCursors.last, isNull);
    });
  });

  group('delta tombstone removal respects pending local adds (bug: a re-added '
      'edge flickers away)', () {
    Future<({String p, String c})> seedEdge() async {
      final pid = await db.insertTask(Task(name: 'Parent', syncId: 'sp'));
      final cid = await db.insertTask(Task(name: 'Child', syncId: 'sc'));
      await db.addRelationship(pid, cid); // also enqueues a pending 'add'
      return (p: 'sp', c: 'sc');
    }

    test('keeps the edge when its add is still pending push', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await seedEdge();

      final fakeFs = _FakeFirestoreService()
        ..relsSince = [(parentSyncId: 'sp', childSyncId: 'sc', deleted: true)];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      // The pending local add protects the just-re-created edge from the stale
      // remote tombstone — it must survive.
      final rels = await db.getAllRelationshipsWithSyncIds();
      expect(rels.any((r) => r.parentSyncId == 'sp' && r.childSyncId == 'sc'),
          isTrue);
    });

    test('removes the edge when there is no pending add', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await seedEdge();
      await db.drainSyncQueue(); // simulate the add already pushed

      final fakeFs = _FakeFirestoreService()
        ..relsSince = [(parentSyncId: 'sp', childSyncId: 'sc', deleted: true)];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      final rels = await db.getAllRelationshipsWithSyncIds();
      expect(rels.any((r) => r.parentSyncId == 'sp' && r.childSyncId == 'sc'),
          isFalse);
    });

    test('dependency branch: keeps the dep when its add is still pending',
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final tid = await db.insertTask(Task(name: 'Task', syncId: 'st'));
      final did = await db.insertTask(Task(name: 'Blocker', syncId: 'sd'));
      await db.addDependency(tid, did); // enqueues a pending 'add'

      final fakeFs = _FakeFirestoreService()
        ..depsSince = [
          (taskSyncId: 'st', dependsOnSyncId: 'sd', deleted: true)
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      final deps = await db.getAllDependenciesWithSyncIds();
      expect(deps.any((d) => d.taskSyncId == 'st' && d.dependsOnSyncId == 'sd'),
          isTrue);
    });

    test('schedule branch (key1-only shape): keeps the schedule when its add '
        'is still pending', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final tid = await db.insertTask(Task(name: 'Scheduled', syncId: 'stk'));
      await db.replaceSchedules(tid, [TaskSchedule(taskId: tid, dayOfWeek: 1)]);
      // The generated schedule sync_id (and its pending 'add' in sync_queue).
      final scheduleSyncId = (await db.getAllScheduleSyncIds()).single;

      final fakeFs = _FakeFirestoreService()
        ..schedulesSince = [
          {'sync_id': scheduleSyncId, 'deleted': true}
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      // Pending add (keyed by sync_id alone) protects it from the tombstone.
      expect(await db.getAllScheduleSyncIds(), contains(scheduleSyncId));
    });
  });

  group('task deletion propagation (bug I-49: deleted tasks resurrect on other '
      'devices)', () {
    Future<int> seedSyncedTask(String syncId) async {
      final id = await db.insertTask(Task(name: 'T-$syncId', syncId: syncId));
      await db.markTasksSynced([id]); // simulate already pushed to remote
      return id;
    }

    test('delta tombstone removes the local task', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await seedSyncedTask('gone');

      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [(task: null, syncId: 'gone', deleted: true)];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(await db.getAllTaskSyncIds(), isNot(contains('gone')));
    });

    test('delta tombstone respects a pending local re-add', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      // A locally re-created task not yet pushed (sync_status stays 'pending').
      await db.insertTask(Task(name: 'Re-added', syncId: 'readd'));

      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [(task: null, syncId: 'readd', deleted: true)];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      // The pending add protects it from the stale tombstone.
      expect(await db.getAllTaskSyncIds(), contains('readd'));
    });

    test('full pull removes a synced local task absent from remote', () async {
      // No prior cursor → this is a full pull; the fake returns no remote tasks.
      SharedPreferences.setMockInitialValues({});
      await seedSyncedTask('orphan');

      final sync = SyncService(_FakeAuthProvider(),
          firestore: _FakeFirestoreService());

      await sync.pull();

      expect(await db.getAllTaskSyncIds(), isNot(contains('orphan')));
    });

    test('full pull keeps a pending local task absent from remote', () async {
      SharedPreferences.setMockInitialValues({});
      // Pending (never-synced) local task — must survive reconciliation.
      await db.insertTask(Task(name: 'Fresh', syncId: 'fresh'));

      final sync = SyncService(_FakeAuthProvider(),
          firestore: _FakeFirestoreService());

      await sync.pull();

      expect(await db.getAllTaskSyncIds(), contains('fresh'));
    });
  });

  group("Today's-5 LWW clock basis (bug I-48: push-time stamp inverts LWW)", () {
    test('push sends the edit-time persisted-at stamp, not push-time now()',
        () async {
      SharedPreferences.setMockInitialValues({});
      final id = await db.insertTask(Task(name: 'Pinned', syncId: 'p5'));
      // Not pending → push() won't invoke the real (network) pushTasks.
      await db.markTasksSynced([id]);
      await db.saveTodaysFiveState(
        date: todayDateKey(),
        taskIds: [id],
        completedIds: const {},
        workedOnIds: const {},
        pinnedIds: {id},
      );
      // saveTodaysFiveState stamps persisted-at to now(); overwrite it with a
      // known, distinct EDIT-time value so we can tell it apart from push-time.
      const editStamp = 4242;
      await (await SharedPreferences.getInstance())
          .setInt(DatabaseHelper.prefsKeyTodaysFivePersistedAt, editStamp);

      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      final before = DateTime.now().millisecondsSinceEpoch;

      await sync.push();

      // Before the fix push stamped remote updated_at with push-time now(),
      // which the pull side compares against the edit-time localPersistedAt —
      // inverting LWW. It must now push the edit-time stamp (both sides share a
      // clock basis).
      expect(fakeFs.capturedTodaysFiveUpdatedAt, editStamp);
      expect(fakeFs.capturedTodaysFiveUpdatedAt, lessThan(before));
    });
  });

  group('bulk-op sync mutex (bug I-50: bulk ops raced push/pull)', () {
    test('a bulk op holds the mutex so a concurrent pull defers until it ends',
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final fakeFs = _FakeFirestoreService()
        ..gateFirstTaskPull = Completer<void>();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      // replaceLocalWithCloud runs under _runExclusive (holds _syncing) and
      // parks inside pullTasksSince (full pull → null cursor).
      final bulk = sync.replaceLocalWithCloud();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(fakeFs.capturedTaskCursors, [null]); // reached the gate

      // Issue a pull WHILE the bulk op holds the mutex. Before the fix the bulk
      // op didn't set _syncing, so this pull ran immediately and interleaved
      // (a second cursor would appear now). It must defer instead.
      final concurrent = sync.pull();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(fakeFs.capturedTaskCursors, [null]); // still deferred, no 2nd pull

      // Release the bulk op; its finally drains the pending pull.
      fakeFs.gateFirstTaskPull!.complete();
      await Future.wait([bulk, concurrent]);
      for (var i = 0; i < 100 && fakeFs.capturedTaskCursors.length < 2; i++) {
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // The deferred pull ran AFTER the bulk op finished → a real delta pull
      // (non-null cursor) now appears, and only then.
      expect(fakeFs.capturedTaskCursors.length, 2);
      expect(fakeFs.capturedTaskCursors.last, isNotNull);
    });
  });

  group('full-pull task reconciliation (I-49 delete authority)', () {
    // Seed one synced (non-pending) task with a sync_id, so it is eligible for
    // the "absent from remote → delete" reconciliation (pending tasks are
    // guarded and would survive regardless, which wouldn't test the invariant).
    Future<String> seedSyncedTask() async {
      final id = await db.insertTask(Task(name: 'Keeper'));
      await db.markTasksSynced([id]);
      final syncIds = await db.getAllTaskSyncIds();
      expect(syncIds, hasLength(1));
      return syncIds.first;
    }

    test('control: a complete (empty) remote set DOES delete a synced local '
        'task absent from it — proves the reconcile is live', () async {
      SharedPreferences.setMockInitialValues({}); // no cursor → full pull
      await seedSyncedTask();
      final fakeFs = _FakeFirestoreService(); // pullTasksSince returns []
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      // Absent from the (successfully fetched, empty) remote set → deleted.
      expect(await db.getAllTasks(), isEmpty);
    });

    test('invariant: a FAILED remote task fetch deletes nothing (guards against '
        'mistaking a partial/errored list for "all deleted")', () async {
      SharedPreferences.setMockInitialValues({}); // no cursor → full pull
      await seedSyncedTask();
      final fakeFs = _FakeFirestoreService()
        ..throwOnFullTaskPull = FirestoreException('List tasks failed: 500');
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      // pull() swallows the error internally (sets error status); it must abort
      // before the delete loop, leaving the local task intact.
      await sync.pull();

      final remaining = await db.getAllTasks();
      expect(remaining, hasLength(1));
      expect(remaining.first.name, 'Keeper');
    });
  });

  // CR I-54: the Today tab reloads only when this number changes, so it must
  // move on a pull that wrote local data and stay put on one that did not.
  group('dataChangeGeneration (I-54: push loop from sync status)', () {
    test('a pull that writes remote changes bumps the generation', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final id = await db.insertTask(Task(name: 'Gone', syncId: 'gone'));
      await db.markTasksSynced([id]);
      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [(task: null, syncId: 'gone', deleted: true)];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(sync.dataChangeGeneration, 1);
    });

    test('a pull with nothing new leaves the generation unchanged', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final sync =
          SyncService(_FakeAuthProvider(), firestore: _FakeFirestoreService());

      await sync.pull();

      expect(sync.dataChangeGeneration, 0);
    });

    // [Regression — CR I-54] The push sets `synced` too. The Today tab
    // reloaded on that `synced`, re-saved, and queued the next push. A push
    // must set `synced` without moving the generation.
    test('a push sets synced but leaves the generation unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      final id = await db.insertTask(Task(name: 'Pinned', syncId: 'pinned'));
      await db.markTasksSynced([id]);
      await db.saveTodaysFiveState(
        date: todayDateKey(),
        taskIds: [id],
        completedIds: const {},
        workedOnIds: const {},
        pinnedIds: {id},
      );
      final auth = _FakeAuthProvider();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      await sync.push();

      expect(auth.syncStatus, SyncStatus.synced);
      expect(sync.dataChangeGeneration, 0);
    });

    // [Mechanism] Replacing local data with the cloud copy rewrites the
    // database, so the Today tab must reload after it.
    test('replaceLocalWithCloud bumps the generation', () async {
      final sync =
          SyncService(_FakeAuthProvider(), firestore: _FakeFirestoreService());

      await sync.replaceLocalWithCloud();

      expect(sync.dataChangeGeneration, 1);
    });
  });

  group('push: pending tasks and the sync_queue', () {
    test('pending tasks are pushed, then marked synced', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      expect(fakeFs.pushedTaskSyncIds, ['new']);
      expect(await db.getPendingTasks(), isEmpty);
      expect(auth.syncStatus, SyncStatus.synced);
    });

    test('each queue entry type calls its Firestore method, in queue order, '
        'and the queue is emptied', () async {
      SharedPreferences.setMockInitialValues({});
      final tid = await _syncedTask(db, 'sched-owner');
      await db.replaceSchedules(tid, [TaskSchedule(taskId: tid, dayOfWeek: 3)]);
      final scheduleSyncId = (await db.getAllScheduleSyncIds()).single;
      await db.drainSyncQueue();

      await _enqueue(db, 'task', 'remove', 'dead-task');
      await _enqueue(db, 'relationship', 'add', 'p', 'c');
      await _enqueue(db, 'relationship', 'remove', 'p2', 'c2');
      await _enqueue(db, 'dependency', 'add', 'a', 'b');
      await _enqueue(db, 'dependency', 'remove', 'a2', 'b2');
      await _enqueue(db, 'schedule', 'add', scheduleSyncId);
      // A schedule deleted locally before its add was pushed: nothing to send.
      await _enqueue(db, 'schedule', 'add', 'no-such-schedule');
      await _enqueue(db, 'schedule', 'remove', 'old-schedule');

      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.push();

      // No pending tasks and no Today's 5 → neither pushTasks nor
      // pushTodaysFive is called.
      expect(fakeFs.calls, [
        'deleteTask:dead-task',
        'pushRelationships:p>c',
        'deleteRelationship:p2:c2',
        'pushDependencies:a>b',
        'deleteDependency:a2:b2',
        'pushSchedules:1',
        'deleteSchedule:old-schedule',
      ]);
      expect(fakeFs.pushedSchedules.single['task_sync_id'], 'sched-owner');
      expect(fakeFs.pushedSchedules.single['day_of_week'], 3);
      expect(await db.peekSyncQueue(), isEmpty);
    });

    test('a failing entry keeps itself and every later entry queued; earlier '
        'entries are removed', () async {
      SharedPreferences.setMockInitialValues({});
      await _enqueue(db, 'relationship', 'add', 'p', 'c');
      await _enqueue(db, 'relationship', 'remove', 'p2', 'c2');
      await _enqueue(db, 'dependency', 'add', 'a', 'b');
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..failOn['deleteRelationship'] =
            FirestoreException('Soft-delete failed (users/test-uid/x): 503');
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      final left = await db.peekSyncQueue();
      expect(left.map((e) => '${e['entity_type']}:${e['action']}'),
          ['relationship:remove', 'dependency:add']);
      expect(fakeFs.calls, isNot(contains('pushDependencies:a>b')));
      expect(auth.syncStatus, SyncStatus.error);
      expect(auth.syncError, 'Sync failed — please try again');
    });

    test('a failed task push leaves the task pending for the next push',
        () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      await _enqueue(db, 'task', 'remove', 'dead-task');
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..failOn['pushTasks'] = const SocketException('Connection refused');
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      expect((await db.getPendingTasks()).single.syncId, 'new');
      expect(await db.peekSyncQueue(), hasLength(1));
      expect(auth.syncStatus, SyncStatus.error);
    });

    test('a failed token refresh pushes nothing and returns to idle', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      expect(fakeFs.calls, isEmpty);
      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.idle]);
      expect(await db.getPendingTasks(), hasLength(1));
    });

    test('an expired token that refreshes still pushes', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      final auth = _FakeAuthProvider()..tokenExpired = true;
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      expect(fakeFs.pushedTaskSyncIds, ['new']);
      expect(auth.syncStatus, SyncStatus.synced);
    });

    test('push does nothing when signed out', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      final auth = _FakeAuthProvider()..signedIn = false;
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.push();

      expect(fakeFs.calls, isEmpty);
      expect(auth.statuses, isEmpty);
    });

    test("Today's 5 push sends deadline suppressions, and stamps now() when "
        'no local persisted-at stamp exists', () async {
      SharedPreferences.setMockInitialValues({});
      final id = await _syncedTask(db, 'removed-due-today');
      await db.suppressDeadlineAutoPin(todayDateKey(), id);
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      final before = DateTime.now().millisecondsSinceEpoch;

      await sync.push();

      final after = DateTime.now().millisecondsSinceEpoch;
      expect(fakeFs.pushedTodaysFiveEntries, isEmpty);
      expect(fakeFs.pushedSuppressedSyncIds, ['removed-due-today']);
      expect(fakeFs.capturedTodaysFiveUpdatedAt,
          inInclusiveRange(before, after));
    });
  });

  // _userFriendlyError: the status bar shows syncError, so it must be one of
  // four fixed messages and never the exception text (which can hold hosts,
  // paths or Firestore response bodies).
  group('error status mapping (no raw exception text in syncError)', () {
    Future<_FakeAuthProvider> pullFailingWith(Object error) async {
      SharedPreferences.setMockInitialValues({}); // full pull
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()..throwOnFullTaskPull = error;
      await SyncService(auth, firestore: fakeFs).pull();
      return auth;
    }

    final cases = <String, (Object, String)>{
      'SocketException': (
        const SocketException('Failed host lookup: secret.internal'),
        'Sync failed — check your connection',
      ),
      'FirestoreException': (
        FirestoreException('List tasks failed: 500 {"detail":"secret"}'),
        'Sync failed — please try again',
      ),
      'TimeoutException': (
        TimeoutException('secret request timed out', const Duration(seconds: 30)),
        'Sync timed out — try again later',
      ),
      'any other error': (
        StateError('secret /home/user/db path'),
        'Sync error — try again later',
      ),
    };

    cases.forEach((name, c) {
      test('$name maps to "${c.$2}"', () async {
        final auth = await pullFailingWith(c.$1);

        expect(auth.syncStatus, SyncStatus.error);
        expect(auth.syncError, c.$2);
        expect(auth.syncError, isNot(contains('secret')));
      });
    });

    test('a failed pull advances neither the delta cursor nor the full-pull '
        'cycle counter (M-40)', () async {
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_pull_cycle_count': 3,
      });
      final fakeFs = _FakeFirestoreService()
        ..failOn['pullTodaysFive'] = FirestoreException('boom');
      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('sync_last_sync_at'), 1000);
      expect(prefs.getInt('sync_pull_cycle_count'), 3);
    });
  });

  group('first sign-in: migration choices', () {
    Future<void> seedLocalGraph() async {
      final p = await db.insertTask(Task(name: 'Parent', syncId: 'lp'));
      final c = await db.insertTask(Task(name: 'Child', syncId: 'lc'));
      await db.addRelationship(p, c);
      await db.addDependency(p, c);
      await db.replaceSchedules(c, [TaskSchedule(taskId: c, dayOfWeek: 2)]);
    }

    test('needsInitialMigration is true for a new user and false once the '
        'migration has run', () async {
      SharedPreferences.setMockInitialValues({});
      final sync =
          SyncService(_FakeAuthProvider(), firestore: _FakeFirestoreService());

      expect(await sync.needsInitialMigration(), isTrue);
      await sync.initialMigration();
      expect(await sync.needsInitialMigration(), isFalse);
    });

    test('needsInitialMigration and hasCloudData are false when signed out',
        () async {
      SharedPreferences.setMockInitialValues({});
      final fakeFs = _FakeFirestoreService()..remoteHasData = true;
      final sync =
          SyncService(_FakeAuthProvider()..signedIn = false, firestore: fakeFs);

      expect(await sync.needsInitialMigration(), isFalse);
      expect(await sync.hasCloudData(), isFalse);
      expect(fakeFs.calls, isEmpty);
    });

    test('hasCloudData returns what Firestore reports', () async {
      final fakeFs = _FakeFirestoreService()..remoteHasData = true;
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      expect(await sync.hasCloudData(), isTrue);
      fakeFs.remoteHasData = false;
      expect(await sync.hasCloudData(), isFalse);
    });

    test('hasCloudData is false without asking Firestore when the token '
        'refresh fails', () async {
      final fakeFs = _FakeFirestoreService()..remoteHasData = true;
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final sync = SyncService(auth, firestore: fakeFs);

      expect(await sync.hasCloudData(), isFalse);
      expect(fakeFs.calls, isEmpty);
    });

    test('initialMigration uploads every local task, edge, dependency and '
        'schedule, then empties the queue', () async {
      SharedPreferences.setMockInitialValues({});
      await seedLocalGraph();
      await _syncedTask(db, 'already-synced');
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.initialMigration();

      // All tasks go up, including one already marked synced.
      expect(fakeFs.pushedTaskSyncIds,
          unorderedEquals(['lp', 'lc', 'already-synced']));
      expect(fakeFs.calls, contains('pushRelationships:lp>lc'));
      expect(fakeFs.calls, contains('pushDependencies:lp>lc'));
      expect(fakeFs.pushedSchedules.single['task_sync_id'], 'lc');
      expect(await db.getPendingTasks(), isEmpty);
      expect(await db.peekSyncQueue(), isEmpty);
      expect(auth.syncStatus, SyncStatus.synced);
      expect((await SharedPreferences.getInstance()).getInt('sync_last_sync_at'),
          isNotNull);
    });

    test('initialMigration skips pushSchedules when there are none', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Solo', syncId: 'solo'));
      final fakeFs = _FakeFirestoreService();

      await SyncService(_FakeAuthProvider(), firestore: fakeFs)
          .initialMigration();

      expect(fakeFs.calls.where((c) => c.startsWith('pushSchedules')), isEmpty);
    });

    test('initialMigration runs once per user: a second call sends nothing',
        () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Solo', syncId: 'solo'));
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.initialMigration();
      final callsAfterFirst = List.of(fakeFs.calls);
      await db.insertTask(Task(name: 'Later', syncId: 'later'));
      await sync.initialMigration();

      expect(fakeFs.calls, callsAfterFirst);
    });

    test('a failed initialMigration sets an error and is retried next time '
        '(not marked done, tasks stay pending)', () async {
      SharedPreferences.setMockInitialValues({});
      await seedLocalGraph();
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..failOn['pushRelationships'] = const SocketException('offline');
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.initialMigration();

      expect(auth.syncStatus, SyncStatus.error);
      expect(auth.syncError, 'Sync failed — check your connection');
      expect(await sync.needsInitialMigration(), isTrue);
      expect(await db.getPendingTasks(), hasLength(2));
    });

    test('initialMigration with a failed token refresh returns to idle and is '
        'not marked done', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.initialMigration();

      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.idle]);
      expect(fakeFs.calls, isEmpty);
      expect(await sync.needsInitialMigration(), isTrue);
    });

    test('replaceLocalWithCloud wipes local data and loads tasks, edges, '
        "dependencies, schedules and Today's 5 from the cloud", () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Local only', syncId: 'local-only'));
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [
          Task(name: 'Cloud parent', syncId: 'cp', updatedAt: 10),
          Task(name: 'Cloud child', syncId: 'cc', updatedAt: 10),
        ]
        ..allRels = [(parentSyncId: 'cp', childSyncId: 'cc')]
        ..allDeps = [(taskSyncId: 'cp', dependsOnSyncId: 'cc')]
        ..allSchedules = [
          {'sync_id': 'cs', 'task_sync_id': 'cc', 'day_of_week': 5,
              'updated_at': 10},
        ]
        ..todaysFive = (
          entries: [
            {'task_sync_id': 'cc', 'is_completed': false,
                'is_worked_on': false, 'is_pinned': true, 'sort_order': 0},
          ],
          suppressedSyncIds: const <String>[],
          updatedAt: 10,
        );
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      var dataChangedCalls = 0;
      sync.onDataChanged = () => dataChangedCalls++;

      await sync.replaceLocalWithCloud();

      expect(await db.getAllTaskSyncIds(), unorderedEquals(['cp', 'cc']));
      expect(await db.getAllRelationshipsWithSyncIds(),
          [(parentSyncId: 'cp', childSyncId: 'cc')]);
      expect(await db.getAllDependenciesWithSyncIds(),
          [(taskSyncId: 'cp', dependsOnSyncId: 'cc')]);
      expect(await db.getAllScheduleSyncIds(), ['cs']);
      final today = await db.loadTodaysFiveState(todayDateKey());
      final cc = await db.getTaskBySyncId('cc');
      expect(today!.taskIds, [cc!.id]);
      expect(dataChangedCalls, 1);
      expect(await sync.needsInitialMigration(), isFalse);
    });

    // [Documents actual behaviour] The wipe runs before the cloud reads, so a
    // failure part-way leaves local data deleted and only part of the cloud
    // copy loaded. The error is reported; nothing is rolled back.
    test('a replaceLocalWithCloud failure after the wipe reports an error and '
        'leaves the local data deleted', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Local only', syncId: 'local-only'));
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'Cloud', syncId: 'cloud', updatedAt: 1)]
        ..failOn['pullTodaysFive'] = FirestoreException('Pull failed: 500');
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.replaceLocalWithCloud();

      expect(auth.syncStatus, SyncStatus.error);
      expect(auth.syncError, 'Sync failed — please try again');
      expect(await db.getAllTaskSyncIds(), ['cloud']);
      expect(sync.dataChangeGeneration, 0);
      expect(await sync.needsInitialMigration(), isTrue);
    });

    test('replaceLocalWithCloud with a failed token refresh keeps local data',
        () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Local only', syncId: 'local-only'));
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      await sync.replaceLocalWithCloud();

      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.idle]);
      expect(await db.getAllTaskSyncIds(), ['local-only']);
    });

    test('replaceCloudWithLocal deletes every cloud record, then uploads all '
        'local data', () async {
      SharedPreferences.setMockInitialValues({});
      await seedLocalGraph();
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [
          Task(name: 'Cloud', syncId: 'rt'),
          // A remote task with no sync id cannot be addressed; it is skipped.
          Task(name: 'No id'),
        ]
        ..allRels = [(parentSyncId: 'rp', childSyncId: 'rc')]
        ..allDeps = [(taskSyncId: 'rd', dependsOnSyncId: 're')]
        ..allSchedules = [
          {'sync_id': 'rs', 'task_sync_id': 'rt', 'day_of_week': 1}
        ];
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.replaceCloudWithLocal();

      expect(fakeFs.calls.take(4), [
        'deleteTask:rt',
        'deleteRelationship:rp:rc',
        'deleteDependency:rd:re',
        'deleteSchedule:rs',
      ]);
      expect(fakeFs.calls.skip(4), [
        'pushTasks:2',
        'pushRelationships:lp>lc',
        'pushDependencies:lp>lc',
        'pushSchedules:1',
      ]);
      expect(await db.getPendingTasks(), isEmpty);
      expect(await db.peekSyncQueue(), isEmpty);
      expect(auth.syncStatus, SyncStatus.synced);
      expect(await sync.needsInitialMigration(), isFalse);
    });

    test('a replaceCloudWithLocal failure sets an error and leaves local data '
        'pending', () async {
      SharedPreferences.setMockInitialValues({});
      await seedLocalGraph();
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'Cloud', syncId: 'rt')]
        ..failOn['deleteTask'] = TimeoutException('slow');
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.replaceCloudWithLocal();

      expect(auth.syncStatus, SyncStatus.error);
      expect(auth.syncError, 'Sync timed out — try again later');
      expect(await db.getPendingTasks(), hasLength(2));
      expect(await sync.needsInitialMigration(), isTrue);
    });

    test('replaceCloudWithLocal with a failed token refresh touches nothing',
        () async {
      SharedPreferences.setMockInitialValues({});
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'Cloud', syncId: 'rt')];

      await SyncService(auth, firestore: fakeFs).replaceCloudWithLocal();

      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.idle]);
      expect(fakeFs.calls, isEmpty);
    });

    test('bulk ops do nothing when signed out', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Local', syncId: 'local'));
      final auth = _FakeAuthProvider()..signedIn = false;
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(auth, firestore: fakeFs);

      await sync.initialMigration();
      await sync.replaceLocalWithCloud();
      await sync.replaceCloudWithLocal();

      expect(auth.statuses, isEmpty);
      expect(fakeFs.calls, isEmpty);
      expect(await db.getAllTaskSyncIds(), ['local']);
    });

    // [Documents actual behaviour] initialMigration stamps the delta cursor
    // with now(), so the pull inside mergeBoth is a DELTA pull: it fetches
    // only cloud records changed after the upload, not the older cloud data
    // the user chose to merge. profile_icon.dart follows mergeBoth with
    // startPeriodicPull, whose on-open full pull fetches the rest.
    test('mergeBoth uploads local data, then runs a delta pull from the '
        'cursor the upload set', () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'Local', syncId: 'local'));
      final fakeFs = _FakeFirestoreService()
        // Only reachable through a full pull.
        ..remoteTasks = [Task(name: 'Old cloud', syncId: 'old', updatedAt: 1)]
        ..tasksDeltaSince = [
          (task: Task(name: 'New cloud', syncId: 'new', updatedAt: 1),
              syncId: 'new', deleted: false),
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      final before = DateTime.now().millisecondsSinceEpoch;

      await sync.mergeBoth();

      expect(fakeFs.pushedTaskSyncIds, ['local']);
      expect(fakeFs.capturedTaskCursors.single,
          greaterThanOrEqualTo(before));
      expect(await db.getAllTaskSyncIds(), unorderedEquals(['local', 'new']));
    });

    test('a bulk op started while a push holds the sync lock waits for it',
        () async {
      SharedPreferences.setMockInitialValues({});
      await db.insertTask(Task(name: 'New', syncId: 'new'));
      final fakeFs = _FakeFirestoreService()
        ..gateFirstPushTasks = Completer<void>();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      final push = sync.push();
      await Future.delayed(const Duration(milliseconds: 20));
      var migrationDone = false;
      final migration =
          sync.initialMigration().then((_) => migrationDone = true);
      await Future.delayed(const Duration(milliseconds: 120));
      expect(migrationDone, isFalse); // still polling for the lock

      fakeFs.gateFirstPushTasks!.complete();
      await Future.wait([push, migration]);

      // The push finished its pushTasks before the migration sent anything.
      expect(fakeFs.calls.first, 'pushTasks:1');
      expect(fakeFs.calls.where((c) => c.startsWith('pushTasks')),
          hasLength(2));
    });
  });

  group('syncNow', () {
    test('pushes local changes, then pulls remote ones', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await db.insertTask(Task(name: 'Local', syncId: 'local'));
      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [
          (task: Task(name: 'Cloud', syncId: 'cloud', updatedAt: 1),
              syncId: 'cloud', deleted: false),
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.syncNow();

      expect(fakeFs.pushedTaskSyncIds, ['local']);
      expect(await db.getAllTaskSyncIds(), unorderedEquals(['local', 'cloud']));
    });
  });

  group('pull: delta branches', () {
    test('a remote task insert or newer edit is applied and onDataChanged '
        'fires once', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final id = await _syncedTask(db, 'edited');
      final local = (await db.getTaskBySyncId('edited'))!;
      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [
          (task: Task(name: 'Brand new', syncId: 'fresh', updatedAt: 5),
              syncId: 'fresh', deleted: false),
          (task: Task(name: 'Renamed', syncId: 'edited',
                  updatedAt: (local.updatedAt ?? 0) + 1000),
              syncId: 'edited', deleted: false),
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      var dataChangedCalls = 0;
      sync.onDataChanged = () => dataChangedCalls++;

      await sync.pull();

      expect((await db.getTaskBySyncId('fresh'))!.name, 'Brand new');
      expect((await db.getTaskById(id))!.name, 'Renamed');
      expect(dataChangedCalls, 1);
      expect(sync.dataChangeGeneration, 1);
    });

    test('a remote edit older than the local copy is ignored', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final id = await db.insertTask(
          Task(name: 'Local name', syncId: 'mine', updatedAt: 9000));
      await db.markTasksSynced([id]);
      final fakeFs = _FakeFirestoreService()
        ..tasksDeltaSince = [
          (task: Task(name: 'Stale', syncId: 'mine', updatedAt: 1),
              syncId: 'mine', deleted: false),
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect((await db.getTaskById(id))!.name, 'Local name');
      expect(sync.dataChangeGeneration, 0);
    });

    test('a remote edge is added, but one that would make a cycle is skipped',
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final a = await _syncedTask(db, 'a');
      final b = await _syncedTask(db, 'b');
      await _syncedTask(db, 'c');
      await db.addRelationship(a, b); // local a → b
      await db.drainSyncQueue();
      final fakeFs = _FakeFirestoreService()
        ..relsSince = [
          (parentSyncId: 'b', childSyncId: 'c', deleted: false),
          (parentSyncId: 'b', childSyncId: 'a', deleted: false), // b → a cycles
        ];

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(await db.getAllRelationshipsWithSyncIds(), unorderedEquals([
        (parentSyncId: 'a', childSyncId: 'b'),
        (parentSyncId: 'b', childSyncId: 'c'),
      ]));
    });

    test('a remote dependency is added, but one that would make a cycle is '
        'skipped; a tombstone removes one', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final a = await _syncedTask(db, 'a');
      final b = await _syncedTask(db, 'b');
      final c = await _syncedTask(db, 'c');
      await db.addDependency(a, b); // a waits on b
      await db.addDependency(c, a); // c waits on a
      await db.drainSyncQueue();
      final fakeFs = _FakeFirestoreService()
        ..depsSince = [
          (taskSyncId: 'b', dependsOnSyncId: 'a', deleted: false), // cycles
          (taskSyncId: 'c', dependsOnSyncId: 'b', deleted: false),
          (taskSyncId: 'c', dependsOnSyncId: 'a', deleted: true),
        ];

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(await db.getAllDependenciesWithSyncIds(), unorderedEquals([
        (taskSyncId: 'a', dependsOnSyncId: 'b'),
        (taskSyncId: 'c', dependsOnSyncId: 'b'),
      ]));
    });

    test('a remote schedule is upserted and a schedule tombstone deletes the '
        'local schedule', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final tid = await _syncedTask(db, 'owner');
      await db.replaceSchedules(tid, [TaskSchedule(taskId: tid, dayOfWeek: 1)]);
      final oldScheduleId = (await db.getAllScheduleSyncIds()).single;
      await db.drainSyncQueue();
      final fakeFs = _FakeFirestoreService()
        ..schedulesSince = [
          {'sync_id': oldScheduleId, 'deleted': true},
          {'sync_id': 'remote-sched', 'task_sync_id': 'owner',
              'day_of_week': 6, 'updated_at': 5},
        ];

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(await db.getAllScheduleSyncIds(), ['remote-sched']);
    });

    test('a delta pull does not clean up tombstones', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final fakeFs = _FakeFirestoreService();

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(fakeFs.cleanedCollections, isEmpty);
    });

    test('a pull with a failed token refresh returns to idle and keeps the '
        'cursor', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final auth = _FakeAuthProvider()
        ..tokenExpired = true
        ..refreshSucceeds = false;
      final fakeFs = _FakeFirestoreService();

      await SyncService(auth, firestore: fakeFs).pull();

      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.idle]);
      expect(fakeFs.capturedTaskCursors, isEmpty);
      expect((await SharedPreferences.getInstance()).getInt('sync_last_sync_at'),
          1000);
    });

    test('pull does nothing when signed out', () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final auth = _FakeAuthProvider()..signedIn = false;
      final fakeFs = _FakeFirestoreService();

      await SyncService(auth, firestore: fakeFs).pull();

      expect(auth.statuses, isEmpty);
      expect(fakeFs.capturedTaskCursors, isEmpty);
    });
  });

  group('pull: full reconciliation branches', () {
    test('every 10th pull is a full pull, and the counter is saved after it',
        () async {
      SharedPreferences.setMockInitialValues({
        'sync_last_sync_at': 1000,
        'sync_pull_cycle_count': 9,
      });
      final fakeFs = _FakeFirestoreService();

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(fakeFs.capturedTaskCursors.single, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('sync_pull_cycle_count'), 10);
      expect(prefs.getInt('sync_last_full_pull_at'), isNotNull);
    });

    test('remote tasks, edges, dependencies and schedules are applied; synced '
        'local ones missing from the cloud are removed', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await _syncedTask(db, 'a');
      final b = await _syncedTask(db, 'b');
      await db.addRelationship(a, b); // local only, already pushed
      await db.addDependency(a, b);
      await db.replaceSchedules(b, [TaskSchedule(taskId: b, dayOfWeek: 4)]);
      await db.drainSyncQueue();
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [
          Task(name: 'A', syncId: 'a'),
          Task(name: 'B', syncId: 'b'),
          Task(name: 'C', syncId: 'c', updatedAt: 1),
        ]
        ..allRels = [(parentSyncId: 'a', childSyncId: 'c')]
        ..allDeps = [(taskSyncId: 'c', dependsOnSyncId: 'b')]
        ..allSchedules = [
          {'sync_id': 'cs', 'task_sync_id': 'c', 'day_of_week': 0,
              'updated_at': 1},
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(await db.getAllTaskSyncIds(), unorderedEquals(['a', 'b', 'c']));
      expect(await db.getAllRelationshipsWithSyncIds(),
          [(parentSyncId: 'a', childSyncId: 'c')]);
      expect(await db.getAllDependenciesWithSyncIds(),
          [(taskSyncId: 'c', dependsOnSyncId: 'b')]);
      expect(await db.getAllScheduleSyncIds(), ['cs']);
      expect(sync.dataChangeGeneration, 1);
    });

    test('local edges, dependencies and schedules not yet pushed survive a '
        'full pull that lacks them', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await _syncedTask(db, 'a');
      final b = await _syncedTask(db, 'b');
      await db.addRelationship(a, b); // each enqueues a pending 'add'
      await db.addDependency(a, b);
      await db.replaceSchedules(b, [TaskSchedule(taskId: b, dayOfWeek: 4)]);
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'A', syncId: 'a'), Task(name: 'B', syncId: 'b')];

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(await db.getAllRelationshipsWithSyncIds(), hasLength(1));
      expect(await db.getAllDependenciesWithSyncIds(), hasLength(1));
      expect(await db.getAllScheduleSyncIds(), hasLength(1));
    });

    test('a full pull skips remote edges and dependencies that would make a '
        'cycle', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await _syncedTask(db, 'a');
      final b = await _syncedTask(db, 'b');
      await db.addRelationship(a, b);
      await db.addDependency(a, b);
      await db.drainSyncQueue();
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'A', syncId: 'a'), Task(name: 'B', syncId: 'b')]
        ..allRels = [
          (parentSyncId: 'a', childSyncId: 'b'),
          (parentSyncId: 'b', childSyncId: 'a'),
        ]
        ..allDeps = [
          (taskSyncId: 'a', dependsOnSyncId: 'b'),
          (taskSyncId: 'b', dependsOnSyncId: 'a'),
        ];

      await SyncService(_FakeAuthProvider(), firestore: fakeFs).pull();

      expect(await db.getAllRelationshipsWithSyncIds(),
          [(parentSyncId: 'a', childSyncId: 'b')]);
      expect(await db.getAllDependenciesWithSyncIds(),
          [(taskSyncId: 'a', dependsOnSyncId: 'b')]);
    });

    test('a full pull cleans up tombstones in all five collections, and a '
        'cleanup failure does not fail the pull', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = _FakeAuthProvider();
      final fakeFs = _FakeFirestoreService()
        ..cleanupError = FirestoreException('cleanup failed');

      await SyncService(auth, firestore: fakeFs).pull();
      // Let the unawaited cleanup futures settle into their catchError.
      await Future.delayed(Duration.zero);

      expect(fakeFs.cleanedCollections,
          ['tasks', 'relationships', 'dependencies', 'schedules', 'xp_events']);
      expect(auth.syncStatus, SyncStatus.synced);
    });
  });

  group("pull: Today's 5", () {
    test("remote Today's 5 is merged into local state and counts as a change",
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final id = await _syncedTask(db, 'pin-me');
      final fakeFs = _FakeFirestoreService()
        ..todaysFive = (
          entries: [
            {'task_sync_id': 'pin-me', 'is_completed': false,
                'is_worked_on': false, 'is_pinned': true, 'sort_order': 0},
          ],
          suppressedSyncIds: const <String>[],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      final today = await db.loadTodaysFiveState(todayDateKey());
      expect(today!.taskIds, [id]);
      expect(today.pinnedIds, {id});
      expect(sync.dataChangeGeneration, 1);
    });

    test("an empty remote Today's 5 document leaves local state alone",
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final id = await _syncedTask(db, 'mine');
      await db.saveTodaysFiveState(
        date: todayDateKey(),
        taskIds: [id],
        completedIds: const {},
        workedOnIds: const {},
        pinnedIds: {id},
      );
      final fakeFs = _FakeFirestoreService()
        ..todaysFive = (
          entries: const <Map<String, dynamic>>[],
          suppressedSyncIds: const <String>[],
          updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
        );
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect((await db.loadTodaysFiveState(todayDateKey()))!.taskIds, [id]);
      expect(sync.dataChangeGeneration, 0);
    });
  });

  // These run in fake time (testWidgets) so the 5 s push debounce and the
  // 5 min pull interval can be stepped through. The token refresh fails in
  // most of them, so each push/pull records [syncing, idle] and returns
  // without touching the database (whose I/O stalls inside fake time).
  group('timers: push debounce and periodic pull', () {
    _FakeAuthProvider offlineAuth() => _FakeAuthProvider()
      ..tokenExpired = true
      ..refreshSucceeds = false;
    const pushRun = [SyncStatus.syncing, SyncStatus.idle];

    testWidgets('schedulePush waits 5 s, and a second call restarts the wait',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.schedulePush();
      await tester.pump(const Duration(seconds: 3));
      sync.onTodaysFivePersisted(); // restarts the 5 s debounce
      await tester.pump(const Duration(seconds: 4));
      expect(auth.statuses, isEmpty);

      await tester.pump(const Duration(seconds: 1));
      expect(auth.statuses, pushRun); // exactly one push
    });

    testWidgets('a debounced push does nothing if signed out by then',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.schedulePush();
      auth.signedIn = false;
      await tester.pump(const Duration(seconds: 6));

      expect(auth.statuses, isEmpty);
    });

    testWidgets('flushPush pushes at once and cancels the pending debounce',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.schedulePush();
      sync.flushPush();
      await tester.pump();
      expect(auth.statuses, pushRun);

      await tester.pump(const Duration(seconds: 6));
      expect(auth.statuses, pushRun); // the debounce did not fire again
    });

    testWidgets('flushPush does nothing when no push is pending',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.flushPush();
      await tester.pump();

      expect(auth.statuses, isEmpty);
    });

    testWidgets('handleSignOut cancels the pending push and signs out',
        (tester) async {
      final auth = offlineAuth()..signedIn = true;
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.schedulePush();
      await sync.handleSignOut();
      // Sign back in so a push that survived the cancel would run.
      auth.signedIn = true;
      await tester.pump(const Duration(seconds: 6));

      expect(auth.signOutCalls, 1);
      expect(auth.statuses, isEmpty);
    });

    testWidgets('dispose cancels the pending push and the periodic pull',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.startPeriodicPull();
      await tester.pump();
      auth.statuses.clear(); // drop the immediate pull
      sync.schedulePush();
      sync.dispose();
      await tester.pump(const Duration(minutes: 6));

      expect(auth.statuses, isEmpty);
    });

    testWidgets('startPeriodicPull pulls at once, then every 5 minutes',
        (tester) async {
      final auth = offlineAuth();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.startPeriodicPull();
      await tester.pump();
      expect(auth.statuses, pushRun);

      await tester.pump(const Duration(minutes: 5));
      expect(auth.statuses, [...pushRun, ...pushRun]);

      // While signed out the timer keeps ticking but does not pull.
      auth.signedIn = false;
      await tester.pump(const Duration(minutes: 5));
      expect(auth.statuses, [...pushRun, ...pushRun]);
      sync.dispose();
    });

    testWidgets('startPeriodicPull does not pull at once when signed out',
        (tester) async {
      final auth = offlineAuth()..signedIn = false;
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      sync.startPeriodicPull();
      await tester.pump();

      expect(auth.statuses, isEmpty);
      sync.dispose();
    });

    // CR-fix M-41: right after a successful push the cloud matches what this
    // device sent, so the next periodic tick is skipped.
    testWidgets('a successful push skips the next periodic pull only',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final auth = _FakeAuthProvider();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());
      await tester.runAsync(sync.push);
      expect(auth.statuses, [SyncStatus.syncing, SyncStatus.synced]);

      // From here on, pulls fail their token refresh and stay off the DB.
      auth
        ..tokenExpired = true
        ..refreshSucceeds = false
        ..signedIn = false;
      sync.startPeriodicPull(); // signed out → no immediate pull
      auth.signedIn = true;
      auth.statuses.clear();

      await tester.pump(const Duration(minutes: 5));
      expect(auth.statuses, isEmpty); // skipped

      await tester.pump(const Duration(minutes: 5));
      expect(auth.statuses, pushRun); // the following tick pulls
      sync.dispose();
    });

    testWidgets('a push requested during a pull is scheduled once the pull '
        'ends', (tester) async {
      final auth = offlineAuth()..gateFirstRefresh = Completer<void>();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      final pull = sync.pull(); // parks in refreshToken, holding the lock
      await tester.pump();
      final push = sync.push(); // deferred
      await tester.pump();
      expect(auth.statuses, [SyncStatus.syncing]);

      auth.gateFirstRefresh!.complete();
      await tester.pump();
      await pull;
      await push;
      expect(auth.statuses, pushRun); // the pull only, push not yet

      await tester.pump(const Duration(seconds: 5));
      expect(auth.statuses, [...pushRun, ...pushRun]);
    });

    testWidgets('a push requested during a push is re-scheduled, not dropped',
        (tester) async {
      final auth = offlineAuth()..gateFirstRefresh = Completer<void>();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      final first = sync.push();
      await tester.pump();
      final second = sync.push(); // deferred
      auth.gateFirstRefresh!.complete();
      await tester.pump();
      await first;
      await second;
      expect(auth.statuses, pushRun);

      await tester.pump(const Duration(seconds: 5));
      expect(auth.statuses, [...pushRun, ...pushRun]);
    });

    testWidgets('a pull requested during a push runs as soon as the push ends',
        (tester) async {
      final auth = offlineAuth()..gateFirstRefresh = Completer<void>();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      final push = sync.push();
      await tester.pump();
      final pull = sync.pull(); // deferred
      await tester.pump();

      auth.gateFirstRefresh!.complete();
      await tester.pump();
      await push;
      await pull;
      await tester.pump();

      expect(auth.statuses, [...pushRun, ...pushRun]);
    });

    testWidgets('a push requested during a bulk op is scheduled once the bulk '
        'op ends', (tester) async {
      final auth = offlineAuth()..gateFirstRefresh = Completer<void>();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      final bulk = sync.replaceLocalWithCloud(); // holds the lock
      await tester.pump();
      final push = sync.push(); // deferred
      await tester.pump();

      auth.gateFirstRefresh!.complete();
      await tester.pump();
      await bulk;
      await push;
      expect(auth.statuses, pushRun); // the bulk op only

      await tester.pump(const Duration(seconds: 5));
      expect(auth.statuses, [...pushRun, ...pushRun]);
    });

    // [Documents actual behaviour] _runExclusive polls for at most 5 s, then
    // runs the bulk op even though the push still holds the lock — the
    // accepted trade-off noted in sync_service.dart.
    testWidgets('a bulk op gives up waiting for the lock after 5 s and runs '
        'alongside the push', (tester) async {
      final auth = offlineAuth()..gateFirstRefresh = Completer<void>();
      final sync = SyncService(auth, firestore: _FakeFirestoreService());

      final push = sync.push(); // parks in refreshToken, holding the lock
      await tester.pump();
      var bulkDone = false;
      final bulk = sync.replaceLocalWithCloud().then((_) => bulkDone = true);

      await tester.pump(const Duration(seconds: 4));
      expect(bulkDone, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(bulkDone, isTrue); // ran while the push is still parked

      auth.gateFirstRefresh!.complete();
      await tester.pump();
      await push;
      await bulk;
      expect(auth.statuses, [
        SyncStatus.syncing, // push
        SyncStatus.syncing, // bulk op
        SyncStatus.idle, // bulk op
        SyncStatus.idle, // push
      ]);
    });
  });

  // The xp_events sync was written before the July sync fixes (delta pulls,
  // tombstones, pending-add guards). Each test below pins one bug it had.
  group('xp_events sync', () {
    Future<String> onlyXpSyncId() async =>
        (await db.getAllXpEventSyncIds()).single;

    test('revoking XP pushes a tombstone so other devices drop it', () async {
      // Bug: revoking deleted the row locally but queued nothing, so the cloud
      // copy lived on and the next pull brought the XP back.
      SharedPreferences.setMockInitialValues({});
      final taskId = await db.insertTask(Task(name: 'T', syncId: 't1'));
      await db.insertXpEvent(
          eventType: 'worked_on', xpAmount: 10, taskId: taskId, date: '2026-10-07');
      final syncId = await onlyXpSyncId();
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);
      await sync.push();

      await db.deleteXpEventsForTask(taskId, 'worked_on', '2026-10-07');
      await sync.push();

      expect(fakeFs.calls, contains('deleteXpEvent:$syncId'));
    });

    test('a push sends only XP events not yet pushed', () async {
      // Bug: every push re-sent the whole xp_events table, one Firestore
      // write per event per push.
      SharedPreferences.setMockInitialValues({});
      await db.insertXpEvent(
          eventType: 'streak_bonus', xpAmount: 5, date: '2026-10-06');
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.push();
      expect(fakeFs.pushedXpSyncIds, hasLength(1));

      await sync.push();
      expect(fakeFs.pushedXpSyncIds, hasLength(1));
    });

    test('a pull before the push keeps a freshly earned XP event', () async {
      // Bug: the pull deleted every local event missing from the cloud, and
      // nothing marked a new event as pending, so XP earned in the 5 s before
      // the debounced push was wiped.
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await db.insertXpEvent(
          eventType: 'streak_bonus', xpAmount: 5, date: '2026-10-06');
      final sync = SyncService(_FakeAuthProvider(),
          firestore: _FakeFirestoreService());

      await sync.pull();

      expect(await db.getTotalXp(), 5);
    });

    test('a delta pull removes a local XP event tombstoned in the cloud',
        () async {
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      await db.upsertXpEventFromRemote(
        syncId: 'gone',
        eventType: 'streak_bonus',
        xpAmount: 5,
        date: '2026-10-06',
        createdAt: 1,
      );
      final fakeFs = _FakeFirestoreService()
        ..xpSince = [
          {'sync_id': 'gone', 'deleted': true},
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(await db.getTotalXp(), 0);
    });

    test('undo then redo before a push leaves the event live in the cloud',
        () async {
      // Undo and redo reuse one sync id. The queue must end with the add, or
      // the push would tombstone XP the user still has.
      SharedPreferences.setMockInitialValues({});
      final taskId = await db.insertTask(Task(name: 'T', syncId: 't1'));
      await db.insertXpEvent(
          eventType: 'worked_on', xpAmount: 10, taskId: taskId, date: '2026-10-07');
      await db.deleteXpEventsForTask(taskId, 'worked_on', '2026-10-07');
      await db.insertXpEvent(
          eventType: 'worked_on', xpAmount: 10, taskId: taskId, date: '2026-10-07');
      final syncId = await onlyXpSyncId();
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.push();

      expect(fakeFs.calls.where((c) => c.contains('XpEvent')),
          ['pushXpEvents:1']);
      expect(fakeFs.pushedXpSyncIds, [syncId]);
    });

    test('a delta pull does not download the whole xp_events collection',
        () async {
      // Bug: every 5-minute pull read every XP event, which eats the
      // Firestore free-tier read quota that delta pulls exist to protect.
      SharedPreferences.setMockInitialValues({'sync_last_sync_at': 1000});
      final fakeFs = _FakeFirestoreService();
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(fakeFs.xpFullPulls, 0);
    });

    test('a full pull removes a local XP event tombstoned in the cloud',
        () async {
      SharedPreferences.setMockInitialValues({});
      await db.upsertXpEventFromRemote(
        syncId: 'gone',
        eventType: 'streak_bonus',
        xpAmount: 5,
        date: '2026-10-06',
        createdAt: 1,
      );
      final fakeFs = _FakeFirestoreService()
        ..allXpEvents = [
          {
            'sync_id': 'gone',
            'event_type': 'streak_bonus',
            'xp_amount': 5,
            'task_sync_id': null,
            'date': '2026-10-06',
            'created_at': 1,
            'deleted': true,
          },
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(await db.getTotalXp(), 0);
    });

    test('replaceLocalWithCloud drops local XP events that are not in the cloud',
        () async {
      // Bug: deleteAllLocalData skipped xp_events, so "replace local with
      // cloud" kept local XP and the next push merged it into the cloud.
      SharedPreferences.setMockInitialValues({});
      await db.insertXpEvent(
          eventType: 'streak_bonus', xpAmount: 5, date: '2026-10-06');
      final sync = SyncService(_FakeAuthProvider(),
          firestore: _FakeFirestoreService());

      await sync.replaceLocalWithCloud();

      expect(await db.getTotalXp(), 0);
    });

    test('an XP event pulled from the cloud links to the local task', () async {
      // Bug: pulled events always stored task_id = null, so undoing on this
      // device could not find XP that another device had awarded.
      SharedPreferences.setMockInitialValues({});
      final taskId = await _syncedTask(db, 't1');
      final fakeFs = _FakeFirestoreService()
        ..remoteTasks = [Task(name: 'T-t1', syncId: 't1')]
        ..allXpEvents = [
          {
            'sync_id': 'remote-xp',
            'event_type': 'worked_on',
            'xp_amount': 10,
            'task_sync_id': 't1',
            'date': '2026-10-07',
            'created_at': 1,
          },
        ];
      final sync = SyncService(_FakeAuthProvider(), firestore: fakeFs);

      await sync.pull();

      expect(await db.deleteXpEventsForTask(taskId, 'worked_on', '2026-10-07'), 1);
    });
  });
}
