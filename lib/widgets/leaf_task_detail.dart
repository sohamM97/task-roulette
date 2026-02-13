import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';

class LeafTaskDetail extends StatelessWidget {
  final Task task;
  final List<String> parentNames;
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final VoidCallback onAddParent;
  final VoidCallback onToggleStarted;
  final VoidCallback onRename;
  final void Function(String?) onUpdateUrl;
  final ValueChanged<int> onUpdatePriority;
  final ValueChanged<int> onUpdateDifficulty;

  const LeafTaskDetail({
    super.key,
    required this.task,
    required this.parentNames,
    required this.onDone,
    required this.onSkip,
    required this.onAddParent,
    required this.onToggleStarted,
    required this.onRename,
    required this.onUpdateUrl,
    required this.onUpdatePriority,
    required this.onUpdateDifficulty,
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

  Future<void> _openUrl(BuildContext context) async {
    final uri = Uri.tryParse(task.url!);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  void _editUrl(BuildContext context) {
    final controller = TextEditingController(text: task.url ?? '');
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Link'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
          onSubmitted: (value) {
            final url = value.trim().isEmpty ? null : value.trim();
            Navigator.pop(dialogContext);
            onUpdateUrl(url);
          },
        ),
        actions: [
          if (task.hasUrl)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                onUpdateUrl(null);
              },
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final url = controller.text.trim().isEmpty
                  ? null
                  : controller.text.trim();
              Navigator.pop(dialogContext);
              onUpdateUrl(url);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlSection(
      BuildContext context, ColorScheme colorScheme, TextTheme textTheme) {
    if (task.hasUrl) {
      return InkWell(
        onTap: () => _openUrl(context),
        onLongPress: () => _editUrl(context),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link, size: 18, color: colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _displayUrl(task.url!),
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: colorScheme.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return InkWell(
      onTap: () => _editUrl(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_link, size: 18, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'Add link',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _displayUrl(String url) {
    var display = url.replaceFirst(RegExp(r'^https?://'), '');
    if (display.endsWith('/')) display = display.substring(0, display.length - 1);
    return display.length > 40 ? '${display.substring(0, 40)}...' : display;
  }

  Widget _buildSegmentedRow(
    BuildContext context, {
    required String label,
    required List<String> labels,
    required int selected,
    required ValueChanged<int> onChanged,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SegmentedButton<int>(
          segments: [
            for (int i = 0; i < labels.length; i++)
              ButtonSegment(value: i, label: Text(labels[i])),
          ],
          selected: {selected},
          onSelectionChanged: (values) => onChanged(values.first),
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStatePropertyAll(textTheme.bodySmall),
          ),
        ),
      ],
    );
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
            const SizedBox(height: 12),
            _buildUrlSection(context, colorScheme, textTheme),
            const SizedBox(height: 20),
            _buildSegmentedRow(
              context,
              label: 'Priority',
              labels: Task.priorityLabels,
              selected: task.priority,
              onChanged: onUpdatePriority,
            ),
            const SizedBox(height: 12),
            _buildSegmentedRow(
              context,
              label: 'Difficulty',
              labels: Task.difficultyLabels,
              selected: task.difficulty,
              onChanged: onUpdateDifficulty,
            ),
            const SizedBox(height: 24),
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: onSkip,
                  icon: const Icon(Icons.not_interested),
                  label: const Text('Skip'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    textStyle: textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onDone,
                  icon: const Icon(Icons.check),
                  label: const Text('Done'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    textStyle: textTheme.titleMedium,
                  ),
                ),
              ],
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
