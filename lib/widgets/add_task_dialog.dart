import 'package:flutter/material.dart';
import '../models/task.dart';
import '../utils/display_utils.dart' show normalizeUrl, isAllowedUrl, showInfoSnackBar, UrlTextField;

/// Result from AddTaskDialog: a single task name, a request to switch to brain
/// dump mode, or a request to use an already-existing task instead of creating
/// a duplicate.
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

/// The user tapped an inline "already exists" suggestion — they want to act on
/// the existing [task] (pin/star/link/open, per surface) instead of creating a
/// duplicate. The caller decides what "use it" means for its surface.
class UseExisting extends AddTaskResult {
  final Task task;
  UseExisting(this.task);
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

  /// Existing tasks to check the typed name against. When the trimmed name
  /// exactly matches (case-insensitive) one or more of these, an inline
  /// "already exists" suggestion is shown offering to use the existing task
  /// instead of creating a duplicate (pops [UseExisting]). Empty disables the
  /// feature.
  final List<Task> existingTasks;

  /// Icon shown on each suggestion row, representing what tapping it does on
  /// this surface (pin / star / link / open). Must be self-explanatory on its
  /// own (mobile has no tooltips).
  final IconData existingActionIcon;

  /// Human label for the action, surfaced as the icon's tooltip (desktop) and
  /// accessibility semantics — NOT drawn as visible text.
  final String existingActionLabel;

  /// Parent names per task id (from `getParentNamesMap`). Used to append a
  /// "(under parent)" hint to each suggestion so same-named tasks are
  /// distinguishable. Tasks absent here (or at root) get no hint.
  final Map<int, List<String>> existingParentNames;

  const AddTaskDialog({
    super.key,
    this.showPinOption = false,
    this.showInboxOption = false,
    this.initialName,
    this.showAddMultiple = true,
    this.existingTasks = const [],
    this.existingActionIcon = Icons.arrow_forward,
    this.existingActionLabel = 'Use this',
    this.existingParentNames = const {},
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

  /// Existing tasks whose name exactly matches the current input (case- and
  /// whitespace-insensitive). Drives the "already exists" suggestion.
  List<Task> get _matches {
    final q = _controller.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return widget.existingTasks
        .where((t) => t.name.trim().toLowerCase() == q)
        .toList();
  }

  /// The in-field "already exists" indicator: a tappable badge (info icon +
  /// count when several) that opens a popup of matching tasks. Living in the
  /// field's suffix keeps the dialog a fixed size — a match never grows the
  /// dialog or shifts the buttons. Each popup entry shows the task name, a muted
  /// location hint ("(under Parent)" / "(under Inbox)" / none for a plain root
  /// task), and the action icon; selecting one pops [UseExisting] so the caller
  /// can act on the existing task instead of creating a duplicate.
  Widget _buildMatchIndicator(ColorScheme colorScheme, List<Task> matches) {
    const maxShown = 3;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    final nameStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        );
    return PopupMenuButton<Task>(
      tooltip: matches.length == 1
          ? '1 task already has this name — tap to use it'
          : '${matches.length} tasks already have this name — tap to use one',
      // Anchor the menu directly under the field so it reads as a "did you
      // mean" dropdown without pushing any dialog content.
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
      padding: EdgeInsets.zero,
      onSelected: (t) => Navigator.pop(context, UseExisting(t)),
      itemBuilder: (context) => [
        PopupMenuItem<Task>(
          enabled: false,
          height: 30,
          child: Text('Did you mean:', style: muted),
        ),
        for (final t in matches.take(maxShown))
          PopupMenuItem<Task>(
            value: t,
            child: Row(
              children: [
                // Dynamic name+location must be Expanded (project rule) so
                // ellipsis works and it never overflows the menu.
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: t.name, style: nameStyle),
                      TextSpan(text: _locationHint(t), style: muted),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: widget.existingActionLabel,
                  child: Icon(widget.existingActionIcon,
                      size: 20, color: colorScheme.primary),
                ),
              ],
            ),
          ),
        if (matches.length > maxShown)
          PopupMenuItem<Task>(
            enabled: false,
            height: 30,
            child: Text('+${matches.length - maxShown} more with this name',
                style: muted),
          ),
      ],
      // The in-field badge: a highlight-tinted info icon, plus the count when
      // there are several matches, so it reads as "heads up, this already
      // exists — tap me".
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 20, color: colorScheme.tertiary),
            if (matches.length > 1) ...[
              const SizedBox(width: 2),
              Text('${matches.length}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colorScheme.tertiary,
                        fontWeight: FontWeight.w700,
                      )),
            ],
          ],
        ),
      ),
    );
  }

  /// Where the existing task lives, shown after its name to disambiguate
  /// same-named tasks: "(under Parent)" for a parented task (first parent + "+N"
  /// when there are several) or "(under Inbox)" for an inbox task. Empty for a
  /// plain root task — no hint is shown in that case.
  String _locationHint(Task t) {
    final parents = widget.existingParentNames[t.id] ?? const [];
    if (parents.isNotEmpty) {
      if (parents.length == 1) return ' (under ${parents.first})';
      return ' (under ${parents.first} +${parents.length - 1})';
    }
    if (t.isInbox) return ' (under Inbox)';
    return '';
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
              // A Row so the "already exists" indicator can sit beside the URL
              // toggle. Keeping the suggestions in a popup off this indicator
              // (rather than an inline panel) means a match never resizes the
              // dialog or shifts the buttons.
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_matches.isNotEmpty)
                    _buildMatchIndicator(colorScheme, _matches),
                  IconButton(
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
                ],
              ),
            ),
            textCapitalization: TextCapitalization.sentences,
            // Rebuild on every keystroke so the "already exists" indicator
            // updates live as the name is typed/edited.
            onChanged: widget.existingTasks.isEmpty
                ? null
                : (_) => setState(() {}),
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
