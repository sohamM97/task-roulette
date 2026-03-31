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
}
