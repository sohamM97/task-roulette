import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:ui' show VoidCallback;
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_helper.dart';
import '../providers/auth_provider.dart';
import '../utils/display_utils.dart';
import 'firestore_service.dart';

/// Orchestrates sync between local SQLite and Firestore.
/// - Debounced push: 5 seconds after local mutation
/// - Periodic pull: every 5 minutes while signed in
/// - Initial migration: push all local data on first sign-in
class SyncService {
  final DatabaseHelper _db = DatabaseHelper();
  final FirestoreService _firestore;
  final AuthProvider _authProvider;

  Timer? _pushDebounceTimer;
  Timer? _periodicPullTimer;
  bool _syncing = false;
  bool _pushPending = false;
  bool _pullPending = false;
  // Whether the deferred (queued-because-syncing) pull should be a full pull.
  // Bug fix: without carrying this, a pull(fullPullOnOpen: true) that lands
  // while a sync is in flight was re-dispatched as a plain delta pull, so the
  // on-open/on-resume full reconciliation silently didn't happen.
  bool _pendingPullFull = false;
  bool _skipNextPeriodicPull = false;

  /// Every Nth pull does a full reconciliation instead of delta, catching any
  /// updates that were missed due to lastSyncAt advancing past their updated_at.
  /// Bug fix: without this, a task updated on device A could be permanently
  /// invisible to device B's delta pulls if B's lastSyncAt advanced past the
  /// task's updated_at (e.g. due to quota errors or timing).
  /// Counter is persisted so it survives app restarts (especially important
  /// for web where users frequently close/reopen the tab).
  static const _fullPullInterval = 10;
  static const _prefsKeyPullCycleCount = 'sync_pull_cycle_count';

  /// On app/tab open, do a full reconciliation pull (not just delta) if it's
  /// been at least this long since the last successful full pull.
  ///
  /// Bug fix: web sessions are often shorter than the ~50-min periodic
  /// full-pull interval (users open a tab briefly and close it), and the pull
  /// cycle counter is persisted — so a bursty user could go days on delta-only
  /// pulls and never reconcile stranded/stale data. A full pull on open closes
  /// that gap. Throttling by wall-clock (rather than firing on every open)
  /// bounds the extra Firestore reads so frequent tab reopens don't blow the
  /// read quota.
  static const _fullPullOnOpenThrottle = Duration(hours: 2);
  static const _prefsKeyLastFullPullAt = 'sync_last_full_pull_at';

  /// Lookback margin subtracted from the delta-pull cursor when it's persisted.
  ///
  /// Root-cause fix for the "edit made on one device never reaches another"
  /// bug: the cursor (`_prefsKeyLastSyncAt`) is stamped with THIS device's
  /// wall clock, but remote `updated_at` values are stamped by the *writing*
  /// device's clock. When this reader's clock runs ahead of a writer's, that
  /// writer's edits (a rename, a completion) get an `updated_at` below the
  /// cursor and are skipped by every future delta pull — a permanent miss,
  /// previously only healed by the every-10th-cycle full pull (~50 min).
  /// Rewinding the stored cursor by this margin means each delta pull re-scans
  /// a short overlap window, so skew up to [_deltaCursorLookback] is tolerated
  /// immediately. Re-scanning is cheap (only docs mutated inside the window
  /// match the `updated_at` filter) and idempotent (upserts are last-writer-
  /// wins). The periodic full pull remains the backstop for larger skew.
  static const _deltaCursorLookback = Duration(minutes: 10);

  static const _prefsKeyLastSyncAt = 'sync_last_sync_at';
  static const _prefsKeyInitialMigrationDone = 'sync_initial_migration_done';
  // The Today's 5 LWW timestamp is owned + stamped by DatabaseHelper (every
  // local save stamps it); we only read it here — see
  // [DatabaseHelper.prefsKeyTodaysFivePersistedAt].

  static const _pushDebounceDelay = Duration(seconds: 5);
  static const _pullInterval = Duration(minutes: 5);

  /// [firestore] is injectable so tests can drive `pull`/`push` against a fake
  /// Firestore without real network/env config; production passes nothing.
  SyncService(this._authProvider, {FirestoreService? firestore})
      : _firestore = firestore ?? FirestoreService();

  /// Returns today's date as YYYY-MM-DD string for Firestore document key.
  String _todayDateKey() => todayDateKey();

  /// Pushes the current Today's-5 state (+ deadline suppressions) to Firestore.
  //
  // CR-fix I-48: the remote `updated_at` was stamped with DateTime.now() at
  // PUSH time (after the 5s debounce). The pull side gates LWW on
  // `remoteUpdatedAt >= localPersistedAt`, where localPersistedAt is the
  // EDIT-time stamp written by DatabaseHelper.saveTodaysFiveState. Comparing a
  // push-time stamp against an edit-time stamp inverts LWW whenever push order
  // != edit order (variable latency, debounce coalescing) — an older edit could
  // overwrite a newer one. Push the same edit-time stamp so both sides share a
  // clock basis.
  Future<void> _pushTodaysFiveState(String uid, String idToken) async {
    final dateKey = _todayDateKey();
    final todaysFiveEntries = await _db.getTodaysFiveStateWithSyncIds(dateKey);
    final suppressedSyncIds = await _db.getDeadlineSuppressedSyncIds(dateKey);
    if (todaysFiveEntries.isEmpty && suppressedSyncIds.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final updatedAt =
        prefs.getInt(DatabaseHelper.prefsKeyTodaysFivePersistedAt) ??
            DateTime.now().millisecondsSinceEpoch;
    await _firestore.pushTodaysFive(
        uid, idToken, dateKey, todaysFiveEntries, suppressedSyncIds, updatedAt);
  }

  /// Runs [body] under the same `_syncing` guard that push()/pull() honour, so
  /// they defer (and drain afterward) instead of interleaving with a bulk op.
  //
  // CR-fix I-50: initialMigration / replaceLocalWithCloud / replaceCloudWithLocal
  // previously ran with NO mutex. A debounced push() or the 5-min periodic
  // pull() could fire mid-way (e.g. while replaceLocalWithCloud sits between
  // deleteAllLocalData() and its re-insert), running against a half-wiped DB and
  // advancing the delta cursor — leaving interleaved, inconsistent state. Now
  // these acquire `_syncing`; concurrent push/pull see it set and defer.
  Future<void> _runExclusive(Future<void> Function() body) async {
    // Wait (bounded) for any in-flight push/pull to release the guard before we
    // take it. push()/pull() are short; bulk ops are rare and user-initiated.
    for (var i = 0; _syncing && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _syncing = true;
    try {
      await body();
    } finally {
      _syncing = false;
      if (_pushPending) {
        _pushPending = false;
        schedulePush();
      } else if (_pullPending) {
        _pullPending = false;
        final full = _pendingPullFull;
        _pendingPullFull = false;
        pull(fullPullOnOpen: full);
      }
    }
  }

  bool get _canSync =>
      _authProvider.isSignedIn &&
      _authProvider.uid != null &&
      _authProvider.firebaseIdToken != null &&
      _firestore.isConfigured;

  /// Start periodic pull timer, with an immediate pull to catch up.
  void startPeriodicPull() {
    _periodicPullTimer?.cancel();
    _periodicPullTimer = Timer.periodic(_pullInterval, (_) {
      if (!_canSync) return;
      if (_skipNextPeriodicPull) {
        _skipNextPeriodicPull = false;
        return;
      }
      pull();
    });
    // Immediate pull so we don't wait 5 minutes for the first sync. Request a
    // (throttled) full reconciliation since this is an app/tab open.
    if (_canSync) pull(fullPullOnOpen: true);
  }

  /// Stop all timers.
  void dispose() {
    _pushDebounceTimer?.cancel();
    _periodicPullTimer?.cancel();
  }

  /// Stops sync timers and signs out. Local data is kept as-is.
  Future<void> handleSignOut() async {
    _pushDebounceTimer?.cancel();
    _periodicPullTimer?.cancel();
    await _authProvider.signOut();
  }

  /// Schedule a debounced push (called after every local mutation).
  void schedulePush() {
    _pushDebounceTimer?.cancel();
    _pushDebounceTimer = Timer(_pushDebounceDelay, () {
      if (_canSync) push();
    });
  }

  /// Signals that Today's 5 was persisted locally → schedule a push.
  /// The LWW timestamp is stamped by [DatabaseHelper.saveTodaysFiveState]
  /// itself (on every local save), so this only needs to trigger the push.
  void onTodaysFivePersisted() {
    schedulePush();
  }

  /// Cancel any pending debounce timer and push immediately.
  /// Called when the app goes to the background so unsaved changes
  /// aren't lost if the OS kills the process.
  void flushPush() {
    if (_pushDebounceTimer?.isActive ?? false) {
      _pushDebounceTimer!.cancel();
      _pushDebounceTimer = null;
      if (_canSync) push();
    }
  }

  /// Returns true if this is the first sign-in (migration not yet done).
  Future<bool> needsInitialMigration() async {
    if (!_canSync) return false;
    final prefs = await SharedPreferences.getInstance();
    final uid = _authProvider.uid!;
    final key = '${_prefsKeyInitialMigrationDone}_$uid';
    return prefs.getBool(key) != true;
  }

  /// Returns true if the user already has data in Firestore.
  Future<bool> hasCloudData() async {
    if (!_canSync) return false;
    final idToken = await _getValidToken();
    if (idToken == null) return false;
    return _firestore.hasRemoteData(_authProvider.uid!, idToken);
  }

  /// Perform initial migration: push all local data to Firestore.
  /// Called on first sign-in when cloud is empty (or user chose "Merge both").
  Future<void> initialMigration() async {
    if (!_canSync) return;

    final prefs = await SharedPreferences.getInstance();
    final uid = _authProvider.uid!;
    final key = '${_prefsKeyInitialMigrationDone}_$uid';
    if (prefs.getBool(key) == true) return;

    await _runExclusive(() async {
    _authProvider.setSyncStatus(SyncStatus.syncing);

    try {
      final idToken = await _getValidToken();
      if (idToken == null) {
        _authProvider.setSyncStatus(SyncStatus.idle);
        return;
      }

      // Push all tasks
      final allTasks = await _db.getAllTasksWithSyncId();
      await _firestore.pushTasks(uid, idToken, allTasks);

      // Push all relationships
      final rels = await _db.getAllRelationshipsWithSyncIds();
      await _firestore.pushRelationships(uid, idToken, rels);

      // Push all dependencies
      final deps = await _db.getAllDependenciesWithSyncIds();
      await _firestore.pushDependencies(uid, idToken, deps);

      // Push all schedules
      final schedules = await _db.getAllSchedulesWithTaskSyncIds();
      if (schedules.isNotEmpty) {
        await _firestore.pushSchedules(uid, idToken, schedules);
      }

      // Mark all tasks as synced
      final taskIds = allTasks.where((t) => t.id != null).map((t) => t.id!).toList();
      await _db.markTasksSynced(taskIds);

      // Drain sync queue (anything enqueued during migration)
      await _db.drainSyncQueue();

      // Push Today's 5 state (+ deadline suppressions so cross-device removals stick)
      await _pushTodaysFiveState(uid, idToken);

      // Mark migration done
      await prefs.setBool(key, true);
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

      _authProvider.setSyncStatus(SyncStatus.synced);
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    }
    });
  }

  /// Replace local data with cloud data: wipe local, pull everything from cloud.
  Future<void> replaceLocalWithCloud() async {
    if (!_canSync) return;

    await _runExclusive(() async {
    _authProvider.setSyncStatus(SyncStatus.syncing);

    try {
      final idToken = await _getValidToken();
      if (idToken == null) {
        _authProvider.setSyncStatus(SyncStatus.idle);
        return;
      }
      final uid = _authProvider.uid!;

      // Wipe all local data
      await _db.deleteAllLocalData();

      // Pull all tasks from cloud
      final remoteTasks = await _firestore.pullTasksSince(uid, idToken);
      for (final task in remoteTasks) {
        await _db.upsertFromRemote(task);
      }

      // Pull all relationships
      final rels = await _firestore.pullAllRelationships(uid, idToken);
      for (final rel in rels) {
        await _db.upsertRelationshipFromRemote(rel.parentSyncId, rel.childSyncId);
      }

      // Pull all dependencies
      final deps = await _firestore.pullAllDependencies(uid, idToken);
      for (final dep in deps) {
        await _db.upsertDependencyFromRemote(dep.taskSyncId, dep.dependsOnSyncId);
      }

      // Pull all schedules
      final remoteSchedules = await _firestore.pullAllSchedules(uid, idToken);
      for (final schedule in remoteSchedules) {
        await _db.upsertScheduleFromRemote(schedule);
      }

      // Pull Today's 5 state (+ deadline suppressions). Bug fix: this restore
      // path used to drop suppressions, so a cross-device removal of a due-today
      // task was resurrected after "Replace local with cloud" — deleteAllLocalData
      // wiped the local suppression, the restore brought back members without it,
      // and the next reconcile re-auto-pinned the removed task.
      final dateKey = _todayDateKey();
      final remote5 = await _firestore.pullTodaysFive(uid, idToken, dateKey);
      if (remote5 != null &&
          (remote5.entries.isNotEmpty || remote5.suppressedSyncIds.isNotEmpty)) {
        await _db.upsertTodaysFiveFromRemote(dateKey, remote5.entries,
            remoteSuppressedSyncIds: remote5.suppressedSyncIds);
      }

      // Mark migration done
      final prefs = await SharedPreferences.getInstance();
      final key = '${_prefsKeyInitialMigrationDone}_$uid';
      await prefs.setBool(key, true);
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

      _authProvider.setSyncStatus(SyncStatus.synced);
      _onDataChanged?.call();
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    }
    });
  }

  /// Replace cloud data with local: wipe all cloud data, push local up.
  Future<void> replaceCloudWithLocal() async {
    if (!_canSync) return;

    await _runExclusive(() async {
    _authProvider.setSyncStatus(SyncStatus.syncing);

    try {
      final idToken = await _getValidToken();
      if (idToken == null) {
        _authProvider.setSyncStatus(SyncStatus.idle);
        return;
      }
      final uid = _authProvider.uid!;

      // Delete all existing cloud data first
      final remoteTasks = await _firestore.pullTasksSince(uid, idToken);
      for (final task in remoteTasks) {
        if (task.syncId != null) {
          await _firestore.deleteTask(uid, idToken, task.syncId!);
        }
      }
      final remoteRels = await _firestore.pullAllRelationships(uid, idToken);
      for (final rel in remoteRels) {
        await _firestore.deleteRelationship(uid, idToken, rel.parentSyncId, rel.childSyncId);
      }
      final remoteDeps = await _firestore.pullAllDependencies(uid, idToken);
      for (final dep in remoteDeps) {
        await _firestore.deleteDependency(uid, idToken, dep.taskSyncId, dep.dependsOnSyncId);
      }
      final remoteScheds = await _firestore.pullAllSchedules(uid, idToken);
      for (final sched in remoteScheds) {
        final syncId = sched['sync_id'] as String;
        await _firestore.deleteSchedule(uid, idToken, syncId);
      }

      // Now push all local data to cloud
      final allTasks = await _db.getAllTasksWithSyncId();
      await _firestore.pushTasks(uid, idToken, allTasks);

      final rels = await _db.getAllRelationshipsWithSyncIds();
      await _firestore.pushRelationships(uid, idToken, rels);

      final deps = await _db.getAllDependenciesWithSyncIds();
      await _firestore.pushDependencies(uid, idToken, deps);

      // Push all schedules
      final schedules = await _db.getAllSchedulesWithTaskSyncIds();
      if (schedules.isNotEmpty) {
        await _firestore.pushSchedules(uid, idToken, schedules);
      }

      // Mark all tasks as synced
      final taskIds = allTasks.where((t) => t.id != null).map((t) => t.id!).toList();
      await _db.markTasksSynced(taskIds);
      await _db.drainSyncQueue();

      // Push Today's 5 state (+ deadline suppressions so cross-device removals stick)
      await _pushTodaysFiveState(uid, idToken);

      // Mark migration done
      final prefs = await SharedPreferences.getInstance();
      final key = '${_prefsKeyInitialMigrationDone}_$uid';
      await prefs.setBool(key, true);
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

      _authProvider.setSyncStatus(SyncStatus.synced);
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    }
    });
  }

  /// Merge both: push local to cloud first, then pull cloud data.
  /// Both datasets end up combined.
  Future<void> mergeBoth() async {
    await initialMigration();
    await pull();
  }

  /// Push pending local changes to Firestore.
  Future<void> push() async {
    if (!_canSync) return;
    if (_syncing) {
      _pushPending = true;
      return;
    }
    _syncing = true;

    _authProvider.setSyncStatus(SyncStatus.syncing);

    try {
      final idToken = await _getValidToken();
      if (idToken == null) {
        _authProvider.setSyncStatus(SyncStatus.idle);
        return;
      }
      final uid = _authProvider.uid!;

      // Push pending tasks
      final pendingTasks = await _db.getPendingTasks();
      if (pendingTasks.isNotEmpty) {
        await _firestore.pushTasks(uid, idToken, pendingTasks);
        final taskIds = pendingTasks.where((t) => t.id != null).map((t) => t.id!).toList();
        await _db.markTasksSynced(taskIds);
      }

      // Process sync queue entries one at a time — only delete after success
      // so entries survive partial push failures.
      final queue = await _db.peekSyncQueue();
      for (final entry in queue) {
        final entryId = entry['id'] as int;
        final entityType = entry['entity_type'] as String;
        final action = entry['action'] as String;
        final key1 = entry['key1'] as String;
        final key2 = entry['key2'] as String;

        switch (entityType) {
          case 'task':
            if (action == 'remove') {
              await _firestore.deleteTask(uid, idToken, key1);
            }
          case 'relationship':
            if (action == 'add') {
              await _firestore.pushRelationships(
                uid,
                idToken,
                [(parentSyncId: key1, childSyncId: key2)],
              );
            } else if (action == 'remove') {
              await _firestore.deleteRelationship(uid, idToken, key1, key2);
            }
          case 'dependency':
            if (action == 'add') {
              await _firestore.pushDependencies(
                uid,
                idToken,
                [(taskSyncId: key1, dependsOnSyncId: key2)],
              );
            } else if (action == 'remove') {
              await _firestore.deleteDependency(uid, idToken, key1, key2);
            }
          case 'schedule':
            if (action == 'add') {
              final data = await _db.getScheduleBySyncId(key1);
              if (data != null) {
                await _firestore.pushSchedules(uid, idToken, [data]);
              }
            } else if (action == 'remove') {
              await _firestore.deleteSchedule(uid, idToken, key1);
            }
        }
        await _db.deleteSyncQueueEntry(entryId);
      }

      // Push Today's 5 state (+ deadline suppressions so cross-device removals stick)
      await _pushTodaysFiveState(uid, idToken);

      _authProvider.setSyncStatus(SyncStatus.synced);
      // CR-fix M-41: skip the next periodic pull because remote now matches what
      // THIS device pushed. Note this does NOT mean remote == local overall —
      // changes another device made between our last pull and this push aren't
      // fetched until the following periodic cycle (bounded by the 5-min
      // interval). Explicit pull() calls (startup, manual sync) are unaffected.
      _skipNextPeriodicPull = true;
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    } finally {
      _syncing = false;
      if (_pushPending) {
        _pushPending = false;
        schedulePush();
      } else if (_pullPending) {
        _pullPending = false;
        final full = _pendingPullFull;
        _pendingPullFull = false;
        pull(fullPullOnOpen: full);
      }
    }
  }

  /// Pull remote changes and merge into local DB.
  ///
  /// [fullPullOnOpen] requests a full reconciliation (not just a delta) when
  /// this is an app/tab open, throttled by [_fullPullOnOpenThrottle] so rapid
  /// reopens don't blow the Firestore read quota.
  Future<void> pull({bool fullPullOnOpen = false}) async {
    if (!_canSync) return;
    if (_syncing) {
      _pullPending = true;
      _pendingPullFull = _pendingPullFull || fullPullOnOpen;
      return;
    }
    _syncing = true;

    _authProvider.setSyncStatus(SyncStatus.syncing);

    try {
      final idToken = await _getValidToken();
      if (idToken == null) {
        _authProvider.setSyncStatus(SyncStatus.idle);
        return;
      }
      final uid = _authProvider.uid!;

      final prefs = await SharedPreferences.getInstance();
      var lastSyncAt = prefs.getInt(_prefsKeyLastSyncAt);

      // Full reconciliation (clear lastSyncAt) is forced in two cases, both of
      // which catch updates missed by delta pulls (e.g. when lastSyncAt advanced
      // past a task's updated_at):
      //   1. Every _fullPullInterval cycles (counter persisted across restarts).
      //   2. On app/tab open, if it's been >= _fullPullOnOpenThrottle since the
      //      last full pull — closes the "short web session never full-pulls"
      //      gap without a full pull on every reopen.
      // CR-fix M-40: compute the next cycle count but persist it only after the
      // pull succeeds (see below). Previously it was incremented+persisted here,
      // so a throwing pull still advanced it — repeated failures "used up" the
      // every-Nth full-reconciliation backstop and delayed it.
      final pullCycleCount = (prefs.getInt(_prefsKeyPullCycleCount) ?? 0) + 1;
      final periodicFull =
          lastSyncAt != null && pullCycleCount % _fullPullInterval == 0;
      final lastFullPullAt = prefs.getInt(_prefsKeyLastFullPullAt) ?? 0;
      final openFull = fullPullOnOpen &&
          lastSyncAt != null &&
          DateTime.now().millisecondsSinceEpoch - lastFullPullAt >=
              _fullPullOnOpenThrottle.inMilliseconds;
      if (periodicFull || openFull) {
        debugLog('SyncService: full pull (cycle $pullCycleCount, '
            'onOpen=$openFull)');
        lastSyncAt = null;
      }
      // A null cursor here (forced above, or first-ever sync) means this is a
      // full pull — record it so the on-open throttle can measure from it.
      final isFullPull = lastSyncAt == null;

      // Pull tasks: delta (with tombstones) when possible, full on first sync.
      bool anyChange = false;
      if (lastSyncAt != null) {
        // CR-fix I-49: delta pull now includes task tombstones so remote
        // deletions propagate (previously tasks were insert/update only and a
        // deleted task lived on forever, resurrecting on re-edit).
        final taskDeltas =
            await _firestore.pullTaskDeltasSince(uid, idToken, lastSyncAt);
        // Don't drop a task with a pending local add/edit just because a stale
        // tombstone is still in the delta window — same guard as relationships.
        final pendingTaskSyncIds = await _db.getPendingTaskSyncIds();
        for (final delta in taskDeltas) {
          if (delta.deleted) {
            if (!pendingTaskSyncIds.contains(delta.syncId)) {
              final removed = await _db.deleteTaskBySyncId(delta.syncId);
              if (removed) anyChange = true;
            }
          } else if (delta.task != null) {
            final changed = await _db.upsertFromRemote(delta.task!);
            if (changed) anyChange = true;
          }
        }
      } else {
        // Full pull — upsert live remote tasks, then reconcile deletions by
        // removing local tasks absent from the remote set (guarding pending
        // local adds), exactly like the relationship/dependency/schedule
        // full-pull branches below.
        final remoteTasks = await _firestore.pullTasksSince(uid, idToken);
        final remoteTaskSyncIds = <String>{};
        for (final remoteTask in remoteTasks) {
          if (remoteTask.syncId != null) {
            remoteTaskSyncIds.add(remoteTask.syncId!);
          }
          final changed = await _db.upsertFromRemote(remoteTask);
          if (changed) anyChange = true;
        }
        final pendingTaskSyncIds = await _db.getPendingTaskSyncIds();
        final localTaskSyncIds = await _db.getAllTaskSyncIds();
        for (final localSyncId in localTaskSyncIds) {
          if (!remoteTaskSyncIds.contains(localSyncId) &&
              !pendingTaskSyncIds.contains(localSyncId)) {
            final removed = await _db.deleteTaskBySyncId(localSyncId);
            if (removed) anyChange = true;
          }
        }
      }

      // Pull relationships: delta when possible, full on first sync
      if (lastSyncAt != null) {
        // Delta pull — includes tombstoned docs (deleted_at set) so we
        // can apply remote deletions without a full reconciliation.
        final recentRels = await _firestore.pullRelationshipsSince(
            uid, idToken, lastSyncAt);
        // Don't drop an edge that has a pending local add (re-created but not
        // yet pushed) just because a stale tombstone is still in the delta
        // window — it would flicker out of the UI until the push re-asserts it.
        // Same guard the full-pull path uses.
        final pendingRelKeys = await _db.getPendingSyncAddKeys('relationship');
        for (final rel in recentRels) {
          if (rel.deleted) {
            if (!pendingRelKeys.contains(
                '${rel.parentSyncId}:${rel.childSyncId}')) {
              await _db.removeRelationshipFromRemote(
                  rel.parentSyncId, rel.childSyncId);
              anyChange = true;
            }
          } else {
            final wouldCycle = await _db.wouldRelationshipCreateCycle(
                rel.parentSyncId, rel.childSyncId);
            if (!wouldCycle) {
              await _db.upsertRelationshipFromRemote(
                  rel.parentSyncId, rel.childSyncId);
              anyChange = true;
            }
          }
        }
      } else {
        // Full pull — first sync after sign-in, reconcile deletions
        final remoteRels = await _firestore.pullAllRelationships(uid, idToken);
        for (final rel in remoteRels) {
          final wouldCycle = await _db.wouldRelationshipCreateCycle(
              rel.parentSyncId, rel.childSyncId);
          if (!wouldCycle) {
            await _db.upsertRelationshipFromRemote(
                rel.parentSyncId, rel.childSyncId);
          }
        }
        final remoteRelSet = remoteRels
            .map((r) => '${r.parentSyncId}:${r.childSyncId}')
            .toSet();
        final pendingRelKeys = await _db.getPendingSyncAddKeys('relationship');
        final localRels = await _db.getAllRelationshipsWithSyncIds();
        for (final local in localRels) {
          final key = '${local.parentSyncId}:${local.childSyncId}';
          if (!remoteRelSet.contains(key) && !pendingRelKeys.contains(key)) {
            await _db.removeRelationshipFromRemote(
                local.parentSyncId, local.childSyncId);
            anyChange = true;
          }
        }
      }

      // Pull dependencies: delta when possible, full on first sync
      if (lastSyncAt != null) {
        final recentDeps = await _firestore.pullDependenciesSince(
            uid, idToken, lastSyncAt);
        // See relationship branch: skip removal when a pending local add exists.
        final pendingDepKeys = await _db.getPendingSyncAddKeys('dependency');
        for (final dep in recentDeps) {
          if (dep.deleted) {
            if (!pendingDepKeys.contains(
                '${dep.taskSyncId}:${dep.dependsOnSyncId}')) {
              await _db.removeDependencyFromRemote(
                  dep.taskSyncId, dep.dependsOnSyncId);
              anyChange = true;
            }
          } else {
            final wouldCycle = await _db.wouldDependencyCreateCycle(
                dep.taskSyncId, dep.dependsOnSyncId);
            if (!wouldCycle) {
              await _db.upsertDependencyFromRemote(
                  dep.taskSyncId, dep.dependsOnSyncId);
              anyChange = true;
            }
          }
        }
      } else {
        final remoteDeps = await _firestore.pullAllDependencies(uid, idToken);
        for (final dep in remoteDeps) {
          final wouldCycle = await _db.wouldDependencyCreateCycle(
              dep.taskSyncId, dep.dependsOnSyncId);
          if (!wouldCycle) {
            await _db.upsertDependencyFromRemote(
                dep.taskSyncId, dep.dependsOnSyncId);
          }
        }
        final remoteDepSet = remoteDeps
            .map((d) => '${d.taskSyncId}:${d.dependsOnSyncId}')
            .toSet();
        final pendingDepKeys = await _db.getPendingSyncAddKeys('dependency');
        final localDeps = await _db.getAllDependenciesWithSyncIds();
        for (final local in localDeps) {
          final key = '${local.taskSyncId}:${local.dependsOnSyncId}';
          if (!remoteDepSet.contains(key) && !pendingDepKeys.contains(key)) {
            await _db.removeDependencyFromRemote(
                local.taskSyncId, local.dependsOnSyncId);
            anyChange = true;
          }
        }
      }

      // Pull schedules: delta when possible, full on first sync
      if (lastSyncAt != null) {
        final recentSchedules = await _firestore.pullSchedulesSince(
            uid, idToken, lastSyncAt);
        // See relationship branch: skip removal when a pending local add exists.
        final pendingScheduleKeys = await _db.getPendingSyncAddKeys('schedule');
        for (final schedule in recentSchedules) {
          if (schedule['deleted'] == true) {
            final syncId = schedule['sync_id'] as String?;
            if (syncId != null && !pendingScheduleKeys.contains(syncId)) {
              await _db.deleteScheduleBySyncId(syncId);
              anyChange = true;
            }
          } else {
            await _db.upsertScheduleFromRemote(schedule);
            anyChange = true;
          }
        }
      } else {
        final remoteSchedules = await _firestore.pullAllSchedules(uid, idToken);
        for (final schedule in remoteSchedules) {
          await _db.upsertScheduleFromRemote(schedule);
        }
        final remoteScheduleIds = remoteSchedules
            .map((s) => s['sync_id'] as String)
            .toSet();
        final pendingScheduleKeys = await _db.getPendingSyncAddKeys('schedule');
        final localScheduleIds = await _db.getAllScheduleSyncIds();
        for (final localSyncId in localScheduleIds) {
          if (!remoteScheduleIds.contains(localSyncId) &&
              !pendingScheduleKeys.contains(localSyncId)) {
            await _db.deleteScheduleBySyncId(localSyncId);
            anyChange = true;
          }
        }

        // Clean up old tombstones (fire-and-forget, best-effort).
        // Only on full pull (app startup) — when all devices have had
        // a chance to see the tombstones.
        const tombstoneMaxAge = Duration(days: 7);
        // CR-fix I-49: purge old task tombstones too (added with task soft-delete).
        _firestore.cleanupTombstones(uid, idToken, 'tasks', tombstoneMaxAge).catchError(
            (e) => debugLog('Tombstone cleanup (tasks) failed: $e'));
        _firestore.cleanupTombstones(uid, idToken, 'relationships', tombstoneMaxAge).catchError(
            (e) => debugLog('Tombstone cleanup (relationships) failed: $e'));
        _firestore.cleanupTombstones(uid, idToken, 'dependencies', tombstoneMaxAge).catchError(
            (e) => debugLog('Tombstone cleanup (dependencies) failed: $e'));
        _firestore.cleanupTombstones(uid, idToken, 'schedules', tombstoneMaxAge).catchError(
            (e) => debugLog('Tombstone cleanup (schedules) failed: $e'));
      }

      // Pull Today's 5 state (+ deadline suppressions)
      final dateKey = _todayDateKey();
      final remote5 = await _firestore.pullTodaysFive(uid, idToken, dateKey);
      if (remote5 != null &&
          (remote5.entries.isNotEmpty || remote5.suppressedSyncIds.isNotEmpty)) {
        final localPersistedAt =
            prefs.getInt(DatabaseHelper.prefsKeyTodaysFivePersistedAt) ?? 0;
        final todaysFiveChanged = await _db.upsertTodaysFiveFromRemote(
          dateKey,
          remote5.entries,
          remoteSuppressedSyncIds: remote5.suppressedSyncIds,
          remoteUpdatedAt: remote5.updatedAt,
          localPersistedAt: localPersistedAt,
        );
        if (todaysFiveChanged) anyChange = true;
      }

      // Update last sync timestamp. Rewind by the skew lookback so a lagging
      // writer's edits (updated_at stamped by a clock behind ours) aren't
      // skipped by the next delta pull — see [_deltaCursorLookback].
      await prefs.setInt(
        _prefsKeyLastSyncAt,
        DateTime.now().millisecondsSinceEpoch -
            _deltaCursorLookback.inMilliseconds,
      );
      // CR-fix M-40: advance the pull-cycle counter only now that the pull
      // succeeded, so failed pulls don't skip the periodic full reconciliation.
      await prefs.setInt(_prefsKeyPullCycleCount, pullCycleCount);
      // Record a successful full pull so the on-open throttle measures from it.
      if (isFullPull) {
        await prefs.setInt(_prefsKeyLastFullPullAt,
            DateTime.now().millisecondsSinceEpoch);
      }

      _authProvider.setSyncStatus(SyncStatus.synced);

      // Notify if data changed so UI can refresh
      if (anyChange) {
        _onDataChanged?.call();
      }
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    } finally {
      _syncing = false;
      if (_pushPending) {
        _pushPending = false;
        schedulePush();
      } else if (_pullPending) {
        _pullPending = false;
        final full = _pendingPullFull;
        _pendingPullFull = false;
        pull(fullPullOnOpen: full);
      }
    }
  }

  /// Full sync: push then pull.
  Future<void> syncNow() async {
    await push();
    await pull();
  }

  /// Callback invoked when remote data changes local state.
  VoidCallback? _onDataChanged;
  set onDataChanged(VoidCallback? callback) => _onDataChanged = callback;

  /// Maps exceptions to user-friendly messages (avoids leaking internal details).
  String _userFriendlyError(Object e) {
    if (e is SocketException) return 'Sync failed — check your connection';
    if (e is FirestoreException) return 'Sync failed — please try again';
    if (e is TimeoutException) return 'Sync timed out — try again later';
    return 'Sync error — try again later';
  }

  /// Get a valid token, refreshing if expired or missing.
  Future<String?> _getValidToken() async {
    if (_authProvider.firebaseIdToken != null && !_authProvider.isTokenExpired) {
      return _authProvider.firebaseIdToken;
    }
    final success = await _authProvider.refreshToken();
    return success ? _authProvider.firebaseIdToken : null;
  }
}
