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
  final FirestoreService _firestore = FirestoreService();
  final AuthProvider _authProvider;

  Timer? _pushDebounceTimer;
  Timer? _periodicPullTimer;
  bool _syncing = false;
  bool _pushPending = false;
  bool _pullPending = false;

  static const _prefsKeyLastSyncAt = 'sync_last_sync_at';
  static const _prefsKeyInitialMigrationDone = 'sync_initial_migration_done';
  static const _prefsKeyTodaysFivePersistedAt = 'sync_todays_five_persisted_at';

  static const _pushDebounceDelay = Duration(seconds: 5);
  static const _pullInterval = Duration(minutes: 5);

  SyncService(this._authProvider);

  /// Returns today's date as YYYY-MM-DD string for Firestore document key.
  String _todayDateKey() => todayDateKey();

  bool get _canSync =>
      _authProvider.isSignedIn &&
      _authProvider.uid != null &&
      _authProvider.firebaseIdToken != null &&
      _firestore.isConfigured;

  /// Start periodic pull timer, with an immediate pull to catch up.
  void startPeriodicPull() {
    _periodicPullTimer?.cancel();
    _periodicPullTimer = Timer.periodic(_pullInterval, (_) {
      if (_canSync) pull();
    });
    // Immediate pull so we don't wait 5 minutes for the first sync.
    if (_canSync) pull();
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

  /// Records that Today's 5 was persisted locally, then schedules a push.
  /// The timestamp is used during pull merge to determine whether remote
  /// or local state is newer (last-writer-wins).
  void onTodaysFivePersisted() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt(
          _prefsKeyTodaysFivePersistedAt, DateTime.now().millisecondsSinceEpoch);
    });
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

      // Push Today's 5 state
      final dateKey = _todayDateKey();
      final todaysFiveEntries = await _db.getTodaysFiveStateWithSyncIds(dateKey);
      if (todaysFiveEntries.isNotEmpty) {
        await _firestore.pushTodaysFive(
          uid, idToken, dateKey, todaysFiveEntries,
          DateTime.now().millisecondsSinceEpoch,
        );
      }

      // Mark migration done
      await prefs.setBool(key, true);
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

      _authProvider.setSyncStatus(SyncStatus.synced);
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    }
  }

  /// Replace local data with cloud data: wipe local, pull everything from cloud.
  Future<void> replaceLocalWithCloud() async {
    if (!_canSync) return;

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

      // Pull Today's 5 state
      final dateKey = _todayDateKey();
      final remote5 = await _firestore.pullTodaysFive(uid, idToken, dateKey);
      if (remote5 != null && remote5.entries.isNotEmpty) {
        await _db.upsertTodaysFiveFromRemote(dateKey, remote5.entries);
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
  }

  /// Replace cloud data with local: wipe all cloud data, push local up.
  Future<void> replaceCloudWithLocal() async {
    if (!_canSync) return;

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

      // Push Today's 5 state
      final dateKey = _todayDateKey();
      final todaysFiveEntries = await _db.getTodaysFiveStateWithSyncIds(dateKey);
      if (todaysFiveEntries.isNotEmpty) {
        await _firestore.pushTodaysFive(
          uid, idToken, dateKey, todaysFiveEntries,
          DateTime.now().millisecondsSinceEpoch,
        );
      }

      // Mark migration done
      final prefs = await SharedPreferences.getInstance();
      final key = '${_prefsKeyInitialMigrationDone}_$uid';
      await prefs.setBool(key, true);
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

      _authProvider.setSyncStatus(SyncStatus.synced);
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    }
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

      // Push Today's 5 state
      final dateKey = _todayDateKey();
      final todaysFiveEntries = await _db.getTodaysFiveStateWithSyncIds(dateKey);
      if (todaysFiveEntries.isNotEmpty) {
        await _firestore.pushTodaysFive(
          uid, idToken, dateKey, todaysFiveEntries,
          DateTime.now().millisecondsSinceEpoch,
        );
      }

      _authProvider.setSyncStatus(SyncStatus.synced);
    } catch (e) {
      _authProvider.setSyncStatus(SyncStatus.error, error: _userFriendlyError(e));
    } finally {
      _syncing = false;
      if (_pushPending) {
        _pushPending = false;
        schedulePush();
      } else if (_pullPending) {
        _pullPending = false;
        pull();
      }
    }
  }

  /// Pull remote changes and merge into local DB.
  Future<void> pull() async {
    if (!_canSync) return;
    if (_syncing) {
      _pullPending = true;
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
      final lastSyncAt = prefs.getInt(_prefsKeyLastSyncAt);

      // Pull tasks
      final remoteTasks = await _firestore.pullTasksSince(
        uid,
        idToken,
        lastSyncAt: lastSyncAt,
      );

      bool anyChange = false;
      for (final remoteTask in remoteTasks) {
        final changed = await _db.upsertFromRemote(remoteTask);
        if (changed) anyChange = true;
      }

      // Pull all relationships and dependencies, then reconcile with local
      final remoteRels = await _firestore.pullAllRelationships(uid, idToken);
      for (final rel in remoteRels) {
        // Check for DAG cycle before inserting
        final wouldCycle = await _db.wouldRelationshipCreateCycle(
            rel.parentSyncId, rel.childSyncId);
        if (!wouldCycle) {
          await _db.upsertRelationshipFromRemote(rel.parentSyncId, rel.childSyncId);
        }
      }

      // Remove local synced relationships that no longer exist remotely
      // but skip any that are pending push (locally created, not yet synced)
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

      final remoteDeps = await _firestore.pullAllDependencies(uid, idToken);
      for (final dep in remoteDeps) {
        // Check for dependency cycle before inserting
        final wouldCycle = await _db.wouldDependencyCreateCycle(
            dep.taskSyncId, dep.dependsOnSyncId);
        if (!wouldCycle) {
          await _db.upsertDependencyFromRemote(dep.taskSyncId, dep.dependsOnSyncId);
        }
      }

      // Remove local synced dependencies that no longer exist remotely
      // but skip any that are pending push (locally created, not yet synced)
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

      // Pull schedules
      final remoteSchedules = await _firestore.pullAllSchedules(uid, idToken);
      for (final schedule in remoteSchedules) {
        await _db.upsertScheduleFromRemote(schedule);
      }
      // Remove local schedules not in remote
      // but skip any that are pending push (locally created, not yet synced)
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

      // Pull Today's 5 state
      final dateKey = _todayDateKey();
      final remote5 = await _firestore.pullTodaysFive(uid, idToken, dateKey);
      if (remote5 != null && remote5.entries.isNotEmpty) {
        final localPersistedAt = prefs.getInt(_prefsKeyTodaysFivePersistedAt) ?? 0;
        final todaysFiveChanged = await _db.upsertTodaysFiveFromRemote(
          dateKey,
          remote5.entries,
          remoteUpdatedAt: remote5.updatedAt,
          localPersistedAt: localPersistedAt,
        );
        if (todaysFiveChanged) anyChange = true;
      }

      // Update last sync timestamp
      await prefs.setInt(_prefsKeyLastSyncAt, DateTime.now().millisecondsSinceEpoch);

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
        pull();
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
