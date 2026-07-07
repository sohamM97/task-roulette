import 'dart:async';

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

/// Always-signed-in auth so [SyncService] proceeds past its `_canSync` gate.
class _FakeAuthProvider extends AuthProvider {
  @override
  bool get isSignedIn => true;
  @override
  String? get uid => 'test-uid';
  @override
  String? get firebaseIdToken => 'test-token';
  @override
  bool get isTokenExpired => false;
  @override
  Future<bool> refreshToken() async => true;
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

  @override
  Future<void> pushTodaysFive(
    String uid,
    String idToken,
    String date,
    List<Map<String, dynamic>> entries,
    List<String> suppressedSyncIds,
    int updatedAt,
  ) async {
    capturedTodaysFiveUpdatedAt = updatedAt;
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
    return const [];
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
      pullAllRelationships(String uid, String idToken) async => const [];

  @override
  Future<List<({String parentSyncId, String childSyncId, bool deleted})>>
      pullRelationshipsSince(String uid, String idToken, int lastSyncAt) async =>
          relsSince;

  @override
  Future<List<({String taskSyncId, String dependsOnSyncId})>>
      pullAllDependencies(String uid, String idToken) async => const [];

  @override
  Future<List<({String taskSyncId, String dependsOnSyncId, bool deleted})>>
      pullDependenciesSince(String uid, String idToken, int lastSyncAt) async =>
          depsSince;

  @override
  Future<List<Map<String, dynamic>>> pullAllSchedules(
      String uid, String idToken) async => const [];

  @override
  Future<List<Map<String, dynamic>>> pullSchedulesSince(
      String uid, String idToken, int lastSyncAt) async => schedulesSince;

  @override
  Future<({List<Map<String, dynamic>> entries, List<String> suppressedSyncIds, int updatedAt})?>
      pullTodaysFive(String uid, String idToken, String date) async => null;

  @override
  Future<void> cleanupTombstones(
      String uid, String idToken, String collectionId, Duration maxAge) async {}
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
}
