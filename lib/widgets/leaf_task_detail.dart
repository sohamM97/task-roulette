import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';
import '../utils/display_utils.dart';

class LeafTaskDetail extends StatelessWidget {
  final Task task;
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final VoidCallback onToggleStarted;
  final VoidCallback onRename;
  final void Function(String?) onUpdateUrl;
  final ValueChanged<int> onUpdatePriority;
  final ValueChanged<int> onUpdateQuickTask;
  final VoidCallback? onWorkedOn;
  final VoidCallback? onUndoWorkedOn;
  final List<Task> dependencies;
  final void Function(int)? onRemoveDependency;
  final VoidCallback? onAddDependency;
  final List<String> parentNames;
  final bool isPinnedInTodays5;
  final bool atMaxPins;
  final VoidCallback? onTogglePin;

  const LeafTaskDetail({
    super.key,
    required this.task,
    required this.onDone,
    required this.onSkip,
    required this.onToggleStarted,
    required this.onRename,
    required this.onUpdateUrl,
    required this.onUpdatePriority,
    required this.onUpdateQuickTask,
    this.onWorkedOn,
    this.onUndoWorkedOn,
    this.dependencies = const [],
    this.onRemoveDependency,
    this.onAddDependency,
    this.parentNames = const [],
    this.isPinnedInTodays5 = false,
    this.atMaxPins = false,
    this.onTogglePin,
  });

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
    if (uri == null || !isAllowedUrl(task.url!)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only web links (http/https) are supported'), showCloseIcon: true, persist: false),
        );
      }
      return;
    }
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link'), showCloseIcon: true, persist: false),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link'), showCloseIcon: true, persist: false),
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
            maxLength: 2048,
            decoration: const InputDecoration(
              hintText: 'https://...',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
            onSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isEmpty) {
                Navigator.pop(dialogContext);
                onUpdateUrl(null);
                return;
              }
              final url = normalizeUrl(trimmed);
              if (url == null || !isAllowedUrl(url)) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Only web links (http/https) are supported'), persist: false),
                );
                return;
              }
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
              final trimmed = controller.text.trim();
              if (trimmed.isEmpty) {
                Navigator.pop(dialogContext);
                onUpdateUrl(null);
                return;
              }
              final url = normalizeUrl(trimmed);
              if (url == null || !isAllowedUrl(url)) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Only web links (http/https) are supported'), persist: false),
                );
                return;
              }
              Navigator.pop(dialogContext);
              onUpdateUrl(url);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isHighPriority = task.isHighPriority;

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
            // Parent tags — shown when task has parents
            if (parentNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Under:',
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant.withAlpha(160),
                      ),
                    ),
                    ...parentNames.map((name) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: colorScheme.surfaceContainerHighest.withAlpha(160),
                    ),
                    child: Text(
                      name,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )),
                  ],
                ),
              ),
            // Task settings icons — right below title
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Pin icon — shown when onTogglePin is available
                if (onTogglePin != null)
                  PinButton(
                    isPinned: isPinnedInTodays5,
                    onToggle: onTogglePin!,
                    size: 20,
                    mutedWhenUnpinned: true,
                    atMaxPins: atMaxPins,
                  ),
                IconButton(
                  onPressed: () => onUpdatePriority(isHighPriority ? 0 : 1),
                  tooltip: isHighPriority ? 'High priority' : 'Set high priority',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    isHighPriority ? Icons.flag : Icons.flag_outlined,
                    size: 20,
                    color: isHighPriority
                        ? colorScheme.error
                        : colorScheme.onSurfaceVariant.withAlpha(120),
                  ),
                ),
                IconButton(
                  onPressed: () => onUpdateQuickTask(task.isQuickTask ? 0 : 1),
                  tooltip: task.isQuickTask ? 'Quick task' : 'Mark as quick task',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    task.isQuickTask ? Icons.bolt : Icons.bolt_outlined,
                    size: 20,
                    color: task.isQuickTask
                        ? Colors.amber
                        : colorScheme.onSurfaceVariant.withAlpha(120),
                  ),
                ),
                // Link icon — always shown
                IconButton(
                  onPressed: task.hasUrl
                      ? () => _openUrl(context)
                      : () => showEditUrlDialog(context, task.url, onUpdateUrl),
                  onLongPress: task.hasUrl
                      ? () => showEditUrlDialog(context, task.url, onUpdateUrl)
                      : null,
                  tooltip: task.hasUrl ? displayUrl(task.url!) : 'Add link',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    task.hasUrl ? Icons.link : Icons.add_link,
                    size: 20,
                    color: task.hasUrl
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant.withAlpha(120),
                  ),
                ),
                // Dependency icon — shown when callback available
                if (onAddDependency != null || dependencies.isNotEmpty)
                  IconButton(
                    onPressed: dependencies.isNotEmpty
                        ? () {
                            final dep = dependencies.first;
                            if (onRemoveDependency != null) {
                              onRemoveDependency!(dep.id!);
                            }
                          }
                        : onAddDependency,
                    tooltip: dependencies.isNotEmpty
                        ? 'After: ${dependencies.first.name}'
                        : 'Do after...',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      dependencies.isNotEmpty
                          ? Icons.hourglass_top
                          : Icons.add_task,
                      size: 20,
                      color: dependencies.isNotEmpty
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withAlpha(120),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // "Done today" — toggle: mark / undo
            if (task.isWorkedOnToday)
              OutlinedButton.icon(
                onPressed: onUndoWorkedOn,
                icon: const Icon(Icons.undo),
                label: const Text('Worked on today'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  textStyle: textTheme.titleMedium,
                  side: BorderSide(color: colorScheme.primary),
                ),
              )
            else
              FilledButton.icon(
                onPressed: onWorkedOn ?? onDone,
                icon: const Icon(Icons.today),
                label: const Text('Done today'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  textStyle: textTheme.titleMedium,
                ),
              ),
            const SizedBox(height: 8),
            // "Done for good!" — permanently complete
            OutlinedButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Done for good!'),
            ),
            const SizedBox(height: 16),
            // Secondary row: Start | Skip
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: onToggleStarted,
                  icon: Icon(
                    task.isStarted ? Icons.check : Icons.play_arrow,
                    size: 18,
                  ),
                  label: Text(
                    task.isStarted
                        ? 'Started ${_formatTimeAgo(task.startedAt!)}'
                        : 'Start',
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: task.isStarted
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    textStyle: textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 16),
                TextButton.icon(
                  onPressed: onSkip,
                  icon: const Icon(Icons.not_interested, size: 18),
                  label: const Text('Skip'),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.onSurfaceVariant,
                    textStyle: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
