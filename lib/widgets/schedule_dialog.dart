import 'package:flutter/material.dart';
import '../models/task_schedule.dart';

/// Bottom sheet for editing a task's weekly schedule (day-of-week chips).
/// Returns the new list of schedules, or null if cancelled.
class ScheduleDialog extends StatefulWidget {
  final int taskId;
  final List<TaskSchedule> currentSchedules;

  const ScheduleDialog({
    super.key,
    required this.taskId,
    required this.currentSchedules,
  });

  /// Shows the schedule bottom sheet and returns updated schedules, or null.
  static Future<List<TaskSchedule>?> show(
    BuildContext context, {
    required int taskId,
    required List<TaskSchedule> currentSchedules,
  }) {
    return showModalBottomSheet<List<TaskSchedule>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ScheduleDialog(
        taskId: taskId,
        currentSchedules: currentSchedules,
      ),
    );
  }

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  final Set<int> _selectedDays = {}; // 1=Mon..7=Sun

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    for (final s in widget.currentSchedules) {
      _selectedDays.add(s.dayOfWeek);
    }
  }

  bool get _hasChanges {
    final oldDays = widget.currentSchedules
        .map((s) => s.dayOfWeek)
        .toSet();
    return !_setsEqual(oldDays, _selectedDays);
  }

  bool _setsEqual(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  List<TaskSchedule> _buildSchedules() {
    return _selectedDays.map((day) => TaskSchedule(
      taskId: widget.taskId,
      dayOfWeek: day,
    )).toList();
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
              if (_selectedDays.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _selectedDays.clear()),
                  child: const Text('Clear all'),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Day chips
          Text('Repeat weekly',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: List.generate(7, (i) {
              final day = i + 1; // 1=Mon..7=Sun
              final selected = _selectedDays.contains(day);
              return FilterChip(
                label: Text(_dayLabels[i]),
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
            }),
          ),
          const SizedBox(height: 20),

          // Save button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _hasChanges || _selectedDays.isEmpty != widget.currentSchedules.isEmpty
                  ? () => Navigator.pop(context, _buildSchedules())
                  : null,
              child: const Text('Save'),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
