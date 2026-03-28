import 'package:flutter/material.dart';

/// Full-screen overlay that dims all content and spotlights a single task card
/// with a glow effect and action buttons.
class SpotlightOverlay extends StatefulWidget {
  /// Global-coordinate rect of the card to spotlight.
  final Rect cardRect;

  /// The actual TaskCard widget to render in the spotlight.
  final Widget cardContent;

  /// Whether the spotlighted task has navigable children (shows "Spin Deeper").
  final bool hasChildren;

  final VoidCallback onDismiss;
  final VoidCallback onGoDeeper;
  final VoidCallback onGoToTask;

  const SpotlightOverlay({
    super.key,
    required this.cardRect,
    required this.cardContent,
    required this.hasChildren,
    required this.onDismiss,
    required this.onGoDeeper,
    required this.onGoToTask,
  });

  @override
  State<SpotlightOverlay> createState() => _SpotlightOverlayState();
}

class _SpotlightOverlayState extends State<SpotlightOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _dimOpacity;
  late Animation<double> _cardScale;
  late Animation<double> _glowOpacity;
  late Animation<double> _buttonOpacity;

  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // Dim backdrop fades in first
    _dimOpacity = Tween(begin: 0.0, end: 0.6).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );

    // Card scales up slightly after dim starts
    _cardScale = Tween(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 0.6, curve: Curves.easeOut),
      ),
    );

    // Glow appears as card scales
    _glowOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
      ),
    );

    // Action buttons fade in last
    _buttonOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.6, 1.0, curve: Curves.easeOut),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rect = widget.cardRect;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Stack(
          children: [
            // Dim backdrop — tap to dismiss
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                child: ColoredBox(
                  color: Colors.black.withAlpha(
                    (_dimOpacity.value * 255).round(),
                  ),
                ),
              ),
            ),

            // Spotlighted card with glow
            Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: Transform.scale(
                scale: _cardScale.value,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withAlpha(
                          (_glowOpacity.value * 120).round(),
                        ),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                      BoxShadow(
                        color: colorScheme.primary.withAlpha(
                          (_glowOpacity.value * 60).round(),
                        ),
                        blurRadius: 40,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onGoToTask,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: widget.cardContent,
                    ),
                  ),
                ),
              ),
            ),

            // Action chips near the spotlighted card
            if (widget.hasChildren)
              Positioned(
                left: rect.left,
                right: MediaQuery.of(context).size.width - rect.right,
                top: _buttonsBelow(context)
                    ? rect.bottom + 8
                    : null,
                bottom: _buttonsBelow(context)
                    ? null
                    : MediaQuery.of(context).size.height - rect.top + 8,
                child: Opacity(
                  opacity: _buttonOpacity.value,
                  child: _buildCardActions(context),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _buttonsBelow(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return screenHeight - widget.cardRect.bottom > 70;
  }

  Widget _buildCardActions(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ActionChip(
            avatar: const Icon(Icons.keyboard_double_arrow_down, size: 16),
            label: const Text('Spin Deeper', style: TextStyle(fontSize: 12)),
            onPressed: widget.onGoDeeper,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            side: BorderSide.none,
          ),
        ],
      ),
    );
  }
}

