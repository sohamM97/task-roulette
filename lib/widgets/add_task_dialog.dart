import 'package:flutter/material.dart';

/// Result from AddTaskDialog: either a single task name or a request
/// to switch to brain dump mode.
sealed class AddTaskResult {}

class SingleTask extends AddTaskResult {
  final String name;
  final bool pinInTodays5;
  SingleTask(this.name, {this.pinInTodays5 = false});
}

class SwitchToBrainDump extends AddTaskResult {}

class AddTaskDialog extends StatefulWidget {
  /// Whether to show the "Pin in Today's 5" toggle.
  final bool showPinOption;

  const AddTaskDialog({super.key, this.showPinOption = false});

  @override
  State<AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<AddTaskDialog> {
  final _controller = TextEditingController();
  bool _pin = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) {
      Navigator.pop(context, SingleTask(name, pinInTodays5: _pin));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Add Task'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: 'Task name',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, SwitchToBrainDump()),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  textStyle: Theme.of(context).textTheme.bodySmall,
                ),
                child: const Text('Add multiple'),
              ),
              if (widget.showPinOption) ...[
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _pin = !_pin),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _pin ? Icons.push_pin : Icons.push_pin_outlined,
                          size: 16,
                          color: _pin
                              ? colorScheme.tertiary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "Today's 5",
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: _pin
                                ? colorScheme.tertiary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
