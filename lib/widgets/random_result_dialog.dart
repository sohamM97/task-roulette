import 'package:flutter/material.dart';
import '../models/task.dart';

enum RandomResultAction { goDeeper, goToTask, pickAnother }

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
      actionsOverflowDirection: VerticalDirection.down,
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        Row(
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, RandomResultAction.pickAnother),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Pick Another'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (hasChildren)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, RandomResultAction.goDeeper),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Go Deeper'),
                ),
              ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, RandomResultAction.goToTask),
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Go to Task'),
            ),
          ],
        ),
      ],
    );
  }
}
