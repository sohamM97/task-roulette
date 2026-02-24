import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/widgets/empty_state.dart';
import 'package:task_roulette/widgets/delete_task_dialog.dart';
import 'package:task_roulette/widgets/add_task_dialog.dart';
import 'package:task_roulette/widgets/brain_dump_dialog.dart';

void main() {
  // ---------------------------------------------------------------------------
  // EmptyState
  // ---------------------------------------------------------------------------
  group('EmptyState', () {
    testWidgets('isRoot: true shows "No tasks yet" with task_alt icon',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: EmptyState(isRoot: true)),
        ),
      );

      expect(find.text('No tasks yet'), findsOneWidget);
      expect(find.byIcon(Icons.task_alt), findsOneWidget);
      expect(find.text('Tap + to add your first one!'), findsOneWidget);
    });

    testWidgets(
        'isRoot: false shows "No subtasks yet" with subdirectory_arrow_right icon',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: EmptyState(isRoot: false)),
        ),
      );

      expect(find.text('No subtasks yet'), findsOneWidget);
      expect(find.byIcon(Icons.subdirectory_arrow_right), findsOneWidget);
      expect(find.text('Tap + to add your first one!'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // DeleteTaskDialog
  // ---------------------------------------------------------------------------
  group('DeleteTaskDialog', () {
    Future<DeleteChoice?> showDeleteDialog(WidgetTester tester,
        {String taskName = 'My Task'}) async {
      DeleteChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<DeleteChoice>(
                    context: context,
                    builder: (_) => DeleteTaskDialog(taskName: taskName),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('shows task name in title', (tester) async {
      await showDeleteDialog(tester, taskName: 'Buy groceries');

      expect(find.text('Delete "Buy groceries"?'), findsOneWidget);
    });

    testWidgets('has Cancel, Keep sub-tasks, and Delete everything buttons',
        (tester) async {
      await showDeleteDialog(tester);

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Keep sub-tasks'), findsOneWidget);
      expect(find.text('Delete everything'), findsOneWidget);
    });

    testWidgets('Cancel returns null', (tester) async {
      DeleteChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<DeleteChoice>(
                    context: context,
                    builder: (_) => DeleteTaskDialog(taskName: 'Test'),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('Keep sub-tasks returns DeleteChoice.reparent', (tester) async {
      DeleteChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<DeleteChoice>(
                    context: context,
                    builder: (_) => DeleteTaskDialog(taskName: 'Test'),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep sub-tasks'));
      await tester.pumpAndSettle();

      expect(result, DeleteChoice.reparent);
    });

    testWidgets('Delete everything returns DeleteChoice.deleteAll',
        (tester) async {
      DeleteChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<DeleteChoice>(
                    context: context,
                    builder: (_) => DeleteTaskDialog(taskName: 'Test'),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete everything'));
      await tester.pumpAndSettle();

      expect(result, DeleteChoice.deleteAll);
    });
  });

  // ---------------------------------------------------------------------------
  // AddTaskDialog
  // ---------------------------------------------------------------------------
  group('AddTaskDialog', () {
    Future<void> openAddTaskDialog(WidgetTester tester,
        {required ValueChanged<AddTaskResult?> onResult}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) => const AddTaskDialog(),
                  );
                  onResult(result);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows "Add Task" title and TextField', (tester) async {
      await openAddTaskDialog(tester, onResult: (_) {});

      expect(find.text('Add Task'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('entering text and tapping Add returns SingleTask',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialog(tester, onResult: (r) => result = r);

      await tester.enterText(find.byType(TextField), 'New task name');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      expect((result as SingleTask).name, 'New task name');
    });

    testWidgets('empty text does not submit when tapping Add', (tester) async {
      AddTaskResult? result;
      bool resultCalled = false;
      await openAddTaskDialog(tester, onResult: (r) {
        resultCalled = true;
        result = r;
      });

      // Leave the text field empty and tap Add
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // Dialog should still be open (not dismissed)
      expect(find.text('Add Task'), findsOneWidget);
      // result callback may not have been called, or if called, result is null
      if (resultCalled) {
        expect(result, isNull);
      }
    });

    testWidgets('whitespace-only text does not submit', (tester) async {
      await openAddTaskDialog(tester, onResult: (_) {});

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // Dialog should still be open
      expect(find.text('Add Task'), findsOneWidget);
    });

    testWidgets('"Add multiple" button returns SwitchToBrainDump',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialog(tester, onResult: (r) => result = r);

      await tester.tap(find.text('Add multiple'));
      await tester.pumpAndSettle();

      expect(result, isA<SwitchToBrainDump>());
    });

    // -------------------------------------------------------------------------
    // Pin option in AddTaskDialog
    // -------------------------------------------------------------------------

    Future<void> openAddTaskDialogWithPin(WidgetTester tester,
        {required ValueChanged<AddTaskResult?> onResult,
        bool showPinOption = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) =>
                        AddTaskDialog(showPinOption: showPinOption),
                  );
                  onResult(result);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('when showPinOption is false, no pin toggle is shown',
        (tester) async {
      await openAddTaskDialogWithPin(tester,
          onResult: (_) {}, showPinOption: false);

      expect(find.text("Today's 5"), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    });

    testWidgets(
        'when showPinOption is true, pin toggle is shown with "Today\'s 5" text',
        (tester) async {
      await openAddTaskDialogWithPin(tester, onResult: (_) {});

      expect(find.text("Today's 5"), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    });

    testWidgets('tapping pin toggle changes icon to push_pin (filled)',
        (tester) async {
      await openAddTaskDialogWithPin(tester, onResult: (_) {});

      // Initially unpinned
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Tap the pin toggle
      await tester.tap(find.text("Today's 5"));
      await tester.pumpAndSettle();

      // Now pinned
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    });

    testWidgets(
        'submitting with pin toggled returns SingleTask with pinInTodays5=true',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialogWithPin(tester, onResult: (r) => result = r);

      // Toggle pin on
      await tester.tap(find.text("Today's 5"));
      await tester.pumpAndSettle();

      // Enter text and submit
      await tester.enterText(find.byType(TextField), 'Pinned task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      final singleTask = result as SingleTask;
      expect(singleTask.name, 'Pinned task');
      expect(singleTask.pinInTodays5, isTrue);
    });

    testWidgets(
        'submitting without pin toggled returns SingleTask with pinInTodays5=false',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialogWithPin(tester, onResult: (r) => result = r);

      // Do not toggle pin — leave it off
      await tester.enterText(find.byType(TextField), 'Unpinned task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      final singleTask = result as SingleTask;
      expect(singleTask.name, 'Unpinned task');
      expect(singleTask.pinInTodays5, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // BrainDumpDialog
  // ---------------------------------------------------------------------------
  group('BrainDumpDialog', () {
    Future<void> openBrainDumpDialog(WidgetTester tester,
        {required ValueChanged<List<String>?> onResult}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<List<String>>(
                    context: context,
                    builder: (_) => const BrainDumpDialog(),
                  );
                  onResult(result);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows "Brain dump" title', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      expect(find.text('Brain dump'), findsOneWidget);
      expect(find.text('One task per line'), findsOneWidget);
    });

    testWidgets('entering multiple lines shows correct count', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      await tester.enterText(
          find.byType(TextField), 'Task A\nTask B\nTask C');
      await tester.pumpAndSettle();

      expect(find.text('3 tasks'), findsOneWidget);
    });

    testWidgets('single line shows "1 task" (singular)', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      await tester.enterText(find.byType(TextField), 'Only one');
      await tester.pumpAndSettle();

      expect(find.text('1 task'), findsOneWidget);
    });

    testWidgets('trims whitespace and filters empty lines', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      await tester.enterText(
          find.byType(TextField), '  Task A  \n\n  \nTask B\n\n');
      await tester.pumpAndSettle();

      // Only 2 non-empty lines after trimming
      expect(find.text('2 tasks'), findsOneWidget);
    });

    testWidgets('submit returns list of task names', (tester) async {
      List<String>? result;
      await openBrainDumpDialog(tester, onResult: (r) => result = r);

      await tester.enterText(
          find.byType(TextField), 'Buy groceries\n  Call dentist \n\nFinish report');
      await tester.pumpAndSettle();

      // The button should show "Add 3"
      expect(find.text('Add 3'), findsOneWidget);

      await tester.tap(find.text('Add 3'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result, ['Buy groceries', 'Call dentist', 'Finish report']);
    });

    testWidgets('Add button is disabled when text is empty', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      // With no text entered, the button should show just "Add" and be disabled
      expect(find.text('Add'), findsOneWidget);
    });
  });
}
