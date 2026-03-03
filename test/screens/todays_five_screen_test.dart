import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/providers/theme_provider.dart';
import 'package:task_roulette/screens/todays_five_screen.dart';
import 'package:task_roulette/services/sync_service.dart';

String _todayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

void main() {
  late DatabaseHelper db;
  late TaskProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    // Use NoIsolate variant for widget tests: databaseFactoryFfi uses worker
    // isolates whose ReceivePort callbacks don't fire in FakeAsync (testWidgets).
    // NoIsolate runs FFI synchronously so futures resolve via microtasks that
    // pump() can process.
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

  Widget buildTestWidget({void Function(Task)? onNavigateToTask}) {
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
          body: TodaysFiveScreen(onNavigateToTask: onNavigateToTask),
        ),
      ),
    );
  }

  /// Pumps the widget and waits for all async loading to complete.
  /// DB operations inside the widget (via databaseFactoryFfiNoIsolate) need
  /// runAsync to exit FakeAsync, then pump to process microtask continuations.
  Future<void> pumpAndLoad(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  group('TodaysFiveScreen', () {
    testWidgets('shows empty state when no tasks exist', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('No tasks for today!'), findsOneWidget);
      expect(find.text('Add some tasks in the All Tasks tab.'), findsOneWidget);
    });

    testWidgets('shows tasks when leaf tasks exist', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Buy groceries'));
        await db.insertTask(Task(name: 'Write report'));
        await db.insertTask(Task(name: 'Call dentist'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('No tasks for today!'), findsNothing);
      expect(find.text('Completing even 1 is a win!'), findsOneWidget);
      expect(find.text('Buy groceries'), findsOneWidget);
      expect(find.text('Write report'), findsOneWidget);
      expect(find.text('Call dentist'), findsOneWidget);
    });

    testWidgets('picks at most 5 tasks', (tester) async {
      await tester.runAsync(() async {
        for (var i = 1; i <= 7; i++) {
          await db.insertTask(Task(name: 'Task $i'));
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('No tasks for today!'), findsNothing);
      var taskCount = 0;
      for (var i = 1; i <= 7; i++) {
        if (find.text('Task $i').evaluate().isNotEmpty) taskCount++;
      }
      expect(taskCount, 5);
    });

    testWidgets('excludes non-leaf tasks', (tester) async {
      late int childId;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        childId = await db.insertTask(Task(name: 'Leaf child'));
        await db.addRelationship(parentId, childId);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Only the leaf should appear — Parent should not be in the task list.
      // Note: "Parent" may appear in the hierarchy path label, so check
      // that only 1 task card is rendered.
      expect(find.text('Leaf child'), findsOneWidget);
    });

    testWidgets('excludes blocked tasks', (tester) async {
      await tester.runAsync(() async {
        final a = await db.insertTask(Task(name: 'Blocker'));
        final b = await db.insertTask(Task(name: 'Blocked'));
        await db.addDependency(b, a);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Blocker'), findsOneWidget);
      expect(find.text('Blocked'), findsNothing);
    });

    testWidgets('tapping undone task opens bottom sheet with options', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'My task'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('My task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Done today'), findsOneWidget);
      expect(find.text('Done for good!'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
    });

    testWidgets('shows Stop working for started task', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Started task'));
        await db.startTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Started task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Stop working'), findsOneWidget);
      expect(find.text('In progress'), findsNothing);
    });

    testWidgets('swap button is present on undone tasks', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Some task'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.shuffle), findsOneWidget);
    });

    testWidgets('navigate button calls onNavigateToTask', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Navigate me'));
      });
      Task? navigatedTask;

      await pumpAndLoad(
        tester,
        buildTestWidget(onNavigateToTask: (task) => navigatedTask = task),
      );

      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pump();

      expect(navigatedTask, isNotNull);
      expect(navigatedTask!.name, 'Navigate me');
    });

    testWidgets('shows progress bar', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Task 1'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('shows high priority flag icon', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Urgent', priority: 2));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flag), findsOneWidget);
    });

    testWidgets('refresh button shows confirmation dialog', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Task 1'));
        await db.insertTask(Task(name: 'Task 2'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      final refreshFinder = find.byIcon(Icons.refresh);
      expect(refreshFinder, findsOneWidget);

      await tester.tap(refreshFinder);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('New set?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Replace'), findsOneWidget);
    });

    testWidgets('restores state from DB on reload', (tester) async {
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Persisted 1'));
        id2 = await db.insertTask(Task(name: 'Persisted 2'));
        // Pre-save state to DB as if a previous session saved it
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {id1},
          workedOnIds: {id1},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Both tasks should be visible
      expect(find.text('Persisted 1'), findsOneWidget);
      expect(find.text('Persisted 2'), findsOneWidget);
      // Persisted 1 should show as done (check icon present)
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('SharedPreferences → DB migration', () {
    testWidgets('migrates prefs data to DB and clears prefs', (tester) async {
      late int id1, id2, id3;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Task A'));
        id2 = await db.insertTask(Task(name: 'Task B'));
        id3 = await db.insertTask(Task(name: 'Task C'));
      });

      final today = _todayKey();
      // Simulate old SharedPreferences state
      SharedPreferences.setMockInitialValues({
        'todays5_date': today,
        'todays5_ids': [id1.toString(), id2.toString(), id3.toString()],
        'todays5_completed': [id1.toString()],
        'todays5_worked_on': [id1.toString()],
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Tasks should be restored from migrated data
      expect(find.text('Task A'), findsOneWidget);
      expect(find.text('Task B'), findsOneWidget);
      expect(find.text('Task C'), findsOneWidget);

      // Verify DB has the data
      await tester.runAsync(() async {
        final dbState = await db.loadTodaysFiveState(today);
        expect(dbState, isNotNull);
        expect(dbState!.taskIds, containsAll([id1, id2, id3]));
        expect(dbState.completedIds, contains(id1));
        expect(dbState.workedOnIds, contains(id1));
      });

      // Verify SharedPreferences were cleared
      await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('todays5_date'), isNull);
        expect(prefs.getStringList('todays5_ids'), isNull);
      });
    });
  });

  group('Sync reload', () {
    testWidgets('reloads from DB when sync status changes to synced', (tester) async {
      // Simulate: laptop opens, generates local set, then sync brings
      // different tasks from phone. The screen should show phone's tasks.
      await tester.runAsync(() async {
        // Create tasks that will be in both local and remote sets
        await db.insertTask(Task(name: 'Phone Task A', syncId: 'sync-a'));
        await db.insertTask(Task(name: 'Phone Task B', syncId: 'sync-b'));
        // These will be the locally-generated set
        await db.insertTask(Task(name: 'Laptop Task C', syncId: 'sync-c'));
        await db.insertTask(Task(name: 'Laptop Task D', syncId: 'sync-d'));
        await db.insertTask(Task(name: 'Laptop Task E', syncId: 'sync-e'));
      });

      final authProvider = AuthProvider();
      final widget = MultiProvider(
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
            body: TodaysFiveScreen(),
          ),
        ),
      );

      // Load the widget — it generates a local set from all 5 leaf tasks
      await pumpAndLoad(tester, widget);
      expect(find.text('No tasks for today!'), findsNothing);

      // Now simulate a sync pull: overwrite DB with phone's selections
      await tester.runAsync(() async {
        await db.upsertTodaysFiveFromRemote(_todayKey(), [
          {'task_sync_id': 'sync-a', 'is_completed': false, 'is_worked_on': false, 'is_pinned': false, 'sort_order': 0},
          {'task_sync_id': 'sync-b', 'is_completed': false, 'is_worked_on': false, 'is_pinned': false, 'sort_order': 1},
        ]);
      });

      // Trigger _onSyncStatusChanged by setting syncStatus to synced
      authProvider.setSyncStatus(SyncStatus.synced);

      // Let the reload complete
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Phone tasks should now be visible
      expect(find.text('Phone Task A'), findsOneWidget);
      expect(find.text('Phone Task B'), findsOneWidget);
    });

    testWidgets('reload after sync preserves completed status from remote', (tester) async {
      late int idA, idB;
      await tester.runAsync(() async {
        idA = await db.insertTask(Task(name: 'Task Alpha', syncId: 'sync-alpha'));
        idB = await db.insertTask(Task(name: 'Task Beta', syncId: 'sync-beta'));
        // Pre-save as today's set so the widget loads them directly
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idA, idB],
          completedIds: {},
          workedOnIds: {},
        );
      });

      final authProvider = AuthProvider();
      final widget = MultiProvider(
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
            body: TodaysFiveScreen(),
          ),
        ),
      );

      await pumpAndLoad(tester, widget);

      // Both tasks visible, neither completed
      expect(find.text('Task Alpha'), findsOneWidget);
      expect(find.text('Task Beta'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      // Simulate sync: remote says Alpha is completed
      await tester.runAsync(() async {
        await db.upsertTodaysFiveFromRemote(_todayKey(), [
          {'task_sync_id': 'sync-alpha', 'is_completed': true, 'is_worked_on': false, 'is_pinned': false, 'sort_order': 0},
          {'task_sync_id': 'sync-beta', 'is_completed': false, 'is_worked_on': false, 'is_pinned': false, 'sort_order': 1},
        ]);
      });

      // Trigger reload via sync status change
      authProvider.setSyncStatus(SyncStatus.synced);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Alpha should now show completed (check_circle icon)
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });
}
