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
  /// If the task is already pinned, it gets unpinned.
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
      // Unpin
      pinnedIds.remove(taskId);
      return PinResult(taskIds: taskIds, pinnedIds: pinnedIds);
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
