import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/utils/display_utils.dart';

void main() {
  group('PinButton', () {
    Widget buildPinButton({
      required bool isPinned,
      bool atMaxPins = false,
      bool mutedWhenUnpinned = false,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: PinButton(
            isPinned: isPinned,
            onToggle: () {},
            atMaxPins: atMaxPins,
            mutedWhenUnpinned: mutedWhenUnpinned,
          ),
        ),
      );
    }

    testWidgets('atMaxPins: true, isPinned: false -> push_pin_outlined icon, '
        '"Max pins reached" tooltip', (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: false,
        atMaxPins: true,
      ));

      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byTooltip('Max pins reached'), findsOneWidget);
    });

    testWidgets('atMaxPins: true, isPinned: true -> push_pin (filled) icon, '
        '"Unpin" tooltip (can still unpin)', (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: true,
        atMaxPins: true,
      ));

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
      expect(find.byTooltip('Unpin'), findsOneWidget);
    });

    testWidgets('atMaxPins: false, isPinned: false -> push_pin_outlined icon, '
        '"Pin" tooltip', (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: false,
        atMaxPins: false,
      ));

      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byTooltip('Pin'), findsOneWidget);
    });

    testWidgets('atMaxPins: false, isPinned: true -> push_pin (filled) icon, '
        '"Unpin" tooltip', (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: true,
        atMaxPins: false,
      ));

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byTooltip('Unpin'), findsOneWidget);
    });

    testWidgets('disabled state (atMaxPins + unpinned) uses greyed-out color',
        (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: false,
        atMaxPins: true,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.push_pin_outlined));
      // The disabled color uses onSurfaceVariant.withAlpha(100), which will
      // have a low alpha value compared to the normal tertiary color.
      expect((icon.color!.a * 255.0).round(), 100);
    });

    testWidgets('non-disabled unpinned state uses full tertiary color '
        '(not greyed out)', (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: false,
        atMaxPins: false,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.push_pin_outlined));
      // When not disabled and not muted, color should be tertiary with full alpha (255)
      expect((icon.color!.a * 255.0).round(), 255);
    });

    testWidgets('mutedWhenUnpinned uses reduced alpha for unpinned state',
        (tester) async {
      await tester.pumpWidget(buildPinButton(
        isPinned: false,
        atMaxPins: false,
        mutedWhenUnpinned: true,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.push_pin_outlined));
      // mutedWhenUnpinned should use tertiary.withAlpha(170)
      expect((icon.color!.a * 255.0).round(), 170);
    });

    testWidgets('onToggle callback is invoked when tapped', (tester) async {
      bool toggled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PinButton(
            isPinned: false,
            onToggle: () => toggled = true,
          ),
        ),
      ));

      await tester.tap(find.byType(IconButton));
      expect(toggled, isTrue);
    });

    testWidgets('onToggle is NOT callable when atMaxPins and unpinned '
        '(button is disabled)', (tester) async {
      bool toggled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PinButton(
            isPinned: false,
            onToggle: () => toggled = true,
            atMaxPins: true,
          ),
        ),
      ));

      await tester.tap(find.byType(IconButton));
      expect(toggled, isFalse);
    });
  });
}
