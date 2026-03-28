import 'package:flutter/material.dart';
import '../models/task.dart';
import '../utils/display_utils.dart';

enum RandomResultAction { goDeeper, goToTask, pickAnother }

class RandomResultDialog extends StatelessWidget {
  final Task task;
  final bool hasChildren;
  final bool canPickAnother;

  const RandomResultDialog({
    super.key,
    required this.task,
    required this.hasChildren,
    this.canPickAnother = true,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Lucky Pick'),
      content: Text(
        task.name,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        Row(
          children: [
            if (canPickAnother)
              IconButton(
                onPressed: () => Navigator.pop(context, RandomResultAction.pickAnother),
                icon: const Icon(spinIcon),
                tooltip: 'Spin Again',
              ),
            if (hasChildren)
              IconButton(
                onPressed: () => Navigator.pop(context, RandomResultAction.goDeeper),
                icon: const Icon(Icons.keyboard_double_arrow_down),
                tooltip: 'Go Deeper',
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, RandomResultAction.goToTask),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Go to Task'),
            ),
          ],
        ),
      ],
    );
  }
}
