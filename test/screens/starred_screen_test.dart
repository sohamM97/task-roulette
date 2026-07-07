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

    testWidgets('leaf node shows navigate icon', (tester) async {
      await tester.runAsync(() async {
        final parentId = await createStarredTask('Parent');
        final leaf = await db.insertTask(Task(name: 'My leaf'));
        await db.addRelationship(parentId, leaf);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Header has one ↗, leaf row has another
      expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(2));
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
}
