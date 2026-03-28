import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/widgets/spotlight_overlay.dart';

Widget _wrap({
  required Widget cardContent,
  required bool hasChildren,
  VoidCallback? onDismiss,
  VoidCallback? onGoDeeper,
  VoidCallback? onGoToTask,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SpotlightOverlay(
        cardRect: const Rect.fromLTWH(20, 100, 300, 80),
        cardContent: cardContent,
        hasChildren: hasChildren,
        onDismiss: onDismiss ?? () {},
        onGoDeeper: onGoDeeper ?? () {},
        onGoToTask: onGoToTask ?? () {},
      ),
    ),
  );
}

void main() {
  group('SpotlightOverlay', () {
    testWidgets('renders dim backdrop', (tester) async {
      await tester.pumpWidget(_wrap(
        cardContent: const Text('My Task'),
        hasChildren: false,
      ));
      // Let animation progress
      await tester.pumpAndSettle();

      // The backdrop is a ColoredBox with black color at 60% opacity after animation.
      // Find all ColoredBox widgets and check that one has the expected dim color.
      final coloredBoxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
      final hasDimBackdrop = coloredBoxes.any((box) {
        final color = box.color;
        return color.r == 0 && color.g == 0 && color.b == 0 &&
            (color.a * 255).round() == (0.6 * 255).round();
      });
      expect(hasDimBackdrop, isTrue);
    });

    testWidgets('shows card content', (tester) async {
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Task Card Content'),
        hasChildren: false,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Task Card Content'), findsOneWidget);
    });

    testWidgets('shows Spin Deeper chip when hasChildren is true',
        (tester) async {
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Parent Task'),
        hasChildren: true,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Spin Deeper'), findsOneWidget);
      expect(find.byType(ActionChip), findsOneWidget);
    });

    testWidgets('hides Spin Deeper chip when hasChildren is false',
        (tester) async {
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Leaf Task'),
        hasChildren: false,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Spin Deeper'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('calls onDismiss when backdrop tapped', (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(_wrap(
        cardContent: const SizedBox(width: 100, height: 40),
        hasChildren: false,
        onDismiss: () => dismissed = true,
      ));
      await tester.pumpAndSettle();

      // Tap in an area outside the card (top-left corner of the backdrop)
      await tester.tapAt(const Offset(5, 5));
      // The dismiss reverses the animation, so pump until settled
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });

    testWidgets('calls onGoToTask when card tapped', (tester) async {
      bool navigated = false;
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Tap Me'),
        hasChildren: false,
        onGoToTask: () => navigated = true,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tap Me'));
      await tester.pump();

      expect(navigated, isTrue);
    });

    testWidgets('calls onGoDeeper when Spin Deeper chip tapped',
        (tester) async {
      bool wentDeeper = false;
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Parent'),
        hasChildren: true,
        onGoDeeper: () => wentDeeper = true,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spin Deeper'));
      await tester.pump();

      expect(wentDeeper, isTrue);
    });

    testWidgets('shows keyboard_double_arrow_down icon on Spin Deeper chip',
        (tester) async {
      await tester.pumpWidget(_wrap(
        cardContent: const Text('Task'),
        hasChildren: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.keyboard_double_arrow_down), findsOneWidget);
    });
  });
}
