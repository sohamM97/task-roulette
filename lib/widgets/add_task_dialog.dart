import 'package:flutter/material.dart';
import '../utils/display_utils.dart' show normalizeUrl, isAllowedUrl, showInfoSnackBar, UrlTextField;

/// Result from AddTaskDialog: either a single task name or a request
/// to switch to brain dump mode.
sealed class AddTaskResult {}

class SingleTask extends AddTaskResult {
  final String name;
  final String? url;
  final bool pinInTodays5;
  final bool addToInbox;
  SingleTask(this.name, {this.url, this.pinInTodays5 = false, this.addToInbox = false});
}

class SwitchToBrainDump extends AddTaskResult {
  final String initialText;
  SwitchToBrainDump({this.initialText = ''});
}

class AddTaskDialog extends StatefulWidget {
  /// Whether to show the "Pin in Today's 5" toggle.
  final bool showPinOption;
  /// Whether to show the "Add to Inbox" toggle (root level only).
  final bool showInboxOption;
  /// Optional text to pre-fill the task name field with (e.g. the term the
  /// user searched for when creating a task from empty search results).
  final String? initialName;
  /// Whether to show the "Add multiple" (brain dump) button. Callers whose
  /// result handler only accepts a [SingleTask] MUST set this false — otherwise
  /// tapping "Add multiple" pops a [SwitchToBrainDump] the caller silently
  /// drops (bug: Today's 5 create-from-search discarded the task with no
  /// feedback). Default true for the standard AddTaskFlow path, which handles
  /// the brain-dump branch.
  final bool showAddMultiple;

  const AddTaskDialog({
    super.key,
    this.showPinOption = false,
    this.showInboxOption = false,
    this.initialName,
    this.showAddMultiple = true,
  });

  @override
  State<AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<AddTaskDialog> {
  late final TextEditingController _controller;
  final _urlController = TextEditingController();
  bool _pin = false;
  bool _showUrl = false;
  bool _inbox = true; // default ON for inbox

  @override
  void initState() {
    super.initState();
    final initial = widget.initialName ?? '';
    _controller = TextEditingController(text: initial);
    // Place the cursor at the end so the user can keep typing / editing the
    // pre-filled term rather than overwriting it.
    _controller.selection =
        TextSelection.collapsed(offset: initial.length);
  }

  @override
  void dispose() {
    _controller.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    String? url;
    if (_showUrl) {
      final raw = _urlController.text.trim();
      if (raw.isNotEmpty) {
        url = normalizeUrl(raw);
        if (url == null || !isAllowedUrl(url)) {
          ScaffoldMessenger.of(context).clearSnackBars();
          showInfoSnackBar(context, 'Invalid URL');
          return;
        }
      }
    }
    Navigator.pop(context, SingleTask(name, url: url, pinInTodays5: _pin, addToInbox: widget.showInboxOption && _inbox));
  }

  /// The Inbox / Pin toggle chips, shared between the "Add multiple" row and
  /// the actions bar so both placements stay identical.
  List<Widget> _buildToggles(ColorScheme colorScheme) {
    return [
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
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  'Inbox',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _inbox
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      if (widget.showPinOption)
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _pin = !_pin),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                  widget.showInboxOption ? 'Pin' : 'Pin for today',
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
    ];
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
            decoration: InputDecoration(
              hintText: 'Task name',
              border: const OutlineInputBorder(),
              counterText: '',
              suffixIcon: IconButton(
                icon: Icon(
                  Icons.link,
                  size: 20,
                  color: _showUrl
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant.withAlpha(120),
                ),
                tooltip: 'Add URL',
                onPressed: () => setState(() => _showUrl = !_showUrl),
              ),
            ),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _submit(),
          ),
          if (_showUrl) ...[
            const SizedBox(height: 8),
            UrlTextField(
              controller: _urlController,
              isDense: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
          // When "Add multiple" is shown it anchors the left of a dedicated
          // toggle row (Spacer pushes Inbox/Pin right). When it's hidden
          // (e.g. Today's 5 create flow), that row would be just a lone chip
          // stranded next to a wide empty gap, so we drop the row entirely and
          // fold the toggles into the actions bar beside Cancel/Add instead.
          if (widget.showAddMultiple) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, SwitchToBrainDump(initialText: _controller.text.trim())),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.onSurfaceVariant,
                    textStyle: Theme.of(context).textTheme.bodySmall,
                  ),
                  child: const Text('Add multiple'),
                ),
                const Spacer(),
                ..._buildToggles(colorScheme),
              ],
            ),
          ],
        ],
      ),
      actions: [
        // Toggles live inline with Cancel/Add when there's no "Add multiple"
        // row to host them (see comment above).
        if (!widget.showAddMultiple) ..._buildToggles(colorScheme),
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
