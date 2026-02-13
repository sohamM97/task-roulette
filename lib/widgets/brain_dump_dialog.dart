import 'package:flutter/material.dart';

/// Dialog for rapid multi-task entry. Each line becomes a separate task.
/// Returns a list of task names (non-empty, trimmed).
class BrainDumpDialog extends StatefulWidget {
  const BrainDumpDialog({super.key});

  @override
  State<BrainDumpDialog> createState() => _BrainDumpDialogState();
}

class _BrainDumpDialogState extends State<BrainDumpDialog> {
  final _controller = TextEditingController();
  int _lineCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateLineCount);
  }

  void _updateLineCount() {
    final count = _parseNames().length;
    if (count != _lineCount) {
      setState(() => _lineCount = count);
    }
  }

  List<String> _parseNames() {
    return _controller.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  void _submit() {
    final names = _parseNames();
    if (names.isNotEmpty) {
      Navigator.pop(context, names);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Brain dump'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'One task per line',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              maxLines: 8,
              minLines: 4,
              autofocus: true,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Buy groceries\nCall dentist\nFinish report\n...',
                border: OutlineInputBorder(),
              ),
            ),
            if (_lineCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$_lineCount ${_lineCount == 1 ? 'task' : 'tasks'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _lineCount > 0 ? _submit : null,
          child: Text(_lineCount > 0 ? 'Add $_lineCount' : 'Add'),
        ),
      ],
    );
  }
}
