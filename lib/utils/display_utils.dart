import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Icon used for the archive/completed-tasks screen.
const IconData archiveIcon = Icons.inventory_2_outlined;

/// Returns the deadline icon color based on days until deadline.
/// Used by task cards, Today's 5, and schedule dialog.
Color deadlineProximityColor(int daysUntil, ColorScheme colorScheme) {
  if (daysUntil <= 2) return Colors.deepOrange;
  if (daysUntil <= 7) return Colors.orange;
  return colorScheme.primary;
}

/// Shows a brief informational snackbar with a close icon (or Undo action).
void showInfoSnackBar(BuildContext context, String message, {VoidCallback? onUndo}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    showCloseIcon: onUndo == null,
    action: onUndo != null ? SnackBarAction(label: 'Undo', onPressed: onUndo) : null,
    duration: Duration(seconds: onUndo != null ? 5 : 3),
  ));
}

/// Returns today's date as a 'YYYY-MM-DD' string, used as a key for
/// Today's 5 state in the DB and Firestore.
String todayDateKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

/// Shortens an ancestor path for display in compact badges.
/// Truncates ancestor names from the left so the immediate parent
/// (last segment) stays fully visible.
String shortenAncestorPath(String path) {
  final segments = path.split(' › ');
  if (segments.length <= 1) return path;
  if (segments.length > 3) {
    return '…${segments.sublist(segments.length - 2).join(' › ')}';
  }
  final last = segments.last;
  final prior = segments.sublist(0, segments.length - 1)
      .map((s) => s.length > 12 ? '…${s.substring(s.length - 8)}' : s);
  return '${prior.join(' › ')} › $last';
}

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

/// Validates and launches a URL, showing a snackbar on failure.
/// Centralizes the scheme check, try-catch, and mounted guard so callers
/// don't duplicate the same error-handling boilerplate.
Future<void> launchSafeUrl(BuildContext context, String url) async {
  if (!isAllowedUrl(url)) {
    if (context.mounted) {
      showInfoSnackBar(context, 'Only web links (http/https) are supported');
    }
    return;
  }
  bool opened;
  try {
    opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    showInfoSnackBar(context, 'Could not open link');
  }
}

/// A URL text field with auto-fill "https://":
/// - Swipe right on mobile (when empty)
/// - Tab key on desktop/web (when empty)
class UrlTextField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool isDense;

  const UrlTextField({
    super.key,
    required this.controller,
    this.onSubmitted,
    this.autofocus = false,
    this.isDense = false,
  });

  void _fillHttps() {
    controller.text = 'https://';
    controller.selection = TextSelection.fromPosition(
      TextPosition(offset: controller.text.length),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        controller.text.isEmpty) {
      _fillHttps();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 0 && controller.text.isEmpty) {
          _fillHttps();
        }
      },
      child: Focus(
        onKeyEvent: _handleKey,
        child: TextField(
          controller: controller,
          maxLength: 2048,
          decoration: InputDecoration(
            hintText: 'https://...',
            border: const OutlineInputBorder(),
            counterText: '',
            isDense: isDense,
          ),
          keyboardType: TextInputType.url,
          autofocus: autofocus,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
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
