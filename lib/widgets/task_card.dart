import 'package:flutter/material.dart';
import '../models/task.dart';

class TaskCard extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onAddParent;
  final VoidCallback? onUnlink;

  const TaskCard({
    super.key,
    required this.task,
    required this.onTap,
    required this.onDelete,
    this.onAddParent,
    this.onUnlink,
  });

  void _showDeleteBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onAddParent != null)
                ListTile(
                  leading: const Icon(Icons.account_tree),
                  title: const Text('Also show under...'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    onAddParent!();
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
                  _confirmDelete(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Task'),
        content: Text('Delete "${task.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              onDelete();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
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
