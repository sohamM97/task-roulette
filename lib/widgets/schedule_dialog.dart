import 'package:flutter/material.dart';
import '../models/task_schedule.dart';
import '../utils/display_utils.dart';

/// Result from the schedule dialog.
class ScheduleDialogResult {
  final List<TaskSchedule> schedules;
  final bool isOverride;
  /// Updated deadline (null = no change, empty string = cleared).
  final String? deadline;
  final String? deadlineType;

  const ScheduleDialogResult({
    required this.schedules,
    required this.isOverride,
    this.deadline,
    this.deadlineType,
  });
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
  final String? currentDeadline;
  final String currentDeadlineType;
  /// Inherited deadline from an ancestor (read-only display).
  final ({String deadline, String deadlineType, String sourceName})? inheritedDeadline;

  const ScheduleDialog({
    super.key,
    required this.taskId,
    required this.currentSchedules,
    this.inheritedDays = const {},
    this.isCurrentlyOverriding = false,
    this.sources = const [],
    this.currentDeadline,
    this.currentDeadlineType = 'due_by',
    this.inheritedDeadline,
  });

  /// Shows the schedule bottom sheet and returns the result, or null.
  static Future<ScheduleDialogResult?> show(
    BuildContext context, {
    required int taskId,
    required List<TaskSchedule> currentSchedules,
    Set<int> inheritedDays = const {},
    bool isCurrentlyOverriding = false,
    List<ScheduleSource> sources = const [],
    String? currentDeadline,
    String currentDeadlineType = 'due_by',
    ({String deadline, String deadlineType, String sourceName})? inheritedDeadline,
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
        currentDeadline: currentDeadline,
        currentDeadlineType: currentDeadlineType,
        inheritedDeadline: inheritedDeadline,
      ),
    );
  }

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  final Set<int> _selectedDays = {}; // 1=Mon..7=Sun
  bool _isOverriding = false;
  String? _deadline; // YYYY-MM-DD or null
  String _deadlineType = 'due_by'; // 'due_by' or 'on'

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    for (final s in widget.currentSchedules) {
      _selectedDays.add(s.dayOfWeek);
    }
    // Task is overriding if it has own schedules or the override flag is set
    _isOverriding = widget.currentSchedules.isNotEmpty || widget.isCurrentlyOverriding;
    _deadline = widget.currentDeadline;
    _deadlineType = widget.currentDeadlineType;
  }

  bool get _isInheriting => !_isOverriding && widget.inheritedDays.isNotEmpty;

  bool get _hasChanges {
    if (_deadline != widget.currentDeadline) return true;
    if (_deadlineType != widget.currentDeadlineType && _deadline != null) return true;
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

  bool get _deadlineChanged => _deadline != widget.currentDeadline;

  void _save() {
    Navigator.pop(context, ScheduleDialogResult(
      schedules: _buildSchedules(),
      isOverride: !_isInheriting,
      // Use empty string as sentinel for "cleared"; null = no change
      deadline: _deadlineChanged ? (_deadline ?? '') : null,
      deadlineType: _deadlineType != widget.currentDeadlineType ? _deadlineType : null,
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

          // Deadline section
          _buildDeadlineSection(colorScheme),

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

  Color _deadlineColor(ColorScheme colorScheme) {
    if (_deadline == null) return colorScheme.onSurfaceVariant;
    final parsed = DateTime.tryParse(_deadline!);
    if (parsed == null) return colorScheme.onSurfaceVariant;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(parsed.year, parsed.month, parsed.day)
        .difference(today)
        .inDays;
    return deadlineProximityColor(days, colorScheme);
  }

  static String _formatDeadline(String deadlineStr) {
    final parsed = DateTime.tryParse(deadlineStr);
    if (parsed == null) return deadlineStr;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                     'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[parsed.month - 1]} ${parsed.day}, ${parsed.year}';
  }

  Widget _buildDeadlineSection(ColorScheme colorScheme) {
    final hasOwnDeadline = _deadline != null && _deadline!.isNotEmpty;
    final inherited = widget.inheritedDeadline;
    final hasInherited = !hasOwnDeadline && inherited != null;

    // Show inherited deadline as read-only
    if (hasInherited) {
      final isOn = inherited.deadlineType == 'on';
      final inheritedColor = isOn
          ? colorScheme.primary
          : _deadlineColorFor(inherited.deadline, colorScheme);
      final inheritedLabel = isOn ? 'On' : 'Due by';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_available, color: inheritedColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$inheritedLabel: ${_formatDeadline(inherited.deadline)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: inheritedColor,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(
                'Inherited from: ${inherited.sourceName}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Own deadline (editable)
    final color = _deadlineType == 'on'
        ? colorScheme.primary
        : _deadlineColor(colorScheme);
    final typeLabel = _deadlineType == 'on' ? 'On' : 'Due by';
    final label = hasOwnDeadline
        ? '$typeLabel: ${_formatDeadline(_deadline!)}'
        : 'Set deadline';

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final now = DateTime.now();
        final initial = hasOwnDeadline
            ? (DateTime.tryParse(_deadline!) ?? now)
            : now;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial.isBefore(now) ? now : initial,
          firstDate: now,
          lastDate: now.add(const Duration(days: 730)),
          initialEntryMode: DatePickerEntryMode.calendarOnly,
        );
        if (picked != null) {
          setState(() {
            _deadline = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
          });
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.event_available, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                ),
              ),
            ),
            if (hasOwnDeadline)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  _deadlineType = _deadlineType == 'due_by' ? 'on' : 'due_by';
                }),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: colorScheme.primaryContainer,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.swap_horiz, size: 14,
                        color: colorScheme.onPrimaryContainer),
                      const SizedBox(width: 4),
                      Text(
                        _deadlineType == 'on' ? 'On' : 'Due by',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasOwnDeadline)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _deadline = null),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Icon(Icons.close, size: 18,
                    color: colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _deadlineColorFor(String deadlineStr, ColorScheme colorScheme) {
    final parsed = DateTime.tryParse(deadlineStr);
    if (parsed == null) return colorScheme.onSurfaceVariant;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(parsed.year, parsed.month, parsed.day)
        .difference(today)
        .inDays;
    return deadlineProximityColor(days, colorScheme);
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
