import 'package:flutter/material.dart';
import '../models/task_schedule.dart';

/// Result from the schedule dialog.
class ScheduleDialogResult {
  final List<TaskSchedule> schedules;
  final bool isOverride;

  const ScheduleDialogResult({required this.schedules, required this.isOverride});
}

/// A parent task that contributes schedule days via inheritance.
typedef ScheduleSource = ({int id, String name, Set<int> days});

/// Bottom sheet for editing a task's weekly schedule (day-of-week chips).
///
/// Return value semantics:
/// - `null` → cancelled (no change)
/// - `ScheduleDialogResult(isOverride: true, ...)` → save as override (may be empty)
/// - `ScheduleDialogResult(isOverride: false, ...)` → clear override, restore inheritance
class ScheduleDialog extends StatefulWidget {
  final int taskId;
  final List<TaskSchedule> currentSchedules;
  final Set<int> inheritedDays;
  final bool isCurrentlyOverriding;
  final List<ScheduleSource> sources;

  const ScheduleDialog({
    super.key,
    required this.taskId,
    required this.currentSchedules,
    this.inheritedDays = const {},
    this.isCurrentlyOverriding = false,
    this.sources = const [],
  });

  /// Shows the schedule bottom sheet and returns the result, or null.
  static Future<ScheduleDialogResult?> show(
    BuildContext context, {
    required int taskId,
    required List<TaskSchedule> currentSchedules,
    Set<int> inheritedDays = const {},
    bool isCurrentlyOverriding = false,
    List<ScheduleSource> sources = const [],
  }) {
    return showModalBottomSheet<ScheduleDialogResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ScheduleDialog(
        taskId: taskId,
        currentSchedules: currentSchedules,
        inheritedDays: inheritedDays,
        isCurrentlyOverriding: isCurrentlyOverriding,
        sources: sources,
      ),
    );
  }

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  final Set<int> _selectedDays = {}; // 1=Mon..7=Sun
  bool _isOverriding = false;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    for (final s in widget.currentSchedules) {
      _selectedDays.add(s.dayOfWeek);
    }
    // Task is overriding if it has own schedules or the override flag is set
    _isOverriding = widget.currentSchedules.isNotEmpty || widget.isCurrentlyOverriding;
  }

  bool get _isInheriting => !_isOverriding && widget.inheritedDays.isNotEmpty;

  bool get _hasChanges {
    final oldDays = widget.currentSchedules
        .map((s) => s.dayOfWeek)
        .toSet();
    if (!_setsEqual(oldDays, _selectedDays)) return true;
    // Override state only matters when there are inherited days to override
    if (widget.inheritedDays.isNotEmpty) {
      final wasOverriding = widget.isCurrentlyOverriding ||
          widget.currentSchedules.isNotEmpty;
      if (wasOverriding != _isOverriding) return true;
    }
    return false;
  }

  bool _setsEqual(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  List<TaskSchedule> _buildSchedules() {
    return _selectedDays.map((day) => TaskSchedule(
      taskId: widget.taskId,
      dayOfWeek: day,
    )).toList();
  }

  void _save() {
    Navigator.pop(context, ScheduleDialogResult(
      schedules: _buildSchedules(),
      isOverride: !_isInheriting,
    ));
  }

  void _startOverriding(int day) {
    setState(() {
      _isOverriding = true;
      // Carry over inherited days as the starting selection
      _selectedDays.addAll(widget.inheritedDays);
      // Then toggle the tapped day
      if (_selectedDays.contains(day)) {
        _selectedDays.remove(day);
      } else {
        _selectedDays.add(day);
      }
    });
  }

  void _clearOverride() {
    setState(() {
      _isOverriding = false;
      _selectedDays.clear();
    });
  }

  String _sourceLabel() {
    if (_isInheriting && widget.sources.isNotEmpty) {
      final names = widget.sources.map((s) => s.name).join(', ');
      return 'Inherited from: $names';
    }
    if (_isOverriding && widget.sources.isNotEmpty) {
      return 'Custom schedule';
    }
    return 'Repeat weekly';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20, right: 20, top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.event, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text('Schedule',
                style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_selectedDays.isNotEmpty || _isInheriting)
                TextButton(
                  onPressed: () {
                    if (_isInheriting) {
                      // Switch to override mode with no days (opt out)
                      setState(() {
                        _isOverriding = true;
                        _selectedDays.clear();
                      });
                    } else {
                      setState(() => _selectedDays.clear());
                    }
                  },
                  child: const Text('Clear all'),
                ),
              if (_isOverriding && widget.inheritedDays.isNotEmpty)
                TextButton(
                  onPressed: _clearOverride,
                  child: const Text('Clear override'),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Source label
          Text(
            _sourceLabel(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),

          // Day chips
          Wrap(
            spacing: 6,
            children: List.generate(7, (i) {
              final day = i + 1; // 1=Mon..7=Sun
              if (_isInheriting) {
                return _buildInheritedChip(day, colorScheme);
              }
              return _buildOverrideChip(day, colorScheme);
            }),
          ),

          const SizedBox(height: 20),

          // Save button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _hasChanges ? _save : null,
              child: const Text('Save'),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildInheritedChip(int day, ColorScheme colorScheme) {
    final inherited = widget.inheritedDays.contains(day);
    return FilterChip(
      label: Text(_dayLabels[day - 1]),
      selected: inherited,
      onSelected: (_) => _startOverriding(day),
      showCheckmark: false,
      selectedColor: colorScheme.surfaceContainerHighest,
      labelStyle: TextStyle(
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildOverrideChip(int day, ColorScheme colorScheme) {
    final selected = _selectedDays.contains(day);
    return FilterChip(
      label: Text(_dayLabels[day - 1]),
      selected: selected,
      onSelected: (val) => setState(() {
        if (val) {
          _selectedDays.add(day);
        } else {
          _selectedDays.remove(day);
        }
      }),
      showCheckmark: false,
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: selected
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSurfaceVariant,
      ),
    );
  }
}
