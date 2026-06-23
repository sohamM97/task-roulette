import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/widgets/pick_task_for_today_dialog.dart';

import '../helpers/async_pump.dart';

/// Widget tests for [PickTaskForTodayDialog] — the manual-model "pick existing
/// task" picker that replaced the old auto-pick/reroll flow.
///
/// The dialog queries the real DB via the provider (getRootTasks/getChildren/
/// getAllLeafTasks/getParentNamesMap), so these use the sqflite-ffi NoIsolate
/// widget harness with the pumpAndLoad/pumpAsync pattern.
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
  });

  tearDown(() async {
    await db.reset();
  });

  /// Pumps a host with a button that opens the dialog, and captures the
  /// dialog's result into [resultHolder] when it pops.
  Widget buildHost({
    Set<int> excludeIds = const {},
    required List<Task?> resultHolder,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final r = await showDialog<Task>(
                context: context,
                builder: (_) => PickTaskForTodayDialog(
                  provider: provider,
                  excludeIds: excludeIds,
                ),
              );
              resultHolder.add(r);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('Open'));
    await pumpAsync(tester);
  }

  group('PickTaskForTodayDialog — browse', () {
    testWidgets('shows root tasks, hiding inbox tasks', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Groceries'));
        await db.insertTask(Task(name: 'Inbox item', isInbox: true));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      expect(find.text("Pin a task to Today’s 5"), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      // Inbox tasks are hidden at the root level.
      expect(find.text('Inbox item'), findsNothing);
    });

    testWidgets('hides tasks already in Today\'s 5 (excludeIds)',
        (tester) async {
      late int excludedId;
      await tester.runAsync(() async {
        excludedId = await db.insertTask(Task(name: 'Already pinned'));
        await db.insertTask(Task(name: 'Available'));
      });

      await pumpAndLoad(
          tester, buildHost(excludeIds: {excludedId}, resultHolder: []));
      await openDialog(tester);

      expect(find.text('Available'), findsOneWidget);
      expect(find.text('Already pinned'), findsNothing);
    });

    testWidgets('shows "No tasks here" when nothing to pin', (tester) async {
      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      expect(find.text('No tasks here'), findsOneWidget);
    });

    testWidgets('tapping a leaf returns it as the selection', (tester) async {
      final result = <Task?>[];
      late int leafId;
      await tester.runAsync(() async {
        leafId = await db.insertTask(Task(name: 'Leaf task'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: result));
      await openDialog(tester);

      await tester.tap(find.text('Leaf task'));
      await pumpAsync(tester);

      expect(result, hasLength(1));
      expect(result.first?.id, leafId);
    });

    testWidgets('tapping a non-leaf drills into its children', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final a = await db.insertTask(Task(name: 'Child A'));
        final b = await db.insertTask(Task(name: 'Child B'));
        await db.addRelationship(parentId, a);
        await db.addRelationship(parentId, b);
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      // Tapping the parent drills in (does NOT pop), revealing children.
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.text('Child A'), findsOneWidget);
      expect(find.text('Child B'), findsOneWidget);
      // Back button is shown when drilled in.
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('drilling in then tapping a child leaf returns the child',
        (tester) async {
      final result = <Task?>[];
      late int childId;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        childId = await db.insertTask(Task(name: 'Leaf child'));
        await db.addRelationship(parentId, childId);
      });

      await pumpAndLoad(tester, buildHost(resultHolder: result));
      await openDialog(tester);

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf child'));
      await pumpAsync(tester);

      expect(result, hasLength(1));
      expect(result.first?.id, childId);
    });

    testWidgets('back button returns from a drilled-in subtree',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final a = await db.insertTask(Task(name: 'Child A'));
        await db.addRelationship(parentId, a);
        await db.insertTask(Task(name: 'Sibling root'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      expect(find.text('Child A'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await pumpAsync(tester);

      // Back at root: siblings visible again, child gone.
      expect(find.text('Sibling root'), findsOneWidget);
      expect(find.text('Child A'), findsNothing);
    });

    testWidgets('Cancel pops with a null result', (tester) async {
      final result = <Task?>[];
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Some task'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: result));
      await openDialog(tester);

      await tester.tap(find.text('Cancel'));
      await pumpAsync(tester);

      expect(result, hasLength(1));
      expect(result.first, isNull);
    });

    testWidgets('"Show all N items" appears for more than 6 children',
        (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          await db.insertTask(Task(name: 'Root $i'));
        }
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      expect(find.text('Show all 8 items'), findsOneWidget);

      // Collapsed: only the first 6 children render.
      expect(find.text('Root 0'), findsOneWidget);
      expect(find.text('Root 6'), findsNothing);

      await tester.tap(find.text('Show all 8 items'));
      await pumpAsync(tester);

      // After expanding, the toggle is gone and the 7th child renders.
      expect(find.text('Show all 8 items'), findsNothing);
      expect(find.text('Root 6'), findsOneWidget);
    });
  });

  group('PickTaskForTodayDialog — search', () {
    testWidgets('typing filters to matching leaf tasks by name',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Buy milk'));
        await db.insertTask(Task(name: 'Walk dog'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'milk');
      await pumpAsync(tester);

      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text('Walk dog'), findsNothing);
    });

    testWidgets('search matches by parent name and shows "under" subtitle',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Kitchen'));
        final child = await db.insertTask(Task(name: 'Wash plates'));
        await db.addRelationship(parentId, child);
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      // Search by the parent's name — the leaf child should match.
      await tester.enterText(find.byType(TextField), 'Kitchen');
      await pumpAsync(tester);

      expect(find.text('Wash plates'), findsOneWidget);
      expect(find.textContaining('under Kitchen'), findsOneWidget);
    });

    testWidgets('search excludes tasks already in Today\'s 5', (tester) async {
      late int excludedId;
      await tester.runAsync(() async {
        excludedId = await db.insertTask(Task(name: 'Pinned milk'));
        await db.insertTask(Task(name: 'Free milk'));
      });

      await pumpAndLoad(
          tester, buildHost(excludeIds: {excludedId}, resultHolder: []));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'milk');
      await pumpAsync(tester);

      expect(find.text('Free milk'), findsOneWidget);
      expect(find.text('Pinned milk'), findsNothing);
    });

    testWidgets('search only returns leaves, not parents', (tester) async {
      await tester.runAsync(() async {
        // "Project alpha" is a parent (non-leaf); its child is a leaf.
        final parentId = await db.insertTask(Task(name: 'Project alpha'));
        final child = await db.insertTask(Task(name: 'alpha subtask'));
        await db.addRelationship(parentId, child);
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'alpha');
      await pumpAsync(tester);

      // The leaf child matches; the parent itself is not a pin target.
      expect(find.text('alpha subtask'), findsOneWidget);
      expect(find.text('Project alpha'), findsNothing);
    });

    testWidgets('shows "No matching tasks" when nothing matches',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Apple'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await pumpAsync(tester);

      expect(find.text('No matching tasks'), findsOneWidget);
    });

    testWidgets('clearing the search returns to the browse view',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Apple'));
        await db.insertTask(Task(name: 'Banana'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: []));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'Apple');
      await pumpAsync(tester);
      expect(find.text('Banana'), findsNothing);

      // Tap the clear (close) suffix icon.
      await tester.tap(find.byIcon(Icons.close));
      await pumpAsync(tester);

      // Browse view restored — both root tasks visible again.
      expect(find.text('Apple'), findsOneWidget);
      expect(find.text('Banana'), findsOneWidget);
    });

    testWidgets('tapping a search result returns it as the selection',
        (tester) async {
      final result = <Task?>[];
      late int leafId;
      await tester.runAsync(() async {
        leafId = await db.insertTask(Task(name: 'Searchable leaf'));
      });

      await pumpAndLoad(tester, buildHost(resultHolder: result));
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'Searchable');
      await pumpAsync(tester);
      await tester.tap(find.text('Searchable leaf'));
      await pumpAsync(tester);

      expect(result, hasLength(1));
      expect(result.first?.id, leafId);
    });
  });
}
