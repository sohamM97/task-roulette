import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/widgets/completion_animation.dart';

void main() {
  group('showCompletionAnimation', () {
    testWidgets('shows overlay and completes without crash', (tester) async {
      bool animationDone = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await showCompletionAnimation(context);
                  animationDone = true;
                },
                child: const Text('Animate'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Animate'));
      // Let the animation run (700ms delay + 650ms controller)
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(animationDone, isTrue);
    });

    testWidgets('renders checkmark during animation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showCompletionAnimation(context),
                child: const Text('Animate'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Animate'));
      // Pump a few frames to see the overlay mid-animation
      await tester.pump(const Duration(milliseconds: 100));

      // The overlay should contain a CustomPaint (the checkmark painter)
      expect(find.byType(CustomPaint), findsWidgets);

      // Let it finish
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });

    testWidgets('overlay is ignored for pointer events', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showCompletionAnimation(context),
                child: const Text('Animate'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Animate'));
      await tester.pump(const Duration(milliseconds: 200));

      // The overlay uses IgnorePointer so it shouldn't block taps
      expect(find.byType(IgnorePointer), findsWidgets);

      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });
}
