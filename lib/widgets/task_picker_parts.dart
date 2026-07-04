import 'package:flutter/material.dart';
import '../models/task.dart';

/// Shared building blocks for the task pickers — the triage dialog
/// (`triage_dialog.dart`) and the unified `TaskPickerDialog`
/// (`task_picker_dialog.dart`), which covers both the flat search/link/move
/// pickers and the Today's 5 browse-tree "pin a task" flow.
///
/// These pickers intentionally keep their own row-tap / selection behavior
/// (triage drills on tap and selects via a trailing button; the browse tree
/// selects leaves on tap and drills into parents; the flat picker returns the
/// tapped task). What they share — and what lived as copy-pasted code before —
/// is the visual chrome: the row card, the search field, the name/parent
/// search filter, and the empty-search state. Those are factored out here so a
/// fix to any of them applies to every picker.

/// A single tappable task row used in the browse list, the search results, and
/// the flat picker. The caller may supply a [leadingIcon] (e.g. folder vs.
/// push-pin) — omit it (null) for rows where an icon would carry no meaning
/// (e.g. the flat link/move/search pickers, where every row is just a
/// selectable task). Also takes an optional [subtitle] (e.g. "under Project
/// X"), the [onTap], and an optional [trailing] widget (e.g. a chevron or a
/// "place here" button).
class PickerTaskCard extends StatelessWidget {
  final Task task;
  final IconData? leadingIcon;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const PickerTaskCard({
    super.key,
    required this.task,
    this.leadingIcon,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colorScheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (leadingIcon != null) ...[
                  Icon(
                    leadingIcon,
                    size: 18,
                    color: colorScheme.primary.withAlpha(180),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        style: Theme.of(context).textTheme.bodyMedium,
                        // Wrap to 2 lines before truncating: single-line
                        // ellipsis made two long same-prefix task names
                        // indistinguishable in the link/move/dependency
                        // pickers, so the user could pick the wrong one.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The always-visible search field at the top of both pickers. [isSearching]
/// drives the clear (×) suffix; [onChanged] fires per keystroke and [onClear]
/// resets the filter.
class PickerSearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool isSearching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const PickerSearchField({
    super.key,
    required this.controller,
    required this.isSearching,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: 500,
      decoration: InputDecoration(
        hintText: 'Search tasks...',
        prefixIcon: const Icon(Icons.search, size: 20),
        border: const OutlineInputBorder(),
        isDense: true,
        counterText: '',
        suffixIcon: isSearching
            ? IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
              )
            : null,
      ),
      onChanged: onChanged,
    );
  }
}

/// The empty state shown when a search yields no matching tasks. When
/// [onCreateTask] is supplied (opt-in) and [query] has non-blank content, it
/// also offers a "Create ..." button so the user can spin up a task named
/// after their search term. Shared by every picker so the affordance looks and
/// behaves identically; pickers that must not offer creation (e.g. the
/// dependency/link pickers) simply leave [onCreateTask] null.
class PickerSearchEmptyState extends StatelessWidget {
  /// The current (raw) search query. Trimmed internally for the button label
  /// and the blank-check.
  final String query;

  /// Opt-in create callback, invoked with the trimmed query.
  final void Function(String query)? onCreateTask;

  /// Overrides the default "No matching tasks" line. Used when the query
  /// matches a task that exists but is hidden from the pool (e.g. a leaf
  /// already in Today's 5) to say so instead of implying nothing matches.
  final String? message;

  const PickerSearchEmptyState({
    super.key,
    required this.query,
    this.onCreateTask,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = query.trim();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message ?? 'No matching tasks', textAlign: TextAlign.center),
            if (onCreateTask != null && trimmed.isNotEmpty) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text('Create "$trimmed"'),
                onPressed: () => onCreateTask!(trimmed),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Filters [candidates] by [filter], matching the task name or any of its
/// parent names (case-insensitive). Returns [candidates] unchanged when
/// [filter] is empty. [parentNames] maps a task id to its parent names.
List<Task> filterTasksBySearch(
  List<Task> candidates,
  String filter,
  Map<int, List<String>>? parentNames,
) {
  if (filter.isEmpty) return candidates;
  final lower = filter.toLowerCase();
  return candidates.where((t) {
    if (t.name.toLowerCase().contains(lower)) return true;
    final parents = parentNames?[t.id!];
    return parents != null && parents.any((p) => p.toLowerCase().contains(lower));
  }).toList();
}
