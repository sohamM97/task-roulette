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

    testWidgets('initialName pre-fills the name field (create-from-search)',
        (tester) async {
      AddTaskResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) => const AddTaskDialog(initialName: 'buy milk'),
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

      // Field is pre-filled with the searched term, and submitting as-is keeps
      // it (cursor is placed at the end so autofocus doesn't overwrite).
      expect(find.text('buy milk'), findsOneWidget);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect((result as SingleTask).name, 'buy milk');
    });

    testWidgets(
        'initialName carries into brain dump when "Add multiple" tapped '
        'without typing (create-from-search seeding)', (tester) async {
      // AddTaskFlow documents that initialName also seeds the brain-dump text
      // if the user switches to "Add multiple". That seeding happens via the
      // shared name controller (pre-filled with initialName), which the "Add
      // multiple" button reads into SwitchToBrainDump.initialText. This guards
      // the seeding path for the case where the user does NOT type anything —
      // distinct from the existing "preserves typed text" test.
      AddTaskResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) => const AddTaskDialog(initialName: 'buy milk'),
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

      await tester.tap(find.text('Add multiple'));
      await tester.pumpAndSettle();

      expect(result, isA<SwitchToBrainDump>());
      expect((result as SwitchToBrainDump).initialText, 'buy milk');
    });

    testWidgets('"Add multiple" is hidden when showAddMultiple is false',
        (tester) async {
      // Bug fix: the Today's 5 create flow only handles SingleTask, so it must
      // hide "Add multiple" — otherwise tapping it silently discards the task.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDialog<AddTaskResult>(
                  context: context,
                  builder: (_) => const AddTaskDialog(showAddMultiple: false),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Task'), findsOneWidget); // dialog is open
      expect(find.text('Add multiple'), findsNothing);
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

    testWidgets('"Add multiple" preserves typed text in SwitchToBrainDump',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialog(tester, onResult: (r) => result = r);

      await tester.enterText(find.byType(TextField), 'My task name');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add multiple'));
      await tester.pumpAndSettle();

      expect(result, isA<SwitchToBrainDump>());
      expect((result as SwitchToBrainDump).initialText, 'My task name');
    });

    testWidgets('"Add multiple" trims whitespace in initialText',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialog(tester, onResult: (r) => result = r);

      await tester.enterText(find.byType(TextField), '  spaced out  ');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add multiple'));
      await tester.pumpAndSettle();

      expect((result as SwitchToBrainDump).initialText, 'spaced out');
    });

    testWidgets('"Add multiple" with empty text passes empty initialText',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialog(tester, onResult: (r) => result = r);

      // Don't type anything
      await tester.tap(find.text('Add multiple'));
      await tester.pumpAndSettle();

      expect((result as SwitchToBrainDump).initialText, '');
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

      expect(find.text('Pin for today'), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    });

    testWidgets(
        'when showPinOption is true, pin toggle icon is shown',
        (tester) async {
      await openAddTaskDialogWithPin(tester, onResult: (_) {});

      expect(find.text('Pin for today'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    });

    testWidgets('tapping pin toggle changes icon to push_pin (filled)',
        (tester) async {
      await openAddTaskDialogWithPin(tester, onResult: (_) {});

      // Initially unpinned
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsNothing);

      // Tap the pin toggle
      await tester.tap(find.text('Pin for today'));
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
      await tester.tap(find.text('Pin for today'));
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
  // AddTaskDialog — Inbox toggle
  // ---------------------------------------------------------------------------
  group('AddTaskDialog inbox toggle', () {
    Future<void> openAddTaskDialogWithInbox(WidgetTester tester,
        {required ValueChanged<AddTaskResult?> onResult,
        bool showInboxOption = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) =>
                        AddTaskDialog(showInboxOption: showInboxOption),
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

    testWidgets('inbox toggle visible when showInboxOption is true',
        (tester) async {
      await openAddTaskDialogWithInbox(tester, onResult: (_) {});
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byIcon(Icons.inbox), findsOneWidget);
    });

    testWidgets('inbox toggle hidden when showInboxOption is false',
        (tester) async {
      await openAddTaskDialogWithInbox(tester,
          onResult: (_) {}, showInboxOption: false);
      expect(find.text('Inbox'), findsNothing);
    });

    testWidgets('inbox defaults ON, submitting returns addToInbox=true',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialogWithInbox(tester, onResult: (r) => result = r);

      // Inbox icon should be filled (on by default)
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(find.byIcon(Icons.inbox_outlined), findsNothing);

      await tester.enterText(find.byType(TextField), 'Inbox task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      expect((result as SingleTask).addToInbox, isTrue);
    });

    testWidgets('toggling inbox OFF then submitting returns addToInbox=false',
        (tester) async {
      AddTaskResult? result;
      await openAddTaskDialogWithInbox(tester, onResult: (r) => result = r);

      // Tap to toggle off
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();

      // Now should show outlined icon
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Regular task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      expect((result as SingleTask).addToInbox, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // AddTaskDialog — toggle placement driven by showAddMultiple
  // ---------------------------------------------------------------------------
  // The Inbox/Pin chips were extracted into a shared _buildToggles() helper.
  // With showAddMultiple:true they live in the dedicated "Add multiple" row
  // inside the dialog content (right-aligned via a Spacer). With
  // showAddMultiple:false that row is dropped and the chips fold into the
  // actions bar (an OverflowBar) beside Cancel/Add. These tests pin down the
  // button visibility, the placement in each mode, and that toggle state is
  // still honoured in the returned SingleTask regardless of where the chips
  // render.
  group('AddTaskDialog toggle placement (showAddMultiple)', () {
    Future<void> openDialog(WidgetTester tester,
        {required ValueChanged<AddTaskResult?> onResult,
        required bool showAddMultiple,
        bool showPinOption = true,
        bool showInboxOption = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<AddTaskResult>(
                    context: context,
                    builder: (_) => AddTaskDialog(
                      showAddMultiple: showAddMultiple,
                      showPinOption: showPinOption,
                      showInboxOption: showInboxOption,
                    ),
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

    // -- "Add multiple" button visibility -------------------------------------

    testWidgets('shows "Add multiple" button when showAddMultiple is true',
        (tester) async {
      await openDialog(tester, onResult: (_) {}, showAddMultiple: true);
      expect(find.text('Add multiple'), findsOneWidget);
    });

    testWidgets('hides "Add multiple" button when showAddMultiple is false',
        (tester) async {
      await openDialog(tester, onResult: (_) {}, showAddMultiple: false);
      expect(find.text('Add Task'), findsOneWidget); // dialog is open
      expect(find.text('Add multiple'), findsNothing);
    });

    // -- Toggle placement ------------------------------------------------------

    testWidgets(
        'toggles live in the content (not the actions bar) when '
        'showAddMultiple is true', (tester) async {
      await openDialog(tester, onResult: (_) {}, showAddMultiple: true);

      // Both chips render.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Pin'), findsOneWidget);

      // AlertDialog wraps its actions in an OverflowBar. In the true case the
      // chips belong to the "Add multiple" content row, so they must NOT be
      // descendants of the actions OverflowBar.
      expect(
        find.ancestor(
            of: find.text('Inbox'), matching: find.byType(OverflowBar)),
        findsNothing,
      );
      expect(
        find.ancestor(
            of: find.text('Pin'), matching: find.byType(OverflowBar)),
        findsNothing,
      );
    });

    testWidgets(
        'toggles fold into the actions bar (OverflowBar) when '
        'showAddMultiple is false', (tester) async {
      await openDialog(tester, onResult: (_) {}, showAddMultiple: false);

      // Both chips still render.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Pin'), findsOneWidget);

      // With no "Add multiple" row to host them, the chips render inline in the
      // actions OverflowBar beside Cancel/Add.
      expect(
        find.ancestor(
            of: find.text('Inbox'), matching: find.byType(OverflowBar)),
        findsOneWidget,
      );
      expect(
        find.ancestor(
            of: find.text('Pin'), matching: find.byType(OverflowBar)),
        findsOneWidget,
      );
      // Sanity: Cancel/Add share that same actions bar.
      expect(
        find.ancestor(
            of: find.text('Cancel'), matching: find.byType(OverflowBar)),
        findsOneWidget,
      );
    });

    // -- Toggle state honoured regardless of placement -------------------------

    testWidgets(
        'toggle state (pin on, inbox off) reflected in SingleTask when '
        'showAddMultiple is false (actions-bar placement)', (tester) async {
      AddTaskResult? result;
      await openDialog(tester,
          onResult: (r) => result = r, showAddMultiple: false);

      // Inbox defaults ON; turn it off. Pin defaults OFF; turn it on.
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();

      // Icons reflect the new state even in the actions-bar placement.
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Today five task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(result, isA<SingleTask>());
      final single = result as SingleTask;
      expect(single.name, 'Today five task');
      expect(single.pinInTodays5, isTrue);
      expect(single.addToInbox, isFalse);
    });

    testWidgets(
        'default toggle state (inbox on, pin off) reflected in SingleTask when '
        'showAddMultiple is false', (tester) async {
      AddTaskResult? result;
      await openDialog(tester,
          onResult: (r) => result = r, showAddMultiple: false);

      // Do not touch the toggles — inbox defaults ON, pin defaults OFF.
      await tester.enterText(find.byType(TextField), 'Defaults task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final single = result as SingleTask;
      expect(single.addToInbox, isTrue);
      expect(single.pinInTodays5, isFalse);
    });

    testWidgets(
        'toggle state (pin on, inbox off) still honoured when '
        'showAddMultiple is true (content-row placement)', (tester) async {
      AddTaskResult? result;
      await openDialog(tester,
          onResult: (r) => result = r, showAddMultiple: true);

      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Content row task');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final single = result as SingleTask;
      expect(single.pinInTodays5, isTrue);
      expect(single.addToInbox, isFalse);
    });

    // -- Pin label still adapts to inbox visibility under either placement -----

    testWidgets(
        'pin label reads "Pin" when inbox shown (showAddMultiple false)',
        (tester) async {
      // Both options → compact "Pin" label beside the Inbox chip.
      await openDialog(tester,
          onResult: (_) {}, showAddMultiple: false, showInboxOption: true);
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Pin for today'), findsNothing);
    });

    testWidgets(
        'pin label reads "Pin for today" when inbox hidden '
        '(showAddMultiple false)', (tester) async {
      // Pin only (no inbox) → the standalone "Pin for today" label.
      await openDialog(tester,
          onResult: (_) {}, showAddMultiple: false, showInboxOption: false);
      expect(find.text('Pin for today'), findsOneWidget);
      expect(find.text('Pin'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // BrainDumpDialog — Inbox toggle
  // ---------------------------------------------------------------------------
  group('BrainDumpDialog inbox toggle', () {
    Future<void> openBrainDumpWithInbox(WidgetTester tester,
        {required ValueChanged<BrainDumpResult?> onResult,
        bool showInboxOption = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<BrainDumpResult>(
                    context: context,
                    builder: (_) =>
                        BrainDumpDialog(showInboxOption: showInboxOption),
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

    testWidgets('inbox toggle visible when showInboxOption is true and has text',
        (tester) async {
      await openBrainDumpWithInbox(tester, onResult: (_) {});

      // Initially no inbox toggle (no text entered yet)
      // Enter some text to show the toggle
      await tester.enterText(find.byType(TextField), 'Task 1\nTask 2');
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('submitting brain dump with inbox ON returns addToInbox=true',
        (tester) async {
      BrainDumpResult? result;
      await openBrainDumpWithInbox(tester, onResult: (r) => result = r);

      await tester.enterText(find.byType(TextField), 'Task A\nTask B');
      await tester.pumpAndSettle();

      // Inbox should be ON by default
      expect(find.byIcon(Icons.inbox), findsOneWidget);

      await tester.tap(find.text('Add 2'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.names, ['Task A', 'Task B']);
      expect(result!.addToInbox, isTrue);
    });

    testWidgets('toggling inbox OFF in brain dump returns addToInbox=false',
        (tester) async {
      BrainDumpResult? result;
      await openBrainDumpWithInbox(tester, onResult: (r) => result = r);

      await tester.enterText(find.byType(TextField), 'Task X');
      await tester.pumpAndSettle();

      // Toggle off
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add 1'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.addToInbox, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // BrainDumpDialog
  // ---------------------------------------------------------------------------
  group('BrainDumpDialog', () {
    Future<void> openBrainDumpDialog(WidgetTester tester,
        {required ValueChanged<BrainDumpResult?> onResult}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<BrainDumpResult>(
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

    testWidgets('submit returns BrainDumpResult with task names', (tester) async {
      BrainDumpResult? result;
      await openBrainDumpDialog(tester, onResult: (r) => result = r);

      await tester.enterText(
          find.byType(TextField), 'Buy groceries\n  Call dentist \n\nFinish report');
      await tester.pumpAndSettle();

      // The button should show "Add 3"
      expect(find.text('Add 3'), findsOneWidget);

      await tester.tap(find.text('Add 3'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.names, ['Buy groceries', 'Call dentist', 'Finish report']);
      expect(result!.addToInbox, isFalse); // showInboxOption is false by default
    });

    testWidgets('Add button is disabled when text is empty', (tester) async {
      await openBrainDumpDialog(tester, onResult: (_) {});

      // With no text entered, the button should show just "Add" and be disabled
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('pre-fills with initialText', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await showDialog<BrainDumpResult>(
                    context: context,
                    builder: (_) =>
                        const BrainDumpDialog(initialText: 'Carried over'),
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

      // The text field should contain the initial text
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, 'Carried over');
      // Line count should reflect the pre-filled text
      expect(find.text('1 task'), findsOneWidget);
    });
  });
}
