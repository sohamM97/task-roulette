import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_picker_parts.dart';

/// Unit tests for the shared task-picker building blocks introduced in PR #69.
///
/// Both the triage dialog and the "pin a task to Today's 5" dialog were
/// migrated to share [filterTasksBySearch]. The two dialogs' widget tests
/// exercise it end-to-end, but this gives the pure function direct, fast
/// coverage of its branches (name match, parent match, exclusion, empty filter,
/// case-insensitivity, null/absent parent map).
void main() {
  Task t(int id, String name) => Task(id: id, name: name);

  group('filterTasksBySearch', () {
    final apple = t(1, 'Apple pie');
    final banana = t(2, 'Banana bread');
    final cherry = t(3, 'Cherry tart');
    final candidates = [apple, banana, cherry];

    test('[Baseline] empty filter returns all candidates unchanged', () {
      final result = filterTasksBySearch(candidates, '', null);
      expect(result, same(candidates));
    });

    test('[Mechanism] matches by task name (case-insensitive)', () {
      final result = filterTasksBySearch(candidates, 'BANANA', null);
      expect(result, [banana]);
    });

    test('[Mechanism] substring match anywhere in the name', () {
      // "art" appears in "Cherry tart".
      final result = filterTasksBySearch(candidates, 'art', null);
      expect(result, [cherry]);
    });

    test('[Mechanism] matches by a parent name even when the name does not', () {
      // "Wash plates" doesn't contain "kitchen", but its parent does.
      final leaf = t(10, 'Wash plates');
      final parentNames = {10: ['Kitchen']};
      final result = filterTasksBySearch([leaf], 'kitchen', parentNames);
      expect(result, [leaf]);
    });

    test('[Mechanism] matches any one of multiple parent names', () {
      final leaf = t(11, 'Generic chore');
      final parentNames = {11: ['Garage', 'Weekend list']};
      expect(filterTasksBySearch([leaf], 'weekend', parentNames), [leaf]);
      expect(filterTasksBySearch([leaf], 'garage', parentNames), [leaf]);
    });

    test('[Edge case] no match in name or parents returns empty', () {
      final leaf = t(12, 'Pay rent');
      final parentNames = {12: ['Finances']};
      expect(filterTasksBySearch([leaf], 'zzz', parentNames), isEmpty);
    });

    test('[Edge case] null parentNames map: name-only matching, no crash', () {
      final result = filterTasksBySearch(candidates, 'cherry', null);
      expect(result, [cherry]);
      // A filter that only a parent could satisfy finds nothing.
      expect(filterTasksBySearch(candidates, 'kitchen', null), isEmpty);
    });

    test('[Edge case] task absent from parentNames falls back to name only',
        () {
      final leaf = t(13, 'Solo task');
      final result = filterTasksBySearch([leaf], 'solo', const {});
      expect(result, [leaf]);
      expect(filterTasksBySearch([leaf], 'parent', const {}), isEmpty);
    });

    test('[Edge case] empty candidate list returns empty for any filter', () {
      expect(filterTasksBySearch(const [], 'anything', null), isEmpty);
    });

    test('[Mechanism] returns all candidates that match, preserving order', () {
      final a = t(20, 'Task alpha');
      final b = t(21, 'beta');
      final c = t(22, 'task gamma');
      // "task" matches a and c (case-insensitive), in original order.
      final result = filterTasksBySearch([a, b, c], 'task', null);
      expect(result, [a, c]);
    });
  });

  // The unified picker refactor made PickerTaskCard's leadingIcon optional so
  // flat-mode rows (link/move/search pickers) render with no leading icon,
  // while browse rows keep the folder/push-pin icon that hints at the tap
  // action. These guard that contract directly.
  group('PickerTaskCard leadingIcon', () {
    Widget host(Widget child) =>
        MaterialApp(home: Scaffold(body: child));

    testWidgets('[Mechanism] renders the leading icon when one is provided',
        (tester) async {
      await tester.pumpWidget(host(
        PickerTaskCard(
          task: t(1, 'Browse row'),
          leadingIcon: Icons.folder_outlined,
        ),
      ));

      expect(find.text('Browse row'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('[Mechanism] omits the leading icon when leadingIcon is null',
        (tester) async {
      // Flat-picker contract: no leading icon on plain selectable rows.
      await tester.pumpWidget(host(
        PickerTaskCard(task: t(2, 'Flat row')),
      ));

      expect(find.text('Flat row'), findsOneWidget);
      // No Icon renders inside the card when leadingIcon is null and no
      // trailing widget is supplied.
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('[Mechanism] tapping the card invokes onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(
        PickerTaskCard(
          task: t(3, 'Tappable'),
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.text('Tappable'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('[Regression] task name wraps to 2 lines before truncating',
        (tester) async {
      // Regression guard for the card-look unification: single-line ellipsis
      // made two long same-prefix names indistinguishable in the link/move/
      // dependency pickers. The name now wraps to 2 lines.
      await tester.pumpWidget(host(
        PickerTaskCard(
          task: t(4, 'A very long task name that would otherwise be truncated'),
        ),
      ));

      final nameText = tester.widget<Text>(find.text(
          'A very long task name that would otherwise be truncated'));
      expect(nameText.maxLines, 2);
      expect(nameText.overflow, TextOverflow.ellipsis);
    });
  });
}
