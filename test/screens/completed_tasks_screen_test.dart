import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/screens/completed_tasks_screen.dart';

void main() {
  late DatabaseHelper db;
  late TaskProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    // Use NoIsolate for widget tests — isolate-based factory hangs in FakeAsync.
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

  Widget buildTestWidget() {
    return ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(
        home: CompletedTasksScreen(),
      ),
    );
  }

  /// DB ops inside the widget need runAsync (exit FakeAsync) + pump (process
  /// microtask continuations) cycles.
  Future<void> pumpAndLoad(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  group('CompletedTasksScreen', () {
    testWidgets('shows empty state when no archived tasks', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('No archived tasks'), findsOneWidget);
      expect(find.text('Tasks you complete or skip will appear here'), findsOneWidget);
    });

    testWidgets('shows completed tasks', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Done task'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Done task'), findsOneWidget);
      expect(find.text('No archived tasks'), findsNothing);
    });

    testWidgets('shows skipped tasks', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Skipped task'));
        await db.skipTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Skipped task'), findsOneWidget);
    });

    testWidgets('shows Completed today label', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Fresh'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Completed today'), findsOneWidget);
    });

    testWidgets('shows Skipped today label', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Nah'));
        await db.skipTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Skipped today'), findsOneWidget);
    });

    testWidgets('has restore and delete buttons', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Archived'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.restore), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('restore removes task from archive list', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Restore me'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Restore me'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.restore));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.text('Restore me'), findsNothing);
      expect(find.text('Restored "Restore me"'), findsOneWidget);
    });

    testWidgets('delete button shows confirmation dialog', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Delete me'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.delete_outline));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Delete permanently?'), findsOneWidget);
      expect(find.text('"Delete me" will be gone forever.'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('confirming delete removes task from list', (tester) async {
      await tester.runAsync(() async {
        final id = await db.insertTask(Task(name: 'Bye'));
        await db.completeTask(id);
      });

      await pumpAndLoad(tester, buildTestWidget());
      expect(find.text('Bye'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Delete'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(find.text('Bye'), findsNothing);
      expect(find.text('Permanently deleted "Bye"'), findsOneWidget);
    });

    testWidgets('shows parent context', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Work'));
        final childId = await db.insertTask(Task(name: 'Report'));
        await db.addRelationship(parentId, childId);
        await db.completeTask(childId);
      });

      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Was under Work'), findsOneWidget);
    });

    testWidgets('AppBar shows Archive title', (tester) async {
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Archive'), findsOneWidget);
    });
  });
}
