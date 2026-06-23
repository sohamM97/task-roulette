import 'package:flutter/material.dart';
import '../models/task.dart';

/// Shared building blocks for the browse/search task pickers — the triage
/// dialog (`triage_dialog.dart`) and the "pin a task to Today's 5" dialog
/// (`pick_task_for_today_dialog.dart`).
///
/// These dialogs intentionally keep their own row-tap / selection behavior
/// (triage drills on tap and selects via a trailing button; the Today's 5
/// picker selects leaves on tap and drills into parents). What they share —
/// and what lived as copy-pasted code before — is the visual chrome: the row
/// card, the search field, and the name/parent search filter. Those are
/// factored out here so a fix to any of them applies to both pickers.

/// A single tappable task row used in both the browse list and the search
/// results. The caller supplies the [leadingIcon] (e.g. folder vs. push-pin),
/// an optional [subtitle] (e.g. "under Project X"), the [onTap], and an
/// optional [trailing] widget (e.g. a chevron or a "place here" button).
class PickerTaskCard extends StatelessWidget {
  final Task task;
  final IconData leadingIcon;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const PickerTaskCard({
    super.key,
    required this.task,
    required this.leadingIcon,
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
                Icon(
                  leadingIcon,
                  size: 18,
                  color: colorScheme.primary.withAlpha(180),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 1,
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
