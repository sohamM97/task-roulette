import 'package:flutter/material.dart';
import '../models/task.dart';

class TaskCard extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onAddParent;
  final VoidCallback? onUnlink;
  final VoidCallback? onMove;
  final VoidCallback? onRename;
  final VoidCallback? onAddDependency;
  final bool hasStartedDescendant;
  final bool isBlocked;
  final String? blockedByName;
  final int indicatorStyle;

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
    this.hasStartedDescendant = false,
    this.isBlocked = false,
    this.blockedByName,
    this.indicatorStyle = 2,
  });

  void _showDeleteBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
        );
      },
    );
  }

  static const _cardColors = [
    Color(0xFFE8DEF8), // purple
    Color(0xFFD0E8FF), // blue
    Color(0xFFDCEDC8), // green
    Color(0xFFFFE0B2), // orange
    Color(0xFFF8BBD0), // pink
    Color(0xFFB2EBF2), // cyan
    Color(0xFFFFF9C4), // yellow
    Color(0xFFD1C4E9), // lavender
  ];

  static const _cardColorsDark = [
    Color(0xFF352E4D), // purple
    Color(0xFF2E354D), // blue
    Color(0xFF2E3E35), // sage
    Color(0xFF3E3530), // warm grey
    Color(0xFF3E2E38), // mauve
    Color(0xFF2E3E3E), // teal
    Color(0xFF38362E), // taupe
    Color(0xFF302E45), // slate
  ];

  Color _cardColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? _cardColorsDark : _cardColors;
    return colors[(task.id ?? 0) % colors.length];
  }

  String _displayUrl(String url) {
    var display = url.replaceFirst(RegExp(r'^https?://'), '');
    if (display.endsWith('/')) display = display.substring(0, display.length - 1);
    return display.length > 30 ? '${display.substring(0, 30)}...' : display;
  }

  bool get _showIndicator => task.isStarted || hasStartedDescendant;

  Color _indicatorColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);
  }

  @override
  Widget build(BuildContext context) {
    final showIndicator = _showIndicator;
    final indicatorColor = _indicatorColor(context);

    return Opacity(
      opacity: isBlocked ? 0.6 : 1.0,
      child: Card(
        color: _cardColor(context),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: () => _showDeleteBottomSheet(context),
          child: Stack(
            children: [
              // Style 1: colored left border strip
              if (showIndicator && indicatorStyle == 1)
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: indicatorColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
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
                                  _displayUrl(task.url!),
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
                    ],
                  ),
                ),
              ),
              // High priority flag in top-left corner
              if (task.isHighPriority)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Icon(
                    Icons.flag,
                    size: 16,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              // Style 0: dot in top-right corner
              if (showIndicator && indicatorStyle == 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: indicatorColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              // Style 2: play icon in top-right corner
              if (showIndicator && indicatorStyle == 2)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Icon(
                    Icons.play_circle_filled,
                    size: 18,
                    color: indicatorColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
