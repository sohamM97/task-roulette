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

  const TaskCard({
    super.key,
    required this.task,
    required this.onTap,
    required this.onDelete,
    this.onAddParent,
    this.onUnlink,
    this.onMove,
    this.onRename,
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

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _cardColor(context),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: () => _showDeleteBottomSheet(context),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              task.name,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
