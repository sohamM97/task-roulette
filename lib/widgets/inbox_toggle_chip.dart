import 'package:flutter/material.dart';

/// The "Inbox" toggle chip shown by both the Add Task dialog and the Brain dump
/// dialog.
///
/// Extracted because the two had drifted: the ON state matched, but the OFF
/// state used `onSurfaceVariant` in the Add Task dialog and
/// `onSurfaceVariant.withAlpha(120)` in the brain dump — so the same chip
/// visibly dimmed when the user tapped "Add multiple". That was easy to miss
/// while the brain dump's OFF state was only reachable by tapping, but once the
/// Inbox choice began carrying across the switch, OFF became the brain dump's
/// *opening* state and the mismatch showed on every use. The extra fade also
/// read as "disabled" rather than "off".
///
/// One widget, so the two placements cannot diverge again.
class InboxToggleChip extends StatelessWidget {
  const InboxToggleChip({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Whether the task(s) will be filed in the Inbox.
  final bool value;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // ON = accent; OFF = plain muted (NOT further faded — that reads as
    // disabled, and the chip is always tappable).
    final color = value ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.inbox : Icons.inbox_outlined,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              'Inbox',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
