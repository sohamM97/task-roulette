import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/async_pump.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/widgets/triage_dialog.dart';

void main() {
  late DatabaseHelper db;
  late TaskProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    db = DatabaseHelper();
    await db.reset();
    await db.database;
    provider = TaskProvider();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.reset();
  });

  TriageResult? dialogResult;

  Widget buildTestWidget(Task task, {int remainingCount = 0}) {
    dialogResult = null;
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            // Show the dialog immediately on build
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              dialogResult = await showDialog<TriageResult>(
                context: context,
                builder: (_) => TriageDialog(
                  task: task,
                  provider: provider,
                  remainingCount: remainingCount,
                ),
              );
            });
            return const SizedBox();
          },
        ),
      ),
    );
  }

  group('TriageDialog', () {
    testWidgets('shows dialog title with task name', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Buy groceries', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      expect(find.text('File "Buy groceries"'), findsOneWidget);
    });

    testWidgets('shows remaining count badge when > 0', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Task A', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task, remainingCount: 3));

      expect(find.text('+3 more'), findsOneWidget);
    });

    testWidgets('does not show remaining count when 0', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Task A', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task, remainingCount: 0));

      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('shows search bar', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Task A', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows "Keep at top level" option in suggestions phase',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Create a potential parent so suggestions phase shows
        await db.insertTask(Task(name: 'Groceries'));
        final id = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      expect(find.text('Keep at top level'), findsOneWidget);
      expect(find.byIcon(Icons.vertical_align_top), findsOneWidget);
    });

    testWidgets('tapping "Keep at top level" returns keepAtTopLevel result',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Groceries'));
        final id = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.tap(find.text('Keep at top level'));
      await pumpAsync(tester);

      expect(dialogResult, isNotNull);
      expect(dialogResult!.keepAtTopLevel, isTrue);
      expect(dialogResult!.parent, isNull);
    });

    testWidgets('shows suggestion cards with parent context', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Create parent and child so suggestions have context
        final parentId = await db.insertTask(Task(name: 'Shopping'));
        final childId = await db.insertTask(Task(name: 'Buy bread'));
        await db.addRelationship(parentId, childId);
        // Create the inbox task with a name that matches
        final id = await db.insertTask(Task(name: 'Buy eggs', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Should show "Suggested" label
      expect(find.text('Suggested'), findsOneWidget);
      // Shopping should be suggested (name similarity + sibling match)
      expect(find.text('Shopping'), findsOneWidget);
    });

    testWidgets('tapping a suggestion returns parent result', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Shopping'));
        final childId = await db.insertTask(Task(name: 'Buy bread'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'Buy eggs', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Tap the Shopping suggestion
      await tester.tap(find.text('Shopping'));
      await pumpAsync(tester);

      expect(dialogResult, isNotNull);
      expect(dialogResult!.parent, isNotNull);
      expect(dialogResult!.parent!.name, 'Shopping');
      expect(dialogResult!.keepAtTopLevel, isFalse);
    });

    testWidgets('falls back to browse when no suggestions', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Only inbox task, no potential parents → suggestions empty → browse mode
        final id = await db.insertTask(Task(name: 'zzz completely unique', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Should show Suggestions button (meaning we're in browse mode)
      expect(find.text('Suggestions'), findsOneWidget);
    });

    testWidgets('Browse button switches to browse phase', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Create matching names so suggestions are generated (stays in suggestions phase)
        final parentId = await db.insertTask(Task(name: 'Shopping'));
        final childId = await db.insertTask(Task(name: 'Buy bread'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Should start in suggestions phase, showing Browse button
      await tester.tap(find.text('Browse'));
      await pumpAsync(tester);

      // In browse phase, should show Suggestions button instead
      expect(find.text('Suggestions'), findsOneWidget);
      // Keep at top level should be visible in browse at root
      expect(find.text('Keep at top level'), findsOneWidget);
    });

    testWidgets('browse shows root tasks excluding self and inbox tasks',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Use names that don't match the inbox task so suggestions are empty
        // → auto-switches to browse mode
        await db.insertTask(Task(name: 'Work'));
        await db.insertTask(Task(name: 'Personal'));
        await db.insertTask(Task(name: 'Other inbox', isInbox: true));
        final id = await db.insertTask(
            Task(name: 'zzz unique thing', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // No matching suggestions → auto-switched to browse mode
      // Should show Work and Personal but not the inbox task or self
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Other inbox'), findsNothing);
      expect(find.text('zzz unique thing'), findsNothing);
    });

    testWidgets('browse into a task shows its children and back button',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Work'));
        await db.insertTask(Task(name: 'Project A'));
        final childId = await db.insertTask(Task(name: 'Task under work'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'New thing', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Switch to browse
      await tester.tap(find.text('Browse'));
      await pumpAsync(tester);

      // Tap into Work (the task card, not the check button)
      await tester.tap(find.text('Work'));
      await pumpAsync(tester);

      // Should show child and back button
      expect(find.text('Task under work'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      // Should show "Here" button to file at current level
      expect(find.text('Here'), findsOneWidget);
    });

    testWidgets('browse back button returns to parent level', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Work'));
        final childId = await db.insertTask(Task(name: 'Sub'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'New', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Go to browse, then into Work
      await tester.tap(find.text('Browse'));
      await pumpAsync(tester);
      await tester.tap(find.text('Work'));
      await pumpAsync(tester);

      // Now go back
      await tester.tap(find.byIcon(Icons.arrow_back));
      await pumpAsync(tester);

      // Should see root tasks again
      expect(find.text('Work'), findsOneWidget);
    });

    testWidgets('browse "Here" button files under current parent',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Work'));
        final childId = await db.insertTask(Task(name: 'Sub'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'New', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.tap(find.text('Browse'));
      await pumpAsync(tester);
      await tester.tap(find.text('Work'));
      await pumpAsync(tester);

      // Tap "Here" to file under Work
      await tester.tap(find.text('Here'));
      await pumpAsync(tester);

      expect(dialogResult, isNotNull);
      expect(dialogResult!.parent!.name, 'Work');
    });

    testWidgets('browse check button files directly under that task',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Work'));
        final childId = await db.insertTask(Task(name: 'Sub'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'New', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.tap(find.text('Browse'));
      await pumpAsync(tester);

      // Tap the check_circle_outline icon next to Work
      await tester.tap(find.byIcon(Icons.check_circle_outline).first);
      await pumpAsync(tester);

      expect(dialogResult, isNotNull);
      expect(dialogResult!.parent!.name, 'Work');
    });

    testWidgets('search filters tasks by name', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Groceries'));
        await db.insertTask(Task(name: 'Work projects'));
        await db.insertTask(Task(name: 'Personal stuff'));
        final id = await db.insertTask(Task(name: 'New item', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Type in search
      await tester.enterText(find.byType(TextField), 'groc');
      await pumpAsync(tester);

      // Should show Groceries, not others
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Work projects'), findsNothing);
      expect(find.text('Personal stuff'), findsNothing);
    });

    testWidgets('search shows "No matching tasks" for no results',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Groceries'));
        final id = await db.insertTask(Task(name: 'New item', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.enterText(find.byType(TextField), 'xyznonexistent');
      await pumpAsync(tester);

      expect(find.text('No matching tasks'), findsOneWidget);
    });

    testWidgets('search clear button resets search', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Groceries'));
        final id = await db.insertTask(Task(name: 'New item', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.enterText(find.byType(TextField), 'groc');
      await pumpAsync(tester);

      // Clear button should appear
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await pumpAsync(tester);

      // Search should be cleared — back to suggestions/browse view
      // (search text field should be empty)
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('tapping search result returns parent result', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Shopping'));
        final id = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      await tester.enterText(find.byType(TextField), 'shop');
      await pumpAsync(tester);

      await tester.tap(find.text('Shopping'));
      await pumpAsync(tester);

      expect(dialogResult, isNotNull);
      expect(dialogResult!.parent!.name, 'Shopping');
    });

    testWidgets('search filters by parent name too', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Cooking'));
        final childId = await db.insertTask(Task(name: 'Recipes'));
        await db.addRelationship(parentId, childId);
        final id = await db.insertTask(Task(name: 'Zzzz', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Search for the parent name "Cooking" — should find child "Recipes" too
      await tester.enterText(find.byType(TextField), 'cooking');
      await pumpAsync(tester);

      expect(find.text('Recipes'), findsOneWidget);
    });

    testWidgets('browse shows "No sub-tasks here" for empty folders',
        (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // A leaf task (no children) — use non-matching name so auto-browse
        await db.insertTask(Task(name: 'Empty folder'));
        final id = await db.insertTask(
            Task(name: 'zzz unique xyz', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Auto-switched to browse — navigate into the empty folder
      await tester.tap(find.text('Empty folder'));
      await pumpAsync(tester);

      expect(find.text('No sub-tasks here'), findsOneWidget);
    });

    testWidgets('browse "Show all" appears when > 6 items', (tester) async {
      late Task task;
      await tester.runAsync(() async {
        // Create 8 root tasks — use non-matching name so auto-browse
        for (int i = 1; i <= 8; i++) {
          await db.insertTask(Task(name: 'Category $i'));
        }
        final id = await db.insertTask(
            Task(name: 'zzz unique xyz', isInbox: true));
        task = (await db.getTaskById(id))!;
      });
      await pumpAndLoad(tester, buildTestWidget(task));

      // Auto-switched to browse — should show "Show all 8 items" button
      expect(find.text('Show all 8 items'), findsOneWidget);
    });
  });

  group('TriageResult', () {
    test('default keepAtTopLevel is false', () {
      const result = TriageResult();
      expect(result.keepAtTopLevel, isFalse);
      expect(result.parent, isNull);
    });

    test('with parent sets parent', () {
      final task = Task(id: 1, name: 'Parent');
      final result = TriageResult(parent: task);
      expect(result.parent, task);
      expect(result.keepAtTopLevel, isFalse);
    });

    test('keepAtTopLevel constructor', () {
      const result = TriageResult(keepAtTopLevel: true);
      expect(result.keepAtTopLevel, isTrue);
      expect(result.parent, isNull);
    });
  });
}
