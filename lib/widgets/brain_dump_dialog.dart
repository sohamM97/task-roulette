import 'package:flutter/material.dart';

/// Dialog for rapid multi-task entry. Each line becomes a separate task.
/// Returns a list of task names (non-empty, trimmed).
/// Result from BrainDumpDialog: task names + inbox preference.
class BrainDumpResult {
  final List<String> names;
  final bool addToInbox;
  BrainDumpResult(this.names, {this.addToInbox = false});
}

class BrainDumpDialog extends StatefulWidget {
  final String initialText;
  final bool showInboxOption;

  const BrainDumpDialog({super.key, this.initialText = '', this.showInboxOption = false});

  @override
  State<BrainDumpDialog> createState() => _BrainDumpDialogState();
}

class _BrainDumpDialogState extends State<BrainDumpDialog> {
  final _controller = TextEditingController();
  int _lineCount = 0;
  bool _inbox = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialText.isNotEmpty) {
      _controller.text = widget.initialText;
    }
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
        .map((l) => l.length > 500 ? l.substring(0, 500) : l)
        .toList();
  }

  void _submit() {
    final names = _parseNames();
    if (names.isNotEmpty) {
      Navigator.pop(context, BrainDumpResult(names, addToInbox: widget.showInboxOption && _inbox));
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
              maxLength: 25000,
              autofocus: true,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Buy groceries\nCall dentist\nFinish report\n...',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            if (_lineCount > 0 || widget.showInboxOption) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_lineCount > 0)
                    Text(
                      '$_lineCount ${_lineCount == 1 ? 'task' : 'tasks'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  const Spacer(),
                  if (widget.showInboxOption)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setState(() => _inbox = !_inbox),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _inbox ? Icons.inbox : Icons.inbox_outlined,
                              size: 16,
                              color: _inbox
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(120),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Inbox',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: _inbox
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(120),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
