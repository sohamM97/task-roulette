import 'package:flutter/material.dart';

/// Icon used for the archive/completed-tasks screen.
const IconData archiveIcon = Icons.inventory_2_outlined;

String displayUrl(String url, {int maxLength = 40}) {
  var display = url.replaceFirst(RegExp(r'^https?://'), '');
  if (display.endsWith('/')) display = display.substring(0, display.length - 1);
  return display.length > maxLength ? '${display.substring(0, maxLength)}...' : display;
}

/// Normalizes a URL: auto-prepends https:// for bare domains.
/// Returns null if the input is empty/null or not a valid URL with a host.
String? normalizeUrl(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final trimmed = raw.trim();
  final normalized = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.host.contains('.')) return null;
  return normalized;
}

/// Returns true if the URL has an allowed scheme (http or https).
bool isAllowedUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// Pin/unpin toggle button for Today's 5 tasks.
class PinButton extends StatelessWidget {
  final bool isPinned;
  final VoidCallback onToggle;
  final double size;
  /// When true, unpinned state uses a muted color to blend with surrounding icons.
  final bool mutedWhenUnpinned;
  /// When true and not already pinned, show greyed-out disabled state.
  final bool atMaxPins;

  const PinButton({
    super.key,
    required this.isPinned,
    required this.onToggle,
    this.size = 18,
    this.mutedWhenUnpinned = false,
    this.atMaxPins = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final disabled = atMaxPins && !isPinned;
    final color = disabled
        ? colorScheme.onSurfaceVariant.withAlpha(100)
        : isPinned
            ? colorScheme.tertiary
            : mutedWhenUnpinned
                ? colorScheme.tertiary.withAlpha(170)
                : colorScheme.tertiary;
    return IconButton(
      icon: Icon(
        isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        size: size,
        color: color,
      ),
      onPressed: disabled ? null : onToggle,
      tooltip: disabled ? 'Max pins reached' : isPinned ? 'Unpin' : 'Pin',
      visualDensity: VisualDensity.compact,
    );
  }
}
