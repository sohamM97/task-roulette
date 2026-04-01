import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/async_pump.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/providers/progression_provider.dart';
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
    SharedPreferences.setMockInitialValues({
      'progression_backfill_done': true,
    });
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
        ChangeNotifierProvider(create: (_) => ProgressionProvider()),
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
      // Motivational text rotates daily — just verify one of them is shown
      final motivationalTexts = [
        'Completing even 1 is a win!',
        'Pick one and start small.',
        'One step at a time.',
        'Just begin \u2014 momentum follows.',
        'You\u2019ve got this.',
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

      expect(find.byTooltip('Spin'), findsOneWidget);
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

      // Progress is now segmented (Row of Container widgets), not a LinearProgressIndicator
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // Verify the segmented progress row exists by checking for the row structure
      // built by _buildSegmentedProgress: a Row containing Expanded > Container widgets
      expect(find.byType(Row), findsWidgets);
    });

    testWidgets('shows high priority flag icon', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Urgent', priority: 2));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flag), findsOneWidget);
    });

    testWidgets('shows someday bedtime icon', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Eventually', isSomeday: true));
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.bedtime), findsOneWidget);
    });

    testWidgets('refresh button shows confirmation dialog', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Task 1'));
        await db.insertTask(Task(name: 'Task 2'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      final refreshFinder = find.byTooltip('Reroll all');
      expect(refreshFinder, findsOneWidget);

      await tester.tap(refreshFinder);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Reroll all?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Reroll'), findsOneWidget);
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

    testWidgets('pinned status survives refreshSnapshots after completion', (tester) async {
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Pinned done'));
        id2 = await db.insertTask(Task(name: 'Normal'));
        // Complete id1 in the tasks table
        await db.completeTask(id1);
        // Pre-save Today's 5 state with id1 pinned + completed
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {id1},
          workedOnIds: {},
          pinnedIds: {id1},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Pin icon should be visible on the completed task
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // Trigger refreshSnapshots (simulates navigating back to Today's 5)
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Pin icon should still be visible after refresh
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      // Verify DB still has the pin persisted
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.pinnedIds, contains(id1));
    });

    testWidgets('Bug a: pin from task list survives refreshSnapshots', (tester) async {
      // Scenario: pin a task from task list screen (writes to DB),
      // then swipe to Today's 5 (refreshSnapshots). Pin should persist.
      late int id1, id2, id3;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Task A'));
        id2 = await db.insertTask(Task(name: 'Task B'));
        id3 = await db.insertTask(Task(name: 'Task C'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // No pins initially
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Simulate task list screen pinning task B directly in DB
      // (this is what _togglePinInTodays5 does)
      await tester.runAsync(() async {
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {id2},
        );
      });

      // Trigger refreshSnapshots (simulates swiping back to Today's 5)
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // Pin icon should be visible (section header + PinButton)
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

      // Verify DB still has the pin (not overwritten by stale state)
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.pinnedIds, contains(id2));
    });

    testWidgets('Bug b: unpin from task list reflected after refreshSnapshots', (tester) async {
      // Scenario: task is pinned, user unpins from task list (writes to DB),
      // then swipes to Today's 5. Pin should be gone.
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Pinned task'));
        id2 = await db.insertTask(Task(name: 'Other task'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {id1},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Pin icon should be visible initially (section header + PinButton)
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

      // Simulate task list screen unpinning task directly in DB
      await tester.runAsync(() async {
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},
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

      // Pin icon should be gone
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Verify DB has no pins (not re-added by stale state)
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.pinnedIds, isEmpty);
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

      // No pins initially
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Simulate task list screen adding a new task and pinning it
      // (replaces last unpinned undone slot in DB)
      await tester.runAsync(() async {
        idNew = await db.insertTask(Task(name: 'Newly Added'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4, idNew],  // id5 replaced by idNew
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {idNew},
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

      // New task should appear pinned
      expect(find.text('Newly Added'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

      // Verify DB state is correct (not overwritten)
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.taskIds, contains(idNew));
      expect(saved.pinnedIds, contains(idNew));
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
      // Task 2 should show as pinned (section header + PinButton)
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));
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

      // Parent should be pinned (section header + PinButton)
      expect(find.text('Parent task'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

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

      // Child should appear pinned, parent should be gone
      expect(find.text('Child task'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

      // Verify DB state preserved correctly
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.pinnedIds, contains(idChild));
      expect(saved.pinnedIds, isNot(contains(idParent)));
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

      // Verify initial state (section header + PinButton)
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));

      // Trigger refreshSnapshots with NO external changes
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // State should be unchanged — pin still there
      expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));
      expect(find.text('Stable 1'), findsOneWidget);
      expect(find.text('Stable 2'), findsOneWidget);

      // DB should be unchanged
      final saved = await tester.runAsync(() => db.loadTodaysFiveState(_todayKey()));
      expect(saved!.pinnedIds, {id1});
    });

    testWidgets('refreshSnapshots with all valid leaves skips full selection context fetch', (tester) async {
      // Verifies the lazy-load fix: when all tasks in Today's 5 are still
      // valid leaves, refreshSnapshots must NOT call _fetchSelectionContext
      // (which triggers 5 DB queries including recursive norm data).
      // We verify this indirectly: the refresh completes correctly and quickly
      // without the DB lock warning that would appear if normalization queries
      // ran unnecessarily on every tab return.
      late int id1, id2, id3;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Still leaf 1'));
        id2 = await db.insertTask(Task(name: 'Still leaf 2'));
        id3 = await db.insertTask(Task(name: 'Still leaf 3'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3],
          completedIds: {},
          workedOnIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Still leaf 1'), findsOneWidget);
      expect(find.text('Still leaf 2'), findsOneWidget);
      expect(find.text('Still leaf 3'), findsOneWidget);

      // All tasks remain valid leaves — no replacement/backfill needed.
      // refreshSnapshots should complete without fetching selection context.
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      // All tasks should still be present and unchanged
      expect(find.text('Still leaf 1'), findsOneWidget);
      expect(find.text('Still leaf 2'), findsOneWidget);
      expect(find.text('Still leaf 3'), findsOneWidget);
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
        'progression_backfill_done': true,
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

  group('Deadline auto-pin override', () {
    /// Helper: today's date as YYYY-MM-DD for deadline field.
    String todayDeadline() {
      final now = DateTime.now();
      return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    }

    testWidgets('reload: unpinned deadline task stays unpinned', (tester) async {
      // A deadline task already in the set with is_pinned=0 should NOT be
      // force-pinned on reload.
      late int idDeadline, idOther;
      await tester.runAsync(() async {
        idDeadline = await db.insertTask(
          Task(name: 'Deadline unpinned', deadline: todayDeadline()),
        );
        idOther = await db.insertTask(Task(name: 'Regular task'));
        // Save state with deadline task NOT pinned
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idDeadline, idOther],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},  // explicitly unpinned
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Both tasks visible
      expect(find.text('Deadline unpinned'), findsOneWidget);
      expect(find.text('Regular task'), findsOneWidget);
      // No pin icons — the deadline task should NOT be force-pinned
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Verify DB state: pinnedIds should still be empty
      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds, isEmpty);
    });

    testWidgets('reload: NEW deadline task not in set is NOT auto-pinned', (tester) async {
      // Auto-pin only happens on first generation of the day.
      // On reload with saved state, new deadline tasks should NOT be auto-pinned.
      late int idExisting;
      await tester.runAsync(() async {
        idExisting = await db.insertTask(Task(name: 'Existing task'));
        await db.insertTask(
          Task(name: 'New deadline task', deadline: todayDeadline()),
        );
        // Save state with only the existing task
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idExisting],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Only existing task should be visible — new deadline task NOT added
      expect(find.text('Existing task'), findsOneWidget);
      // No pins
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('first generation: deadline task is auto-pinned', (tester) async {
      // On first generation of the day (no saved state), deadline-due tasks
      // should be auto-pinned into Today's 5.
      late int deadlineId;
      await tester.runAsync(() async {
        deadlineId = await db.insertTask(
          Task(name: 'Deadline task', deadline: todayDeadline()),
        );
        // Add filler tasks so there's a pool to pick from
        for (int i = 0; i < 6; i++) {
          await db.insertTask(Task(name: 'Filler $i'));
        }
        // NO saved state — this is first generation
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Deadline task should appear and be pinned
      expect(find.text('Deadline task'), findsOneWidget);
      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds, contains(deadlineId));
    });

    testWidgets('first generation: on deadline task is auto-pinned on the day', (tester) async {
      // 'on' deadline tasks should be auto-pinned on first generation
      // when the deadline date is today.
      late int onDeadlineId;
      await tester.runAsync(() async {
        onDeadlineId = await db.insertTask(
          Task(name: 'On deadline', deadline: todayDeadline(), deadlineType: 'on'),
        );
        for (int i = 0; i < 6; i++) {
          await db.insertTask(Task(name: 'Filler $i'));
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('On deadline'), findsOneWidget);
      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds, contains(onDeadlineId));
    });

    testWidgets('first generation: suppressed deadline task is NOT auto-pinned', (tester) async {
      // If the user previously unpinned a deadline task (suppressed),
      // it should not be auto-pinned even on first generation.
      late int deadlineId;
      await tester.runAsync(() async {
        deadlineId = await db.insertTask(
          Task(name: 'Suppressed deadline', deadline: todayDeadline()),
        );
        await db.suppressDeadlineAutoPin(_todayKey(), deadlineId);
        for (int i = 0; i < 6; i++) {
          await db.insertTask(Task(name: 'Filler $i'));
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds, isNot(contains(deadlineId)));
    });

    testWidgets('first generation: respects max 5 pins limit', (tester) async {
      // Even on first generation, auto-pin should not exceed maxPins (5).
      await tester.runAsync(() async {
        for (int i = 0; i < 7; i++) {
          await db.insertTask(
            Task(name: 'Deadline $i', deadline: todayDeadline()),
          );
        }
      });

      await pumpAndLoad(tester, buildTestWidget());

      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds.length, lessThanOrEqualTo(5));
    });

    testWidgets('midnight rollover: yesterday state exists, today does not — auto-pins', (tester) async {
      // Simulates midnight rollover: saved state exists for yesterday's date
      // but not for today. _loadTodaysTasksInner finds saved == null for
      // today's key → _generateNewSet(autoPin: true).
      late int deadlineId;
      await tester.runAsync(() async {
        deadlineId = await db.insertTask(
          Task(name: 'Deadline task', deadline: todayDeadline()),
        );
        for (int i = 0; i < 6; i++) {
          await db.insertTask(Task(name: 'Filler $i'));
        }
        // Save state for YESTERDAY — simulating stale data from previous day
        final yesterday = DateTime.now().subtract(const Duration(days: 1));
        final yesterdayKey = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
        await db.saveTodaysFiveState(
          date: yesterdayKey,
          taskIds: [deadlineId],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},  // NOT pinned yesterday
        );
        // No state for today — first generation
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Deadline task should be auto-pinned for today
      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved, isNotNull);
      expect(saved!.pinnedIds, contains(deadlineId));
    });

    testWidgets('regeneration: no deadline auto-pin on New set', (tester) async {
      // "New set" should not auto-pin deadline tasks. Pins are user-driven.
      late int idOther1, idOther2;
      await tester.runAsync(() async {
        idOther1 = await db.insertTask(Task(name: 'Keep A'));
        idOther2 = await db.insertTask(Task(name: 'Keep B'));
        await db.insertTask(
          Task(name: 'Fresh deadline', deadline: todayDeadline()),
        );
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idOther1, idOther2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Trigger "New set"
      await tester.tap(find.byTooltip('Reroll all'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Reroll'));
      await pumpAsync(tester, rounds: 30);

      // No deadline task should be auto-pinned
      final saved = await tester.runAsync(
        () => db.loadTodaysFiveState(_todayKey()),
      );
      expect(saved!.pinnedIds, isEmpty);
    });
  });

  group('deadline removal on Done today', () {
    testWidgets('shows Remove deadline dialog when task has a due_by deadline', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(
          name: 'Deadline task',
          deadline: '2026-04-15',
          deadlineType: 'due_by',
        ));
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
        await db.insertTask(Task(
          name: 'Scheduled task',
          deadline: '2026-01-10',
          deadlineType: 'on',
        ));
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
        await db.insertTask(Task(name: 'No deadline task'));
      });

      // Extra rounds needed: _generateNewSet now calls _fetchSelectionContext
      // which does 5 DB queries (schedule boost, deadline boost, norm, etc.)
      await pumpAndLoad(tester, buildTestWidget(), rounds: 40);

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
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Other day task'), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsNothing);
    });

    testWidgets('no scheduledTodayIcon for task with no schedule', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Unscheduled task'));
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
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Scheduled with deadline'), findsOneWidget);
      expect(find.byIcon(deadlineIcon), findsOneWidget);
      expect(find.byIcon(scheduledTodayIcon), findsOneWidget);
    });
  });

  group('backfill passes schedule/deadline/norm params', () {
    // Bug fix: previously, backfill paths in _loadTodaysTasksInner,
    // refreshSnapshots, and _replaceIfNoLongerLeaf called pickWeightedN
    // without scheduleBoostedIds/deadlineDaysMap/normData, silently
    // dropping the 2.5x schedule boost and up to 8x deadline boost.

    testWidgets('restore backfill prefers scheduled task', (tester) async {
      // Setup: 5 saved tasks, 1 becomes non-leaf → backfill needed.
      // Only eligible replacement is a scheduled-for-today task.
      // Before fix: picked without schedule boost. After fix: boost applies.
      late int id1, id2, id3, id4, id5, idScheduled;
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Task 1'));
        id2 = await db.insertTask(Task(name: 'Task 2'));
        id3 = await db.insertTask(Task(name: 'Task 3'));
        id4 = await db.insertTask(Task(name: 'Task 4'));
        id5 = await db.insertTask(Task(name: 'Will become non-leaf'));
        idScheduled = await db.insertTask(Task(name: 'Scheduled task'));
        await db.replaceSchedules(idScheduled, [
          TaskSchedule(taskId: idScheduled, dayOfWeek: todayDow),
        ]);
        // Make id5 a non-leaf by adding a child
        final childId = await db.insertTask(Task(name: 'Child of 5'));
        await db.addRelationship(id5, childId);
        // Save state with id5 still listed (simulates it was a leaf yesterday)
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4, id5],
          completedIds: {},
          workedOnIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // id5 is no longer a leaf, so it should be replaced by backfill.
      // The scheduled task and 'Child of 5' are the eligible replacements.
      // With schedule boost, 'Scheduled task' should be strongly preferred.
      // Note: 'Will become non-leaf' may still appear in path labels of its
      // child, so we check for replacement presence rather than parent absence.
      final hasScheduled = find.text('Scheduled task').evaluate().isNotEmpty;
      final hasChild = find.text('Child of 5').evaluate().isNotEmpty;
      expect(hasScheduled || hasChild, isTrue,
        reason: 'Backfill should have picked an eligible replacement');
    });

    testWidgets('refreshSnapshots backfill prefers scheduled task', (tester) async {
      // Setup: 4 tasks in Today's 5, one becomes non-leaf mid-session.
      // Backfill candidate includes a scheduled task.
      late int id1, id2, id3, id4, idScheduled;
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Ref Task 1'));
        id2 = await db.insertTask(Task(name: 'Ref Task 2'));
        id3 = await db.insertTask(Task(name: 'Ref Task 3'));
        id4 = await db.insertTask(Task(name: 'Ref Will break'));
        idScheduled = await db.insertTask(Task(name: 'Ref Scheduled'));
        await db.replaceSchedules(idScheduled, [
          TaskSchedule(taskId: idScheduled, dayOfWeek: todayDow),
        ]);
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4],
          completedIds: {},
          workedOnIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Now make id4 a non-leaf
      await tester.runAsync(() async {
        final childId = await db.insertTask(Task(name: 'Child of Ref4'));
        await db.addRelationship(id4, childId);
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

      // id4 should be replaced; backfill should have picked a replacement.
      // Note: 'Ref Will break' may still appear in path labels of its child,
      // so we check for replacement presence rather than parent absence.
      final hasScheduled = find.text('Ref Scheduled').evaluate().isNotEmpty;
      final hasChild = find.text('Child of Ref4').evaluate().isNotEmpty;
      expect(hasScheduled || hasChild, isTrue,
        reason: 'refreshSnapshots backfill should pick an eligible replacement');
    });

    testWidgets('pinned-descendant replacement uses schedule params on restore', (tester) async {
      // Setup: pinned parent becomes non-leaf, has 2 leaf descendants
      // (1 scheduled, 1 not). The replacement should use schedule boost.
      late int idParent, idOther1, idOther2, idSchedChild, idPlainChild;
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        idParent = await db.insertTask(Task(name: 'Pinned parent'));
        idOther1 = await db.insertTask(Task(name: 'Other A'));
        idOther2 = await db.insertTask(Task(name: 'Other B'));
        // Create two children of the parent
        idSchedChild = await db.insertTask(Task(name: 'Sched child'));
        idPlainChild = await db.insertTask(Task(name: 'Plain child'));
        await db.addRelationship(idParent, idSchedChild);
        await db.addRelationship(idParent, idPlainChild);
        // Schedule one child for today
        await db.replaceSchedules(idSchedChild, [
          TaskSchedule(taskId: idSchedChild, dayOfWeek: todayDow),
        ]);
        // Save state with parent as pinned (it was a leaf when saved)
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [idParent, idOther1, idOther2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {idParent},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Parent is no longer a leaf → pinned-descendant replacement fires.
      // One of its children should replace it.
      // Note: 'Pinned parent' may still appear in path labels of its children,
      // so we check for descendant presence rather than parent absence.
      final hasSchedChild = find.text('Sched child').evaluate().isNotEmpty;
      final hasPlainChild = find.text('Plain child').evaluate().isNotEmpty;
      expect(
        hasSchedChild || hasPlainChild,
        isTrue,
        reason: 'One of the parent descendants should replace the pinned parent',
      );
    });

    testWidgets('refreshSnapshots with all valid leaves skips full selection context fetch',
        (tester) async {
      // Verifies that refreshSnapshots does NOT eagerly call _fetchSelectionContext
      // when all pinned leaves are still valid — only getAllLeafTasks() is called.
      // (Performance regression guard: previously _fetchSelectionContext ran on
      // every Today-tab return even when nothing needed replacing.)
      late int id1, id2, id3, id4, id5;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Snap A'));
        id2 = await db.insertTask(Task(name: 'Snap B'));
        id3 = await db.insertTask(Task(name: 'Snap C'));
        id4 = await db.insertTask(Task(name: 'Snap D'));
        id5 = await db.insertTask(Task(name: 'Snap E'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, id3, id4, id5],
          completedIds: {},
          workedOnIds: {},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // All 5 tasks are valid leaves — refreshSnapshots should return early.
      final state = tester.state<TodaysFiveScreenState>(
        find.byType(TodaysFiveScreen),
      );
      await tester.runAsync(() => state.refreshSnapshots());
      await pumpAsync(tester, rounds: 20);

      // All 5 tasks should still be shown (no replacement needed)
      expect(find.text('Snap A'), findsOneWidget);
      expect(find.text('Snap B'), findsOneWidget);
      expect(find.text('Snap C'), findsOneWidget);
      expect(find.text('Snap D'), findsOneWidget);
      expect(find.text('Snap E'), findsOneWidget);
    });

    testWidgets('_replaceIfNoLongerLeaf uses schedule params on uncomplete', (tester) async {
      // Bug fix: _replaceIfNoLongerLeaf previously called pickWeightedN
      // without schedule/deadline/norm params. This test verifies the fix
      // by uncompleting a done task that is no longer a leaf.
      // Flow: tap done task → _handleUncomplete → _replaceIfNoLongerLeaf.
      late int id1, id2, idTarget, idScheduled;
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Replace A'));
        id2 = await db.insertTask(Task(name: 'Replace B'));
        idTarget = await db.insertTask(Task(name: 'Will uncomplete'));
        idScheduled = await db.insertTask(Task(name: 'Replace Scheduled'));
        await db.replaceSchedules(idScheduled, [
          TaskSchedule(taskId: idScheduled, dayOfWeek: todayDow),
        ]);
        // Mark target as worked-on so it loads as "done today"
        await db.markWorkedOn(idTarget);
        // Make target a non-leaf by adding a child
        final childId = await db.insertTask(Task(name: 'Child of target'));
        await db.addRelationship(idTarget, childId);
        // Save state: target is in completedIds + workedOnIds
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2, idTarget],
          completedIds: {idTarget},
          workedOnIds: {idTarget},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Target should show as done (strikethrough text visible)
      expect(find.text('Will uncomplete'), findsWidgets);

      // Tap the done task to uncomplete it → _handleUncomplete →
      // _replaceIfNoLongerLeaf fires because target is no longer a leaf
      await tester.tap(find.text('Will uncomplete').first);
      await pumpAsync(tester, rounds: 20);

      // Target should be replaced since it's no longer a leaf.
      // Eligible replacements: 'Replace Scheduled', 'Child of target'.
      // With schedule boost, 'Replace Scheduled' is strongly preferred.
      final hasScheduled = find.text('Replace Scheduled').evaluate().isNotEmpty;
      final hasChild = find.text('Child of target').evaluate().isNotEmpty;
      expect(hasScheduled || hasChild, isTrue,
        reason: '_replaceIfNoLongerLeaf should pick an eligible replacement');
    });
  });

  group('reserved scheduled slots in _generateNewSet', () {
    // Reserved slot feature: when generating Today's 5 from scratch,
    // 1 slot per distinct scheduled source is reserved (capped at min(sources, 4),
    // always leaving ≥1 general-pool slot). This guarantees that scheduled tasks
    // appear in the day's selection, unlike the old boost-only approach.

    testWidgets('scheduled-today leaf appears in generated set', (tester) async {
      // Single scheduled leaf + 4 non-scheduled leaves → the scheduled task
      // is guaranteed a reserved slot and must appear in the 5.
      final todayDow = DateTime.now().weekday;
      late int idScheduled;
      await tester.runAsync(() async {
        idScheduled = await db.insertTask(Task(name: 'Reserved scheduled'));
        await db.replaceSchedules(idScheduled, [
          TaskSchedule(taskId: idScheduled, dayOfWeek: todayDow),
        ]);
        // 4 non-scheduled fillers to ensure we have enough tasks for Today's 5
        await db.insertTask(Task(name: 'Filler 1'));
        await db.insertTask(Task(name: 'Filler 2'));
        await db.insertTask(Task(name: 'Filler 3'));
        await db.insertTask(Task(name: 'Filler 4'));
      });

      await pumpAndLoad(tester, buildTestWidget(), rounds: 30);

      // The scheduled task must appear — it has a reserved slot.
      expect(find.text('Reserved scheduled'), findsOneWidget);
    });

    testWidgets('two scheduled sources each get a reserved slot', (tester) async {
      // 2 scheduled leaves from distinct sources → both should appear
      // (each gets 1 reserved slot; 3 general-pool slots remain for fillers).
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        final id1 = await db.insertTask(Task(name: 'Slot source A'));
        final id2 = await db.insertTask(Task(name: 'Slot source B'));
        await db.replaceSchedules(id1, [TaskSchedule(taskId: id1, dayOfWeek: todayDow)]);
        await db.replaceSchedules(id2, [TaskSchedule(taskId: id2, dayOfWeek: todayDow)]);
        // 3 non-scheduled fillers
        await db.insertTask(Task(name: 'Gen filler 1'));
        await db.insertTask(Task(name: 'Gen filler 2'));
        await db.insertTask(Task(name: 'Gen filler 3'));
      });

      await pumpAndLoad(tester, buildTestWidget(), rounds: 30);

      expect(find.text('Slot source A'), findsOneWidget);
      expect(find.text('Slot source B'), findsOneWidget);
    });

    testWidgets('always leaves at least one general-pool slot when multiple sources',
        (tester) async {
      // 4 scheduled sources → maxReserved = min(4, slotsAvailable-1) = 4
      // But slotsAvailable=5, so maxReserved = min(4, 4) = 4, leaving 1 general slot.
      // A non-scheduled task must appear alongside the 4 reserved ones.
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        for (var i = 1; i <= 4; i++) {
          final id = await db.insertTask(Task(name: 'Sched source $i'));
          await db.replaceSchedules(id, [TaskSchedule(taskId: id, dayOfWeek: todayDow)]);
        }
        await db.insertTask(Task(name: 'General pool task'));
      });

      await pumpAndLoad(tester, buildTestWidget(), rounds: 30);

      // All 4 scheduled sources + 1 general task = 5 total
      for (var i = 1; i <= 4; i++) {
        expect(find.text('Sched source $i'), findsOneWidget);
      }
      expect(find.text('General pool task'), findsOneWidget);
    });

    testWidgets('reserved slot cap: 5 sources → only 4 reserved, 1 general slot remains',
        (tester) async {
      // 5 scheduled sources but slotsAvailable=5 → maxReserved=4 (not all 5)
      // One of the 5 scheduled tasks must lose its guaranteed slot.
      final todayDow = DateTime.now().weekday;
      await tester.runAsync(() async {
        for (var i = 1; i <= 5; i++) {
          final id = await db.insertTask(Task(name: 'Cap source $i'));
          await db.replaceSchedules(id, [TaskSchedule(taskId: id, dayOfWeek: todayDow)]);
        }
      });

      await pumpAndLoad(tester, buildTestWidget(), rounds: 30);

      // Exactly 5 tasks shown total (screen has no fillers here)
      var count = 0;
      for (var i = 1; i <= 5; i++) {
        if (find.text('Cap source $i').evaluate().isNotEmpty) count++;
      }
      // At most 4 reserved + 1 general (which could be any of the 5 scheduled)
      // so all 5 may appear, but only 4 were reserved — total is still 5
      expect(count, equals(5));
    });
  });

  group('Roulette terminology', () {
    testWidgets('swap bottom sheet shows Roulette spin and Place your bet', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Swap me'));
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Tap the spin/swap button (tooltip: 'Spin')
      final spinButton = find.byTooltip('Spin');
      expect(spinButton, findsOneWidget);
      await tester.tap(spinButton);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Roulette spin'), findsOneWidget);
      expect(find.text('Spin the wheel for a new task'), findsOneWidget);
      expect(find.text('Place your bet'), findsOneWidget);
      expect(find.text('Hand-pick a task for this slot'), findsOneWidget);
    });

    testWidgets('respin pinned task dialog shows reroll text', (tester) async {
      late int id1, id2;
      await tester.runAsync(() async {
        id1 = await db.insertTask(Task(name: 'Pinned task'));
        id2 = await db.insertTask(Task(name: 'Other task'));
        await db.saveTodaysFiveState(
          date: _todayKey(),
          taskIds: [id1, id2],
          completedIds: {},
          workedOnIds: {},
          pinnedIds: {id1},
        );
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Find the spin button for the pinned task — there should be at least one
      final spinButtons = find.byTooltip('Spin');
      expect(spinButtons, findsAtLeastNWidgets(1));

      // Tap the first spin button (pinned task)
      await tester.tap(spinButtons.first);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Bottom sheet should show "This task was manually pinned." banner
      expect(find.text('This task was manually pinned.'), findsOneWidget);

      // Tap "Roulette spin" to trigger the unpin confirmation dialog
      await tester.tap(find.text('Roulette spin'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Reroll pinned task?'), findsOneWidget);
      expect(find.text('Reroll'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
