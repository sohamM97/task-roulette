import 'package:flutter/foundation.dart' show kDebugMode, setEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/auth_provider.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../services/sync_service.dart';
import '../utils/display_utils.dart';
import '../widgets/completion_animation.dart';
import '../widgets/profile_icon.dart';
import '../widgets/task_picker_dialog.dart';
import 'completed_tasks_screen.dart';

/// Data needed for weighted task selection, shared by generation and swap.
class _SelectionContext {
  final List<Task> allLeaves;
  final List<int> leafIds;
  final Set<int> blockedIds;
  final Set<int> scheduleBoostedIds;
  final Map<int, int> deadlineDaysMap;
  final NormalizationData normData;
  /// Maps scheduled-source task ID → list of its leaf descendants active today.
  /// Used by the reserved-slot algorithm in _generateNewSet.
  final Map<int, List<int>> scheduledSourceToLeafMap;

  _SelectionContext({
    required this.allLeaves,
    required this.leafIds,
    required this.blockedIds,
    required this.scheduleBoostedIds,
    required this.deadlineDaysMap,
    required this.normData,
    required this.scheduledSourceToLeafMap,
  });
}

class TodaysFiveScreen extends StatefulWidget {
  final void Function(Task task)? onNavigateToTask;

  const TodaysFiveScreen({super.key, this.onNavigateToTask});

  @override
  State<TodaysFiveScreen> createState() => TodaysFiveScreenState();
}

class TodaysFiveScreenState extends State<TodaysFiveScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Task> _todaysTasks = [];
  final Set<int> _completedIds = {};
  /// Tracks tasks marked "Done today" (vs "Done for good!") so
  /// _handleUncomplete can revert the correct state.
  final Set<int> _workedOnIds = {};
  /// Tracks tasks that were auto-started by "Done today" (weren't started
  /// before). _handleUncomplete uses this to also call unstartTask.
  final Set<int> _autoStartedIds = {};
  /// Tracks pre-mutation lastWorkedAt values for "Done today" tasks,
  /// so _handleUncomplete can restore the original value.
  final Map<int, int?> _preWorkedOnLastWorkedAt = {};
  /// Task IDs explicitly uncompleted this session — prevents refreshSnapshots
  /// from re-adding them to _completedIds via isWorkedOnToday auto-detection.
  /// Bug fix: provider.unmarkWorkedOn triggers an unawaited refreshSnapshots()
  /// that races with _unmarkDone, re-reading isWorkedOnToday before DB settles.
  final Set<int> _explicitlyUncompletedIds = {};
  /// Cached ancestor-path strings keyed by task ID (e.g. "Work > Project X").
  Map<int, String> _taskPaths = {};
  /// Task ID → effective deadline info for icon display.
  Map<int, ({String deadline, String type})> _effectiveDeadlines = {};
  /// Leaf task IDs scheduled for today (for icon display).
  Set<int> _scheduledTodayIds = {};
  /// Other tasks completed/worked-on today, outside the Today's 5 set.
  List<Task> _otherDoneToday = [];
  bool _otherDoneExpanded = false;
  /// Tracks manually pinned tasks — protected from refresh until explicitly swapped.
  final Set<int> _pinnedIds = {};
  /// Deadline task IDs the user explicitly unpinned today. Persisted to DB
  /// so auto-pin doesn't override user intent across reloads/regeneration.
  final Set<int> _deadlineSuppressedIds = {};
  bool _loading = true;
  /// The date key that was last loaded, used to detect midnight rollover.
  String _loadedDateKey = '';
  TaskProvider? _provider;
  AuthProvider? _authProvider;

  @override
  void initState() {
    super.initState();
    _loadTodaysTasks();
    // Listen for external changes (e.g. undo "Done for good" from All Tasks)
    // so _otherDoneToday stays in sync without requiring a tab switch.
    _provider = context.read<TaskProvider>();
    _provider!.addListener(_onProviderChanged);
    // Listen for sync completion to reload Today's 5 from DB after pull.
    _authProvider = context.read<AuthProvider>();
    _authProvider!.addListener(_onSyncStatusChanged);
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    _authProvider?.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted || _loading) return;
    if (_todayKey() != _loadedDateKey) {
      _reloadFromDb();
      return;
    }
    refreshSnapshots();
  }

  void _onSyncStatusChanged() {
    if (!mounted || _loading) return;
    if (_authProvider?.syncStatus == SyncStatus.synced) {
      // Use refreshSnapshots() instead of _reloadFromDb() — it checks
      // whether the DB actually differs from in-memory state before
      // reloading. This avoids clearing in-flight pin/completion changes
      // when the sync didn't change Today's 5 data at all.
      // Pass checkCompletionStatus: true so remote completion changes are
      // detected (unlike tab-switch, where local state is authoritative).
      refreshSnapshots(checkCompletionStatus: true);
    }
  }

  /// Fully reloads Today's 5 from DB after a sync pull.
  /// Unlike refreshSnapshots() which keeps the same task IDs,
  /// this picks up any changes to the task list itself (e.g.
  /// different selections synced from another device).
  Future<void> _reloadFromDb() async {
    _completedIds.clear();
    _workedOnIds.clear();
    _pinnedIds.clear();
    _autoStartedIds.clear();
    _preWorkedOnLastWorkedAt.clear();
    _explicitlyUncompletedIds.clear();
    await _loadTodaysTasks();
  }

  String _todayKey() => todayDateKey();

  Future<void> _loadTodaysTasks() async {
    try {
      await _loadTodaysTasksInner();
    } catch (e) {
      if (kDebugMode) debugPrint('TodaysFiveScreen: _loadTodaysTasks failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadTodaysTasksInner() async {
    final provider = context.read<TaskProvider>();
    final db = DatabaseHelper();
    final today = _todayKey();
    _loadedDateKey = today;

    // Migrate SharedPreferences → DB (idempotent, safe to call every time)
    await db.migrateTodaysFiveFromPrefs();

    // Load suppressed deadline auto-pin IDs for today + purge old rows
    _deadlineSuppressedIds.clear();
    _deadlineSuppressedIds.addAll(await db.getDeadlineSuppressedIds(today));
    db.purgeOldDeadlineSuppressed(today).catchError(
        (e) => debugPrint('Failed to purge old suppression rows: $e'));

    // Try to restore from DB
    final saved = await db.loadTodaysFiveState(today);
    if (saved != null && saved.taskIds.isNotEmpty) {
      final ctx = await _fetchSelectionContext();
      final allLeaves = ctx.allLeaves;
      final leafIdSet = allLeaves.map((t) => t.id!).toSet();
      final savedCompletedIds = Set<int>.from(saved.completedIds);
      final savedWorkedOnIds = Set<int>.from(saved.workedOnIds);
      final savedPinnedIds = Set<int>.from(saved.pinnedIds);
      final tasks = <Task>[];
      for (final id in saved.taskIds) {
        if (leafIdSet.contains(id)) {
          // Still a leaf — restore from fresh data
          final match = allLeaves.where((t) => t.id == id);
          if (match.isNotEmpty) {
            tasks.add(match.first);
            // Detect external completion (e.g. worked-on from All Tasks)
            if (match.first.isWorkedOnToday && !savedCompletedIds.contains(id)) {
              savedCompletedIds.add(id);
            }
          }
        } else {
          // No longer a leaf — check if completed/done externally
          final fresh = await db.getTaskById(id);
          if (fresh != null) {
            if (savedCompletedIds.contains(id) || fresh.isCompleted || fresh.isWorkedOnToday) {
              savedCompletedIds.add(id);
              tasks.add(fresh);
            } else if (savedPinnedIds.contains(id)) {
              // Pinned task became non-leaf — try to slot in a leaf descendant
              final descendants = await db.getLeafDescendants(id);
              final currentIds = tasks.map((t) => t.id).toSet();
              final descLeafIds = descendants.map((d) => d.id!).toList();
              final descBlockedIds = await provider.getBlockedChildIds(descLeafIds);
              final eligibleDesc = descendants.where(
                (d) => !currentIds.contains(d.id) && !descBlockedIds.contains(d.id),
              ).toList();
              if (eligibleDesc.isNotEmpty) {
                // Bug fix: previously called pickWeightedN without schedule/
                // deadline/norm params, silently dropping 2.5x schedule boost
                // and up to 8x deadline boost during pinned-descendant replacement.
                final picked = provider.pickWeightedN(eligibleDesc, 1,
                    scheduleBoostedIds: ctx.scheduleBoostedIds,
                    deadlineDaysMap: ctx.deadlineDaysMap,
                    normData: ctx.normData);
                if (picked.isNotEmpty) {
                  tasks.add(picked.first);
                  savedPinnedIds.remove(id);
                  savedPinnedIds.add(picked.first.id!);
                }
              } else {
                savedPinnedIds.remove(id);
                // Will be backfilled randomly below
              }
            }
          }
        }
      }
      // Backfill if some non-done tasks are no longer leaves
      if (tasks.length < 5) {
        final currentIds = tasks.map((t) => t.id).toSet();
        final eligible = allLeaves.where(
          (t) => !currentIds.contains(t.id) && !ctx.blockedIds.contains(t.id),
        ).toList();
        // Bug fix: previously only passed normData, silently dropping
        // 2.5x schedule boost and up to 8x deadline boost during backfill.
        final replacements = provider.pickWeightedN(
          eligible, 5 - tasks.length,
          scheduleBoostedIds: ctx.scheduleBoostedIds,
          deadlineDaysMap: ctx.deadlineDaysMap,
          normData: ctx.normData,
        );
        tasks.addAll(replacements);
      }
      // Only keep completed/worked-on IDs for tasks still in the list
      final taskIdSet = tasks.map((t) => t.id).toSet();
      final validCompletedIds = savedCompletedIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      final validWorkedOnIds = savedWorkedOnIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      // Keep pinned IDs for tasks still in the list (including transferred pins)
      final validPinnedIds = savedPinnedIds
          .where((id) => taskIdSet.contains(id))
          .toSet();
      if (!mounted) return;
      _todaysTasks = tasks;
      await _loadOtherDoneToday();
      await _loadTaskPaths();
      if (!mounted) return;
      setState(() {
        _completedIds.addAll(validCompletedIds);
        _workedOnIds.addAll(validWorkedOnIds);
        _pinnedIds.addAll(validPinnedIds);
        _loading = false;
      });
      await _persist();
      return;
    }

    await _generateNewSet(autoPin: true);
  }

  /// Re-fetches task snapshots from DB without regenerating the set.
  /// Called when switching back to the Today tab to pick up changes
  /// made in All Tasks (e.g. unstarting a task, toggling pins).
  /// If the current set is empty, generates a new set instead (handles
  /// the case where the app started with no tasks and user added some).
  Future<void> refreshSnapshots({bool checkCompletionStatus = false}) async {
    // Midnight rollover: date changed since last load → generate fresh set
    if (_todayKey() != _loadedDateKey) {
      await _reloadFromDb();
      return;
    }
    if (_todaysTasks.isEmpty) {
      await _generateNewSet(autoPin: true);
      return;
    }

    // Detect external modifications: the task list screen can toggle pins
    // or add pinned tasks directly to the DB. If the DB state differs from
    // our in-memory state, do a full reload so we don't overwrite DB changes
    // when _persist() runs at the end.
    final saved = await DatabaseHelper().loadTodaysFiveState(_todayKey());
    if (saved != null) {
      final inMemoryTaskIds = _todaysTasks.map((t) => t.id!).toSet();
      final savedTaskIds = saved.taskIds.toSet();
      if (!setEquals(saved.pinnedIds, _pinnedIds) ||
          !setEquals(savedTaskIds, inMemoryTaskIds) ||
          (checkCompletionStatus && (
            !setEquals(saved.completedIds, _completedIds) ||
            !setEquals(saved.workedOnIds, _workedOnIds)))) {
        // Preserve session-only undo state (not persisted to DB)
        final prevAutoStarted = Set<int>.from(_autoStartedIds);
        final prevPreWorkedOn = Map<int, int?>.from(_preWorkedOnLastWorkedAt);
        await _reloadFromDb();
        _autoStartedIds.addAll(prevAutoStarted);
        _preWorkedOnLastWorkedAt.addAll(prevPreWorkedOn);
        return;
      }
    }

    if (!mounted) return;
    final provider = context.read<TaskProvider>();
    // Fetch only leaf list upfront — needed to determine which tasks are still
    // valid leaves. Full selection context (schedule boost, deadline boost,
    // norm, blocked) is fetched lazily below, only if pickWeightedN is needed.
    final allLeaves = await provider.getAllLeafTasks();
    final leafIdSet = allLeaves.map((t) => t.id!).toSet();
    final db = DatabaseHelper();
    final refreshed = <Task>[];
    _SelectionContext? ctx; // fetched lazily when pickWeightedN is needed
    for (final t in _todaysTasks) {
      if (leafIdSet.contains(t.id)) {
        // Still a leaf — re-fetch fresh data
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null) {
          refreshed.add(fresh);
          // Detect "worked on today" done externally (e.g. from All Tasks leaf detail).
          // Skip tasks explicitly uncompleted this session to prevent race
          // condition: unawaited refreshSnapshots re-adding tasks mid-uncomplete.
          if (fresh.isWorkedOnToday && !_completedIds.contains(fresh.id) &&
              !_explicitlyUncompletedIds.contains(fresh.id)) {
            _completedIds.add(fresh.id!);
          }
        }
      } else {
        // No longer a leaf — check if completed/done externally
        final fresh = await db.getTaskById(t.id!);
        if (fresh != null) {
          if (_completedIds.contains(t.id) || fresh.isCompleted || fresh.isWorkedOnToday) {
            // Keep for progress tracking
            _completedIds.add(fresh.id!);
            refreshed.add(fresh);
          } else if (_pinnedIds.contains(t.id)) {
            // Pinned task became non-leaf — try to slot in a leaf descendant
            final descendants = await db.getLeafDescendants(t.id!);
            final currentIds = refreshed.map((r) => r.id).toSet();
            final descLeafIds = descendants.map((d) => d.id!).toList();
            final descBlockedIds = await provider.getBlockedChildIds(descLeafIds);
            final eligibleDesc = descendants.where(
              (d) => !currentIds.contains(d.id) && !descBlockedIds.contains(d.id),
            ).toList();
            if (eligibleDesc.isNotEmpty) {
              // Bug fix: previously called pickWeightedN without schedule/
              // deadline/norm params, silently dropping 2.5x schedule boost
              // and up to 8x deadline boost during pinned-descendant replacement.
              ctx ??= await _fetchSelectionContext();
              final picked = provider.pickWeightedN(eligibleDesc, 1,
                  scheduleBoostedIds: ctx.scheduleBoostedIds,
                  deadlineDaysMap: ctx.deadlineDaysMap,
                  normData: ctx.normData);
              if (picked.isNotEmpty) {
                refreshed.add(picked.first);
                _pinnedIds.remove(t.id);
                _pinnedIds.add(picked.first.id!);
              }
            } else {
              _pinnedIds.remove(t.id);
              // Will be backfilled randomly below
            }
          }
          // Otherwise: became non-leaf without being done — will be backfilled
        }
      }
    }
    // Backfill replacements for non-done tasks that became non-leaf/deleted
    if (refreshed.length < _todaysTasks.length) {
      ctx ??= await _fetchSelectionContext();
      final currentIds = refreshed.map((t) => t.id).toSet();
      final eligible = ctx.allLeaves.where(
        (t) => !currentIds.contains(t.id) && !ctx!.blockedIds.contains(t.id),
      ).toList();
      // Bug fix: previously only passed normData, silently dropping
      // 2.5x schedule boost and up to 8x deadline boost during backfill.
      final replacements = provider.pickWeightedN(
        eligible, _todaysTasks.length - refreshed.length,
        scheduleBoostedIds: ctx.scheduleBoostedIds,
        deadlineDaysMap: ctx.deadlineDaysMap,
        normData: ctx.normData,
      );
      refreshed.addAll(replacements);
    }
    // Clean up completed IDs: remove if task left the list, or was
    // uncompleted externally (e.g. restored from archive)
    _completedIds.removeWhere((id) {
      final task = refreshed.where((t) => t.id == id).firstOrNull;
      if (task == null) return true; // no longer in list
      return !task.isCompleted && !task.isWorkedOnToday; // restored
    });
    // Keep workedOnIds in sync — remove if no longer in completed set
    _workedOnIds.removeWhere((id) => !_completedIds.contains(id));
    // Clean pinned IDs: remove if task left the list or is no longer a leaf.
    // Keep pins on completed tasks — they're not in leafIdSet (getAllLeafTasks
    // excludes completed) but should retain their pinned indicator.
    _pinnedIds.removeWhere((id) {
      if (!refreshed.any((t) => t.id == id)) return true; // not in list
      if (_completedIds.contains(id)) return false; // keep pin on done tasks
      return !leafIdSet.contains(id); // no longer a leaf
    });
    if (!mounted) return;
    _todaysTasks = refreshed;
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {});
    await _persistAndTrim();
  }

  /// Fetches all data needed for weighted task selection (normalization,
  /// schedule boosts, deadline data, blocked IDs). Shared by generation
  /// and swap to keep selection logic consistent.
  Future<_SelectionContext> _fetchSelectionContext() async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);
    final scheduleBoostedIds = await provider.getScheduleBoostedLeafIds();
    final deadlineDaysMap = await provider.getDeadlineBoostedLeafData();
    final normData = await provider.getNormalizationData(leafIds);
    final scheduledSourceToLeafMap = await provider.getScheduledSourceToLeafMap();
    return _SelectionContext(
      allLeaves: allLeaves,
      leafIds: leafIds,
      blockedIds: blockedIds,
      scheduleBoostedIds: scheduleBoostedIds,
      deadlineDaysMap: deadlineDaysMap,
      normData: normData,
      scheduledSourceToLeafMap: scheduledSourceToLeafMap,
    );
  }

  /// Bug fix: Previously, deadline-due tasks were never auto-pinned during
  /// generation — only when explicitly setting a deadline from All Tasks.
  /// Before: 'on' deadline tasks got neither weight boost nor auto-pin when
  /// Today's 5 was first generated, so they were unlikely to appear.
  /// After: [autoPin] = true on first generation force-pins deadline-due
  /// tasks. Rerolls ("New set") don't auto-pin to avoid whack-a-mole.
  Future<void> _generateNewSet({bool autoPin = false}) async {
    // Clear stale per-session tracking sets from previous day
    _workedOnIds.clear();
    _autoStartedIds.clear();
    _preWorkedOnLastWorkedAt.clear();

    final provider = context.read<TaskProvider>();
    final ctx = await _fetchSelectionContext();

    // Keep done + pinned tasks, only replace the rest
    final kept = _todaysTasks.where(
      (t) => _completedIds.contains(t.id) || _pinnedIds.contains(t.id),
    ).toList();
    // Clean pinned IDs for tasks no longer in the kept set
    _pinnedIds.removeWhere((id) => !kept.any((t) => t.id == id));
    final keptIds = kept.map((t) => t.id).toSet();

    // On first generation of the day, auto-pin deadline-due tasks.
    // Not on rerolls ("New set") — that would cause whack-a-mole where
    // unpinning one deadline task just pins another on next reroll.
    if (autoPin) {
      final deadlinePinIds = await provider.getDeadlinePinLeafIds();
      final leafById = {for (final t in ctx.allLeaves) t.id!: t};
      for (final id in deadlinePinIds) {
        if (keptIds.contains(id)) continue;
        if (_deadlineSuppressedIds.contains(id)) continue;
        if (ctx.blockedIds.contains(id)) continue;
        final task = leafById[id];
        if (task == null) continue;
        if (_pinnedIds.length >= maxPins) break;
        kept.add(task);
        keptIds.add(id);
        _pinnedIds.add(id);
      }
    }

    final leafById = {for (final t in ctx.allLeaves) t.id!: t};

    // --- Reserved slots: guarantee representation for scheduled sources ---
    // For each distinct source with a schedule for today, reserve 1 slot by
    // picking a leaf from that source. This ensures scheduled tasks appear
    // regardless of how many descendants they have (probabilistic boosts are
    // unreliable when normalization penalizes large hierarchies).
    //
    // Rules:
    //  - Cap at min(sources, 4) reserved — always leave ≥1 general-pool slot
    //    when 2+ sources are available (variety matters per ADHD research).
    //  - If only 1 slot remains, give it to a scheduled source (user scheduled it).
    //  - Sources are shuffled so no source always gets first pick.
    //  - Reserved picks are NOT pinned — user can swap them freely.
    //  - Reserved picks' roots are seeded into existingRootPickCounts so the
    //    general pool penalises picking the same root again.
    final reserved = <Task>[];
    final reservedIds = <int>{};
    final slotsAvailable = (5 - kept.length).clamp(0, 5);
    if (slotsAvailable > 0 && ctx.scheduledSourceToLeafMap.isNotEmpty) {
      final sources = ctx.scheduledSourceToLeafMap.keys.toList()..shuffle();
      // Reserve up to min(sources, 4), but never consume all slots unless
      // there's only 1 slot left (in which case still reserve it).
      final maxReserved = slotsAvailable == 1
          ? 1
          : sources.length.clamp(0, (slotsAvailable - 1).clamp(0, 4));
      for (final sourceId in sources) {
        if (reserved.length >= maxReserved) break;
        final candidateIds = ctx.scheduledSourceToLeafMap[sourceId]!;
        // Prefer exclusive leaf (not already reserved by another source).
        // If all candidates are already reserved (shared DAG leaves), fall back
        // to the full eligible pool — the pick won't add a duplicate.
        final exclusiveCandidates = candidateIds
            .where((id) => !ctx.blockedIds.contains(id) && !keptIds.contains(id) &&
                !reservedIds.contains(id))
            .map((id) => leafById[id])
            .whereType<Task>()
            .toList();
        final candidates = exclusiveCandidates.isNotEmpty
            ? exclusiveCandidates
            : candidateIds
                .where((id) => !ctx.blockedIds.contains(id) && !keptIds.contains(id))
                .map((id) => leafById[id])
                .whereType<Task>()
                .toList();
        if (candidates.isEmpty) continue;
        final pick = provider.pickWeightedN(candidates, 1,
            scheduleBoostedIds: ctx.scheduleBoostedIds,
            deadlineDaysMap: ctx.deadlineDaysMap,
            normData: ctx.normData);
        if (pick.isNotEmpty && !reservedIds.contains(pick.first.id)) {
          reserved.add(pick.first);
          reservedIds.add(pick.first.id!);
        }
      }
    }

    // Seed diversity penalty with roots already represented by kept + reserved,
    // so the general pool penalises picking the same root categories again.
    final rootPickCounts = <int, int>{};
    for (final task in [...kept, ...reserved]) {
      final roots = ctx.normData.leafToRoots[task.id] ?? <int>{};
      for (final r in roots) {
        rootPickCounts[r] = (rootPickCounts[r] ?? 0) + 1;
      }
    }

    final eligible = ctx.allLeaves.where(
      (t) => !ctx.blockedIds.contains(t.id) &&
          !keptIds.contains(t.id) &&
          !reservedIds.contains(t.id),
    ).toList();

    final slotsToFill = (5 - kept.length - reserved.length).clamp(0, 5);
    final picked = provider.pickWeightedN(eligible, slotsToFill,
        scheduleBoostedIds: ctx.scheduleBoostedIds,
        deadlineDaysMap: ctx.deadlineDaysMap,
        normData: ctx.normData,
        existingRootPickCounts: rootPickCounts.isEmpty ? null : rootPickCounts);
    if (!mounted) return;
    _todaysTasks = [...kept, ...reserved, ...picked];
    await _loadOtherDoneToday();
    await _loadTaskPaths();
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    await _persist();
  }

  /// Trims excess unpinned undone tasks and persists. Calls setState if
  /// the list actually shrank so the UI updates immediately.
  Future<void> _persistAndTrim() async {
    final currentIds = _todaysTasks.map((t) => t.id!).toList();
    final trimmedIds = TodaysFivePinHelper.trimExcess(
      currentIds, _completedIds, _pinnedIds,
    );
    if (trimmedIds.length < currentIds.length) {
      final trimmedSet = trimmedIds.toSet();
      _todaysTasks.removeWhere((t) => !trimmedSet.contains(t.id));
      if (mounted) setState(() {});
    }
    await _persist();
  }

  Future<void> _persist() async {
    await DatabaseHelper().saveTodaysFiveState(
      date: _todayKey(),
      taskIds: _todaysTasks.map((t) => t.id!).toList(),
      completedIds: _completedIds,
      workedOnIds: _workedOnIds,
      pinnedIds: _pinnedIds,
    );
    if (mounted) {
      context.read<SyncService>().schedulePush();
    }
  }

  /// Fetches ancestor paths for all tasks in [_todaysTasks] + [_otherDoneToday]
  /// and caches them.
  Future<void> _loadTaskPaths() async {
    final db = DatabaseHelper();
    final paths = <int, String>{};
    final allTasks = [..._todaysTasks, ..._otherDoneToday];
    for (final task in allTasks) {
      final ancestors = await db.getAncestorPath(task.id!);
      if (ancestors.isNotEmpty) {
        paths[task.id!] = ancestors.map((t) => t.name).join(' › ');
      }
    }
    _taskPaths = paths;
    final taskIds = allTasks.map((t) => t.id!).toList();
    _effectiveDeadlines = await db.getEffectiveDeadlines(taskIds);
    _scheduledTodayIds = await db.getEffectiveScheduledTodayIds(taskIds);
  }

  /// Loads tasks completed/worked-on today that aren't in Today's 5.
  Future<void> _loadOtherDoneToday() async {
    final todaysFiveIds = _todaysTasks.map((t) => t.id!).toSet();
    _otherDoneToday = await DatabaseHelper().getTasksDoneToday(
      excludeIds: todaysFiveIds,
    );
  }

  /// Truncates a hierarchy path to keep the last 2 segments when there
  /// are more than 3, so the immediate parent is always visible.
  /// e.g. "Coding › App › Enhancements › Random" → "… › Enhancements › Random"
  Color _deadlineIconColor(({String deadline, String type}) info, ColorScheme colorScheme) {
    return deadlineDisplayColor(info.deadline, info.type, colorScheme);
  }

  String _shortenPath(String path) => shortenAncestorPath(path);

  /// Re-fetches a single task from DB and updates it in [_todaysTasks].
  /// Does NOT call setState — callers handle that.
  /// Returns the fresh task, or null if not found.
  Future<Task?> _refreshTaskSnapshot(int taskId) async {
    final fresh = await DatabaseHelper().getTaskById(taskId);
    if (fresh != null) {
      final idx = _todaysTasks.indexWhere((t) => t.id == taskId);
      if (idx >= 0) _todaysTasks[idx] = fresh;
    }
    return fresh;
  }

  /// Marks a task as done: updates sets, refreshes snapshot, setState, persist.
  /// [workedOn] — true for "Done today", false for "Done for good!"
  /// [autoStarted] — true if the task was auto-started by "Done today"
  Future<void> _markDone(int taskId, {required bool workedOn, required bool autoStarted}) async {
    _completedIds.add(taskId);
    _explicitlyUncompletedIds.remove(taskId);
    if (workedOn) _workedOnIds.add(taskId);
    if (autoStarted) _autoStartedIds.add(taskId);
    await _refreshTaskSnapshot(taskId);
    await _loadOtherDoneToday();
    if (!mounted) return;
    setState(() {});
    await _persist();
  }

  /// Unmarks a task as done: updates sets, refreshes snapshot, setState, persist.
  /// Also trims excess tasks — uncompleting may leave unpinned undone tasks
  /// beyond slot 5 that should be removed.
  Future<void> _unmarkDone(int taskId, {required bool workedOn, required bool autoStarted}) async {
    _completedIds.remove(taskId);
    if (workedOn) _workedOnIds.remove(taskId);
    if (autoStarted) _autoStartedIds.remove(taskId);
    await _refreshTaskSnapshot(taskId);
    await _loadOtherDoneToday();
    if (!mounted) return;
    setState(() {});
    await _persistAndTrim();
  }

  /// Shows a bottom sheet: "In progress" / "Done today" / "Done for good!" / Pin/Unpin
  void _showTaskOptions(Task task) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPinned = _pinnedIds.contains(task.id);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.today, color: Colors.orange),
                title: const Text('Done today'),
                subtitle: const Text('Partial work counts — we\'ll remind you again soon.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _workedOnTask(task);
                },
              ),
              ListTile(
                leading: Icon(Icons.check_circle, color: colorScheme.primary),
                title: const Text('Done for good!'),
                subtitle: const Text('Permanently complete this task'),
                onTap: () {
                  Navigator.pop(ctx);
                  _completeNormalTask(task);
                },
              ),
              if (!task.isStarted)
                ListTile(
                  leading: Icon(Icons.play_circle_outline, color: colorScheme.tertiary),
                  title: const Text('In progress'),
                  subtitle: const Text("I'm working on this"),
                  onTap: () {
                    Navigator.pop(ctx);
                    _markInProgress(task);
                  },
                )
              else
                ListTile(
                  leading: Icon(Icons.stop_circle_outlined, color: colorScheme.onSurfaceVariant),
                  title: const Text('Stop working'),
                  subtitle: const Text('Remove in-progress marker'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _stopWorking(task);
                  },
                ),
              if (isPinned)
                ListTile(
                  leading: Icon(Icons.push_pin_outlined, color: colorScheme.onSurfaceVariant),
                  title: const Text('Unpin'),
                  subtitle: const Text('Remove from must do'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePinFromSheet(task);
                  },
                )
              else if (_pinnedIds.length < maxPins)
                ListTile(
                  leading: Icon(Icons.push_pin, color: colorScheme.tertiary),
                  title: const Text('Pin'),
                  subtitle: const Text('Mark as must do'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _togglePinFromSheet(task);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _togglePinFromSheet(Task task) {
    final wasPinned = _pinnedIds.contains(task.id);
    final result = TodaysFivePinHelper.togglePinInPlace(
      _pinnedIds, task.id!,
    );
    if (result == null) {
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, 'Max 5 pinned tasks — unpin one first');
    } else {
      setState(() {
        _pinnedIds.clear();
        _pinnedIds.addAll(result);
      });
      // Track deadline suppression: if user unpins a deadline task, suppress
      // auto-pin so it doesn't get re-pinned on reload/regeneration.
      if (wasPinned && _effectiveDeadlines.containsKey(task.id)) {
        _deadlineSuppressedIds.add(task.id!);
        DatabaseHelper().suppressDeadlineAutoPin(_todayKey(), task.id!).catchError(
            (e) => debugPrint('Failed to suppress deadline auto-pin: $e'));
      } else if (!wasPinned && _deadlineSuppressedIds.contains(task.id)) {
        _deadlineSuppressedIds.remove(task.id!);
        DatabaseHelper().unsuppressDeadlineAutoPin(_todayKey(), task.id!).catchError(
            (e) => debugPrint('Failed to unsuppress deadline auto-pin: $e'));
      }
      _persistAndTrim();
    }
  }

  Future<void> _stopWorking(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.unstartTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — stopped.');
  }

  Future<void> _markInProgress(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.startTask(task.id!);
    await _refreshTaskSnapshot(task.id!);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — on it!');
  }

  Future<void> _workedOnTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final wasStarted = task.isStarted;
    final previousLastWorkedAt = task.lastWorkedAt;
    _preWorkedOnLastWorkedAt[task.id!] = previousLastWorkedAt;
    // If the task has its own deadline, ask whether to remove it.
    // null = cancelled (dismiss/back) → abort the whole "Done today" action.
    final hadDeadline = task.hasDeadline;
    bool removeDeadline = false;
    if (hadDeadline) {
      final result = await askRemoveDeadlineOnDone(context, task.deadline!, task.deadlineType);
      if (!mounted) return;
      if (result == null) return; // user cancelled — abort
      removeDeadline = result;
    }
    await showCompletionAnimation(context);
    if (!mounted) return;
    await provider.markWorkedOn(task.id!);
    if (!wasStarted) await provider.startTask(task.id!);
    if (removeDeadline) {
      await provider.updateTaskDeadline(task.id!, null);
    }
    await _markDone(task.id!, workedOn: true, autoStarted: !wasStarted);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" — nice work! We\'ll remind you again soon.', onUndo: () async {
      _preWorkedOnLastWorkedAt.remove(task.id);
      await provider.unmarkWorkedOn(task.id!, restoreTo: previousLastWorkedAt);
      if (!wasStarted) await provider.unstartTask(task.id!);
      if (removeDeadline) {
        await provider.updateTaskDeadline(task.id!, task.deadline!, deadlineType: task.deadlineType);
      }
      if (!mounted) return;
      _explicitlyUncompletedIds.add(task.id!);
      await _unmarkDone(task.id!, workedOn: true, autoStarted: !wasStarted);
    });
  }

  Future<void> _completeNormalTask(Task task) async {
    final provider = context.read<TaskProvider>();

    // Check if completing this task will free any dependents — confirm first.
    final dependentNames = await provider.getDependentTaskNames(task.id!);
    if (!mounted) return;
    if (!await confirmDependentUnblock(context, task.name, dependentNames)) return;
    if (!mounted) return;

    await showCompletionAnimation(context);
    if (!mounted) return;
    final removedDeps = await provider.completeTaskOnly(task.id!);
    await _markDone(task.id!, workedOn: false, autoStarted: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, '"${task.name}" done!', onUndo: () async {
      await provider.uncompleteTask(task.id!, restoredDeps: removedDeps);
      if (!mounted) return;
      await _unmarkDone(task.id!, workedOn: false, autoStarted: false);
    });
  }

  /// Handles the check action on a Today's 5 task.
  /// Always shows bottom sheet: "Done today" vs "Done for good!"
  Future<void> _handleTaskDone(Task task) async {
    _showTaskOptions(task);
  }

  /// If [task] is no longer a leaf, replaces it in [_todaysTasks] with
  /// a randomly picked eligible leaf (or removes it if none available).
  /// Calls setState if a replacement happens.
  Future<void> _replaceIfNoLongerLeaf(Task task) async {
    final provider = context.read<TaskProvider>();
    final ctx = await _fetchSelectionContext();
    final leafIdSet = ctx.allLeaves.map((t) => t.id!).toSet();
    if (leafIdSet.contains(task.id)) return;

    final idx = _todaysTasks.indexWhere((t) => t.id == task.id);
    if (idx < 0) return;

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final eligible = ctx.allLeaves.where(
      (t) => !currentIds.contains(t.id) && !ctx.blockedIds.contains(t.id),
    ).toList();
    // Bug fix: previously called pickWeightedN without any optional params,
    // silently dropping schedule boost (2.5x), deadline boost (up to 8x),
    // and normalization during non-leaf replacement.
    final replacements = provider.pickWeightedN(eligible, 1,
        scheduleBoostedIds: ctx.scheduleBoostedIds,
        deadlineDaysMap: ctx.deadlineDaysMap,
        normData: ctx.normData);
    if (!mounted) return;
    _pinnedIds.remove(task.id);
    setState(() {
      if (replacements.isNotEmpty) {
        _todaysTasks[idx] = replacements.first;
      } else {
        _todaysTasks.removeAt(idx);
      }
    });
  }

  /// Uncompletes a task that was marked done in Today's 5.
  /// Correctly reverts "Done today" (unmark worked-on + unstart) vs
  /// "Done for good!" (uncomplete). If the task is no longer a leaf,
  /// swaps it out immediately.
  Future<void> _handleUncomplete(Task task) async {
    final provider = context.read<TaskProvider>();

    // Check actual DB state — task may have been completed externally
    // (e.g. via "Go to task" → All Tasks) even if _workedOnIds has it.
    final wasWorkedOn = _workedOnIds.contains(task.id);
    final wasAutoStarted = _autoStartedIds.contains(task.id);
    if (wasWorkedOn && !task.isCompleted) {
      // "Done today" only — revert worked-on state, restore original lastWorkedAt
      final restoreTo = _preWorkedOnLastWorkedAt.remove(task.id);
      await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
      if (wasAutoStarted) await provider.unstartTask(task.id!);
    } else if (task.isCompleted) {
      // "Done for good!" (or externally completed) — revert completion
      await provider.uncompleteTask(task.id!);
      if (wasWorkedOn) {
        final restoreTo = _preWorkedOnLastWorkedAt.remove(task.id);
        await provider.unmarkWorkedOn(task.id!, restoreTo: restoreTo);
      }
    }

    if (!mounted) return;
    _explicitlyUncompletedIds.add(task.id!);
    await _unmarkDone(task.id!, workedOn: wasWorkedOn, autoStarted: wasAutoStarted);
    if (!mounted) return;
    await _replaceIfNoLongerLeaf(task);

    if (!mounted) return;
    final wasRemoved = !_todaysTasks.any((t) => t.id == task.id);
    ScaffoldMessenger.of(context).clearSnackBars();
    showInfoSnackBar(context, wasRemoved
        ? '"${task.name}" restored and removed from Today\'s 5 (all slots are pinned).'
        : '"${task.name}" restored.');
  }

  Future<void> _confirmNewSet() async {
    final replaceableCount = _todaysTasks.where(
      (t) => !_completedIds.contains(t.id) && !_pinnedIds.contains(t.id),
    ).length;
    final pinnedCount = _todaysTasks.where(
      (t) => _pinnedIds.contains(t.id) && !_completedIds.contains(t.id),
    ).length;
    final String message;
    if (replaceableCount == 0) {
      message = 'All tasks are done or pinned — nothing to reroll.';
    } else if (pinnedCount > 0) {
      message = 'Reroll $replaceableCount undone ${replaceableCount == 1 ? 'task' : 'tasks'}? '
          'Done and pinned tasks will stay.';
    } else if (replaceableCount == _todaysTasks.length) {
      message = 'Reroll all tasks with a fresh set of 5?';
    } else {
      message = 'Reroll $replaceableCount undone ${replaceableCount == 1 ? 'task' : 'tasks'}? '
          'Done tasks will stay.';
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reroll all?'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          if (replaceableCount > 0)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reroll'),
            ),
        ],
      ),
    );
    if (confirmed == true) await _generateNewSet();
  }

  Future<void> _confirmSwapTask(int index) async {
    final task = _todaysTasks[index];
    final isPinned = _pinnedIds.contains(task.id);
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPinned)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.push_pin, size: 16, color: colorScheme.tertiary),
                      const SizedBox(width: 6),
                      Text(
                        'This task was manually pinned.',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: Icon(spinIcon, color: colorScheme.onSurfaceVariant),
                title: const Text('Roulette spin'),
                subtitle: const Text('Spin the wheel for a new task'),
                onTap: () {
                  Navigator.pop(ctx);
                  if (isPinned) {
                    _confirmUnpinAndSwap(index);
                  } else {
                    _swapTask(index);
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.checklist, color: colorScheme.primary),
                title: const Text('Place your bet'),
                subtitle: const Text('Hand-pick a task for this slot'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndPinTask(index);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows extra confirmation when randomly replacing a pinned task.
  Future<void> _confirmUnpinAndSwap(int index) async {
    final task = _todaysTasks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reroll pinned task?'),
        content: Text('"${task.name}" was manually pinned. Reroll this slot?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reroll'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _pinnedIds.remove(task.id);
      await _swapTask(index);
    }
  }

  /// Opens TaskPickerDialog to let the user choose a task for a slot, then pins it.
  Future<void> _pickAndPinTask(int index) async {
    final provider = context.read<TaskProvider>();
    final allLeaves = await provider.getAllLeafTasks();
    final leafIds = allLeaves.map((t) => t.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(leafIds);

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final eligible = allLeaves.where(
      (t) => !currentIds.contains(t.id) &&
             !blockedIds.contains(t.id) &&
             !t.isWorkedOnToday,
    ).toList();

    if (eligible.isEmpty) {
      if (mounted) {
        showInfoSnackBar(context, 'No tasks left to spin');
      }
      return;
    }

    final parentNamesMap = await provider.getParentNamesForTaskIds(
      eligible.map((t) => t.id!).toList(),
    );

    if (!mounted) return;
    final picked = await showDialog<Task>(
      context: context,
      builder: (ctx) => TaskPickerDialog(
        candidates: eligible,
        title: 'Place your bet',
        parentNamesMap: parentNamesMap,
      ),
    );
    if (picked == null || !mounted) return;

    final oldTask = _todaysTasks[index];
    final wasPinned = _pinnedIds.remove(oldTask.id);
    // Always pin the picked task (we just freed a slot if old was pinned)
    final newPins = TodaysFivePinHelper.togglePinInPlace(_pinnedIds, picked.id!);
    if (newPins == null) {
      // Restore old pin if we can't fit the new one
      if (wasPinned) _pinnedIds.add(oldTask.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Max 5 pinned tasks — unpin one first');
      }
      return;
    }
    _pinnedIds.clear();
    _pinnedIds.addAll(newPins);
    // Load ancestor path for the new task's breadcrumb subtitle
    final ancestors = await DatabaseHelper().getAncestorPath(picked.id!);
    if (ancestors.isNotEmpty) {
      _taskPaths[picked.id!] = ancestors.map((t) => t.name).join(' › ');
    } else {
      _taskPaths.remove(picked.id!);
    }
    setState(() {
      _todaysTasks[index] = picked;
    });
    await _persist();
  }

  Future<void> _swapTask(int index) async {
    final provider = context.read<TaskProvider>();
    final ctx = await _fetchSelectionContext();

    final currentIds = _todaysTasks.map((t) => t.id).toSet();
    final eligible = ctx.allLeaves.where(
      (t) => !currentIds.contains(t.id) &&
             !ctx.blockedIds.contains(t.id) &&
             !t.isWorkedOnToday,
    ).toList();

    if (eligible.isEmpty) {
      if (mounted) {
        showInfoSnackBar(context, 'No tasks left to spin');
      }
      return;
    }

    // Seed diversity penalty from current Today's 5 (excluding the task
    // being swapped out) so the replacement respects existing root spread.
    // Completed tasks aren't in normData.leafToRoots (they're excluded from
    // getAllLeafTasks), so look up their roots separately.
    final missingIds = <int>[];
    for (int i = 0; i < _todaysTasks.length; i++) {
      if (i == index) continue;
      final tid = _todaysTasks[i].id;
      if (tid != null && !ctx.normData.leafToRoots.containsKey(tid)) {
        missingIds.add(tid);
      }
    }
    final extraRoots = missingIds.isEmpty
        ? <int, Set<int>>{}
        : await DatabaseHelper().getRootAncestorsForLeaves(missingIds);

    final rootPickCounts = <int, int>{};
    for (int i = 0; i < _todaysTasks.length; i++) {
      if (i == index) continue; // skip the slot being replaced
      final tid = _todaysTasks[i].id;
      if (tid != null) {
        final roots = ctx.normData.leafToRoots[tid]
            ?? extraRoots[tid]
            ?? <int>{};
        for (final r in roots) {
          rootPickCounts[r] = (rootPickCounts[r] ?? 0) + 1;
        }
      }
    }

    final picked = provider.pickWeightedN(eligible, 1,
        scheduleBoostedIds: ctx.scheduleBoostedIds,
        deadlineDaysMap: ctx.deadlineDaysMap,
        normData: ctx.normData,
        existingRootPickCounts: rootPickCounts);
    if (picked.isNotEmpty) {
      // Complete async work before mutating state
      final db = DatabaseHelper();
      final newId = picked.first.id!;
      final ancestors = await db.getAncestorPath(newId);
      final deadlines = await db.getEffectiveDeadlines([newId]);
      if (!mounted) return;
      _pinnedIds.remove(_todaysTasks[index].id);
      _todaysTasks[index] = picked.first;
      if (ancestors.isNotEmpty) {
        _taskPaths[newId] = ancestors.map((t) => t.name).join(' › ');
      } else {
        _taskPaths.remove(newId);
      }
      if (deadlines.containsKey(newId)) {
        _effectiveDeadlines[newId] = deadlines[newId]!;
      }
      setState(() {});
      await _persist();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final completedCount = _completedIds.length;
    final totalCount = _todaysTasks.length;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Task Roulette',
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 30,
                fontWeight: FontWeight.w400,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              "Today\u2019s 5",
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 16,
                fontWeight: FontWeight.w300,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        toolbarHeight: 72,
        actions: [
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.nightlight_round, size: 20),
              onPressed: () async {
                // Simulate midnight rollover: set _loadedDateKey to yesterday
                // so refreshSnapshots detects a date mismatch and triggers
                // _reloadFromDb → _loadTodaysTasksInner (same as real midnight).
                final messenger = ScaffoldMessenger.of(context);
                final yesterday = DateTime.now().subtract(const Duration(days: 1));
                _loadedDateKey = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
                // Delete today's saved state so first-gen auto-pin fires
                await DatabaseHelper().deleteTodaysFiveState(_todayKey());
                await refreshSnapshots();
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Simulated midnight rollover')),
                  );
                }
              },
              tooltip: 'Simulate midnight rollover',
            ),
          const ProfileIcon(),
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return IconButton(
                icon: Icon(themeProvider.icon, size: 22),
                onPressed: themeProvider.toggle,
                tooltip: 'Toggle theme',
              );
            },
          ),
          IconButton(
            icon: const Icon(archiveIcon, size: 22),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const CompletedTasksScreen(),
                ),
              );
              if (mounted) await refreshSnapshots();
            },
            tooltip: 'Archive',
          ),
          if (_todaysTasks.any((t) =>
              !_completedIds.contains(t.id) && !_pinnedIds.contains(t.id)))
            IconButton(
              icon: SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: -1,
                      bottom: 0,
                      child: Transform.rotate(
                        angle: -0.3,
                        child: Icon(Icons.casino_rounded, size: 16,
                            color: Theme.of(context).colorScheme.onSurface.withAlpha(140)),
                      ),
                    ),
                    Positioned(
                      right: -1,
                      top: 0,
                      child: Transform.rotate(
                        angle: 0.25,
                        child: Icon(Icons.casino_rounded, size: 18,
                            color: Theme.of(context).colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
              onPressed: _confirmNewSet,
              tooltip: 'Reroll all',
            ),
        ],
      ),
      body: _todaysTasks.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 64, color: colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'No tasks for today!',
                    style: textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add some tasks in the All Tasks tab.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        : Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Segmented progress bar
            _buildSegmentedProgress(colorScheme, totalCount, completedCount),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: completedCount == 0
                        ? _motivationalText()
                        : completedCount == totalCount
                            ? 'All $totalCount done!'
                            : '$completedCount of $totalCount done',
                    style: completedCount == totalCount && totalCount > 0
                        ? const TextStyle(color: Color(0xFF66BB6A), fontWeight: FontWeight.w500)
                        : null,
                  ),
                  if (_otherDoneToday.isNotEmpty)
                    TextSpan(
                      text: '  +${_otherDoneToday.length} ${_otherDoneToday.length == 1 ? 'other' : 'others'}',
                      style: TextStyle(
                        color: completedCount == totalCount && totalCount > 0
                            ? const Color(0xFF66BB6A).withAlpha(140)
                            : colorScheme.primary.withAlpha(180),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Task list — pinned undone tasks on top as "Must do"
            Expanded(
              child: _buildTaskList(context, colorScheme, textTheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList(BuildContext context, ColorScheme colorScheme, TextTheme textTheme) {
    // Split into three buckets: pinned-undone, undone-unpinned, done
    final mustDo = <int>[]; // indices into _todaysTasks
    final rest = <int>[];
    final done = <int>[];
    for (int i = 0; i < _todaysTasks.length; i++) {
      final task = _todaysTasks[i];
      final isDone = _completedIds.contains(task.id);
      if (isDone) {
        done.add(i);
      } else if (_pinnedIds.contains(task.id)) {
        mustDo.add(i);
      } else {
        rest.add(i);
      }
    }

    final showSections = mustDo.isNotEmpty || done.isNotEmpty;

    if (!showSections) {
      // No pinned tasks and no done tasks — flat list, no headers
      return ListView(
        children: [
          for (int i = 0; i < _todaysTasks.length; i++)
            _buildTaskCard(context, _todaysTasks[i], i, false),
          if (_otherDoneToday.isNotEmpty)
            _buildOtherDoneBox(context, textTheme, colorScheme),
        ],
      );
    }

    return ListView(
      children: [
        if (mustDo.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            icon: Icons.push_pin,
            label: 'Must do',
            color: colorScheme.tertiary,
          ),
          for (final i in mustDo)
            _buildTaskCard(context, _todaysTasks[i], i, false),
        ],
        if (rest.isNotEmpty) ...[
          if (mustDo.isNotEmpty)
            _buildSectionHeader(
              context,
              icon: Icons.casino_outlined,
              label: 'Also on the table',
              color: colorScheme.onSurfaceVariant,
              topPadding: 12,
            ),
          for (final i in rest)
            _buildTaskCard(context, _todaysTasks[i], i, false),
        ],
        if (done.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            icon: Icons.check_circle_outline,
            label: 'Done',
            color: colorScheme.primary,
            topPadding: 12,
          ),
          for (final i in done)
            _buildTaskCard(context, _todaysTasks[i], i, true),
        ],
        if (_otherDoneToday.isNotEmpty)
          _buildOtherDoneBox(context, textTheme, colorScheme),
      ],
    );
  }


  Widget _buildSegmentedProgress(ColorScheme colorScheme, int total, int completed) {
    if (total == 0) return const SizedBox.shrink();
    return Row(
      children: List.generate(total, (i) {
        final isDone = i < completed;
        final isFirst = i == 0;
        final isLast = i == total - 1;
        return Expanded(
          child: Container(
            height: 8,
            margin: EdgeInsets.only(
              left: isFirst ? 0 : 1.5,
              right: isLast ? 0 : 1.5,
            ),
            decoration: BoxDecoration(
              color: isDone
                  ? const Color(0xFF66BB6A)
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.horizontal(
                left: isFirst ? const Radius.circular(4) : Radius.zero,
                right: isLast ? const Radius.circular(4) : Radius.zero,
              ),
            ),
          ),
        );
      }),
    );
  }

  String _motivationalText() {
    const texts = [
      'Completing even 1 is a win!',
      'Pick one and start small.',
      'One step at a time.',
      'Just begin \u2014 momentum follows.',
      'You\u2019ve got this.',
    ];
    // Use today's date as seed for daily rotation
    final now = DateTime.now();
    final dayIndex = (now.year * 366 + now.month * 31 + now.day) % texts.length;
    return texts[dayIndex];
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    double topPadding = 0,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: color.withAlpha(80),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildCardSubtitle(Task task, bool isDone, ColorScheme colorScheme, TextTheme textTheme) {
    final hasPath = _taskPaths.containsKey(task.id);
    final hasDeadline = _effectiveDeadlines.containsKey(task.id);
    final isScheduled = _scheduledTodayIds.contains(task.id);
    final hasIcons = task.isHighPriority || task.isSomeday || hasDeadline || isScheduled || (task.isStarted && !isDone);
    if (!hasPath && !hasIcons) return const SizedBox.shrink();

    final children = <Widget>[];
    if (hasPath) {
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _shortenPath(_taskPaths[task.id]!),
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    if (hasIcons) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (task.isHighPriority)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.flag, size: 14, color: colorScheme.error),
              ),
            if (task.isSomeday)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.bedtime, size: 14, color: Color(0xFF7EB8D8)),
              ),
            if (hasDeadline)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(deadlineIcon, size: 14,
                    color: _deadlineIconColor(
                      _effectiveDeadlines[task.id]!, colorScheme),
                ),
              ),
            if (isScheduled)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(scheduledTodayIcon, size: 14,
                    color: colorScheme.tertiary),
              ),
            if (task.isStarted && !isDone)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.play_circle_filled, size: 14,
                    color: colorScheme.tertiary),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildTaskCard(
    BuildContext context,
    Task task,
    int index,
    bool isDone,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('task_${task.id}_$isDone'),
      color: colorScheme.surfaceContainerHigh,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.onSurface.withAlpha(20),
        ),
      ),
      child: Opacity(
        opacity: isDone ? 0.38 : 1.0,
        child: ListTile(
          leading: isDone
              ? Icon(Icons.check_circle, color: const Color(0xFF66BB6A))
              : Icon(Icons.radio_button_unchecked,
                  color: colorScheme.onSurfaceVariant),
          title: Text(
            task.name,
            style: textTheme.bodyLarge?.copyWith(
              decoration: isDone ? TextDecoration.lineThrough : null,
              decorationColor: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          subtitle: _buildCardSubtitle(task, isDone, colorScheme, textTheme),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDone)
                PinButton(
                  isPinned: _pinnedIds.contains(task.id),
                  onToggle: () => _togglePinFromSheet(task),
                ),
              if (isDone && _pinnedIds.contains(task.id))
                Icon(Icons.push_pin, size: 18, color: colorScheme.tertiary),
              if (!isDone)
                IconButton(
                  icon: SizedBox(
                    width: 18,
                    height: 18,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: -1,
                          bottom: 0,
                          child: Transform.rotate(
                            angle: -0.3,
                            child: Icon(Icons.casino_outlined, size: 12,
                                color: colorScheme.onSurface.withAlpha(140)),
                          ),
                        ),
                        Positioned(
                          right: -1,
                          top: 0,
                          child: Transform.rotate(
                            angle: 0.25,
                            child: Icon(Icons.casino_outlined, size: 14,
                                color: colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                  onPressed: () => _confirmSwapTask(index),
                  tooltip: 'Spin',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              if (widget.onNavigateToTask != null && !task.isCompleted)
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: () => widget.onNavigateToTask!(task),
                  tooltip: 'Go to task',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              if (task.isCompleted)
                IconButton(
                  icon: const Icon(archiveIcon, size: 18),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CompletedTasksScreen(),
                      ),
                    );
                    if (mounted) await refreshSnapshots();
                  },
                  tooltip: 'View in archive',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
            ],
          ),
          onTap: isDone
              ? () => _handleUncomplete(task)
              : () => _handleTaskDone(task),
        ),
      ),
    );
  }

  Widget _buildOtherDoneBox(BuildContext context, TextTheme textTheme, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withAlpha(40),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final hasOverflow = _otherDoneExpanded || _chipsOverflow(context, constraints.maxWidth);
            return GestureDetector(
              onTap: hasOverflow ? () => setState(() => _otherDoneExpanded = !_otherDoneExpanded) : null,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Also done today',
                        style: textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (hasOverflow) ...[
                        const SizedBox(width: 4),
                        Icon(
                          _otherDoneExpanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildOtherDoneChips(context),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Returns true if the chips won't all fit in a single row.
  bool _chipsOverflow(BuildContext context, double maxWidth) {
    const spacing = 6.0;
    const maxChipWidth = 160.0;
    var usedWidth = 0.0;

    for (final task in _otherDoneToday) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: task.name,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final rawChipWidth = 14 + 4 + textPainter.width + 20 + 2;
      textPainter.dispose();
      final chipWidth = rawChipWidth.clamp(0.0, maxChipWidth);
      final neededWidth = usedWidth > 0 ? chipWidth + spacing : chipWidth;

      if (usedWidth + neededWidth > maxWidth) return true;
      usedWidth += neededWidth;
    }
    return false;
  }

  Widget _buildOtherDoneChips(BuildContext context) {
    if (_otherDoneExpanded) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: _otherDoneToday.map((task) =>
          _buildOtherDoneChip(context, task),
        ).toList(),
      );
    }

    // Collapsed: show chips that fit in one row
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        const spacing = 6.0;
        const maxChipWidth = 160.0;
        var usedWidth = 0.0;
        var visibleCount = 0;

        for (final task in _otherDoneToday) {
          final textPainter = TextPainter(
            text: TextSpan(
              text: task.name,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          final rawChipWidth = 14 + 4 + textPainter.width + 20 + 2;
          textPainter.dispose();
          final chipWidth = rawChipWidth.clamp(0.0, maxChipWidth);
          final neededWidth = usedWidth > 0 ? chipWidth + spacing : chipWidth;

          if (usedWidth + neededWidth <= maxWidth) {
            usedWidth += neededWidth;
            visibleCount++;
          } else {
            break;
          }
        }

        if (visibleCount == 0) visibleCount = 1;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: _otherDoneToday.take(visibleCount).map((task) =>
            _buildOtherDoneChip(context, task),
          ).toList(),
        );
      },
    );
  }

  Widget _buildOtherDoneChip(BuildContext context, Task task) {
    final doneForGood = task.isCompleted;
    final chipColor = doneForGood ? Colors.green : Colors.lightGreen;
    final icon = doneForGood ? Icons.done_all : Icons.check;

    return Tooltip(
      message: task.name,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: chipColor.withAlpha(40),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: chipColor.withAlpha(80)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: chipColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  task.name,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: chipColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
