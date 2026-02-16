import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_picker_dialog.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  List<Task> makeTasks(List<String> names) {
    return [
      for (var i = 0; i < names.length; i++)
        Task(id: i + 1, name: names[i], createdAt: now),
    ];
  }

  Widget buildDialog({
    required List<Task> candidates,
    Set<int> priorityIds = const {},
    Set<int> secondaryPriorityIds = const {},
    Map<int, List<String>> parentNamesMap = const {},
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              showDialog<Task>(
                context: context,
                builder: (_) => TaskPickerDialog(
                  candidates: candidates,
                  priorityIds: priorityIds,
                  secondaryPriorityIds: secondaryPriorityIds,
                  parentNamesMap: parentNamesMap,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }

  /// Returns the displayed task names in order from the ListView.
  List<String> getDisplayedTaskNames(WidgetTester tester) {
    final listTiles = tester.widgetList<ListTile>(find.byType(ListTile));
    return listTiles.map((tile) {
      final titleWidget = tile.title as Text;
      return titleWidget.data!;
    }).toList();
  }

  group('TaskPickerDialog priorityIds', () {
    testWidgets('without priorityIds, preserves original order',
        (tester) async {
      final tasks = makeTasks(['Zebra', 'Apple', 'Mango']);

      await tester.pumpWidget(buildDialog(candidates: tasks));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(getDisplayedTaskNames(tester), ['Zebra', 'Apple', 'Mango']);
    });

    testWidgets('priority tasks appear first', (tester) async {
      final tasks = makeTasks(['Zebra', 'Apple', 'Mango', 'Banana']);
      // Apple (id=2) and Banana (id=4) are priority
      final priorityIds = {2, 4};

      await tester.pumpWidget(
          buildDialog(candidates: tasks, priorityIds: priorityIds));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      expect(names, ['Apple', 'Banana', 'Zebra', 'Mango']);
    });

    testWidgets('preserves relative order within priority and non-priority groups',
        (tester) async {
      final tasks = makeTasks(['D', 'C', 'B', 'A', 'E']);
      // C (id=2) and A (id=4) are priority
      final priorityIds = {2, 4};

      await tester.pumpWidget(
          buildDialog(candidates: tasks, priorityIds: priorityIds));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // Priority: C, A (original order); Rest: D, B, E (original order)
      expect(names, ['C', 'A', 'D', 'B', 'E']);
    });

    testWidgets('priority sorting applies after search filter',
        (tester) async {
      final tasks = makeTasks(['Buy milk', 'Buy eggs', 'Sell car', 'Buy bread']);
      // Buy eggs (id=2) and Buy bread (id=4) are priority
      final priorityIds = {2, 4};

      await tester.pumpWidget(
          buildDialog(candidates: tasks, priorityIds: priorityIds));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Type "buy" to filter
      await tester.enterText(find.byType(TextField), 'buy');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // Filtered to "Buy" tasks, priority first: Buy eggs, Buy bread, Buy milk
      expect(names, ['Buy eggs', 'Buy bread', 'Buy milk']);
    });

    testWidgets('all tasks in priority set preserves original order',
        (tester) async {
      final tasks = makeTasks(['C', 'A', 'B']);
      final priorityIds = {1, 2, 3};

      await tester.pumpWidget(
          buildDialog(candidates: tasks, priorityIds: priorityIds));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(getDisplayedTaskNames(tester), ['C', 'A', 'B']);
    });

    testWidgets('no tasks match priority set preserves original order',
        (tester) async {
      final tasks = makeTasks(['C', 'A', 'B']);
      final priorityIds = {99, 100};

      await tester.pumpWidget(
          buildDialog(candidates: tasks, priorityIds: priorityIds));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(getDisplayedTaskNames(tester), ['C', 'A', 'B']);
    });

    testWidgets('search by parent context also respects priority order',
        (tester) async {
      final tasks = makeTasks(['Task A', 'Task B', 'Task C']);
      // Task B (id=2) has a parent named "Groceries"
      // Task C (id=3) has a parent named "Groceries"
      final parentNamesMap = {
        2: ['Groceries'],
        3: ['Groceries'],
      };
      // Task C is priority
      final priorityIds = {3};

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        priorityIds: priorityIds,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Search for "groceries" — matches Task B and Task C via parent context
      await tester.enterText(find.byType(TextField), 'groceries');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // Task C (priority) first, then Task B
      expect(names, ['Task C', 'Task B']);
    });
  });

  group('TaskPickerDialog secondaryPriorityIds', () {
    testWidgets('three-tier sorting: primary, secondary, rest', (tester) async {
      final tasks = makeTasks(['Rest1', 'Secondary1', 'Primary1', 'Secondary2', 'Rest2', 'Primary2']);
      // Primary: ids 3, 6. Secondary: ids 2, 4.
      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        priorityIds: {3, 6},
        secondaryPriorityIds: {2, 4},
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(getDisplayedTaskNames(tester),
          ['Primary1', 'Primary2', 'Secondary1', 'Secondary2', 'Rest1', 'Rest2']);
    });

    testWidgets('secondary without primary shows secondary first', (tester) async {
      final tasks = makeTasks(['C', 'A', 'B']);
      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        secondaryPriorityIds: {2}, // A
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(getDisplayedTaskNames(tester), ['A', 'C', 'B']);
    });

    testWidgets('secondary sorting applies after search filter', (tester) async {
      final tasks = makeTasks(['Buy milk', 'Buy eggs', 'Sell car', 'Buy bread']);
      // Buy eggs (id=2) is primary, Buy bread (id=4) is secondary
      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        priorityIds: {2},
        secondaryPriorityIds: {4},
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'buy');
      await tester.pumpAndSettle();

      // Primary: Buy eggs, Secondary: Buy bread, Rest: Buy milk
      expect(getDisplayedTaskNames(tester), ['Buy eggs', 'Buy bread', 'Buy milk']);
    });
  });
}
