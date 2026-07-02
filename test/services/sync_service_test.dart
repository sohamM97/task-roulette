import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/services/firestore_service.dart';
import 'package:task_roulette/services/sync_service.dart';

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

  /// If set, the FIRST task pull awaits this before returning — lets a test
  /// hold `_syncing` true and issue a second pull that gets queued.
  Completer<void>? gateFirstTaskPull;
  bool _firstTaskPullGated = false;

  @override
  bool get isConfigured => true;

  @override
  Future<List<Task>> pullTasksSince(String uid, String idToken,
      {int? lastSyncAt}) async {
    capturedTaskCursors.add(lastSyncAt);
    if (gateFirstTaskPull != null && !_firstTaskPullGated) {
      _firstTaskPullGated = true;
      await gateFirstTaskPull!.future;
    }
    return const [];
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
      String uid, String idToken, int lastSyncAt) async => const [];

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
  });
}
