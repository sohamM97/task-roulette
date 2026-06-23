import 'database_helper.dart';

/// Max number of pinned tasks allowed in Today's 5.
const int maxPins = 5;

/// Max total slots in Today's 5 (original 5 + up to 5 appended).
const int maxSlots = 10;

/// Result of a pin operation. Contains the mutated lists to persist.
class PinResult {
  final List<int> taskIds;
  final Set<int> pinnedIds;

  const PinResult({required this.taskIds, required this.pinnedIds});
}

/// Pure business logic for Today's 5 pin operations.
///
/// All methods are static and side-effect-free — they compute the new state
/// from the current [TodaysFiveData] without touching the DB or UI.
/// Callers are responsible for persisting and updating widget state.
class TodaysFivePinHelper {
  TodaysFivePinHelper._();

  /// Toggle pin status for [taskId].
  ///
  /// If the task is already pinned, it gets unpinned AND removed from
  /// Today's 5 (manual model: pin = membership). Completed tasks stay in
  /// the list when unpinned so progress isn't lost.
  /// If unpinned and not yet in Today's 5, it replaces the last unpinned
  /// undone slot, or gets appended if all slots are done/pinned (up to
  /// [maxSlots]).
  ///
  /// Returns a [PinResult] with the mutated state, or `null` if the
  /// operation was blocked (max pins reached, or max slots reached with
  /// no replaceable slot).
  static PinResult? togglePin(TodaysFiveData saved, int taskId) {
    final taskIds = List<int>.from(saved.taskIds);
    final pinnedIds = Set<int>.from(saved.pinnedIds);

    if (pinnedIds.contains(taskId)) {
      pinnedIds.remove(taskId);
      // Remove from list unless completed (keep done tasks visible for progress).
      if (!saved.completedIds.contains(taskId)) {
        taskIds.remove(taskId);
      }
      final trimmed = trimExcess(taskIds, saved.completedIds, pinnedIds);
      return PinResult(taskIds: trimmed, pinnedIds: pinnedIds);
    }

    // Pin — enforce max pins
    if (pinnedIds.length >= maxPins) return null;

    pinnedIds.add(taskId);

    // If task isn't already in Today's 5, add it
    if (!taskIds.contains(taskId)) {
      final index = _findReplaceableSlot(
        taskIds, saved.completedIds, pinnedIds,
      );
      if (index != null) {
        taskIds[index] = taskId;
      } else if (taskIds.length < maxSlots) {
        taskIds.add(taskId);
      } else {
        // Can't fit — roll back
        pinnedIds.remove(taskId);
        return null;
      }
    }

    return PinResult(taskIds: taskIds, pinnedIds: pinnedIds);
  }

  /// Pin a newly created task into Today's 5.
  ///
  /// Always pins the task (never toggles). Replaces the last unpinned
  /// undone slot, or appends (up to [maxSlots]).
  ///
  /// Returns a [PinResult], or `null` if blocked (max pins or max slots
  /// with no replaceable slot).
  static PinResult? pinNewTask(TodaysFiveData saved, int taskId) {
    final taskIds = List<int>.from(saved.taskIds);
    final pinnedIds = Set<int>.from(saved.pinnedIds);

    if (pinnedIds.length >= maxPins) return null;

    final index = _findReplaceableSlot(
      taskIds, saved.completedIds, pinnedIds,
    );
    if (index != null) {
      taskIds[index] = taskId;
    } else if (taskIds.length < maxSlots) {
      taskIds.add(taskId);
    } else {
      return null;
    }

    pinnedIds.add(taskId);
    return PinResult(taskIds: taskIds, pinnedIds: pinnedIds);
  }

  // Pin auto-transfer was removed with the manual Today's 5 model: adding a
  // subtask to a pinned task now just drops the (now non-leaf) parent instead
  // of moving its pin to a child. transferPin is no longer wired into any flow
  // — kept commented out (with its tests) rather than deleted so it's trivial
  // to restore if transfer-on-subtask is ever reintroduced.
  /*
  /// Transfers a parent's Today's 5 slot to a newly-created child.
  ///
  /// When a pinned (or merely present) parent gains its first subtask it
  /// becomes non-leaf, so its slot should follow the work down to the child:
  /// the parent's entry is replaced by [childId] in-place, and if the parent
  /// was pinned the pin moves to the child too.
  ///
  /// Returns a [PinResult] with the mutated state, or `null` if the parent
  /// isn't in Today's 5 (nothing to transfer).
  static PinResult? transferPin(TodaysFiveData saved, int parentId, int childId) {
    final taskIds = List<int>.from(saved.taskIds);
    final pinnedIds = Set<int>.from(saved.pinnedIds);

    final index = taskIds.indexOf(parentId);
    if (index < 0) return null;

    taskIds[index] = childId;
    if (pinnedIds.remove(parentId)) {
      pinnedIds.add(childId);
    }
    return PinResult(taskIds: taskIds, pinnedIds: pinnedIds);
  }
  */

  // Commented out (with its tests) like transferPin above: the manual model
  // replaced the Today's 5 bottom-sheet pin/unpin tile with the Remove flow,
  // removing all callers of togglePinInPlace. Kept rather than deleted so it's
  // easy to restore if an in-place pin/unpin toggle is reintroduced.
  /*
  /// Simple pin/unpin for a task that is already in Today's 5.
  ///
  /// Returns the new pinnedIds set, or `null` if blocked (max pins).
  static Set<int>? togglePinInPlace(Set<int> currentPins, int taskId) {
    final pinnedIds = Set<int>.from(currentPins);
    if (pinnedIds.contains(taskId)) {
      pinnedIds.remove(taskId);
      return pinnedIds;
    }
    if (pinnedIds.length >= maxPins) return null;
    pinnedIds.add(taskId);
    return pinnedIds;
  }
  */

  /// Removes unpinned undone tasks from the end of the list until the list
  /// has at most 5 items (or only pinned/completed tasks remain).
  ///
  /// Call this after any mutation that might leave excess tasks (e.g.
  /// uncompleting a task, refreshing snapshots).
  ///
  /// Returns the trimmed list, or the original if no trimming was needed.
  static List<int> trimExcess(
    List<int> taskIds,
    Set<int> completedIds,
    Set<int> pinnedIds,
  ) {
    if (taskIds.length <= 5) return taskIds;
    final result = List<int>.from(taskIds);
    // Remove from the end first — those are the most recently appended
    for (int i = result.length - 1; i >= 0 && result.length > 5; i--) {
      final id = result[i];
      if (!completedIds.contains(id) && !pinnedIds.contains(id)) {
        result.removeAt(i);
      }
    }
    return result;
  }

  /// Find the last unpinned, undone slot index (searching from end).
  /// Returns `null` if no such slot exists.
  static int? _findReplaceableSlot(
    List<int> taskIds,
    Set<int> completedIds,
    Set<int> pinnedIds,
  ) {
    for (int i = taskIds.length - 1; i >= 0; i--) {
      final id = taskIds[i];
      if (!completedIds.contains(id) && !pinnedIds.contains(id)) {
        return i;
      }
    }
    return null;
  }
}
