import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/async_pump.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/providers/theme_provider.dart';
import 'package:task_roulette/screens/starred_screen.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/utils/display_utils.dart' show todayDateKey;

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

  Task? navigatedTask;

  Widget buildTestWidget() {
    navigatedTask = null;
    final authProvider = AuthProvider();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: provider),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: authProvider),
        Provider<SyncService>(
          create: (_) => SyncService(authProvider),
          dispose: (_, sync) => sync.dispose(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: StarredScreen(
            onNavigateToTask: (task) => navigatedTask = task,
          ),
        ),
      ),
    );
  }

  /// Helper to create a task and star it.
  Future<int> createStarredTask(String name, {int? parentId}) async {
    final id = await db.insertTask(Task(name: name));
    if (parentId != null) {
      await db.addRelationship(parentId, id);
    }
    await db.updateTaskStarred(id, true, starOrder: id);
    return id;
  }

  group('StarredScreen', () {
    testWidgets('shows empty state when no starred tasks', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('No starred tasks yet'), findsOneWidget);
      expect(find.text('Long-press any task and tap Star\nto bookmark it here'),
          findsOneWidget);
    });

    testWidgets('displays starred task card', (tester) async {
      await tester.runAsync(() => createStarredTask('Guitar practice'));

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Guitar practice'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('displays multiple starred tasks in order', (tester) async {
      await tester.runAsync(() async {
        await createStarredTask('Task A');
        await createStarredTask('Task B');
        await createStarredTask('Task C');
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Task A'), findsOneWidget);
      expect(find.text('Task B'), findsOneWidget);
      expect(find.text('Task C'), findsOneWidget);
    });

    testWidgets('shows sub-task count in subtitle', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        await db.insertTask(Task(name: 'Child 1'));
        await db.addRelationship(parentId, 2);
        await db.insertTask(Task(name: 'Child 2'));
        await db.addRelationship(parentId, 3);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('2 sub-tasks'), findsOneWidget);
    });

    testWidgets('shows "In progress" for started tasks', (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Started task');
        await db.startTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.textContaining('In progress'), findsOneWidget);
    });

    testWidgets('shows tree preview with children', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Music');
        final child1 = await db.insertTask(Task(name: 'Guitar'));
        await db.addRelationship(parentId, child1);
        final child2 = await db.insertTask(Task(name: 'Piano'));
        await db.addRelationship(parentId, child2);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Guitar'), findsOneWidget);
      expect(find.text('Piano'), findsOneWidget);
    });

    // CR-fix I-53 regression: grandchildren in the tree-preview card must be
    // styled via the shared childTextStyle (priority tint / blocked dimming),
    // same as the expanded dialog. Before the fix they used one hardcoded
    // grandchild colour, so a high-priority grandchild looked identical to a
    // normal one in the card while being tinted in the dialog (DRY violation).
    testWidgets('high-priority grandchild is tinted in tree preview (I-53)',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Project');
        final child = await db.insertTask(Task(name: 'Phase 1'));
        await db.addRelationship(parentId, child);
        final gcNormal =
            await db.insertTask(Task(name: 'GC Normal', priority: 0));
        await db.addRelationship(child, gcNormal);
        final gcHigh = await db.insertTask(Task(name: 'GC High', priority: 2));
        await db.addRelationship(child, gcHigh);
      });

      await pumpAndLoad(tester, buildTestWidget());

      final normalStyle = tester.widget<Text>(find.text('GC Normal')).style!;
      final highStyle = tester.widget<Text>(find.text('GC High')).style!;
      // The high-priority grandchild must render in a different colour than the
      // normal one — proving childTextStyle's priority tint reaches this depth.
      expect(highStyle.color, isNot(normalStyle.color));
    });

    // CR-fix I-53 (second half): the card must also DIM a blocked grandchild,
    // which requires including grandchild ids in the _blockedInfo fetch (only
    // direct-child ids were fetched before). Before the fix a blocked
    // grandchild rendered full-emphasis in the card but dimmed in the dialog.
    testWidgets('blocked grandchild is dimmed in tree preview (I-53)',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Project');
        final child = await db.insertTask(Task(name: 'Phase 1'));
        await db.addRelationship(parentId, child);
        final gcFree = await db.insertTask(Task(name: 'GC Free'));
        await db.addRelationship(child, gcFree);
        final gcBlocked = await db.insertTask(Task(name: 'GC Blocked'));
        await db.addRelationship(child, gcBlocked);
        // Block gcBlocked on an incomplete blocker.
        final blocker = await db.insertTask(Task(name: 'Blocker'));
        await db.addDependency(gcBlocked, blocker);
      });

      await pumpAndLoad(tester, buildTestWidget());

      final freeStyle = tester.widget<Text>(find.text('GC Free')).style!;
      final blockedStyle = tester.widget<Text>(find.text('GC Blocked')).style!;
      // Blocked style dims to alpha 100; the free grandchild keeps the fuller
      // grandchild colour. The blocked one must be visibly more transparent.
      expect(blockedStyle.color!.a, lessThan(freeStyle.color!.a));
      expect(blockedStyle.color!.a, closeTo(100 / 255, 0.01));
    });

    testWidgets('shows badge count in app bar', (tester) async {
      await tester.runAsync(() async {
        await createStarredTask('Task 1');
        await createStarredTask('Task 2');
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('long-press navigates to task', (tester) async {
      await tester.runAsync(() => createStarredTask('Navigate me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.longPress(find.text('Navigate me'));
      await tester.pump();

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Navigate me');
    });

    testWidgets('shows drag handle for reordering', (tester) async {
      await tester.runAsync(() => createStarredTask('Draggable'));

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.drag_indicator_rounded), findsOneWidget);
    });
  });

  group('StarredScreen - Tap expanded view', () {
    testWidgets('tap leaf starred task opens expanded dialog (unified behavior)',
        (tester) async {
      await tester.runAsync(() => createStarredTask('Guitar'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Guitar'));
      await pumpAsync(tester);

      // Behavior change: leaf (childless) starred tasks now open the expanded
      // dialog like non-leaf ones, rather than navigating to All Tasks — so a
      // subtask can be added inline via the dialog's "+" button. Long-press is
      // the remaining path to All Tasks. The dialog header shows the name, so
      // it appears twice (card + header); tapping must NOT navigate.
      expect(navigatedTask, isNull);
      expect(find.text('Guitar'), findsNWidgets(2));
      expect(find.text('No sub-tasks'), findsOneWidget);
    });

    testWidgets('tap non-leaf starred task opens expanded dialog', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Guitar');
        await db.insertTask(Task(name: 'Fingerpicking')).then(
          (childId) => db.addRelationship(parentId, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Guitar').first);
      await pumpAsync(tester);

      // Dialog should show the task name in the header
      // Original card has one, dialog header has another
      expect(find.text('Guitar'), findsNWidgets(2));
    });

    testWidgets('expanded view shows direct children, expands on tap',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Music');
        final child = await db.insertTask(Task(name: 'Guitar'));
        await db.addRelationship(parentId, child);
        final grandchild = await db.insertTask(Task(name: 'Fingerpicking'));
        await db.addRelationship(child, grandchild);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Music').first);
      await pumpAsync(tester);

      // Direct child visible, grandchild hidden (collapsed)
      expect(find.text('Guitar'), findsNWidgets(2)); // card preview + dialog
      expect(find.text('Fingerpicking'), findsOneWidget); // card preview only

      // Tap Guitar row to expand (shows chevron + child count)
      await tester.tap(find.text('Guitar').last);
      await pumpAsync(tester);

      // Now grandchild is visible
      expect(find.text('Fingerpicking'), findsNWidgets(2));
    });

    testWidgets('collapse hides grandchildren', (tester) async {
      await tester.runAsync(() async {
        final root = await createStarredTask('Root');
        final child = await db.insertTask(Task(name: 'Middle'));
        await db.addRelationship(root, child);
        final grandchild = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(child, grandchild);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Root').first);
      await pumpAsync(tester);

      // Tap Middle row to expand and reveal Leaf
      await tester.tap(find.text('Middle').last);
      await pumpAsync(tester);
      expect(find.text('Leaf'), findsNWidgets(2)); // preview + dialog

      // Tap Middle again to collapse
      await tester.tap(find.text('Middle').last);
      await pumpAsync(tester);
      // Leaf only in card preview now, not in dialog
      expect(find.text('Leaf'), findsOneWidget);
    });

    testWidgets('long-press leaf starred task also navigates', (tester) async {
      await tester.runAsync(() => createStarredTask('Leaf task'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.longPress(find.text('Leaf task'));
      await pumpAsync(tester);

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Leaf task');
    });

    testWidgets('star icon in expanded view opens confirmation dialog',
        (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Confirm me');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Confirm me').first);
      await pumpAsync(tester);

      // Tap the star icon button in the dialog header
      final starIcons = find.byIcon(Icons.star_rounded);
      await tester.tap(starIcons.last);
      await tester.pump();

      expect(find.text('Remove from starred?'), findsOneWidget);
      expect(find.text('Are you sure you want to unstar "Confirm me"?'),
          findsOneWidget);
    });

    testWidgets('cancel in confirmation dialog keeps task starred',
        (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Keep me');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Keep me').first);
      await pumpAsync(tester);

      // Tap star to trigger confirmation
      await tester.tap(find.byIcon(Icons.star_rounded).last);
      await tester.pump();

      // Cancel
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      // Confirmation dismissed, expanded view still open
      expect(find.text('Remove from starred?'), findsNothing);
    });

    testWidgets('confirm unstar removes task and shows undo snackbar',
        (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Remove me');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Remove me').first);
      await pumpAsync(tester);

      // Tap star to trigger confirmation
      await tester.tap(find.byIcon(Icons.star_rounded).last);
      await tester.pump();

      // Confirm removal
      await tester.tap(find.text('Remove'));
      await pumpAsync(tester);

      // Snackbar with undo
      expect(find.text('Unstarred "Remove me"'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('undo in snackbar re-stars the task', (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Undo me');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Undo me').first);
      await pumpAsync(tester);

      // Unstar flow
      await tester.tap(find.byIcon(Icons.star_rounded).last);
      await tester.pump();
      await tester.tap(find.text('Remove'));
      await pumpAsync(tester);

      // Tap undo (warnIfMissed: false — snackbar renders at bottom edge of
      // test viewport, but the tap still registers)
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      // Task should be back
      expect(find.text('Undo me'), findsOneWidget);
    });

    testWidgets('long-press tree node navigates to that task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        final child = await db.insertTask(Task(name: 'Child node'));
        await db.addRelationship(parentId, child);
        // Give child a sub-task so it's not a leaf (leaves navigate on tap)
        final grandchild = await db.insertTask(Task(name: 'Grandchild'));
        await db.addRelationship(child, grandchild);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Long-press the non-leaf node to navigate
      await tester.longPress(find.text('Child node').last);
      await tester.pump();

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Child node');
    });

    testWidgets('tap leaf node navigates directly', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        final leaf = await db.insertTask(Task(name: 'Leaf node'));
        await db.addRelationship(parentId, leaf);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Tap the leaf node — should navigate directly (no expand)
      await tester.tap(find.text('Leaf node').last);
      await tester.pump();

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Leaf node');
    });

    testWidgets('dismiss dialog by tapping outside', (tester) async {
      await tester.runAsync(() => createStarredTask('Dismiss me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Dismiss me'));
      await pumpAsync(tester);

      // Tap outside the dialog to dismiss
      await tester.tapAt(const Offset(10, 10));
      await pumpAsync(tester);

      // Dialog dismissed — only card text remains
      expect(find.text('Dismiss me'), findsOneWidget);
    });

    testWidgets('shows child count badge on expandable nodes', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        final child = await db.insertTask(Task(name: 'Expandable'));
        await db.addRelationship(parentId, child);
        // Give the child 3 sub-tasks so badge shows "3"
        for (var i = 0; i < 3; i++) {
          final gc = await db.insertTask(Task(name: 'GC $i'));
          await db.addRelationship(child, gc);
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Badge on "Expandable" should show "3"
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('leaf nodes do not show chevron', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        // Create a leaf child (no sub-tasks)
        final leaf = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(parentId, leaf);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // No chevron icons — the only child is a leaf
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    });

    testWidgets('navigate icon shown in dialog header', (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Header task');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Header task').first);
      await pumpAsync(tester);

      expect(find.byIcon(Icons.open_in_new_rounded), findsAtLeastNWidgets(1));
    });

    testWidgets('header navigate icon goes to task', (tester) async {
      await tester.runAsync(() async {
        final id = await createStarredTask('Go here');
        await db.insertTask(Task(name: 'Sub')).then(
          (childId) => db.addRelationship(id, childId),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Go here').first);
      await pumpAsync(tester);

      // Tap the navigate icon in the header (first one)
      await tester.tap(find.byIcon(Icons.open_in_new_rounded).first);
      await tester.pump();

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Go here');
    });

    testWidgets('only the header carries a navigate icon', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        final leaf = await db.insertTask(Task(name: 'My leaf'));
        await db.addRelationship(parentId, leaf);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Leaf rows have no ↗ of their own — the whole row body navigates, and
      // dropping the icon frees the width the trailing "+" needs. Only the
      // dialog header keeps a "Go to task" arrow.
      expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
      expect(find.byTooltip('Go to task'), findsOneWidget);
    });
  });

  group('StarredScreen - Add subtask FAB', () {
    // [Mechanism] The "+" FAB in the expanded dialog opens AddTaskDialog.
    testWidgets('FAB opens the AddTaskDialog', (tester) async {
      await tester.runAsync(() => createStarredTask('Project'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      // Tap the add FAB.
      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      expect(find.text('Add Task'), findsOneWidget);
    });

    // [Mechanism] The "+" FAB creates a subtask of the starred task.
    testWidgets('FAB creates a subtask of the starred task', (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      await tester.enterText(find.byType(TextField).first, 'New subtask');
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      // Persisted as a child of the starred task.
      final children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children!.map((t) => t.name), contains('New subtask'));
      // And surfaced in the expanded dialog tree.
      expect(find.text('New subtask'), findsOneWidget);
    });

    // [Regression] Guards the "add multiple did nothing" bug — the brain-dump
    // path from the Starred dialog must actually create the tasks AND parent
    // them under the starred card (previously this produced no subtasks).
    testWidgets('FAB "Add multiple" brain-dump creates multiple subtasks',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      // Switch to brain dump mode.
      await tester.tap(find.text('Add multiple'));
      await pumpAsync(tester);
      expect(find.text('Brain dump'), findsOneWidget);

      // Enter three lines.
      await tester.enterText(
          find.byType(TextField).first, 'Sub A\nSub B\nSub C');
      await pumpAsync(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Add 3'));
      });
      await pumpAsync(tester);

      // All three persisted as children of the starred task.
      final children = await tester.runAsync(() => db.getChildren(starredId));
      final names = children!.map((t) => t.name).toSet();
      expect(names, containsAll(['Sub A', 'Sub B', 'Sub C']));
      expect(children, hasLength(3));
    });

    // [Edge case] Cancelling the AddTaskDialog from the FAB creates nothing.
    testWidgets('cancelling the FAB dialog adds no subtask', (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      await tester.tap(find.text('Cancel'));
      await pumpAsync(tester);

      final children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children, isEmpty);
    });

    // [Mechanism] When the starred task is pinned in Today's 5, adding a
    // subtask shows the "this task is pinned" warning, and on confirm the pin
    // transfers to the new child (parent slot is replaced).
    testWidgets('pinned starred task warns but does NOT transfer pin to subtask',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Pinned project');
        // Put the starred task into Today's 5 and pin it.
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [starredId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {starredId},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Pinned project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      // Pinned warning appears first, now phrased as a drop (not a replace).
      expect(find.text('This task is pinned'), findsOneWidget);
      expect(find.textContaining('drop out of'), findsOneWidget);
      await tester.tap(find.text('Add anyway'));
      await pumpAsync(tester);

      // Then the AddTaskDialog.
      expect(find.text('Add Task'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Child task');
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      // Manual model: NO pin transfer. AddTaskFlow leaves Today's 5 state
      // untouched — the new child is not auto-pinned. The now-non-leaf parent
      // drops out of Today's 5 only when the Today's 5 screen next refreshes
      // (filtered by leaf status there; see todays_five_screen_test), so at the
      // DB layer the parent's pin is still present immediately after the add.
      final state =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      final children = await tester.runAsync(() => db.getChildren(starredId));
      final childId = children!.firstWhere((t) => t.name == 'Child task').id;
      expect(state!.pinnedIds, isNot(contains(childId)));
      expect(state.pinnedIds, {starredId});
      expect(state.taskIds, [starredId]);
    });

    // [Baseline] Unpinned starred task adds a subtask with no warning.
    testWidgets('unpinned starred task shows no pin warning', (tester) async {
      await tester.runAsync(() => createStarredTask('Plain project'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      // No pinned warning — straight to AddTaskDialog.
      expect(find.text('This task is pinned'), findsNothing);
      expect(find.text('Add Task'), findsOneWidget);
    });

    // [Mechanism] The subtask add dialog now offers a "Pin for today" toggle
    // (so a new subtask can go straight into Today's 5) but NO Inbox toggle
    // (subtasks aren't root-level) — mirrors the All Tasks drill-in flow.
    testWidgets('subtask dialog shows "Pin for today" toggle, no Inbox toggle',
        (tester) async {
      await tester.runAsync(() => createStarredTask('Plain project'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      expect(find.text('Pin for today'), findsOneWidget);
      expect(find.text('Inbox'), findsNothing);
    });

    // [Mechanism] Toggling "Pin for today" ON when adding a subtask actually
    // pins the new subtask into Today's 5.
    testWidgets('toggling "Pin for today" pins the new subtask into Today\'s 5',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Plain project');
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      await tester.enterText(find.byType(TextField).first, 'Pinned child');
      // Turn the pin toggle on, then add.
      await tester.tap(find.text('Pin for today'));
      await pumpAsync(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      final state =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      final children = await tester.runAsync(() => db.getChildren(starredId));
      final childId =
          children!.firstWhere((t) => t.name == 'Pinned child').id;
      expect(state!.pinnedIds, contains(childId));
      expect(state.taskIds, contains(childId));
    });

    // [Edge case] When the starred task is ITSELF pinned in Today's 5, the pin
    // toggle is hidden — adding a subtask makes the parent a non-leaf so it
    // drops out anyway (mirrors task_list_screen._runAddFlow). The user still
    // gets the "this task is pinned" warning first.
    testWidgets('pinned starred parent hides the "Pin for today" toggle',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Pinned project');
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [starredId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {starredId},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Pinned project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      // Clear the pinned warning first.
      expect(find.text('This task is pinned'), findsOneWidget);
      await tester.tap(find.text('Add anyway'));
      await pumpAsync(tester);

      // Dialog is open but the pin toggle is suppressed.
      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Pin for today'), findsNothing);
    });

    // [Edge case] When Today's 5 is already full (5 pinned), the pin toggle is
    // hidden — there's no slot to pin the new subtask into. The starred parent
    // here is NOT one of the pinned five, so fullness is the only reason.
    testWidgets('full Today\'s 5 hides the "Pin for today" toggle',
        (tester) async {
      await tester.runAsync(() async {
        await createStarredTask('Plain project');
        // Pin five unrelated tasks to fill Today's 5.
        final ids = <int>[];
        for (var i = 0; i < 5; i++) {
          ids.add(await db.insertTask(Task(name: 'Filler $i')));
        }
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: ids,
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: ids.toSet(),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);

      // No warning (parent isn't pinned), dialog open, but no pin toggle.
      expect(find.text('This task is pinned'), findsNothing);
      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Pin for today'), findsNothing);
    });

    // [Regression] Pin-state must refresh WITHIN the expanded dialog across
    // consecutive adds. Start with 4 pinned fillers (one free slot), so the
    // pin toggle shows on the first add. Pinning the new subtask fills Today's
    // 5 to 5; on the SECOND add the toggle must be gone. Guards the
    // `_reloadAfterAdd` -> `_loadTodays5PinState` refresh + the
    // `onTodaysFiveChanged` count update — without them `_todays5PinnedCount`
    // stays stale at 4 and the toggle would wrongly reappear.
    testWidgets(
        'pin toggle disappears on the next add once pinning fills Today\'s 5',
        (tester) async {
      await tester.runAsync(() async {
        await createStarredTask('Plain project');
        // Fill 4 of 5 Today's 5 slots with unrelated tasks (one slot free).
        final ids = <int>[];
        for (var i = 0; i < 4; i++) {
          ids.add(await db.insertTask(Task(name: 'Filler $i')));
        }
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: ids,
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: ids.toSet(),
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain project'));
      await pumpAsync(tester);

      // First add: free slot exists, so the toggle is offered. Pin the subtask.
      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);
      expect(find.text('Pin for today'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'First child');
      await tester.tap(find.text('Pin for today'));
      await pumpAsync(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      // Today's 5 is now full (4 fillers + pinned subtask = 5).
      final state =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(state!.pinnedIds.length, 5);

      // Second add within the same dialog: no free slot, toggle must be gone.
      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);
      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Pin for today'), findsNothing);
    });
  });

  group('StarredScreen - screen-level Add task FAB', () {
    // [Mechanism] The screen "+" FAB opens AddTaskDialog with the Inbox toggle
    // (root-level add), shown even on the empty state.
    testWidgets('FAB on empty state opens AddTaskDialog with Inbox toggle',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      // Empty state still shows the add FAB.
      expect(find.text('No starred tasks yet'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);

      expect(find.text('Add Task'), findsOneWidget);
      // Inbox toggle is shown (root-level add) and defaults on.
      expect(find.text('Inbox'), findsOneWidget);
    });

    // [Regression] On an empty day (no Today's 5 yet) the Pin toggle must still
    // appear — the old `taskIds.isNotEmpty` gate hid it, so pinning the first
    // task of the day from Starred was impossible.
    testWidgets('FAB shows Pin toggle on an empty day', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);

      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Pin'), findsOneWidget);
    });

    // [Mechanism] Adding via the screen FAB creates an auto-starred ROOT task
    // (so it lands on the Starred list, not nested under any task).
    testWidgets('FAB creates an auto-starred root task', (tester) async {
      await tester.runAsync(() => createStarredTask('Existing'));

      await pumpAndLoad(tester, buildTestWidget());

      // The populated screen has exactly one (screen-level) FAB.
      expect(find.byType(FloatingActionButton), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);

      await tester.enterText(find.byType(TextField).first, 'Brand new starred');
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      // Persisted as an auto-starred, root-level task (DB is source of truth;
      // screen-rebuild assertions are timing-flaky under FakeAsync).
      final created = await tester.runAsync(() async {
        final all = await db.getAllTasks();
        return all.firstWhere((t) => t.name == 'Brand new starred');
      });
      expect(created!.isStarred, isTrue,
          reason: 'screen FAB auto-stars new tasks');
      final starred = await tester.runAsync(() => provider.getStarredTasks());
      expect(starred!.any((t) => t.id == created.id), isTrue);
      final parents =
          await tester.runAsync(() => provider.getParentIds(created.id!));
      expect(parents, isEmpty,
          reason: 'screen FAB must add at root, not under any task');
    });

    // [Regression] Same dropped-Inbox-toggle bug as the All Tasks "+" FAB, but
    // through the Starred screen's own AddTaskFlow (a different addBatch closure
    // — isStarred + atRoot). Before: turning Inbox OFF and tapping "Add
    // multiple" reopened the brain dump with Inbox back ON, so the whole batch
    // was filed into the Inbox against the user's choice. After: the batch lands
    // as plain starred root tasks.
    testWidgets('screen FAB: Inbox OFF survives "Add multiple"',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);
      expect(find.text('Inbox'), findsOneWidget);

      // Turn Inbox OFF, then switch to the brain dump.
      await tester.tap(find.text('Inbox'));
      await pumpAsync(tester);
      await tester.tap(find.text('Add multiple'));
      await pumpAsync(tester);
      expect(find.text('Brain dump'), findsOneWidget);

      await tester.enterText(
          find.byType(TextField).first, 'Starred one\nStarred two');
      await pumpAsync(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Add 2'));
      });
      await pumpAsync(tester);

      final batch = await tester.runAsync(() async {
        final all = await db.getAllTasks();
        return all.where((t) => t.name.startsWith('Starred ')).toList();
      });
      expect(batch, hasLength(2), reason: 'both lines created');
      for (final t in batch!) {
        expect(t.isInbox, isFalse,
            reason: '"${t.name}" must honour the Inbox-OFF choice');
        expect(t.isStarred, isTrue,
            reason: 'screen FAB auto-stars the batch too');
      }
    });
  });

  group('StarredScreen - search', () {
    /// Types into the picker's search field and lets its 200ms debounce fire.
    /// pumpAsync alone pumps without advancing the fake clock, so the debounce
    /// Timer would never run and the filter would stay stale.
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pump(const Duration(milliseconds: 300));
      await pumpAsync(tester);
    }

    // [Mechanism] The app bar search icon opens the shared global search
    // picker — the same "Search tasks" dialog the All Tasks tab opens.
    testWidgets('app bar search icon opens the global search dialog',
        (tester) async {
      await tester.runAsync(() => createStarredTask('Guitar practice'));
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      expect(find.text('Search tasks'), findsOneWidget);
    });

    // [Mechanism] Search spans EVERY task, not just starred ones — the whole
    // point of putting it on this tab. Picking a result hands it to
    // onNavigateToTask (AppShell drills in + slides to the All Tasks tab).
    testWidgets('picking an unstarred result navigates to it', (tester) async {
      await tester.runAsync(() async {
        await createStarredTask('Guitar practice');
        await db.insertTask(Task(name: 'Buy strings'));
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      await search(tester, 'strings');

      await tester.tap(find.text('Buy strings').last);
      await pumpAsync(tester);

      expect(navigatedTask, isNotNull,
          reason: 'a search result must open in the All Tasks tab');
      expect(navigatedTask!.name, 'Buy strings');
    });

    // [Mechanism] Empty search → "Create ..." routes into the shared root add
    // flow with the query pre-filled and the Inbox toggle shown.
    testWidgets('empty search offers create with the query pre-filled',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      await search(tester, 'Nothing matches');

      expect(find.textContaining('Create'), findsOneWidget);
      await tester.tap(find.textContaining('Create'));
      await pumpAsync(tester);

      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Inbox'), findsOneWidget);
      // Name pre-filled from the search term.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text, 'Nothing matches');
    });

    // [Mechanism] Search is a GLOBAL action, so unlike the screen "+" FAB it
    // does NOT auto-star what it creates — it files a plain root task (the
    // user picked "same as All Tasks" behavior).
    testWidgets('create-from-search files a plain root task, not starred',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);
      await search(tester, 'Fresh capture');
      await tester.tap(find.textContaining('Create'));
      await pumpAsync(tester);

      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      final created = await tester.runAsync(() async {
        final all = await db.getAllTasks();
        return all.firstWhere((t) => t.name == 'Fresh capture');
      });
      expect(created!.isStarred, isFalse,
          reason: 'search create must not auto-star');
      final parents =
          await tester.runAsync(() => provider.getParentIds(created.id!));
      expect(parents, isEmpty, reason: 'search create files at root');
    });

    // [Mechanism] showTaskSearch pre-loads getParentNamesMap() and hands it to
    // the picker, so a query can match a task by its PARENT's name and the row
    // shows the "under X" context. Without that wiring the search would be
    // name-only and buried subtasks would be unreachable from this tab.
    testWidgets('matches a task by its parent name and shows "under X"',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Guitar practice'));
        final childId = await db.insertTask(Task(name: 'Restring'));
        await db.addRelationship(parentId, childId);
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      // Query matches the PARENT's name only — "Restring" contains none of it.
      await search(tester, 'Guitar');

      expect(find.text('Restring'), findsOneWidget,
          reason: 'child must surface via its parent name');
      expect(find.text('under Guitar practice'), findsOneWidget);
    });

    // [Edge case] The pre-filled name can be edited into one that already
    // exists (the search that opened this dialog found nothing, but the user
    // retypes). showRootAddFromSearch wires onUseExisting → onOpenExisting, so
    // tapping the match OPENS the existing task instead of creating a duplicate
    // — there is no parent to file it under at root.
    testWidgets('create-from-search "Open" suggestion opens existing, '
        'no duplicate', (tester) async {
      await tester.runAsync(() => db.insertTask(Task(name: 'Write report')));
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);
      await search(tester, 'Nothing matches');
      await tester.tap(find.textContaining('Create'));
      await pumpAsync(tester);

      // Retype the name of an existing task → in-field suggestion indicator.
      await tester.enterText(find.byType(TextField).first, 'write REPORT');
      await pumpAsync(tester);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      // pumpAndSettle is needed for the popup's open animation (pumpAsync does
      // not advance the fake clock, leaving the menu collapsed and unhittable).
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byWidgetPredicate(
            (w) => w is PopupMenuItem<Task> && w.enabled));
      });
      await pumpAsync(tester);

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Write report');
      final all = await tester.runAsync(() => db.getAllTasks()) ?? [];
      expect(all.where((t) => t.name.toLowerCase() == 'write report').length, 1,
          reason: 'no duplicate created');
    });
  });

  group('TaskProvider - starOrder preservation', () {
    test('updateTaskStarred with explicit starOrder preserves position',
        () async {
      await db.insertTask(Task(name: 'Task A'));
      await db.insertTask(Task(name: 'Task B'));
      await db.insertTask(Task(name: 'Task C'));

      // Star all three
      await provider.updateTaskStarred(1, true);
      await provider.updateTaskStarred(2, true);
      await provider.updateTaskStarred(3, true);

      // Unstar Task B
      await provider.updateTaskStarred(2, false);

      // Re-star with original order (1) — should slot back in
      await provider.updateTaskStarred(2, true, starOrder: 1);

      final starred = await provider.getStarredTasks();
      final names = starred.map((t) => t.name).toList();
      expect(names, ['Task A', 'Task B', 'Task C']);
    });

    test('updateTaskStarred without starOrder appends to end', () async {
      await db.insertTask(Task(name: 'First'));
      await db.insertTask(Task(name: 'Second'));

      await provider.updateTaskStarred(1, true);
      await provider.updateTaskStarred(2, true);

      // Unstar and re-star without order — goes to end
      await provider.updateTaskStarred(1, false);
      await provider.updateTaskStarred(1, true);

      final starred = await provider.getStarredTasks();
      final names = starred.map((t) => t.name).toList();
      expect(names, ['Second', 'First']);
    });
  });

  group('"already exists" suggestion → Star instead (screen-level add)', () {
    // The Starred screen's + FAB seeds AddTaskFlow with existingTasks. Typing a
    // name matching an existing task surfaces the inline suggestion; tapping it
    // ("Star instead") stars the existing task so it shows on this page instead
    // of creating a duplicate.
    Future<void> tapScreenSuggestion(WidgetTester tester, String name) async {
      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await pumpAsync(tester);
      // Open the in-field "did you mean" popup, then select the match by its
      // action icon (star). pumpAndSettle completes the menu-open animation so
      // the item is at its final hittable position (pumpAsync advances no fake
      // time, leaving the menu collapsed at the anchor).
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.star));
      });
      await pumpAsync(tester);
    }

    // [Mechanism] Tapping the suggestion stars the EXISTING (unstarred) task via
    // updateTaskStarred — it appears on the Starred page and no duplicate task
    // is inserted.
    testWidgets('stars the existing task instead of creating a duplicate',
        (tester) async {
      late int existingId;
      await tester.runAsync(() async {
        // A plain, unstarred root task — not on the Starred page yet.
        existingId = await db.insertTask(Task(name: 'Groceries'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('No starred tasks yet'), findsOneWidget);

      await tapScreenSuggestion(tester, 'groceries');

      final starred = await tester.runAsync(() => provider.getStarredTasks());
      expect(starred!.map((t) => t.id), contains(existingId),
          reason: 'existing task is now starred');
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Groceries'), hasLength(1),
          reason: 'no duplicate created');
    });

    // [Mechanism] The "Starred …" snackbar offers Undo, which unstars the task
    // (matching the long-press Unstar undo) so it drops back off the page.
    testWidgets('Star instead offers Undo that unstars the task',
        (tester) async {
      late int existingId;
      await tester.runAsync(() async {
        existingId = await db.insertTask(Task(name: 'Groceries'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tapScreenSuggestion(tester, 'groceries');

      var starred = await tester.runAsync(() => provider.getStarredTasks());
      expect(starred!.map((t) => t.id), contains(existingId));
      // Settle the snackbar slide-in so the Undo action is hittable.
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      starred = await tester.runAsync(() => provider.getStarredTasks());
      expect(starred!.map((t) => t.id), isNot(contains(existingId)),
          reason: 'undo unstarred the task');
    });

    // [Edge case] If the matched task is ALREADY starred, tapping the suggestion
    // is a no-op with an "already starred" snackbar (re-starring would be
    // meaningless / could churn star_order).
    testWidgets('already-starred match shows snackbar and does not duplicate',
        (tester) async {
      await tester.runAsync(() => createStarredTask('Groceries'));

      await pumpAndLoad(tester, buildTestWidget());

      await tapScreenSuggestion(tester, 'Groceries');

      expect(find.textContaining('already starred'), findsOneWidget);
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Groceries'), hasLength(1));
      final starred = await tester.runAsync(() => provider.getStarredTasks());
      expect(starred!.where((t) => t.name == 'Groceries'), hasLength(1));
    });
  });

  group('"already exists" suggestion → Add here (expanded subtask add)', () {
    // The expanded starred dialog's "Add subtask" FAB seeds AddTaskFlow with
    // existingTasks. Typing a name matching an existing task surfaces the
    // suggestion; tapping it ("Add here") links that task as a subtask of the
    // starred parent (multi-parent DAG) instead of creating a duplicate.
    Future<void> tapSubtaskSuggestion(
        WidgetTester tester, String name) async {
      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await pumpAsync(tester);
      // Open the in-field "did you mean" popup, then select the match by its
      // action icon (add_link). pumpAndSettle completes the menu-open animation
      // so the item is at its final hittable position.
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.add_link));
      });
      await pumpAsync(tester);
    }

    // [Mechanism] "Add here" links the existing task under the starred parent
    // via addParentToTask — the existing task gains the parent as a new parent
    // and no duplicate is created.
    testWidgets('links the existing task as a subtask, no duplicate',
        (tester) async {
      late int starredId;
      late int existingId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        existingId = await db.insertTask(Task(name: 'Shared task'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tapSubtaskSuggestion(tester, 'shared TASK');

      final children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children!.map((t) => t.id), contains(existingId),
          reason: 'existing task linked as a subtask');
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Shared task'), hasLength(1),
          reason: 'no duplicate created');
    });

    // [Mechanism] The "Added … here" snackbar (rendered inside the expanded
    // dialog via its own ScaffoldMessenger) offers Undo, which removes the
    // subtask link (removeParentFromTask).
    testWidgets('Add here offers Undo that removes the subtask link',
        (tester) async {
      late int starredId;
      late int existingId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        existingId = await db.insertTask(Task(name: 'Shared task'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tapSubtaskSuggestion(tester, 'shared TASK');

      var children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children!.map((t) => t.id), contains(existingId));
      // Settle the in-dialog snackbar slide-in so Undo is hittable.
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children!.map((t) => t.id), isNot(contains(existingId)),
          reason: 'undo removed the subtask link');
    });

    // [Edge case — Codex P2] Typing the name of a task that is ALREADY a subtask
    // of this starred task must NOT wire a destructive Undo (re-linking is a
    // no-op whose Undo would remove the pre-existing edge). Guard short-circuits
    // with an "already a subtask" message and leaves the edge intact.
    testWidgets('Add here on an existing subtask is a safe no-op',
        (tester) async {
      late int starredId;
      late int existingId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        existingId = await db.insertTask(Task(name: 'Existing sub'));
        await db.addRelationship(starredId, existingId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tapSubtaskSuggestion(tester, 'existing SUB');

      expect(find.textContaining('already a subtask'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      final children = await tester.runAsync(() => db.getChildren(starredId));
      expect(children!.map((t) => t.id), contains(existingId),
          reason: 'the pre-existing subtask edge is preserved');
    });

    // [Edge case] Typing the starred parent's OWN name matches itself; the guard
    // (existing.id == widget.task.id) refuses to self-parent and shows "that's
    // this task" instead of linking the task under itself.
    testWidgets('typing the parent\'s own name refuses to self-parent',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        // Give it a child so the card is a non-leaf and opens the tree.
        final childId = await db.insertTask(Task(name: 'Existing sub'));
        await db.addRelationship(starredId, childId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tapSubtaskSuggestion(tester, 'Project');

      expect(find.textContaining("this task"), findsOneWidget);
      // No self-loop edge created.
      final parentsOfSelf =
          await tester.runAsync(() => db.getParentIds(starredId)) ?? [];
      expect(parentsOfSelf, isEmpty);
    });

    // [Edge case] "Add here" delegates to addParentToTask, which returns false
    // when linking the existing task under the starred parent would create a
    // cycle (the existing task is an ancestor of the starred parent). The
    // subtask surface must surface "Couldn't add — it would create a loop" and
    // leave the graph unchanged — mirrors the All Tasks cycle guard, which the
    // task_list_screen suite covers, but exercises the distinct starred code
    // path here.
    testWidgets('linking an ancestor shows the loop warning, no edge added',
        (tester) async {
      late int starredId;
      late int ancestorId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        // Give Project a child so its card is a non-leaf and opens the tree.
        final childId = await db.insertTask(Task(name: 'Existing sub'));
        await db.addRelationship(starredId, childId);
        // Project has an ancestor, so linking that ancestor as a subtask of
        // Project would form a cycle.
        ancestorId = await db.insertTask(Task(name: 'Ancestor'));
        await db.addRelationship(ancestorId, starredId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tapSubtaskSuggestion(tester, 'Ancestor');

      expect(find.textContaining('loop'), findsOneWidget);
      // Ancestor did NOT gain Project as a new parent.
      final ancestorParents =
          await tester.runAsync(() => db.getParentIds(ancestorId)) ?? [];
      expect(ancestorParents, isNot(contains(starredId)));
    });
  });

  group('StarredScreen - add a subtask at any level', () {
    // [Edge case] The "already exists" suggestion is advisory, not a block.
    // Typing a name that already exists and tapping Add creates a genuine new
    // task under that row — it neither links to the existing one nor refuses.
    // Found by the user during manual testing, who tapped Add rather than the
    // suggestion and got two same-named tasks, which is correct.
    testWidgets('tapping Add on a duplicate name creates a separate task',
        (tester) async {
      late int existingId;
      late int otherRowId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final firstRowId = await db.insertTask(Task(name: 'First row'));
        await db.addRelationship(starredId, firstRowId);
        existingId = await db.insertTask(Task(name: 'Shared name'));
        await db.addRelationship(firstRowId, existingId);
        otherRowId = await db.insertTask(Task(name: 'Second row'));
        await db.addRelationship(starredId, otherRowId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      // Ignore the ⓘ suggestion entirely and just submit the name.
      await tester.tap(find.byTooltip('Add subtask under "Second row"'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Shared name');
      await tester.tap(find.text('Add'));
      await pumpAsync(tester);

      final newChildIds =
          await tester.runAsync(() => db.getChildIds(otherRowId)) ?? [];
      expect(newChildIds, hasLength(1));
      expect(newChildIds.first, isNot(existingId),
          reason: 'a new task, not a link to the existing one');

      // The existing task keeps its own single parent — it was not re-homed.
      final existingParents =
          await tester.runAsync(() => db.getParentIds(existingId)) ?? [];
      expect(existingParents, hasLength(1));
      expect(existingParents, isNot(contains(otherRowId)));
    });

    // [Mechanism] Every tree row carries its own "+", so a subtask can be
    // created under a nested row without leaving the expanded dialog. Before
    // this, the dialog's only add control was a FAB that always parented to the
    // starred task at the top.
    testWidgets('a nested row\'s + parents the new task under that row',
        (tester) async {
      late int childId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        childId = await db.insertTask(Task(name: 'Phase one'));
        await db.addRelationship(starredId, childId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Phase one"'));
      await pumpAsync(tester);

      await tester.enterText(find.byType(TextField).first, 'Sub of phase one');
      await tester.tap(find.text('Add'));
      await pumpAsync(tester);

      final childIds =
          await tester.runAsync(() => db.getChildIds(childId)) ?? [];
      expect(childIds, hasLength(1));
      final created =
          await tester.runAsync(() => db.getTaskById(childIds.first));
      expect(created!.name, 'Sub of phase one');
    });

    // [Mechanism] The new subtask is revealed straight away: _reloadAfterAdd
    // expands the row it was added under and refreshes the level above too, so
    // the row that was a leaf gains its chevron instead of staying stale.
    testWidgets('adding under a leaf reveals the new subtask in place',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final leafId = await db.insertTask(Task(name: 'Lonely leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Lonely leaf"'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Brand new');
      await tester.tap(find.text('Add'));
      await pumpAsync(tester);

      // Visible without any further tap — the parent row was auto-expanded.
      expect(find.text('Brand new'), findsOneWidget);
    });

    // [Mechanism] The dialog's FAB adds a direct child of the starred task —
    // the same thing each row's "+" does for that row.
    testWidgets('the FAB parents the new task under the starred task',
        (tester) async {
      late int starredId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Top level sub');
      await tester.tap(find.text('Add'));
      await pumpAsync(tester);

      final childIds =
          await tester.runAsync(() => db.getChildIds(starredId)) ?? [];
      expect(childIds, hasLength(1));
      final created =
          await tester.runAsync(() => db.getTaskById(childIds.first));
      expect(created!.name, 'Top level sub');
    });

    // [Regression] The pinned warning follows the row being added under, not
    // the starred task at the top. The pin state is a set of ids for exactly
    // this reason: a single "is the starred task pinned" flag leaves a pinned
    // nested row with no warning, so its pin silently disappears when the add
    // turns it into a non-leaf.
    testWidgets('a pinned nested row warns before adding under it',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final leafId = await db.insertTask(Task(name: 'Pinned leaf'));
        await db.addRelationship(starredId, leafId);
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [leafId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {leafId},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Pinned leaf"'));
      await pumpAsync(tester);

      expect(find.text('This task is pinned'), findsOneWidget);
      await tester.tap(find.text('Add anyway'));
      await pumpAsync(tester);

      // The pinned row is the one being added under, so its own pin toggle is
      // suppressed too.
      expect(find.text('Add Task'), findsOneWidget);
      expect(find.text('Pin for today'), findsNothing);
    });

    // [Regression] The mirror of the test above: the starred task is pinned but
    // the row being added under is not, so there is nothing to warn about. A
    // flag that tracked only the starred task's pin state would warn here and
    // hide the pin toggle for a row that can still be pinned.
    testWidgets('a pinned starred task does not warn when the row is unpinned',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final leafId = await db.insertTask(Task(name: 'Phase one'));
        await db.addRelationship(starredId, leafId);
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [starredId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {starredId},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Phase one"'));
      await pumpAsync(tester);

      expect(find.text('This task is pinned'), findsNothing);
      expect(find.text('Add Task'), findsOneWidget);
      // One of the five slots is taken, so the toggle is still on offer.
      expect(find.text('Pin for today'), findsOneWidget);
    });

    // [Regression] An add refreshes every level on screen without collapsing
    // the tree. Clearing the expansion state instead would shut every other
    // branch the user had opened, which on a deep tree means finding their
    // place again after each add.
    testWidgets('adding under one row leaves other branches expanded',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final branchId = await db.insertTask(Task(name: 'Branch A'));
        await db.addRelationship(starredId, branchId);
        final grandChild = await db.insertTask(Task(name: 'A1'));
        await db.addRelationship(branchId, grandChild);
        final leafId = await db.insertTask(Task(name: 'Leaf B'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      // Open Branch A. A1 now shows in the card preview behind AND in the
      // dialog; collapsed it would show in the preview only.
      await tester.tap(find.text('Branch A').last);
      await pumpAsync(tester);
      expect(find.text('A1'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Add subtask under "Leaf B"'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Under B');
      await tester.tap(find.text('Add'));
      await pumpAsync(tester);

      expect(find.text('Under B'), findsWidgets);
      expect(find.text('A1'), findsNWidgets(2),
          reason: 'Branch A stayed expanded across the add');
    });

    // [Mechanism] The "already exists" suggestion links the match under the row
    // whose "+" was tapped, so "Add here" on a nested row does not quietly file
    // the task under the starred task instead.
    testWidgets('"Add here" on a nested row links under that row',
        (tester) async {
      late int starredId;
      late int rowId;
      late int existingId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        rowId = await db.insertTask(Task(name: 'Phase one'));
        await db.addRelationship(starredId, rowId);
        existingId = await db.insertTask(Task(name: 'Shared task'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Phase one"'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'shared TASK');
      await pumpAsync(tester);
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.add_link));
      });
      await pumpAsync(tester);

      final rowChildren =
          await tester.runAsync(() => db.getChildIds(rowId)) ?? [];
      expect(rowChildren, contains(existingId));
      final starredChildren =
          await tester.runAsync(() => db.getChildIds(starredId)) ?? [];
      expect(starredChildren, isNot(contains(existingId)),
          reason: 'the link went under the row, not the starred task');
    });

    // [Edge case] Typing the row's own name matches the row itself. The guard
    // compares against the row being added under, so it refuses to file the row
    // under itself rather than only catching the starred task.
    testWidgets('typing a nested row\'s own name refuses to self-parent',
        (tester) async {
      late int starredId;
      late int rowId;
      await tester.runAsync(() async {
        starredId = await createStarredTask('Project');
        rowId = await db.insertTask(Task(name: 'Phase one'));
        await db.addRelationship(starredId, rowId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Add subtask under "Phase one"'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'phase ONE');
      await pumpAsync(tester);
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.add_link));
      });
      await pumpAsync(tester);

      expect(find.textContaining("this task"), findsOneWidget);
      final parents = await tester.runAsync(() => db.getParentIds(rowId)) ?? [];
      expect(parents, [starredId], reason: 'no self-loop edge');
    });
  });

  group('StarredScreen - mark a task done', () {
    /// Opens the expanded dialog for [starred] and taps the done circle on its
    /// only leaf row.
    Future<void> openDoneMenu(WidgetTester tester, String starred) async {
      await tester.tap(find.text(starred));
      await pumpAsync(tester);
      await tester.tap(find.byTooltip('Mark done'));
      // The menu animates open. pumpAsync alone pumps frames without moving
      // the fake clock, so the items exist but are still mid-animation and off
      // their final position — every tap on one would miss.
      await pumpAsync(tester, rounds: 5);
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// Picks [label] from the done chooser and waits the action out.
    ///
    /// Two animations have to finish in turn, and neither is advanced by a bare
    /// pump: the menu delivers the choice only once its pop animation ends, and
    /// the completion animation then holds for 700ms before the database write.
    /// Advancing the clock in slices, interleaved with [pumpAsync] for the real
    /// async database work, clears both.
    Future<void> chooseDone(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await pumpAsync(tester, rounds: 5);
      }
    }

    /// Taps [label] and lets the clock and the database work run on, the same
    /// way [chooseDone] does. For the confirmation dialogs that sit between the
    /// chooser and the write ("Remove deadline?", "Unblock waiting tasks?").
    Future<void> tapAndSettle(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await pumpAsync(tester, rounds: 5);
      }
    }

    /// The task name as the expanded dialog renders it (17px). The starred
    /// card's tree preview behind the dialog shows the same names at 14px, so a
    /// bare find.text matches twice.
    Text rowText(WidgetTester tester, String name) => tester
        .widgetList<Text>(find.text(name))
        .firstWhere((t) => t.style?.fontSize == 17);

    // [Mechanism] Only leaves get a done circle: "Done for good!" lives in
    // LeafTaskDetail, which All Tasks shows only for leaves, so a task with
    // children has no completion path anywhere in the app.
    testWidgets('leaf rows get a done circle, branch rows do not',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final branchId = await db.insertTask(Task(name: 'Branch'));
        await db.addRelationship(starredId, branchId);
        final grandChild = await db.insertTask(Task(name: 'Grandchild'));
        await db.addRelationship(branchId, grandChild);
        final leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      // Both rows are on screen, and only the leaf carries a done circle.
      expect(find.byTooltip('Add subtask under "Branch"'), findsOneWidget);
      expect(find.byTooltip('Add subtask under "Leaf"'), findsOneWidget);
      expect(find.byTooltip('Mark done'), findsOneWidget);
    });

    // [Mechanism] The circle offers the same pair of actions Today's 5 offers
    // in its bottom sheet, rather than silently completing for good.
    testWidgets('tapping the circle offers both kinds of done', (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');

      expect(find.text('Done today'), findsOneWidget);
      expect(find.text('Done for good!'), findsOneWidget);
    });

    // [Mechanism] "Done for good!" completes the task in the database and the
    // row stays on screen struck through, rather than vanishing — the user can
    // see what they just cleared.
    testWidgets('"Done for good!" completes the task and keeps the row',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done for good!');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNotNull);

      expect(rowText(tester, 'Leaf').style!.decoration,
          TextDecoration.lineThrough);
    });

    // [Mechanism] "Done today" stamps last_worked_at instead of completing, so
    // the task resurfaces later. The row dims rather than striking through.
    testWidgets('"Done today" marks worked-on without completing',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done today');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNull);
      expect(task.isWorkedOnToday, isTrue);

      // Struck through like a "Done for good!" row: both ticked-off states read
      // as handled, and the circle is what distinguishes them. Only a blocked
      // row is dimmed without a strikethrough.
      expect(rowText(tester, 'Leaf').style!.decoration,
          TextDecoration.lineThrough);
    });

    // [Mechanism] A ticked-off row taps straight back to undone, so a mis-tap
    // is reversible after the 5-second undo snackbar has gone. The stored
    // DoneOutcome carries the undo closure that restores dependency links.
    testWidgets('tapping a ticked-off row again undoes it', (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done for good!');

      // The circle is now a check; tapping it reverses the completion.
      await tester.tap(find.byTooltip('Undo done'));
      await pumpAsync(tester);
      expect(find.byTooltip('Mark done'), findsOneWidget,
          reason: 'the circle is back to offering the chooser');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNull);
      expect(rowText(tester, 'Leaf').style!.decoration,
          isNot(TextDecoration.lineThrough));
    });

    // [Mechanism] "Done today" auto-starts a task that was not started, and the
    // undo reverses that too — a task the user never started should not be left
    // "In progress" by a mis-tap.
    testWidgets('"Done today" starts the task, and undo unstarts it',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done today');

      var task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.isStarted, isTrue);

      await tester.tap(find.byTooltip('Undo done'));
      await pumpAsync(tester);

      task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.isStarted, isFalse);
      expect(task.isWorkedOnToday, isFalse);
    });

    // [Mechanism] Undo from the snackbar, rather than from the circle, has to
    // clear the row's styling as well — the `onChanged` callback is what keeps
    // the two in step, so without it the row stays struck through over a task
    // that is open again.
    testWidgets('undo from the snackbar clears the struck-through row',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done for good!');
      expect(rowText(tester, 'Leaf').style!.decoration,
          TextDecoration.lineThrough);

      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNull);
      expect(rowText(tester, 'Leaf').style!.decoration,
          isNot(TextDecoration.lineThrough));
      expect(find.byTooltip('Mark done'), findsOneWidget);
    });

    // [Edge case] Completing a blocker frees whatever was waiting on it, so the
    // tree asks first — same confirmation the All Tasks leaf detail shows.
    // Declining leaves the task open and the row unmarked.
    testWidgets('cancelling the unblock confirmation leaves the task open',
        (tester) async {
      late int blockerId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        blockerId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, blockerId);
        final waitingId = await db.insertTask(Task(name: 'Waiting task'));
        await db.addDependency(waitingId, blockerId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done for good!');

      expect(find.text('Unblock waiting tasks?'), findsOneWidget);
      expect(find.textContaining('Waiting task'), findsOneWidget);
      await tapAndSettle(tester, 'Cancel');

      final task = await tester.runAsync(() => db.getTaskById(blockerId));
      expect(task!.completedAt, isNull);
      expect(find.byTooltip('Mark done'), findsOneWidget,
          reason: 'the row was never marked, so the chooser is still there');
    });

    // [Mechanism] Completing a blocker drops the dependency links it held, and
    // the undo closure stored with the row restores them — the whole reason the
    // row keeps its DoneOutcome rather than re-deriving an undo later.
    testWidgets('undo after completing a blocker restores the dependency',
        (tester) async {
      late int blockerId;
      late int waitingId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        blockerId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, blockerId);
        waitingId = await db.insertTask(Task(name: 'Waiting task'));
        await db.addDependency(waitingId, blockerId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done for good!');
      await tapAndSettle(tester, 'Complete');

      var blockers =
          await tester.runAsync(() => db.getDependencies(waitingId)) ?? [];
      expect(blockers, isEmpty, reason: 'completing freed the waiting task');

      await tester.tap(find.byTooltip('Undo done'));
      await pumpAsync(tester);

      final task = await tester.runAsync(() => db.getTaskById(blockerId));
      expect(task!.completedAt, isNull);
      blockers =
          await tester.runAsync(() => db.getDependencies(waitingId)) ?? [];
      expect(blockers.map((t) => t.id), contains(blockerId),
          reason: 'the dependency link came back with the undo');
    });

    // [Mechanism] The chevron sits outside the row's InkWell (the marker column
    // it shares with the done circle), so it needs its own tap target —
    // otherwise it looks tappable and does nothing. Tapping it expands and
    // collapses exactly as tapping the row name does.
    testWidgets('the chevron toggles the row like tapping its name',
        (tester) async {
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        final branchId = await db.insertTask(Task(name: 'Branch'));
        await db.addRelationship(starredId, branchId);
        final childId = await db.insertTask(Task(name: 'Hidden child'));
        await db.addRelationship(branchId, childId);
      });

      // The starred card's tree preview behind the dialog lists the same
      // grandchild at 14px, so presence has to be judged on the dialog's own
      // 17px rows.
      bool dialogShows(String name) => tester
          .widgetList<Text>(find.text(name))
          .any((t) => t.style?.fontSize == 17);

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      expect(dialogShows('Hidden child'), isFalse);

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpAsync(tester);
      expect(dialogShows('Hidden child'), isTrue);

      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await pumpAsync(tester);
      expect(dialogShows('Hidden child'), isFalse);
    });

    // [Regression] _blockedIds was only ever added to, never rebuilt, so a row
    // freed by completing its blocker kept the dimmed blocked styling until the
    // dialog was closed and reopened. Both tasks are siblings under the starred
    // task here, so both are visible rows in the tree.
    testWidgets('completing a blocker un-dims the row waiting on it',
        (tester) async {
      late int blockerId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        blockerId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, blockerId);
        final waitingId = await db.insertTask(Task(name: 'Waiting task'));
        await db.addRelationship(starredId, waitingId);
        await db.addDependency(waitingId, blockerId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      // Blocked rows render at alpha 100; an unblocked row keeps the row's full
      // base colour (childTextStyle, starred_screen.dart).
      final blockedColor = rowText(tester, 'Waiting task').style!.color!;
      expect(blockedColor.a, closeTo(100 / 255, 0.01),
          reason: 'dimmed while the blocker is outstanding');

      // Both rows are leaves, so both carry a circle. Dependency-chain ordering
      // puts the blocker first, so .first is "Leaf".
      await tester.tap(find.byTooltip('Mark done').first);
      await pumpAsync(tester, rounds: 5);
      await tester.pump(const Duration(milliseconds: 500));
      await chooseDone(tester, 'Done for good!');
      await tapAndSettle(tester, 'Complete');

      final freedColor = rowText(tester, 'Waiting task').style!.color!;
      expect(freedColor.a, greaterThan(blockedColor.a),
          reason: 'un-dims as soon as the blocker is completed, without '
              'reopening the dialog');

      // And dims again when the completion is undone.
      await tester.tap(find.byTooltip('Undo done'));
      await pumpAsync(tester);
      expect(rowText(tester, 'Waiting task').style!.color!.a,
          closeTo(blockedColor.a, 0.01));
    });

    // [Edge case] "Done today" on a task with its own deadline asks whether the
    // deadline still applies, and "Remove" clears it along with marking the
    // task worked on.
    testWidgets('"Done today" offers to clear the task\'s deadline',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(
          Task(name: 'Leaf', deadline: '2030-06-01'),
        );
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done today');

      expect(find.text('Remove deadline?'), findsOneWidget);
      await tapAndSettle(tester, 'Remove');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.deadline, isNull);
      expect(task.isWorkedOnToday, isTrue);
    });

    // [Edge case] Dismissing that deadline prompt instead of answering it
    // aborts the whole action — the task is neither marked nor stripped of its
    // deadline, and the row stays untouched.
    testWidgets('dismissing the deadline prompt aborts the mark',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(
          Task(name: 'Leaf', deadline: '2030-06-01'),
        );
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      await chooseDone(tester, 'Done today');
      expect(find.text('Remove deadline?'), findsOneWidget);

      // Tap the barrier outside the prompt to dismiss it.
      await tester.tapAt(const Offset(5, 5));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await pumpAsync(tester, rounds: 5);
      }

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.deadline, '2030-06-01');
      expect(task.isWorkedOnToday, isFalse);
      expect(find.byTooltip('Mark done'), findsOneWidget);
    });

    // [Edge case] Dismissing the chooser without picking leaves the task alone
    // — the circle is a menu, so a stray tap must not complete anything.
    testWidgets('dismissing the done chooser changes nothing', (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        final starredId = await createStarredTask('Project');
        leafId = await db.insertTask(Task(name: 'Leaf'));
        await db.addRelationship(starredId, leafId);
      });

      await pumpAndLoad(tester, buildTestWidget());
      await openDoneMenu(tester, 'Project');
      expect(find.text('Done today'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await pumpAsync(tester, rounds: 5);
      }

      expect(find.text('Done today'), findsNothing);
      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNull);
      expect(task.isWorkedOnToday, isFalse);
      expect(rowText(tester, 'Leaf').style!.decoration,
          isNot(TextDecoration.lineThrough));
    });
  });
}
