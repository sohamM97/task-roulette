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

  /// Helper to insert a parent with a child and navigate into the parent.
  Future<void> insertAndNavigateInto(
    WidgetTester tester, {
    required String parentName,
    String? parentUrl,
    bool addChild = true,
  }) async {
    late Task parent;
    await tester.runAsync(() async {
      final parentId = await db.insertTask(Task(name: parentName, url: parentUrl));
      if (addChild) {
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
      }
      parent = (await db.getTaskById(parentId))!;
    });
    // Load root first, then navigate into parent
    await tester.runAsync(() async {
      await provider.loadRootTasks();
      await provider.navigateInto(parent);
    });
    await pumpAsync(tester);
  }

  group('TaskListScreen overflow menu', () {
    testWidgets('shows overflow menu at root with export/import items only',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      final menuButton = find.byIcon(Icons.more_vert);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await pumpAsync(tester);

      // Root on non-web: only export/import, no task-specific items
      expect(find.text('Export backup'), findsOneWidget);
      expect(find.text('Import backup'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Schedule'), findsNothing);
      expect(find.text('Also show under...'), findsNothing);
    });

    testWidgets(
        'shows task-specific items when navigated into a task with children',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());
      await insertAndNavigateInto(tester, parentName: 'Parent');

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      // Non-root with children: Rename, link, Do after, Schedule, Delete, export/import
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Do after...'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Export backup'), findsOneWidget);
      expect(find.text('Import backup'), findsOneWidget);
      // "Also show under..." only for leaves
      expect(find.text('Also show under...'), findsNothing);
    });

    testWidgets(
        'shows "Also show under..." for leaf task (no children) instead of Rename/Do after',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());
      await insertAndNavigateInto(tester, parentName: 'Leaf', addChild: false);

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      expect(find.text('Also show under...'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Do after...'), findsNothing);
      // Schedule and Delete still present
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('shows "Add link" when task has no URL', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());
      await insertAndNavigateInto(tester, parentName: 'No URL Task');

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      expect(find.text('Add link'), findsOneWidget);
      expect(find.text('Edit link'), findsNothing);
    });

    testWidgets('shows "Edit link" when task has a URL', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());
      await insertAndNavigateInto(tester,
          parentName: 'URL Task', parentUrl: 'https://example.com');

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      expect(find.text('Edit link'), findsOneWidget);
      expect(find.text('Add link'), findsNothing);
    });

    testWidgets('has two dividers when non-root with children on non-web',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());
      await insertAndNavigateInto(tester, parentName: 'Task');

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      // Two dividers: one between Do after and Schedule/Delete section,
      // one between Delete and Export/Import
      final dividers = find.byType(PopupMenuDivider);
      expect(dividers, findsNWidgets(2));
    });

    testWidgets('has no divider at root on non-web',
        (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpAsync(tester);

      // At root, no task-specific items appear, so the export/import divider
      // is also hidden (no items above it to separate from)
      final dividers = find.byType(PopupMenuDivider);
      expect(dividers, findsNothing);
    });
  });
}
