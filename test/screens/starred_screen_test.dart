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

  group('StarredScreen - Long press expanded view', () {
    testWidgets('long press opens expanded dialog', (tester) async {
      await tester.runAsync(() => createStarredTask('Guitar'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Guitar'));
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

    testWidgets('expanded view shows "No sub-tasks" for leaf', (tester) async {
      await tester.runAsync(() => createStarredTask('Leaf task'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Leaf task'));
      await pumpAsync(tester);

      expect(find.text('No sub-tasks'), findsOneWidget);
    });

    testWidgets('star icon in expanded view opens confirmation dialog',
        (tester) async {
      await tester.runAsync(() => createStarredTask('Confirm me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Confirm me'));
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
      await tester.runAsync(() => createStarredTask('Keep me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Keep me'));
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
      await tester.runAsync(() => createStarredTask('Remove me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Remove me'));
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
      await tester.runAsync(() => createStarredTask('Undo me'));

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Undo me'));
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
  });
}
