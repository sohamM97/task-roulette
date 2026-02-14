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
  final List<Task> dependencies;
  final void Function(int)? onRemoveDependency;
  final VoidCallback? onAddDependency;

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
    this.dependencies = const [],
    this.onRemoveDependency,
    this.onAddDependency,
  });

  String _formatDate(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String _formatTimeAgo(int millis) {
    final started = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(started);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  Future<void> _openUrl(BuildContext context) async {
    final uri = Uri.tryParse(task.url!);
    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
      return;
    }
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }

  static void showEditUrlDialog(
    BuildContext context,
    String? currentUrl,
    void Function(String?) onUpdateUrl,
  ) {
    final controller = TextEditingController(text: currentUrl ?? '');
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Link'),
        content: GestureDetector(
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 0 && controller.text.isEmpty) {
              controller.text = 'https://';
              controller.selection = TextSelection.fromPosition(
                TextPosition(offset: controller.text.length),
              );
            }
          },
          child: TextField(
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
        ),
        actions: [
          if (currentUrl != null && currentUrl.isNotEmpty)
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

  Widget _buildUrlRow(
      BuildContext context, ColorScheme colorScheme, TextTheme textTheme) {
    if (!task.hasUrl) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _openUrl(context),
      onLongPress: () => showEditUrlDialog(context, task.url, onUpdateUrl),
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
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => showEditUrlDialog(context, task.url, onUpdateUrl),
              child: Icon(
                Icons.edit_outlined,
                size: 14,
                color: colorScheme.onSurfaceVariant.withAlpha(180),
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

  Widget _buildDependencyChips(BuildContext context, ColorScheme colorScheme) {
    final dep = dependencies.isNotEmpty ? dependencies.first : null;
    if (dep != null) {
      // Show current dependency with X to remove
      return InputChip(
        avatar: Icon(
          dep.isCompleted || dep.isSkipped
              ? Icons.check
              : Icons.hourglass_top,
          size: 16,
        ),
        label: Text(
          'After: ${dep.name}',
          style: TextStyle(
            color: dep.isCompleted || dep.isSkipped
                ? colorScheme.onSurfaceVariant.withAlpha(150)
                : null,
          ),
        ),
        onDeleted: onRemoveDependency != null
            ? () => onRemoveDependency!(dep.id!)
            : null,
      );
    }
    return const SizedBox.shrink();
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
            // Task name with pencil icon — tappable to rename
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
                    const SizedBox(width: 5),
                    Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: colorScheme.onSurfaceVariant.withAlpha(180),
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
            _buildUrlRow(context, colorScheme, textTheme),
            // Dependency chips
            if (dependencies.isNotEmpty || onAddDependency != null)
              const SizedBox(height: 8),
            if (dependencies.isNotEmpty || onAddDependency != null)
              _buildDependencyChips(context, colorScheme),
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
                  icon: const Icon(Icons.skip_next),
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
