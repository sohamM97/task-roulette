import 'package:flutter/material.dart';

enum DeleteChoice { reparent, deleteAll }

class DeleteTaskDialog extends StatelessWidget {
  final String taskName;

  const DeleteTaskDialog({super.key, required this.taskName});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Delete "$taskName"?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('This task has sub-tasks. What should happen to them?'),
          const SizedBox(height: 20),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green.withAlpha(40),
              foregroundColor: Colors.green,
            ),
            onPressed: () => Navigator.pop(context, DeleteChoice.reparent),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Text('Keep sub-tasks',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                  const SizedBox(height: 2),
                  Text("They'll be moved to where this task is listed",
                      style: TextStyle(fontSize: 12, color: Colors.green)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.error,
              side: BorderSide(color: colorScheme.error),
            ),
            onPressed: () => Navigator.pop(context, DeleteChoice.deleteAll),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: colorScheme.error),
                      const SizedBox(width: 4),
                      Text('Delete everything',
                          style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.error)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('Permanently delete this task and all sub-tasks',
                      style: TextStyle(fontSize: 12, color: colorScheme.error)),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
