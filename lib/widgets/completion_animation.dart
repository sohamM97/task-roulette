import 'package:flutter/material.dart';

/// Shows a brief celebratory full-screen overlay and returns when done.
/// Call with `await showCompletionAnimation(context)` before completing.
Future<void> showCompletionAnimation(BuildContext context) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => _CompletionOverlay(
      onDone: () => entry.remove(),
    ),
  );

  overlay.insert(entry);
  return Future.delayed(const Duration(milliseconds: 700));
}

class _CompletionOverlay extends StatefulWidget {
  final VoidCallback onDone;

  const _CompletionOverlay({required this.onDone});

  @override
  State<_CompletionOverlay> createState() => _CompletionOverlayState();
}

class _CompletionOverlayState extends State<_CompletionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _backdropOpacity;
  late Animation<double> _circleScale;
  late Animation<double> _checkProgress;
  late Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 650),
      vsync: this,
    );

    // Backdrop fades in quickly
    _backdropOpacity = Tween(begin: 0.0, end: 0.55).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.2, curve: Curves.easeOut),
      ),
    );

    // Circle pops in with a bounce
    _circleScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.1)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.1, end: 0.95)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.95, end: 1.0),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.0),
        weight: 40,
      ),
    ]).animate(_controller);

    // Checkmark draws after circle appears
    _checkProgress = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 0.55, curve: Curves.easeOut),
      ),
    );

    // Everything fades out at the end
    _fadeOut = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.7, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward().then((_) => widget.onDone());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return IgnorePointer(
          child: Opacity(
            opacity: _fadeOut.value,
            child: Stack(
              children: [
                // Dimmed backdrop
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withAlpha(
                      (_backdropOpacity.value * 255).round(),
                    ),
                  ),
                ),
                // Centered checkmark circle
                Center(
                  child: Transform.scale(
                    scale: _circleScale.value,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorScheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: colorScheme.primary.withAlpha(80),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: CustomPaint(
                        painter: _CheckPainter(
                          progress: _checkProgress.value,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  final double progress;
  final Color color;

  _CheckPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final cx = size.width / 2;
    final cy = size.height / 2;

    // Checkmark points relative to center
    final p1 = Offset(cx - 16, cy + 2);
    final p2 = Offset(cx - 4, cy + 14);
    final p3 = Offset(cx + 18, cy - 12);

    final path = Path();
    final totalLen1 = (p2 - p1).distance;
    final totalLen2 = (p3 - p2).distance;
    final totalLen = totalLen1 + totalLen2;
    final drawn = progress * totalLen;

    if (drawn <= totalLen1) {
      final t = drawn / totalLen1;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * t,
        p1.dy + (p2.dy - p1.dy) * t,
      );
    } else {
      final t = (drawn - totalLen1) / totalLen2;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(p2.dx, p2.dy);
      path.lineTo(
        p2.dx + (p3.dx - p2.dx) * t,
        p2.dy + (p3.dy - p2.dy) * t,
      );
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
