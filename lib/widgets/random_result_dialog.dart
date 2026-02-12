import 'package:flutter/material.dart';
import '../models/task.dart';

enum RandomResultAction { goDeeper, goToTask }

class RandomResultDialog extends StatelessWidget {
  final Task task;
  final bool hasChildren;

  const RandomResultDialog({
    super.key,
    required this.task,
    required this.hasChildren,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Random Pick'),
      content: Text(
        task.name,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (hasChildren)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, RandomResultAction.goDeeper),
            icon: const Icon(Icons.shuffle),
            label: const Text('Go Deeper'),
          ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, RandomResultAction.goToTask),
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Go to Task'),
        ),
      ],
    );
  }
}
