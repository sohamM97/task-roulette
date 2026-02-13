import 'package:flutter/material.dart';
import '../models/task.dart';

class LeafTaskDetail extends StatelessWidget {
  final Task task;
  final List<String> parentNames;
  final VoidCallback onDone;
  final VoidCallback onAddParent;
  final VoidCallback onToggleStarted;
  final VoidCallback onRename;

  const LeafTaskDetail({
    super.key,
    required this.task,
    required this.parentNames,
    required this.onDone,
    required this.onAddParent,
    required this.onToggleStarted,
    required this.onRename,
  });

  String _formatDate(int millis) {
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final taskDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(taskDay).inDays;

    if (diff == 0) return 'Created today';
    if (diff == 1) return 'Created yesterday';
    if (diff < 7) return 'Created $diff days ago';

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Created ${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatTimeAgo(int millis) {
    final started = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(started);
    if (diff.inDays > 0) {
      return 'Started ${diff.inDays} ${diff.inDays == 1 ? 'day' : 'days'} ago';
    }
    if (diff.inHours > 0) {
      return 'Started ${diff.inHours} ${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    if (diff.inMinutes > 0) {
      return 'Started ${diff.inMinutes} ${diff.inMinutes == 1 ? 'minute' : 'minutes'} ago';
    }
    return 'Started just now';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onRename,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        task.name,
                        style: textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.edit,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _formatDate(task.createdAt),
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: onAddParent,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        parentNames.isNotEmpty
                            ? 'Listed under ${parentNames.join(', ')}'
                            : 'Top-level task',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.add_circle_outline,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            if (!task.isStarted)
              OutlinedButton.icon(
                onPressed: onToggleStarted,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start working'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: textTheme.titleMedium,
                ),
              )
            else ...[
              FilledButton.tonalIcon(
                onPressed: onToggleStarted,
                icon: const Icon(Icons.check),
                label: const Text('Started'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatTimeAgo(task.startedAt!),
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.check),
              label: const Text('Done'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Tap + to break this into subtasks',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
