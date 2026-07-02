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
import 'package:task_roulette/screens/task_list_screen.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/utils/display_utils.dart';

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

  Widget buildTestWidget() {
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
      child: const MaterialApp(
        home: TaskListScreen(),
      ),
    );
  }

  group('TaskListScreen root state', () {
    testWidgets('shows "Task Roulette" title at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Task Roulette'), findsOneWidget);
    });

    testWidgets('shows empty state when no tasks at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // EmptyState widget shows "No tasks yet"
      expect(find.textContaining('No tasks yet'), findsOneWidget);
    });

    testWidgets('shows add FAB at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('does not show link FAB at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.playlist_add), findsNothing);
    });

    testWidgets('shows back button hidden at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('shows task graph button at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    });

    testWidgets('shows task cards in grid when tasks exist', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Work'));
        await db.insertTask(Task(name: 'Personal'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
    });

    testWidgets('shows flare FAB when tasks exist', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Task'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flare), findsOneWidget);
    });

    testWidgets('hides flare FAB when no tasks', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flare), findsNothing);
    });

    testWidgets('no star button at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.star_outline), findsNothing);
      expect(find.byIcon(Icons.star), findsNothing);
    });
  });

  group('TaskListScreen navigation', () {
    testWidgets('navigating into a task shows its name in AppBar',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'My Project'));
        final childId = await db.insertTask(Task(name: 'Sub Task'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Tap on the task card to navigate
      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);

      expect(find.text('My Project'), findsWidgets); // AppBar + breadcrumb
      expect(find.text('Sub Task'), findsOneWidget);
    });

    testWidgets('shows back button when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('back button returns to root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await pumpAsync(tester);

      expect(find.text('Task Roulette'), findsOneWidget);
    });

    testWidgets('shows breadcrumb when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Level 1'));
        final childId = await db.insertTask(Task(name: 'Level 2'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Level 1'));
      await pumpAsync(tester);

      // Breadcrumb should show "Task Roulette" as clickable root + current task
      expect(find.text('Task Roulette'), findsOneWidget); // breadcrumb root
      // Chevron separator
      expect(find.byIcon(Icons.chevron_right), findsWidgets);
    });

    testWidgets('hides task graph button when not at root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
    });

    testWidgets('shows link FAB when not at root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.playlist_add), findsOneWidget);
    });

    testWidgets('shows star button when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.star_outline), findsOneWidget);
    });
  });

  group('TaskListScreen leaf detail', () {
    testWidgets('shows leaf task detail when navigating into a leaf',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Leaf Task'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Navigate into parent, then into leaf
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf Task'));
      await pumpAsync(tester);

      // Should show the leaf task name in AppBar
      expect(find.text('Leaf Task'), findsWidgets);
    });
  });

  group('TaskListScreen inbox', () {
    testWidgets('shows inbox section at root when inbox tasks exist',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular task'));
        await db.insertTask(Task(name: 'Inbox task', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Should show both tasks
      expect(find.text('Regular task'), findsOneWidget);
      expect(find.text('Inbox task'), findsOneWidget);
      // Inbox section header
      expect(find.textContaining('Inbox'), findsWidgets);
    });
  });

  group('TaskListScreen link button', () {
    testWidgets('shows link icon when task has URL and children',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(
            Task(name: 'Linked', url: 'https://example.com'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Linked'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.link), findsOneWidget);
    });

    testWidgets('hides link icon when task has no URL', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'No URL'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('No URL'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.link), findsNothing);
    });
  });

  group('Pin-for-today on add (empty-day regression)', () {
    // [Regression] Bug: AddTaskFlow._pinNewTask returned true (reporting
    // success) without pinning when no Today's 5 row existed yet. Since Today's
    // 5 is empty-by-default each day, "Pin for today" on a fresh day silently
    // created the task UNPINNED. After the fix it bootstraps an empty state and
    // pins into it.
    testWidgets('pinning a new task on an empty day actually pins it',
        (tester) async {
      await tester.runAsync(() => provider.loadRootTasks());
      await pumpAndLoad(tester, buildTestWidget());

      // Empty day — no saved Today's 5 state.
      final before = await tester
          .runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(before, isNull);

      // Open the Add dialog via the + FAB, turn Pin ON, add a task.
      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.tap(find.text('Pin'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Focus task');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      });
      await pumpAsync(tester);

      // The task is pinned into a freshly bootstrapped Today's 5 state.
      final after = await tester
          .runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(after, isNotNull);
      expect(after!.pinnedIds, isNotEmpty);
      expect(after.taskIds.length, 1);
    });
  });

  group('Deadline-today suppression from All Tasks unpin (Codex P2)', () {
    // [Regression] Codex P2: unpinning a due-today task from All Tasks only
    // dropped it from todays_five_state without writing a suppression, so the
    // next Today reconcile re-auto-pinned it (the unpin didn't stick). The
    // unpin must now record the suppression, matching the Today screen's remove.
    testWidgets('unpinning a due-today task from All Tasks suppresses it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(
            Task(name: 'Due today leaf', deadline: todayDateKey()));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [id],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {id},
        );
        await provider.loadRootTasks();
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Navigate into the leaf to reach its detail view + pin toggle.
      await tester.tap(find.text('Due today leaf'));
      await pumpAsync(tester);

      // Unpin from All Tasks (PinButton shows tooltip 'Unpin' when pinned).
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Unpin'));
      });
      await pumpAsync(tester);

      // Dropped from Today's 5 AND recorded as suppressed.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved?.taskIds ?? const <int>[], isNot(contains(id)));
      final suppressed = await tester
          .runAsync(() => db.getDeadlineSuppressedIds(todayDateKey()));
      expect(suppressed, contains(id));
    });

    // [Regression] Codex P2 (round 2): the suppression was gated to due-today
    // tasks only, so unpinning a NON-deadline pinned task left no tombstone and
    // the removal bounced back (re-added by the local-only-pinned merge append
    // on the next pull). It must now suppress regardless of deadline.
    testWidgets('unpinning a non-deadline task from All Tasks suppresses it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Plain pinned leaf'));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [id],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {id},
        );
        await provider.loadRootTasks();
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain pinned leaf'));
      await pumpAsync(tester);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Unpin'));
      });
      await pumpAsync(tester);

      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved?.taskIds ?? const <int>[], isNot(contains(id)));
      final suppressed = await tester
          .runAsync(() => db.getDeadlineSuppressedIds(todayDateKey()));
      expect(suppressed, contains(id));
    });
  });
}
