import 'package:flutter/material.dart';
import '../models/task.dart';
import '../theme/app_colors.dart';
import '../utils/display_utils.dart';

class TaskCard extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onAddParent;
  final VoidCallback? onUnlink;
  final VoidCallback? onMove;
  final VoidCallback? onRename;
  final VoidCallback? onAddDependency;
  final VoidCallback? onSchedule;
  final VoidCallback? onStopWorking;
  final VoidCallback? onFile;
  final bool isBlocked;
  final String? blockedByName;
  final bool isInTodaysFive;
  final bool isPinnedInTodaysFive;
  final List<String> parentNames;
  /// Effective deadline info (own or inherited from ancestor). Used for icon display.
  final ({String deadline, String type})? effectiveDeadline;
  final VoidCallback? onToggleStar;
  final bool isStarred;
  final bool isScheduledToday;

  const TaskCard({
    super.key,
    required this.task,
    required this.onTap,
    required this.onDelete,
    this.onAddParent,
    this.onUnlink,
    this.onMove,
    this.onRename,
    this.onAddDependency,
    this.onSchedule,
    this.onStopWorking,
    this.onFile,
    this.isBlocked = false,
    this.blockedByName,
    this.isInTodaysFive = false,
    this.isPinnedInTodaysFive = false,
    this.parentNames = const [],
    this.effectiveDeadline,
    this.onToggleStar,
    this.isStarred = false,
    this.isScheduledToday = false,
  });

  void _showDeleteBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (bottomSheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onFile != null)
                ListTile(
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: const Text('File under...'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onFile!();
                  },
                ),
              if (onRename != null)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Rename'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onRename!();
                  },
                ),
              if (onAddParent != null)
                ListTile(
                  leading: const Icon(Icons.account_tree),
                  title: const Text('Also show under...'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onAddParent!();
                  },
                ),
              if (onAddDependency != null)
                ListTile(
                  leading: const Icon(Icons.hourglass_top),
                  title: const Text('Do after...'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onAddDependency!();
                  },
                ),
              if (onSchedule != null)
                ListTile(
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Schedule'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onSchedule!();
                  },
                ),
              if (onMove != null)
                ListTile(
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: const Text('Move to...'),
                  subtitle: const Text('Move from here to another list'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onMove!();
                  },
                ),
              if (onUnlink != null)
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Remove from here'),
                  subtitle: const Text('Keeps the task, just unlinks it from this list'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onUnlink!();
                  },
                ),
              if (onStopWorking != null)
                ListTile(
                  leading: Icon(Icons.stop_circle_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  title: const Text('Stop working'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onStopWorking!();
                  },
                ),
              if (onToggleStar != null)
                ListTile(
                  leading: Icon(
                    isStarred ? Icons.star : Icons.star_outline,
                    color: isStarred ? AppColors.starGold : null,
                  ),
                  title: Text(isStarred ? 'Unstar' : 'Star'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onToggleStar!();
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete "${task.name}"',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(bottomSheetContext);
                  onDelete();
                },
              ),
            ],
          ),
          ),
        );
      },
    );
  }

  Color _cardColor(BuildContext context) {
    return AppColors.cardColor(context, task.id ?? 0);
  }


  bool get _showIndicator => task.isStarted;

  bool get _hasEffectiveDeadline =>
      task.hasDeadline || effectiveDeadline != null;

  Color? _deadlineColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (task.hasDeadline) {
      return deadlineDisplayColor(task.deadline!, task.deadlineType, colorScheme);
    }
    if (effectiveDeadline == null) return null;
    return deadlineDisplayColor(
        effectiveDeadline!.deadline, effectiveDeadline!.type, colorScheme);
  }

  Color _indicatorColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);
  }

  @override
  Widget build(BuildContext context) {
    final showIndicator = _showIndicator;
    final indicatorColor = _indicatorColor(context);

    return Opacity(
      opacity: isBlocked ? 0.6 : task.isWorkedOnToday ? 0.5 : 1.0,
      child: Card(
        color: _cardColor(context),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: () => _showDeleteBottomSheet(context),
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        task.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (task.hasUrl)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.link, size: 12, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  displayUrl(task.url!, maxLength: 30),
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.primary,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isBlocked && blockedByName != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.hourglass_top, size: 12,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  'After: $blockedByName',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (parentNames.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Also under:',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontSize: 10,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(160),
                                ),
                              ),
                              ...parentNames.map((name) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(160),
                              ),
                              child: Text(
                                name,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontSize: 10,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Top-left icons: today's 5, in-progress, priority flag, worked-on-today, someday, deadline, starred
              if (task.isHighPriority || task.isSomeday || showIndicator || task.isWorkedOnToday || isInTodaysFive || _hasEffectiveDeadline || isScheduledToday || isStarred)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isInTodaysFive)
                        Icon(
                          isPinnedInTodaysFive ? Icons.push_pin : Icons.local_fire_department,
                          size: 16,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      if (task.isWorkedOnToday)
                        Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      if (showIndicator)
                        Icon(
                          Icons.play_circle_filled,
                          size: 18,
                          color: indicatorColor,
                        ),
                      if (task.isHighPriority)
                        Icon(
                          Icons.flag,
                          size: 16,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      if (task.isSomeday)
                        const Icon(
                          Icons.bedtime,
                          size: 16,
                          color: Color(0xFF7EB8D8), // soft sky blue
                        ),
                      if (_hasEffectiveDeadline)
                        Icon(
                          deadlineIcon,
                          size: 16,
                          color: _deadlineColor(context),
                        ),
                      if (isScheduledToday)
                        Icon(
                          scheduledTodayIcon,
                          size: 16,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      if (isStarred)
                        const Icon(
                          Icons.star,
                          size: 16,
                          color: AppColors.starGold,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
