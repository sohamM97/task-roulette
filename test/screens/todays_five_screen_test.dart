import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/async_pump.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/data/todays_five_pin_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/providers/theme_provider.dart';
import 'package:task_roulette/screens/todays_five_screen.dart';
import 'package:task_roulette/models/task_schedule.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/utils/display_utils.dart';

String _todayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

/// Helper: seeds Today's 5 with given task IDs (manual model — Today's 5
/// only contains user-pinned tasks). By default, all seeded tasks are
/// also pinned; pass [pinnedIds] to override.
Future<void> seedTodaysFive(
  DatabaseHelper db,
  List<int> taskIds, {
  Set<int> pinnedIds = const {},
}) async {
  await db.saveTodaysFiveState(
    date: _todayKey(),
    taskIds: taskIds,
    completedIds: const {},
    workedOnIds: const {},
    pinnedIds: pinnedIds.isEmpty ? Set<int>.from(taskIds) : pinnedIds,
  );
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


  group('TodaysFiveScreen', () {
    testWidgets('shows empty state when no tasks exist', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Nothing pinned yet'), findsOneWidget);
      expect(
        find.text(
          'Tap the + button to pick a task to focus on today.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('manual model: empty even when leaf tasks exist '
        'but no saved state', (tester) async {
      // Inserting leaves alone should NOT auto-populate Today's 5 anymore.
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Unpinned A'));
        await db.insertTask(Task(name: 'Unpinned B'));
        await db.insertTask(Task(name: 'Unpinned C'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Nothing pinned yet'), findsOneWidget);
      expect(find.text('Unpinned A'), findsNothing);
      expect(find.text('Unpinned B'), findsNothing);
      expect(find.text('Unpinned C'), findsNothing);
    });

    testWidgets('shows tasks when seeded into Today\'s 5', (tester) async {
      await tester.runAsync(() async {
        final id1 = await db.insertTask(Task(name: 'Buy groceries'));
        final id2 = await db.insertTask(Task(name: 'Write report'));
        final id3 = await db.insertTask(Task(name: 'Call dentist'));
        await seedTodaysFive(db, [id1, id2, id3]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Nothing pinned yet'), findsNothing);
      // Motivational text rotates daily — just verify one of them is shown
      final motivationalTexts = [
        'Completing even 1 is a win!',
        'Pick one and start small.',
        'One step at a time.',
        'Just begin — momentum follows.',
        'You’ve got this.',
      ];
      expect(
        motivationalTexts.any(
          (text) => find.text(text).evaluate().isNotEmpty,
        ),
        isTrue,
      );
      expect(find.text('Buy groceries'), findsOneWidget);
      expect(find.text('Write report'), findsOneWidget);
      expect(find.text('Call dentist'), findsOneWidget);
    });

    testWidgets('tapping undone task opens bottom sheet with options', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'My task'));
        await seedTodaysFive(db, [id]);
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
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Started task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Stop working'), findsOneWidget);
      expect(find.text('In progress'), findsNothing);
    });

    testWidgets('uncompleting an externally "Done today" task clears the DB '
        'worked-on flag (I-51)', (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Ext done'));
        await seedTodaysFive(db, [id]);
        // Marked "Done today" OUTSIDE Today's 5 (e.g. All Tasks leaf detail):
        // sets last_worked_at in the DB, but never touches the screen's session
        // sets — so _workedOnIds does NOT contain it, only isWorkedOnToday is true.
        await db.markWorkedOn(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Renders as done via isWorkedOnToday.
      expect(find.byIcon(Icons.check_circle), findsWidgets);

      // Tap the done card → _handleUncomplete. Drive it in real async so the
      // provider's DB writes and the listener-driven refresh serialize on the
      // shared DB connection instead of interleaving under FakeAsync.
      await tester.runAsync(() async {
        await tester.tap(find.text('Ext done'));
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Before the I-51 fix both revert branches were skipped (wasWorkedOn was
      // false and isCompleted false), so the DB kept last_worked_at=today and the
      // task bounced back to "done" on the next reload/sync. It must now be cleared.
      final refreshed = await tester.runAsync(() => db.getTaskById(id));
      expect(refreshed!.isWorkedOnToday, isFalse);
    });

    testWidgets('navigate button calls onNavigateToTask', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Navigate me'));
        await seedTodaysFive(db, [id]);
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
        final id = await db.insertTask(Task(name: 'Task 1'));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Progress is now segmented (Row of Container widgets), not a LinearProgressIndicator
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // Verify the segmented progress row exists by checking for the row structure
      // built by _buildSegmentedProgress: a Row containing Expanded > Container widgets
      expect(find.byType(Row), findsWidgets);
    });

    testWidgets('shows high priority flag icon', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Urgent', priority: 2));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flag), findsOneWidget);
    });

    testWidgets('shows someday bedtime icon', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Eventually', isSomeday: true));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.bedtime), findsOneWidget);
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

    testWidgets('Bug c: new pinned task from add dialog survives refreshSnapshots', (tester) async {
      // Scenario: user adds a new task and pins it from the add dialog
      // (task list screen writes new task to DB's today's 5 list),
      // then swipes to Today's 5. New task should appear pinned.
      late int id1, id2, id3, id4, id5, idNew;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Existing 1'));
        id2 = await db.insertTask(Task(name: 'Existing 2'));
        id3 = await db.insertTask(Task(name: 'Existing 3'));
        id4 = await db.insertTask(Task(name: 'Existing 4'));
        id5 = await db.insertTask(Task(name: 'Existing 5'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4, id5],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Simulate task list screen adding a new task and pinning it
      // (replaces last slot in DB)
      await tester.runAsync(() async {
        idNew = await db.insertTask(Task(name: 'Newly Added'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4, idNew],  // id5 replaced by idNew
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {id1, id2, id3, id4, idNew},
        );
      });

      // Trigger refreshSnapshots
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // New task should appear in the list (implicit-pin model)
      expect(find.text('Newly Added'), findsOneWidget);

      // Verify DB state is correct (not overwritten)
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(idNew));
    });

    testWidgets('refreshSnapshots preserves completed state across external pin change', (tester) async {
      // Verifies that completed state (persisted to DB) is preserved when
      // refreshSnapshots detects external pin changes and does a full reload.
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Done task'));
        id2 = await db.insertTask(Task(name: 'Other task'));
        // Pre-save with id1 marked as worked-on
        await db.markWorkedOn(id1);
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {id1},
          workedOnIds: {id1},
          pinnedIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Task 1 should show as done
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Simulate external pin modification in DB
      await tester.runAsync(() async {
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {id1},
          workedOnIds: {id1},
          pinnedIds: {id2},  // External pin change
        );
      });

      // Trigger refreshSnapshots
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Task 1 should still show as done (completed state preserved from DB)
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('refreshSnapshots picks up eagerly transferred pin from parent to child', (tester) async {
      // Scenario: parent task was pinned in Today's 5, user added a subtask
      // making parent non-leaf. Task list screen eagerly transferred the pin
      // to the child in DB. Today's 5 screen should pick this up.
      late int idParent, idChild, idOther1, idOther2, idOther3;
      await tester.runAsync(() async {
        idParent = await db.insertTask(Task(name: 'Parent task'));
        idOther1 = await db.insertTask(Task(name: 'Other 1'));
        idOther2 = await db.insertTask(Task(name: 'Other 2'));
        idOther3 = await db.insertTask(Task(name: 'Other 3'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idParent, idOther1, idOther2, idOther3],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {idParent},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Parent should appear in the list (implicit-pin model)
      expect(find.text('Parent task'), findsOneWidget);

      // Simulate: task list screen added subtask and transferred pin in DB
      await tester.runAsync(() async {
        idChild = await db.insertTask(Task(name: 'Child task'));
        await db.addRelationship(idParent, idChild);
        // Eager transfer: replace parent with child in Today's 5, move pin
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idChild, idOther1, idOther2, idOther3],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {idChild},
        );
      });

      // Trigger refreshSnapshots
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Child should appear in the list, parent should be gone
      expect(find.text('Child task'), findsOneWidget);

      // Verify DB state preserved correctly
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(idChild));
      expect(saved.taskIds, isNot(contains(idParent)));
    });

    testWidgets('no-change refreshSnapshots does not reload from DB', (tester) async {
      // When DB state matches in-memory state, refreshSnapshots should
      // NOT trigger a full reload — just refresh task snapshots.
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Stable 1'));
        id2 = await db.insertTask(Task(name: 'Stable 2'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {id1},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Verify initial state — both tasks visible
      expect(find.text('Stable 1'), findsOneWidget);
      expect(find.text('Stable 2'), findsOneWidget);

      // Trigger refreshSnapshots with NO external changes
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // State should be unchanged — both tasks still visible
      expect(find.text('Stable 1'), findsOneWidget);
      expect(find.text('Stable 2'), findsOneWidget);

      // DB should still have both tasks
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, containsAll([id1, id2]));
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
      // Simulate: laptop has a manually-pinned local set, then sync brings
      // different tasks from phone. The screen should show phone's tasks.
      late int idC, idD, idE;
      await tester.runAsync(() async {
        // Create tasks that will be in both local and remote sets
        await db.insertTask(Task(name: 'Phone Task A', syncId: 'sync-a'));
        await db.insertTask(Task(name: 'Phone Task B', syncId: 'sync-b'));
        // These are the locally-pinned set (manual model: must be seeded)
        idC = await db.insertTask(Task(name: 'Laptop Task C', syncId: 'sync-c'));
        idD = await db.insertTask(Task(name: 'Laptop Task D', syncId: 'sync-d'));
        idE = await db.insertTask(Task(name: 'Laptop Task E', syncId: 'sync-e'));
        await seedTodaysFive(db, [idC, idD, idE]);
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

      // Load the widget — it restores the locally-pinned set
      await pumpAndLoad(tester, widget);
      expect(find.text('Nothing pinned yet'), findsNothing);
      expect(find.text('Laptop Task C'), findsOneWidget);

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

  group('deadline removal on Done today', () {
    testWidgets('shows Remove deadline dialog when task has a due_by deadline', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(
          name: 'Deadline task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Tap task to open bottom sheet
      await tester.tap(find.text('Deadline task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Tap "Done today"
      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      // The "Remove deadline?" dialog should appear
      expect(find.text('Remove deadline?'), findsOneWidget);
      expect(find.textContaining('due by Apr 15, 2026'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('shows Remove deadline dialog with "on" label for "on" type deadline', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(
          name: 'Scheduled task',
          deadline: '2026-01-10',
          deadlineType: 'on',
        ));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Scheduled task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      expect(find.text('Remove deadline?'), findsOneWidget);
      expect(find.textContaining('scheduled on Jan 10, 2026'), findsOneWidget);
    });

    testWidgets('tapping Keep preserves the deadline', (tester) async {
      late int taskId;
      await tester.runAsync(() async {
        taskId = await db.insertTask(Task(
          name: 'Keep deadline task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [taskId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Keep deadline task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      // Tap Keep
      await tester.tap(find.text('Keep'));
      // Pump through completion animation timer (700ms) and async work
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 40);

      // Verify deadline is preserved in DB
      final task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.deadline, '2026-04-15');
      expect(task.deadlineType, 'due_by');
    });

    testWidgets('tapping Remove clears the deadline', (tester) async {
      late int taskId;
      await tester.runAsync(() async {
        taskId = await db.insertTask(Task(
          name: 'Remove deadline task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [taskId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Remove deadline task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      // Tap Remove
      await tester.tap(find.text('Remove'));
      // Pump through completion animation timer (700ms) and async work
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 40);

      // Verify deadline is removed in DB
      final task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.deadline, isNull);
    });

    testWidgets('snackbar undo after Remove restores the deadline', (tester) async {
      late int taskId;
      await tester.runAsync(() async {
        taskId = await db.insertTask(Task(
          name: 'Undo remove task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [taskId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Undo remove task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      // Tap Remove
      await tester.tap(find.text('Remove'));
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 40);

      // Deadline should be gone
      var task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.deadline, isNull);

      // Invoke the SnackBarAction's onPressed directly — snackbar overlay
      // doesn't pass hit-test in FakeAsync widget tests.
      final action = tester.widget<SnackBarAction>(
        find.widgetWithText(SnackBarAction, 'Undo'),
      );
      action.onPressed();
      await pumpAsync(tester, rounds: 40);

      // Deadline should be restored
      task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.deadline, '2026-04-15');
      expect(task.deadlineType, 'due_by');
    });

    testWidgets('no dialog shown for task without deadline', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'No deadline task'));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('No deadline task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      // Pump enough to see if dialog appears, but also advance the
      // completion animation timer (700ms) so it doesn't remain pending.
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 40);

      // No deadline dialog should appear — should go straight to animation
      expect(find.text('Remove deadline?'), findsNothing);
    });

    testWidgets('dismissing dialog cancels the Done today action', (tester) async {
      late int taskId;
      await tester.runAsync(() async {
        taskId = await db.insertTask(Task(
          name: 'Cancel task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [taskId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Cancel task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Done today'));
      await pumpAsync(tester, rounds: 10);

      expect(find.text('Remove deadline?'), findsOneWidget);

      // Dismiss by tapping the barrier (outside the dialog)
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 20);

      // Task should NOT be marked done — deadline preserved, no completion
      final task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.deadline, '2026-04-15');
      expect(task.isWorkedOnToday, isFalse);
    });

    testWidgets('Done for good does not show deadline dialog and preserves deadline', (tester) async {
      late int taskId;
      await tester.runAsync(() async {
        taskId = await db.insertTask(Task(
          name: 'Complete task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
        await seedTodaysFive(db, [taskId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Complete task'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Tap "Done for good!" instead of "Done today"
      await tester.tap(find.text('Done for good!'));
      // Pump through getDependentTaskNames async call + completion animation
      await pumpAsync(tester, rounds: 10);
      await tester.pump(const Duration(milliseconds: 800));
      await pumpAsync(tester, rounds: 40);

      // No deadline dialog should have appeared
      expect(find.text('Remove deadline?'), findsNothing);

      // Task is completed but deadline is still in DB (untouched)
      final task = await tester.runAsync(() => db.getTaskById(taskId));
      expect(task!.isCompleted, isTrue);
      expect(task.deadline, '2026-04-15');
      expect(task.deadlineType, 'due_by');
    });
  });

  group('scheduled-today icon in card subtitle', () {
    testWidgets('shows scheduledTodayIcon for task scheduled today', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Weekly standup'));
        // Schedule for today's day of the week
        final todayDow = DateTime.now().weekday; // 1=Mon..7=Sun
        await db.replaceSchedules(id, [
          TaskSchedule(taskId: id, dayOfWeek: todayDow),
        ]);
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Weekly standup'), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsOneWidget);
    });

    testWidgets('no scheduledTodayIcon for task not scheduled today', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Other day task'));
        // Schedule for a different day of the week
        final todayDow = DateTime.now().weekday;
        final otherDow = (todayDow % 7) + 1; // next day
        await db.replaceSchedules(id, [
          TaskSchedule(taskId: id, dayOfWeek: otherDow),
        ]);
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Other day task'), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsNothing);
    });

    testWidgets('no scheduledTodayIcon for task with no schedule', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Unscheduled task'));
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Unscheduled task'), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsNothing);
    });

    testWidgets('shows both deadline and scheduledToday icons', (tester) async {
      await tester.runAsync(() async {
        final tomorrow = DateTime.now().add(const Duration(days: 3));
        final dl = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
        final id = await db.insertTask(Task(
          name: 'Scheduled with deadline',
          deadline: dl,
          deadlineType: 'due_by',
        ));
        final todayDow = DateTime.now().weekday;
        await db.replaceSchedules(id, [
          TaskSchedule(taskId: id, dayOfWeek: todayDow),
        ]);
        await seedTodaysFive(db, [id]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Scheduled with deadline'), findsOneWidget);
      expect(find.byIcon(deadlineIcon), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsOneWidget);
    });
  });

  // Removed groups: 'backfill passes schedule/deadline/norm params',
  // 'reserved scheduled slots in _generateNewSet', and 'Roulette terminology'.
  // The auto-selection / reroll / spin model has been replaced with the
  // manual-only model — pins are user-driven.

  group('implicit-pin model: remove from Today\'s 5', () {
    testWidgets("Remove tile in bottom sheet shows confirmation dialog", (tester) async {
      late int id1;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Up for removal'));
        await seedTodaysFive(db, [id1]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Open bottom sheet for the task
      await tester.tap(find.text('Up for removal'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text("Remove from Today’s 5"), findsOneWidget);
      await tester.tap(find.text("Remove from Today’s 5"));
      await pumpAsync(tester, rounds: 20);

      // Confirmation dialog should be visible
      expect(find.text("Remove from Today’s 5?"), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('Cancel in confirmation keeps the task', (tester) async {
      late int id1;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Stays put'));
        await seedTodaysFive(db, [id1]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Stays put'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text("Remove from Today’s 5"));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Cancel'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 10);

      // Task should still be visible
      expect(find.text('Stays put'), findsOneWidget);

      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.taskIds, contains(id1));
    });

    testWidgets('Confirm in confirmation removes the task', (tester) async {
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Stays'));
        id2 = await db.insertTask(Task(name: 'Goes'));
        await seedTodaysFive(db, [id1, id2]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Goes'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text("Remove from Today’s 5"));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 10);

      // Removed task is gone, the other survives
      expect(find.text('Goes'), findsNothing);
      expect(find.text('Stays'), findsOneWidget);

      // Task itself still exists in the DB (only removed from Today's 5)
      final stillExists = await tester.runAsync(() => db.getTaskById(id2));
      expect(stillExists, isNotNull);

      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.taskIds, isNot(contains(id2)));
      expect(saved.taskIds, contains(id1));
    });

    testWidgets('Card X button also opens confirmation', (tester) async {
      await tester.runAsync(() async {
        final id1 = await db.insertTask(Task(name: 'X-removable'));
        await seedTodaysFive(db, [id1]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // The card's trailing X button (close icon)
      final removeBtn = find.widgetWithIcon(IconButton, Icons.close);
      expect(removeBtn, findsOneWidget);
      await tester.tap(removeBtn);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text("Remove from Today’s 5?"), findsOneWidget);
    });
  });

  group('deadline-today auto-pin', () {
    // Manual model exception: leaf tasks whose deadline is exactly today are
    // force-pinned into Today's 5 on every load, unless the user removed
    // (suppressed) them today. Overdue deadlines are NOT auto-pinned.
    String yesterdayKey() {
      final d = DateTime.now().subtract(const Duration(days: 1));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    testWidgets('auto-pins a leaf due today even with no saved state',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Due today', deadline: _todayKey()));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Nothing pinned yet'), findsNothing);
      expect(find.text('Due today'), findsOneWidget);
      // Persisted into Today's 5 state so it survives a reload.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(id));
    });

    testWidgets('does NOT auto-pin an overdue (yesterday) deadline',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Overdue', deadline: yesterdayKey()));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Nothing pinned yet'), findsOneWidget);
      expect(find.text('Overdue'), findsNothing);
    });

    testWidgets('reconcile does not re-pin a suppressed deadline task',
        (tester) async {
      await tester.runAsync(() async {
        final id =
            await db.insertTask(Task(name: 'Removed today', deadline: _todayKey()));
        // Simulate the user having removed it earlier today.
        await db.suppressDeadlineAutoPin(_todayKey(), id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Removed today'), findsNothing);
      expect(find.text('Nothing pinned yet'), findsOneWidget);
    });

    testWidgets('removing one deadline task still auto-pins a different one',
        (tester) async {
      // User's scenario: A was due today and got removed (suppressed); then B
      // also becomes due today. Reconcile must pin B without re-pinning A.
      late int idA;
      await tester.runAsync(() async {
        idA = await db.insertTask(Task(name: 'Task A', deadline: _todayKey()));
        await db.insertTask(Task(name: 'Task B', deadline: _todayKey()));
        await db.suppressDeadlineAutoPin(_todayKey(), idA);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Task A'), findsNothing);
      expect(find.text('Task B'), findsOneWidget);
    });

    testWidgets('refreshSnapshots auto-pins a task that became due today '
        '(no full reload / restart needed)', (tester) async {
      // Bug fix: a deadline set to today while the app is open must auto-pin
      // on the next refresh (provider notify / tab focus), not only on restart.
      late int seeded, becameDue;
      await tester.runAsync(() async {
        seeded = await db.insertTask(Task(name: 'Already pinned'));
        await seedTodaysFive(db, [seeded]);
        becameDue = await db.insertTask(Task(name: 'Newly due'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Already pinned'), findsOneWidget);
      expect(find.text('Newly due'), findsNothing);

      // Simulate the deadline being set to today from another screen, then a
      // provider-driven refresh (no widget rebuild / restart).
      await tester.runAsync(() async {
        await db.updateTaskDeadline(becameDue, _todayKey());
      });
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.text('Newly due'), findsOneWidget);
      expect(find.text('Already pinned'), findsOneWidget);
    });

    testWidgets('refreshSnapshots does NOT re-pin a suppressed deadline task',
        (tester) async {
      // Regression for the new refreshSnapshots reconcile path: removing a
      // deadline-today task suppresses it; a later provider-driven refresh
      // (NOT a full reload/restart) must not bring it back.
      late int pinnedB;
      await tester.runAsync(() async {
        pinnedB = await db.insertTask(Task(name: 'Plain pinned B'));
        await seedTodaysFive(db, [pinnedB]);
        // Referenced by name in finders below, so its id isn't captured.
        await db.insertTask(Task(name: 'Deadline A', deadline: _todayKey()));
      });

      await pumpAndLoad(tester, buildTestWidget());
      // Reconcile auto-pinned the deadline task alongside the manual pin.
      expect(find.text('Deadline A'), findsOneWidget);
      expect(find.text('Plain pinned B'), findsOneWidget);

      // Remove the deadline task specifically (via its bottom sheet) → suppresses it.
      await tester.tap(find.text('Deadline A'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text("Remove from Today’s 5"));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 10);
      expect(find.text('Deadline A'), findsNothing);

      // A provider-driven refresh must NOT re-pin the suppressed task.
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.text('Deadline A'), findsNothing);
      expect(find.text('Plain pinned B'), findsOneWidget);
    });

    testWidgets('removing an auto-pinned deadline task suppresses it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Auto-pinned', deadline: _todayKey()));
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Auto-pinned'), findsOneWidget);

      // Remove via the card's X button → confirm.
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 10);

      expect(find.text('Auto-pinned'), findsNothing);
      // Removal recorded as a suppression so reconcile won't re-pin it today.
      final suppressed =
          await tester.runAsync(() => db.getDeadlineSuppressedIds(_todayKey()));
      expect(suppressed, contains(id));
      // Removing the only task leaves an empty (null) state — the task is gone.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved?.taskIds ?? const <int>[], isNot(contains(id)));
    });

    // [Mechanism] The deadline auto-pin is a MERGE into the saved manual set,
    // not a replacement: an existing user pin and a freshly-due deadline task
    // must both appear. Existing group tests only exercise deadline-only sets.
    testWidgets('merges deadline auto-pin with an existing manual pin',
        (tester) async {
      late int manualId;
      late int deadlineId;
      await tester.runAsync(() async {
        manualId = await db.insertTask(Task(name: 'Manual pin'));
        deadlineId =
            await db.insertTask(Task(name: 'Due today', deadline: _todayKey()));
        await seedTodaysFive(db, [manualId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Manual pin'), findsOneWidget);
      expect(find.text('Due today'), findsOneWidget);
      // Both persisted into the merged Today's 5 set.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, containsAll([manualId, deadlineId]));
    });

    // [Edge case] When more deadline-today tasks exist than the maxPins cap, the
    // merge loop currently adds ALL of them (it has no cap) — so the auto-pin
    // path can push the set beyond maxPins. This documents the actual behavior;
    // if a cap is ever added, this test should be updated to assert it.
    testWidgets('auto-pins every deadline task even beyond the maxPins cap',
        (tester) async {
      final ids = <int>[];
      await tester.runAsync(() async {
        for (var i = 0; i < maxPins + 1; i++) {
          ids.add(await db
              .insertTask(Task(name: 'Due $i', deadline: _todayKey())));
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      // All maxPins+1 deadline tasks are pinned (no cap on the auto-pin merge).
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, containsAll(ids));
      expect(saved.taskIds.length, greaterThan(maxPins));
    });

    // [Edge case] A deadline-today task that's already completed must NOT be
    // auto-pinned on load — getDeadlinePinLeafIds() excludes completed leaves,
    // so a finished task doesn't reappear as a fresh pin the next day-load.
    testWidgets('does NOT auto-pin a completed deadline-today task',
        (tester) async {
      await tester.runAsync(() async {
        final id = await db
            .insertTask(Task(name: 'Done deadline', deadline: _todayKey()));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Done deadline'), findsNothing);
      expect(find.text('Nothing pinned yet'), findsOneWidget);
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved?.taskIds ?? const <int>[], isEmpty);
    });

    // [Regression] Manually re-pinning a previously-suppressed deadline task
    // must clear its suppression (via unsuppressDeadlineAutoPin), so it's once
    // again treated as a normal member. This exercises the _pinTaskInTodaysFive
    // unsuppress path — distinct from the existing tests, none of which re-pin.
    testWidgets('re-pinning a suppressed deadline task clears its suppression',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db
            .insertTask(Task(name: 'Re-pin me', deadline: _todayKey()));
        // User removed it earlier today → suppressed, so it loads empty.
        await db.suppressDeadlineAutoPin(_todayKey(), id);
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Nothing pinned yet'), findsOneWidget);

      // Re-pin via the FAB → Pick existing → tap the task.
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await pumpAsync(tester, rounds: 15);
      }

      await tester.tap(find.byType(FloatingActionButton));
      await settle();
      await tester.tap(find.text('Pick existing task'));
      await settle();
      await tester.tap(find.text('Re-pin me'));
      await settle();

      expect(find.text('Re-pin me'), findsOneWidget);
      // Suppression is cleared, so the task is a normal member again.
      final suppressed =
          await tester.runAsync(() => db.getDeadlineSuppressedIds(_todayKey()));
      expect(suppressed, isNot(contains(id)));
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(id));
    });

    // [Baseline] After the user removes an auto-pinned deadline task (recorded
    // as a suppression), a subsequent full reload must keep it gone — the
    // suppression persists for the rest of the day. Existing test 3 pre-seeds
    // the suppression; this exercises remove → reload end-to-end.
    testWidgets('suppression persists across a reload after removal',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db
            .insertTask(Task(name: 'Gone for today', deadline: _todayKey()));
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Gone for today'), findsOneWidget);

      // Remove via the card's X → confirm.
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 10);
      expect(find.text('Gone for today'), findsNothing);

      // Rebuild the screen from scratch (simulates the next reconcile / fresh
      // load). The _loadTodaysTasksInner pipeline must honor the suppression and
      // NOT re-pin the removed deadline task.
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Gone for today'), findsNothing);
      expect(find.text('Nothing pinned yet'), findsOneWidget);
      final suppressed =
          await tester.runAsync(() => db.getDeadlineSuppressedIds(_todayKey()));
      expect(suppressed, contains(id));
    });
  });

  group('Add to Today\'s 5 FAB sheet', () {
    // Advances route (sheet/dialog) animations AND async DB loads together.
    Future<void> settleRoute(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 15);
    }

    testWidgets('FAB opens sheet with Create new / Pick existing options',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);

      expect(find.text("Add to Today’s 5"), findsOneWidget);
      expect(find.text('Create new task'), findsOneWidget);
      expect(find.text('Pick existing task'), findsOneWidget);
    });

    testWidgets('Pick existing opens the PickTaskForTodayDialog', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Pickable leaf'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);
      await tester.tap(find.text('Pick existing task'));
      await settleRoute(tester);

      // The picker dialog is shown, listing the leaf task.
      expect(find.text("Pin a task to Today’s 5"), findsOneWidget);
      expect(find.text('Pickable leaf'), findsOneWidget);
    });

    testWidgets('picking an existing task pins it into Today\'s 5',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        leafId = await db.insertTask(Task(name: 'Pin me'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Empty to start (manual model).
      expect(find.text('Nothing pinned yet'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);
      await tester.tap(find.text('Pick existing task'));
      await settleRoute(tester);
      await tester.tap(find.text('Pin me'));
      await settleRoute(tester);

      // The task is now in Today's 5 and persisted.
      expect(find.text('Nothing pinned yet'), findsNothing);
      expect(find.text('Pin me'), findsOneWidget);

      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.taskIds, contains(leafId));
      expect(saved.pinnedIds, contains(leafId));
    });

    testWidgets('picker excludes tasks already in Today\'s 5', (tester) async {
      late int pinnedId;
      await tester.runAsync(() async {
        pinnedId = await db.insertTask(Task(name: 'Already here'));
        await db.insertTask(Task(name: 'Not yet'));
        await seedTodaysFive(db, [pinnedId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);
      await tester.tap(find.text('Pick existing task'));
      await settleRoute(tester);

      // The pinned task is excluded from the picker; the other is selectable.
      expect(find.text("Pin a task to Today’s 5"), findsOneWidget);
      expect(find.text('Not yet'), findsOneWidget);
      // "Already here" appears only in the background Today's 5 card, not in
      // the picker dialog list. Two matches would mean it leaked into the
      // picker; we expect exactly one (the background card).
      expect(find.text('Already here'), findsOneWidget);
    });
  });

  group('+ FAB visibility at max pins', () {
    // [Mechanism] Once Today's 5 holds maxPins tasks, the + FAB is hidden so
    // there's never an add button that can only fail with a "full" message.
    testWidgets('+ FAB is hidden when Today\'s 5 is full', (tester) async {
      await tester.runAsync(() async {
        final ids = <int>[];
        for (var i = 0; i < maxPins; i++) {
          ids.add(await db.insertTask(Task(name: 'Pinned $i')));
        }
        await seedTodaysFive(db, ids);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byType(FloatingActionButton), findsNothing);
    });

    // [Baseline] Below the limit the + FAB is present.
    testWidgets('+ FAB is shown when below the pin limit', (tester) async {
      await tester.runAsync(() async {
        final ids = <int>[];
        for (var i = 0; i < maxPins - 1; i++) {
          ids.add(await db.insertTask(Task(name: 'Pinned $i')));
        }
        await seedTodaysFive(db, ids);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('midnight rollover (manual-model empty-at-start)', () {
    // [Regression] Bug: the empty/no-saved-state load path returned without
    // clearing _todaysTasks, so on rollover to an empty day yesterday's tasks
    // lingered (shown undone, then re-marked done on the next refresh). The
    // debug night icon deletes today's state and triggers the same reload path
    // as a real midnight rollover — the screen must end at the empty state.
    testWidgets('rollover clears yesterday\'s tasks to the empty state',
        (tester) async {
      await tester.runAsync(() async {
        final id1 = await db.insertTask(Task(name: 'Yesterday A'));
        final id2 = await db.insertTask(Task(name: 'Yesterday B'));
        await seedTodaysFive(db, [id1, id2]);
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Yesterday A'), findsOneWidget);

      // Simulate midnight rollover (debug-only icon; kDebugMode is true here).
      await tester.tap(find.byTooltip('Simulate midnight rollover'));
      await pumpAsync(tester, rounds: 10);

      expect(find.text('Yesterday A'), findsNothing);
      expect(find.text('Yesterday B'), findsNothing);
      expect(find.text('Nothing pinned yet'), findsOneWidget);
    });
  });

  group('"already exists" suggestion → Pin instead (create-new flow)', () {
    // The FAB → "Create new task" dialog is seeded with existingTasks so that
    // typing a name matching an existing task surfaces the inline "did you
    // mean" suggestion. Tapping it ("Pin instead") pops UseExisting, and the
    // screen pins the existing task instead of creating a duplicate.
    Future<void> settleRoute(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pumpAsync(tester, rounds: 15);
    }

    // Opens FAB sheet → Create new task → types [name] and taps the suggestion.
    Future<void> tapSuggestion(WidgetTester tester, String name) async {
      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);
      await tester.tap(find.text('Create new task'));
      await settleRoute(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await settleRoute(tester);
      // Open the popup and settle its open animation (settleRoute advances no
      // fake time, leaving the menu collapsed at the anchor and unhittable),
      // then select the match by its action icon (push_pin).
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.push_pin));
      });
      await settleRoute(tester);
    }

    // [Mechanism] Tapping the suggestion pins the EXISTING task into Today's 5
    // (via _pinTaskInTodaysFive) rather than inserting a second task with the
    // same name — the core "don't duplicate" guarantee for this surface.
    testWidgets('pins the existing task instead of creating a duplicate',
        (tester) async {
      late int existingId;
      await tester.runAsync(() async {
        existingId = await db.insertTask(Task(name: 'Buy milk'));
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Nothing pinned yet'), findsOneWidget);

      await tapSuggestion(tester, 'buy MILK');

      // Existing task is now pinned; no duplicate created.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(existingId));
      expect(saved.pinnedIds, contains(existingId));
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Buy milk'), hasLength(1),
          reason: 'no duplicate task created');
    });

    // [Edge case] When the matched task is ALREADY in Today's 5, tapping the
    // suggestion must NOT re-pin it (which would duplicate the slot) — the
    // screen shows the "already in Today's 5" snackbar and leaves state intact.
    testWidgets('already-pinned match shows snackbar and does not re-add',
        (tester) async {
      late int existingId;
      await tester.runAsync(() async {
        existingId = await db.insertTask(Task(name: 'Buy milk'));
        await seedTodaysFive(db, [existingId]);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tapSuggestion(tester, 'Buy milk');

      expect(find.textContaining('already in Today'), findsOneWidget);
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      // Still exactly one slot for the task — no duplicate slot appended.
      expect(saved!.taskIds, [existingId]);
    });

    // [Mechanism] The Today's 5 match pool is LEAF tasks only (getAllLeafTasks)
    // — Today's 5 can only hold leaves, so a same-named NON-leaf parent must not
    // be offered as a "Pin instead" target (pinning it would be invalid). Typing
    // a non-leaf's name surfaces no suggestion at all.
    testWidgets('non-leaf match is not offered as a Pin-instead suggestion',
        (tester) async {
      await tester.runAsync(() async {
        // "Chores" is a non-leaf (has a child) → excluded from the leaf pool.
        final parentId = await db.insertTask(Task(name: 'Chores'));
        final childId = await db.insertTask(Task(name: 'Sweep floor'));
        await db.addRelationship(parentId, childId);
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Open FAB sheet → Create new task → type the non-leaf's exact name.
      await tester.tap(find.byType(FloatingActionButton));
      await settleRoute(tester);
      await tester.tap(find.text('Create new task'));
      await settleRoute(tester);
      await tester.enterText(find.byType(TextField).first, 'chores');
      await settleRoute(tester);

      // No indicator: the non-leaf isn't in the leaf-only pool, so nothing
      // matches and the in-field "did you mean" badge never appears.
      expect(find.byIcon(Icons.info_outline), findsNothing);
    });
  });
}
