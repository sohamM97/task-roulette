import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';

class LeafTaskDetail extends StatelessWidget {
  final Task task;
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final VoidCallback onToggleStarted;
  final VoidCallback onRename;
  final void Function(String?) onUpdateUrl;
  final List<Task> dependencies;
  final void Function(int)? onRemoveDependency;
  final VoidCallback? onAddDependency;

  const LeafTaskDetail({
    super.key,
    required this.task,
    required this.onDone,
    required this.onSkip,
    required this.onToggleStarted,
    required this.onRename,
    required this.onUpdateUrl,
    this.dependencies = const [],
    this.onRemoveDependency,
    this.onAddDependency,
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
            // URL row — only if URL exists
            _buildUrlRow(context, colorScheme, textTheme),
            if (task.hasUrl) const SizedBox(height: 12),
            // Dependency chips
            if (dependencies.isNotEmpty || onAddDependency != null)
              _buildDependencyChips(context, colorScheme),
            if (dependencies.isNotEmpty || onAddDependency != null)
              const SizedBox(height: 12),
            // Start chip in a Wrap (future chips slot in here)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                if (!task.isStarted)
                  ActionChip(
                    avatar: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start working'),
                    onPressed: onToggleStarted,
                  )
                else
                  ActionChip(
                    avatar: const Icon(Icons.check, size: 18),
                    label: Text('Started ${_formatTimeAgo(task.startedAt!)}'),
                    onPressed: onToggleStarted,
                    backgroundColor: colorScheme.secondaryContainer,
                  ),
              ],
            ),
            const SizedBox(height: 20),
            // Done button — primary, moderately prominent
            FilledButton.icon(
              onPressed: onDone,
              icon: const Icon(Icons.check),
              label: const Text('Done'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                textStyle: textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            // Skip — de-emphasized
            TextButton(
              onPressed: onSkip,
              style: TextButton.styleFrom(
                textStyle: textTheme.bodyMedium,
              ),
              child: const Text('Skip'),
            ),
          ],
        ),
      ),
    );
  }
}
