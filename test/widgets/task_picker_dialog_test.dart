import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_picker_dialog.dart';
import 'package:task_roulette/widgets/task_picker_parts.dart';

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

  /// Returns the displayed task names in order from the result list. Flat-mode
  /// rows render as [PickerTaskCard]s (shared card chrome).
  List<String> getDisplayedTaskNames(WidgetTester tester) {
    final cards =
        tester.widgetList<PickerTaskCard>(find.byType(PickerTaskCard));
    return cards.map((card) => card.task.name).toList();
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

  group('TaskPickerDialog search ranking', () {
    testWidgets('name matches appear before context-only matches',
        (tester) async {
      // Task "1.2" plus children that match via parent context
      final tasks = makeTasks(['Child A', 'Child B', '1.2', 'Child C']);
      final parentNamesMap = {
        1: ['1.2'], // Child A is under 1.2
        2: ['1.2'], // Child B is under 1.2
        4: ['1.2'], // Child C is under 1.2
      };

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '1.2');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // "1.2" matches by name — should be first
      expect(names.first, '1.2');
      // Children match only via parent context — should come after
      expect(names.sublist(1), containsAll(['Child A', 'Child B', 'Child C']));
    });

    testWidgets('context-only matches preserve relative order',
        (tester) async {
      final tasks = makeTasks(['Alpha', 'Beta', 'Gamma', 'Target']);
      final parentNamesMap = {
        1: ['Target'], // Alpha under Target
        2: ['Target'], // Beta under Target
        3: ['Target'], // Gamma under Target
      };

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Target');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      expect(names, ['Target', 'Alpha', 'Beta', 'Gamma']);
    });

    testWidgets('multiple name matches preserve relative order',
        (tester) async {
      final tasks = makeTasks(['Buy milk', 'Sell car', 'Buy eggs']);

      await tester.pumpWidget(buildDialog(candidates: tasks));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'buy');
      await tester.pumpAndSettle();

      // Both match by name — should keep original order
      expect(getDisplayedTaskNames(tester), ['Buy milk', 'Buy eggs']);
    });

    testWidgets('exact name match jumps above all priority tiers',
        (tester) async {
      // "1.2" is the exact match; e1, e2 are siblings (priority) that match via context
      final tasks = makeTasks(['e1', 'e2', '1.2', 'e3']);
      final parentNamesMap = {
        1: ['1.2'], // e1 under 1.2
        2: ['1.2'], // e2 under 1.2
      };
      // e1 (id=1), e2 (id=2) are in priority tier (siblings)
      final priorityIds = {1, 2};

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        priorityIds: priorityIds,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '1.2');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // Exact name match "1.2" jumps to top, then priority siblings e1, e2
      expect(names.first, '1.2');
      expect(names.sublist(1), ['e1', 'e2']);
    });

    testWidgets('partial name match also ranks above context-only in priority tier',
        (tester) async {
      // "Project" contains "proj"; Child Y is priority but only context match
      final tasks = makeTasks(['Child X', 'Project', 'Child Y']);
      final parentNamesMap = {
        1: ['Project'], // Child X under Project
        3: ['Project'], // Child Y under Project
      };
      // Child Y (id=3) is in priority tier
      final priorityIds = {3};

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        priorityIds: priorityIds,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'proj');
      await tester.pumpAndSettle();

      final names = getDisplayedTaskNames(tester);
      // Name match (Project) first, then context-only by tier
      // (Child Y is priority, Child X is rest)
      expect(names, ['Project', 'Child Y', 'Child X']);
    });

    testWidgets('no filter shows original order without ranking',
        (tester) async {
      final tasks = makeTasks(['Zebra', 'Apple', 'Mango']);
      final parentNamesMap = {
        1: ['Apple'], // Zebra under Apple
      };

      await tester.pumpWidget(buildDialog(
        candidates: tasks,
        parentNamesMap: parentNamesMap,
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // No filter typed — should be original order, no ranking applied
      expect(getDisplayedTaskNames(tester), ['Zebra', 'Apple', 'Mango']);
    });
  });

  group('TaskPickerDialog input limits', () {
    testWidgets('search field has maxLength of 500', (tester) async {
      final tasks = makeTasks(['Alpha']);
      await tester.pumpWidget(buildDialog(candidates: tasks));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.maxLength, 500);
    });
  });

  group('TaskPickerDialog headerAction', () {
    testWidgets('headerAction is shown when provided and no search filter',
        (tester) async {
      final tasks = makeTasks(['Alpha', 'Beta']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<Object>(
                  context: context,
                  builder: (_) => TaskPickerDialog(
                    candidates: tasks,
                    headerAction: const Text('Remove dependency'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Remove dependency'), findsOneWidget);
    });

    testWidgets('headerAction is hidden when search filter is active',
        (tester) async {
      final tasks = makeTasks(['Alpha', 'Beta']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<Object>(
                  context: context,
                  builder: (_) => TaskPickerDialog(
                    candidates: tasks,
                    headerAction: const Text('Remove dependency'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Remove dependency'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pumpAndSettle();

      expect(find.text('Remove dependency'), findsNothing);
    });

    testWidgets('headerAction is not shown when not provided',
        (tester) async {
      final tasks = makeTasks(['Alpha']);
      await tester.pumpWidget(buildDialog(candidates: tasks));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Only the task list and search, no header action
      expect(find.text('Remove dependency'), findsNothing);
    });

    testWidgets(
        'remove dependency headerAction with long name uses Expanded to prevent overflow',
        (tester) async {
      // Reproduces the exact widget structure from _addDependencyToTask
      // in task_list_screen.dart — the bug fix wraps Text in Expanded
      // inside a Row so long blocker names get ellipsis instead of overflow.
      final tasks = makeTasks(['Alpha', 'Beta']);
      const longBlockerName =
          'This is a very long blocker task name that would definitely '
          'overflow the row width in the dialog without proper text wrapping';

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final colorScheme = Theme.of(context).colorScheme;
              return ElevatedButton(
                onPressed: () {
                  showDialog<Object>(
                    context: context,
                    builder: (_) => TaskPickerDialog(
                      candidates: tasks,
                      title: 'Do "My Task" after...',
                      // Mirrors the exact structure from task_list_screen.dart
                      headerAction: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => Navigator.pop(context, 'remove'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 8),
                            child: Row(
                              children: [
                                Icon(Icons.link_off,
                                    size: 18, color: colorScheme.error),
                                const SizedBox(width: 8),
                                // Bug fix: Expanded prevents overflow
                                Expanded(
                                  child: Text(
                                    'Remove dependency on "$longBlockerName"',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: colorScheme.error),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Verify the remove dependency row is rendered
      expect(find.byIcon(Icons.link_off), findsOneWidget);
      final removeText = find.textContaining('Remove dependency on');
      expect(removeText, findsOneWidget);

      // Verify Text is wrapped in Expanded (the bug fix)
      final expandedAncestor = find.ancestor(
        of: removeText,
        matching: find.byType(Expanded),
      );
      expect(expandedAncestor, findsOneWidget,
          reason:
              'Text must be wrapped in Expanded to prevent overflow with long names');

      // Verify text has ellipsis overflow
      final textWidget = tester.widget<Text>(removeText);
      expect(textWidget.overflow, TextOverflow.ellipsis);
      expect(textWidget.maxLines, 1);

      // Verify no overflow errors were reported
      // (Flutter test framework automatically fails on layout overflow)
    });
  });

  group('TaskPickerDialog onCreateTask (create-from-search)', () {
    // Local builder that wires an opt-in onCreateTask callback. Captures the
    // query the button fires with so tests can assert on it.
    Widget buildWithCreate({
      required List<Task> candidates,
      required void Function(String query)? onCreateTask,
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
                    onCreateTask: onCreateTask,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
    }

    testWidgets('shows Create button when query matches nothing', (tester) async {
      await tester.pumpWidget(
        buildWithCreate(candidates: makeTasks(['Apple']), onCreateTask: (_) {}),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'buy milk');
      // Search filter is debounced by 200ms.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('No matching tasks'), findsOneWidget);
      expect(find.text('Create "buy milk"'), findsOneWidget);
    });

    testWidgets('tapping Create fires onCreateTask with the trimmed query',
        (tester) async {
      String? captured;
      await tester.pumpWidget(
        buildWithCreate(
          candidates: makeTasks(['Apple']),
          onCreateTask: (q) => captured = q,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Leading/trailing whitespace should be trimmed before creation.
      await tester.enterText(find.byType(TextField), '  buy milk  ');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create "buy milk"'));
      await tester.pumpAndSettle();

      expect(captured, 'buy milk');
    });

    testWidgets(
        'Create uses the live field text, not the stale debounced query',
        (tester) async {
      // CR-fix M-48 regression: type a name and let the 200ms debounce settle
      // so the "Create" button renders, then correct the text and tap Create
      // BEFORE the debounce refreshes _filter. The created task must be named
      // from the live field, not the earlier (stale) query the label still shows.
      String? captured;
      await tester.pumpWidget(
        buildWithCreate(
          candidates: makeTasks(['Apple']),
          onCreateTask: (q) => captured = q,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Buy milk');
      await tester.pump(const Duration(milliseconds: 250)); // debounce fires
      expect(find.text('Create "Buy milk"'), findsOneWidget);

      // Correct the text; tap within the 200ms window (no rebuild → label stale).
      await tester.enterText(find.byType(TextField), 'Buy milkshake');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Create "Buy milk"'));
      await tester.pumpAndSettle();

      expect(captured, 'Buy milkshake');
    });

    testWidgets('no Create button when onCreateTask is null (other pickers)',
        (tester) async {
      await tester.pumpWidget(
        buildWithCreate(candidates: makeTasks(['Apple']), onCreateTask: null),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'buy milk');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(find.text('No matching tasks'), findsOneWidget);
      expect(find.textContaining('Create'), findsNothing);
    });

    testWidgets('no Create button when query is blank', (tester) async {
      // No candidates → empty list, but with no query there is nothing to name
      // the new task, so the create affordance stays hidden.
      await tester.pumpWidget(
        buildWithCreate(candidates: const [], onCreateTask: (_) {}),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('No matching tasks'), findsOneWidget);
      expect(find.textContaining('Create'), findsNothing);
    });

    testWidgets('clearing the field removes the stale Create button immediately',
        (tester) async {
      // Bug fix: the flat filter is debounced 200ms, but clearing the field
      // must take effect at once — otherwise the "Create <old query>" button
      // lingers over an empty field for ~200ms and a fast tap creates a task
      // named after the deleted text.
      await tester.pumpWidget(
        buildWithCreate(candidates: makeTasks(['Apple']), onCreateTask: (_) {}),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 250)); // past debounce
      expect(find.text('Create "zzz"'), findsOneWidget);

      // Clear the field and pump only a single short frame — well under the
      // 200ms debounce. The Create button must already be gone.
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.textContaining('Create'), findsNothing);
      expect(find.text('Apple'), findsOneWidget); // full list restored
    });
  });
}
