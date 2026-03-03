import 'package:flutter/material.dart';
import '../models/task_schedule.dart';

/// Bottom sheet for editing a task's schedule (weekly days + one-off dates).
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
  final List<String> _oneOffDates = []; // 'YYYY-MM-DD'

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    for (final s in widget.currentSchedules) {
      if (s.isWeekly && s.dayOfWeek != null) {
        _selectedDays.add(s.dayOfWeek!);
      } else if (s.isOneOff && s.specificDate != null) {
        _oneOffDates.add(s.specificDate!);
      }
    }
  }

  bool get _hasChanges {
    final oldDays = widget.currentSchedules
        .where((s) => s.isWeekly && s.dayOfWeek != null)
        .map((s) => s.dayOfWeek!)
        .toSet();
    final oldDates = widget.currentSchedules
        .where((s) => s.isOneOff && s.specificDate != null)
        .map((s) => s.specificDate!)
        .toList()..sort();
    final newDates = List<String>.from(_oneOffDates)..sort();
    return !_setsEqual(oldDays, _selectedDays) ||
        !_listsEqual(oldDates, newDates);
  }

  bool _setsEqual(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<TaskSchedule> _buildSchedules() {
    final schedules = <TaskSchedule>[];
    for (final day in _selectedDays) {
      schedules.add(TaskSchedule(
        taskId: widget.taskId,
        scheduleType: 'weekly',
        dayOfWeek: day,
      ));
    }
    for (final date in _oneOffDates) {
      schedules.add(TaskSchedule(
        taskId: widget.taskId,
        scheduleType: 'oneoff',
        specificDate: date,
      ));
    }
    return schedules;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      final dateStr = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      if (!_oneOffDates.contains(dateStr)) {
        setState(() => _oneOffDates.add(dateStr));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEmpty = _selectedDays.isEmpty && _oneOffDates.isEmpty;

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
              if (!isEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    _selectedDays.clear();
                    _oneOffDates.clear();
                  }),
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
          const SizedBox(height: 16),

          // One-off dates
          Row(
            children: [
              Text('Specific dates',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant)),
              const Spacer(),
              TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add date'),
              ),
            ],
          ),
          if (_oneOffDates.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _oneOffDates.map((date) {
                final parsed = DateTime.parse(date);
                final label = '${parsed.day}/${parsed.month}/${parsed.year}';
                return Chip(
                  label: Text(label),
                  onDeleted: () => setState(() => _oneOffDates.remove(date)),
                  deleteIconColor: colorScheme.error,
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 20),

          // Save button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _hasChanges || isEmpty != (widget.currentSchedules.isEmpty)
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
